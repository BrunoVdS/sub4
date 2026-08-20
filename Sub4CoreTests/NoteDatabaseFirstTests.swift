//
//  NoteDatabaseFirstTests.swift
//  Sub4CoreTests
//
//  The four controls for the inverted order — patch 409, ADR-0003 §12.153,
//  plan topic 1B.
//
//  WHAT 408 COULD NOT TEST
//  -----------------------
//  408 built the narrow write and changed no order, so `NoteWriteTests` proves
//  a note can be committed in one transaction and says nothing about WHEN. The
//  defect 1B names is entirely a question of when: a note save was memory,
//  then `notes.json`, then a fire-and-forget whole-world import, and a
//  termination in that last window left SQLite older than the file. Before B2
//  that was a durability gap somebody would notice at the next import. **After
//  B2's flip the launch hydrates from the database**, so it is a wrong answer
//  on screen — the athlete's edit reverts, silently, at the next launch.
//
//  Every test here fails against the pre-409 order. That is the point of them;
//  §12.69 says a guard that cannot fail has not been tested, and the same is
//  true of a contract.
//
//  WHY THESE STORES CARRY THEIR OWN DATABASE
//  -----------------------------------------
//  `init(directory:database:)`, which 409 added for exactly this. The obvious
//  alternative — let the store read `Sub4Launch.shared.database` — put the
//  athlete's real notes at risk from the suite: `DatabaseBootstrapTests` and
//  `ImporterSeedTests` call `Sub4Launch.shared.begin()`, which opens the app's
//  own database for every test that runs after them. See `AuthoredDatabase`.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A note commits before it is published")
@MainActor
struct NoteDatabaseFirstTests {

    // MARK: Fixtures

    /// A database the importer has been through — `user_note.accountID`
    /// references `account`, so a bare in-memory database refuses every note.
    private func imported() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        return db
    }

    private func writableDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-db-first-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// A directory that does not exist, which is the only honest way to make a
    /// file write fail.
    private func unwritableDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-gone-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func session(_ uid: String = "w03-tue") -> Session {
        Session(uid: uid, weekUid: "w03", day: "Tue", date: "2026-08-04",
                discipline: .run, intensity: .easy, title: "Easy 8 km",
                detail: nil, fuel: nil, prep: nil, seq: 1,
                swimDetail: nil, strengthDetail: nil)
    }

    private func storedNotes(_ db: Sub4Database) -> [NotesStore.Note] {
        guard case .loaded(let notes, _, _) = AuthoredRepository.load(db) else {
            return []
        }
        return notes
    }

    /// **THE NEXT LAUNCH.** A fresh store over the same directory, hydrated
    /// from the database exactly as B2's flip hydrates the real one.
    ///
    /// This is the only instrument that can see 1B's defect at all: the whole
    /// failure is that a store built after a termination publishes the wrong
    /// value, and a store that never went away cannot show it. It reads
    /// `directory` too, so a test can tell "the database won" from "they
    /// happened to agree".
    private func relaunch(on db: Sub4Database, in directory: URL) -> NotesStore {
        let store = NotesStore(directory: directory, database: db)
        store.hydrate(from: storedNotes(db))
        return store
    }

    // MARK: 1 — a refused commit publishes nothing

    @Test("A commit the database refuses leaves nothing published anywhere")
    func aRefusedCommitPublishesNothing() throws {
        let dir = try writableDirectory()
        let db = try imported()
        let store = NotesStore(directory: dir, database: db)

        // `user_note` CHECKs `rpe IS NULL OR (rpe >= 1 AND rpe <= 10)`, which
        // is the one refusal that reaches the store rather than the outer
        // commit — a foreign-key violation fires later, at the transaction.
        #expect(throws: StoreWriteError.self) {
            _ = try store.save(session: self.session(), rpe: 99, feel: .expected,
                               text: "eleven out of ten")
        }

        // THE THREE PLACES, ALL THREE ASKED. Memory is what the sheet reads
        // back; the file is what the pre-409 order would already have written;
        // the rows are the authority. A control that asked only one of them
        // could pass over a note sitting in either of the others.
        #expect(store.count == 0, "the sheet must not show a note the database refused")
        #expect(!FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("notes.json").path),
                "file-first wrote the mirror before the commit was attempted")
        #expect(storedNotes(db).isEmpty)
    }

    // MARK: 2 — the commit survives a mirror that never lands

    @Test("A note committed before the mirror failed is there at the next launch")
    func theCommitSurvivesTheMirror() throws {
        let dir = unwritableDirectory()
        let db = try imported()
        let store = NotesStore(directory: dir, database: db)

        // The mirror cannot land — the directory does not exist. Under the
        // inverted order that is not the athlete's problem: the edit is
        // already committed, so it must NOT be reported as a failure.
        let saved = try store.save(session: session(), rpe: 4, feel: .expected,
                                   text: "committed, not mirrored")
        #expect(saved?.text == "committed, not mirrored")
        #expect(store.count == 1)

        // AND THIS IS THE CANCELLATION THE TOPIC NAMES. Nothing else ran; the
        // process may as well have been killed here. What the athlete gets is
        // whatever the next launch publishes.
        let next = relaunch(on: db, in: dir)
        #expect(next.note(for: session())?.text == "committed, not mirrored",
                "the edit was acknowledged, so a relaunch that loses it is 1B's defect")
    }

    // MARK: 3 — a mirror failure is recorded, not thrown

    @Test("A mirror that fails after a commit is recorded and does not throw")
    func aFailedMirrorIsRecorded() throws {
        let dir = unwritableDirectory()
        let db = try imported()
        let store = NotesStore(directory: dir, database: db)

        _ = try store.save(session: session(), rpe: 4, feel: .expected,
                           text: "mirror will fail")

        // §12.54.2. A store that quietly stopped writing its mirror looks
        // exactly like one that never had to, so the journal is where the
        // Database screen reads "Unsaved stores" from and it must have the
        // entry. Not throwing is the other half: the editor's first action is
        // *Copy the text*, and offering that over a note that is already
        // committed is advice about nothing.
        // HOISTED, like a `try` — the `#expect` macro expands its argument
        // into a nonisolated closure, and `unsaved` is main-actor isolated.
        let recorded = StoreWriteJournal.shared.unsaved["notes.json"] != nil
        #expect(recorded,
                "the gap between the rows and the file has to be sayable")
    }

    // MARK: 4 — create, edit and delete each survive a relaunch

    /// **THIS ONE DOES NOT DISCRIMINATE THE ORDER, AND SAYING SO IS THE POINT.**
    ///
    /// Run against a `NotesStore` sabotaged back to file-first, controls 1–3
    /// fail and this passes: the old order still committed, just afterwards, so
    /// inside one process the round trip is identical. It is a real assertion —
    /// it fails if the delete stops reaching the rows, or if an edit writes a
    /// second one — but it is a statement about the ROUND TRIP, not about when
    /// the commit happens. §12.69 does not let a control's coverage be assumed
    /// from its name, and control 5 is what covers the order on the delete side.
    @Test("Create, edit and delete each hold across a relaunch")
    func theRoundTripHolds() throws {
        let dir = try writableDirectory()
        let db = try imported()

        let first = NotesStore(directory: dir, database: db)
        _ = try first.save(session: session(), rpe: 6, feel: .expected,
                           text: "first")
        #expect(relaunch(on: db, in: dir).note(for: session())?.text == "first")

        let second = relaunch(on: db, in: dir)
        _ = try second.save(session: session(), rpe: 7, feel: .harder,
                            text: "second")
        let afterEdit = relaunch(on: db, in: dir)
        #expect(afterEdit.note(for: session())?.text == "second")
        #expect(afterEdit.note(for: session())?.rpe == 7)
        #expect(storedNotes(db).count == 1, "an edit is one row, never a second")

        // **THE DELETE IS THE WORST DIRECTION AND IT IS WHY `remove` IS IN
        // THIS PATCH.** Under the old order the row outlived the file, so a
        // relaunch hydrating from the database brought the deleted note back —
        // an app changing its mind about something the athlete threw away.
        let third = relaunch(on: db, in: dir)
        try third.remove(session: session())
        #expect(storedNotes(db).isEmpty)
        #expect(relaunch(on: db, in: dir).note(for: session()) == nil,
                "a deletion that undoes itself at the next launch is the worst of 1B")
    }

    // MARK: 5 — the delete order, which is the direction that resurrects

    @Test("A delete the mirror could not record is still gone from the database")
    func aDeleteOutlivesItsMirror() throws {
        let dir = try writableDirectory()
        let db = try imported()

        let store = NotesStore(directory: dir, database: db)
        _ = try store.save(session: session(), rpe: 6, feel: .expected,
                           text: "to be deleted")
        #expect(storedNotes(db).count == 1)

        // The file becomes unwritable AFTER the note exists — a directory that
        // goes away between two mutations, which is what a container being
        // rebuilt underneath a running app looks like.
        try FileManager.default.removeItem(at: dir)

        // **THE OLD ORDER THROWS HERE AND NEVER REACHES THE DATABASE.** It
        // removed from memory, failed to mirror, rolled memory back, threw —
        // and the delete of the row was the statement after the one that threw.
        // So the row survived, and the next launch hydrated the note back into
        // a list the athlete had already cleared.
        try store.remove(session: session())

        #expect(storedNotes(db).isEmpty,
                "the deletion is authoritative even when its mirror cannot land")
        #expect(store.count == 0)
    }

    // MARK: 6 — the diagnostic can say it has no answer (409a)

    @Test("A store that has written nothing says so, rather than yes")
    func nothingWrittenIsItsOwnAnswer() throws {
        let dir = try writableDirectory()
        let db = try imported()
        let store = NotesStore(directory: dir, database: db)

        // **THE CONTROL THAT WAS MISSING, AND THE CAMPAIGN FOUND IT — §12.153.9.**
        //
        // This was a `Bool` reset on every launch, so "no note has been written
        // yet" and "the last note reached the database" were the SAME VALUE and
        // printed the same sentence. `DEVICE-CAMPAIGN-409.md` reads that line
        // after a force-quit and relaunch — where nothing has been written — so
        // its row could only ever pass. §12.15: could-not-be-checked is not the
        // same as checked-and-fine.
        #expect(store.lastCommit == .noneThisLaunch)
        #expect(!AuthoredCommit.line([("notes", store.lastCommit)]).hasSuffix("yes"),
                "a launch that has written nothing must not claim it reached the database")
    }

    @Test("The diagnostic follows the write, both ways")
    func theDiagnosticFollowsTheWrite() throws {
        let dir = try writableDirectory()
        let db = try imported()

        let committing = NotesStore(directory: dir, database: db)
        _ = try committing.save(session: session(), rpe: 6, feel: .expected,
                                text: "reached")
        #expect(committing.lastCommit == .reached)

        // A seam with no database is the shut-gate state the app must survive
        // before B9 — the file takes the note and the line says the row did not.
        let fileOnly = NotesStore(directory: try writableDirectory())
        _ = try fileOnly.save(session: session(), rpe: 6, feel: .expected,
                              text: "file only")
        #expect(fileOnly.lastCommit == .missed)
        #expect(AuthoredCommit.line([("notes", fileOnly.lastCommit)]).contains("NO"))

        // AND A DELETE MOVES IT TOO. `remove` commits through the same pair, so
        // a diagnostic that only followed `save` would go stale the moment the
        // athlete cleared a note.
        try committing.remove(session: session())
        #expect(committing.lastCommit == .reached)
    }
}
