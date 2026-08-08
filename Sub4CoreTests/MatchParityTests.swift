//
//  MatchParityTests.swift
//  Sub4CoreTests
//
//  D6c slice 5 — plan matching. Patch 321, ADR-0003 §12.64.
//
//  WHAT THESE ARE FOR
//  ------------------
//  One proves the comparison works. The rest prove it can FAIL, which is what
//  groundwork §2.1 demands of every D6c slice — and this is the slice where a
//  false green would be most expensive, because the figure underneath it is
//  *Sessions 4/4* on the Week screen.
//
//  The two that matter most:
//
//    `aPlanThatMatchedNothingIsNotAPass`
//        — most planned sessions resolve to nothing on both sides. Counting
//          those as evidence would make a run over 37 weeks look thorough and
//          describe nothing. §12.54.2, one level up.
//
//    `matchedOnOneSideOnlyIsCaught`
//        — the exact shape that turns 4/4 into 3/4, and the exact shape the
//          match-picker defect produces.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct MatchParityTests {

    // MARK: Fixtures

    private func activity(_ id: String,
                          sport: String = "Run",
                          km: Double = 10,
                          at startLocal: String = "2026-04-20T09:00:00") -> Activity {
        Activity(id: id, name: "Session \(id)", sportType: sport,
                 startLocal: startLocal, distance: km * 1_000,
                 movingTime: Int(km * 330), elapsedTime: Int(km * 340),
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-04-20T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func session(_ uid: String,
                         discipline: Discipline = .run,
                         title: String? = nil,
                         seq: Int = 0) -> Session {
        Session(uid: uid, weekUid: "w1", day: "Mon", date: "2026-04-20",
                discipline: discipline, intensity: nil, title: title,
                detail: nil, fuel: nil, prep: nil, seq: seq,
                swimDetail: nil, strengthDetail: nil)
    }

    private func decision(_ uid: String, _ activityId: String?) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: activityId,
                      decided: Date(timeIntervalSince1970: 1), dateIsKnown: true)
    }

    /// One day, resolved through the app's own function.
    private func day(_ sessions: [Session], _ activities: [Activity],
                     decisions: [String: MatchDecision] = [:],
                     on key: String = "2026-04-20") -> [String: MatchResolver.Day] {
        [key: MatchResolver.day(sessions: sessions, activities: activities,
                                decisions: decisions, dayKey: key)]
    }

    // MARK: It agrees when it should

    @Test("Identical sides agree on every match")
    func identicalSidesAgree() {
        let side = day([session("s1", title: "20 km"), session("s2", seq: 1)],
                       [activity("a1", km: 20), activity("a2", km: 6,
                                                         at: "2026-04-20T18:00:00")])
        let r = MatchParity.compare(app: side, database: side)

        #expect(r.daysCompared == 1)
        #expect(r.sessionsCompared == 2)
        #expect(r.matchesResolved == 2, "both sessions claimed an activity")
        #expect(r.unexplained == 0)
        #expect(r.lookedAtSomething)
        #expect(r.isHealthy)
        #expect(r.adherenceLine == "2 of 2 vs 2 of 2")
    }

    /// Groundwork §2.1 case 2.
    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() {
        let r = MatchParity.compare(app: [:], database: [:])
        #expect(r.unexplained == 0, "there is genuinely nothing to disagree about")
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy)
        #expect(r.summary.contains("nothing compared"))
    }

    /// THE DENOMINATOR THAT WOULD HAVE LIED. A plan week is mostly rest days
    /// and sessions with no activity to find; those resolve to nothing on both
    /// sides and agree perfectly. `sessionsCompared` would say 5 and mean
    /// nothing — `matchesResolved` is what `lookedAtSomething` tests.
    @Test("A plan whose sessions matched nothing is not a pass")
    func aPlanThatMatchedNothingIsNotAPass() {
        let side = day([session("s1"), session("s2", seq: 1),
                        session("rest", discipline: .rest, seq: 2)], [])
        let r = MatchParity.compare(app: side, database: side)

        #expect(r.daysCompared == 1)
        #expect(r.sessionsCompared == 3, "they were all resolved")
        #expect(r.matchesResolved == 0, "and not one of them claimed anything")
        #expect(r.unexplained == 0)
        #expect(!r.lookedAtSomething, "three agreements about nothing")
        #expect(!r.isHealthy)
    }

    // MARK: The negative controls

    /// THE ROW THIS SLICE EXISTS FOR. Both sides matched the session and named
    /// a different activity — which on a vague session is exactly what a
    /// different activity ORDER produces.
    @Test("A session claiming a different activity is caught and named")
    func aDifferentActivityIsCaught() {
        let first = activity("first", km: 8)
        let second = activity("second", km: 12, at: "2026-04-20T18:00:00")
        let vague = session("s1", title: "easy")

        let r = MatchParity.compare(app: day([vague], [first, second]),
                                    database: day([vague], [second, first]))
        #expect(r.sessionsWithADifferentActivity == ["s1"])
        #expect(r.matchesResolved == 1, "the denominator survives the difference")
        #expect(!r.isHealthy)
    }

    /// THE SHAPE THAT TURNS 4/4 INTO 3/4, and the shape the match-picker defect
    /// produces. It is reported apart from a different activity, because "the
    /// session found nothing" and "the session found something else" are
    /// different problems with different causes.
    @Test("Matched on one side only is caught, apart from a different activity")
    func matchedOnOneSideOnlyIsCaught() {
        let s = session("s1")
        let r = MatchParity.compare(app: day([s], [activity("a1")]),
                                    database: day([s], []))
        #expect(r.sessionsDoneOnOneSideOnly == ["s1"])
        #expect(r.sessionsWithADifferentActivity.isEmpty,
                "it did not claim a different activity — it claimed none")
        #expect(r.appSessionsDone == 1)
        #expect(r.databaseSessionsDone == 0)
        #expect(r.adherenceLine == "1 of 1 vs 0 of 1")
        #expect(!r.isHealthy)
    }

    /// The same activity, chosen a different way. The row on screen would look
    /// identical and the fact behind it would not.
    @Test("A session chosen a different way is caught")
    func aDifferentSourceIsCaught() {
        let s = session("s1")
        let a = activity("a1")
        let r = MatchParity.compare(
            app: day([s], [a]),
            database: day([s], [a], decisions: ["s1": decision("s1", "a1")]))

        #expect(r.sessionsWithADifferentActivity.isEmpty, "the same activity")
        #expect(r.sessionsWithADifferentSource == ["s1"], "and not the same choice")
        #expect(!r.isHealthy)
    }

    @Test("A session one side never saw is counted apart")
    func aSessionOnOneSideOnly() {
        let r = MatchParity.compare(
            app: day([session("s1"), session("s2", seq: 1)], [activity("a1")]),
            database: day([session("s1")], [activity("a1")]))
        #expect(r.sessionsOnOneSideOnly == ["s2"])
        #expect(!r.isHealthy)
    }

    @Test("A day one side does not have is counted")
    func aDayOnOneSideOnly() {
        var app = day([session("s1")], [activity("a1")])
        app["2026-04-21"] = MatchResolver.day(sessions: [], activities: [],
                                              decisions: [:], dayKey: "2026-04-21")
        let r = MatchParity.compare(app: app,
                                    database: day([session("s1")], [activity("a1")]))
        #expect(r.daysOnlyInApp == ["2026-04-21"])
        #expect(!r.isHealthy)
    }

    // MARK: The extras — the other half of the movement picture

    @Test("Extras are compared by identity")
    func extrasMembershipIsCompared() {
        let s = session("s1")
        let r = MatchParity.compare(
            app: day([s], [activity("a1"), activity("walk", sport: "Walk")]),
            database: day([s], [activity("a1")]))
        #expect(r.daysWithDifferentExtras == ["2026-04-20"])
        #expect(!r.isHealthy)
    }

    /// The extras list is sorted by `startLocal` and the screen draws it in
    /// that order, so the same activities in a different sequence are not the
    /// same screen. Reported apart from a membership difference, because one is
    /// a missing session and the other is a sort.
    @Test("Extras in a different order are caught, apart from membership")
    func extrasOrderIsCompared() {
        // Two activities that sort the same way whatever order they arrive in,
        // so a genuine order difference has to be constructed rather than
        // wished for: the resolver sorts, so identical inputs cannot differ.
        let s = session("s1")
        let early = activity("early", sport: "Walk", at: "2026-04-20T06:00:00")
        let late = activity("late", sport: "Walk", at: "2026-04-20T20:00:00")
        let side = day([s], [activity("a1"), early, late])
        let sorted = MatchParity.compare(app: side, database: side)
        #expect(sorted.daysWithDifferentExtraOrder.isEmpty)
        #expect(sorted.daysWithDifferentExtras.isEmpty)

        // And the order check is live: a hand-built pair in the wrong sequence
        // is reported, which is what proves the row is not decorative.
        let scrambled = ["2026-04-20": MatchResolver.Day(
            matches: side["2026-04-20"]!.matches, extras: [late, early])]
        let r = MatchParity.compare(app: side, database: scrambled)
        #expect(r.daysWithDifferentExtras.isEmpty, "the same two activities")
        #expect(r.daysWithDifferentExtraOrder == ["2026-04-20"])
        #expect(!r.isHealthy)
    }

    // MARK: Context that has to be printed

    /// ZERO OVERRIDES IS THE STATE ON THE DEVICE — `match_decision` holds no
    /// rows. Printing the count is what stops "no differences" being read as
    /// coverage the run does not have: the override branch was never entered.
    @Test("Overrides applied is counted, and zero is the honest answer")
    func overridesAppliedIsCounted() {
        let s = session("s1")
        let a = activity("a1")
        let none = MatchParity.compare(app: day([s], [a]), database: day([s], [a]))
        #expect(none.overridesApplied == 0, "and the run is still healthy")
        #expect(none.isHealthy)

        let side = day([s], [a], decisions: ["s1": decision("s1", "a1")])
        let one = MatchParity.compare(app: side, database: side)
        #expect(one.overridesApplied == 1)
        #expect(one.isHealthy)
    }

    /// Rest days are excluded from the adherence count on both sides, exactly
    /// as `Matcher.adherence` excludes them.
    @Test("Adherence excludes rest days on both sides")
    func adherenceExcludesRestDays() {
        let side = day([session("s1"), session("rest", discipline: .rest, seq: 1)],
                       [activity("a1")])
        let r = MatchParity.compare(app: side, database: side)
        #expect(r.sessionsCounted == 1, "the rest day is not part of the figure")
        #expect(r.adherenceLine == "1 of 1 vs 1 of 1")
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line, including the zeros — 266c's rule, and
    /// §12.54.2's.
    @Test("Every diagnostic line is present when nothing differs")
    func theDiagnosticLinesAreUnconditional() {
        let side = day([session("s1", title: "20 km")],
                       [activity("a1", km: 20), activity("walk", sport: "Walk")])
        let text = MatchParity.compare(app: side, database: side)
            .diagnosticLines.joined(separator: "\n")

        for expected in ["Match parity: 1 days, 1 matches",
                         "held from the app: \(MatchParity.heldFromTheApp)",
                         "planned sessions compared: 1",
                         "sessions that claimed an activity on both sides: 1",
                         "extras compared: 1",
                         "days only in the app: 0",
                         "days only in the database: 0",
                         "sessions on one side only: 0",
                         "sessions that claimed a different activity: 0",
                         "sessions done on one side only: 0",
                         "sessions chosen a different way: 0",
                         "days with different extras: 0",
                         "days with a different extras order: 0",
                         "overrides applied: 0",
                         "adherence: 1 of 1 vs 1 of 1",
                         "unexplained differences: 0"] {
            #expect(text.contains(expected), "the paste is missing: \(expected)")
        }
    }
}
