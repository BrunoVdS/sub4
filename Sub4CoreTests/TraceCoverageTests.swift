//
//  TraceCoverageTests.swift
//  Sub4CoreTests
//
//  Why 23 activities have no trace — patch 277, ADR-0003 §12.23.8.
//
//  `theAccountBalances` is the one that matters. Five counters can each be
//  right while the set of them is missing a case; a total that has to add up
//  cannot hide one. Everything else here checks that a given activity lands in
//  the bucket it belongs to.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct TraceCoverageTests {

    private func activity(_ id: String, distance: Double = 10_000) -> Activity {
        Activity(id: id, name: "Session", sportType: "Run",
                 startLocal: "2026-07-28T09:24:06", distance: distance,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T07:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func classify(_ activities: [Activity],
                          traces: Set<String> = [],
                          refused: Set<String> = [],
                          answeredEmpty: Set<String> = [],
                          queued: Set<String> = []) -> TraceCoverage {
        TraceCoverageReport.classify(activities: activities,
                                     hasTrace: { traces.contains($0) },
                                     refused: refused,
                                     answeredEmpty: answeredEmpty,
                                     queued: queued,
                                     minDistance: 500)
    }

    // MARK: The account

    /// THE ONE THAT MATTERS.
    @Test("Every activity lands in exactly one bucket")
    func theAccountBalances() {
        let acts = [activity("1"), activity("2"), activity("3", distance: 0),
                    activity("4"), activity("5"), activity("6", distance: 200)]
        let c = classify(acts, traces: ["1"], refused: ["2"],
                         answeredEmpty: ["4"], queued: ["5"])

        #expect(c.total == 6)
        #expect(c.balances, "the buckets do not sum to the total: \(c)")
        #expect(c.withTrace == 1)
        #expect(c.refused == 1)
        #expect(c.answeredEmpty == 1)
        #expect(c.belowThreshold == 2)
        #expect(c.queued == 1)
        #expect(c.unexplained == 0)
    }

    @Test("Nothing to explain when everything has a trace")
    func everythingCovered() {
        let acts = [activity("1"), activity("2")]
        let c = classify(acts, traces: ["1", "2"])
        #expect(c.missing == 0)
        #expect(c.isFullyExplained)
        #expect(c.balances)
    }

    // MARK: The order is the definition

    @Test("A trace that arrived outranks every reason it might have been absent")
    func aTraceOutranksItsOldExcuses() {
        // The store answered empty once and the trace arrived later — which is
        // what a schema bump plus a re-drain does. The reason is stale.
        let c = classify([activity("1")], traces: ["1"], answeredEmpty: ["1"])
        #expect(c.withTrace == 1)
        #expect(c.answeredEmpty == 0)
    }

    @Test("A refusal outranks an empty answer")
    func aRefusalOutranksAnEmptyAnswer() {
        // A 404 stops the detail fetch before the stream fetch is reached, so
        // being in both sets means the refusal is the live fact.
        let c = classify([activity("1")], refused: ["1"], answeredEmpty: ["1"])
        #expect(c.refused == 1)
        #expect(c.answeredEmpty == 0)
    }

    @Test("The distance rule outranks the queue")
    func theDistanceRuleOutranksTheQueue() {
        // An activity under the threshold is never put in the queue at all, so
        // if it is in both, the rule is the reason.
        let c = classify([activity("1", distance: 100)], queued: ["1"])
        #expect(c.belowThreshold == 1)
        #expect(c.queued == 0)
    }

    // MARK: The residual

    /// The only number on the screen worth watching.
    @Test("An activity with no trace and no reason is unexplained")
    func aMysteryIsCounted() {
        // Over the threshold, not refused, not answered, not queued, no trace.
        let c = classify([activity("1", distance: 10_000)])
        #expect(c.unexplained == 1)
        #expect(c.isFullyExplained == false)
        #expect(c.balances)
    }

    @Test("The threshold is a floor, not a ceiling")
    func exactlyAtTheThresholdIsAsked() {
        // `needsStreams` uses `>=`, so 500 m exactly is eligible and its
        // absence is a mystery rather than a rule.
        let c = classify([activity("1", distance: 500)])
        #expect(c.belowThreshold == 0)
        #expect(c.unexplained == 1)
    }

    @Test("An empty store explains nothing and balances anyway")
    func emptyBalances() {
        let c = classify([])
        #expect(c.total == 0)
        #expect(c.missing == 0)
        #expect(c.balances)
        #expect(c.isFullyExplained)
    }

    // MARK: The shape the device is in

    /// The device on 5 August: 668 activities, 645 traces, 2 answered empty,
    /// the rest under the threshold. Written as a fixture so the arithmetic
    /// §12.23.7 corrected is checked rather than asserted in prose.
    @Test("The 5 August device shape accounts for all 23")
    func theDeviceShapeAddsUp() {
        var acts: [Activity] = []
        var traces: Set<String> = []
        for i in 0..<645 { acts.append(activity("t\(i)")); traces.insert("t\(i)") }
        for i in 0..<2   { acts.append(activity("e\(i)")) }
        for i in 0..<21  { acts.append(activity("s\(i)", distance: 0)) }

        let c = classify(acts, traces: traces,
                         answeredEmpty: ["e0", "e1"])

        #expect(c.total == 668)
        #expect(c.withTrace == 645)
        #expect(c.missing == 23)
        #expect(c.answeredEmpty == 2)
        #expect(c.belowThreshold == 21)
        #expect(c.unexplained == 0)
        #expect(c.balances)
    }
}
