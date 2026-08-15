//
//  SessionChoiceTests.swift
//  Sub4CoreTests
//
//  The two decisions inside the reverse picker — patch 366,
//  rewritten at 366a. ADR-0003 §12.110, §12.110.7.
//
//  WHAT 366's VERSION OF THIS FILE COULD NOT SEE
//  ---------------------------------------------
//  It drove `needsAMove(sessionDate:activityDay:)` and every case passed. The
//  parameter was named `sessionDate` and the caller handed it `Session.date` —
//  which since 365 is the SERVED date, already carrying whatever move is
//  stored. A pure function tested with literals cannot notice that the value
//  reaching it in production is the wrong one, which is why
//  `thePlannedDateDoesNotFollowTheMove` and `movingItBackIsPuttingItBack`
//  exist: the first pins the source, the second drives the round trip through
//  a real store.
//
//  THE TWO THAT WOULD HAVE CAUGHT IT
//  ---------------------------------
//    · `thePlannedDateDoesNotFollowTheMove` — apply a move, then ask
//      `PlanStore.plannedDate`. If it answers the new day, the picker cannot
//      tell a move from putting one back and the undo is unreachable.
//    · `movingItBackIsPuttingItBack` — the whole gesture: move, then decide
//      again from the original day. The answer must be `.putBack`, because a
//      `.moveTo` there is a `correction` row naming the day the plan already
//      holds.
//

import Testing
import Foundation
@testable import Sub4

@Suite("What the reverse picker has to decide")
struct SessionChoiceTests {

    // MARK: The correction — §12.110.3, against the planned date

    /// **§12.110.3.** Choosing a session the plan already puts on the
    /// activity's day writes the match and nothing else — and, if a move is
    /// stored, takes it away.
    @Test("The activity's own day puts it back")
    func theActivitysOwnDayPutsItBack() {
        #expect(SessionChoice.correction(plannedDate: "2026-08-15",
                                         activityDay: "2026-08-15") == .putBack)
    }

    @Test("Another day is a move to that day")
    func anotherDayIsAMove() {
        #expect(SessionChoice.correction(plannedDate: "2026-08-14",
                                         activityDay: "2026-08-15")
                == .moveTo("2026-08-15"))
        #expect(SessionChoice.correction(plannedDate: "2026-08-16",
                                         activityDay: "2026-08-15")
                == .moveTo("2026-08-15"))
    }

    /// **THE MOVE IS TO THE ACTIVITY'S DAY, NEVER THE SESSION'S.** Returning
    /// the planned day would write a row that changes nothing and dismiss the
    /// sheet as though it had worked.
    @Test("The move names the activity's day")
    func theMoveNamesTheActivitysDay() {
        guard case .moveTo(let d) =
            SessionChoice.correction(plannedDate: "2026-08-10",
                                     activityDay: "2026-08-15") else {
            Issue.record("expected a move")
            return
        }
        #expect(d == "2026-08-15")
    }

    /// **NIL IS NOT THE ACTIVITY'S DAY.** The plan's logged prologue weeks
    /// carry sessions with no date at all. Giving one a day is a move — the one
    /// case where a `?? activityDay` fallback would silently record nothing.
    ///
    /// It also has no way back, for want of a day to go back to. Disclosed in
    /// §12.110.7; those weeks are behind this plan's start.
    @Test("A session with no planned date takes a move")
    func aDatelessSessionTakesAMove() {
        #expect(SessionChoice.correction(plannedDate: nil,
                                         activityDay: "2026-08-15")
                == .moveTo("2026-08-15"))
    }

    // MARK: window

    @Test("The window is seven days centred on the activity")
    func theWindowIsSevenDaysCentred() {
        let w = SessionChoice.window(around: "2026-08-15")
        #expect(w == ["2026-08-12", "2026-08-13", "2026-08-14", "2026-08-15",
                      "2026-08-16", "2026-08-17", "2026-08-18"])
        #expect(w.count == 2 * SessionChoice.radius + 1)
        #expect(w[SessionChoice.radius] == "2026-08-15",
                "the activity's own day is not in the middle")
    }

    /// **STRING MATH WOULD PASS EVERY TEST ABOVE AND FAIL THIS ONE.**
    @Test("The window survives a month boundary")
    func theWindowSurvivesAMonthBoundary() {
        #expect(SessionChoice.window(around: "2026-09-01")
                == ["2026-08-29", "2026-08-30", "2026-08-31", "2026-09-01",
                    "2026-09-02", "2026-09-03", "2026-09-04"])
    }

    @Test("The window survives a year boundary")
    func theWindowSurvivesAYearBoundary() {
        #expect(SessionChoice.window(around: "2027-01-01")
                == ["2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01",
                    "2027-01-02", "2027-01-03", "2027-01-04"])
    }

    /// **THE MIDNIGHT ANCHOR'S BUG, AND IT IS INSIDE THIS PLAN.**
    ///
    /// 25 October 2026 is twenty-five hours long in Brussels. Anchored at local
    /// midnight, one day of 86 400 s from the 24th lands at 23:00 on the 25th
    /// and the step after that lands on the 25th AGAIN — a window with a
    /// duplicate and a missing day. Anchored at noon the hour is absorbed.
    ///
    /// On a machine running UTC this passes either way, which is not a reason
    /// to leave it out: the device this ships to is on Europe/Brussels and so
    /// is the machine the suite is run on.
    @Test("The window survives a daylight-saving change")
    func theWindowSurvivesADaylightSavingChange() {
        let w = SessionChoice.window(around: "2026-10-25")
        #expect(w == ["2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25",
                      "2026-10-26", "2026-10-27", "2026-10-28"])
        #expect(Set(w).count == w.count, "a day appears twice in the window")
    }

    @Test("The spring change too")
    func theWindowSurvivesTheSpringChange() {
        let w = SessionChoice.window(around: "2027-03-28")
        #expect(w == ["2027-03-25", "2027-03-26", "2027-03-27", "2027-03-28",
                      "2027-03-29", "2027-03-30", "2027-03-31"])
        #expect(Set(w).count == w.count)
    }

    /// **§12.15.** A key the formatter cannot read returns the key itself, not
    /// an empty list — an empty picker saying "the plan has nothing within
    /// three days" would be a false statement about the plan.
    @Test("An unreadable day yields itself, not nothing")
    func anUnreadableDayYieldsItself() {
        #expect(SessionChoice.window(around: "not-a-day") == ["not-a-day"])
        #expect(SessionChoice.window(around: "") == [""])
    }

    @Test("The radius is honoured")
    func theRadiusIsHonoured() {
        #expect(SessionChoice.window(around: "2026-08-15", radius: 0)
                == ["2026-08-15"])
        #expect(SessionChoice.window(around: "2026-08-15", radius: 1)
                == ["2026-08-14", "2026-08-15", "2026-08-16"])
    }

    /// The window is what the picker offers, so it has to be in the order the
    /// picker's own sort assumes — ascending, with the activity's day in the
    /// middle rather than at the front.
    @Test("The window is ascending")
    func theWindowIsAscending() {
        let w = SessionChoice.window(around: "2026-11-03")
        #expect(w == w.sorted())
    }
}

// MARK: - Where the picker gets the date it decides on

/// **THE HALF 366 COULD NOT TEST.** `SessionChoice.correction` is pure and its
/// suite above passes on literals. What 366 got wrong was the VALUE handed to
/// it, and only a real store can show that.
@Suite("The planned date is not the served one")
@MainActor
struct PlannedDateTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    private func bundled() throws -> (store: PlanStore, session: Session,
                                      planned: String) {
        let plan = PlanStore.decodeBundle().plan
        let session = try #require(plan.sessions.first { $0.date != nil })
        let store = PlanStore()
        store.hydrate(from: plan)
        return (store, session, try #require(session.date))
    }

    /// **THE DEFECT, IN ONE ASSERTION — §12.110.7.** If `plannedDate` follows
    /// the move it is `Session.date` with extra steps, and the picker is back
    /// to being unable to tell a move from putting one back.
    @Test("The planned date does not follow the move")
    func thePlannedDateDoesNotFollowTheMove() throws {
        let (store, s, planned) = try bundled()
        #expect(store.plannedDate(of: s.uid) == planned)

        store.applyMoves([move(s.uid, "2026-08-17")])

        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date
                == "2026-08-17", "the served plan did not move")
        #expect(store.plannedDate(of: s.uid) == planned,
                "plannedDate followed the move — it is reading the served plan")
    }

    /// **THE ROUND TRIP, WHICH IS THE WHOLE FIX.** Move a session, then decide
    /// again from an activity on its ORIGINAL day. `.moveTo` there is a
    /// `correction` row naming the day the plan already holds — the row
    /// §12.110.3 forbids, written by the code that cites it.
    @Test("Moving it back is putting it back, not a move")
    func movingItBackIsPuttingItBack() throws {
        let (store, s, planned) = try bundled()
        store.applyMoves([move(s.uid, "2026-08-17")])

        // What 366 asked, on the served plan.
        let served = try #require(
            store.plan.sessions.first { $0.uid == s.uid }?.date)
        #expect(served != planned, "the fixture proves nothing otherwise")

        // What 366a asks.
        #expect(SessionChoice.correction(
            plannedDate: store.plannedDate(of: s.uid),
            activityDay: planned) == .putBack,
                "putting a moved session back writes a correction row naming the day the plan already holds")
    }

    /// And moving it somewhere ELSE is still a move, so the fix did not buy
    /// §12.110.3 by making every choice a no-op.
    @Test("Moving a moved session to a third day is still a move")
    func aThirdDayIsStillAMove() throws {
        let (store, s, _) = try bundled()
        store.applyMoves([move(s.uid, "2026-08-17")])

        #expect(SessionChoice.correction(
            plannedDate: store.plannedDate(of: s.uid),
            activityDay: "2026-08-19") == .moveTo("2026-08-19"))
    }

    /// A uid this plan does not contain answers nil — a move made against a
    /// superseded revision names nothing (§12.106.4), and nil is the honest
    /// answer rather than a day it invented.
    @Test("A uid the plan does not hold has no planned date")
    func anUnknownUidHasNoPlannedDate() throws {
        let (store, _, _) = try bundled()
        #expect(store.plannedDate(of: "wk-99-never-existed") == nil)
    }

    /// Hydration replaces the plan, so the planned dates have to be rebuilt
    /// from the new one — and cleared first, because a hydration can REMOVE a
    /// session and a merge would leave its planned day alive.
    @Test("Hydrating rebuilds the planned dates")
    func hydrationRebuildsThePlannedDates() throws {
        let (store, s, planned) = try bundled()
        store.applyMoves([move(s.uid, "2026-08-17")])

        store.hydrate(from: PlanStore.decodeBundle().plan)
        #expect(store.plannedDate(of: s.uid) == planned)
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date
                == "2026-08-17",
                "hydration dropped a correction the athlete made")
    }

    /// **§12.109.3, RESTATED FOR THIS INDEX.** A freshly constructed store has
    /// planned dates matching the bundle, so no suite reading them can be
    /// moved by whatever `moves.json` the test host happens to hold.
    ///
    /// **THIS IS THE TEST THAT FOUND §12.110.9.** 366a built `plannedDates` in
    /// `derive()`, which `init` does not call — so a constructed store answered
    /// nil for every session and 40 of these failed on the first run. Left
    /// exactly as it was written: the suite was right.
    @Test("A new store's planned dates are the bundle's")
    func aNewStoreIsUncorrected() {
        let store = PlanStore()
        for s in PlanStore.decodeBundle().plan.sessions where s.date != nil {
            #expect(store.plannedDate(of: s.uid) == s.date)
        }
    }

    /// **THE GENERAL FORM OF §12.110.9, SAID OUT LOUD — patch 366c.**
    ///
    /// `rebuildIndexes` carries a comment from 344 about four things moving
    /// together or the store being worse than either half. 366a added a fifth
    /// and put it beside the OTHER caller, so `init` populated four of five.
    ///
    /// The rule is not "plannedDates works"; it is that ONE call populates all
    /// of them, so a store that was only constructed answers every question the
    /// store can answer. A sixth index built in `derive` fails this without
    /// anybody having to think of a sixth test.
    @Test("A constructed store has every index, not four of five")
    func aConstructedStoreHasEveryIndex() throws {
        let store = PlanStore()
        let s = try #require(store.plan.sessions.first { $0.date != nil })
        let day = try #require(s.date)

        #expect(store.sessions(on: day).contains { $0.uid == s.uid },
                "byDate is empty on a constructed store")
        #expect(store.plannedDate(of: s.uid) == day,
                "plannedDates is empty on a constructed store — built in derive(), which init does not call")
        #expect(store.week(for: s) != nil,
                "weeksByUid is empty on a constructed store")
    }
}
