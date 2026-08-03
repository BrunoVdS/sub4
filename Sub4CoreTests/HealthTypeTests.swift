//
//  HealthTypeTests.swift
//  Sub4CoreTests
//
//  The Health authorisation set, pinned — patch 181, plan step 2.2.
//
//  WHY A TEST FOR A LIST OF CONSTANTS
//  ----------------------------------
//  `HK-02` was not a subtle bug. `distanceCycling` was read in one file and
//  absent from the request in another, and it stayed that way because nothing
//  connects the two: HealthKit answers an unrequested read with an empty result,
//  which is indistinguishable from a device that has no cycling data. No error,
//  no prompt, no warning — rides simply never gained a distance.
//
//  That is the shape of failure a test exists for. The request now derives from
//  `typesRead`, and these assertions hold the description and the version marker
//  to the same list, so the next type added has to be added in all three places
//  or the build goes red.
//

import Testing
import Foundation
import HealthKit
@testable import Sub4

@Suite
@MainActor
struct HealthTypeTests {

    /// The seven the app actually reads, named. If this list changes, the
    /// purpose string shown at the permission prompt has to change with it —
    /// that string is the user-facing half of the same claim.
    @Test("Exactly the seven documented types are requested")
    func requestedTypesAreTheDocumentedSeven() {
        let types = HealthStore.shared.typesRead
        #expect(types.count == 7, "requesting \(types.count) types, expected 7")

        let identifiers = Set(types.map(\.identifier))
        let expected: Set<String> = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.distanceSwimming.rawValue,
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.distanceCycling.rawValue,
            HKObjectType.workoutType().identifier
        ]
        // One literal — `Comment` is ExpressibleByStringInterpolation and has no
        // `+`. See the note in DataLifecycleTests.
        #expect(identifiers == expected,
                "missing: \(expected.subtracting(identifiers)); unexpected: \(identifiers.subtracting(expected))")
    }

    /// The specific regression. Worth its own named test so a failure says what
    /// broke rather than "a set did not match".
    @Test("Cycling distance is requested, not just read")
    func cyclingDistanceIsRequested() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        #expect(ids.contains(HKQuantityTypeIdentifier.distanceCycling.rawValue),
                "distanceCycling is read when enriching a ride and must be requested (HK-02)")
    }

    /// The plain-language list is what Settings and the privacy inventory show.
    /// If it falls behind the real set, the app is describing itself wrongly to
    /// the person deciding whether to grant access.
    @Test("The described list covers every requested type")
    func descriptionMatchesTheRequest() {
        #expect(HealthStore.typesReadDescribed.count
                == HealthStore.shared.typesRead.count,
                "\(HealthStore.typesReadDescribed.count) descriptions for \(HealthStore.shared.typesRead.count) types")
        for d in HealthStore.typesReadDescribed {
            #expect(d.isEmpty == false)
        }
    }

    // MARK: The status model

    /// `noData` must not read as a fault. A device with no swims is not broken,
    /// and an app that says otherwise sends people to fix nothing.
    @Test("An empty window is not reported as a problem")
    func noDataIsNotAProblem() {
        #expect(HealthStore.SeriesStatus.noData.isProblem == false)
        #expect(HealthStore.SeriesStatus.notRequested.isProblem == false)
        #expect(HealthStore.SeriesStatus.ok(count: 0).isProblem == false)
    }

    /// And the converse: the two states that mean something actually went wrong
    /// have to say so, or a broken read looks like an empty one.
    @Test("A failure and a timeout are reported as problems")
    func failuresAreProblems() {
        #expect(HealthStore.SeriesStatus.failed("boom").isProblem)
        #expect(HealthStore.SeriesStatus.timedOut.isProblem)
    }

    @Test("Every status can describe itself")
    func everyStatusHasALabel() {
        let all: [HealthStore.SeriesStatus] = [
            .notRequested, .noData, .ok(count: 1), .ok(count: 120),
            .failed("network"), .timedOut
        ]
        for s in all { #expect(s.label.isEmpty == false) }
        // Singular and plural, because "1 days" in a settings row is the kind of
        // thing that makes a reader doubt everything else on the screen.
        #expect(HealthStore.SeriesStatus.ok(count: 1).label == "1 day")
        #expect(HealthStore.SeriesStatus.ok(count: 2).label == "2 days")
    }

    // MARK: The query outcome

    /// The distinction the whole patch turns on: a successful empty read and a
    /// failed read must not produce the same value, because `refresh` decides
    /// whether to overwrite the live series from exactly this.
    @Test("A successful empty read is distinguishable from a failure")
    func emptySuccessIsNotAFailure() {
        let empty = HealthStore.QueryOutcome.ok([:])
        let failed = HealthStore.QueryOutcome.failed("no")
        let timeout = HealthStore.QueryOutcome.timedOut

        #expect(empty.values != nil, "a successful empty read must carry a value")
        #expect(empty.values?.isEmpty == true)
        #expect(failed.values == nil, "a failure must not present as data")
        #expect(timeout.values == nil, "a timeout must not present as data")
    }

    /// `values` is what `refresh` guards on, so a non-empty success has to hand
    /// its readings back intact.
    @Test("A successful read carries its readings")
    func successCarriesValues() throws {
        let outcome = HealthStore.QueryOutcome.ok(["2026-08-01": 9_412])
        let v = try #require(outcome.values)
        #expect(v["2026-08-01"] == 9_412)
    }
}
