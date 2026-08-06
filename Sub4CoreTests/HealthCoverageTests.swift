//
//  HealthCoverageTests.swift
//  Sub4CoreTests
//
//  Does Apple Health hold the history — 4A M0, patch 282, ADR-0003 §12.28.
//
//  `anUntrustworthyReadingNeverReadsAsAnEmptyStore` is the one with teeth, and
//  it is the reason this type exists rather than a screen that counts things.
//  `HealthStore.workouts(from:to:)` returns `[]` on a denial, a timeout and an
//  empty store alike. A diagnostic that reported "Health has nothing" when the
//  truth was "the query never ran" would retire Strava on the strength of a
//  permissions bug — and the zeros would look exactly like an answer.
//
//  `aDayTheAppHasAndHealthDoesNotIsTheAnswer` is the finding M0 was asked for:
//  every one of those days is a training day the disconnect would destroy with
//  nothing to put in its place.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct HealthCoverageTests {

    // MARK: Fixtures

    private func workout(_ dayKey: String,
                         sport: Discipline? = .run,
                         distanceM: Double? = 10_000,
                         hr: Double? = 148,
                         sources: [String] = ["Bruno's Apple Watch"],
                         minute: Int = 7 * 60,
                         hrBand: (Double, Double)? = (96, 178),
                         hasRoute: Bool? = nil) -> HealthWorkout {
        let start = DayKey.date(dayKey) ?? Date(timeIntervalSince1970: 0)
        return HealthWorkout(id: UUID().uuidString,
                             start: start,
                             end: start.addingTimeInterval(3600),
                             dayKey: dayKey,
                             sport: sport,
                             rawType: "Running",
                             durationSeconds: 3600,
                             activeSeconds: nil,
                             distanceM: distanceM,
                             averageHeartRate: hr,
                             sources: sources,
                             hrMin: hrBand?.0,
                             hrMax: hrBand?.1,
                             hasRoute: hasRoute,
                             startMinuteOfDay: minute)
    }

    /// A summary pushed back by Strava: one heart-rate value, so the band is
    /// flat. This is what 285 exists to count.
    private func pushedSummary(_ dayKey: String,
                               distanceM: Double? = nil,
                               hasRoute: Bool? = false) -> HealthWorkout {
        workout(dayKey, distanceM: distanceM, hr: 141, sources: ["Strava"],
                hrBand: (141, 141), hasRoute: hasRoute)
    }

    private func activity(_ dayKey: String) -> Activity {
        Activity(id: UUID().uuidString, name: "Morning Run", sportType: "Run",
                 startLocal: "\(dayKey)T07:00:00", distance: 10_000,
                 movingTime: 3600, elapsedTime: 3700,
                 elevationGain: 40, averageHeartrate: 148, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 4.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "\(dayKey)T05:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func build(_ health: [HealthWorkout],
                       _ activities: [Activity],
                       months: [String] = ["2025-07"],
                       reading: HealthCoverage.Reading = .read) -> HealthCoverage.Report {
        HealthCoverage.build(health: health, activities: activities,
                             months: months, reading: reading,
                             generated: "test")
    }

    // MARK: The window

    @Test("The month list runs from the cutoff to the month it is asked about")
    func theMonthListSpansTheWindow() {
        let now = DayKey.date("2026-01-14") ?? Date()
        let keys = HealthCoverage.monthKeys(from: "2025-07-01", now: now)
        #expect(keys.first == "2025-07")
        #expect(keys.last == "2026-01", "the current month must be included, part-done")
        #expect(keys.count == 7)
        #expect(keys.contains("2025-12"))
    }

    @Test("A malformed cutoff returns nothing rather than spinning")
    func aMalformedCutoffIsEmpty() {
        #expect(HealthCoverage.monthKeys(from: "oops", now: Date()).isEmpty)
    }

    // MARK: The reading

    /// THE ONE WITH TEETH.
    @Test("An untrustworthy reading never reads as an empty store")
    func anUntrustworthyReadingNeverReadsAsAnEmptyStore() {
        for reading: HealthCoverage.Reading in [.unavailable, .neverAsked,
                                                .noUsageDescription,
                                                .failed("it timed out")] {
            let r = build([], [activity("2025-07-04")], reading: reading)

            #expect(!reading.isTrustworthy)
            // The headline must be the reading, NOT "0 sessions found". The
            // report holds a stored activity and no Health workout, which is
            // the exact shape a real shortfall would have.
            #expect(r.headline == reading.line)
            // And the paste stops before the table, so nobody can screenshot
            // an empty grid and call it a measurement.
            let text = HealthCoverage.text(r)
            #expect(!text.contains("month    |"))
            #expect(text.contains("NOT MEASURED"))
        }
    }

    @Test("A read that answered says so and prints the table")
    func aTrustworthyReadingPrintsTheTable() {
        let r = build([workout("2025-07-04")], [activity("2025-07-04")])
        #expect(r.reading.isTrustworthy)
        let text = HealthCoverage.text(r)
        #expect(text.contains("month    |"))
        #expect(text.contains("2025-07"))
    }

    // MARK: Days

    @Test("A day on both sides is covered")
    func aDayOnBothSidesIsCovered() {
        let r = build([workout("2025-07-04")], [activity("2025-07-04")])
        let t = r.total
        #expect(t.days == 1)
        #expect(t.storedDays == 1)
        #expect(t.daysBoth == 1)
        #expect(t.daysStoredOnly == 0)
        #expect(r.monthsWithLoss.isEmpty)
    }

    /// THE FINDING M0 WAS ASKED FOR.
    @Test("A day the app has and Health does not is the answer")
    func aDayTheAppHasAndHealthDoesNotIsTheAnswer() {
        let r = build([workout("2025-07-04")],
                      [activity("2025-07-04"), activity("2025-07-19")])
        let t = r.total
        #expect(t.storedDays == 2)
        #expect(t.days == 1)
        #expect(t.daysStoredOnly == 1)
        #expect(r.monthsWithLoss.map(\.month) == ["2025-07"])
        #expect(r.headline.contains("1 training day is in the app and not in Health"))
        #expect(r.headline.contains("across 1 month."), "one month, not '1 months'")
    }

    @Test("Two sessions on one day are two sessions and one day")
    func twoSessionsOnOneDayIsOneDay() {
        let r = build([workout("2025-07-04"), workout("2025-07-04", sport: .swim)],
                      [activity("2025-07-04")])
        let t = r.total
        #expect(t.sessions == 2)
        #expect(t.days == 1)
        #expect(t.runs == 1)
        #expect(t.swims == 1)
    }

    @Test("A day only Health has is reported and is not a loss")
    func aDayOnlyHealthHasIsNotALoss() {
        let r = build([workout("2025-07-04"), workout("2025-07-06")],
                      [activity("2025-07-04")])
        let t = r.total
        #expect(t.daysHealthOnly == 1)
        #expect(t.daysStoredOnly == 0)
        #expect(r.monthsWithLoss.isEmpty, "Health knowing more is not a shortfall")
    }

    // MARK: Naming the days — 283

    /// THE POINT OF 283. "3 training days" is a number somebody has to act on,
    /// and acting on it means opening those days in the app.
    @Test("The days the app has and Health does not are named, not counted")
    func theMissingDaysAreNamed() {
        let r = build([workout("2025-07-04")],
                      [activity("2025-07-04"), activity("2025-07-19"),
                       activity("2025-07-11")])
        // SORTED, so two runs over unchanged data give the same report.
        #expect(r.total.datesStoredOnly == ["2025-07-11", "2025-07-19"])
        #expect(r.total.daysStoredOnly == 2, "the count is derived from the list")
    }

    @Test("The dates reach the paste, all of them")
    func theDatesReachThePaste() {
        let r = build([workout("2025-07-04")],
                      [activity("2025-07-04"), activity("2025-07-19")])
        let text = HealthCoverage.text(r)
        #expect(text.contains("2025-07-19"))
        #expect(text.contains("and NOT in Health"))
    }

    @Test("Days Health has and the app does not are named separately")
    func theExtraDaysAreNamedSeparately() {
        let r = build([workout("2025-07-04"), workout("2025-07-06")],
                      [activity("2025-07-04")])
        #expect(r.total.datesHealthOnly == ["2025-07-06"])
        #expect(r.total.datesStoredOnly.isEmpty)
    }

    /// The count is computed from the list, so a total that summed one and set
    /// the other cannot drift. That was one edit away from happening.
    @Test("Totals concatenate the dates rather than counting them twice")
    func totalsConcatenateTheDates() {
        let r = build([],
                      [activity("2025-07-04"), activity("2025-08-02")],
                      months: ["2025-07", "2025-08"])
        #expect(r.total.datesStoredOnly == ["2025-07-04", "2025-08-02"])
        #expect(r.total.daysStoredOnly == 2)
    }

    // MARK: Both sides counted the same way — 283

    /// The first report counted Health by discipline and the app only in
    /// total, so "does Health have my commutes?" had no answer on the screen.
    @Test("The app is counted by discipline, like Health")
    func theAppIsCountedByDiscipline() {
        let acts = [activity("2025-07-04"), activity("2025-07-05")]
        let r = build([], acts)
        let t = r.total
        #expect(t.storedSessions == 2)
        #expect(t.storedRuns == 2, "both fixtures are runs")
        #expect(t.storedRides == 0)
        #expect(t.storedRuns + t.storedRides + t.storedSwims
                + t.storedStrength + t.storedOther == t.storedSessions,
                "the split must account for every stored session")
    }

    @Test("The discipline comparison reaches the paste")
    func theDisciplineTableReachesThePaste() {
        let r = build([workout("2025-07-04")], [activity("2025-07-04")])
        let text = HealthCoverage.text(r)
        #expect(text.contains("discipline | health |"))
        #expect(text.contains("ride"))
    }

    // MARK: Who wrote it

    @Test("A session Strava alone wrote is counted apart")
    func stravaAloneIsCountedApart() {
        let r = build([workout("2025-07-04", sources: ["Strava"]),
                       workout("2025-07-05", sources: ["Bruno's Apple Watch", "Strava"]),
                       workout("2025-07-06", sources: ["Bruno's Apple Watch"])],
                      [])
        let t = r.total
        #expect(t.stravaWrote == 2, "two of the three name Strava somewhere")
        #expect(t.stravaAlone == 1, "only one has nothing else behind it")
    }

    @Test("The writer test does not depend on how the app spelled its name")
    func theWriterTestIsCaseInsensitive() {
        let r = build([workout("2025-07-04", sources: ["strava"]),
                       workout("2025-07-05", sources: ["Strava "])], [])
        #expect(r.total.stravaAlone == 2)
    }

    @Test("A session with no writers at all is not Strava's")
    func noWritersIsNotStravas() {
        let r = build([workout("2025-07-04", sources: [])], [])
        #expect(r.total.stravaWrote == 0)
        #expect(r.total.stravaAlone == 0)
    }

    // MARK: Thinness of the Strava-alone set — 285

    @Test("A flat heart-rate band is one value, not samples")
    func aFlatBandIsNotSamples() {
        let summary = pushedSummary("2025-07-04")
        let recorded = workout("2025-07-05")
        #expect(!summary.hasVaryingHeartRate, "141 to 141 is one reading")
        #expect(recorded.hasVaryingHeartRate)
    }

    @Test("No heart rate at all is not varying heart rate")
    func noHeartRateIsNotVarying() {
        let w = workout("2025-07-04", hr: nil, hrBand: nil)
        #expect(!w.hasVaryingHeartRate)
    }

    @Test("Only sessions Strava alone wrote are censused")
    func onlyStravaAloneIsCensused() {
        let r = build([pushedSummary("2025-07-04"),
                       workout("2025-07-05", sources: ["Bruno's Apple Watch", "Strava"]),
                       workout("2025-07-06")], [])
        #expect(r.thinness.sessions == 1, "the co-written one is not Strava's alone")
    }

    /// THE ONE WITH TEETH, and the same shape as the reading guard one level
    /// up: a census that did not run must not read as a census that found
    /// nothing.
    @Test("Routes not asked about never read as routes not found")
    func routesNotAskedAboutAreNotRoutesNotFound() {
        let notAsked = build([pushedSummary("2025-07-04", hasRoute: nil)], [])
        #expect(notAsked.thinness.sessions == 1)
        #expect(notAsked.thinness.routesRead == false)
        #expect(notAsked.thinness.withRoute == 0)
        #expect(notAsked.thinness.line.contains("routes not measured"))
        // And the paste says so out loud rather than printing a bare zero.
        #expect(HealthCoverage.text(notAsked).contains("Routes were NOT measured"))

        let asked = build([pushedSummary("2025-07-04", hasRoute: false)], [])
        #expect(asked.thinness.routesRead)
        #expect(asked.thinness.withRoute == 0)
        #expect(!HealthCoverage.text(asked).contains("Routes were NOT measured"))
    }

    @Test("A shell is a session with none of the three")
    func aShellHasNoneOfTheThree() {
        let r = build([pushedSummary("2025-07-04", hasRoute: false)], [])
        #expect(r.thinness.shells == 1)
        #expect(r.thinness.withRoute == 0)
        #expect(r.thinness.withVaryingHeartRate == 0)
        #expect(r.thinness.withDistance == 0)
    }

    @Test("A Strava-written session that carries things is not a shell")
    func aFullSessionIsNotAShell() {
        let r = build([pushedSummary("2025-07-04", distanceM: 8_400, hasRoute: true)], [])
        #expect(r.thinness.withRoute == 1)
        #expect(r.thinness.withDistance == 1)
        #expect(r.thinness.shells == 0)
    }

    @Test("Merging keeps the wider heart-rate band")
    func mergingKeepsTheWiderBand() {
        let watch = workout("2025-07-04", sources: ["Bruno's Apple Watch"])
        let pushed = pushedSummary("2025-07-04", distanceM: 10_000)
        let merged = HealthWorkout.merged(watch, pushed)
        #expect(merged.hasVaryingHeartRate,
                "Health does hold samples for this session, from the watch copy")
        #expect(!merged.stravaAlone, "two writers is not Strava alone")
    }

    // MARK: Thinness

    @Test("Distance and heart rate are counted, not assumed")
    func thinnessIsCounted() {
        let r = build([workout("2025-07-04"),
                       workout("2025-07-05", distanceM: nil, hr: nil)], [])
        let t = r.total
        #expect(t.sessions == 2)
        #expect(t.withDistance == 1)
        #expect(t.withHeartRate == 1)
    }

    // MARK: Bucketing

    @Test("Anything outside the window is ignored rather than folded in")
    func outsideTheWindowIsIgnored() {
        let r = build([workout("2025-06-30"), workout("2025-07-04")],
                      [activity("2025-06-30"), activity("2025-07-04")],
                      months: ["2025-07"])
        let t = r.total
        #expect(t.sessions == 1)
        #expect(t.storedSessions == 1)
        #expect(t.daysStoredOnly == 0)
    }

    @Test("Months are summed, and a month with nothing still appears")
    func everyMonthAppears() {
        let r = build([workout("2025-08-02")],
                      [activity("2025-07-04"), activity("2025-08-02")],
                      months: ["2025-07", "2025-08"])
        #expect(r.months.map(\.month) == ["2025-07", "2025-08"])
        let july = r.months[0]
        #expect(july.sessions == 0)
        #expect(july.storedSessions == 1)
        #expect(july.daysStoredOnly == 1)
        #expect(r.total.storedSessions == 2)
        #expect(r.total.daysStoredOnly == 1)
    }
}
