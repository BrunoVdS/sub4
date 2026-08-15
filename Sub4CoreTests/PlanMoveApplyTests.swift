//
//  PlanMoveApplyTests.swift
//  Sub4CoreTests
//
//  A stored move changes what the app shows — patch 365, ADR-0003 §12.109.
//
//  THE TWO THAT DEFINE THE DESIGN
//  ------------------------------
//  `applyingTwiceIsApplyingOnce` and `movingItBackRestoresThePlannedDay` are
//  the same fact from two sides. `PlanCorrections.apply` overwrites
//  `Session.date`, so a store that applied a move to its OWN served plan would
//  destroy the planned day — and the planned day is exactly what putting a
//  session back requires. `PlanStore` keeps `planAsStored` for that reason, and
//  these two are what hold it there.
//
//  `theDayIndexFollowsTheMove` IS THE FEASIBILITY ARGUMENT
//  -------------------------------------------------------
//  §2.1 of the groundwork: `Session.date` is read in about ten places and every
//  one of them goes through `PlanStore`, so the override is applied once and
//  ten readers stay ignorant of corrections. `byDate` is the busiest of the
//  ten — every day-oriented screen is built from it — so if the choke point is
//  real, moving a session moves it in that index without anybody teaching the
//  index about moves.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A move rewrites the day a session was due")
@MainActor
struct PlanMoveApplyTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    /// The bundled plan, and the first session that carries a date. Real data
    /// rather than a fixture: the applier's whole job is to survive the plan
    /// this app actually ships.
    private func bundled() throws -> (plan: Plan, session: Session) {
        let plan = PlanStore.decodeBundle().plan
        let session = try #require(plan.sessions.first { $0.date != nil })
        return (plan, session)
    }

    // MARK: The applier

    @Test("A named session gets the day it was actually done")
    func aNamedSessionMoves() throws {
        let (plan, s) = try bundled()
        let planned = try #require(s.date)
        let moved = PlanCorrections.apply(plan, moves: [move(s.uid, "2026-08-17")])

        let after = try #require(moved.sessions.first { $0.uid == s.uid })
        #expect(after.date == "2026-08-17")
        #expect(planned != "2026-08-17", "the fixture proves nothing otherwise")
        // AND NOTHING ELSE ABOUT IT MOVED.
        #expect(after.weekUid == s.weekUid)
        #expect(after.seq == s.seq)
        #expect(after.discipline == s.discipline)
        #expect(after.title == s.title)
    }

    @Test("Every session nobody named is returned unchanged")
    func theOthersAreUntouched() throws {
        let (plan, s) = try bundled()
        let moved = PlanCorrections.apply(plan, moves: [move(s.uid, "2026-08-17")])

        #expect(moved.sessions.count == plan.sessions.count)
        for (before, after) in zip(plan.sessions, moved.sessions)
        where before.uid != s.uid {
            #expect(before.date == after.date)
        }
    }

    /// §3.1. A move changes the DAY a session was done, never its week
    /// membership — so the Week view and `plan_week_stat` keep the plan's own
    /// arithmetic, and a session can appear in one week's list and on a day
    /// inside the next one. That cost is disclosed, not hidden.
    @Test("The weeks are untouched")
    func theWeeksAreUntouched() throws {
        let (plan, s) = try bundled()
        let moved = PlanCorrections.apply(plan, moves: [move(s.uid, "2027-01-01")])

        #expect(moved.weeks == plan.weeks)
        #expect(moved.exercises.count == plan.exercises.count)
        let after = try #require(moved.sessions.first { $0.uid == s.uid })
        #expect(after.weekUid == s.weekUid,
                "a move that re-homed the week would change plan_week_stat")
    }

    /// §12.106.4. A plan revision reissues session uids, so a move naming an
    /// old one names nothing. The session stays where the plan put it — which
    /// is the whole reason an orphan was called harmless rather than fixed.
    @Test("A move naming no session changes nothing")
    func anOrphanedMoveChangesNothing() throws {
        let (plan, _) = try bundled()
        let moved = PlanCorrections.apply(
            plan, moves: [move("wk-99-never-existed", "2026-08-17")])

        #expect(moved.sessions.map(\.date) == plan.sessions.map(\.date))
    }

    @Test("No moves is the plan, unchanged")
    func noMovesIsANoOp() throws {
        let (plan, _) = try bundled()
        let moved = PlanCorrections.apply(plan, moves: [])
        #expect(moved.sessions.map(\.date) == plan.sessions.map(\.date))
    }

    @Test("Two moves move two sessions")
    func twoMovesMoveTwo() throws {
        let plan = PlanStore.decodeBundle().plan
        let dated = plan.sessions.filter { $0.date != nil }
        let a = try #require(dated.first)
        let b = try #require(dated.dropFirst().first)

        let moved = PlanCorrections.apply(
            plan, moves: [move(a.uid, "2026-08-17"), move(b.uid, "2026-08-18")])
        #expect(moved.sessions.first { $0.uid == a.uid }?.date == "2026-08-17")
        #expect(moved.sessions.first { $0.uid == b.uid }?.date == "2026-08-18")
    }

    // MARK: The store

    /// **THE REASON THERE ARE TWO PLANS.** Deriving from the served plan would
    /// mean the second application corrects a correction; deriving from the
    /// stored one means applying twice is applying once.
    @Test("Applying twice is applying once")
    func applyingTwiceIsApplyingOnce() throws {
        let (plan, s) = try bundled()
        let store = PlanStore()
        store.hydrate(from: plan)

        store.applyMoves([move(s.uid, "2026-08-17")])
        let once = store.plan.sessions.first { $0.uid == s.uid }?.date
        store.applyMoves([move(s.uid, "2026-08-17")])
        let twice = store.plan.sessions.first { $0.uid == s.uid }?.date

        #expect(once == "2026-08-17")
        #expect(twice == "2026-08-17")
    }

    /// **UNDO, AND IT NEEDS NO CODE OF ITS OWN.** `PlanMoveStore.clear` removes
    /// the record; the store then applies one fewer move, and the session is
    /// back on the day the plan asked for. That only works because the planned
    /// day was never overwritten.
    @Test("Moving it back restores the planned day")
    func movingItBackRestoresThePlannedDay() throws {
        let (plan, s) = try bundled()
        let planned = try #require(s.date)
        let store = PlanStore()
        store.hydrate(from: plan)

        store.applyMoves([move(s.uid, "2026-08-17")])
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == "2026-08-17")

        store.applyMoves([])
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == planned,
                "the planned day was overwritten and cannot be restored")
    }

    /// **THE FEASIBILITY ARGUMENT, TESTED.** `byDate` is the busiest of the ten
    /// readers of `Session.date` and it knows nothing about corrections. If the
    /// choke point is real, it follows a move for free.
    @Test("The day index follows the move without knowing about moves")
    func theDayIndexFollowsTheMove() throws {
        let (plan, s) = try bundled()
        let planned = try #require(s.date)
        let store = PlanStore()
        store.hydrate(from: plan)

        #expect(store.sessions(on: planned).contains { $0.uid == s.uid })
        #expect(!store.sessions(on: "2026-08-17").contains { $0.uid == s.uid })

        store.applyMoves([move(s.uid, "2026-08-17")])

        #expect(store.sessions(on: "2026-08-17").contains { $0.uid == s.uid },
                "the day index did not follow the move")
        #expect(!store.sessions(on: planned).contains { $0.uid == s.uid },
                "the session is on two days at once")
    }

    /// Hydration replaces the PLAN, not the athlete's corrections to it. The
    /// write-through can hydrate long after the launch handed the moves over.
    @Test("Hydrating again keeps the moves that were applied")
    func hydrationKeepsTheMoves() throws {
        let (plan, s) = try bundled()
        let store = PlanStore()
        store.hydrate(from: plan)
        store.applyMoves([move(s.uid, "2026-08-17")])

        store.hydrate(from: plan)
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == "2026-08-17",
                "a second hydration dropped a correction the athlete made")
    }

    /// **§12.109.3.** A freshly constructed store applies nothing, so the
    /// suites that read dates off `PlanStore()` cannot be moved by whatever
    /// `moves.json` the test host happens to hold.
    @Test("A new store applies no moves of its own")
    func aNewStoreIsUncorrected() throws {
        let store = PlanStore()
        let bundle = PlanStore.decodeBundle().plan
        #expect(store.plan.sessions.map(\.date) == bundle.sessions.map(\.date),
                "PlanStore() reached for the shared move store")
    }

    // MARK: What the plan tables must never see

    /// **THE CHECK 365 PROTECTS.** `plan_session` holds the plan; a move lives
    /// in `correction`. The importer seeds from `decodeBundle()`, which is
    /// pristine — so a moved date cannot reach the plan tables, and the plan
    /// read-back comparing that bundle against those rows is what would notice
    /// if it ever did.
    @Test("The bundle the importer seeds from carries no moves")
    func theSeedIsPristine() throws {
        let (_, s) = try bundled()
        let planned = try #require(s.date)
        let store = PlanStore()
        store.hydrate(from: PlanStore.decodeBundle().plan)
        store.applyMoves([move(s.uid, "2026-08-17")])

        // The served plan moved; the seed did not.
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == "2026-08-17")
        let seed = PlanStore.decodeBundle().plan
        #expect(seed.sessions.first { $0.uid == s.uid }?.date == planned,
                "a moved date reached the importer's seed")
    }
}
