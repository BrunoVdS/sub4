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

// PATCH 346a — `PlanStore()` AND NOT `PlanStore.shared`.
//
// Until 346 the singleton WAS the bundled plan. Since 346 it is whatever the
// app is serving, and in the test host that is the simulator's database: the
// test bundle launches the app, `Sub4Launch.begin()` runs, and the store
// hydrates from rows nothing in this target wrote. Three assertions failed the
// moment the constant flipped, on a stored plan holding 260 sessions where the
// bundle holds 261.
//
// Every check in this file is about `plan.json` — its coverage, its shape, its
// dates. `PlanStore()` decodes the bundle and nothing else, which is why 344
// made `init` internal. §12.57: a result that is true of the thing you are
// holding and false about the world.
//
// PATCH 350a — AND 346a MISSED FIVE OF THEM, BECAUSE THEY DO NOT SAY `.shared`.
//
// `WorkoutParser.coverage(_ store: PlanStore = .shared)`. Every call below read
// the singleton through that DEFAULT ARGUMENT, so 346a's sweep for the literal
// `PlanStore.shared` found the `#require` guards and not one of the five
// measurements standing next to them. The guard decoded the bundle; the count
// came from the database; nothing said so.
//
// It passed for four patches because both sides held 103 run sessions. Patch
// 349 put 105 in the bundle and left the simulator's database at 103, and two
// assertions failed naming a number nobody had changed. **A default argument is
// a call site that no grep for the value will show you.** §12.95.4.
//
// Every measurement now takes the SAME store the guard proved, and
// `coverageAnswersAboutTheStoreItIsGiven` is the control that would have caught
// this in 346a rather than in 350.

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
    /// Amended 12 August 2026, patch 351 — the Berlin week's Tuesday steady
    /// run became the rest day that breaks up the run block (§12.96), so one
    /// PARSED run leaves. Refused is untouched: the eleven are the by-feel
    /// pointers and the field test, and none of them moved.
    ///
    /// Amended 12 August 2026, patch 349 — weeks 4–6 rebuilt (§12.94): the
    /// Berlin run block added two run sessions, and every changed detail line
    /// reused a shape the parser already handles, so `refused` did not move.
    enum Expected {
        static let runSessions = 104
        static let parsed = 93
        static let refused = 11
    }

    @Test("The plan is available to the test bundle at all")
    func planLoads() throws {
        let store = PlanStore()
        // If this fails, the test target has no host application. Nothing else
        // in this file means anything until it passes.
        try #require(store.plan.sessions.isEmpty == false,
                     "plan.json did not load — set a host application on Sub4CoreTests")
        #expect(store.loadError == nil)
    }

    @Test("Every run session in the plan is either parsed or explicitly refused")
    func coverageIsTotal() throws {
        let store = PlanStore()
        try #require(store.plan.sessions.isEmpty == false)
        let c = WorkoutParser.coverage(store)
        // No third outcome. A session that is neither parsed nor refused has
        // fallen out of the audit entirely, which is how a gap goes unseen.
        #expect(c.total == c.parsed.count + c.refused.count)
        #expect(c.total == Expected.runSessions,
                "the plan has \(c.total) run sessions, expected \(Expected.runSessions)")
    }

    @Test("The parsed and refused counts have not moved")
    func countsAreUnchanged() throws {
        let store = PlanStore()
        try #require(store.plan.sessions.isEmpty == false)
        let c = WorkoutParser.coverage(store)
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
        let store = PlanStore()
        try #require(store.plan.sessions.isEmpty == false)
        for r in WorkoutParser.coverage(store).refused {
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
        let sessions = PlanStore().plan.sessions
        try #require(sessions.isEmpty == false)
        let uids = sessions.map(\.uid)
        #expect(Set(uids).count == uids.count, "the plan contains duplicate session uids")
    }

    /// THE NEGATIVE CONTROL FOR THE DEFAULT ARGUMENT — patch 350a.
    ///
    /// Counts the run sessions of the store by hand and requires `coverage` to
    /// have counted the same ones. Deliberately a second implementation rather
    /// than a call to the first: §12.43 forbids re-implementing a RULE, and
    /// this is the one place where re-deriving is the point — a control that
    /// called `coverage` to check `coverage` cannot fail.
    ///
    /// Today the bundle holds 104 and the simulator's database 103, so this
    /// fails outright if the argument is ever dropped again. After an import
    /// aligns them it stops being able to fail on that specific defect, which
    /// is honest: it goes on asserting that the answer is about the plan it was
    /// handed.
    @Test("Coverage answers about the store it is given")
    func coverageAnswersAboutTheStoreItIsGiven() throws {
        let store = PlanStore()
        try #require(store.plan.sessions.isEmpty == false)
        let planUids = Set(store.planWeeks.map(\.uid))
        let runs = store.plan.sessions.filter {
            $0.discipline == .run && planUids.contains($0.weekUid)
        }
        let c = WorkoutParser.coverage(store)
        #expect(c.total == runs.count,
                """
                    coverage counted \(c.total) run sessions where the store \
                    handed to it holds \(runs.count) — it is reading a \
                    different plan
                    """)
    }

    @Test("Parsing is deterministic")
    func parsingIsStable() throws {
        // One store, parsed twice: the subject is the parser, not the decoder.
        let store = PlanStore()
        try #require(store.plan.sessions.isEmpty == false)
        let a = WorkoutParser.coverage(store)
        let b = WorkoutParser.coverage(store)
        #expect(a.parsed.count == b.parsed.count)
        #expect(a.refused.count == b.refused.count)
        #expect(a.refused.map(\.id) == b.refused.map(\.id))
    }
}
