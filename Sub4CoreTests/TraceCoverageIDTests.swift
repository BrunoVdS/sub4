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
