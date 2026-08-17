//
//  AuthoredHydrationTests.swift
//  Sub4CoreTests
//
//  The authored hydration machinery — patch 357, D7 slice B2, ADR-0003 §12.102.
//
//  WHAT 357 IS. 344 built B1's bootstrap and planner; 346 flipped it and found
//  four failures that were attributable BECAUSE the two were separate patches.
//  This is 344's half for B2. Nothing hydrates yet — `hydratedFamilies` still
//  names the three B1 moved — and the most important test in this file is the
//  one asserting exactly that.
//
//  THE DECISION THIS FILE PINS. An authored family that reads cleanly and holds
//  nothing is NOT hydrated. Zero notes is a legitimate permanent state, so
//  emptiness cannot be a fault — but a database holding no notes while
//  `notes.json` holds one can also mean the write-through has not caught up,
//  and hydrating there would blank the only copy. §12.8.1 is what that costs.
//
//  WHY THE BOOTSTRAP IS BUILT FROM A REAL DATABASE. Hand-assembling five loads
//  means inventing values for three families this patch does not touch, and a
//  fixture that drifts from `PlanLoad`'s real shape would fail for reasons that
//  have nothing to do with B2. A migrated empty database produces all five
//  cleanly and is the exact state a fresh install is in.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The authored hydration machinery")
@MainActor
struct AuthoredHydrationTests {

    // MARK: Fixtures

    private func note(_ uid: String) -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: 5, feel: nil, text: "ok",
                        created: Date(timeIntervalSince1970: 1_000),
                        edited: Date(timeIntervalSince1970: 1_000))
    }

    private func commute(_ id: String) -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: true,
                        decided: Date(timeIntervalSince1970: 1_000))
    }

    private func decision(_ uid: String) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: nil,
                      decided: Date(timeIntervalSince1970: 1_000),
                      dateIsKnown: true)
    }

    // MARK: 357 hydrates nothing

    /// **THIS TEST KEPT 357 FROM BEING 358 AND 358 IS WHERE IT INVERTS.**
    ///
    /// It is not deleted, because the property it defends did not go away — it
    /// changed value. `B2ActivationTests` owns the flip; this one stays here so
    /// that the file which built the machinery also says, in one place, what
    /// the machinery ended up doing.
    ///
    /// **THE PREDICTION IN THIS DOC WAS WRONG, AND 377 IS HOW — §12.121.8.**
    /// It said a later slice adding a sixth family would separate these two
    /// counts again. The sixth family arrived at 377 and they never separated:
    /// the moves' machinery had been built at 361 and 365, so the family and
    /// its flip landed in one patch. What separates the counts is a family
    /// READ before it is FED, and 377 was not that shape. B3 will be.
    ///
    /// **B3 IS, AND 379 IS THE PATCH — §12.123.** Seven families read, six
    /// fed. The doc above was right about the shape and wrong about which
    /// patch, which is the more useful half to have been right about.
    /// **REWRITTEN AT 382 TO ASSERT WHAT THIS FILE OWNS.** It pinned the whole
    /// set, so B3's flip broke a suite about B2 — the drift 377d paid four
    /// rounds for, one file over. The four families this patch built the
    /// machinery for are what it asserts now; the set as a whole belongs to
    /// `ActivitiesAreReadTests`, which is where the flip lives.
    @Test("This build hydrates every family B1 and B2 cover")
    func everyFamilyHydratesNow() {
        for f: PersistenceAuthority.Family in [.plan, .extras, .athlete,
                                               .authored, .decisions, .moves] {
            #expect(PersistenceAuthority.hydrates(f),
                    "a family B1 or B2 covers and this build does not feed")
        }
        #expect(PersistenceAuthority.Family.allCases.count == 9,
                "and the seventh is B3's, fed at 382")
    }

    // MARK: The two verdicts — §12.92

    @Test("A clean read of nothing is not a failed read")
    func cleanAndEmptyIsNotAFailure() {
        let empty = AuthoredLoad.loaded(notes: [], commutes: [], skipped: 0)
        #expect(empty.wasReadCleanly)
        #expect(!empty.holdsContent)

        let some = AuthoredLoad.loaded(notes: [note("a")], commutes: [], skipped: 0)
        #expect(some.wasReadCleanly)
        #expect(some.holdsContent, "one note is content")

        let commutesOnly = AuthoredLoad.loaded(notes: [], commutes: [commute("1")],
                                               skipped: 0)
        #expect(commutesOnly.holdsContent, "so is one commute decision")

        for bad: AuthoredLoad in [.unavailable, .failed("the queue was closed")] {
            #expect(!bad.wasReadCleanly)
            #expect(!bad.holdsContent, "a read that failed holds nothing to know")
        }
    }

    @Test("The same two questions of the match decisions")
    func theDecisionsAnswerBoth() {
        let empty = MatchDecisionLoad.loaded(decisions: [], skipped: 0)
        #expect(empty.wasReadCleanly)
        #expect(!empty.holdsContent, "and this is this device's real state")

        let some = MatchDecisionLoad.loaded(decisions: [decision("a")], skipped: 0)
        #expect(some.wasReadCleanly)
        #expect(some.holdsContent)

        #expect(!MatchDecisionLoad.failed("nope").wasReadCleanly)
        #expect(!MatchDecisionLoad.failed("nope").holdsContent)
    }

    // MARK: The bootstrap, over a real empty database

    @Test("Seven families, read cleanly, holding nothing")
    func theBootstrapReadsSevenFamilies() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(DatabaseBootstrap.fieldCount == 7)
        #expect(b.wasReadCleanly, "a migrated empty database reads cleanly")
        #expect(b.firstFault == nil)
        #expect(!b.canHydrate, "and holds no plan, which is a fresh install")
        #expect(b.emptyAuthoredFamilies == ["notes and commutes",
                                            "match decisions",
                                            "plan moves"])
    }

    /// The pin exists so a family added without a line is a test failure rather
    /// than a gap in the paste. 357 adds two families and one verdict line.
    @Test("Every family has a line and the count is pinned to it")
    func thePasteMatchesThePin() throws {
        let db = try Sub4Database.inMemory()
        let lines = DatabaseBootstrapReader.read(db).diagnosticLines

        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)
        #expect(DatabaseBootstrap.diagnosticLineCount
                == DatabaseBootstrap.fieldCount + 6)
        #expect(lines.contains(where: { $0.hasPrefix("  notes and commutes:") }))
        #expect(lines.contains(where: { $0.hasPrefix("  match decisions:") }))
        #expect(lines.contains(where: {
            $0.contains("authored families keeping their files:")
        }))
        // PREFIX, NOT EQUALITY — patch 358 put "read at launch" and what it
        // is NOT to be compared against into this line. What this test pins is
        // that the family count is the first thing said, which is what it
        // always meant.
        #expect(lines.first?.hasPrefix("Database bootstrap: 7 families") == true)
    }

    // MARK: An empty family is not hydratable

    /// **THE DECISION OF 14 AUGUST.** Nil, not an empty payload — the
    /// difference between leaving a note alone and blanking it.
    @Test("A family that read cleanly and holds nothing hands over nil")
    func anEmptyFamilyIsNotHydratable() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(b.authored.wasReadCleanly)
        #expect(b.hydratableAuthored == nil,
                "an empty read must not be able to blank notes.json")
        #expect(b.decisions.wasReadCleanly)
        #expect(b.hydratableDecisions == nil)
    }

    /// And the other half: emptiness must not be reported as a fault, or a
    /// device where the athlete has written nothing would look broken for ever.
    @Test("Emptiness is reported separately from a fault")
    func emptinessIsNotAFault() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(b.firstFault == nil, "nothing failed")
        #expect(!b.emptyAuthoredFamilies.isEmpty, "and two families are empty")
        #expect(b.diagnosticLines.contains(where: {
            $0.contains("first fault: none")
        }))
        #expect(b.diagnosticLines.contains(where: {
            $0.contains("keeping their files: notes and commutes, match decisions")
        }))
    }

    // MARK: The planner

    /// The planner must hand over nil for both authored families — once because
    /// the build does not hydrate them, and once because they are empty. Both
    /// reasons are live today and either alone would produce this.
    @Test("The planner carries no authored payload in this build")
    func thePlannerCarriesNothingAuthored() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        switch HydrationPlanner.decide(mode: .shadow("B1 — a test"), bootstrap: b) {
        case .leaveOnFiles(let outcome):
            // An empty database has no plan, so this is the expected branch —
            // and it is `nothingStored`, not `fault`, which is the distinction
            // the whole stage rests on.
            #expect(!outcome.isFault)
            #expect(outcome.line.contains("nothing stored"))
        case .hydrate:
            Issue.record("an empty database hydrated something")
        }
    }

    @Test("A mode that does not want hydration says so before anything else")
    func aModeThatDoesNotWantItSaysSo() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        switch HydrationPlanner.decide(mode: .legacyAuthoritative, bootstrap: b) {
        case .leaveOnFiles(let outcome):
            #expect(!outcome.isFault)
            #expect(outcome.line.contains("not this launch"))
        case .hydrate:
            Issue.record("a legacy-authoritative launch hydrated")
        }
    }

    // MARK: The stores

    /// Hydration replaces, says where it read from, and DOES NOT WRITE. The
    /// last is the rule the whole stage rests on: under a slice under test the
    /// file is the legacy side's only copy.
    @Test("Hydrating the notes store replaces and does not touch the file")
    func hydratingNotesDoesNotWrite() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-357-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = NotesStore(directory: dir)
        #expect(store.servedFrom == .files)
        #expect(store.all.isEmpty)

        store.hydrate(from: [note("wk-01-tue-easy"), note("wk-02-fri-easy")])
        #expect(store.all.count == 2)
        #expect(store.servedFrom == .database)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("notes.json").path),
            "hydration wrote notes.json, destroying the independent side")
    }

    @Test("Hydrating the commute store replaces and does not touch the file")
    func hydratingCommutesDoesNotWrite() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-357-commutes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CommuteStore(directory: dir)
        #expect(store.servedFrom == .files)

        store.hydrate(from: [commute("1"), commute("2")])
        #expect(store.decisions.count == 2)
        #expect(store.servedFrom == .database)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("commutes.json").path))
    }

    /// The matcher's copy lives in `UserDefaults`, so the equivalent check is
    /// that hydration leaves the suite's stored blob alone.
    @Test("Hydrating the matcher replaces and does not touch the blob")
    func hydratingTheMatcherDoesNotWrite() throws {
        let name = "sub4-357-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let m = Matcher(defaults: defaults)
        #expect(m.servedFrom == .files)

        m.hydrate(from: [decision("wk-01-tue-easy")])
        #expect(m.decisions.count == 1)
        #expect(m.servedFrom == .database)
        #expect(defaults.data(forKey: Matcher.decisionsKey) == nil,
                "hydration wrote the blob the legacy side still owns")
    }
}
