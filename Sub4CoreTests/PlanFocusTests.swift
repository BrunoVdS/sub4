//
//  PlanFocusTests.swift
//  Sub4CoreTests
//
//  What kind of plan this is — patch 239.
//
//  THE POINT OF THE RULE
//  ---------------------
//  The week header used to say "of which about 35 km is running" because
//  somebody knew Sub-4 was a running plan and wrote it in. `PlanFocus` asks the
//  plan instead. So the tests that matter are the two plans this app has never
//  seen: an even triathlon block, and a cycling block. If the rule only works
//  on the plan it was written against, it is not a rule.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct PlanFocusTests {

    private func week(_ uid: String, logged: Bool = false) -> Week {
        Week(uid: uid, weekNo: 1, label: "1", dateRange: nil,
             startDate: "2026-07-27", tag: nil, badge: nil, kind: nil,
             logged: logged, stats: [:])
    }

    private func session(_ uid: String, _ discipline: Discipline,
                         week weekUid: String = "w1",
                         title: String = "Session",
                         detail: String? = nil,
                         dated: Bool = true) -> Session {
        Session(uid: uid, weekUid: weekUid, day: "Mon",
                date: dated ? "2026-07-27" : nil,
                discipline: discipline, intensity: nil, title: title,
                detail: detail, fuel: nil, prep: nil, seq: 0,
                swimDetail: nil, strengthDetail: nil)
    }

    private func focus(_ sessions: [Session],
                       weeks: [Week] = []) -> PlanFocus {
        let ws = weeks.isEmpty ? [week("w1")] : weeks
        return PlanFocus.derive(sessions: sessions,
                                weeksByUid: Dictionary(uniqueKeysWithValues:
                                    ws.map { ($0.uid, $0) }))
    }

    // MARK: The three shapes

    /// The plan that exists. Three runs, one ride, one swim — 60/20/20, so
    /// running leads alone and the other two sit below the line. This is the
    /// behaviour that was hard-coded before, now derived.
    @Test("A running plan leads with running alone")
    func aRunningPlanLeadsWithRunning() {
        let f = focus([session("1", .run), session("2", .run), session("3", .run),
                       session("4", .bike), session("5", .swim)])
        #expect(f.leads == [.run])
        #expect(f.soleLead == .run)
        #expect(f.isMultisport == false)
        #expect(f.supporting == [.bike, .swim])
    }

    /// THE ONE THAT MATTERS. An even triathlon block is 33/33/33 and every
    /// sport clears 30%, so all three lead and nothing is relegated.
    @Test("A triathlon plan leads with all three")
    func aTriathlonPlanLeadsWithAllThree() {
        let f = focus([session("1", .run), session("2", .run),
                       session("3", .bike), session("4", .bike),
                       session("5", .swim), session("6", .swim)])
        #expect(f.leads == [.run, .bike, .swim])
        #expect(f.isMultisport)
        #expect(f.supporting.isEmpty)
        #expect(f.soleLead == nil)
    }

    /// And a cycling block leads with cycling — which the old hard-coded line
    /// could not express at all, since it named running in the string.
    @Test("A cycling plan leads with cycling")
    func aCyclingPlanLeadsWithCycling() {
        let f = focus([session("1", .bike), session("2", .bike),
                       session("3", .bike), session("4", .bike),
                       session("5", .run)])
        #expect(f.leads == [.bike])
        #expect(f.supporting == [.run])
    }

    // MARK: The exclusions

    /// Optional sessions do not vote. 28 of this plan's bike sessions are
    /// optional Zwift rides; counting them would drift a running plan towards
    /// calling itself a cycling one on sessions nobody committed to.
    @Test("Optional sessions do not count towards the focus")
    func optionalSessionsDoNotVote() {
        let f = focus([session("1", .run), session("2", .run),
                       session("3", .bike, title: "Zwift · optional",
                               detail: "opt. 60–75 min")])
        #expect(f.leads == [.run])
        #expect(f.supporting.isEmpty, "an optional ride was counted as a sport")
    }

    /// The logged July prologue is what already happened, not what the plan
    /// asks for. A prologue full of rides must not make this a cycling plan.
    @Test("Logged weeks do not count towards the focus")
    func loggedWeeksDoNotVote() {
        let f = focus([session("1", .run, week: "w1"),
                       session("2", .run, week: "w1"),
                       session("3", .bike, week: "log"),
                       session("4", .bike, week: "log"),
                       session("5", .bike, week: "log")],
                      weeks: [week("w1"), week("log", logged: true)])
        #expect(f.leads == [.run])
    }

    @Test("Undated sessions do not count towards the focus")
    func undatedSessionsDoNotVote() {
        let f = focus([session("1", .run), session("2", .run),
                       session("3", .bike, dated: false),
                       session("4", .bike, dated: false)])
        #expect(f.leads == [.run])
    }

    /// Strength is support, not a sport the plan is about. A block of three
    /// runs and three strength sessions is a running plan.
    @Test("Strength never leads")
    func strengthNeverLeads() {
        let f = focus([session("1", .run),
                       session("2", .strength), session("3", .strength),
                       session("4", .strength), session("5", .strength)])
        #expect(f.leads == [.run])
        let mentionsStrength = f.leads.contains(.strength) || f.supporting.contains(.strength)
        #expect(!mentionsStrength)
    }

    @Test("A plan with no committed endurance sessions leads with nothing")
    func anEmptyPlanLeadsWithNothing() {
        let f = focus([session("1", .strength), session("2", .rest)])
        #expect(f.leads.isEmpty)
        #expect(f.supporting.isEmpty)
    }

    /// A tie must not depend on dictionary order, or the header would reorder
    /// itself between launches for no reason the reader can see.
    @Test("Equal shares come out in a fixed order")
    func tiesAreOrderedDeterministically() {
        let a = focus([session("1", .swim), session("2", .bike), session("3", .run)])
        let b = focus([session("1", .run), session("2", .swim), session("3", .bike)])
        #expect(a.leads == [.run, .bike, .swim])
        #expect(a.leads == b.leads)
    }

    /// The threshold is a judgement and it is exercised at both sides. Four
    /// runs to one ride is 20% and the ride does not lead; seven to three is
    /// 30% exactly and it does.
    @Test("The 30% line is inclusive")
    func theThresholdIsInclusive() {
        let under = focus((1...4).map { session("r\($0)", .run) } + [session("b", .bike)])
        #expect(under.leads == [.run])

        let exactly = focus((1...7).map { session("r\($0)", .run) }
                            + (1...3).map { session("b\($0)", .bike) })
        #expect(exactly.leads == [.run, .bike], "30% did not clear its own threshold")
    }

    // MARK: The real plan

    /// The bundled plan must still read as a running plan — that is the
    /// behaviour the athlete has and asked to keep. If a future plan edit
    /// changes this, the header changes with it, which is the whole point; the
    /// test exists so that happens visibly rather than by surprise.
    @Test("The bundled plan reads as a running plan")
    func theBundledPlanIsARunningPlan() {
        let f = PlanStore.shared.focus
        #expect(f.soleLead == .run)
        #expect(f.supporting == [.bike, .swim])
        let runShare = f.shares[.run] ?? 0
        #expect(runShare > 0.5, "running is no longer the majority of this plan")
    }

    /// The header line for a real week, end to end.
    @Test("A real week's lead line names running and a distance")
    func aRealWeekProducesALeadLine() throws {
        let store = PlanStore.shared
        // Computed into a local first: `#expect`/`#require` decompose a call
        // into `Testing.__checkFunctionCall`, which is `rethrows`, and an
        // inline `first(where:)` then demands a `try` it does not need. Bitten
        // by this three times — patches 208, 210 and 213.
        let candidates = store.planWeeks.filter { store.plannedVolume(week: $0).runKm > 0 }
        let week = try #require(candidates.first)
        let line = try #require(store.leadLine(for: week))
        #expect(line.hasPrefix("of which"))
        #expect(line.contains("km running"))
    }
}
