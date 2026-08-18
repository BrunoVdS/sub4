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
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == corrupt)
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

    // MARK: The third file — plan moves, patch 404

    private func move(_ uid: String, to day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day,
                 decided: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func movesStore(_ dir: URL, holding: [PlanMove]) throws -> PlanMoveStore {
        let map = Dictionary(holding.map { ($0.sessionUid, $0) },
                             uniquingKeysWith: { a, _ in a })
        try JSONEncoder.sub4.encode(map)
            .write(to: dir.appendingPathComponent("moves.json"))
        return PlanMoveStore(directory: dir)
    }

    /// **A MOVE IS THE ATHLETE DISAGREEING WITH THE PLAN**, and `moves.json` is
    /// the only copy. It changes what Today shows, what counts as adherence and
    /// which session a match may satisfy.
    @Test("A move missing from the file is added, and reaches the disk")
    func aMissingMoveIsAdded() throws {
        let dir = try directory()
        let store = try movesStore(dir, holding: [move("wk-01-mon", to: "2026-08-04")])

        let r = try store.restore(from: .loaded(moves: [
            move("wk-01-mon", to: "2026-08-04"),
            move("wk-03-thu", to: "2026-08-20")], skipped: 0))
        #expect(r.store == "moves.json")
        #expect(r.added == 1)
        #expect(r.alreadyHeld == 1)
        #expect(PlanMoveStore(directory: dir).moves.count == 2,
                "a restore that repaired memory and not the file is gone next launch")
    }

    /// The store's copy wins, here as everywhere. A move re-decided since the
    /// import must not be reverted to the day the row remembers.
    @Test("A move re-decided since the import is not reverted")
    func aReDecidedMoveIsNotReverted() throws {
        let dir = try directory()
        let store = try movesStore(dir, holding: [move("wk-01-mon", to: "2026-08-06")])

        _ = try store.restore(from: .loaded(
            moves: [move("wk-01-mon", to: "2026-08-04")], skipped: 0))
        #expect(store.moves["wk-01-mon"]?.movedTo == "2026-08-06",
                "the database moved the session back to a day he changed his mind about")
    }

    /// An empty table is the ordinary state for this store — no gesture wrote a
    /// move until 366 — so "nothing stored" must be a clean no-op rather than
    /// anything that touches the file.
    @Test("An empty moves table touches nothing")
    func anEmptyMovesTableTouchesNothing() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("moves.json")
        try Data("{ not json".utf8).write(to: file)
        let store = PlanMoveStore(directory: dir)

        let r = try store.restore(from: .loaded(moves: [], skipped: 0))
        #expect(r.added == 0 && r.alreadyHeld == 0)
        #expect(r.setAside == nil)
        #expect(FileManager.default.fileExists(atPath: file.path),
                "an empty database must not move an unreadable file aside")
    }

    /// A failed read is not an empty one — §12.92 — and neither writes.
    @Test("A failed moves read restores nothing")
    func aFailedMovesReadRestoresNothing() throws {
        let dir = try directory()
        let store = try movesStore(dir, holding: [move("wk-01-mon", to: "2026-08-04")])
        #expect(throws: AuthoredRestoreFault.self) {
            try store.restore(from: .failed("disk I/O error"))
        }
        #expect(store.moves.count == 1)
    }


    // MARK: The fifth store, and the one that is not a file — patch 407

    /// A throwaway suite, so nothing here touches the athlete's preferences.
    private func defaults() -> UserDefaults {
        let suite = "authored-restore-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func decision(_ uid: String, activity: String?) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: activity,
                      decided: Date(timeIntervalSince1970: 1_755_000_000),
                      dateIsKnown: true)
    }

    private func matcher(_ d: UserDefaults,
                         holding: [MatchDecision]) throws -> Matcher {
        let list = holding.sorted { $0.sessionUid < $1.sessionUid }
        d.set(try JSONEncoder.sub4.encode(list), forKey: Matcher.decisionsKey)
        return Matcher(defaults: d)
    }

    /// The same additive rule as the three files, in a different medium.
    @Test("A match decision missing from the preference is added")
    func aMissingDecisionIsAdded() throws {
        let d = defaults()
        let m = try matcher(d, holding: [decision("wk-01-mon", activity: "111")])

        let r = try m.restore(from: .loaded(decisions: [
            decision("wk-01-mon", activity: "111"),
            decision("wk-02-tue", activity: "222")], skipped: 0))
        #expect(r.store == "match decisions")
        #expect(r.added == 1)
        #expect(r.alreadyHeld == 1)
        #expect(r.setAside == nil, "the blob decoded, so nothing was preserved")
        #expect(Matcher(defaults: d).decisions.count == 2,
                "a repair that did not reach the preference is gone next launch")
    }

    /// The store's judgement wins. A decision re-made since the import must not
    /// revert to the activity the row remembers.
    @Test("A decision re-made since the import is not reverted")
    func aReMadeDecisionIsNotReverted() throws {
        let d = defaults()
        let m = try matcher(d, holding: [decision("wk-01-mon", activity: "999")])

        _ = try m.restore(from: .loaded(
            decisions: [decision("wk-01-mon", activity: "111")], skipped: 0))
        #expect(m.decisions["wk-01-mon"]?.activityId == "999",
                "the database overruled a judgement the athlete had changed")
    }

    /// **THE PATH NO FILE STORE CAN REACH ON A DEVICE.** Corrupting the only
    /// copy of `notes.json` on a phone is not something a campaign may do, so
    /// that row stays uncovered there. A preference suite costs nothing.
    @Test("Undecodable bytes are copied aside before they are replaced")
    func undecodableBytesAreCopiedAside() throws {
        let d = defaults()
        let rubbish = Data("not a decisions blob".utf8)
        d.set(rubbish, forKey: Matcher.decisionsKey)

        let m = Matcher(defaults: d)
        #expect(!m.lastLoad.isTrustworthy, "the blob does not decode")

        let r = try m.restore(from: .loaded(
            decisions: [decision("wk-01-mon", activity: "111")], skipped: 0))
        let aside = try #require(r.setAside, "the unreadable bytes were not kept")
        #expect(r.added == 1)
        #expect(aside.hasPrefix(Matcher.decisionsKey + ".unreadable-"))
        #expect(d.data(forKey: aside) == rubbish,
                "the preserved copy is not the blob that could not be read")
        #expect(Matcher(defaults: d).decisions.count == 1,
                "and the restore reached the preference")
    }

    /// §12.371's finding, in this medium: a store whose blob was unreadable
    /// stays unwritable for the session unless the verdict moves with the
    /// bytes — so the one action offered for fixing it would fix nothing.
    @Test("The verdict moves with the preserved bytes")
    func theVerdictMovesWithThePreservedBytes() throws {
        let d = defaults()
        d.set(Data("not a decisions blob".utf8), forKey: Matcher.decisionsKey)
        let m = Matcher(defaults: d)

        _ = try m.restore(from: .loaded(
            decisions: [decision("wk-01-mon", activity: "111")], skipped: 0))
        #expect(m.lastLoad.isTrustworthy,
                "every later write this session would refuse")
    }

    /// Two restores in one second are two taps, and the second aside must not
    /// land on the first — `StoreRestore.asideURL`'s rule in this medium.
    @Test("A second aside in the same second does not collide")
    func asideKeysDoNotCollide() {
        let d = defaults()
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let first = Matcher.asideKey(now: now, in: d)
        d.set(Data("x".utf8), forKey: first)
        let second = Matcher.asideKey(now: now, in: d)
        #expect(first != second)
        #expect(second.contains("unreadable-"))
    }

    /// An empty table touches nothing, and a failed read is a different answer
    /// — the same two refusals the files make, in a store that cannot throw
    /// from its write.
    @Test("An empty table touches nothing and a failed read says why")
    func theTwoRefusals() throws {
        let d = defaults()
        d.set(Data("not a decisions blob".utf8), forKey: Matcher.decisionsKey)
        let m = Matcher(defaults: d)

        let r = try m.restore(from: .loaded(decisions: [], skipped: 0))
        #expect(r.added == 0 && r.alreadyHeld == 0)
        #expect(r.setAside == nil, "an empty database must not touch the bytes")
        #expect(d.data(forKey: Matcher.decisionsKey) != nil,
                "the unreadable blob is still where it was")

        #expect(throws: AuthoredRestoreFault.self) {
            try m.restore(from: .failed("disk I/O error"))
        }
    }

    // MARK: The receipt

    /// **THE DEFECT THE DEVICE PROVED — patch 402, §12.146.**
    ///
    /// Two exports of the authored read-back on 17 August, one of them after
    /// pressing Restore, were BYTE-IDENTICAL. The receipt lived in `@State`
    /// and rendered as a row, so the paste could not tell a restore that ran
    /// from a button nobody pressed. "Not run" is the answer that makes every
    /// other answer readable. §12.54.2.
    @Test("A restore that has not run says so, and a restore that has says what")
    func theRestoreLinesSayWhichCaseThisIs() {
        let none = StoreRestore.lines([], failures: [], subject: "Authored")
        #expect(none.count == 1)
        #expect(none[0] == "Authored restore: not run since this launch.",
                "silence here is indistinguishable from a control nobody wired in")

        let ran = StoreRestore.lines(
            [.nothingStored("moves.json"),
             StoreRestore.Receipt(store: "notes.json", added: 2, alreadyHeld: 3,
                                  setAside: "notes.json.unreadable-20260819-060000")],
            failures: [], subject: "Authored")
        #expect(ran.count == 3, "a heading and one line per store")
        #expect(ran[0] == "Authored restore:")
        #expect(ran[1].contains("moves.json") && ran[1].contains("added 0"))
        #expect(ran[2].contains("notes.json") && ran[2].contains("added 2"))
        #expect(ran[2].contains("unreadable bytes kept as"))

        // §12.7 — THE PASTE CARRIES NOTHING OF THE ATHLETE'S. Store names,
        // counts and an aside FILENAME. A receipt cannot carry a note's text or
        // an activity's identity because it never holds one.
        // AND IT CANNOT CARRY A PATH AT ALL SINCE 407 — the field is a NAME.
        // A test that a path does not appear was the weaker guarantee; a type
        // that cannot hold one is the stronger. §12.151.
        #expect(!ran.joined().contains("/"),
                "a container path is not something this paste may carry")
    }

    /// **A FAILURE IS NOT A RECEIPT WITH ZEROS — patch 404, §12.148.**
    ///
    /// `added: 0` means the store was looked at and needed nothing.
    /// `NOT RESTORED` means it was not looked at, or could not be written.
    /// Collapsing them would let "nothing to do" and "could not be done" print
    /// the same line, which is §12.15 in a repair tool.
    @Test("A store that could not be restored says so beside the ones that were")
    func aFailedStoreIsNamedBesideTheOthers() {
        let lines = StoreRestore.lines(
            [StoreRestore.Receipt(store: "notes.json", added: 1,
                                  alreadyHeld: 4, setAside: nil)],
            failures: [.init(store: "moves.json", why: "the read has not run yet")],
            subject: "Authored")

        #expect(lines.count == 3)
        #expect(lines[1].contains("notes.json") && lines[1].contains("added 1"))
        #expect(lines[2].contains("moves.json"))
        #expect(lines[2].contains("NOT RESTORED"),
                "a reader must not have to infer failure from an absence")
        #expect(!lines[2].contains("added"),
                "a failure carries no counts — it never got far enough to have any")

        // AND A RUN THAT ONLY FAILED IS STILL A RUN. Without this the paste
        // would say "not run since this launch" after a press that tried three
        // stores and could not write one, which is the opposite of what
        // happened.
        let onlyFailed = StoreRestore.lines(
            [], failures: [.init(store: "notes.json", why: "disk full")],
            subject: "Authored")
        #expect(onlyFailed.count == 2)
        #expect(!onlyFailed[0].contains("not run"))
    }

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
                                         setAside: "notes.json.unreadable-20260819")
        #expect(moved.line.contains("notes.json"))
        #expect(moved.line.contains("added 3"))
        #expect(moved.line.contains("unreadable bytes kept as"),
                "the reader must learn a file was moved without being told twice")
    }
}
