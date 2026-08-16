//
//  MinutesAreDerivedTests.swift
//  Sub4CoreTests
//
//  Seconds add, minutes do not — patch 375, ADR-0003 §12.119.
//
//  THE ONE THAT IS THE DEFECT
//  --------------------------
//  `aSumOfTruncatedMinutesLosesTime`. It states the arithmetic in isolation,
//  because that is the whole bug: `movingTime / 60` throws away up to 59
//  seconds, and seven places added those values together. Ten activities lost
//  up to nine minutes, and `WeekView` printed the result.
//
//  THE ONE THAT SAYS WHY IT FLOORS
//  -------------------------------
//  `theTotalIsNeverMoreThanItsParts`. Rounding the sum is closer to the truth
//  and would print a total larger than the rows above it — two 29:59 rides
//  showing 29 and 29 beneath a total of 60. §12.119.3.
//
//  AND THE ONE THAT KEEPS THE PATCH HONEST
//  ---------------------------------------
//  `oneActivityIsUnchanged`. A single activity's minutes were always right.
//  A fix that reached them would be changing what a card says for no reason.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Minutes are derived, never accumulated")
@MainActor
struct MinutesAreDerivedTests {

    // MARK: Fixtures

    /// The shape `TabSummaryTests` uses, so a reader comparing the two sees
    /// the same activity twice rather than two inventions.
    private func activity(_ id: String,
                          sportType: String = "Run",
                          km: Double = 10,
                          startLocal: String = "2026-07-27T09:00:00",
                          movingTime: Int = 3_600) -> Activity {
        Activity(id: id, name: "Session", sportType: sportType,
                 startLocal: startLocal, distance: km * 1000,
                 movingTime: movingTime, elapsedTime: movingTime,
                 elevationGain: 0, averageHeartrate: nil, isTrainer: false,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-27T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    /// Ten rides of 29:59. Each is 29 minutes on its own card and the ten
    /// together are 299 minutes and 50 seconds.
    private func tenNearlyThirtyMinuteRides() -> [Activity] {
        (0..<10).map { activity("a\($0)", movingTime: 1_799) }
    }

    /// **A COMMUTE, WHICH IS A NARROWER THING THAN AN ACTIVITY — patch 375a.**
    ///
    /// `CommuteSummary.init` keeps `discipline == .bike && !isPlanEligible`,
    /// and for a bike `isPlanEligible` is `!isCommuteRide` — so the filter
    /// means "a bike ride that is a commute". 375 fed it runs and got an empty
    /// set. §12.119.6.
    ///
    /// 4 km because `isCommuteRide` falls back to the distance rule for an id
    /// the store has never seen, and the real commute is 3.2–4.2 km.
    ///
    /// THE IDS ARE NAMESPACED. `isCommuteRide` consults `CommuteStore.shared`,
    /// which points at the athlete's own decisions; there is no seam through
    /// `CommuteSummary` that avoids it. An id like `c0` could collide with a
    /// real answer and flip this test without touching it.
    private func commute(_ id: String,
                         startLocal: String = "2026-07-27T09:00:00") -> Activity {
        activity(id, sportType: "Ride", km: 4,
                 startLocal: startLocal, movingTime: 1_799)
    }

    // MARK: The defect

    /// **THE ONE THAT IS THE DEFECT.**
    @Test("A sum of truncated minutes loses time")
    func aSumOfTruncatedMinutesLosesTime() {
        let rides = tenNearlyThirtyMinuteRides()

        let theOldWay = rides.reduce(0) { $0 + $1.minutes }
        #expect(theOldWay == 290, "ten 29:59 rides used to add up to 290")

        #expect(rides.totalMinutes == 299,
                "the ten rides cover 299 minutes and 50 seconds")
        #expect(rides.totalMinutes - theOldWay == 9,
                "the loss grows with the count — nine activities, nine minutes")
    }

    @Test("totalMinutes divides once")
    func totalMinutesDividesOnce() {
        let rides = tenNearlyThirtyMinuteRides()
        #expect(rides.movingSeconds == 17_990)
        #expect(rides.totalMinutes == 17_990 / 60)
    }

    /// §12.119.3. Rounding would have produced a total bigger than the rows a
    /// reader can add up above it.
    @Test("The total is never more than its parts suggest")
    func theTotalIsNeverMoreThanItsParts() {
        let two = [activity("a", movingTime: 1_799),
                   activity("b", movingTime: 1_799)]
        // 59:58. Rounded that is 60; floored it is 59, and the two rows above
        // it read 29 and 29.
        #expect(two.totalMinutes == 59)
        #expect(two.totalMinutes >= two.reduce(0) { $0 + $1.minutes },
                "the total must never be smaller than the sum of what is shown")
    }

    /// The places that were always right must stay right.
    @Test("One activity is unchanged")
    func oneActivityIsUnchanged() {
        let a = activity("a", movingTime: 1_799)
        #expect(a.minutes == 29)
        #expect([a].totalMinutes == 29,
                "a sequence of one must agree with the activity's own card")
    }

    @Test("An empty sequence is zero, not a crash")
    func anEmptySequenceIsZero() {
        let none: [Activity] = []
        #expect(none.movingSeconds == 0)
        #expect(none.totalMinutes == 0)
    }

    // MARK: The four call sites

    /// `DayDistance` reports a mixed-discipline day as its time, and that
    /// figure is what `VolumeParity` compares.
    @Test("A mixed day counts every second")
    func aMixedDayCountsEverySecond() {
        let mixed = [activity("run", sportType: "Run", km: 5, movingTime: 1_799),
                     activity("ride", sportType: "Ride", km: 20, movingTime: 1_799)]
        #expect(DayDistance.of(mixed) == .minutes(59),
                "two disciplines report time, and 59:58 is 59 minutes")
    }

    @Test("A day with no distance still counts every second")
    func aDayWithNoDistanceCountsEverySecond() {
        let gym = [activity("s1", sportType: "WeightTraining", km: 0, movingTime: 1_799),
                   activity("s2", sportType: "WeightTraining", km: 0, movingTime: 1_799)]
        #expect(DayDistance.of(gym) == .none(minutes: 59))
    }

    @Test("The week accumulates seconds")
    func theWeekAccumulatesSeconds() {
        let day = MatchResolver.Day(matches: [], extras: tenNearlyThirtyMinuteRides())
        let w = TabSummary.weekActuals([day])

        #expect(w.movingSeconds == 17_990)
        #expect(w.minutes == 299, "the week used to read 290")
        #expect(w.recorded == 10)
    }

    /// THE BUCKET ITSELF, not just the all-time total beside it — that is the
    /// field `WeekBucket` changed. Dated to today rather than to a fixed day,
    /// because the buckets are the last twelve weeks and a hard-coded date
    /// makes this pass until it silently stops testing anything.
    @Test("The commute bucket accumulates seconds")
    func theCommuteBucketAccumulatesSeconds() throws {
        let today = DayKey.key()
        let rides = (0..<10).map {
            commute("375-bucket-\($0)", startLocal: today + "T09:00:00")
        }
        // **THE ASSERTION 375 DID NOT HAVE — patch 375a, §12.119.6.**
        // The first version used runs. `CommuteSummary` filtered every one of
        // them away, so the figures below were compared against an empty set
        // and the production code was never asked anything.
        // OUT OF THE MACRO — patch 375b. `allSatisfy` is `rethrows`; inside
        // `#expect` the expansion loses that and reads as throwing. §12.119.7.
        let allAreCommutes = rides.allSatisfy(\.isCommuteRide)
        #expect(allAreCommutes,
                "the fixture must be commutes or the summary discards it")

        let summary = CommuteSummary(rides)
        let thisWeek = try #require(summary.thisWeek,
                                    "the current week should always have a bucket")
        #expect(thisWeek.count == 10)
        #expect(thisWeek.movingSeconds == 17_990)
        #expect(thisWeek.minutes == 299, "the bucket used to read 290")
        #expect(summary.allTime.movingSeconds == 17_990)
    }

    /// §12.119.1's worst case: a truncated sum, truncated again into hours.
    @Test("Commute hours are not truncated twice")
    func commuteHoursAreNotTruncatedTwice() {
        // 120 rides of 59 seconds short of a minute each. The old path lost
        // two hours before the hours were even computed.
        let many = (0..<120).map { commute("375-hours-\($0)") }
        // §12.119.7, as above.
        let allAreCommutes = many.allSatisfy(\.isCommuteRide)
        #expect(allAreCommutes,
                "the fixture must be commutes or the summary discards it")

        let summary = CommuteSummary(many)

        #expect(summary.allTime.movingSeconds == 215_880)
        #expect(summary.allTime.movingSeconds / 3600 == 59,
                "215 880 seconds is 59 hours")

        let theOldWay = many.reduce(0) { $0 + $1.minutes } / 60
        #expect(theOldWay == 58, "the card used to say 58")
    }
}
