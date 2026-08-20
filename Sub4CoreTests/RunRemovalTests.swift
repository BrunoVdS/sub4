//
//  RunRemovalTests.swift
//  Sub4CoreTests
//
//  Which family a run deleted from, kept after the run is gone — patch 415,
//  ADR-0003 §12.160, plan topic 1C.
//
//  WHAT THE DEVICE SAID ON 20 AUGUST
//  ---------------------------------
//  `runs that removed rows: 0` · `newest removal: never — no run has deleted
//  anything`. It had read `2` and `2026-08-15T15:25:27Z · authored · 1 row` the
//  day before. The retention prune had aged out the record of the only two
//  removals this database has ever made, because `MigrationLedger` keeps the
//  newest 200 automatic runs and that is under two days on this phone.
//
//  So durability is not a property of the new table on its own — it cascades
//  from `migration_run`. It comes from the RUN surviving, which is what
//  `aRunThatRemovedIsNeverPruned` is about, and that test is the patch.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A removal outlives its run's retention")
struct RunRemovalTests {

    private func openRun(_ db: Sub4Database, _ trigger: MigrationRunTrigger) throws -> String {
        try MigrationLedger.open(db, appVersion: "415-test", snapshotID: nil,
                                 trigger: trigger, cause: "a test",
                                 now: "2026-08-20T09:00:00Z")
    }

    private func removalRows(_ db: Sub4Database) throws -> [(String, String, Int)] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT runID, family, rows FROM migration_run_removal
                 ORDER BY family
                """).map { (($0["runID"] as String?) ?? "",
                            ($0["family"] as String?) ?? "",
                            ($0["rows"] as Int?) ?? 0) }
        }
    }

    // MARK: 1 — the durability, which is the whole patch

    @Test("A run that removed rows is never pruned, so its record survives")
    func aRunThatRemovedIsNeverPruned() throws {
        let db = try Sub4Database.inMemory()

        let kept = try openRun(db, .authored)
        try MigrationLedger.recordRemovals(db, id: kept, rows: 1,
                                           families: [(.notes, 1)])
        try MigrationLedger.finish(db, id: kept, state: .pending, note: nil,
                                   now: "2026-08-20T09:00:01Z")

        // Enough ordinary runs to push it well past any retention window.
        for _ in 0 ..< 12 {
            let id = try openRun(db, .backgrounded)
            try MigrationLedger.recordRemovals(db, id: id, rows: 0)
            try MigrationLedger.finish(db, id: id, state: .pending, note: nil,
                                       now: "2026-08-20T09:00:02Z")
        }
        // A retention of 3 would have taken the removal run with it before 415.
        _ = try MigrationLedger.prune(db, keeping: 3, keepingInterrupted: 3)

        let survivors = try db.queue.read { d in
            try String.fetchAll(d, sql: "SELECT id FROM migration_run")
        }
        #expect(survivors.contains(kept),
                "the only evidence that a deletion happened must not age out")
        #expect(try removalRows(db).map(\.1) == ["notes"],
                "and its family record with it")
    }

    // MARK: 2 — the account decomposes the total

    @Test("Every removal counter is named, and they sum to the total")
    func everyRemovalCounterIsNamed() {
        var r = Sub4Import.Report()
        r.notesRemoved = 1
        r.matchDecisionsRemoved = 2
        r.reviewsRemoved = 3
        r.correctionsRemoved = 4
        r.movesRemoved = 5
        r.workItemsRemoved = 6

        // RULE 2 checks every declared counter is IN the sum. This checks the
        // record takes the sum back apart — a counter in one and not the other
        // is a row deleted with nothing saying by whom. §6: an account beats a
        // list.
        #expect(r.removals.reduce(0) { $0 + $1.rows } == r.removedTotal)
        #expect(Set(r.removals.map(\.family)) == Set(RemovalFamily.allCases))
    }

    @Test("A family that lost nothing writes no row")
    func zeroIsNotARecord() throws {
        let db = try Sub4Database.inMemory()
        let id = try openRun(db, .manual)
        try MigrationLedger.recordRemovals(db, id: id, rows: 2,
                                           families: [(.notes, 2), (.reviews, 0)])
        // "lost nothing" and "was not considered" must not be the same row.
        #expect(try removalRows(db).map(\.1) == ["notes"])
    }

    @Test("Recording twice corrects the record rather than doubling it")
    func aSecondRecordIsAnUpdate() throws {
        let db = try Sub4Database.inMemory()
        let id = try openRun(db, .manual)
        try MigrationLedger.recordRemovals(db, id: id, rows: 1, families: [(.notes, 1)])
        try MigrationLedger.recordRemovals(db, id: id, rows: 6, families: [(.notes, 6)])
        let rows = try removalRows(db)
        #expect(rows.count == 1)
        #expect(rows.first?.2 == 6)
    }

    // MARK: 3 — the two vocabularies, and the join between them

    @Test("Every reconcilable family can be recorded as a removal")
    func theTwoVocabulariesAgree() {
        // §12.129: when you build a tripwire over a join, write down which way
        // it points. This way. A family that may be reconciled and cannot be
        // recorded would delete rows the account could not name.
        for f in ReconcileFamily.allCases {
            #expect(RemovalFamily(rawValue: f.rawValue) != nil,
                    "\(f.rawValue) can be reconciled but not recorded")
        }
        // And the other way is deliberately NOT an equality: `workQueue` is
        // pruned without a permission because nothing authored it, so the
        // removal vocabulary is a strict superset. §12.160.
        #expect(RemovalFamily.allCases.count == ReconcileFamily.allCases.count + 1)
        #expect(RemovalFamily(rawValue: "workQueue") != nil)
    }

    // MARK: 4 — the line says which family

    @Test("The newest removal names its families")
    func theNewestRemovalNamesFamilies() throws {
        let db = try Sub4Database.inMemory()
        let id = try openRun(db, .authored)
        try MigrationLedger.recordRemovals(db, id: id, rows: 3,
                                           families: [(.notes, 1), (.commutes, 2)])
        try MigrationLedger.finish(db, id: id, state: .pending, note: nil,
                                   now: "2026-08-20T09:00:01Z")

        let census = try MigrationLedger.census(db)
        let line = try #require(census.newestRemoval?.line)
        #expect(line.contains("commute decisions 2"))
        #expect(line.contains("notes 1"))
        #expect(census.removedByFamily[.notes] == 1)
        #expect(census.removedByFamily[.commutes] == 2)

        // UNCONDITIONAL, every family, including the zeros.
        let text = census.diagnosticLines.joined(separator: "\n")
        #expect(text.contains("removed by family, durably:"))
        #expect(text.contains("reviews 0"))
    }

    // MARK: 5 — a populated database from before this migration

    @Test("A populated pre-415 database upgrades and keeps its runs")
    func aPopulatedDatabaseUpgrades() throws {
        let queue = try DatabaseQueue(
            configuration: Sub4Database.configuration(label: "run-removal-upgrade"))
        // The ledger's own chain, exactly as `InterruptedRunTests` builds it:
        // `registerInitial` is private, and this test is about `migration_run`
        // rather than about the whole schema.
        var before = DatabaseMigrator()
        Sub4Migrations.registerMigrationRun(&before)
        Sub4Migrations.registerRunTrigger(&before)
        Sub4Migrations.registerInterruptedRun(&before)
        Sub4Migrations.registerRunRecovered(&before)
        Sub4Migrations.registerAuthoredTrigger(&before)
        Sub4Migrations.registerRowsRemoved(&before)
        Sub4Migrations.registerRunCause(&before)
        try before.migrate(queue)

        // A run that deleted something, recorded the only way the old schema
        // could: a number with no family beside it.
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, state, snapshotID, appVersion,
                   triggeredBy, note, rowsRemoved)
                VALUES ('old-run', '2026-08-15T15:25:27Z',
                        '2026-08-15T15:25:28Z', 'pending', NULL, '369',
                        'authored', NULL, 1)
                """)
        }

        var after = before
        Sub4Migrations.registerRunRemoval(&after)
        try after.migrate(queue)

        let db = Sub4Database(queue: queue, location: .inMemory)
        #expect(try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM migration_run") ?? 0
        } == 1, "the migration is additive — the run is still there")

        // **AND THE OLD ROW SAYS IT CANNOT NAME A FAMILY**, rather than
        // printing a removal that appears to have come from nowhere. §12.15.
        let census = try MigrationLedger.census(db)
        let line = try #require(census.newestRemoval?.line)
        #expect(line.contains("1 row"))
        #expect(line.contains("predates 415"))
        #expect(census.removedByFamily.values.allSatisfy { $0 == 0 })
    }
}
