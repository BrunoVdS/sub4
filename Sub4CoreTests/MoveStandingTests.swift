//
//  MoveStandingTests.swift
//  Sub4CoreTests
//
//  Putting a session back, from the session side — patch 367,
//  ADR-0003 §12.111.
//
//  WHY THIS IS `MatchStandingTests`' TWIN
//  --------------------------------------
//  359 built `MatchStanding` because a recorded choice and no choice at all
//  rendered identically in this sheet. `MoveStanding` answers the same question
//  about the DAY, so this suite asks the same things of it: does every state
//  say something, does the flag the control is enabled on distinguish them, and
//  does the decision read the value that is actually honest.
//
//  THE ONE THAT WOULD CATCH THE 366 DEFECT COMING BACK
//  ---------------------------------------------------
//  `theStandingDoesNotComeFromTheServedDate`. `Session.date` on a served plan
//  already carries the move, so deriving "is it moved" from it asks the
//  corrected value whether it was corrected — §12.110.7 exactly. The test
//  drives the whole store: apply a move, then assert the standing still names
//  the PLANNED day rather than the day the session now sits on.
//
//  AND THE ONE THAT CLOSES A DISCLOSED GAP
//  ---------------------------------------
//  `aDatelessSessionCanBePutBack`. 366a disclosed that a session the plan gives
//  no date could be moved and never put back. It runs against the eight such
//  sessions the bundled plan actually holds, not a fixture.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Whether a session sits where the plan put it")
struct MoveStandingTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    // MARK: The three states

    @Test("No stored move is not moved")
    func noStoredMoveIsNotMoved() {
        #expect(MoveStanding.of(storedMove: nil, plannedDate: "2026-08-11")
                == .notMoved)
        #expect(MoveStanding.of(storedMove: nil, plannedDate: nil) == .notMoved)
    }

    /// **§12.111.2.** The standing names the day the PLAN asked for, which is
    /// where the button puts it back to — never the day it currently sits on.
    @Test("A stored move names the planned day")
    func aStoredMoveNamesThePlannedDay() {
        let s = MoveStanding.of(storedMove: move("wk-03-x", "2026-08-12"),
                                plannedDate: "2026-08-11")
        #expect(s == .movedFrom("2026-08-11"))
    }

    /// **§12.110.7's GAP, NAMED.** The plan gives some sessions no day at all.
    /// There is nothing to go back to and nothing needed — removing the row
    /// returns the session to having none.
    @Test("A move on a session the plan never dated says so")
    func aDatelessSessionSaysSo() {
        #expect(MoveStanding.of(storedMove: move("log-p1-x", "2026-08-12"),
                                plannedDate: nil) == .movedFromNoDay)
    }

    /// **366 COULD WRITE A ROW NAMING THE PLANNED DAY; 366a CANNOT.** One
    /// written by the older build must still count as moved, or it is stranded:
    /// invisible to the control that exists to remove it.
    @Test("A row naming the planned day still counts as moved")
    func aRowNamingThePlannedDayStillCounts() {
        let s = MoveStanding.of(storedMove: move("wk-03-x", "2026-08-11"),
                                plannedDate: "2026-08-11")
        #expect(s == .movedFrom("2026-08-11"))
        #expect(s.isMoved, "a row 366 could write would be unclearable")
    }

    // MARK: What the sheet prints

    @Test("Only a moved session can be put back")
    func onlyAMovedSessionIsMoved() {
        #expect(!MoveStanding.notMoved.isMoved)
        #expect(MoveStanding.movedFrom("2026-08-11").isMoved)
        #expect(MoveStanding.movedFromNoDay.isMoved)
    }

    /// **§12.54.2, TURNED ON THE TYPE ITSELF.** Three states sharing one
    /// sentence would defeat the rule from the inside: the footer would be
    /// present on every state and distinguish none of them.
    @Test("Every standing says something, and something different")
    func everyStandingSaysSomethingDifferent() {
        let all: [MoveStanding] = [.notMoved, .movedFrom("2026-08-11"),
                                   .movedFromNoDay]
        let lines = all.map(\.line)
        let actions = all.map(\.action)

        #expect(Set(lines).count == all.count, "two states share a footer")
        #expect(Set(actions).count == all.count, "two states share a button")
        for l in lines { #expect(!l.isEmpty) }
        for a in actions { #expect(!a.isEmpty) }
    }

    /// The moved footer has to name the day, or the athlete is asked to undo
    /// something without being told where it goes.
    @Test("The moved line names the planned day")
    func theMovedLineNamesTheDay() {
        #expect(MoveStanding.movedFrom("2026-08-11").line.contains("2026-08-11"))
    }

    /// The button says where, in the form the rest of the app writes days.
    @Test("The button names the day it puts it back on")
    func theButtonNamesTheDay() {
        let a = MoveStanding.movedFrom("2026-08-11").action
        #expect(a.contains("11 August"),
                "the button does not say where the session is going")
        // A key the formatter cannot read falls back to the key rather than to
        // an empty button. §12.15.
        #expect(MoveStanding.movedFrom("not-a-day").action.contains("not-a-day"))
    }
}

// MARK: - Through the stores

/// **THE HALF A PURE FUNCTION CANNOT PROVE.** `MoveStanding.of` is correct on
/// literals in every case above; 366's defect was the VALUE reaching the
/// equivalent function, not the function. These drive the real stores.
@Suite("Putting it back, end to end")
@MainActor
struct PutBackTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    private func hydrated() -> PlanStore {
        let store = PlanStore()
        store.hydrate(from: PlanStore.decodeBundle().plan)
        return store
    }

    /// **THE 366 DEFECT, GUARDED FOR THE UNDO — §12.110.7.** After the move the
    /// served date IS the moved day. A standing derived from it would report
    /// `movedFrom("2026-08-17")` — the day it is already on — and the button
    /// would offer to put it back where it stands.
    @Test("The standing does not come from the served date")
    func theStandingDoesNotComeFromTheServedDate() throws {
        let store = hydrated()
        let s = try #require(store.plan.sessions.first { $0.date != nil })
        let planned = try #require(s.date)

        store.applyMoves([move(s.uid, "2026-08-17")])

        let served = try #require(
            store.plan.sessions.first { $0.uid == s.uid }?.date)
        #expect(served == "2026-08-17", "the fixture proves nothing otherwise")

        let standing = MoveStanding.of(storedMove: move(s.uid, "2026-08-17"),
                                       plannedDate: store.plannedDate(of: s.uid))
        #expect(standing == .movedFrom(planned),
                "the standing named the day the session already sits on")
    }

    /// The round trip the button performs: one fewer move, and the session is
    /// back where the plan asked. 365 built `applyMoves` so this needs no code
    /// of its own; 367 is what finally calls it from the session side.
    @Test("Putting it back restores the planned day")
    func puttingItBackRestoresThePlannedDay() throws {
        let store = hydrated()
        let s = try #require(store.plan.sessions.first { $0.date != nil })
        let planned = try #require(s.date)

        store.applyMoves([move(s.uid, "2026-08-17")])
        #expect(store.sessions(on: "2026-08-17").contains { $0.uid == s.uid })

        store.applyMoves([])

        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == planned)
        #expect(store.sessions(on: planned).contains { $0.uid == s.uid },
                "the day index did not follow the session back")
        #expect(!store.sessions(on: "2026-08-17").contains { $0.uid == s.uid },
                "the session is on two days at once")
        #expect(MoveStanding.of(storedMove: nil,
                                plannedDate: store.plannedDate(of: s.uid))
                == .notMoved)
    }

    /// **§12.110.7's GAP, CLOSED — and against the plan's own data.** The
    /// bundled plan holds eight sessions with no date. Moving one gives it a
    /// day; putting it back takes the day away, which is the whole of the undo
    /// for a case 366a said had none.
    @Test("A session the plan never dated can be put back")
    func aDatelessSessionCanBePutBack() throws {
        let store = hydrated()
        let s = try #require(
            store.plan.sessions.first(where: { $0.date == nil }),
            "the bundled plan holds no undated session")
        #expect(store.plannedDate(of: s.uid) == nil)

        store.applyMoves([move(s.uid, "2026-08-17")])
        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date
                == "2026-08-17")
        #expect(store.sessions(on: "2026-08-17").contains { $0.uid == s.uid },
                "an undated session did not appear on the day it was given")
        #expect(MoveStanding.of(storedMove: move(s.uid, "2026-08-17"),
                                plannedDate: store.plannedDate(of: s.uid))
                == .movedFromNoDay)

        store.applyMoves([])

        #expect(store.plan.sessions.first { $0.uid == s.uid }?.date == nil,
                "the session kept a day the plan never gave it")
        #expect(!store.sessions(on: "2026-08-17").contains { $0.uid == s.uid },
                "the session still shows on the day it was put back from")
    }

    /// Clearing a move for a session that has none writes nothing — no file, so
    /// no `noteAuthoredChange`, so no authored run that may delete (§12.94,
    /// §12.104). The button is disabled in that state; this is what happens if
    /// a tap gets past it anyway.
    @Test("Clearing a move that does not exist writes nothing")
    func clearingNothingWritesNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let moves = PlanMoveStore(directory: dir)
        let file = dir.appendingPathComponent("moves.json")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try moves.clear("wk-99-never-existed")

        #expect(!FileManager.default.fileExists(atPath: file.path),
                "clearing nothing wrote a file")
        #expect(moves.count == 0)
    }

    /// And clearing one that does exist removes it and only it.
    @Test("Clearing a move removes that move and no other")
    func clearingRemovesOnlyThatMove() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let moves = PlanMoveStore(directory: dir)
        try moves.set("2026-08-17", for: "wk-a")
        try moves.set("2026-08-18", for: "wk-b")
        #expect(moves.count == 2)

        try moves.clear("wk-a")

        #expect(moves.count == 1)
        #expect(moves.movedTo("wk-a") == nil)
        #expect(moves.movedTo("wk-b") == "2026-08-18")

        // And it survives a reload — the removal reached the file, not just
        // memory. §12.92: read cleanly is not the same as holds content.
        let reread = PlanMoveStore(directory: dir)
        #expect(reread.movedTo("wk-a") == nil)
        #expect(reread.movedTo("wk-b") == "2026-08-18")
    }
}
