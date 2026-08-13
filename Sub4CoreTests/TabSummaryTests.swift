//
//  TabSummaryTests.swift
//  Sub4CoreTests
//
//  The tab summaries, as functions of their inputs — D6c slice 8, patch 329,
//  ADR-0003 §12.73.
//
//  WHAT THESE ARE FOR
//  ------------------
//  329 is a MOVE, not a rewrite, and the existing suite is the proof of no
//  behaviour change — every test that touches the Progress or Week tab
//  exercises these bodies. So these tests are not about the arithmetic. They
//  pin the three things a move can silently get wrong and a twin would then
//  inherit:
//
//    `aWeekThatHasNotBegunIsSkipped` / `theCutoffIsTheCallersDayNotTheClock`
//        — groundwork §7 named this as the single most likely way to get slice
//          8 wrong. A twin applying a different cutoff, or reading a different
//          clock, compares 34 weeks against 2 and reports 32 phantom
//          differences. `todayKey` is a parameter so both sides can be handed
//          the same day.
//
//    `theLongestRunIsAMaximumNotASum`
//        — the one figure where a real difference can hide behind an agreeing
//          total. Two activities summing to the same distance have different
//          maxima, and only this test would notice.
//
//    `weekActualsCountsExtras`
//        — the Week card answers "how far did you move", not "how much of the
//          plan did you do". Extras are the difference between the two, and a
//          move that quietly dropped them would leave every other figure right.
//
//  Plus the delegation tests: the `PlanStore` instance methods are now
//  one-line wrappers, and a wrapper that stops agreeing with what it wraps is
//  §12.43's failure with a shorter fuse.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct TabSummaryTests {

    // MARK: Fixtures

    private func session(_ uid: String, week: String = "w1",
                         discipline: Discipline = .run,
                         title: String = "Easy run",
                         detail: String = "8 km easy",
                         date: String? = "2026-07-27") -> Session {
        Session(uid: uid, weekUid: week, day: "Mon", date: date,
                discipline: discipline, intensity: .easy,
                title: title, detail: detail, fuel: nil, prep: nil, seq: 0,
                swimDetail: nil, strengthDetail: nil)
    }

    private func week(_ uid: String, no: Int, start: String?,
                      logged: Bool = false) -> Week {
        Week(uid: uid, weekNo: no, label: String(no), dateRange: nil,
             startDate: start, tag: nil, badge: nil, kind: nil,
             logged: logged, stats: [:])
    }

    /// `sportType` drives `Activity.discipline`, and `distance` is metres.
    private func activity(_ id: String,
                          sportType: String = "Run",
                          km: Double = 10,
                          startLocal: String = "2026-07-27T09:00:00",
                          movingTime: Int = 3_600,
                          isTrainer: Bool = false) -> Activity {
        Activity(id: id, name: "Session", sportType: sportType,
                 startLocal: startLocal, distance: km * 1000,
                 movingTime: movingTime, elapsedTime: movingTime,
                 elevationGain: 0, averageHeartrate: nil, isTrainer: isTrainer,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-27T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func day(matches: [Match] = [], extras: [Activity] = []) -> MatchResolver.Day {
        MatchResolver.Day(matches: matches, extras: extras)
    }

    private func match(_ s: Session, _ a: Activity? = nil) -> Match {
        Match(session: s, activity: a, auto: true)
    }

    /// Every day resolves to nothing unless the test says otherwise.
    private func empty(_ key: String) -> MatchResolver.Day { day() }

    // MARK: The cutoff — groundwork §7

    /// A FUTURE WEEK HAS NOTHING TO SAY, and a twin that disagreed about which
    /// weeks those are would report every one of them as a difference.
    @Test("A week that has not begun is skipped")
    func aWeekThatHasNotBegunIsSkipped() {
        let weeks = [week("w1", no: 1, start: "2026-07-27"),
                     week("w2", no: 2, start: "2026-08-03"),
                     week("w3", no: 3, start: "2026-08-10")]
        let points = TabSummary.weekPoints(weeks: weeks, sessions: [],
                                           todayKey: "2026-08-08", day: empty)
        #expect(points.map(\.weekNo) == [1, 2], "week 3 begins on the 10th")
    }

    /// THE CLOCK IS THE CALLER'S. This is what lets the twin hand both sides
    /// the same day; a function that read `DayKey.key()` could not be asked
    /// twice with the same answer guaranteed.
    @Test("The cutoff is the caller's day, not the clock")
    func theCutoffIsTheCallersDayNotTheClock() {
        let weeks = [week("w1", no: 1, start: "2026-07-27"),
                     week("w2", no: 2, start: "2026-08-03")]
        let early = TabSummary.weekPoints(weeks: weeks, sessions: [],
                                          todayKey: "2026-07-30", day: empty)
        let later = TabSummary.weekPoints(weeks: weeks, sessions: [],
                                          todayKey: "2026-08-08", day: empty)
        #expect(early.count == 1)
        #expect(later.count == 2)
    }

    /// A week with no `weekNo` or no `startDate` is not a week the chart can
    /// place, and dropping it is the behaviour that moved here.
    @Test("A week with no number or no start date is not placed")
    func anUnplaceableWeekIsDropped() {
        let weeks = [week("p1", no: 1, start: nil),
                     week("w1", no: 1, start: "2026-07-27")]
        let points = TabSummary.weekPoints(weeks: weeks, sessions: [],
                                           todayKey: "2026-08-08", day: empty)
        #expect(points.count == 1)
    }

    // MARK: The sensitive figure

    /// A MAXIMUM, NOT A SUM. Two weeks whose runs total the same distance have
    /// different longest runs, and no other figure in the slice would notice.
    @Test("The longest run is a maximum, not a sum")
    func theLongestRunIsAMaximumNotASum() {
        let weeks = [week("w1", no: 1, start: "2026-07-27")]

        let evenly = TabSummary.weekPoints(
            weeks: weeks, sessions: [], todayKey: "2026-08-08",
            day: { $0 == "2026-07-27"
                   ? self.day(extras: [self.activity("a", km: 10),
                                       self.activity("b", km: 10)])
                   : self.day() })

        let lopsided = TabSummary.weekPoints(
            weeks: weeks, sessions: [], todayKey: "2026-08-08",
            day: { $0 == "2026-07-27"
                   ? self.day(extras: [self.activity("a", km: 4),
                                       self.activity("b", km: 16)])
                   : self.day() })

        #expect(evenly[0].actualKm == lopsided[0].actualKm, "20 km either way")
        #expect(evenly[0].longestRunKm == 10)
        #expect(lopsided[0].longestRunKm == 16, "the sums agree and the maxima do not")
    }

    /// RUNS ONLY, on both halves of the chart's axis. A ride in the week must
    /// not enter `actualKm`, because the planned figure it is drawn against is
    /// running kilometres.
    @Test("Only runs reach the chart's actual kilometres")
    func onlyRunsReachTheChartsKilometres() {
        let weeks = [week("w1", no: 1, start: "2026-07-27")]
        let points = TabSummary.weekPoints(
            weeks: weeks, sessions: [], todayKey: "2026-08-08",
            day: { $0 == "2026-07-27"
                   ? self.day(extras: [self.activity("run", km: 8),
                                       self.activity("ride", sportType: "Ride", km: 40)])
                   : self.day() })
        #expect(points[0].actualKm == 8)
        #expect(points[0].longestRunKm == 8)
    }

    /// Matched activities count as well as extras — a session that was done
    /// contributes its distance exactly like an unmatched one.
    @Test("Matched activities and extras both reach the chart")
    func matchedAndExtrasBothCount() {
        let weeks = [week("w1", no: 1, start: "2026-07-27")]
        let s = session("wk1-mon")
        let points = TabSummary.weekPoints(
            weeks: weeks, sessions: [s], todayKey: "2026-08-08",
            day: { $0 == "2026-07-27"
                   ? self.day(matches: [self.match(s, self.activity("m", km: 6))],
                              extras: [self.activity("e", km: 3)])
                   : self.day() })
        #expect(points[0].actualKm == 9)
        #expect(points[0].done == 1)
        #expect(points[0].total == 1)
    }

    // MARK: Actual volume, per discipline

    @Test("Each discipline lands in its own unit")
    func eachDisciplineLandsInItsOwnUnit() {
        let v = TabSummary.actualVolume([
            activity("r", sportType: "Run", km: 12),
            activity("s", sportType: "Swim", km: 1.5),
            activity("b", sportType: "Ride", km: 40, movingTime: 5_400)
        ])
        #expect(v.runKm == 12)
        #expect(v.swimKm == 1.5)
        #expect(v.bikeHours == 1.5, "5400 seconds")
        #expect(v.strengthSessions == 0)
    }

    /// `runExact` describes a PLANNED figure's precision. A recorded distance
    /// is measured, so this must stay at its default and a caller comparing
    /// against a planned volume must not read it.
    @Test("runExact stays true on an actual volume, because it means nothing there")
    func runExactIsMeaninglessOnActuals() {
        #expect(TabSummary.actualVolume([activity("r")]).runExact)
        #expect(TabSummary.actualVolume([]).runExact)
    }

    /// Activities before the block started are not the block's volume.
    @Test("Activities before the plan started are excluded")
    func activitiesBeforeThePlanAreExcluded() {
        let before = activity("old", km: 20, startLocal: "2025-09-01T09:00:00")
        #expect(TabSummary.actualVolume([before]).runKm == 0,
                "before MatchRules.planStartDayKey")
    }

    // MARK: The Week card

    /// THE DIFFERENCE BETWEEN THIS AND THE CHART. The Week card answers "how
    /// far did you move", which includes the commute and the walks; the chart
    /// answers "how much of the plan did you do".
    @Test("Week actuals count extras, and minutes count every sport")
    func weekActualsCountsExtras() {
        let s = session("wk1-mon")
        let d = day(matches: [match(s, activity("m", km: 6, movingTime: 1_800))],
                    extras: [activity("walk", sportType: "Walk", km: 3, movingTime: 2_400),
                             activity("ride", sportType: "Ride", km: 20, movingTime: 3_600)])
        let w = TabSummary.weekActuals([d])
        #expect(w.recorded == 3, "everything recorded, matched or not")
        #expect(w.runKm == 6, "the walk and the ride are not running")
        #expect(w.minutes == 30 + 40 + 60, "time IS comparable across sports")
    }

    @Test("An empty week is zero across the board")
    func anEmptyWeekIsZero() {
        #expect(TabSummary.weekActuals([]) == TabSummary.WeekActuals())
        #expect(TabSummary.weekActuals([day()]) == TabSummary.WeekActuals())
    }

    // MARK: The wrappers still agree with what they wrap

    /// `PlanStore.plannedRunKm(week:)` is a one-line wrapper since 329. A
    /// wrapper that stops agreeing with what it wraps is §12.43's failure with
    /// a shorter fuse, so both are asked the same question.
    @Test("The plannedRunKm wrapper agrees with the static it wraps")
    func thePlannedRunKmWrapperAgrees() {
        let store = PlanStore()
        for w in store.planWeeks.prefix(6) {
            let viaInstance = store.plannedRunKm(week: w)
            let viaStatic = PlanStore.plannedRunKm(sessions: store.plan.sessions,
                                                   inWeek: w)
            #expect(viaInstance.km == viaStatic.km, "\(w.uid)")
            #expect(viaInstance.exact == viaStatic.exact, "\(w.uid)")
        }
    }

    @Test("The plannedVolume wrapper agrees with the static it wraps")
    func thePlannedVolumeWrapperAgrees() {
        let store = PlanStore()
        for day: String? in [nil, "2026-08-08", "2026-12-31"] {
            let viaInstance = store.plannedVolume(throughDay: day)
            let viaStatic = PlanStore.plannedVolume(sessions: store.plan.sessions,
                                                    weeksByUid: store.weeksByUid,
                                                    throughDay: day)
            #expect(viaInstance.runKm == viaStatic.runKm)
            #expect(viaInstance.bikeHours == viaStatic.bikeHours)
            #expect(viaInstance.swimKm == viaStatic.swimKm)
            #expect(viaInstance.strengthSessions == viaStatic.strengthSessions)
            #expect(viaInstance.runExact == viaStatic.runExact)
        }
    }

    /// The static form takes the sessions it is given and nothing else — which
    /// is the whole property the twin depends on.
    @Test("The statics read their arguments and not the singleton")
    func theStaticsReadTheirArguments() {
        let w = week("w1", no: 1, start: "2026-07-27")
        let mine = [session("a", detail: "10 km easy"),
                    session("b", detail: "5 km easy")]
        let d = PlanStore.plannedRunKm(sessions: mine, inWeek: w)
        #expect(d.km == 15, "not whatever the bundled plan says for w1")

        let none = PlanStore.plannedRunKm(sessions: [], inWeek: w)
        #expect(none.km == 0)
    }

    /// The logged-week exclusion needs `weeksByUid`, which is why it travels
    /// with the sessions. A caller holding one without the other holds half a
    /// plan.
    @Test("A logged week contributes nothing to planned volume")
    func aLoggedWeekIsExcluded() {
        let live = week("w1", no: 1, start: "2026-07-27")
        let logged = week("w0", no: 0, start: "2026-07-20", logged: true)
        let sessions = [session("a", week: "w1", detail: "10 km easy"),
                        session("z", week: "w0", detail: "10 km easy")]
        let v = PlanStore.plannedVolume(sessions: sessions,
                                        weeksByUid: ["w1": live, "w0": logged])
        #expect(v.runKm == 10, "the logged week's 10 km is history, not plan")
    }
}
