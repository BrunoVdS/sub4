//
//  TraceCoverageIDTests.swift
//  Sub4CoreTests
//
//  The ids behind the buckets — patch 420, ADR-0003 §12.165, plan topic 3.
//
//  Topic 3 asks a tester to "select an ID classified as answered-empty, then
//  open Activities → activity detail". The screen said `asked, nothing there:
//  2` and named neither, so the step could not be performed — which is the
//  unperformable instruction 417's campaign shipped with and §12.162.5
//  recorded. A campaign step nobody can carry out is worse than a missing one.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The trace buckets name what is in them")
struct TraceCoverageIDTests {

    private func ride(_ id: String, km: Double = 20) -> Activity {
        Activity(id: id, name: "Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: km * 1000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func classify(_ activities: [Activity],
                          hasTrace: Set<String> = [],
                          refused: Set<String> = [],
                          answeredEmpty: Set<String> = [],
                          queued: Set<String> = []) -> TraceCoverage {
        TraceCoverageReport.classify(activities: activities,
                               hasTrace: { hasTrace.contains($0) },
                               refused: refused,
                               answeredEmpty: answeredEmpty,
                               queued: queued,
                               minDistance: 500)
    }

    @Test("An answered-empty activity is named, not only counted")
    func answeredEmptyIsNamed() {
        let c = classify([ride("a"), ride("b"), ride("c")],
                         hasTrace: ["a"], answeredEmpty: ["b", "c"])
        #expect(c.answeredEmpty == 2)
        #expect(c.answeredEmptyIDs == ["b", "c"],
                "the count alone cannot tell a tester which activity to open")
    }

    @Test("An unexplained activity is named — the bucket that is a question")
    func unexplainedIsNamed() {
        // Not traced, not refused, not empty, over the floor, not queued.
        let c = classify([ride("z")])
        #expect(c.unexplained == 1)
        #expect(c.unexplainedIDs == ["z"])
    }

    @Test("The ids are sorted, so two exports of one state are identical")
    func theIDsAreStable() {
        let c = classify([ride("c"), ride("a"), ride("b")],
                         answeredEmpty: ["c", "a", "b"])
        // A pair of exports either side of an action is this project's best
        // device instrument — 401, 404, 405, 412 — and an unstable order would
        // make every pair differ for no reason.
        #expect(c.answeredEmptyIDs == ["a", "b", "c"])
    }

    @Test("An empty bucket names nothing, and the count still prints")
    func anEmptyBucketIsHonest() {
        let c = classify([ride("a")], hasTrace: ["a"])
        #expect(c.answeredEmpty == 0)
        #expect(c.answeredEmptyIDs.isEmpty)
        // §12.54.2 — the line prints "none to name" rather than vanishing, so
        // a bucket with nothing in it cannot be told from one nobody wired in.
    }

    @Test("Every activity lands in exactly one bucket")
    func theAccountIsComplete() {
        let c = classify([ride("a"), ride("b"), ride("c"), ride("d", km: 0.1),
                          ride("e")],
                         hasTrace: ["a"], refused: ["b"], answeredEmpty: ["c"],
                         queued: ["e"])
        // An account beats a list: naming ids is only trustworthy if the
        // buckets still partition the whole.
        #expect(c.withTrace + c.refused + c.answeredEmpty
                + c.belowThreshold + c.queued + c.unexplained == c.total)
        #expect(c.total == 5)
    }
}

/// **PATCH 422 — THE DAY IS ON THE SCREEN AND NOT IN THE PASTE.**
///
/// 420 named the ids and left them unreachable: nothing in this app finds an
/// activity by Strava id, so a tester holding one has nowhere to tap. The day
/// is what makes it navigable, and §12.7 governs what leaves the phone rather
/// than what its owner reads. These are the tests that keep the two apart.
@Suite
struct TracelessActivityTests {

    private func activity(_ id: String, day: String, distance: Double = 5000) -> Activity {
        Activity(id: id, name: "x", sportType: "Run",
                 startLocal: "\(day)T09:00:00", distance: distance,
                 movingTime: 1800, elapsedTime: 1800,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil)
    }

    private func coverage(_ activities: [Activity],
                          answeredEmpty: Set<String>) -> TraceCoverage {
        TraceCoverageReport.classify(activities: activities,
                                     hasTrace: { _ in false },
                                     refused: [],
                                     answeredEmpty: answeredEmpty,
                                     queued: [],
                                     minDistance: 500)
    }

    @Test("The screen names the day and the paste does not")
    func theDayIsScreenOnly() {
        let c = coverage([activity("111", day: "2026-08-12")],
                         answeredEmpty: ["111"])
        let onScreen = c.answeredEmptyActivities.map(\.screenText)
        #expect(onScreen == ["111 · 2026-08-12"])
        // §12.7. The export may carry the id and must not carry the date.
        #expect(c.answeredEmptyIDs == ["111"])
        #expect(!c.answeredEmptyIDs.contains { $0.contains("2026") },
                "a date reached the pasteable list")
    }

    /// THE NEGATIVE CONTROL FOR THE PAIRING. Two activities, two days: if the
    /// ids and the days were parallel arrays they could drift, and this is the
    /// assertion that would notice.
    @Test("Each id keeps its own day")
    func idsKeepTheirOwnDays() {
        let c = coverage([activity("222", day: "2026-08-02"),
                          activity("111", day: "2026-08-01")],
                         answeredEmpty: ["111", "222"])
        // Sorted by id, so 111 comes first and brings 08-01 with it.
        #expect(c.answeredEmptyActivities.map(\.screenText)
                == ["111 · 2026-08-01", "222 · 2026-08-02"])
    }

    @Test("The unexplained bucket names its days too")
    func theUnexplainedBucketIsNamedAsWell() {
        let c = coverage([activity("999", day: "2026-08-20")],
                         answeredEmpty: [])
        #expect(c.unexplained == 1)
        #expect(c.unexplainedActivities.map(\.screenText) == ["999 · 2026-08-20"])
        #expect(c.unexplainedIDs == ["999"])
    }

    @Test("Sorting is by id, not by day")
    func sortingIsByID() {
        let c = coverage([activity("111", day: "2026-12-31"),
                          activity("222", day: "2026-01-01")],
                         answeredEmpty: ["111", "222"])
        #expect(c.answeredEmptyIDs == ["111", "222"],
                "a day-ordered list would make two exports of one state differ")
    }
}

/// **PATCH 423 — THE COUPLING BEHIND THE TAP.**
///
/// The Database screen turns each named id into a button by looking the
/// activity up in `ActivityStore.shared.activities`. That works because
/// `traceCoverage()` classifies the same list — so a named id is in it by
/// construction, and the screen's "not in the activity list" branch cannot fire.
///
/// **§12.69: a guard that cannot fail has not been tested.** The state is one
/// refactor away — `answeredEmpty` is a `UserDefaults` set that outlives the
/// roster, and naming ITS members instead of walking the activities would print
/// activities the roster dropped. This is the assertion that fails that day.
@Suite
struct TracelessActivityCouplingTests {

    private func activity(_ id: String, day: String) -> Activity {
        Activity(id: id, name: "x", sportType: "Run",
                 startLocal: "\(day)T09:00:00", distance: 5000,
                 movingTime: 1800, elapsedTime: 1800,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil)
    }

    @Test("classify names only activities it was given")
    func classifyNamesOnlyActivitiesItWasGiven() {
        // `999` is in the verdict set and NOT in the roster — the exact state a
        // dropped activity leaves behind in `UserDefaults`.
        let c = TraceCoverageReport.classify(
            activities: [activity("111", day: "2025-07-24")],
            hasTrace: { _ in false },
            refused: [],
            answeredEmpty: ["111", "999"],
            queued: [],
            minDistance: 500)

        #expect(c.answeredEmpty == 1, "a verdict with no activity was counted")
        #expect(c.answeredEmptyIDs == ["111"],
                "an id the roster does not hold was named — the screen would render it as a tap that opens nothing")
        // And the account still balances over the activities it was handed.
        #expect(c.total == 1)
        #expect(c.balances)
    }
}
