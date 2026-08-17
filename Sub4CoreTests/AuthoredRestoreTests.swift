//
//  AuthoredRestoreTests.swift
//  Sub4CoreTests
//
//  Putting the athlete's own writing back, from the database — patch 400,
//  ADR-0003 §12.144. `WeatherRestoreTests` is the same suite for the store
//  that got its restore at 374, and the contract is now shared.
//
//  WHY THIS MATTERS MORE THAN THE WEATHER ONE
//  ------------------------------------------
//  Weather is fetched: lose it and the app asks Open-Meteo again. **These
//  records cannot be fetched from anywhere.** A note is the athlete's sentence
//  about how a session felt, a match decision is a judgement he made about
//  which activity was the session, a commute decision says a ride was not
//  training. ADR-0002 promises this category survives the Strava retirement
//  and everything after it, and §5.5 has carried "five authored stores have no
//  restore path — largest open risk" while eleven patches went to B4.
//
//  NOTHING HERE TOUCHES A SINGLETON. Every store is built through
//  `init(directory:)` into a fresh temporary folder; `NotesStore.shared` points
//  at the athlete's real `notes.json`.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Restoring the authored stores from the database")
@MainActor
struct AuthoredRestoreTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("authored-restore-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func note(_ uid: String, text: String = "felt fine",
                      rpe: Int? = 5) -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: rpe, feel: .expected, text: text,
                        created: Date(timeIntervalSince1970: 1_755_000_000),
                        edited: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func commute(_ id: String, isCommute: Bool = true) -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: isCommute,
                        decided: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func load(notes: [NotesStore.Note] = [],
                      commutes: [CommuteDecision] = []) -> AuthoredLoad {
        .loaded(notes: notes, commutes: commutes, skipped: 0)
    }

    /// A store whose file exists and read cleanly, holding what is passed.
    private func notesStore(_ dir: URL, holding: [NotesStore.Note]) throws
    -> NotesStore {
        let file = dir.appendingPathComponent("notes.json")
        let map = Dictionary(holding.map { ($0.sessionUid, $0) },
                             uniquingKeysWith: { a, _ in a })
        // THE STORE'S OWN ENCODER — `save()` calls `StoreWrite.encode` with
        // no encoder argument, which is `JSONEncoder.sub4`. A fixture written
        // with a bare `JSONEncoder` is a file this store cannot read, which is
        // a different test. §12.122.4, and the first draft of this file made
        // exactly that mistake: every seeded store came up empty and
        // untrustworthy, and the restores all passed for the wrong reason.
        try JSONEncoder.sub4.encode(map).write(to: file)
        return NotesStore(directory: dir)
    }

    // MARK: What a restore puts back

    /// **THE ONE THE PATCH EXISTS FOR.** A note the file lost and the database
    /// still holds comes back.
    @Test("A note missing from the file is added")
    func aMissingNoteIsAdded() throws {
        let dir = try directory()
        let store = try notesStore(dir, holding: [note("wk-01-mon")])
        #expect(store.notes.count == 1)

        let r = try store.restore(from: load(notes: [note("wk-01-mon"),
                                                     note("wk-02-tue")]))
        #expect(r.added == 1)
        #expect(r.alreadyHeld == 1)
        #expect(r.setAside == nil, "the file read cleanly, so nothing was moved")
        #expect(store.notes.count == 2)
        #expect(store.notes["wk-02-tue"] != nil)

        // AND IT REACHED THE DISK. A restore that repaired memory and not the
        // file would look identical on screen and be gone next launch. §12.17.
        let again = NotesStore(directory: dir)
        #expect(again.notes.count == 2)
    }

    /// **THE DIRECTION THAT IS THE WHOLE SAFETY OF A RESTORE.** The store's copy
    /// wins. A note edited since the import that wrote the row would otherwise
    /// be silently reverted — a data loss wearing the name of a repair.
    @Test("A note the store already holds is not overwritten")
    func theStoresCopyWins() throws {
        let dir = try directory()
        let store = try notesStore(dir, holding: [note("wk-01-mon",
                                                      text: "edited since")])

        let r = try store.restore(from: load(notes: [note("wk-01-mon",
                                                          text: "the old row")]))
        #expect(r.added == 0)
        #expect(r.alreadyHeld == 1)
        #expect(store.notes["wk-01-mon"]?.text == "edited since",
                "the database reverted the athlete's most recent writing")
    }

    /// A note written since the last import exists in the file and NOT in the
    /// database. Replacing wholesale would delete exactly those — the defect
    /// the restore repairs, with an extra step.
    @Test("A note written since the import survives")
    func aNoteWrittenSinceTheImportSurvives() throws {
        let dir = try directory()
        let store = try notesStore(dir, holding: [note("wk-01-mon"),
                                                  note("wk-09-brand-new")])

        _ = try store.restore(from: load(notes: [note("wk-01-mon")]))
        #expect(store.notes["wk-09-brand-new"] != nil,
                "a wholesale replace would have deleted it")
        #expect(store.notes.count == 2)
    }

    /// Idempotent. Two taps are two restores, and the second must be a no-op
    /// that still says so.
    @Test("Restoring twice adds nothing the second time")
    func restoringTwiceIsANoOp() throws {
        let dir = try directory()
        let store = try notesStore(dir, holding: [])
        let stored = load(notes: [note("wk-01-mon"), note("wk-02-tue")])

        #expect(try store.restore(from: stored).added == 2)
        let second = try store.restore(from: stored)
        #expect(second.added == 0)
        #expect(second.alreadyHeld == 2, "and it says it looked at both")
    }

    // MARK: The unreadable file — the state the restore exists for

    /// **THE GUARD IS SATISFIED, NOT BYPASSED.** `save()` refuses when the file
    /// did not read cleanly, which is §12.116's protection and must stay. So
    /// the bytes are MOVED somewhere they survive and the ordinary write runs
    /// on the ordinary path.
    @Test("An unreadable file is moved aside, not overwritten")
    func anUnreadableFileIsMovedAside() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("notes.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: file)

        let store = NotesStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy, "the file does not decode")

        let r = try store.restore(from: load(notes: [note("wk-01-mon")]))
        let aside = try #require(r.setAside, "the unreadable bytes were not preserved")
        #expect(r.added == 1)

        // THE ORIGINAL BYTES SURVIVE, UNCHANGED. They are the only copy of
        // whatever that file held, and somebody may be able to read them.
        #expect(try Data(contentsOf: aside) == corrupt)
        // AND THE RESTORE REACHED THE DISK, which it could not have done if the
        // guard had merely been skipped.
        #expect(NotesStore(directory: dir).notes.count == 1)
    }

    /// A store whose file was unreadable stays unwritable for the whole session
    /// unless the verdict moves with the bytes — so the one action offered for
    /// fixing it would fix nothing until the next launch. §12.371's finding,
    /// and the half `StoreRestore` cannot do for the caller.
    @Test("The verdict moves with the bytes")
    func theVerdictMovesWithTheBytes() throws {
        let dir = try directory()
        try Data("{ not json".utf8)
            .write(to: dir.appendingPathComponent("notes.json"))
        let store = NotesStore(directory: dir)

        _ = try store.restore(from: load(notes: [note("wk-01-mon")]))
        #expect(store.lastLoad.isTrustworthy,
                "save() would refuse every later write in this session")
    }

    // MARK: Refusals — and each says something different

    /// §12.15. "The database could not be read" and "the database is open and
    /// empty" send a reader to opposite places, so they are not one answer.
    @Test("A failed read restores nothing and says why")
    func aFailedReadRestoresNothing() throws {
        let dir = try directory()
        let store = try notesStore(dir, holding: [note("wk-01-mon")])

        #expect(throws: AuthoredRestoreFault.self) {
            try store.restore(from: .failed("database disk image is malformed"))
        }
        #expect(store.notes.count == 1, "and memory is as it was")
    }

    /// An empty database touches NOTHING — it may not move a readable file
    /// aside and may not write. The counts still tell it apart from a repair,
    /// because `added: 0, alreadyHeld: 0` is only reachable from here.
    @Test("An empty database touches nothing")
    func anEmptyDatabaseTouchesNothing() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("notes.json")
        try Data("{ not json".utf8).write(to: file)
        let store = NotesStore(directory: dir)

        let r = try store.restore(from: load())
        #expect(r.added == 0)
        #expect(r.alreadyHeld == 0)
        #expect(r.setAside == nil, "an empty database must not move a file")
        #expect(FileManager.default.fileExists(atPath: file.path),
                "the unreadable file is still where it was")
    }

    // MARK: The commute store takes the same route

    /// The second store on the shared contract. Keyed by `activityId` rather
    /// than a session uid, which is exactly why `StoreRestore.merge` keys on
    /// `id` — the record's identity, not a closure a call site chooses.
    @Test("Commute decisions restore by activity, additively")
    func commutesRestoreByActivity() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("commutes.json")
        try JSONEncoder.sub4.encode(["a": commute("a", isCommute: false)])
            .write(to: file)
        let store = CommuteStore(directory: dir)
        #expect(store.decisions.count == 1)

        let r = try store.restore(from: load(commutes: [commute("a"),
                                                        commute("b")]))
        #expect(r.store == "commutes.json")
        #expect(r.added == 1)
        #expect(r.alreadyHeld == 1)
        #expect(store.decisions["a"]?.isCommute == false,
                "the store's own judgement survived the restore")
        #expect(store.decisions["b"]?.isCommute == true)
    }

    /// One load feeds two stores and each takes only its own half. A restore
    /// that took the other store's records would key them into the wrong
    /// dictionary — and both sides would be internally consistent, which is
    /// why this is asserted rather than assumed.
    @Test("Each store takes only its own half of the load")
    func eachStoreTakesItsOwnHalf() throws {
        let dir = try directory()
        let notes = NotesStore(directory: dir)
        let commutes = CommuteStore(directory: dir)
        let both = load(notes: [note("wk-01-mon")], commutes: [commute("a")])

        #expect(try notes.restore(from: both).added == 1)
        #expect(notes.notes.count == 1)
        #expect(try commutes.restore(from: both).added == 1)
        #expect(commutes.decisions.count == 1)
    }

    // MARK: The receipt

    /// §12.54.2 and §12.15. One control restores several stores, so a count
    /// without its store name is a number nobody can act on.
    @Test("The receipt names its store in every state")
    func theReceiptNamesItsStore() {
        let none = StoreRestore.Receipt.nothingStored("moves.json")
        #expect(none.line.hasPrefix("moves.json:"))
        #expect(none.line.contains("added 0, already held 0"))
        #expect(!none.line.contains("set aside"))

        let moved = StoreRestore.Receipt(store: "notes.json", added: 3,
                                         alreadyHeld: 1,
                                         setAside: URL(fileURLWithPath: "/tmp/x"))
        #expect(moved.line.contains("notes.json"))
        #expect(moved.line.contains("added 3"))
        #expect(moved.line.contains("unreadable file set aside"),
                "the reader must learn a file was moved without being told twice")
    }
}
