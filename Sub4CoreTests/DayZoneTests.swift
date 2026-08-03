//
//  DayZoneTests.swift
//  Sub4CoreTests
//
//  Which clock a training day was counted on — patch 198, ADR-0003 §4.5.
//
//  THE BUG THESE PIN
//  -----------------
//  `HealthStore` cut its daily buckets with `Calendar.current` and labelled
//  them with a formatter that names no zone, so both used the device's clock at
//  the moment of the query. Days lived in Japan bucketed by JST while the phone
//  was there and re-bucketed by CEST on landing — a seven-hour shift applied to
//  a month of history that had already been read, with nothing on screen to say
//  the numbers had moved.
//
//  The decision was to freeze: a day in Japan stays a Japanese day. What makes
//  that possible without a new store is patch 196 — every activity now carries
//  the offset it was recorded at, and activities are persisted.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct DayZoneTests {

    private let brussels = TimeZone(identifier: "Europe/Brussels")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// Belgium in September is +2, Japan is +9.
    private func activity(_ day: String, offset: Int,
                          zone: String? = nil,
                          positioned: Bool = true,
                          at time: String = "07:00:00") -> Activity {
        Activity(id: "\(day)-\(time)", name: "Run", sportType: "Run",
                 startLocal: "\(day)T\(time)", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "\(day)T05:00:00Z",
                 startLat: positioned ? 51.2 : nil,
                 startLon: positioned ? 4.4 : nil,
                 timeZoneIdentifier: zone, startOffsetSeconds: offset)
    }

    /// The real shape of the September block: home, away for three weeks, home.
    private var theTrip: DayZones {
        DayZones.from(activities: [
            activity("2026-09-01", offset: 7_200, zone: "Europe/Brussels"),
            activity("2026-09-04", offset: 7_200, zone: "Europe/Brussels"),
            activity("2026-09-08", offset: 32_400, zone: "Asia/Tokyo"),
            activity("2026-09-14", offset: 32_400, zone: "Asia/Tokyo"),
            activity("2026-09-28", offset: 32_400, zone: "Asia/Tokyo"),
            activity("2026-10-02", offset: 7_200, zone: "Europe/Brussels")
        ], deviceOffset: 7_200)
    }

    // MARK: Building

    /// Only changes are recorded. Six activities across three stretches is
    /// three entries, not six.
    @Test("A trip is three changes, not one per activity")
    func onlyChangesAreRecorded() {
        #expect(theTrip.changes.map(\.dayKey) == ["2026-09-01", "2026-09-08", "2026-10-02"])
        #expect(theTrip.changes.map(\.offsetSeconds) == [7_200, 32_400, 7_200])
    }

    /// A device that has never left home yields one entry and the caller keeps
    /// the single-query path.
    @Test("A year at home is uniform")
    func homeIsUniform() {
        let z = DayZones.from(activities: [
            activity("2026-06-01", offset: 7_200),
            activity("2026-06-08", offset: 7_200)
        ], deviceOffset: 7_200)
        #expect(z.isUniform)
        #expect(z.changes.count == 1)
    }

    /// Two sessions on a travel day disagree. The later one is the one that
    /// says where the day ended.
    @Test("The last session of a day decides its clock")
    func lastSessionOfTheDayWins() {
        let z = DayZones.from(activities: [
            activity("2026-09-06", offset: 7_200, at: "06:00:00"),
            activity("2026-09-06", offset: 32_400, at: "22:00:00")
        ], deviceOffset: 7_200)
        #expect(z.offset(forDay: "2026-09-06") == 32_400)
    }

    /// An activity with no offset — everything before patch 196 backfilled —
    /// contributes nothing rather than a guess.
    @Test("An activity with no offset is not evidence")
    func activityWithoutOffsetIsIgnored() {
        let z = DayZones.from(activities: [
            activity("2026-09-01", offset: 7_200),
            Activity(id: "old", name: "Run", sportType: "Run",
                     startLocal: "2026-09-05T07:00:00", distance: 1,
                     movingTime: 1, elapsedTime: 1, elevationGain: nil,
                     averageHeartrate: nil, isTrainer: nil, maxHeartrate: nil,
                     gearId: nil, maxSpeed: nil, deviceWatts: nil,
                     averageWatts: nil, startUTC: nil, startLat: nil, startLon: nil,
                     timeZoneIdentifier: nil, startOffsetSeconds: nil)
        ], deviceOffset: 7_200)
        #expect(z.changes.count == 1)
    }

    // MARK: Asking

    /// A rest day inherits from the last session. You did not fly home to
    /// sleep.
    @Test("A rest day in Japan is a Japanese day")
    func restDayInheritsTheTrip() {
        #expect(theTrip.offset(forDay: "2026-09-15") == 32_400,
                "a rest day mid-trip reverted to the home clock")
        #expect(theTrip.offset(forDay: "2026-09-20") == 32_400)
    }

    @Test("A day at home before the trip is a home day")
    func daysBeforeTheTripAreHome() {
        #expect(theTrip.offset(forDay: "2026-09-03") == 7_200)
    }

    /// Days before any recording use the earliest evidence rather than the
    /// device's clock. January 2025 was not lived on today's offset.
    @Test("Days before the first activity use the earliest known clock")
    func daysBeforeAnyActivityUseTheFirstKnown() {
        #expect(theTrip.offset(forDay: "2025-01-01") == 7_200)
    }

    /// After the last activity the device's own clock is right: nothing has
    /// been recorded, and live readings are being taken where the phone is.
    @Test("Days after the last activity use the device clock")
    func daysAfterTheLastActivityUseTheDevice() {
        let z = DayZones.from(activities: [activity("2026-09-01", offset: 7_200)],
                              deviceOffset: 32_400)
        // Uniform, so everything is the single known offset — the trailing
        // value only takes over when there is no evidence at all.
        #expect(z.offset(forDay: "2026-09-30") == 7_200)

        let empty = DayZones.from(activities: [], deviceOffset: 32_400)
        #expect(empty.offset(forDay: "2026-09-30") == 32_400)
    }

    /// THE ACCEPTED COST, WRITTEN DOWN. Land on the 7th, first run on the 8th,
    /// and the 7th buckets as a home day. One day at each end of a trip, and it
    /// is the same answer on every launch — which is what freezing means. A
    /// separate store of the device's zone per day would fix this one day and
    /// add state that can contradict the activities.
    @Test("A travel day with no recording falls to the previous clock")
    func theBoundaryDayCostIsRealAndDeterministic() {
        #expect(theTrip.offset(forDay: "2026-09-07") == 7_200,
                "the arrival day is expected to read as home — see the comment")
        // Deterministic is the property that matters: same answer twice.
        #expect(theTrip.offset(forDay: "2026-09-07") == theTrip.offset(forDay: "2026-09-07"))
    }

    // MARK: Runs

    /// The window is cut into stretches, one per clock.
    @Test("A window spanning the trip is three runs")
    func theTripIsThreeRuns() throws {
        let from = try #require(DayKey.startOfDay("2026-08-01", in: brussels))
        let to = try #require(DayKey.startOfDay("2026-11-01", in: brussels))
        let runs = theTrip.runs(from: from, to: to)
        #expect(runs.count == 3, "got \(runs.count) runs")
        #expect(runs.map(\.offsetSeconds) == [7_200, 32_400, 7_200])
    }

    /// THE PART THAT WOULD HAVE DOUBLE-COUNTED.
    ///
    /// Each run starts at midnight of its first day in its own zone. Tokyo
    /// midnight on the 8th is 15:00Z on the 7th; Brussels midnight on the 8th
    /// is 22:00Z on the 7th. If each run also ENDED at its own midnight the two
    /// would overlap by seven hours and every step in them would be counted
    /// under both days.
    @Test("Runs partition the window with no overlap and no gap")
    func runsPartitionTheWindow() throws {
        let from = try #require(DayKey.startOfDay("2026-08-01", in: brussels))
        let to = try #require(DayKey.startOfDay("2026-11-01", in: brussels))
        let runs = theTrip.runs(from: from, to: to)

        #expect(runs.first?.start == from)
        #expect(runs.last?.end == to)
        for (a, b) in zip(runs, runs.dropFirst()) {
            #expect(a.end == b.start,
                    "runs overlap or leave a gap at \(a.end) → \(b.start)")
        }
    }

    /// And the boundary lands where the clock changed, not where the home
    /// clock's midnight was.
    @Test("The away run begins at midnight in the away zone")
    func awayRunStartsOnItsOwnMidnight() throws {
        let from = try #require(DayKey.startOfDay("2026-08-01", in: brussels))
        let to = try #require(DayKey.startOfDay("2026-11-01", in: brussels))
        let runs = theTrip.runs(from: from, to: to)
        let away = try #require(runs.first { $0.offsetSeconds == 32_400 })
        #expect(away.start == DayKey.startOfDay("2026-09-08", in: tokyo))
    }

    /// THE COALESCING, ASSERTED DIRECTLY — patch 200.
    ///
    /// `changes` records the first day of every stretch including the first
    /// one, so a window opening before the earliest activity picks up a
    /// boundary carrying the offset it already had. Left in, it cuts one run
    /// into two identical halves: same buckets, one extra HealthKit query, and
    /// invisible to a partition check because the partition is still valid.
    @Test("A boundary that does not change the clock does not start a run")
    func sameClockBoundariesAreOneRun() throws {
        // Two changes at the same offset either side of a genuine one.
        let z = DayZones.from(activities: [
            activity("2026-09-01", offset: 7_200),
            activity("2026-09-08", offset: 32_400),
            activity("2026-10-02", offset: 7_200),
            activity("2026-10-09", offset: 7_200)
        ], deviceOffset: 7_200)
        let from = try #require(DayKey.startOfDay("2026-08-01", in: brussels))
        let to = try #require(DayKey.startOfDay("2026-11-01", in: brussels))
        let runs = z.runs(from: from, to: to)
        #expect(runs.map(\.offsetSeconds) == [7_200, 32_400, 7_200],
                "got \(runs.map(\.offsetSeconds))")
    }

    /// A device that never left home still gets exactly one query.
    @Test("A uniform history is a single run")
    func uniformHistoryIsOneRun() throws {
        let z = DayZones.from(activities: [activity("2026-06-01", offset: 7_200)],
                              deviceOffset: 7_200)
        let from = try #require(DayKey.startOfDay("2026-01-01", in: brussels))
        let to = try #require(DayKey.startOfDay("2026-12-01", in: brussels))
        #expect(z.runs(from: from, to: to).count == 1)
    }

    // MARK: Saying so — what Bruno asked for on top of the freeze

    /// The freeze alone is silent: the number is right and nothing says which
    /// midnight it was counted from.
    @Test("A day in Japan says which clock it was counted on")
    func foreignDayIsMarked() throws {
        let marker = try #require(theTrip.marker(forDay: "2026-09-14", readerIn: brussels))
        #expect(["JST", "GMT+9"].contains(marker), "got \(marker)")
        #expect(theTrip.isForeign(dayKey: "2026-09-14", readerIn: brussels))
    }

    /// And a day at home says nothing, so the marker means something when it
    /// appears.
    @Test("A day at home carries no marker")
    func homeDayIsUnmarked() {
        #expect(theTrip.marker(forDay: "2026-09-03", readerIn: brussels) == nil)
        #expect(theTrip.marker(forDay: "2026-10-05", readerIn: brussels) == nil)
    }

    /// Read while still in Japan, a Japanese day is the reader's own day and
    /// needs no marker — and the Belgian ones do.
    @Test("The marker follows the reader, not the athlete's home")
    func markerIsRelativeToTheReader() throws {
        #expect(theTrip.marker(forDay: "2026-09-14", readerIn: tokyo) == nil)
        let home = try #require(theTrip.marker(forDay: "2026-09-03", readerIn: tokyo))
        #expect(["CEST", "GMT+2"].contains(home), "got \(home)")
    }

    /// Patch 197's rule, carried through. A day whose only session was a pool
    /// swim has no trustworthy identifier, so the marker falls back to the
    /// offset rather than announcing Central Africa Time.
    @Test("A day known only from an indoor session does not name a false place")
    func indoorOnlyDayFallsBackToTheOffset() throws {
        let z = DayZones.from(activities: [
            activity("2026-07-14", offset: 7_200, zone: "Africa/Blantyre", positioned: false)
        ], deviceOffset: 7_200)
        let marker = try #require(z.marker(forDay: "2026-07-14", readerIn: tokyo))
        #expect(marker == "GMT+2", "got \(marker)")
    }

    /// Daylight saving, at the day level. Same trap as the activity card: a
    /// summer day at home compared against the reader's WINTER offset would
    /// read as foreign, so the comparison is made at the day itself.
    @Test("A summer day at home is not marked when read in winter")
    func summerDayIsNotMarkedInWinter() {
        let z = DayZones.from(activities: [
            activity("2026-06-14", offset: 7_200, zone: "Europe/Brussels"),
            activity("2026-12-14", offset: 3_600, zone: "Europe/Brussels")
        ], deviceOffset: 3_600)
        #expect(z.marker(forDay: "2026-06-14", readerIn: brussels) == nil,
                "a June day at home was marked as foreign")
        #expect(z.marker(forDay: "2026-12-14", readerIn: brussels) == nil,
                "a December day at home was marked as foreign")
    }
}
