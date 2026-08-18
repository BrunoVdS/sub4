//
//  NoteWriteTests.swift
//  Sub4CoreTests
//
//  One note, one transaction — patch 408, ADR-0003 §12.152, plan topic 1B.
//
//  WHAT THIS IS THE FIRST HALF OF
//  ------------------------------
//  A note save is file-first today: memory, then `notes.json`, then a
//  fire-and-forget whole-world import. A termination before that import commits
//  leaves SQLite older than the file, and the next launch can publish the old
//  value from a database-hydrated store. The plan's mutation contract is the
//  other order — SQLite commits before observable success, and the JSON mirror
//  follows.
//
//  THIS PATCH BUILDS THE WRITE AND CHANGES NO ORDER. `NotesStore` is untouched;
//  409 inverts it. That is 381-before-382's discipline: when the flip is the
//  only thing in its patch, anything that breaks on flip day is attributable to
//  it — 346 produced four failures and 382 three, and every one was diagnosed
//  in minutes because there was nothing else to suspect.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("One note, one transaction")
struct NoteWriteTests {

    private func note(_ uid: String, rpe: Int? = 5, text: String = "felt fine",
                      edited: Double = 1_755_000_000) -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: rpe, feel: .expected, text: text,
                        created: Date(timeIntervalSince1970: 1_755_000_000),
                        edited: Date(timeIntervalSince1970: edited))
    }

    /// **A DATABASE THAT HAS BEEN IMPORTED INTO**, which is the only state a
    /// narrow write ever meets. `user_note.accountID` references `account`, and
    /// the account row is the importer's to create — so a bare in-memory
    /// database refuses every note with a foreign-key error. That is the
    /// correct behaviour and not a gap: a single-note write is not the thing
    /// that should be establishing who the athlete is.
    private func imported() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        return db
    }

    private func rows(_ db: Sub4Database) throws -> [NotesStore.Note] {
        guard case .loaded(let notes, _, _) = AuthoredRepository.load(db) else {
            return []
        }
        return notes
    }

    // MARK: The write

    @Test("A note is inserted, then updated, and says which")
    func insertThenUpdate() throws {
        let db = try imported()

        let first = NoteRepository.upsert(note("wk-01-mon"), in: db)
        #expect(first == .wrote(inserted: true))
        #expect(try rows(db).count == 1)

        let again = NoteRepository.upsert(note("wk-01-mon", text: "edited"), in: db)
        #expect(again == .wrote(inserted: false),
                "the second write is an update, and a caller may need to know")
        let all = try rows(db)
        #expect(all.count == 1, "one session, one note — never a duplicate row")
        #expect(all.first?.text == "edited")
    }

    @Test("A note is deleted, and deleting one that is gone is not a refusal")
    func deleteAndDeleteAgain() throws {
        let db = try imported()
        _ = NoteRepository.upsert(note("wk-01-mon"), in: db)

        #expect(NoteRepository.delete(noteFor: "wk-01-mon", in: db).committed)
        #expect(try rows(db).isEmpty)

        // The caller asked for it to be gone and it is gone. §12.15's
        // distinction is about REASONS, not about work already done.
        #expect(NoteRepository.delete(noteFor: "wk-01-mon", in: db).committed,
                "a delete of nothing is not an error to put in front of somebody")
    }

    /// **THE ONE THAT PROVES THE MAPPING IS SHARED.**
    ///
    /// `NoteRepository.upsert` hands `Sub4Import.importNotes` an array of one.
    /// If it ever grew its own mapping instead, this test would be the only
    /// thing that noticed — two ways to write the athlete's own words, agreeing
    /// on the columns somebody remembered and differing on the rest. §12.43,
    /// whose worst instance was five copies of one rule disagreeing for 230
    /// patches.
    @Test("The narrow write produces exactly what a whole import produces")
    func theNarrowWriteMatchesTheImporter() throws {
        let narrow = try imported()
        let whole = try Sub4Database.inMemory()
        let n = note("wk-03-thu", rpe: 7, text: "hard, and windy")

        _ = NoteRepository.upsert(n, in: narrow)
        _ = try Sub4Import.run(into: whole, activities: [], shoes: [], notes: [n])

        let a = try #require(try rows(narrow).first)
        let b = try #require(try rows(whole).first)
        #expect(a.sessionUid == b.sessionUid)
        #expect(a.rpe == b.rpe)
        #expect(a.feel == b.feel)
        #expect(a.text == b.text)
        #expect(a.created == b.created)
        #expect(a.edited == b.edited)
    }

    // MARK: The refusals, and each says something different

    /// §12.15. "There is no database" is not "the database refused you", and a
    /// caller shows the athlete different things for each.
    @Test("No database is not a refusal")
    func noDatabaseIsNotARefusal() {
        let w = NoteRepository.upsert(note("wk-01-mon"), in: nil)
        #expect(w == .noDatabase)
        #expect(!w.committed)
        #expect(w.line.contains("not open"))
        #expect(NoteRepository.delete(noteFor: "wk-01-mon", in: nil) == .noDatabase)
    }

    /// **A REFUSAL INSIDE THE SAVEPOINT IS NOT A THROW**, and that is the trap
    /// this write had to avoid. `importNotes` catches per note and records a
    /// refusal on the report rather than letting it escape, so a caller that
    /// checked only for a thrown error would read "refused" as "written" — the
    /// exact failure 1B exists to stop.
    ///
    /// **A DATABASE WITH NO ACCOUNT IS THAT CASE, and it was found by
    /// accident.** The first draft of this suite used a bare in-memory database
    /// and every note came back refused on a foreign key, which looked like a
    /// fixture mistake and was also the only reachable way to prove the guard
    /// fires. Removing the check from `upsert` passes every other test in this
    /// file.
    @Test("A refusal recorded on the report is reported, not swallowed")
    func aRecordedRefusalIsReported() throws {
        let bare = try Sub4Database.inMemory()   // migrated, never imported into

        let w = NoteRepository.upsert(note("wk-01-mon"), in: bare)
        #expect(!w.committed, "a foreign-key refusal is not a write")
        guard case .refused(let why) = w else {
            Issue.record("a refused note must say so, not report `wrote`")
            return
        }
        #expect(why.contains("FOREIGN KEY"),
                "and it carries what SQLite said, because a caller has to act on it")
        #expect(try rows(bare).isEmpty, "and nothing is committed")
    }

    /// **THE REFUSAL THAT LANDS INSIDE THE SAVEPOINT, WHICH IS THE ONE THE
    /// GUARD IS FOR.**
    ///
    /// The foreign-key case above proves `upsert` reports a refusal, but not
    /// through the branch that matters: a missing account fires when the OUTER
    /// transaction commits, so it reaches `upsert`'s `catch` and the
    /// `report.refusals` check is never consulted. Deleting that check passed
    /// the whole suite — §12.69, a guard that cannot fail has not been tested.
    ///
    /// `user_note.rpe` carries `CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10))`,
    /// which fires on the statement. `importNotes` catches it, records a
    /// refusal and returns NORMALLY — so nothing throws, `notesImported` stays
    /// zero, and without the check `upsert` would answer `.wrote`.
    @Test("A refusal inside the savepoint is not reported as a write")
    func aSavepointRefusalIsNotAWrite() throws {
        let db = try imported()

        let w = NoteRepository.upsert(note("wk-01-mon", rpe: 99), in: db)
        #expect(!w.committed,
                "the statement was refused and nothing was written")
        guard case .refused(let why) = w else {
            Issue.record("a note the database refused must not report `wrote`")
            return
        }
        #expect(why.contains("CHECK") || why.contains("constraint"),
                "and it says which constraint, because a caller has to act on it")
        #expect(try rows(db).isEmpty)
    }

    /// The other side of the same coin: an ordinary note on an imported
    /// database records no refusal and sets the counter `upsert` reads to
    /// answer inserted-or-updated. Without this the test above could pass on a
    /// write that refuses everything.
    @Test("An ordinary note is not refused")
    func anOrdinaryNoteIsNotRefused() throws {
        let db = try imported()
        var report = Sub4Import.Report()
        try db.queue.write { d in
            try Sub4Import.importNotes(d, notes: [note("wk-01-mon")],
                                       now: Sub4Import.iso8601(Date()),
                                       into: &report)
        }
        #expect(report.refusals.isEmpty)
        #expect(report.notesImported == 1)
    }

    /// The line is always sayable — §12.54.2 — because a caller may need to put
    /// it in front of somebody who cannot see the code.
    @Test("Every outcome can describe itself")
    func everyOutcomeCanDescribeItself() {
        #expect(NoteWrite.wrote(inserted: true).line == "written")
        #expect(NoteWrite.wrote(inserted: false).line == "updated")
        #expect(NoteWrite.refused("disk I/O error").line.contains("REFUSED"))
        #expect(NoteWrite.noDatabase.line.contains("not open"))
    }
}
