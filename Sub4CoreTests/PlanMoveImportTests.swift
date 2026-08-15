//
//  PlanMoveImportTests.swift
//  Sub4CoreTests
//
//  The database learns about the moves — patch 363, ADR-0003 §12.107.
//
//  THE ONE THAT MATTERS IS `anOrphanedMoveDoesNotBlockThePrune`
//  ------------------------------------------------------------
//  `pruneCommutes` refuses to run while any commute decision is unresolved,
//  because that keep-set is built from ids that RESOLVED and an unresolved
//  decision cannot protect its own row. Copying that guard here would look
//  careful and would be wrong twice over: nothing in a move can be unresolved,
//  so the guard could not fail (§12.69), and an orphaned move — which a plan
//  revision produces for free — would freeze the prune for ever.
//
//  So the guard is deliberately absent, and this suite is where that absence is
//  held rather than in a comment.
//
//  AND `theUidIsWrittenVerbatim`
//  -----------------------------
//  Every other writer of `correction` and of `match_decision` resolves a Strava
//  id through `activity_alias` before it writes — the canonical-id trap, three
//  times over (§12.9, §12.19, patch 289). A move is the exception: both sides
//  hold the plan's own uid. A future reader who "fixes" this by adding a
//  resolution step would hand every move an id that matches nothing, and the
//  comparison would report losses that are a join somebody got wrong.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A moved session reaches the database and comes back")
@MainActor
struct PlanMoveImportTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)
    private let session = "wk-03-sun-long"
    private let monday = "2026-08-17"

    private func ride(_ id: String = "19580875358") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 4_000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    private func commute(_ id: String = "19580875358") -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: true, decided: decidedAt)
    }

    private func moveRows(_ db: Sub4Database) throws -> [Row] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT * FROM correction
                WHERE subjectKind = 'planSession' AND field = 'date'
                ORDER BY subjectID
                """)
        }
    }

    private func allCorrections(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM correction") ?? 0
        }
    }

    // MARK: The row

    @Test("A move becomes one correction row, and every column says what it should")
    func theMoveArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        moves: [move(session, monday)])

        #expect(report.movesSeen == 1)
        #expect(report.movesImported == 1)
        #expect(report.movesUpdated == 0)

        let rows = try moveRows(db)
        #expect(rows.count == 1)
        let r = try #require(rows.first)
        #expect(r["subjectKind"] as String? == "planSession")
        #expect(r["field"] as String? == "date")
        #expect(r["value"] as String? == monday)
        // Provenance, not an argument — the same sentence on every row.
        #expect(r["reason"] as String? == Sub4Import.moveReason)
        // THE DATE THE ATHLETE DECIDED, not the day moved to and not the day
        // of the import.
        #expect((r["authoredUTC"] as String? ?? "").hasPrefix("2026-"))
        #expect(r["authoredUTC"] as String? != monday)
    }

    /// **THE EXCEPTION TO THE CANONICAL-ID TRAP.** Every other writer of this
    /// table resolves a Strava id through `activity_alias` first. A move names
    /// a plan session, and both sides hold the plan's own uid — so adding a
    /// resolution step here would hand every move an id matching nothing.
    @Test("The session uid is written verbatim, with no alias resolution")
    func theUidIsWrittenVerbatim() throws {
        let db = try Sub4Database.inMemory()
        // An activity IS present, so an accidental resolution step would have
        // something to resolve against and could plausibly succeed at writing
        // the wrong thing.
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               moves: [move(session, monday)])

        let rows = try moveRows(db)
        let r = try #require(rows.first)
        #expect(r["subjectID"] as String? == session)
        #expect(r["subjectID"] as String? != "19580875358")
    }

    @Test("A second import refreshes the row rather than duplicating it")
    func aSecondImportRefreshes() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        moves: [move(session, "2026-08-18")])

        #expect(second.movesImported == 0)
        #expect(second.movesUpdated == 1)
        let rows = try moveRows(db)
        #expect(rows.count == 1, "the unique key is accountID/kind/subject/field")
        // BOUND, NOT CHAINED. `rows.first?["value"]` is a double optional and
        // `as String?` would be asking about the outer one — the trap 343b
        // named on `Fuel??` and this project has now hit three times.
        let refreshed = try #require(rows.first)
        #expect(refreshed["value"] as String? == "2026-08-18")
    }

    @Test("Two moved sessions are two rows")
    func twoMovesAreTwoRows() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db, activities: [], shoes: [],
            moves: [move(session, monday), move("wk-04-tue-easy", "2026-08-20")])

        #expect(report.movesImported == 2)
        let rows = try moveRows(db)
        #expect(rows.count == 2)
    }

    // MARK: Two families, one table

    /// The patch's headline. `correction` now has two claimants, each counted
    /// by its own comparison, and nothing left over.
    @Test("A move and a commute decision agree separately")
    func aMoveAndACommuteAgreeSeparately() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride()]
        let commutes = [commute()]
        let moves = [move(session, monday)]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: commutes, moves: moves)

        let corrections = try allCorrections(db)
        #expect(corrections == 2)

        let r = try SemanticVerifier.verify(db, activities: acts,
                                            commutes: commutes, moves: moves)
        func check(_ name: String) throws -> VerificationCheck {
            try #require(r.checks.first { $0.name == name })
        }
        let commuteCheck = try check("commute corrections")
        let moveCheck = try check("session moves")
        let unclaimed = try check("unclaimed corrections")

        #expect(commuteCheck.found == "1")
        #expect(commuteCheck.passed)
        #expect(moveCheck.expected == "1")
        #expect(moveCheck.found == "1")
        #expect(moveCheck.passed)
        #expect(unclaimed.found == "0", "both families are claimed")
        #expect(r.passed)
    }

    /// §12.99. Nothing hydrates `PlanMoveStore` from the database, so this
    /// comparison's expectation comes from a file the database does not feed.
    /// It is the first check added since B1 that could actually disagree.
    @Test("The moved sessions count as evidence")
    func theMoveComparisonIsIndependent() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        #expect(HydratedStores.entry(for: "session moves") == nil)
        #expect(r.independentChecks.contains { $0.name == "session moves" })
    }

    /// §12.69. A comparison that counted the whole table, or nothing at all,
    /// would pass every other test in this file.
    @Test("The move comparison can fail")
    func theMoveComparisonCanFail() throws {
        let db = try Sub4Database.inMemory()
        let moves = [move(session, monday)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], moves: moves)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM correction")
        }

        let r = try SemanticVerifier.verify(db, activities: [], moves: moves)
        let check = try #require(r.checks.first { $0.name == "session moves" })
        #expect(check.expected == "1")
        #expect(check.found == "0")
        #expect(!check.passed)
    }

    // MARK: The prune

    @Test("A move the store no longer holds is removed")
    func theWithdrawnMoveIsRemoved() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)],
                               reconcile: .run)
        let before = try moveRows(db)
        #expect(before.count == 1)

        let after = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       moves: [], reconcile: .run)
        #expect(after.movesRemoved == 1)
        let left = try moveRows(db)
        #expect(left.isEmpty)
    }

    /// §12.20. The prune runs only when the gate said so — and the gate is
    /// `AppStores.reconcileRequires`, which names `moves.json` since 363.
    @Test("The prune waits for reconciliation")
    func thePruneWaitsForReconciliation() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)],
                               reconcile: .run)

        let after = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       moves: [],
                                       reconcile: .skipped("a store could not be read"))
        #expect(after.movesRemoved == 0)
        let kept = try moveRows(db)
        #expect(kept.count == 1, "a refused gate deleted a row")
    }

    /// **THE ASYMMETRY, AND THE REASON THIS SUITE EXISTS.**
    ///
    /// `pruneCommutes` holds back entirely while any decision is unresolved.
    /// Copying that here would freeze the prune the first time a plan revision
    /// reissued a uid — and a move cannot be unresolved in the first place,
    /// because there is no lookup. So the orphan is counted, kept, and does not
    /// stop the withdrawn move next to it being removed.
    @Test("An orphaned move is counted and kept, and does not block the prune")
    func anOrphanedMoveDoesNotBlockThePrune() throws {
        let db = try Sub4Database.inMemory()

        // Two moves; the database holds no plan at all, so BOTH are orphans.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday),
                                       move("wk-04-tue-easy", "2026-08-20")],
                               reconcile: .run)
        let both = try moveRows(db)
        #expect(both.count == 2)

        let after = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       moves: [move(session, monday)],
                                       reconcile: .run)
        #expect(after.movesSeen == 1)
        #expect(after.movesOrphaned == 1, "no stored plan holds this uid")
        #expect(after.movesRemoved == 1,
                "the orphan held the prune back — a plan revision would freeze it")
        let rows = try moveRows(db)
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor["subjectID"] as String? == session)
    }

    @Test("A move whose session the plan still holds is not counted as an orphan")
    func aLiveMoveIsNotAnOrphan() throws {
        let db = try Sub4Database.inMemory()
        // Seed a plan so `plan_session` has uids to be known by, then move one
        // of them. The importer's orphan check reads the table, not the store.
        let plan = try #require(PlanStore.decodeBundle().plan)
        let uid = try #require(plan.sessions.first?.uid)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], plan: plan)

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        moves: [move(uid, monday)], plan: plan)
        #expect(report.movesSeen == 1)
        #expect(report.movesOrphaned == 0)
        #expect(report.movesImported == 1)
    }

    /// A claim scoped to one half of the key would take the other family with
    /// it. This is the assertion that says `pruneMoves` names both.
    @Test("The prune leaves the commute decisions alone")
    func thePruneLeavesTheCommutesAlone() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()],
                               moves: [move(session, monday)],
                               reconcile: .run)
        let seeded = try allCorrections(db)
        #expect(seeded == 2)

        // The moves are withdrawn; the commute decision is not.
        let after = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                                       commutes: [commute()], moves: [],
                                       reconcile: .run)
        #expect(after.movesRemoved == 1)
        #expect(after.correctionsRemoved == 0)
        let left = try allCorrections(db)
        #expect(left == 1)
        let moveRowsLeft = try moveRows(db)
        #expect(moveRowsLeft.isEmpty)
    }

    /// And the other direction: withdrawing the commute decision must not take
    /// the move with it.
    @Test("The commute prune leaves the moves alone")
    func theCommutePruneLeavesTheMovesAlone() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()],
                               moves: [move(session, monday)],
                               reconcile: .run)

        let after = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                                       commutes: [],
                                       moves: [move(session, monday)],
                                       reconcile: .run)
        #expect(after.correctionsRemoved == 1)
        #expect(after.movesRemoved == 0)
        let survivors = try moveRows(db)
        #expect(survivors.count == 1)
    }

    // MARK: The report

    @Test("The paste says what the moves did, including the zeros")
    func thePasteIsUnconditional() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [])
        let lines = report.diagnosticLines

        // §12.15 and 266c. A device that has moved nothing must print a zero
        // rather than nothing at all — an absent line and a zero read the same
        // to somebody scanning a paste, and only one of them is an answer.
        #expect(lines.contains { $0.contains("moved sessions: 0 seen") })
        #expect(lines.contains {
            $0.contains("naming a session no stored plan holds: 0")
        })
    }

    @Test("The key comes from the writer, checked against what the writer wrote")
    func theFamilyMatchesTheRow() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])
        let r = try #require(try moveRows(db).first)

        #expect(r["subjectKind"] as String? == ComparedCorrections.planMove.subjectKind)
        #expect(r["field"] as String? == ComparedCorrections.planMove.field)
        #expect(ComparedCorrections.planMove.subjectKind == Sub4Import.moveSubject)
        #expect(ComparedCorrections.planMove.field == Sub4Import.moveField)
        #expect(Sub4Import.moveSubject != Sub4Import.commuteSubject,
                "the two families would collide on the unique key")
    }
}
