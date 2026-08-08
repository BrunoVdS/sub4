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

    /// PATCH 321. A genuinely healthy match slice — one run, one planned run,
    /// matched on both sides. Handed an empty pair instead, the assertion above
    /// would pass with one more failing slice than it means to test, which is
    /// 315a's defect.
    private func matchesAgree() -> MatchParity.Report {
        let a = Activity(id: "m1", name: "Morning Run", sportType: "Run",
                         startLocal: "2026-04-20T09:00:00", distance: 10_000,
                         movingTime: 3_300, elapsedTime: 3_400,
                         elevationGain: nil, averageHeartrate: nil,
                         isTrainer: nil, maxHeartrate: nil, gearId: nil,
                         maxSpeed: nil, deviceWatts: nil, averageWatts: nil,
                         startUTC: "2026-04-20T07:00:00Z", startLat: nil,
                         startLon: nil, timeZoneIdentifier: nil,
                         startOffsetSeconds: 7200)
        let s = Session(uid: "s1", weekUid: "w1", day: "Mon",
                        date: "2026-04-20", discipline: .run, intensity: nil,
                        title: "10 km", detail: nil, fuel: nil, prep: nil,
                        seq: 0, swimDetail: nil, strengthDetail: nil)
        let day = MatchResolver.day(sessions: [s], activities: [a],
                                    decisions: [:], dayKey: "2026-04-20")
        return MatchParity.compare(app: ["2026-04-20": day],
                                   database: ["2026-04-20": day])
    }

    /// PATCH 320. One detail with enough splits to answer a pace, so the
    /// detail slice in `aMissingSliceIsNotAPass` is genuinely healthy rather
    /// than vacuously so.
    private func detail(_ id: String = "a") -> ActivityDetail {
        ActivityDetail(
            activityId: id, calories: nil, descriptionText: nil,
            averageCadence: nil, averageWatts: nil, maxWatts: nil,
            deviceName: nil, polyline: nil,
            splits: (1...5).map {
                ActivityDetail.Split(index: $0, distanceM: 1_000,
                                     movingTime: 330 + $0, elapsedTime: 335 + $0,
                                     elevationDiff: 4, averageHR: 150)
            },
            bestEfforts: [], laps: [], fetched: Date(timeIntervalSince1970: 1))
    }

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

    /// Five zones against the same 185/48. Held identical on both sides — see
    /// `LoadParity`'s header on why the boundaries must not be a variable.
    private let zones: [AthleteStore.HRZone] = [
        .init(index: 1, min: 0, max: 129),
        .init(index: 2, min: 130, max: 148),
        .init(index: 3, min: 149, max: 157),
        .init(index: 4, min: 158, max: 166),
        .init(index: 5, min: 167, max: nil)]

    /// Z2 ends at 149 and Z3 starts at 150, so the integer boundary the
    /// histogram rounds to is also a zone boundary. That is the only place the
    /// histogram and the integral come apart — see
    /// `aRoundingDifferenceMovesAZone`.
    private let boundaryZones: [AthleteStore.HRZone] = [
        .init(index: 1, min: 0, max: 129),
        .init(index: 2, min: 130, max: 149),
        .init(index: 3, min: 150, max: 157),
        .init(index: 4, min: 158, max: 166),
        .init(index: 5, min: 167, max: nil)]

    /// Every comparison names its own `today`. A test that reads the machine's
    /// clock passes on the machine that wrote it — §12.48.5.
    private func compared(_ app: [DailyLoad],
                          _ database: [DailyLoad]) -> LoadParity.Report {
        LoadParity.compare(app: app, database: database,
                           zones: zones, today: "2026-04-30")
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
    ///
    /// `overriding` replaces the heart rate on named bins. Used by
    /// `aRoundingDifferenceMovesAZone` to shift ONE bin by two hundredths of a
    /// beat — enough to cross an integer boundary in the histogram and not
    /// enough to move the TRIMP past its tolerance.
    private func trace(_ id: String, samples: Int = 60, hr: Double = 150,
                       overriding: [Int: Double] = [:],
                       totalM: Double = 24_300,
                       seconds: Double = 3_600) -> ActivityStreams {
        let n = Double(samples)
        // `streamTrimp` bins by `total / (count - 0.5)` and sums `binWidth / v`.
        let speed = n * (totalM / (n - 0.5)) / seconds
        let distance = (0 ..< samples).map { Double($0) * (totalM / (n - 1)) }
        let rates = (0 ..< samples).map { overriding[$0] ?? hr }
        return ActivityStreams(activityId: id,
                               distanceM: distance,
                               heartRate: rates,
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

        let r = compared(series(store), series(twin))
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
        let empty = compared([], [])
        #expect(empty.unexplained == 0, "nothing disagreed")
        #expect(!empty.lookedAtSomething)
        #expect(!empty.isHealthy)
        #expect(empty.summary.hasPrefix("nothing compared"))
    }

    /// The second half of that guard, and the one a day count alone would miss.
    @Test("A series of nothing but rest days is not a pass")
    func restDaysAloneAreNotAPass() {
        let r = compared(series([]), series([]))
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

        let r = compared(withTrace, without)
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
        let r = compared(series(store, streams: t), series(twin, streams: t))
        #expect(r.workoutsWithDifferentSource.isEmpty)
        #expect(r.workoutsWithDifferentFigure.isEmpty)
        #expect(r.appTraces == r.databaseTraces)
        #expect(r.appTraces == 1, "and it really did score from one")
        #expect(r.isHealthy)
    }

    // MARK: THE SHAPE UNDER THE NUMBER — patch 316

    /// THE ONE 316 EXISTS FOR, and it is narrow on purpose.
    ///
    /// The histogram DETERMINES the TRIMP — same walk, same bins — so a
    /// redistribution large enough to see moves both, and 315 already caught
    /// those. The one place they come apart is that the integral uses the exact
    /// heart rate and the histogram ROUNDS it.
    ///
    /// One bin of sixty, moved from 149.49 to 149.51. The bucket crosses from
    /// 149 to 150; the TRIMP moves about 0.0015, under the 0.01 tolerance. With
    /// Z2 ending at 149 and Z3 starting at 150, a minute of the athlete's year
    /// changes zone and every figure 315 compares still agrees.
    @Test("A rounding difference too small to move the load still moves a zone")
    func aRoundingDifferenceMovesAZone() throws {
        let store = history()
        let twin = try imported(store)
        let below = trace("a", overriding: [0: 149.49])
        let above = trace("a", overriding: [0: 149.51])

        let r = LoadParity.compare(app: series(store, streams: ["a": below]),
                                   database: series(twin, streams: ["a": above]),
                                   zones: boundaryZones, today: "2026-04-30")

        #expect(r.workoutsWithDifferentSource.isEmpty, "the same rung")
        #expect(r.workoutsWithDifferentFigure.isEmpty,
                "and the load agrees, within tolerance — this is 315's blind spot")
        #expect(r.hrBucketsCompared == 2,
                "the union of both sides' heart rates — 149 and 150")
        #expect(r.workoutsWithDifferentHistogram == ["a"],
                "got \(r.workoutsWithDifferentHistogram)")
        #expect(r.zonesDiffering.count == 2, "a minute crossed from Z2 to Z3")
        #expect(!r.isHealthy)
    }

    /// The same trace on both sides walks its buckets and finds nothing. The
    /// bucket count is what makes that a result rather than an absence.
    @Test("The same distribution is walked and agrees")
    func theSameShapeIsWalked() throws {
        let store = history()
        let twin = try imported(store)
        let t = ["a": trace("a")]
        let r = compared(series(store, streams: t), series(twin, streams: t))
        #expect(r.hrBucketsCompared == 1, "one heart rate, one bucket")
        #expect(r.workoutsWithDifferentHistogram.isEmpty)
        #expect(r.zonesDiffering.isEmpty)
        #expect(r.zoneTracedApp == 1)
        #expect(r.zoneTracedDatabase == 1)
        #expect(r.isHealthy)
    }

    /// A session the card leaves out is a figure on the card, so it is
    /// compared. Both sides here score from the session average, so neither
    /// carries a distribution and both count it as left out.
    @Test("Sessions the zone card leaves out are counted on both sides")
    func untracedSessionsAreCounted() throws {
        let store = history()
        let twin = try imported(store)
        let r = compared(series(store), series(twin))
        #expect(r.zoneUntracedApp == 3, "three sessions, none with a trace")
        #expect(r.zoneUntracedDatabase == 3)
        #expect(r.hrBucketsCompared == 0, "and nothing to walk")
        #expect(r.isHealthy, "agreeing about having no distributions is agreement")
    }

    /// A history with no traces at all is a phone with no strap, not a broken
    /// comparison — so `lookedAtSomething` deliberately does not require
    /// buckets. The count is printed instead.
    @Test("No traces anywhere is a legitimate state")
    func noTracesIsNotAFailure() throws {
        let store = history()
        let r = compared(series(store), series(try imported(store)))
        #expect(r.hrBucketsCompared == 0)
        #expect(r.lookedAtSomething, "days and sessions were compared")
        #expect(r.isHealthy)
    }

    // MARK: The other negative controls

    /// A rest and a gap both carry a load of zero. The state is the only thing
    /// between them, and a curve drawn across a gap is wrong for six weeks.
    @Test("A day that is a gap on one side and a rest on the other is reported")
    func aGapAgainstARestIsReported() throws {
        // The database has a session nothing can score; the app has nothing.
        let twin = try imported(history() + [ride("x", on: "2026-04-25", hr: nil)])
        let r = compared(series(history()), series(twin))
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

        let r = compared(series(store), series(twin))
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

        let r = compared(series(store), series(twin))
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
        let r = compared(series(history()), short)
        #expect(r.appDays != r.databaseDays)
        #expect(r.unexplained > 0, "a shorter twin is not a clean twin")
        #expect(!r.isHealthy)
    }

    // MARK: What the screen and the paste get

    @Test("Every line is there when everything agrees")
    func everyLineIsThereWhenEverythingAgrees() throws {
        let store = history()
        let r = compared(series(store), series(try imported(store)))
        let lines = r.diagnosticLines
        // 23 AT 317, 22 AT 316. This count is the whole point of the test —
        // a line added to the paste and not to this number is a line nobody
        // decided to add — and it is also why this test failed the moment
        // §12.61 gave the load slice a second limit row. See §12.61.9.
        #expect(lines.count == 23, "got \(lines.count)")
        #expect(lines.first == "Load parity: 11 days, 3 sessions")
        #expect(lines.contains("  days with a different state: 0"))
        #expect(lines.contains("  sessions scored from a different rung: 0"))
        #expect(lines.contains("  unexplained differences: 0"))
        #expect(lines.contains("  held from the app: \(LoadParity.heldFromTheApp)"),
                "the limit is printed, not implied")
        // PATCH 317. "Held from the app" and "held from the app and never
        // checked" are different sentences, and the paste has to carry both
        // or a reader cannot tell which one it is looking at.
        #expect(lines.contains("  of those, verified: \(LoadParity.verifiedByReadBack)"),
                "what the athlete read-back proves is printed, not implied")
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

        // `details` is handed a genuinely healthy report — patch 320, and the
        // reason is 315a's: passing nil there too would make this pass for the
        // wrong reason, since a missing DETAIL slice fails for its own sake.
        let details = DetailParity.compare(app: [detail()], database: [detail()])
        #expect(details.isHealthy, "the detail slice really does pass")

        let withoutLoad = ShadowParity.Outcome.ran(activities: activities,
                                                   volume: volume, load: nil,
                                                   details: details,
                                                   matches: matchesAgree())
        #expect(!withoutLoad.isHealthy, "no answer is not zero differences")
        #expect(withoutLoad.line.contains("differences"))
        #expect(withoutLoad.diagnosticLines
                    .contains("Load parity: the app's own load series was not built"))

        // AND THE OTHER WAY ROUND — patch 320. A detail slice that could not
        // run fails the whole outcome on its own.
        let withoutDetails = ShadowParity.Outcome.ran(activities: activities,
                                                      volume: volume,
                                                      load: nil, details: nil,
                                                      matches: matchesAgree())
        #expect(!withoutDetails.isHealthy)
        #expect(withoutDetails.diagnosticLines
                    .contains("Detail parity: the details could not be read"))
    }
}
