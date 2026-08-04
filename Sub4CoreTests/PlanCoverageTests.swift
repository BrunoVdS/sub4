//
//  PlanCoverageTests.swift
//  Sub4CoreTests
//
//  The workout parser against the whole bundled plan — plan step 1.2.4, the
//  "all 103 plan run prescriptions" fixture.
//
//  WHY A COUNT AND NOT A LIST OF EXPECTED WORKOUTS
//  ----------------------------------------------
//  `WorkoutParser.coverage()` already walks every run session in the plan and
//  sorts the results into parsed and refused. The diagnostic screen has shown
//  those two numbers for months. What it cannot do is fail a build.
//
//  The value here is a ratchet, not a specification. The parser is deliberately
//  fail-closed: a prescription it does not fully understand is REFUSED rather
//  than approximated, because a structured workout built from a guess sends the
//  athlete out to run the wrong session. That design only holds if the refusal
//  set stays small and known. If a change makes the parser refuse a session it
//  used to handle, that is a regression the diagnostic would show and nobody
//  would notice; if it makes the parser accept one it used to refuse, that is
//  either progress or a new way to be confidently wrong, and it should have to
//  be looked at.
//
//  So the assertion is: the counts are what they were when this was written, and
//  changing them means changing this file on purpose.
//
//  A NOTE ON THE HOST APPLICATION
//  -----------------------------
//  `PlanStore` loads `plan.json` from `Bundle.main`. In a unit-test target with
//  a host application that is the app bundle and this works. Configured without
//  a host, `Bundle.main` is the test runner, the plan is empty, and every count
//  below reads zero. The first test distinguishes those two failures, because
//  "the plan did not load" and "the parser broke" look identical in a count
//  mismatch and have nothing to do with each other.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct PlanCoverageTests {

    /// Recorded 3 August 2026, re-confirmed 5 August against the current
    /// 279,078-byte seed (patch 246): 37 weeks, 260 sessions. These are the
    /// numbers the audit screen reports today. `PlanSeedTests` freezes the
    /// seed's bytes; this file freezes what the parser makes of them.
    ///
    /// Update them ONLY together with the change that moved them, in the same
    /// commit, with the reason in the message. A silent edit here to make a red
    /// test green is the one thing this file exists to prevent.
    enum Expected {
        static let runSessions = 103
        static let parsed = 92
        static let refused = 11
    }

    @Test("The plan is available to the test bundle at all")
    func planLoads() throws {
        let store = PlanStore.shared
        // If this fails, the test target has no host application. Nothing else
        // in this file means anything until it passes.
        try #require(store.plan.sessions.isEmpty == false,
                     "plan.json did not load — set a host application on Sub4CoreTests")
        #expect(store.loadError == nil)
    }

    @Test("Every run session in the plan is either parsed or explicitly refused")
    func coverageIsTotal() throws {
        try #require(PlanStore.shared.plan.sessions.isEmpty == false)
        let c = WorkoutParser.coverage()
        // No third outcome. A session that is neither parsed nor refused has
        // fallen out of the audit entirely, which is how a gap goes unseen.
        #expect(c.total == c.parsed.count + c.refused.count)
        #expect(c.total == Expected.runSessions,
                "the plan has \(c.total) run sessions, expected \(Expected.runSessions)")
    }

    @Test("The parsed and refused counts have not moved")
    func countsAreUnchanged() throws {
        try #require(PlanStore.shared.plan.sessions.isEmpty == false)
        let c = WorkoutParser.coverage()
        #expect(c.parsed.count == Expected.parsed,
                "parser now handles \(c.parsed.count) sessions, was \(Expected.parsed)")
        #expect(c.refused.count == Expected.refused,
                "parser now refuses \(c.refused.count) sessions, was \(Expected.refused)")
    }

    /// The fail-closed contract, stated as an assertion. A refusal without a
    /// reason is indistinguishable from a crash the app swallowed, and the
    /// reason is what the audit screen prints.
    @Test("Every refusal carries a reason and an identity")
    func refusalsExplainThemselves() throws {
        try #require(PlanStore.shared.plan.sessions.isEmpty == false)
        for r in WorkoutParser.coverage().refused {
            #expect(r.reason.isEmpty == false, "session \(r.id) refused with no reason")
            #expect(r.id.isEmpty == false)
        }
    }

    /// Two sessions sharing a uid would make notes, matches and review
    /// references ambiguous — `PLAN-02` in the review register. Cheap to check
    /// here, and it covers the imported plan as well as the bundled one once
    /// plans become editable.
    @Test("Session uids are unique across the whole plan")
    func sessionUidsAreUnique() throws {
        let sessions = PlanStore.shared.plan.sessions
        try #require(sessions.isEmpty == false)
        let uids = sessions.map(\.uid)
        #expect(Set(uids).count == uids.count, "the plan contains duplicate session uids")
    }

    @Test("Parsing is deterministic")
    func parsingIsStable() throws {
        try #require(PlanStore.shared.plan.sessions.isEmpty == false)
        let a = WorkoutParser.coverage()
        let b = WorkoutParser.coverage()
        #expect(a.parsed.count == b.parsed.count)
        #expect(a.refused.count == b.refused.count)
        #expect(a.refused.map(\.id) == b.refused.map(\.id))
    }
}
