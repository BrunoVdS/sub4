//
//  AuthoredNarrowWriteTests.swift
//  Sub4CoreTests
//
//  One record, one transaction — for the three families 408 did not cover.
//  Patch 411, ADR-0003 §12.156, plan topic 1B.
//
//  408 built `NoteRepository` and 409 inverted the notes' order. 411 is 408
//  again for the commute decisions, the plan moves and the match decisions,
//  and it CHANGES NO ORDER — the stores still write file-first, and 412 flips
//  them. 381-before-382's discipline: when the flip is alone in its patch,
//  anything that breaks on flip day is attributable to it.
//
//  WHY THIS FILE EXISTS SEPARATELY FROM `NoteWriteTests`
//  ----------------------------------------------------
//  Because the notes were the easy case and nothing said so. `importNotes`
//  reconciles nowhere — the notes' removal pass lives in `reconcileAuthored` —
//  so handing it one note moves one row. **`importCorrections` and
//  `importMoves` prune INSIDE themselves**, from a keep-set built out of the
//  array they are handed. Hand either of them one record with `reconcile: .run(Set(ReconcileFamily.allCases))`
//  and every other row of that family is deleted, by a function called
//  "import", inside one transaction, with no error.
//
//  That is the failure this file is mostly about, and two of its tests exist
//  only to catch it.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("One authored record, one transaction")
struct AuthoredNarrowWriteTests {

    // MARK: Fixtures

    /// **WITH REAL ACTIVITIES, AND THAT IS NOT SETUP NOISE.**
    /// `importCorrections` resolves a decision's activity through
    /// `canonicalActivity` and counts it `correctionsUnresolved` if it finds
    /// nothing — so a commute decision about an activity that is not here is
    /// held back, correctly, and writes no row. A fixture without activities
    /// would make every commute test pass by writing nothing at all.
    private func imported(_ ids: [String] = ["a-1", "a-2", "a-3", "shared"])
    throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: ids.map(ride),
                               shoes: [])
        return db
    }

    private func ride(_ id: String) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 4000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// The canonical id a decision's row is filed under — §3.1, and the reason
    /// `CommuteRepository.delete` resolves before it deletes.
    private func canonical(_ db: Sub4Database, _ externalId: String) throws -> String? {
        try db.queue.read { try Sub4Import.canonicalActivity($0, externalID: externalId) }
    }

    private func commute(_ activityId: String, isCommute: Bool = true)
    -> CommuteDecision {
        CommuteDecision(activityId: activityId, isCommute: isCommute,
                        decided: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func move(_ sessionUid: String, to day: String = "2026-08-12")
    -> PlanMove {
        PlanMove(sessionUid: sessionUid, movedTo: day,
                 decided: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func decision(_ sessionUid: String, activityId: String? = nil)
    -> MatchDecision {
        MatchDecision(sessionUid: sessionUid, activityId: activityId,
                      decided: Date(timeIntervalSince1970: 1_755_000_000),
                      dateIsKnown: true)
    }

    /// Rows of one family, straight out of `correction` — deliberately NOT
    /// through `AuthoredRepository.load`, because a reader that filters the
    /// same way the writer does would agree with a writer that filtered wrong.
    private func correctionSubjects(_ db: Sub4Database, kind: String,
                                    field: String) throws -> Set<String> {
        try db.queue.read { d in
            Set(try String.fetchAll(d, sql: """
                SELECT subjectID FROM correction
                WHERE accountID = ? AND subjectKind = ? AND field = ?
                """, arguments: [Sub4Import.accountID, kind, field]))
        }
    }

    private func commuteSubjects(_ db: Sub4Database) throws -> Set<String> {
        try correctionSubjects(db, kind: Sub4Import.commuteSubject,
                               field: Sub4Import.commuteField)
    }

    private func moveSubjects(_ db: Sub4Database) throws -> Set<String> {
        try correctionSubjects(db, kind: Sub4Import.moveSubject,
                               field: Sub4Import.moveField)
    }

    // MARK: 1 — the prune that must not happen

    @Test("Writing one commute decision does not prune the others")
    func aSingleCommuteWriteDoesNotPruneTheOthers() throws {
        let db = try imported()
        for id in ["a-1", "a-2", "a-3"] {
            #expect(CommuteRepository.upsert(commute(id), in: db).committed)
        }
        let expected = Set(try ["a-1", "a-2", "a-3"].compactMap {
            try canonical(db, $0)
        })
        #expect(expected.count == 3, "three activities, three canonical ids")
        #expect(try commuteSubjects(db) == expected)

        // **THE CONTROL THIS PATCH IS MOSTLY FOR.** `importCorrections` builds
        // its keep-set from the array it is handed and deletes every commute
        // row outside it. With `reconcile: .run(Set(ReconcileFamily.allCases))` this single write would leave
        // ONE row where three stood — silently, inside one transaction, from a
        // function named "import". `.skipped` is what stops it.
        #expect(CommuteRepository.upsert(commute("a-2", isCommute: false),
                                         in: db).committed)
        #expect(try commuteSubjects(db) == expected,
                "a single write must never reconcile the store it writes into")
    }

    @Test("Writing one moved session does not prune the others")
    func aSingleMoveWriteDoesNotPruneTheOthers() throws {
        let db = try imported()
        for uid in ["s-1", "s-2", "s-3"] {
            #expect(PlanMoveRepository.upsert(move(uid), in: db).committed)
        }
        #expect(try moveSubjects(db) == ["s-1", "s-2", "s-3"])

        #expect(PlanMoveRepository.upsert(move("s-2", to: "2026-08-13"),
                                          in: db).committed)
        #expect(try moveSubjects(db) == ["s-1", "s-2", "s-3"],
                "`importMoves` prunes from its own argument, so one move must not reconcile")
    }

    // MARK: 2 — one table, two families

    @Test("Deleting a commute leaves a move that shares its subject")
    func theDiscriminatorIsLoadBearing() throws {
        let db = try imported()
        // THE SAME STRING AS BOTH SUBJECTS. An activity id and a plan session
        // uid come from different namespaces, so this does not happen by
        // accident — which is exactly why a delete keyed on `subjectID` alone
        // would pass every realistic test and still be wrong.
        #expect(CommuteRepository.upsert(commute("shared"), in: db).committed)
        #expect(PlanMoveRepository.upsert(move("shared"), in: db).committed)

        #expect(CommuteRepository.delete(commuteFor: "shared", in: db).committed)

        #expect(try commuteSubjects(db).isEmpty)
        #expect(try moveSubjects(db) == ["shared"],
                "`correction` holds both families and only `subjectKind` tells them apart")
    }

    @Test("Deleting a move leaves a commute that shares its subject")
    func theDiscriminatorHoldsBothWays() throws {
        let db = try imported()
        #expect(CommuteRepository.upsert(commute("shared"), in: db).committed)
        #expect(PlanMoveRepository.upsert(move("shared"), in: db).committed)

        #expect(PlanMoveRepository.delete(moveFor: "shared", in: db).committed)

        #expect(try moveSubjects(db).isEmpty)
        let stillThere = try canonical(db, "shared")
        #expect(try commuteSubjects(db) == Set([stillThere].compactMap { $0 }))
    }

    // MARK: 3 — insert, update, delete, for each family

    @Test("Each family inserts, then updates, and says which")
    func insertThenUpdate() throws {
        let db = try imported()

        #expect(CommuteRepository.upsert(commute("a-1"), in: db)
                    == .wrote(inserted: true))
        #expect(CommuteRepository.upsert(commute("a-1", isCommute: false), in: db)
                    == .wrote(inserted: false), "the second write is an update")
        #expect(try commuteSubjects(db).count == 1, "one subject, one row")

        #expect(PlanMoveRepository.upsert(move("s-1"), in: db)
                    == .wrote(inserted: true))
        #expect(PlanMoveRepository.upsert(move("s-1", to: "2026-08-14"), in: db)
                    == .wrote(inserted: false))
        #expect(try moveSubjects(db).count == 1)

        #expect(MatchDecisionRepository.upsert(decision("s-1"), in: db)
                    == .wrote(inserted: true))
        #expect(MatchDecisionRepository.upsert(decision("s-1"), in: db)
                    == .wrote(inserted: false))
    }

    @Test("Deleting something that is already gone is not a refusal")
    func deleteIsIdempotent() throws {
        let db = try imported()
        #expect(CommuteRepository.upsert(commute("a-1"), in: db).committed)
        #expect(MatchDecisionRepository.upsert(decision("s-1"), in: db).committed)

        #expect(CommuteRepository.delete(commuteFor: "a-1", in: db).committed)
        #expect(CommuteRepository.delete(commuteFor: "a-1", in: db).committed,
                "the caller asked for it to be gone and it is gone")
        #expect(try commuteSubjects(db).isEmpty)

        #expect(MatchDecisionRepository.delete(decisionFor: "s-1", in: db).committed)
        #expect(MatchDecisionRepository.delete(decisionFor: "s-1", in: db).committed)
    }

    // MARK: 4 — no database is its own answer

    @Test("Every write says so when there is no database")
    func noDatabaseIsNotSilence() {
        // §12.15. Before B9 a shut gate is an ordinary state, and a write that
        // returned "refused" for it would make the app unable to record an
        // answer at all — while one that returned "written" would be a lie.
        #expect(CommuteRepository.upsert(commute("a-1"), in: nil) == .noDatabase)
        #expect(CommuteRepository.delete(commuteFor: "a-1", in: nil) == .noDatabase)
        #expect(PlanMoveRepository.upsert(move("s-1"), in: nil) == .noDatabase)
        #expect(PlanMoveRepository.delete(moveFor: "s-1", in: nil) == .noDatabase)
        #expect(MatchDecisionRepository.upsert(decision("s-1"), in: nil) == .noDatabase)
        #expect(MatchDecisionRepository.delete(decisionFor: "s-1", in: nil) == .noDatabase)
    }
}
