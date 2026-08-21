//
//  ActivityHydrationTests.swift
//  Sub4CoreTests
//
//  The activity hydration machinery — patch 380, D7 slice B3,
//  ADR-0003 §12.124.
//
//  WHAT 380 IS, AND WHAT IT IS NOT
//  -------------------------------
//  357 built B2's machinery and 358 flipped it; 379 read the seventh family
//  and fed nothing from it. This is 379's other half: `hydratableActivities`,
//  the payload on `Instruction.hydrate`, and `ActivityStore.hydrate(from:)`.
//
//  **NOTHING HYDRATES.** `hydratedFamilies` still names six, so the planner
//  hands over nil however good the database is — and the first test in this
//  file is the most important one in it, exactly as
//  `everyFamilyHydratesNow` was in `AuthoredHydrationTests` at 357. 381 adds
//  `.activities` to that set and the entry to `HydratedStores`, and the day it
//  does, this file's one assertion inverts and nothing else here moves.
//
//  THE DECISION THIS FILE PINS, AND IT IS NOT THE AUTHORED ONE
//  ------------------------------------------------------------
//  An empty `activity` table hands over nil, the same as an empty notes table
//  — for a different reason. The three authored families withhold because the
//  athlete's writing cannot be fetched again. This one withholds because a
//  clean read of an empty table is a device between its first launch and its
//  first sync, and hydrating there would replace the whole history with
//  nothing. §12.122.1: nothing re-fetches on its own.
//
//  AND THE ONE THAT KEEPS THE SLICE REVERSIBLE
//  -------------------------------------------
//  `hydratingDoesNotWrite`, twice — over no file and over a file this app
//  cannot read. The second is the shape 378 paid for: `activities.json` is the
//  legacy side's only copy while the slice is under test, and a hydration that
//  wrote would make taking `.activities` back out of `hydratedFamilies` a data
//  loss rather than a rollback.
//
//  `isNil` RATHER THAN `== nil`, AND IT IS NOT STYLE
//  -------------------------------------------------
//  `[Activity]?` compared to nil is a call to `Optional.==` and needs
//  `Activity: Equatable`, whose synthesised conformance is MainActor-isolated
//  in this target — the fact `ActivityLoad`'s own header records at 289a and
//  the trap 322a paid a fix-up for. Pattern matching asks the optional itself
//  and needs no conformance at all, so it cannot break the day one of these
//  assertions moves into a nonisolated context.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The activity hydration machinery")
@MainActor
struct ActivityHydrationTests {

    // MARK: Fixtures

    /// The same shape `ActivityRosterTests.ride` uses, and the same dates:
    /// 2026-04-21 is after the cutoff and 2020-01-01 is not, which is what
    /// makes `dropped` provable without knowing what the cutoff is today.
    private func ride(_ id: String, at startLocal: String,
                      movingTime: Int = 3_600, distance: Double = 24_300,
                      sport: String = "Ride") -> Activity {
        Activity(id: id, name: "Ride", sportType: sport,
                 startLocal: startLocal, distance: distance,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: 130, isTrainer: false,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: startLocal + "Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    /// See the header. No `== nil` on an optional array of `Activity`.
    private func isNil(_ a: [Activity]?) -> Bool {
        if case .some = a { return false }
        return true
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-380-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// A bootstrap whose every family read cleanly, with activities in it.
    /// Hand-assembled rather than read from a database, because an in-memory
    /// database holds no activities and the payload question needs some.
    private func withActivities(_ list: [Activity]) -> DatabaseBootstrap {
        DatabaseBootstrap(
            plan: .loaded(meta: Meta(plan: "stored", week1Monday: "2026-07-27",
                                     raceDate: "2027-03-21",
                                     targetTime: "04:00:00",
                                     targetPaceSecKm: 341),
                          weeks: [], sessions: [],
                          version: PlanLoad.VersionNote(
                              sourceLabel: "test",
                              importedUTC: "2026-08-10T00:00:00Z",
                              versionsPresent: 1),
                          rows: PlanLoad.TableRows(), skipped: 0),
            extras: .loaded(fuel: nil, warmup: nil, exercises: [], skipped: 0),
            athlete: .loaded(constants: AthleteConstants(hrMaxObserved: 181,
                                                         version: 1),
                             ftp: 270,
                             zones: [.init(index: 1, min: 0, max: 115)]),
            authored: .noneWritten, decisions: .noneRecorded,
            moves: .loaded(moves: [], skipped: 0),
            activities: .loaded(activities: list, skipped: 0),
            weatherGear: .loaded(weather: [], gear: [], skipped: 0))
    }

    // MARK: THE ONE THAT IS THE PATCH

    /// **THE GAP SURVIVES 380.** The machinery exists and the family is not
    /// fed: `hydratedFamilies` still names six, so the planner refuses the
    /// payload however much the database holds.
    ///
    /// This is `AuthoredHydrationTests.everyFamilyHydratesNow`'s place in the
    /// B2 pair, and it inverts at 381 for the same reason that one did at 358.
    /// **INVERTED AT 382 — the machinery 380 built now carries a payload.**
    /// The test 380 wrote to prove nothing was fed is the test that proves
    /// something is, and the diff that changes it holds the line that did it.
    @Test("The planner carries the activities, and that is the flip")
    func thePlannerCarriesTheActivities() {
        let b = withActivities([ride("a", at: "2026-04-21T09:00:00")])

        #expect(!isNil(b.hydratableActivities),
                "the bootstrap has something to hand over")
        #expect(PersistenceAuthority.hydrates(.activities),
                "and this build wants it — 382 is that line")

        switch HydrationPlanner.decide(mode: .shadow("B3 — a test"),
                                       bootstrap: b) {
        case .hydrate(_, _, _, _, _, _, _, let storedActivities, _, _):
            #expect(!isNil(storedActivities),
                    "the payload travels once the family is fed")
            #expect(storedActivities?.count == 1)
        case .leaveOnFiles:
            Issue.record("every family loaded, so the plan must still hydrate")
        }
    }

    /// **AND THE OTHER HALF OF THE RULE IS UNCHANGED BY THE FLIP.** An empty
    /// table still hands over nil, so a device between its first launch and
    /// its first sync keeps its file rather than showing an empty history.
    /// §12.124.3, and 382 is exactly when it starts to matter.
    @Test("An empty table still hands over nil after the flip")
    func anEmptyTableStillHandsOverNil() {
        let b = withActivities([])
        #expect(isNil(b.hydratableActivities))

        switch HydrationPlanner.decide(mode: .shadow("B3 — a test"),
                                       bootstrap: b) {
        case .hydrate(_, _, _, _, _, _, _, let storedActivities, _, _):
            #expect(isNil(storedActivities),
                    "the build wants the family and the table holds nothing")
        case .leaveOnFiles:
            Issue.record("the plan is loaded, so this must still hydrate")
        }
    }

    /// The counts 379 separated are untouched by this patch. RULE 5 in
    /// `check-invariants.py` derives all four from the source, so a pin that
    /// drifts is a failed run rather than a discovery four rounds later.
    /// **382 MOVES BOTH, AND THAT IS THE FLIP.** 380's version of this test
    /// asserted the counts had not moved; keeping it as an inversion rather
    /// than deleting it is what makes the change visible in a diff.
    @Test("382 moves both counts")
    func theCountsMoved() {
        // **430 — THE GAP CLOSES FOR THE FOURTH TIME.** 428 declared
        // `.weather` and `.gear` and fed neither; 429 built the hydration and
        // still fed neither; this is the line that feeds them. Eleven read,
        // eleven fed. The next number to move here is B6's.
        #expect(DatabaseBootstrap.fieldCount == 8,
                "the bootstrap gained ONE field for the two families — one read")
        #expect(PersistenceAuthority.Family.allCases.count == 11)
        // 398 — AND NOW EVERY FAMILY IS FED. The gap 394 opened and 395 kept
        // open closed at the flip: nine declared, nine hydrated. The next
        // number to move here is B5's, and it moves `allCases` first.
        #expect(PersistenceAuthority.hydratedFamilies.count == 11)
        // 387 — THE LIST'S COUNT WENT WITH THE LIST. `HydratedStores.all.count
        // == 9` was a hand-kept total that stood at 8 while nine comparisons
        // read a hydrated store; what is left is the fact this test is about,
        // which is that the activities are B3's.
        #expect(ExpectationField.activities.slice == "B3",
                "so the verifier's activity comparisons are no longer evidence")
    }

    // MARK: What the bootstrap will hand over

    /// **NIL WHEN EMPTY, FOR A REASON THAT IS NOT THE AUTHORED ONE.** A device
    /// between its first launch and its first sync reads the table cleanly and
    /// finds nothing; hydrating there would replace the store's whole history
    /// with an empty list, and nothing re-fetches on its own. §12.122.1.
    @Test("An empty activity table hands over nil")
    func anEmptyTableHandsOverNil() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(b.activities.wasReadCleanly, "empty is not a fault")
        #expect(!b.activities.holdsContent)
        #expect(isNil(b.hydratableActivities),
                "an empty read must not be able to empty the store")
        #expect(b.firstFault == nil, "and emptiness is still not a fault")
    }

    @Test("A read that did not succeed hands over nothing either")
    func aFailedReadHandsOverNothing() {
        for bad: ActivityLoad in [.unavailable, .failed("no such table: activity")] {
            let b = DatabaseBootstrap(
                plan: .noActiveVersion(versionsPresent: 0),
                extras: .noActiveVersion(versionsPresent: 0),
                athlete: .missing, authored: .noneWritten,
                decisions: .noneRecorded,
                moves: .loaded(moves: [], skipped: 0),
                activities: bad,
            weatherGear: .loaded(weather: [], gear: [], skipped: 0))
            #expect(isNil(b.hydratableActivities),
                    "nil rather than [] — a failed read is not an empty one")
        }
    }

    @Test("Rows that read cleanly are handed over whole")
    func rowsAreHandedOverWhole() throws {
        let b = withActivities([ride("a", at: "2026-04-21T09:00:00"),
                                ride("b", at: "2026-04-22T09:00:00")])
        let handed = try #require(b.hydratableActivities,
                                  "two rows is content")
        #expect(handed.count == 2)
    }

    // MARK: The store

    /// **THE ONE THAT IS THE SLICE.** It replaces, and it says where from.
    @Test("The store takes the stored activities")
    func theStoreTakesTheStoredActivities() throws {
        let store = ActivityStore(directory: try directory())
        #expect(store.count == 0)
        #expect(store.servedFrom == .files)

        store.hydrate(from: [ride("a", at: "2026-04-21T09:00:00"),
                             ride("b", at: "2026-04-22T09:00:00")])

        #expect(store.count == 2)
        #expect(store.servedFrom == .database)
        #expect(store.activities(on: "2026-04-22").count == 1,
                "the day index is rebuilt by the didSet, not by a caller")
    }

    /// **§12.43, THE THIRD DOOR.** `load` settles and `ingest` settles, and
    /// `ActivityParity` has settled the database side since 312. A hydration
    /// that trusted the rows to arrive pre-settled would be a fourth opinion
    /// about what the activity list is.
    ///
    /// The counts are what make it provable: 4 offered, 1 dropped by the
    /// cutoff, 1 collapsed as a duplicate, 2 kept — and newest first by LOCAL
    /// start, which `ActivityRepository.all` does not produce (§4.1: it orders
    /// by `startUTC`).
    @Test("Hydration settles the rows through the same rules as both doors")
    func hydrationSettlesTheRows() throws {
        let store = ActivityStore(directory: try directory())
        let a = ride("a", at: "2026-04-21T09:00:00",
                     movingTime: 7_500, distance: 61_700)
        let dup = ride("b", at: "2026-04-21T09:05:00",
                       movingTime: 7_200, distance: 60_400)
        let later = ride("c", at: "2026-04-22T09:00:00")
        let old = ride("old", at: "2020-01-01T09:00:00")

        store.hydrate(from: [a, dup, later, old])

        let r = try #require(store.hydrationRoster,
                             "a hydration that counted nothing cannot be read")
        #expect(r.offered == 4, "the denominator, without which zero says nothing")
        #expect(r.dropped == 1, "before the cutoff")
        #expect(r.collapsed == 1, "the pair, longer recording kept")
        #expect(store.activities.map(\.id) == ["c", "a"],
                "newest first by local start, as both other doors produce")
    }

    /// §12.121.1 on the largest store here. The file stays complete and
    /// authoritative while the slice is under test — that is the whole of what
    /// makes a slice a slice.
    @Test("Hydrating writes no file")
    func hydratingDoesNotWrite() throws {
        let dir = try directory()
        let store = ActivityStore(directory: dir)

        store.hydrate(from: [ride("a", at: "2026-04-21T09:00:00")])

        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("activities.json").path),
            "hydration wrote a file, so the slice is no longer reversible")
    }

    /// **THE 378 SHAPE, FROM THE OTHER SIDE.** A file this app cannot read is
    /// exactly when a write would be unrecoverable, and a hydration is a write
    /// that would look justified. The bytes must be identical afterwards.
    @Test("Hydrating over an unreadable file leaves the file alone")
    func hydratingLeavesAnUnreadableFileAlone() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("activities.json")
        let before = Data("{ no }".utf8)
        try before.write(to: file)

        let store = ActivityStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy, "the file does not decode")

        store.hydrate(from: [ride("a", at: "2026-04-21T09:00:00")])

        // HOISTED, NEVER INSIDE `#expect` — the macro re-evaluates its
        // expression to build the failure message, and `try` in there is a
        // compile error this project has paid for more than once.
        let after = try Data(contentsOf: file)
        #expect(store.count == 1, "the store serves the rows")
        #expect(after == before,
                "and the only copy of whatever that file held is untouched")
    }

    // MARK: The paste

    /// §12.54.2 and §12.123.7 together. Unconditional, and both states say
    /// something: without this line the roster above describes
    /// `activities.json` while the store holds rows, and nothing on the screen
    /// says which.
    @Test("The hydration line is unconditional and names its subject")
    func theHydrationLineIsUnconditional() {
        let none = ActivityStore.hydrationLine(nil)
        #expect(none.hasPrefix("Activities hydrated: no"))

        let r = ActivityRoster.settle([ride("a", at: "2026-04-21T09:00:00"),
                                       ride("b", at: "2026-04-22T09:00:00")])
        let some = ActivityStore.hydrationLine(r)
        #expect(some.contains("2 kept of 2 offered"))
        #expect(some.contains("activities.json"),
                "the line has to say what the roster above it describes")
    }

    @Test("The store's own paste block carries it in both states")
    func theStoreBlockCarriesIt() throws {
        let dir = try directory()
        let store = ActivityStore(directory: dir)

        let before = store.loadDiagnosticLines
        #expect(before.contains(where: { $0.hasPrefix("Activities hydrated: no") }))
        #expect(before.contains(where: { $0.hasPrefix("Activities arriving late:") }),
                "376's line is unconditional and 380 must not have moved it")

        store.hydrate(from: [ride("a", at: "2026-04-21T09:00:00")])
        let after = store.loadDiagnosticLines
        #expect(after.contains(where: { $0.contains("1 kept of 1 offered") }))
        #expect(after.count == before.count,
                "the same lines, saying different things — not one appearing")
    }

    /// The roster the LOAD produced is not overwritten by a hydration. They
    /// describe different things and the paste prints both — §12.15.
    @Test("The load roster still describes the file after a hydration")
    func theLoadRosterStillDescribesTheFile() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("activities.json")
        let enc = JSONEncoder()
        try enc.encode([ride("f", at: "2026-04-20T09:00:00")]).write(to: file)

        let store = ActivityStore(directory: dir)
        #expect(store.loadRoster?.offered == 1, "one activity came out of the file")

        store.hydrate(from: [ride("a", at: "2026-04-21T09:00:00"),
                             ride("b", at: "2026-04-22T09:00:00")])

        #expect(store.loadRoster?.offered == 1,
                "the file's roster is a fact about the file and does not move")
        #expect(store.hydrationRoster?.offered == 2)
        #expect(store.count == 2)
    }
}
