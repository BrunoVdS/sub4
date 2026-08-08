//
//  MatchResolverTests.swift
//  Sub4CoreTests
//
//  The resolution, extracted — patch 321, ADR-0003 §12.64.
//
//  WHAT THESE ARE FOR
//  ------------------
//  321 moved `Matcher.resolve` and `Matcher.plannedKm` without changing them,
//  so the existing suite is the proof that the move was faithful. These are
//  about the two things that suite could never reach, because the function was
//  private and read its inputs from three singletons:
//
//    `theOrderOfTheListDecidesAVagueMatch`
//        — matching is ORDER-DEPENDENT, which is why slice 5's answer rests on
//          slice 1's `0 order disagreements`. Nothing has ever asserted it.
//
//    `anOverrideNamingAnIneligibleActivityIsLost`
//        — the defect open since 2026-08-05, asserted as it behaves TODAY.
//          321 does not fix it; the choice between the two candidate fixes is
//          the athlete's. The day it is fixed, this test inverts rather than
//          the change going unnoticed.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct MatchResolverTests {

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

    private func day(_ sessions: [Session], _ activities: [Activity],
                     decisions: [String: MatchDecision] = [:]) -> MatchResolver.Day {
        MatchResolver.day(sessions: sessions, activities: activities,
                          decisions: decisions, dayKey: "2026-04-20")
    }

    private func decision(_ uid: String, _ activityId: String?) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: activityId,
                      decided: Date(timeIntervalSince1970: 1), dateIsKnown: true)
    }

    // MARK: The move was faithful

    @Test("One session and one activity match")
    func theSimpleCase() {
        let d = day([session("s1")], [activity("a1")])
        #expect(d.matches.count == 1)
        #expect(d.matches.first?.activity?.id == "a1")
        #expect(d.matches.first?.auto == true)
        #expect(d.extras.isEmpty)
    }

    /// A rest day is done by doing nothing, so there is never an activity to
    /// find and the match is complete with none.
    @Test("A rest day resolves with no activity")
    func restDaysResolveEmpty() {
        let d = day([session("s1", discipline: .rest)], [])
        #expect(d.matches.count == 1)
        #expect(d.matches.first?.activity == nil)
        #expect(d.matches.first?.auto == true)
    }

    /// Sessions with a stated distance are resolved first so they claim the
    /// right activity, and the nearest by kilometres wins.
    @Test("A stated distance claims the nearest activity")
    func aStatedDistanceClaimsTheNearest() {
        let d = day([session("s1", title: "20 km")],
                    [activity("short", km: 5), activity("long", km: 20)])
        #expect(d.matches.first?.activity?.id == "long")
        #expect(d.extras.map(\.id) == ["short"])
    }

    @Test("plannedKm reads the plan's own text")
    func plannedKmReadsTheText() {
        #expect(MatchResolver.plannedKm(session("a", title: "26 km easy")) == 26)
        #expect(MatchResolver.plannedKm(session("b", title: "1200 m repeats")) == 1.2)
        #expect(MatchResolver.plannedKm(session("c", title: "6×100")) == nil)
        #expect(MatchResolver.plannedKm(session("d", title: "12,5 km")) == 12.5,
                "the plan writes decimals with a comma")
    }

    /// THE ONE NOTHING HAD EVER ASSERTED. A session with no stated distance
    /// takes `candidates.first!`, so the ORDER of the activity array decides
    /// what it claims — which is why slice 5's answer rests on slice 1
    /// reporting zero order disagreements. If that ever changed, this would.
    @Test("The order of the activity list decides a vague match")
    func theOrderOfTheListDecidesAVagueMatch() {
        let first = activity("first", km: 8)
        let second = activity("second", km: 12)

        let forwards = day([session("s1", title: "easy")], [first, second])
        let backwards = day([session("s1", title: "easy")], [second, first])

        #expect(forwards.matches.first?.activity?.id == "first")
        #expect(backwards.matches.first?.activity?.id == "second",
                "the same session claims a different activity from the same pair")
    }

    /// Anything the plan did not want is kept, not discarded — commutes, walks,
    /// kayaking and any eligible activity that found no session.
    @Test("Extras keep everything the plan did not claim")
    func extrasKeepWhatThePlanDidNot() {
        let d = day([session("s1")],
                    [activity("run"), activity("walk", sport: "Walk"),
                     activity("spare", at: "2026-04-20T18:00:00")])
        #expect(d.matches.first?.activity?.id == "run")
        #expect(Set(d.extras.map(\.id)) == ["walk", "spare"])
        #expect(d.extras.map(\.id) == d.extras.sorted { $0.startLocal < $1.startLocal }
                    .map(\.id), "sorted by startLocal, which is the order drawn")
    }

    @Test("Adherence counts non-rest sessions only")
    func adherenceExcludesRestDays() {
        let d = day([session("s1"), session("rest", discipline: .rest, seq: 1),
                     session("s2", seq: 2)],
                    [activity("a1")])
        let a = MatchResolver.adherence(d.matches)
        #expect(a.total == 2, "the rest day is not part of the count")
        #expect(a.done == 1)
    }

    // MARK: Overrides

    @Test("An override wins outright")
    func anOverrideWins() {
        let d = day([session("s1", title: "20 km")],
                    [activity("near", km: 20), activity("far", km: 5)],
                    decisions: ["s1": decision("s1", "far")])
        #expect(d.matches.first?.activity?.id == "far",
                "the athlete's answer beats the nearest distance")
        #expect(d.matches.first?.auto == false)
        #expect(d.extras.map(\.id) == ["near"])
    }

    /// "Explicitly nothing" and "the activity named is not here" both produce
    /// an unmatched session, and deliberately so — the athlete overrode the
    /// matcher, so the matcher does not get another guess.
    @Test("An override for nothing leaves the session unmatched")
    func anOverrideForNothing() {
        let d = day([session("s1")], [activity("a1")],
                    decisions: ["s1": decision("s1", nil)])
        #expect(d.matches.first?.activity == nil)
        #expect(d.matches.first?.auto == false, "unmatched on purpose, not by the matcher")
        #expect(d.extras.map(\.id) == ["a1"], "and the activity is still shown")
    }

    @Test("An override naming an activity that is not here is unmatched")
    func anOverrideNamingAGhost() {
        let d = day([session("s1")], [activity("a1")],
                    decisions: ["s1": decision("s1", "somewhere-else")])
        #expect(d.matches.first?.activity == nil)
        #expect(d.matches.first?.auto == false)
    }

    /// THE DEFECT, ASSERTED AS IT BEHAVES TODAY — open since 2026-08-05.
    ///
    /// `resolve` step 1 honours an override only when the named activity is in
    /// the pool, and `day` has already filtered the pool by `isPlanEligible` —
    /// under which a walk is never eligible. So the athlete names the walk, the
    /// override is stored, the matcher cannot find it, and the session falls
    /// through to the same branch as "explicitly nothing". The Week screen says
    /// *Not done* and nothing on it says why.
    ///
    /// **321 does not fix this.** The two candidates change behaviour in ways
    /// only the athlete can choose between — (a) the picker offers only what can
    /// win, (b) an explicit override beats `isPlanEligible`, which is patch
    /// 251's own argument and would put the walk's distance and load into that
    /// session's figures. This test asserts today, so the day it changes the
    /// test inverts rather than the change going unnoticed.
    @Test("An override naming an ineligible activity is lost — the open defect")
    func anOverrideNamingAnIneligibleActivityIsLost() {
        let walk = activity("walk", sport: "Walk")
        #expect(!walk.isPlanEligible, "a walk is never eligible — Activity.isPlanEligible")

        let d = day([session("s1")], [walk],
                    decisions: ["s1": decision("s1", "walk")])

        #expect(d.matches.first?.activity == nil,
                "the override named it and the matcher could not reach it")
        #expect(d.matches.first?.isDone == false,
                "so the session reads as not done, which is the reported defect")
        #expect(d.extras.map(\.id) == ["walk"],
                "and the walk shows only as an extra")
    }

    /// The same override on an ELIGIBLE activity does win, which is what makes
    /// the test above a statement about eligibility rather than about overrides.
    @Test("The same override on an eligible activity does win")
    func theSameOverrideOnAnEligibleActivityWins() {
        let run = activity("run")
        #expect(run.isPlanEligible)
        let d = day([session("s1")], [run], decisions: ["s1": decision("s1", "run")])
        #expect(d.matches.first?.activity?.id == "run")
        #expect(d.matches.first?.auto == false)
    }

    // MARK: Order of the result

    /// The matches come back in the plan's own order however they were
    /// resolved — stated-distance sessions are resolved first, and the sort at
    /// the end puts them back.
    @Test("Matches are returned in the plan's order, not the resolution order")
    func matchesKeepThePlansOrder() {
        let vague = session("vague", title: "easy", seq: 0)
        let stated = session("stated", title: "20 km", seq: 1)
        let d = day([vague, stated], [activity("a", km: 20), activity("b", km: 4)])
        #expect(d.matches.map(\.session.uid) == ["vague", "stated"])
    }
}
