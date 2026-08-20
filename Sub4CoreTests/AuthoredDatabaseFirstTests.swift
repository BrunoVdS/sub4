//
//  AuthoredDatabaseFirstTests.swift
//  Sub4CoreTests
//
//  The inverted order for the other three families — patch 412, §12.157.
//
//  409 did the notes and `NoteDatabaseFirstTests` proved it. This is the same
//  contract for the commute decisions, the plan moves and the match decisions,
//  and every test here fails against the pre-412 order.
//
//  THE THIRD ONE IS NOT SHAPED LIKE THE OTHER TWO. `Matcher.setOverride`
//  returns Void — §12.19's disclosed gap, since `UserDefaults.set` has no
//  failure to surface and there is no alert on that path — so a refusal cannot
//  be thrown at the caller. Its equivalent is NOT PUBLISHING, which is the
//  contract 372 already wrote for a failed `persist()`, moved one step earlier.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("The other three families commit before they publish")
@MainActor
struct AuthoredDatabaseFirstTests {

    // MARK: Fixtures

    private func imported() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride("a-1")], shoes: [])
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

    private func writableDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("authored-412-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func unwritableDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("authored-gone-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "match-412-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// **THE ROWS, READ WITH SQL RATHER THAN THROUGH THE APP'S READER.**
    /// A reader that filters the way the writer does would agree with a writer
    /// that filtered wrong — and 411 shipped exactly that bug for a day, in
    /// `CommuteRepository.delete`.
    private func correctionCount(_ db: Sub4Database, kind: String,
                                 field: String) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM correction
                WHERE accountID = ? AND subjectKind = ? AND field = ?
                """, arguments: [Sub4Import.accountID, kind, field]) ?? 0
        }
    }

    private func commuteRows(_ db: Sub4Database) throws -> Int {
        try correctionCount(db, kind: Sub4Import.commuteSubject,
                            field: Sub4Import.commuteField)
    }

    private func moveRows(_ db: Sub4Database) throws -> Int {
        try correctionCount(db, kind: Sub4Import.moveSubject,
                            field: Sub4Import.moveField)
    }

    private func decisionRows(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM match_decision WHERE accountID = ?
                """, arguments: [Sub4Import.accountID]) ?? 0
        }
    }

    private func storedCommutes(_ db: Sub4Database) -> [CommuteDecision] {
        guard case .loaded(_, let commutes, _) = AuthoredRepository.load(db) else {
            return []
        }
        return commutes
    }

    // MARK: 1 — a refused commit publishes nothing

    @Test("A commute the database refuses is not published anywhere")
    func aRefusedCommutePublishesNothing() throws {
        let dir = try writableDirectory()
        let db = try imported()
        // THE ONLY HONEST REFUSAL LEVER HERE. `user_note.rpe`'s CHECK gave 409
        // a refusal reachable through the public API; `correction` has one CHECK
        // and the repository owns the column it guards, so the reachable way to
        // make the write fail is to take the table away.
        try db.queue.write { try $0.execute(sql: "DROP TABLE correction") }

        let store = CommuteStore(directory: dir, database: db)
        #expect(throws: StoreWriteError.self) {
            try store.set(true, for: "a-1")
        }
        #expect(store.decision(for: "a-1") == nil,
                "the screen must not show a decision the database refused")
        #expect(!FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("commutes.json").path),
                "file-first wrote the mirror before the commit was attempted")
    }

    @Test("A match decision the database refuses does not stick")
    func aRefusedMatchDecisionDoesNotStick() throws {
        let db = try imported()
        try db.queue.write { try $0.execute(sql: "DROP TABLE match_decision") }

        let matcher = Matcher(defaults: try freshDefaults(), database: db)
        matcher.setOverride(sessionUid: "w03-tue", activityId: "a-1")

        // NOT A THROW — see the header. The tick simply does not take, which is
        // what the athlete sees and what 372 chose deliberately.
        #expect(matcher.decisions["w03-tue"] == nil,
                "a refusal it cannot report must still not be published")
    }

    // MARK: 2 — the commit survives a mirror that never lands

    @Test("A commute committed before the mirror failed is there at the next launch")
    func theCommuteCommitSurvivesTheMirror() throws {
        let db = try imported()
        let store = CommuteStore(directory: unwritableDirectory(), database: db)

        // The mirror cannot land; the edit is already committed, so it must not
        // be reported as a failure.
        try store.set(true, for: "a-1")
        #expect(store.decision(for: "a-1") == true)

        // The next launch: a fresh store hydrated from the rows, as B2 does.
        let next = CommuteStore(directory: unwritableDirectory(), database: db)
        next.hydrate(from: storedCommutes(db))
        #expect(next.decision(for: "a-1") == true,
                "the edit was acknowledged, so a relaunch that loses it is 1B's defect")
    }

    @Test("A moved session committed before the mirror failed survives a relaunch")
    func theMoveCommitSurvivesTheMirror() throws {
        let db = try imported()
        let store = PlanMoveStore(directory: unwritableDirectory(), database: db)

        try store.set("2026-08-12", for: "w03-tue")
        #expect(try moveRows(db) == 1, "the row is in before the mirror is tried")
    }

    // MARK: 3 — the delete order, which is the direction that resurrects

    @Test("A cleared commute is gone from the database even when the mirror fails")
    func aClearedCommuteOutlivesItsMirror() throws {
        let dir = try writableDirectory()
        let db = try imported()
        let store = CommuteStore(directory: dir, database: db)
        try store.set(true, for: "a-1")
        #expect(try commuteRows(db) == 1)

        // The directory goes away between two mutations — what a container
        // rebuilt underneath a running app looks like.
        try FileManager.default.removeItem(at: dir)

        // **THE OLD ORDER THROWS HERE AND NEVER REACHES THE DATABASE**, so the
        // row survived and the next launch hydrated the decision back onto a
        // ride the athlete had already returned to the distance rule.
        try store.clear("a-1")

        #expect(try commuteRows(db) == 0,
                "the deletion is authoritative even when its mirror cannot land")
        #expect(store.decision(for: "a-1") == nil)
    }

    @Test("A cleared move is gone from the database even when the mirror fails")
    func aClearedMoveOutlivesItsMirror() throws {
        let dir = try writableDirectory()
        let db = try imported()
        let store = PlanMoveStore(directory: dir, database: db)
        try store.set("2026-08-12", for: "w03-tue")
        #expect(try moveRows(db) == 1)

        try FileManager.default.removeItem(at: dir)
        try store.clear("w03-tue")

        #expect(try moveRows(db) == 0)
        #expect(store.movedTo("w03-tue") == nil)
    }

    @Test("A cleared match decision is gone from the database")
    func aClearedMatchDecisionReachesTheRows() throws {
        let db = try imported()
        let matcher = Matcher(defaults: try freshDefaults(), database: db)
        matcher.setOverride(sessionUid: "w03-tue", activityId: "a-1")
        #expect(try decisionRows(db) == 1)

        matcher.clearOverride(sessionUid: "w03-tue")
        #expect(try decisionRows(db) == 0,
                "a decision that outlived its clear comes back at the next launch")
    }

    // MARK: 4 — the diagnostic, and it names the family

    @Test("The line names the families that went to the file only")
    func theLineNamesWhoMissed() throws {
        let db = try imported()
        let committing = CommuteStore(directory: try writableDirectory(), database: db)
        try committing.set(true, for: "a-1")
        #expect(committing.lastCommit == .reached)

        // A seam with no database is the shut-gate state the app must survive
        // before B9: the file takes it and the line says the row did not.
        let fileOnly = PlanMoveStore(directory: try writableDirectory())
        try fileOnly.set("2026-08-12", for: "w03-tue")
        #expect(fileOnly.lastCommit == .missed)

        let line = AuthoredCommit.line([
            ("notes", .noneThisLaunch),
            ("commutes", committing.lastCommit),
            ("moved sessions", fileOnly.lastCommit),
        ])
        #expect(line.contains("NO"))
        #expect(line.contains("moved sessions"))
        #expect(!line.contains("commutes"),
                "a family that reached the database is not named as one that missed")
    }

    @Test("Nothing written this launch is not the same as everything reached")
    func nothingWrittenIsItsOwnAnswer() {
        let quiet = AuthoredCommit.line([
            ("notes", .noneThisLaunch), ("commutes", .noneThisLaunch),
            ("moved sessions", .noneThisLaunch), ("match decisions", .noneThisLaunch),
        ])
        #expect(quiet.contains("no record written since this launch"))
        #expect(!quiet.hasSuffix("yes"))
    }
}
