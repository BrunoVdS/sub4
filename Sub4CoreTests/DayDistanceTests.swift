//
//  DayDistanceTests.swift
//  Sub4CoreTests
//
//  Patch 249. The rule is one sentence — kilometres do not add across sports,
//  minutes do — and every test here is a way of getting that wrong.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct DayDistanceTests {

    private func activity(_ id: String,
                          sport: String,
                          km: Double,
                          minutes: Int = 30) -> Activity {
        Activity(id: id,
                 name: sport,
                 sportType: sport,
                 startLocal: "2026-08-04T07:00:00",
                 distance: km * 1000,
                 movingTime: minutes * 60,
                 elapsedTime: minutes * 60,
                 elevationGain: nil,
                 averageHeartrate: nil,
                 isTrainer: nil,
                 maxHeartrate: nil,
                 gearId: nil,
                 maxSpeed: nil,
                 deviceWatts: nil,
                 averageWatts: nil,
                 startUTC: nil,
                 startLat: nil,
                 startLon: nil)
    }

    @Test("One sport gives a distance, and names the sport")
    func oneSportIsADistance() {
        let d = DayDistance.of([activity("1", sport: "Ride", km: 2.79),
                                activity("2", sport: "Ride", km: 6.09),
                                activity("3", sport: "Ride", km: 4.44)])
        #expect(d == .km(13.32, .bike))
        #expect(d.unit == "km bike")
        #expect(d.value == "13,3" || d.value == "13.3", "value was \(d.value)")
    }

    @Test("Two sports do not add — the whole point of this file")
    func twoSportsFallBackToTime() {
        // 4 August 2026, if the panel had summed it: 1,2 km of swimming plus
        // 13,3 km of cycling read as 14,5 km, which is not a quantity.
        let d = DayDistance.of([activity("1", sport: "Swim", km: 1.2, minutes: 38),
                                activity("2", sport: "Ride", km: 13.32, minutes: 40)])
        #expect(d == .minutes(78))
        #expect(d.unit == "min")
        #expect(d.isSingleDiscipline == false)
    }

    @Test("A strength session does not make a bike day mixed")
    func zeroDistanceDoesNotContaminate() {
        // The case that would have hidden the one real number on the screen:
        // 4 August held three rides AND a squat session.
        let d = DayDistance.of([activity("1", sport: "Ride", km: 13.32),
                                activity("2", sport: "WeightTraining", km: 0, minutes: 26)])
        #expect(d == .km(13.32, .bike))
    }

    @Test("GPS drift on a gym session is not a second discipline")
    func driftIsBelowTheThreshold() {
        // 40 metres of wander while the watch sat on a bench. Caught by the
        // distance threshold rather than by guessing from the sport label.
        let d = DayDistance.of([activity("1", sport: "Run", km: 10),
                                activity("2", sport: "WeightTraining", km: 0.04)])
        #expect(d == .km(10, .run))
    }

    @Test("A day with no distance is not a day with no time")
    func strengthOnlyKeepsItsMinutes() {
        let d = DayDistance.of([activity("1", sport: "WeightTraining", km: 0, minutes: 26)])
        #expect(d == .none(minutes: 26))
        #expect(d.value == "0,0")
        #expect(d.unit == "km")
    }

    @Test("An empty day is empty rather than wrong")
    func emptyIsHandled() {
        #expect(DayDistance.of([]) == .none(minutes: 0))
    }

    @Test("Minutes count every activity, including the ones with no distance")
    func minutesCountEverything() {
        // The fallback has to be the whole day's time, not just the part that
        // moved — otherwise a mixed day reports less time than it took.
        let d = DayDistance.of([activity("1", sport: "Swim", km: 1.2, minutes: 38),
                                activity("2", sport: "Ride", km: 13.32, minutes: 40),
                                activity("3", sport: "WeightTraining", km: 0, minutes: 26)])
        #expect(d == .minutes(104))
    }

    @Test("An unknown sport is one discipline, not a licence to add")
    func unknownSportsStillGroup() {
        let a = DayDistance.of([activity("1", sport: "Kayaking", km: 5),
                                activity("2", sport: "Kayaking", km: 3)])
        #expect(a == .km(8, .other))
        let b = DayDistance.of([activity("1", sport: "Kayaking", km: 5),
                                activity("2", sport: "Run", km: 3)])
        #expect(b.isSingleDiscipline == false)
    }
}
