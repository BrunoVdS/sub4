//
//  VolumeParityTests.swift
//  Sub4CoreTests
//
//  D6c slice 2 — patch 313, groundwork §2.1 and §6.2, ADR-0003 §12.57.
//
//  SAME JOB AS `ActivityParityTests`: this file is the negative control.
//
//  Slice 1 proved both sides derive the same list. Slice 2 compares the numbers
//  computed from it, and it will report zero differences for exactly the same
//  reason — which means the tests are again the only thing standing between a
//  zero that is a result and a zero that is a broken check.
//
//  Every planted difference below is built through the real `Sub4Import` and
//  read back through the real `ActivityRepository`, then perturbed on the store
//  side. `theWeekBucketingIsUnmoved` is the extra one this slice owes: 313 took
//  twelve lines out of `VolumeSeries.weeks`, which four charts read, and the
//  claim that it changed nothing needs to be a test rather than an assurance.
//
//  `theToleranceIsNotAWildcard` is the one with teeth here. A tolerance is a
//  hole in a gate, and an untested one is a hole nobody has measured: it has to
//  admit a rounding difference and refuse a real one, and the two are ten
//  metres apart.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct VolumeParityTests {

    /// PATCH 321. A genuinely healthy match slice — one run, one planned run,
    /// matched on both sides. Handed an empty pair instead, the assertion above
    /// would pass with one more failing slice than it means to test, which is
    /// 315a's defect.

    /// A summary slice that passes, for the same reason `matchesAgree` exists:
    /// an empty pair compares zero of zero, `lookedAtSomething` is false, and
    /// the assertion above would then pass with one MORE failing slice than it
    /// means to test. 315a's defect, and 330 is the fifth slice to have to
    /// avoid it.
    private func summariesAgree() -> SummaryParity.Report {
        let point = TabSummary.WeekPoint(
            weekNo: 1, start: Date(timeIntervalSince1970: 1_776_600_000),
            plannedKm: 30, plannedExact: true, actualKm: 28,
            longestRunKm: 14, done: 3, total: 4)
        let volume = PlanStore.PlanVolume(runKm: 28, bikeHours: 2,
                                          swimKm: 1.5, strengthSessions: 2,
                                          runExact: true)
        return SummaryParity.compare(app: [point], database: [point],
                                     appActual: volume, databaseActual: volume,
                                     appPlanned: volume, databasePlanned: volume,
                                     planSessionsInApp: 4,
                                     planSessionsInDatabase: 4,
                                     daysAskedFor: 7,
                                     daysWithContentInApp: 4,
                                     daysWithContentInDatabase: 4)
    }

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

    /// PATCH 320. A detail with enough complete splits to answer every pace
    /// window, so the detail slice below is genuinely healthy rather than
    /// vacuously so — 315a's lesson, which was that a slice passed `nil` makes
    /// a test pass for the wrong reason.
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

    private func ride(_ id: String, at startLocal: String,
                      movingTime: Int = 3_600, distance: Double = 24_300,
                      sport: String = "Ride") -> Activity {
        Activity(id: id, name: "Ride", sportType: sport,
                 startLocal: startLocal, distance: distance,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: 130, isTrainer: false,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: startLocal + "Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7_200)
    }

    /// A run, so a day can hold two disciplines and `DayDistance` has to fall
    /// back to minutes — the case patch 249 exists for.
    private func run(_ id: String, at startLocal: String,
                     movingTime: Int = 2_400, distance: Double = 8_000) -> Activity {
        ride(id, at: startLocal, movingTime: movingTime,
             distance: distance, sport: "Run")
    }

    private func imported(_ activities: [Activity]) throws -> [Activity] {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: activities, shoes: [])
        guard let rows = ActivityRepository.all(db).activities else { throw NoRows() }
        return ActivityRoster.settle(rows).activities
    }

    /// Three rides on three days of one week, plus one the week after — so the
    /// week bucketing has something to bucket.
    private func history() -> [Activity] {
        [ride("d", at: "2026-04-27T09:00:00"),
         ride("c", at: "2026-04-23T09:00:00"),
         ride("b", at: "2026-04-22T09:00:00"),
         ride("a", at: "2026-04-21T09:00:00")]
    }

    // MARK: The boring case

    @Test("The same activities produce the same daily and weekly figures")
    func identicalHistoriesAgree() throws {
        let store = history()
        let twin = try imported(store)

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(r.daysCompared == 4, "the denominator")
        #expect(r.weekValuesCompared > 0)
        #expect(r.bandsCompared == 12, "six bands, two units")
        #expect(r.daysDiffering.isEmpty)
        #expect(r.weeksDiffering.isEmpty)
        #expect(r.bandsDiffering.isEmpty)
        #expect(r.historyStartAgrees)
        #expect(r.unexplained == 0)
        #expect(r.isHealthy)
    }

    /// The same guard slice 1 has, applied to three denominators. Zero days
    /// compared against zero days agrees perfectly.
    @Test("Comparing nothing is not agreement")
    func nothingComparedIsNotAgreement() throws {
        let r = VolumeParity.compare(store: [], database: [])
        #expect(r.daysCompared == 0)
        #expect(r.unexplained == 0, "nothing disagreed, because nothing was looked at")
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy, "a comparison of nothing must not read as a pass")
        #expect(r.summary.hasPrefix("nothing compared"))
    }

    // MARK: The negative controls

    /// A distance change small enough to be invisible in the activity list and
    /// large enough to matter on a chart.
    @Test("A different distance on one day is reported")
    func aChangedDistanceIsReported() throws {
        let twin = try imported(history())
        var store = history()
        store[3] = ride("a", at: "2026-04-21T09:00:00", distance: 30_000)

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(r.daysDiffering == ["2026-04-21"])
        #expect(!r.weeksDiffering.isEmpty, "the week that day sits in moved too")
        #expect(!r.bandsDiffering.isEmpty, "and so did the whole-history band")
        #expect(!r.isHealthy)
    }

    /// THE CASE PATCH 249 EXISTS FOR. Add a run to a day that held only rides
    /// and the day stops being a distance at all — it becomes minutes, because
    /// running kilometres and cycling kilometres do not add. Every field on
    /// every activity still agrees; only the derived answer changes.
    @Test("A day that changes from kilometres to minutes is reported")
    func aMixedDayIsReported() throws {
        let twin = try imported(history())
        let store = history() + [run("r", at: "2026-04-21T18:00:00")]

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(r.daysDiffering == ["2026-04-21"],
                "one day went from km to minutes")
        #expect(!r.isHealthy)
    }

    @Test("A different duration on one day is reported, in hours")
    func aChangedDurationIsReported() throws {
        let twin = try imported(history())
        var store = history()
        store[3] = ride("a", at: "2026-04-21T09:00:00", movingTime: 7_200)

        let r = VolumeParity.compare(store: store, database: twin)
        // The distance is unchanged, so the km figures agree and only the hour
        // figures move — which is what naming the unit in the difference is for.
        #expect(r.weeksDiffering.contains { $0.hasSuffix("hours") })
        #expect(!r.weeksDiffering.contains { $0.hasSuffix("km") },
                "kilometres did not change and must not be reported")
        #expect(!r.isHealthy)
    }

    /// A week the database does not have at all. Compared over the UNION of
    /// both sides' weeks, so a missing week is a difference rather than
    /// something quietly not looked at.
    @Test("A week only one side has is reported")
    func aMissingWeekIsReported() throws {
        let twin = try imported(history())
        let store = history() + [ride("z", at: "2026-05-11T09:00:00")]

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(r.weeksDiffering.contains { $0.hasPrefix("2026-05-11") },
                "got \(r.weeksDiffering)")
        #expect(!r.isHealthy)
    }

    @Test("A history that starts on a different day is reported")
    func aDifferentHistoryStartIsReported() throws {
        let twin = try imported(history())
        let store = history() + [ride("early", at: "2026-01-05T09:00:00")]

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(!r.historyStartAgrees)
        #expect(!r.isHealthy)
    }

    /// A ride under the training threshold lands in the commute band rather
    /// than the bike band — same discipline, same day, different answer.
    @Test("A ride that moves between bands is reported")
    func aBandChangeIsReported() throws {
        let full = ride("b2", at: "2026-04-24T08:00:00",
                        movingTime: 3_600, distance: 24_300)
        let short = ride("b2", at: "2026-04-24T08:00:00",
                         movingTime: 600, distance: 3_000)
        let twin = try imported(history() + [full])
        let store = history() + [short]

        let r = VolumeParity.compare(store: store, database: twin)
        #expect(!r.bandsDiffering.isEmpty, "got \(r.bandsDiffering)")
        #expect(!r.isHealthy)
    }

    // MARK: The tolerance

    /// THE ONE WITH TEETH. A tolerance is a hole in a gate; an untested one is
    /// a hole nobody has measured. It must admit a rounding difference and
    /// refuse a real one, and here they are ten metres apart.
    @Test("The tolerance admits rounding and refuses a real difference")
    func theToleranceIsNotAWildcard() {
        let base = ride("a", at: "2026-04-21T09:00:00", distance: 24_300)
        // Half a millimetre — the shape of a floating-point summation residue.
        let rounding = ride("a", at: "2026-04-21T09:00:00", distance: 24_300.0005)
        // Ten metres — small on a chart and real.
        let real = ride("a", at: "2026-04-21T09:00:00", distance: 24_310)

        #expect(VolumeParity.same(DayDistance.of([base]), DayDistance.of([rounding])),
                "half a millimetre is not a data difference")
        #expect(!VolumeParity.same(DayDistance.of([base]), DayDistance.of([real])),
                "ten metres is")
    }

    /// The case itself has to match, with no tolerance at all: a day that
    /// covered no ground and a day that covered 0.0 km in one sport are
    /// different answers, and collapsing them would hide what patch 249 built
    /// `DayDistance` to prevent.
    @Test("The kind of answer is compared exactly")
    func theCaseMustMatch() {
        #expect(!VolumeParity.same(.km(0, .run), .none(minutes: 0)))
        #expect(!VolumeParity.same(.km(10, .run), .km(10, .bike)),
                "same number, different sport, different fact")
        #expect(!VolumeParity.same(.minutes(30), .minutes(31)),
                "minutes are integers and get no tolerance")
    }

    // MARK: The extraction 313 made

    /// 313 TOOK TWELVE LINES OUT OF `VolumeSeries.weeks`, which four charts
    /// read. The claim that it changed nothing needs to be a test, not an
    /// assurance — the same discipline 310 used when it moved three rules out
    /// of `ActivityStore`.
    ///
    /// The old version bucketed only the weeks it drew; this one buckets
    /// everything and reads the window out. For any week inside the window the
    /// two must agree exactly, and outside it the new one has answers the old
    /// one threw away.
    ///
    /// THE SECOND HALF READS THE CLOCK, and it is the one place in these two
    /// files that does. `weeks()` counts back from this Monday, so asking for
    /// 200 of them is what makes April 2026 fall inside the window — true until
    /// roughly 2030, and stated here rather than left to be discovered.
    @Test("The week bucketing covers everything and the window is unmoved")
    func theWeekBucketingIsUnmoved() {
        let acts = history()
        let all = VolumeSeries.recordedByWeek(acts, metric: .bike, unit: .km)

        // Two ISO weeks: 20–26 April and 27 April – 3 May.
        #expect(all.count == 2, "got \(all.keys.sorted())")
        let firstWeek = all["2026-04-20"]
        #expect(firstWeek != nil)
        // Three rides of 24.3 km, all bike, all above the commute threshold.
        #expect(abs((firstWeek?.training ?? 0) - 72.9) < 0.001,
                "got \(firstWeek?.training ?? -1)")
        #expect((firstWeek?.commute ?? -1) == 0)
        #expect(abs((all["2026-04-27"]?.training ?? 0) - 24.3) < 0.001)

        // And the chart still reads the same figures out of it.
        let weeks = VolumeSeries.weeks(count: 200, metric: .bike, unit: .km,
                                       activities: acts, store: PlanStore())
        let drawn = weeks.first { DayKey.key($0.start) == "2026-04-20" }
        #expect(drawn != nil, "the window should reach back to April 2026")
        #expect(abs((drawn?.training ?? 0) - 72.9) < 0.001,
                "the card must read what the bucketing produced")
    }

    @Test("A discipline with nothing recorded produces no weeks, not zeros")
    func anEmptyDisciplineIsEmpty() {
        #expect(VolumeSeries.recordedByWeek(history(), metric: .swim, unit: .km).isEmpty)
    }

    // MARK: The outcome — moved here from ActivityParityTests at 313

    /// `.never` is not agreement and not a failure — §12.15's shape. An
    /// optional report would make "has not run" and "ran and found nothing" the
    /// same nil.
    @Test("Not having compared is its own answer")
    func neverIsAnAnswer() {
        #expect(ShadowParity.Outcome.never.isHealthy,
                "not having looked is not a fault")
        #expect(ShadowParity.Outcome.never.line == "Not compared since this launch.")
        #expect(!ShadowParity.Outcome.noDatabase.isHealthy)
        #expect(!ShadowParity.Outcome.readFailed("disk").isHealthy)
        #expect(ShadowParity.Outcome.noDatabase != .readFailed("disk"),
                "one is the launch gate, the other is the read")
        #expect(ShadowParity.Outcome.never.diagnosticLines
                    == ["Shadow parity: Not compared since this launch."],
                "the paste says which of the four it is, rather than nothing")
    }

    /// ONE SLICE FAILING FAILS THE RUN. That is the whole reason there is one
    /// button rather than three: a person cannot run the half that passes.
    ///
    /// THE OTHER TWO HAVE TO BE GENUINELY HEALTHY for this to prove anything.
    /// 315a: the load slice was added to `Outcome` and this test originally
    /// omitted it, which stopped the file compiling — and the lazy repair,
    /// passing `load: nil`, would have made the test pass because a MISSING
    /// slice fails a run. That is a different fact, and it is already pinned by
    /// `LoadParityTests.aMissingSliceIsNotAPass`. So the load report here is a
    /// real one, built from the same series on both sides.
    @Test("One slice failing fails the run")
    func oneSliceFailingFailsTheRun() throws {
        let store = history()
        let twin = try imported(store)
        var wrong = store
        wrong[3] = ride("a", at: "2026-04-21T09:00:00", distance: 30_000)

        let activitiesAgree = ActivityParity.compare(store: wrong, databaseRows: twin,
                                                     databaseSkipped: 0)
        let volumeDiffers = VolumeParity.compare(store: wrong, database: twin)
        #expect(activitiesAgree.isHealthy, "the same ids, in the same order")
        #expect(!volumeDiffers.isHealthy, "but not the same kilometres")

        let days = LoadSeries.build(
            from: "2026-04-20", to: "2026-04-30",
            byDay: ActivityRoster.byDay(twin),
            inputs: LoadSeries.Inputs(hrMax: 185, hrRest: { _ in 48 }, w: 1.92,
                                      ftp: nil, powerFactor: nil))
        let loadAgrees = LoadParity.compare(app: days, database: days)
        #expect(loadAgrees.isHealthy, "and the load slice really does pass")

        // THE DETAIL SLICE PASSES TOO — patch 320. Handing it an empty pair
        // would make this test pass with THREE failures instead of one, which
        // is 315a's defect: a green assertion for the wrong reason.
        let detailsAgree = DetailParity.compare(app: [detail()], database: [detail()])
        #expect(detailsAgree.isHealthy, "and the detail slice really does pass")

        let outcome = ShadowParity.Outcome.ran(activities: activitiesAgree,
                                               volume: volumeDiffers,
                                               load: loadAgrees,
                                               details: detailsAgree,
                                               matches: matchesAgree(),
                                               summaries: summariesAgree())
        #expect(!outcome.isHealthy, "three passes and one failure is a failure")
        #expect(outcome.line.contains("differences"))
    }
}
