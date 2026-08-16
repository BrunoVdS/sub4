//
//  StoreRefusalTests.swift
//  Sub4CoreTests
//
//  Nothing overwrites a store it could not read — patch 372, ADR-0003 §12.116.
//
//  THE ONE THAT IS THE POINT
//  -------------------------
//  `anUnreadableNotesFileIsNotOverwritten`. 371 proved this shape on weather,
//  where the cost is a re-fetch. `notes.json` holds what the athlete WROTE, and
//  `StoreWrite.swift`'s own header says nothing anywhere can reproduce it. Same
//  chain, thirteen months of prose instead of six hundred temperatures: the
//  file will not decode, the store reads as empty, and the first note written
//  afterwards saves one over all of them.
//
//  AND THE ONE §12.115.6 MISSED
//  ----------------------------
//  `anUnreadableDecisionsBlobIsNotOverwritten`. There were five stores, not
//  four. `Matcher` carries the same `lastLoad` but sets it by hand rather than
//  through `StoreRead.decode`, so it did not answer the search that produced
//  that list — while holding authored decisions and taking a write on every
//  match the athlete makes.
//
//  WHY EACH REFUSAL IS SHAPED DIFFERENTLY
//  --------------------------------------
//  Three stores throw, one throws inside the write journal, and one returns
//  false and rolls memory back. That is not inconsistency; it is who can be
//  told. `aRefusedDecisionDoesNotStick` is the whole argument for the last of
//  them — there is no alert on that path, so the control not sticking IS the
//  report.
//
//  NOTHING HERE TOUCHES A SINGLETON. Every store is built through its
//  `init(directory:)` or `init(defaults:)` seam into a fresh temporary folder
//  or suite, because the singletons point at the athlete's real files.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A store that could not be read is not overwritten")
@MainActor
struct StoreRefusalTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("refusal-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// Valid JSON, substantial, and not the shape the store decodes. Whatever
    /// happened to `weather.json` on 15 August was never recorded; what matters
    /// to every store here is only that the decode threw over bytes worth
    /// keeping.
    @discardableResult
    private func corrupt(_ name: String, in dir: URL) throws -> Data {
        var object: [String: Int] = [:]
        for i in 0..<200 { object["entry-\(i)"] = i }
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent(name))
        return data
    }

    private func bytes(_ name: String, in dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func session(_ uid: String, day: String = "2026-08-17") -> Session {
        Session(uid: uid, weekUid: "w-1", day: "Monday", date: day,
                discipline: .run, intensity: nil, title: "Easy",
                detail: nil, fuel: nil, prep: nil, seq: 1,
                swimDetail: nil, strengthDetail: nil)
    }

    private func defaults(_ label: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "refusal-\(label)-\(UUID().uuidString)"))
    }

    // MARK: The four files

    /// **THE ONE THAT IS THE POINT.** Thirteen months of prose, and the write
    /// that would have replaced it with one line.
    @Test("An unreadable notes file is not overwritten")
    func anUnreadableNotesFileIsNotOverwritten() throws {
        let dir = try directory()
        let before = try corrupt("notes.json", in: dir)

        let store = NotesStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        #expect(throws: StoreWriteError.self) {
            try store.save(session: session("s1"), rpe: 5, feel: nil,
                           text: "felt strong")
        }
        #expect(try bytes("notes.json", in: dir) == before,
                "the file was overwritten after a read that failed")
        // §12.17 — memory follows disk, so the note the athlete typed is not
        // sitting in the list pretending to be saved.
        #expect(store.count == 0)
    }

    @Test("An unreadable commutes file is not overwritten")
    func anUnreadableCommutesFileIsNotOverwritten() throws {
        let dir = try directory()
        let before = try corrupt("commutes.json", in: dir)

        let store = CommuteStore(directory: dir)
        #expect(throws: StoreWriteError.self) {
            try store.set(true, for: "19608576674")
        }
        #expect(try bytes("commutes.json", in: dir) == before)
        #expect(store.decision(for: "19608576674") == nil,
                "the toggle kept an answer that never reached the disk")
    }

    @Test("An unreadable moves file is not overwritten")
    func anUnreadableMovesFileIsNotOverwritten() throws {
        let dir = try directory()
        let before = try corrupt("moves.json", in: dir)

        let store = PlanMoveStore(directory: dir)
        #expect(throws: StoreWriteError.self) {
            try store.set("2026-08-18", for: "s1")
        }
        #expect(try bytes("moves.json", in: dir) == before)
        #expect(store.all.isEmpty)
    }

    /// Through the write journal rather than a bare throw, which is what makes
    /// `remove` report it without a line of its own.
    @Test("An unreadable proposals file is not overwritten")
    func anUnreadableProposalsFileIsNotOverwritten() throws {
        let dir = try directory()
        let before = try corrupt("proposals.json", in: dir)

        let store = ProposalStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        let review = try #require(ReviewBuilder.build(weeksBack: 1),
                                  "the bundled plan should have one finished week")
        _ = store.add(review: review,
                      proposal: ReviewRehearsal.proposal(
                          naming: ReviewRehearsal.sessionUids()),
                      evidence: "refusal test",
                      model: "test-372")

        #expect(try bytes("proposals.json", in: dir) == before,
                "the review history was overwritten after a read that failed")
    }

    /// The write journal is where a refusal on this store is visible at all —
    /// `add` discards the answer, which is §12.17.2's position unchanged.
    @Test("The journal names a refusal")
    func theJournalNamesARefusal() throws {
        let journal = StoreWriteJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        let dir = try directory()
        try corrupt("proposals.json", in: dir)
        let store = ProposalStore(directory: dir)
        let review = try #require(ReviewBuilder.build(weeksBack: 1))
        _ = store.add(review: review,
                      proposal: ReviewRehearsal.proposal(
                          naming: ReviewRehearsal.sessionUids()),
                      evidence: "refusal test",
                      model: "test-372")

        let entry = try #require(journal.unsaved["proposals.json"],
                                 "a refused write left nothing in the journal")
        #expect(entry.error.stage == .refused)
    }

    // MARK: The fifth store

    /// **§12.116.1 — THE ONE THE LIST MISSED.** Authored decisions, written on
    /// every match the athlete makes.
    @Test("An unreadable decisions blob is not overwritten")
    func anUnreadableDecisionsBlobIsNotOverwritten() throws {
        let d = try defaults("blob")
        let before = Data("not a list of decisions".utf8)
        d.set(before, forKey: Matcher.decisionsKey)

        let matcher = Matcher(defaults: d)
        #expect(!matcher.lastLoad.isTrustworthy)

        matcher.setOverride(sessionUid: "s1", activityId: "692")

        let after = try #require(d.data(forKey: Matcher.decisionsKey))
        #expect(after == before,
                "the decisions blob was overwritten after a read that failed")
    }

    /// **§12.116.4 — THE ROLLBACK IS THE REPORT.** There is no alert on this
    /// path, so a tick that stuck would be the only thing the athlete saw, and
    /// it would be a lie until the next launch quietly removed it.
    @Test("A refused decision does not stick")
    func aRefusedDecisionDoesNotStick() throws {
        let d = try defaults("stick")
        d.set(Data("not a list of decisions".utf8), forKey: Matcher.decisionsKey)

        let matcher = Matcher(defaults: d)
        matcher.setOverride(sessionUid: "s1", activityId: "692")

        #expect(matcher.decisions["s1"] == nil,
                "the decision is in memory, so the tick is on screen and the blob does not have it")
    }

    /// **THE HALF THAT SHOWS LEAST, AND IT IS B2'S SCENARIO EXACTLY.**
    ///
    /// A store whose blob will not decode holds nothing — until `hydrate`
    /// fills it from the database, which is what D7 slice B2 does. Memory is
    /// then full and the blob is still unreadable, and a clear would write the
    /// hydrated set straight over it.
    ///
    /// A clear that silently did not happen is worse than a set that did not:
    /// the athlete believes a session is unmatched while the store still says
    /// otherwise, and it looks right, because the screen reads the memory.
    @Test("A refused clear comes back")
    func aRefusedClearComesBack() throws {
        let d = try defaults("clear")
        let before = Data("not a list of decisions".utf8)
        d.set(before, forKey: Matcher.decisionsKey)

        let matcher = Matcher(defaults: d)
        #expect(!matcher.lastLoad.isTrustworthy)
        matcher.hydrate(from: [MatchDecision(sessionUid: "s1",
                                             activityId: "692",
                                             decided: Date(),
                                             dateIsKnown: true)])
        #expect(matcher.decisions["s1"] != nil)

        matcher.clearOverride(sessionUid: "s1")

        #expect(matcher.decisions["s1"] != nil,
                "the session reads as unmatched while the stored blob still names the activity")
        let after = try #require(d.data(forKey: Matcher.decisionsKey))
        #expect(after == before,
                "the hydrated set was written over a blob nobody could read")
    }

    // MARK: What the refusal says

    /// §12.116.3. Retrying inside this session runs the same refusal, because
    /// the read that failed happened once, at launch.
    @Test("A refusal offers no retry")
    func aRefusalOffersNoRetry() {
        let e = StoreWriteError(store: "notes.json", stage: .refused,
                                reason: "the store was not read cleanly at launch")
        #expect(!e.stage.isWorthRetrying,
                "the alert would offer a Try again that runs the same refusal")
    }

    /// The only thing the athlete needs from that alert is that their notes are
    /// still there. A sentence that said only "not saved" would read as loss.
    @Test("A refusal says the data is safe")
    func aRefusalSaysTheDataIsSafe() throws {
        let e = StoreWriteError(store: "notes.json", stage: .refused,
                                reason: "unread")
        let text = try #require(e.errorDescription)
        #expect(text.contains("notes.json"))
        #expect(text.contains("still there"))
        #expect(!text.contains("out of space"),
                "the refusal borrowed the write failure's sentence")
    }

    // MARK: The guard that blocks everything

    /// **§12.69.** A refusal that fired on a clean read would stop the app
    /// saving anything at all, which is a worse patch than the defect.
    @Test("A clean read still saves everywhere")
    func aCleanReadStillSavesEverywhere() throws {
        let dir = try directory()

        let notes = NotesStore(directory: dir)
        #expect(notes.lastLoad == .absent)
        try notes.save(session: session("s1"), rpe: 5, feel: nil, text: "fine")
        #expect(NotesStore(directory: dir).count == 1)

        let commutes = CommuteStore(directory: dir)
        try commutes.set(true, for: "19608576674")
        #expect(CommuteStore(directory: dir).decision(for: "19608576674") == true)

        let moves = PlanMoveStore(directory: dir)
        try moves.set("2026-08-18", for: "s1")
        #expect(PlanMoveStore(directory: dir).all.count == 1)

        let matcher = Matcher(defaults: try defaults("clean"))
        matcher.setOverride(sessionUid: "s1", activityId: "692")
        #expect(matcher.decisions["s1"]?.activityId == "692")
    }
}
