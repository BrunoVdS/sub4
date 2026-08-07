//
//  LoadSeriesTests.swift
//  Sub4CoreTests
//
//  D6c slice 3, part one — patch 314, ADR-0003 §12.58.
//
//  THIS IS THE FIRST TEST THE DAY WALK HAS EVER HAD, and that is the argument
//  for the extraction rather than a side effect of it.
//
//  `LoadStore.recompute` read eight singletons — the activity store, the detail
//  store, the constants, the athlete, the notes, the plan, the matcher and
//  Apple Health. A test would have had to stand all eight up, so there was
//  never one. `PMC.build` has twelve tests because it was already a pure
//  function of its input. This is now the same shape.
//
//  `everyDayIsPresentIncludingTheEmptyOnes` is the one with teeth. The fitness
//  curve is an exponential moving average and an average is only defined over a
//  series with no holes — treating "no row" as "no load" is the single most
//  common way a home-rolled fitness curve goes wrong, and it shortens the
//  window silently.
//
//  The four day states are the second thing worth pinning. A rest day is a real
//  zero and belongs in the curve; a gap is not a zero and a curve drawn across
//  one is wrong for six weeks afterwards. Both produce a `load` of 0, so the
//  ONLY thing that tells them apart is the state — which is exactly the shape
//  a refactor can flatten without any number moving.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct LoadSeriesTests {

    // MARK: Fixtures

    /// A ride with a heart rate — scores from the session average.
    private func scorable(_ id: String, on day: String,
                          hr: Double? = 130) -> Activity {
        Activity(id: id, name: "Ride", sportType: "Ride",
                 startLocal: "\(day)T09:00:00", distance: 24_300,
                 movingTime: 3_600, elapsedTime: 3_900,
                 elevationGain: 100, averageHeartrate: hr, isTrainer: false,
                 maxHeartrate: hr == nil ? nil : 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: "\(day)T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7_200)
    }

    /// A ride with no heart rate, no power and no trace. Load-eligible — 24 km
    /// is well over the ride threshold — and nothing can score it.
    private func unscorable(_ id: String, on day: String) -> Activity {
        scorable(id, on: day, hr: nil)
    }

    /// Constants that let the engine score from an average heart rate.
    private func inputs(streams: [String: ActivityStreams] = [:],
                        hrMax: Int? = 185,
                        hrRest: Int? = 48) -> LoadSeries.Inputs {
        LoadSeries.Inputs(hrMax: hrMax,
                          hrRest: { _ in hrRest },
                          w: 1.92,
                          ftp: nil,
                          powerFactor: nil,
                          streams: streams)
    }

    private func byDay(_ activities: [Activity]) -> [String: [Activity]] {
        ActivityRoster.byDay(activities)
    }

    // MARK: THE ONE WITH TEETH

    /// An average is only defined over a series with no holes. A week with one
    /// session in it is seven points, not one.
    @Test("Every day is present, including the empty ones")
    func everyDayIsPresentIncludingTheEmptyOnes() {
        let days = LoadSeries.build(from: "2026-04-20", to: "2026-04-26",
                                    byDay: byDay([scorable("a", on: "2026-04-22")]),
                                    inputs: inputs())
        #expect(days.count == 7, "got \(days.count)")
        #expect(days.map(\.dayKey) == ["2026-04-20", "2026-04-21", "2026-04-22",
                                       "2026-04-23", "2026-04-24", "2026-04-25",
                                       "2026-04-26"])
        #expect(days.filter { $0.state == .rest }.count == 6)
    }

    @Test("A single day is a single point")
    func oneDayIsOnePoint() {
        let days = LoadSeries.build(from: "2026-04-20", to: "2026-04-20",
                                    byDay: [:], inputs: inputs())
        #expect(days.count == 1)
        #expect(days[0].state == .rest)
    }

    @Test("A range that runs backwards produces nothing")
    func abackwardsRangeIsEmpty() {
        let days = LoadSeries.build(from: "2026-04-26", to: "2026-04-20",
                                    byDay: [:], inputs: inputs())
        #expect(days.isEmpty)
    }

    // MARK: The four states

    /// A rest day is a REAL ZERO and belongs in the curve. Load 0, state rest.
    @Test("A day with nothing on it is rest, and a real zero")
    func nothingIsRest() {
        let days = LoadSeries.build(from: "2026-04-20", to: "2026-04-20",
                                    byDay: [:], inputs: inputs())
        let d = days[0]
        #expect(d.state == .rest)
        #expect(d.load == 0)
        #expect(d.workouts.isEmpty)
    }

    @Test("A day where everything scored is measured")
    func everythingScoredIsMeasured() {
        let days = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22"),
                          scorable("b", on: "2026-04-22")]),
            inputs: inputs())
        let d = days[0]
        #expect(d.state == .measured)
        #expect(d.workouts.count == 2)
        #expect(d.load > 0)
        #expect(d.load == d.scored.reduce(0) { $0 + $1.trimp })
    }

    /// A GAP IS NOT A ZERO, and this is the distinction the whole type exists
    /// for. Both produce `load == 0`, so the state is the only thing that can
    /// tell them apart — and a curve drawn across a gap is wrong for six weeks.
    @Test("A day where nothing could be scored is a gap, not a rest")
    func nothingScoredIsAGap() {
        let days = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([unscorable("a", on: "2026-04-22")]),
            inputs: inputs())
        let d = days[0]
        #expect(d.state == .gap, "got \(d.state)")
        #expect(d.load == 0, "the same zero a rest day has")
        #expect(d.workouts.count == 1, "and something did happen")
        #expect(d.unscored.count == 1)
    }

    @Test("A day where some scored and some did not is partial")
    func someScoredIsPartial() {
        let days = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22"),
                          unscorable("b", on: "2026-04-22")]),
            inputs: inputs())
        let d = days[0]
        #expect(d.state == .partial)
        #expect(d.scored.count == 1)
        #expect(d.unscored.count == 1)
    }

    /// ONLY THE SCORED TRIMPS ARE SUMMED. A day's total that quietly included a
    /// zero from something nothing could score would read identically to a
    /// lighter day, which is the loss the state is there to prevent.
    @Test("A partial day's total counts only what scored")
    func aPartialDayCountsOnlyWhatScored() {
        let alone = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22")]),
            inputs: inputs())
        let withGhost = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22"),
                          unscorable("b", on: "2026-04-22")]),
            inputs: inputs())
        #expect(alone[0].load == withGhost[0].load,
                "the unscorable session must not move the number")
        #expect(alone[0].state != withGhost[0].state,
                "but it must move the state")
    }

    // MARK: The inputs reach the engine

    /// Without a maximum and a resting rate there is no TRIMP to compute, so a
    /// ride that would otherwise score becomes a gap. This is the constants
    /// arriving, proved by their absence.
    @Test("Missing constants turn a scorable day into a gap")
    func missingConstantsProduceAGap() {
        let byOne = byDay([scorable("a", on: "2026-04-22")])
        let withConstants = LoadSeries.build(from: "2026-04-22", to: "2026-04-22",
                                             byDay: byOne, inputs: inputs())
        let without = LoadSeries.build(from: "2026-04-22", to: "2026-04-22",
                                       byDay: byOne,
                                       inputs: inputs(hrMax: nil, hrRest: nil))
        #expect(withConstants[0].state == .measured)
        #expect(without[0].state == .gap,
                "no maximum and no resting rate is not a rest day")
    }

    /// The row carries the constants it was computed under, so staleness is a
    /// direct comparison rather than a version lookup.
    @Test("Each row records the constants it was scored under")
    func theRowCarriesItsConstants() {
        let days = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22")]),
            inputs: inputs(hrMax: 191, hrRest: 44))
        let w = days[0].workouts[0]
        #expect(w.hrMaxUsed == 191)
        #expect(w.hrRestUsed == 44)
        #expect(w.engineVersion == LoadEngine.version)
    }

    /// sRPE is CARRIED, never summed. It reaches the row and does not reach the
    /// day's total.
    @Test("sRPE reaches the row and not the day's load")
    func srpeIsCarriedNotSummed() {
        var i = inputs()
        i.srpe = ["a": 420]
        let days = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22")]),
            inputs: i)
        let plain = LoadSeries.build(
            from: "2026-04-22", to: "2026-04-22",
            byDay: byDay([scorable("a", on: "2026-04-22")]),
            inputs: inputs())
        #expect(days[0].workouts[0].srpe == 420)
        #expect(days[0].load == plain[0].load, "carried, never summed")
    }

    /// Apple Health's heart rate is keyed by activity id and is what makes a
    /// session with no Strava heart rate scorable at all — engine version 4's
    /// whole reason for existing.
    @Test("A Health heart rate rescues a session Strava could not score")
    func healthRescuesAnUnscorableSession() {
        let one = byDay([unscorable("a", on: "2026-04-22")])
        var i = inputs()
        i.healthAverageHR = ["a": 138]
        let rescued = LoadSeries.build(from: "2026-04-22", to: "2026-04-22",
                                       byDay: one, inputs: i)
        let notRescued = LoadSeries.build(from: "2026-04-22", to: "2026-04-22",
                                          byDay: one, inputs: inputs())
        #expect(notRescued[0].state == .gap)
        #expect(rescued[0].state == .measured, "got \(rescued[0].state)")
        #expect(rescued[0].load > 0)
    }

    /// The activity is filtered by `isLoadEligible`, which is deliberately
    /// wider than `isPlanEligible` — a 12 km walk satisfies nothing in the plan
    /// and is still an hour and a half on your feet. A 2 km walk is neither.
    @Test("An activity too small to count is not on the day at all")
    func anIneligibleActivityIsNotADay() {
        let stroll = Activity(id: "w", name: "Walk", sportType: "Walk",
                              startLocal: "2026-04-22T09:00:00", distance: 2_000,
                              movingTime: 1_800, elapsedTime: 1_800,
                              elevationGain: 5, averageHeartrate: 95,
                              isTrainer: false, maxHeartrate: 110, gearId: nil,
                              maxSpeed: 2.0, deviceWatts: false, averageWatts: nil,
                              startUTC: "2026-04-22T07:00:00Z",
                              startLat: nil, startLon: nil,
                              timeZoneIdentifier: "Europe/Brussels",
                              startOffsetSeconds: 7_200)
        let days = LoadSeries.build(from: "2026-04-22", to: "2026-04-22",
                                    byDay: byDay([stroll]), inputs: inputs())
        #expect(days[0].state == .rest, "it is not a gap — nothing eligible happened")
        #expect(days[0].workouts.isEmpty)
    }

    // MARK: The guard, and the reason it exists

    /// An unparseable key used to leave the day unchanged, which appended the
    /// same day three thousand times — duplicate `ForEach` ids and a day
    /// counted three thousand times in every total. It fails closed.
    @Test("An unparseable day key stops the walk rather than repeating it")
    func anUnparseableKeyStops() {
        let days = LoadSeries.build(from: "not-a-day", to: "zzzz",
                                    byDay: [:], inputs: inputs())
        #expect(days.count == 1, "one point for the bad key, then it stops")
    }

    @Test("The walk is bounded however long the range is")
    func theWalkIsBounded() {
        let days = LoadSeries.build(from: "2000-01-01", to: "2099-12-31",
                                    byDay: [:], inputs: inputs())
        #expect(days.count == LoadSeries.maximumDays)
    }

    @Test("The day after the last of a month is the first of the next")
    func nextDayRollsOver() {
        #expect(LoadSeries.nextDay("2026-04-30") == "2026-05-01")
        #expect(LoadSeries.nextDay("2026-12-31") == "2027-01-01")
        #expect(LoadSeries.nextDay("2028-02-28") == "2028-02-29", "a leap year")
        #expect(LoadSeries.nextDay("not-a-day") == nil)
    }

    // MARK: What the curve makes of it

    /// The series feeds `PMC.build`, which has its own twelve tests. This is
    /// the join: a week of rest after a week of training sheds fatigue faster
    /// than fitness, which is the whole model in one assertion.
    @Test("The series drives the curve it was built for")
    func theSeriesFeedsTheCurve() {
        var acts: [Activity] = []
        for d in 20...26 { acts.append(scorable("t\(d)", on: "2026-04-\(d)")) }
        let days = LoadSeries.build(from: "2026-04-20", to: "2026-05-03",
                                    byDay: byDay(acts), inputs: inputs())
        #expect(days.count == 14)

        let points = PMC.build(days)
        #expect(points.count == 14)
        let peak = points[6]
        let after = points[13]
        #expect(after.atl < peak.atl, "a week off sheds fatigue")
        #expect(after.ctl < peak.ctl)
        #expect((after.tsb ?? 0) > (peak.tsb ?? 0), "and freshness rises")
    }
}
