//
//  DetailHydrationTests.swift
//  Sub4CoreTests
//
//  The details and the traces can be fed from the database, and in this build
//  nothing feeds them — patch 394, D7 slice B4, ADR-0003 §12.138.
//  `ActivityHydrationTests` is the same shape one slice earlier.
//
//  WHAT A PATCH THAT CHANGES NOTHING IS FOR
//  ----------------------------------------
//  394 reads two families it does not use. Nine families are read by
//  `DatabaseBootstrapReader` and seven are named in `hydratedFamilies`, so the
//  machinery below runs end to end on every launch and hands its result to a
//  `false`. That gap is the slice: 395 adds two enum cases to one line, and
//  because it adds nothing else, any failure it produces is attributable.
//  346's four failures were, and 382's three were.
//
//  WHAT IS NOT TESTED HERE, AND WHERE IT IS INSTEAD
//  ------------------------------------------------
//  That `hydrate` marks nothing dirty is the safety of the whole slice, and no
//  assertion in this suite can see it: `dirtyDetails` is private, `save()` is
//  private, and `save()`'s only caller is behind a network drain. The seam
//  `DetailStore(directory:)` refuses every write, so a test driving it proves
//  `mayWrite` and not this. `check-invariants.py` RULE 8 reads the source of
//  all nine hydrations instead, and its negative control fires. §12.138.
//
//  THE NEGATIVE CONTROLS, AND ONE OF THEM NEVER REACHED THE SUITE
//  --------------------------------------------------------------
//  Four sabotages, run before this file was called finished (§12.69):
//
//    · `hydratableTraces` without its `holdsContent` guard  → line 159 fails
//    · `theOtherSeven` without its clamp                    → line 289 fails
//    · `hydrate` merging instead of replacing               → lines 198, 222
//    · `.details` added to `hydratedFamilies`               → **RULE 5, and
//      `test.sh` exits before xcodebuild starts.** `ActivityHydrationTests`
//      pins the count at 7, so the flip cannot be made by editing one line and
//      hoping; it has to be taken as a decision in the patch that takes it.
//      `twoFamiliesAreReadAndNotFed` below is therefore the SECOND thing that
//      would fail, not the first — which is the right order, because a pin
//      that reports before the simulator boots is worth more than one that
//      reports two minutes in.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Details and traces can be fed, and are not")
@MainActor
struct DetailHydrationTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-394-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func detail(_ id: String, splits: Int) -> ActivityDetail {
        ActivityDetail(activityId: id,
                       splits: (1...splits).map {
                           .init(index: $0, distanceM: 1000, movingTime: 300,
                                 elapsedTime: 305, elevationDiff: nil,
                                 averageHR: 140)
                       },
                       bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func streams(_ id: String, samples: Int) -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: (0..<samples).map { Double($0) * 100 },
                        heartRate: Array(repeating: 140, count: samples),
                        speed: nil, altitude: nil, grade: nil, power: nil,
                        latitude: nil, longitude: nil,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func seed(_ dir: URL,
                      details: [ActivityDetail] = [],
                      streams: [ActivityStreams] = []) throws {
        let d = dir.appendingPathComponent("details", isDirectory: true)
        let s = dir.appendingPathComponent("streams", isDirectory: true)
        try FileManager.default.createDirectory(at: d,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s,
                                                withIntermediateDirectories: true)
        for v in details {
            try JSONEncoder().encode(v)
                .write(to: d.appendingPathComponent(v.activityId + ".json"))
        }
        for v in streams {
            try JSONEncoder().encode(v)
                .write(to: s.appendingPathComponent(v.activityId + ".json"))
        }
    }

    // MARK: The gap that is the slice

    /// **NINE READ, SEVEN FED, AND THE TWO IN BETWEEN ARE THE PATCH.**
    ///
    /// Asserted as the difference rather than as two `== false` lines, because
    /// the property is not *these two are off* — it is *exactly these two are
    /// read and not fed*. A third family arriving in `Family` and in neither
    /// list would satisfy two negations and fail this.
    @Test("Two families are read and not fed, and that gap is the slice")
    func twoFamiliesAreReadAndNotFed() {
        let read = Set(PersistenceAuthority.Family.allCases)
        let fed = PersistenceAuthority.hydratedFamilies
        #expect(read.subtracting(fed) == [.details, .traces],
                "the details and the traces, and nothing else, wait for 395")
        #expect(fed.isSubset(of: read),
                "a family fed and never read would be fed from nowhere")
        #expect(read.count == DatabaseBootstrap.fieldCount,
                "every family the bootstrap reads has a case, and the reverse")
    }

    /// The decision reaches the two arguments and both are nil in this build.
    /// §12.123's shape one slice later: the machinery is complete and
    /// unreachable, so 395 is the only patch that can be blamed for what 395
    /// does.
    @Test("A full database offers neither family to the store")
    func aFullDatabaseOffersNeither() {
        // THE SAME FIXTURES `HydrationDecisionTests` USES, called rather than
        // copied — §12.43. A second `loadedPlan` here is a second thing that
        // must be kept agreeing with `PlanLoad`.
        let boot = DatabaseBootstrap(
            plan: HydrationFixtures.loadedPlan(),
            extras: HydrationFixtures.loadedExtras(),
            athlete: HydrationFixtures.loadedAthlete(),
            authored: .noneWritten,
            decisions: .noneRecorded,
            moves: .loaded(moves: [], skipped: 0),
            activities: .loaded(activities: [], skipped: 0),
            details: .loaded(details: [detail("1", splits: 3)], skipped: 0),
            traces: .loaded(recordings: [streams("1", samples: 12)], skipped: 0))

        #expect(boot.hydratableDetails?.count == 1,
                "the database holds a detail and is willing to give it")
        #expect(boot.hydratableTraces?.count == 1)

        guard case .hydrate(_, _, _, _, _, _, _, _, let d, let t)
                = HydrationPlanner.decide(mode: .databaseAuthoritative,
                                          bootstrap: boot)
        else {
            Issue.record("a whole plan and an athlete must reach `.hydrate`")
            return
        }
        #expect(d == nil, "read, offered, and refused — `hydratedFamilies` is 395")
        #expect(t == nil)
    }

    /// **AN EMPTY TABLE IS THE BACKFILL MID-FLIGHT, NOT AN EMPTY HISTORY.**
    /// 668 traces in `streams/` and none in `recording` is exactly what this
    /// device looked like for three days in August. Hydrating there would blank
    /// every heart-rate profile and every map, and take the load engine's
    /// `streamCount` to zero with them.
    @Test("An empty table is not offered, however clean the read")
    func anEmptyTableIsNotOffered() {
        let empty = DatabaseBootstrap(plan: .unavailable, extras: .unavailable,
                                      athlete: .missing, authored: .noneWritten,
                                      decisions: .noneRecorded,
                                      moves: .loaded(moves: [], skipped: 0),
                                      activities: .loaded(activities: [], skipped: 0),
                                      details: .loaded(details: [], skipped: 0),
                                      traces: .loaded(recordings: [], skipped: 0))
        #expect(empty.details.wasReadCleanly, "the read itself was fine")
        #expect(!empty.details.holdsContent, "and it found nothing")
        #expect(empty.hydratableDetails == nil,
                "an empty table hands over nothing, or the files are blanked")
        #expect(empty.hydratableTraces == nil)

        let failed = DatabaseBootstrap(plan: .unavailable, extras: .unavailable,
                                       athlete: .missing, authored: .noneWritten,
                                       decisions: .noneRecorded,
                                       moves: .loaded(moves: [], skipped: 0),
                                       activities: .loaded(activities: [], skipped: 0),
                                       details: .failed("disk I/O error"),
                                       traces: .failed("disk I/O error"))
        #expect(!failed.details.wasReadCleanly,
                "and a failure is a different nil from an empty table — §12.92")
        #expect(failed.hydratableDetails == nil)
        #expect(failed.hydratableTraces == nil)
    }

    // MARK: What the store does when it is fed

    /// **TWO PROPERTIES, NOT ONE, AND THIS IS THE TEST THAT SAYS WHY.**
    /// §12.130.1: `ActivityStore` serves rows from the database and the cursor
    /// from `UserDefaults`, and one answer per store was wrong for five of the
    /// verifier's comparisons. This store serves three things, and B8 moves the
    /// third while these two stay.
    @Test("Feeding one half does not move the other")
    func feedingOneHalfDoesNotMoveTheOther() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1", splits: 3)],
                 streams: [streams("1", samples: 12)])

        let store = DetailStore(directory: dir)
        #expect(store.detailsServedFrom == .files,
                "nothing has been handed over yet")
        #expect(store.tracesServedFrom == .files)

        store.hydrate(details: [detail("1", splits: 7),
                                detail("2", splits: 2)], streams: nil)
        #expect(store.detailsServedFrom == .database)
        #expect(store.tracesServedFrom == .files,
                "the traces were not offered, so they are still the files'")
        #expect(store.details.count == 2, "the rows replaced the files' one")
        #expect(store.detail(for: "1")?.splits.count == 7,
                "and replaced it rather than merging with it")
        #expect(store.streams.count == 1, "the trace is untouched")

        store.hydrate(details: nil, streams: [streams("1", samples: 40)])
        #expect(store.tracesServedFrom == .database)
        #expect(store.streams(for: "1")?.distanceM.count == 40)
        #expect(store.details.count == 2,
                "and feeding the second half did not disturb the first")
    }

    /// §12.121.1 on 19 MB of the athlete's data. The files stay complete and
    /// authoritative while the slice is under test — that is the whole of what
    /// makes a slice a slice, and here the seam's `mayWrite` is the enforcement
    /// while RULE 8 covers the singleton the header names.
    @Test("Hydrating leaves the files exactly as it found them")
    func hydratingLeavesTheFilesAlone() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1", splits: 3)],
                 streams: [streams("1", samples: 12)])

        let store = DetailStore(directory: dir)
        store.hydrate(details: [detail("1", splits: 7)],
                      streams: [streams("1", samples: 40)])
        #expect(store.detail(for: "1")?.splits.count == 7,
                "the store is serving the rows")

        // A SECOND READER, not the same one asked twice — the question is what
        // is on disk, and the store that was hydrated would answer from memory.
        let onDisk = DetailStore(directory: dir)
        #expect(onDisk.detail(for: "1")?.splits.count == 3,
                "the file still holds what the athlete's fetch put there")
        #expect(onDisk.streams(for: "1")?.distanceM.count == 12,
                "and so does the trace, or the rollback is a data loss")
    }

    // MARK: The paste

    /// §12.54.2 and §12.15 together. Three states and each says something: a
    /// line that vanished when nothing was hydrated would be indistinguishable
    /// from a build where hydration was never wired in, which is the whole
    /// subject.
    @Test("The hydration line is unconditional and says which half")
    func theHydrationLineIsUnconditional() {
        let neither = DetailStore.hydrationLine(details: nil, traces: nil)
        #expect(neither.contains("no — the store is serving its own files"),
                "394's launch says this, and it is not an error")

        let both = DetailStore.hydrationLine(details: 694, traces: 668)
        #expect(both.contains("694 details"))
        #expect(both.contains("668 traces"))

        // THE ASYMMETRIC STATE IS REACHABLE — 395 can be reverted one family at
        // a time, and a line that could not say so would report half a rollback
        // as none of one.
        let half = DetailStore.hydrationLine(details: 694, traces: nil)
        #expect(half.contains("694 details"))
        #expect(half.contains("no traces"))
        #expect(!half.contains("serving its own files"),
                "half fed is not the same sentence as none fed")
    }

    /// **THE NUMBER THIS PATCH EXISTS TO TAKE.** §12.136.8 is what happened the
    /// last time a figure in this area was computed instead of read, so the
    /// line is asserted to exist in every state — including the one where the
    /// read was instant, which is the state a missing line looks like.
    @Test("The bootstrap timing prints in every state and derives its remainder")
    func theBootstrapTimingIsUnconditional() {
        let unread = BootstrapTiming()
        #expect(unread.line.contains("0.000 s"),
                "a launch that measured nothing still prints — §12.54.2")

        var t = BootstrapTiming()
        t.total = 1.250
        t.details = 0.180
        t.traces = 0.900
        #expect(abs(t.theOtherSeven - 0.170) < 0.0005,
                "the seven are the subtraction, so they cannot drift from it")
        #expect(t.line.contains("1.250 s"))
        #expect(t.line.contains("0.180 s the details"))
        #expect(t.line.contains("0.900 s the traces"))

        // A CLOCK CAN PRODUCE THIS. The two inner measurements are taken inside
        // the outer one, but they are separate `measure` calls over the same
        // work — rounding, or a future reordering, can make them sum to a hair
        // more than the total, and a negative duration in the paste would read
        // as a defect in the app rather than in arithmetic.
        var odd = BootstrapTiming()
        odd.total = 0.100
        odd.details = 0.060
        odd.traces = 0.060
        #expect(odd.theOtherSeven == 0, "clamped, never negative")
    }
}
