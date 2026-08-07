//
//  LoadParityTests.swift
//  Sub4CoreTests
//
//  D6c slice 3 — patch 315, groundwork §2.1, ADR-0003 §12.59.
//
//  THE NEGATIVE CONTROL, and for this slice it is the whole of the evidence.
//
//  Slices 1 and 2 could at least be sanity-checked by eye against the app.
//  Nobody can eyeball whether two four-hundred-day fitness curves agree, so the
//  only thing standing between a zero that is a result and a zero that is a
//  broken check is this file.
//
//  Both sides are built by the real `LoadSeries.build` from genuinely different
//  activity lists — one of them through the real `Sub4Import` and the real
//  `ActivityRepository`, the way the device does it.
//
//  `aPaddedTraceIsCaughtAsADifferentRung` is the one with teeth, and it is the
//  reason slice 3 was worth doing before its own inputs exist. D6a accepted a
//  loss in the traces — a stream shorter than the distance axis comes back
//  padded with zeros. `LoadEngine` scores from the trace when it can and falls
//  back to the session average when it cannot, so that loss can move a session
//  between rungs. This proves the comparison would say so.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct LoadParityTests {

    private nonisolated struct NoRows: Error {}

    private func ride(_ id: String, on day: String,
                      hr: Double? = 130, movingTime: Int = 3_600) -> Activity {
        Activity(id: id, name: "Ride", sportType: "Ride",
                 startLocal: "\(day)T09:00:00", distance: 24_300,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: hr, isTrainer: false,
                 maxHeartrate: hr == nil ? nil : 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: "\(day)T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7_200)
    }

    private func inputs(streams: [String: ActivityStreams] = [:]) -> LoadSeries.Inputs {
        LoadSeries.Inputs(hrMax: 185, hrRest: { _ in 48 }, w: 1.92,
                          ftp: nil, powerFactor: nil, streams: streams)
    }

    private func history() -> [Activity] {
        [ride("c", on: "2026-04-23"), ride("b", on: "2026-04-22"),
         ride("a", on: "2026-04-21")]
    }

    /// Through the real importer and the real reader, then settled — the twin
    /// exactly as the device builds it.
    private func imported(_ activities: [Activity]) throws -> [Activity] {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: activities, shoes: [])
        guard let rows = ActivityRepository.all(db).activities else { throw NoRows() }
        return ActivityRoster.settle(rows).activities
    }

    private func series(_ activities: [Activity],
                        streams: [String: ActivityStreams] = [:]) -> [DailyLoad] {
        LoadSeries.build(from: "2026-04-20", to: "2026-04-30",
                         byDay: ActivityRoster.byDay(activities),
                         inputs: inputs(streams: streams))
    }

    /// A trace the engine will actually integrate, built backwards from the
    /// two checks that reject one.
    ///
    /// `minCoverage` is 0.80 — every bin here carries a heart rate, so
    /// coverage is 1.0. `maxDurationDrift` is 0.25 — the integral's own
    /// seconds must land within a quarter of the activity's moving time, so
    /// the speed is solved for rather than guessed. A trace that misses either
    /// check is silently demoted to the session average, which would make this
    /// file's central test pass for the wrong reason.
    private func trace(_ id: String, samples: Int = 60, hr: Double = 150,
                       totalM: Double = 24_300,
                       seconds: Double = 3_600) -> ActivityStreams {
        let n = Double(samples)
        // `streamTrimp` bins by `total / (count - 0.5)` and sums `binWidth / v`.
        let speed = n * (totalM / (n - 0.5)) / seconds
        let distance = (0 ..< samples).map { Double($0) * (totalM / (n - 1)) }
        return ActivityStreams(activityId: id,
                               distanceM: distance,
                               heartRate: Array(repeating: hr, count: samples),
                               speed: Array(repeating: speed, count: samples),
                               altitude: nil, grade: nil, power: nil,
                               latitude: nil, longitude: nil,
                               fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    // MARK: The boring case

    @Test("The same activities produce the same series and the same curve")
    func identicalSeriesAgree() throws {
        let store = history()
        let twin = try imported(store)

        let r = LoadParity.compare(app: series(store), database: series(twin))
        #expect(r.appDays == r.databaseDays)
        #expect(r.daysCompared == 11, "the denominator")
        #expect(r.workoutsCompared == 3, "the deep denominator")
        #expect(r.daysWithDifferentState.isEmpty)
        #expect(r.daysWithDifferentLoad.isEmpty)
        #expect(r.workoutsWithDifferentSource.isEmpty)
        #expect(r.workoutsWithDifferentFigure.isEmpty)
        #expect(r.pointsWithDifferentFitness == 0)
        #expect(r.pointsCompared == 11)
        #expect(r.unexplained == 0)
        #expect(r.isHealthy)
    }

    /// Zero days against zero days agrees perfectly. `workoutsCompared` is in
    /// the guard too: four hundred rest days would satisfy a day count and
    /// describe no training at all.
    @Test("Comparing nothing is not agreement")
    func nothingComparedIsNotAgreement() {
        let empty = LoadParity.compare(app: [], database: [])
        #expect(empty.unexplained == 0, "nothing disagreed")
        #expect(!empty.lookedAtSomething)
        #expect(!empty.isHealthy)
        #expect(empty.summary.hasPrefix("nothing compared"))
    }

    /// The second half of that guard, and the one a day count alone would miss.
    @Test("A series of nothing but rest days is not a pass")
    func restDaysAloneAreNotAPass() {
        let r = LoadParity.compare(app: series([]), database: series([]))
        #expect(r.daysCompared == 11, "eleven days were walked")
        #expect(r.workoutsCompared == 0, "and no training was in them")
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy)
    }

    // MARK: THE ONE WITH TEETH

    /// D6a ACCEPTED A LOSS IN THE TRACES. `LoadEngine` scores from the trace
    /// when it has one and from the session average when it does not, so a
    /// trace the database could not carry moves a session between rungs — and
    /// the figure moves with it.
    ///
    /// Nothing before this patch could have said so: both sides would have
    /// held the same activity with every field agreeing.
    @Test("A trace the database lost is caught as a different rung")
    func aPaddedTraceIsCaughtAsADifferentRung() throws {
        let store = history()
        let twin = try imported(store)
        // The app has the trace for "a". The database does not.
        let withTrace = series(store, streams: ["a": trace("a")])
        let without = series(twin)

        let r = LoadParity.compare(app: withTrace, database: without)
        #expect(r.workoutsWithDifferentSource == ["a"],
                "got \(r.workoutsWithDifferentSource)")
        #expect(r.appTraces == 1, "the app really did score one from a trace")
        #expect(r.databaseTraces == 0, "and the database scored none")
        #expect(!r.isHealthy)
        // The rung moved, so the figure did too — but it is reported ONCE, as
        // a rung, because the rung is the cause and the figure is the effect.
        #expect(r.workoutsWithDifferentFigure.isEmpty,
                "a session on a different rung is not also a different figure")
    }

    @Test("Both sides scoring from a trace is not a difference")
    func aTraceOnBothSidesAgrees() throws {
        let store = history()
        let twin = try imported(store)
        let t = ["a": trace("a")]
        let r = LoadParity.compare(app: series(store, streams: t),
                                   database: series(twin, streams: t))
        #expect(r.workoutsWithDifferentSource.isEmpty)
        #expect(r.workoutsWithDifferentFigure.isEmpty)
        #expect(r.appTraces == r.databaseTraces)
        #expect(r.appTraces == 1, "and it really did score from one")
        #expect(r.isHealthy)
    }

    // MARK: The other negative controls

    /// A rest and a gap both carry a load of zero. The state is the only thing
    /// between them, and a curve drawn across a gap is wrong for six weeks.
    @Test("A day that is a gap on one side and a rest on the other is reported")
    func aGapAgainstARestIsReported() throws {
        // The database has a session nothing can score; the app has nothing.
        let twin = try imported(history() + [ride("x", on: "2026-04-25", hr: nil)])
        let r = LoadParity.compare(app: series(history()), database: series(twin))
        #expect(r.daysWithDifferentState == ["2026-04-25"])
        #expect(r.daysWithDifferentLoad.isEmpty,
                "both carry zero — the state is the only difference")
        #expect(!r.isHealthy)
    }

    @Test("A different total on one day is reported")
    func aDifferentTotalIsReported() throws {
        let twin = try imported(history())
        var store = history()
        store[2] = ride("a", on: "2026-04-21", movingTime: 7_200)

        let r = LoadParity.compare(app: series(store), database: series(twin))
        #expect(r.daysWithDifferentLoad == ["2026-04-21"])
        #expect(r.workoutsWithDifferentFigure == ["a"])
        #expect(r.workoutsWithDifferentSource.isEmpty, "the same rung, a different number")
        #expect(!r.isHealthy)
    }

    /// The curve is compared over the whole series, not only its last point.
    /// A difference in April that has decayed by August would be invisible in
    /// the headline and is still a difference.
    @Test("A difference early in the series moves the curve and is counted")
    func anEarlyDifferenceMovesTheCurve() throws {
        let twin = try imported(history())
        var store = history()
        store[2] = ride("a", on: "2026-04-21", movingTime: 7_200)

        let r = LoadParity.compare(app: series(store), database: series(twin))
        #expect(r.pointsWithDifferentFitness > 0, "got \(r.pointsWithDifferentFitness)")
        #expect(r.pointsCompared == 11, "the denominator beside it")
        #expect((r.appFitness ?? 0) > (r.databaseFitness ?? 0),
                "twice the moving time is more fitness")
    }

    @Test("Two series of different lengths is itself a difference")
    func differentLengthsAreADifference() throws {
        let short = LoadSeries.build(from: "2026-04-20", to: "2026-04-25",
                                     byDay: ActivityRoster.byDay(history()),
                                     inputs: inputs())
        let r = LoadParity.compare(app: series(history()), database: short)
        #expect(r.appDays != r.databaseDays)
        #expect(r.unexplained > 0, "a shorter twin is not a clean twin")
        #expect(!r.isHealthy)
    }

    // MARK: What the screen and the paste get

    @Test("Every line is there when everything agrees")
    func everyLineIsThereWhenEverythingAgrees() throws {
        let store = history()
        let r = LoadParity.compare(app: series(store),
                                   database: series(try imported(store)))
        let lines = r.diagnosticLines
        #expect(lines.count == 16, "got \(lines.count)")
        #expect(lines.first == "Load parity: 11 days, 3 sessions")
        #expect(lines.contains("  days with a different state: 0"))
        #expect(lines.contains("  sessions scored from a different rung: 0"))
        #expect(lines.contains("  unexplained differences: 0"))
        #expect(lines.contains("  held from the app: \(LoadParity.heldFromTheApp)"),
                "the limit is printed, not implied")
    }

    /// A SLICE THAT COULD NOT RUN IS NOT A PASS. `load` is nil when the app's
    /// own series has never been built, and every version of this screen that
    /// treated a missing answer as a clean one has had to be corrected.
    @Test("A missing load slice fails the run rather than passing it")
    func aMissingSliceIsNotAPass() throws {
        let store = history()
        let twin = try imported(store)
        let activities = ActivityParity.compare(store: store, databaseRows: twin,
                                                databaseSkipped: 0)
        let volume = VolumeParity.compare(store: store, database: twin)
        #expect(activities.isHealthy)
        #expect(volume.isHealthy)

        let withoutLoad = ShadowParity.Outcome.ran(activities: activities,
                                                   volume: volume, load: nil)
        #expect(!withoutLoad.isHealthy, "no answer is not zero differences")
        #expect(withoutLoad.line.contains("differences"))
        #expect(withoutLoad.diagnosticLines
                    .contains("Load parity: the app's own load series was not built"))
    }
}
