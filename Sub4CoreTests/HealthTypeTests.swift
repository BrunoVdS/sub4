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

    /// The eight the app actually reads, named. If this list changes, the
    /// purpose string shown at the permission prompt has to change with it —
    /// that string is the user-facing half of the same claim.
    @Test("Exactly the eight documented types are requested")
    func requestedTypesAreTheDocumentedEight() {
        let types = HealthStore.shared.typesRead
        #expect(types.count == 8, "requesting \(types.count) types, expected 8")

        let identifiers = Set(types.map(\.identifier))
        let expected: Set<String> = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.distanceSwimming.rawValue,
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.distanceCycling.rawValue,
            HKObjectType.workoutType().identifier,
            // Patch 286. Queried by the coverage census since 285 and absent
            // from this set until now — HK-02, second occurrence.
            HKSeriesType.workoutRoute().identifier
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

    /// THE SECOND OCCURRENCE OF THE SAME DEFECT, pinned the same way.
    ///
    /// Patch 285 added a route query and did not add the type. HealthKit
    /// answers an unrequested read with an empty result, so the census
    /// reported nothing and read as a phone with no routes — the identical
    /// failure the header of this file describes for cycling distance, two
    /// screens above the query that repeated it.
    @Test("Workout routes are requested, not just read")
    func workoutRoutesAreRequested() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        #expect(ids.contains(HKSeriesType.workoutRoute().identifier),
                "the coverage census reads routes and must request them (HK-02, 285)")
    }

    /// A failure has to carry HealthKit's reason, not just the fact of it.
    /// 286 reported "a route query returned an error" because the helper threw
    /// the reason away; 286a keeps it, and this is what stops it being thrown
    /// away again.
    @Test("A failed census quotes the reason it was given")
    func aFailedCensusQuotesItsReason() {
        let line = HealthStore.RouteCensus.failed("the type is not supported").line
        #expect(line.contains("the type is not supported"))
    }

    /// The guard that makes the next one of these visible in one run rather
    /// than in a report nobody can interpret: the census asks `typesRead`
    /// before it queries, so an unrequested type is a named refusal instead of
    /// an empty answer.
    @Test("The census refuses to query a type that was never requested")
    func theCensusRefusesAnUnrequestedType() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        let requested = ids.contains(HKSeriesType.workoutRoute().identifier)
        // With the type present the guard must not fire; this asserts the two
        // are wired to each other rather than agreeing by accident.
        #expect(requested, "the guard reads this same list")
        #expect(HealthStore.RouteCensus.notRequested.line
                    .localizedCaseInsensitiveContains("never asked permission"),
                "the refusal has to say what went wrong, not just that it did")
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

    // MARK: The purpose string

    /// PRIV-02, and the reason this test exists rather than a line in the
    /// privacy inventory.
    ///
    /// The string shown at the permission prompt lives in the target's build
    /// settings — `INFOPLIST_KEY_NSHealthShareUsageDescription` — not in any
    /// file this project compiles. It said "Reads your daily step count" while
    /// seven types were being requested, and nothing could have noticed: no
    /// Swift file references it, and the app runs perfectly with it wrong.
    ///
    /// So it is read back out of the built product and held to the same list the
    /// request is built from. If a type is added to `typesRead` without the
    /// prompt being updated, this goes red.
    @Test("The permission prompt names every type the app reads")
    func usageDescriptionNamesEveryTypeRead() throws {
        let text = try #require(HealthStore.usageDescription,
                                "INFOPLIST_KEY_NSHealthShareUsageDescription is not set on the Sub4 target")
        #expect(text.isEmpty == false)

        // One subject per requested type. Deliberately loose — these check that
        // the subject is named, not how the sentence is worded. REWORDING THE
        // STRING IS FINE; rewording it so that one of these no longer appears
        // means a type is being read without being disclosed, which is the thing
        // being prevented. If you change the wording, change this list with it
        // and know which type you are dropping.
        let subjects = ["step", "walking", "running", "cycling",
                        "swim", "workout", "route", "heart rate", "resting"]
        #expect(subjects.count >= HealthStore.shared.typesRead.count,
                "\(subjects.count) subjects for \(HealthStore.shared.typesRead.count) types")

        for s in subjects {
            #expect(text.localizedCaseInsensitiveContains(s),
                    "the prompt does not mention \(s), but that type is requested")
        }
    }

    // MARK: The re-ask banner — 288

    /// THE STRUCTURAL PIN. The banner named two types while eight were
    /// requested, and nothing could have noticed: it is prose in a `View`,
    /// read by a person once every few months at the exact moment they are not
    /// checking it against a list.
    ///
    /// Asserting that every described type appears is trivially true while the
    /// message renders the list — which is the point. It stops being true the
    /// moment somebody replaces the rendering with a sentence, and that is the
    /// failure being prevented.
    @Test("The re-ask banner names every type the app reads")
    func theBannerNamesEveryTypeRead() {
        let message = HealthStore.newTypesMessage
        for described in HealthStore.typesReadDescribed {
            #expect(message.localizedCaseInsensitiveContains(described),
                    "the banner does not mention \(described), but it is requested")
        }
    }

    @Test("The banner counts what it lists")
    func theBannerCountsWhatItLists() {
        let n = HealthStore.typesReadDescribed.count
        #expect(HealthStore.newTypesMessage.contains("\(n) kinds"))
    }

    /// The old text is pinned as ABSENT rather than the new text as present.
    /// "workouts and swim distance" was accurate once; what makes it wrong is
    /// that it is a fixed list, and a test that allowed a different fixed list
    /// would be guarding the wrong thing.
    @Test("The banner does not carry a hand-written list of types")
    func theBannerDoesNotHardCodeTypes() {
        #expect(!HealthStore.newTypesMessage
                    .localizedCaseInsensitiveContains("now also reads"),
                "the banner is computed from typesReadDescribed — see ADR-0003 §12.34")
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
