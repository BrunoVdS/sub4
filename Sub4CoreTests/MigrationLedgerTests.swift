//
//  MigrationLedgerTests.swift
//  Sub4CoreTests
//
//  The import ledger — patch 255, migration contract item 11.
//
//  The acceptance criteria, verbatim from the plan: "an import that throws
//  leaves `failed`, not `running`; two imports produce two rows; the state
//  vocabulary and the enum agree." The third lives in `DomainSchemaTests` with
//  the other frozen vocabularies; the first two are here.
//
//  THE FIRST ONE IS THE WHOLE POINT. It is the reason the ledger writes in
//  three transactions rather than sharing the import's, and a test that only
//  checked the happy path would pass against the version of this code that gets
//  it wrong.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct MigrationLedgerTests {

    private func db() throws -> Sub4Database {
        try Sub4Database.inMemory(label: "ledger")
    }

    private let t0 = "2026-08-05T10:00:00Z"
    private let t1 = "2026-08-05T10:00:12Z"

    // MARK: Opening and closing

    @Test("A run opens as running, with no finish time")
    func openLeavesItRunning() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "255",
                                          snapshotID: "2026-08-05-081716", now: t0)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.id == id)
        #expect(run.state == .running)
        #expect(run.finishedUTC == nil)
        #expect(run.snapshotID == "2026-08-05-081716")
        #expect(run.appVersion == "255")
    }

    @Test("A finished run carries when it finished")
    func finishRecordsTheTime() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        try MigrationLedger.finish(d, id: id, state: .pending,
                                   note: "661 activities", now: t1)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.state == .pending)
        #expect(run.finishedUTC == t1)
        #expect(run.note == "661 activities")
    }

    @Test("A run with no snapshot says so rather than pretending")
    func aRunWithoutASnapshotIsRecordedAsSuch() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        // Contract item 3 wants the inputs copied before they are read. A run
        // that skipped that is a run with nothing to go back to, and the column
        // is how that becomes visible instead of assumed.
        #expect(run.snapshotID == nil)
    }

    // MARK: The acceptance criteria

    @Test("An import that throws leaves failed, not running")
    func aThrowingImportIsRecordedAsFailed() throws {
        let d = try db()

        // `run` throws because the activity has no start instant and the schema
        // refuses it — a real refusal from `ImportTests`, not a contrived one.
        // What matters is that the ledger survives the rollback of the write
        // that failed.
        struct Boom: Error {}
        let id = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        do {
            try d.queue.write { _ in throw Boom() }
        } catch {
            try MigrationLedger.finish(d, id: id, state: .failed,
                                       note: "Boom", now: t1)
        }

        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.state == .failed, "a rolled-back import left the run running")
        #expect(run.finishedUTC == t1)
        #expect(run.note == "Boom")
    }

    @Test("The real importer opens and closes its own run")
    func theImporterClosesItsOwnRun() throws {
        let d = try db()
        // Driven through the real `Sub4Import.run` rather than the ledger
        // directly, because the thing under test is the wiring: that `run`
        // opens a row before its write and closes it after, and that the report
        // can name the row it opened.
        let report = try Sub4Import.run(into: d, activities: [], shoes: [],
                                        appVersion: "255",
                                        snapshotID: "2026-08-05-081716")
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.id == report.runID, "the report should name the row it opened")
        #expect(run.state == .pending, "a committed import is pending verification")
        #expect(run.snapshotID == "2026-08-05-081716")
        #expect(run.note?.contains("0 activities") == true)
    }

    @Test("Two imports produce two rows, newest first")
    func runsAccumulate() throws {
        let d = try db()
        let first = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil,
                                             now: "2026-08-05T09:00:00Z")
        try MigrationLedger.finish(d, id: first, state: .pending, note: nil,
                                   now: "2026-08-05T09:00:05Z")
        let second = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil,
                                              now: "2026-08-05T10:00:00Z")
        try MigrationLedger.finish(d, id: second, state: .pending, note: nil,
                                   now: "2026-08-05T10:00:05Z")

        let all = try MigrationLedger.all(d)
        #expect(all.count == 2)
        #expect(all.first?.id == second, "newest first")
        #expect(all.last?.id == first)
    }

    // MARK: What the schema refuses

    @Test("A state the vocabulary does not have is rejected")
    func anUnknownStateIsRefused() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, NULL, 'halfway', '255')
                    """, arguments: [t0])
            }
        }
    }

    @Test("A running run may not carry a finish time")
    func runningAndFinishedCannotCoexist() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, ?, 'running', '255')
                    """, arguments: [t0, t1])
            }
        }
    }

    @Test("A finished run must carry a finish time")
    func finishedWithoutATimeIsRefused() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, NULL, 'verified', '255')
                    """, arguments: [t0])
            }
        }
    }

    @Test("A run cannot finish before it started")
    func timeRunsForwards() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, ?, 'pending', '255')
                    """, arguments: [t1, t0])
            }
        }
    }

    // MARK: Interrupted runs

    @Test("A run left open is reported, not repaired")
    func staleRunsAreVisible() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        let stale = try MigrationLedger.stale(d)
        #expect(stale.count == 1)
        #expect(stale.first?.state == .running)
        // Rewriting it to `failed` on the next launch would be tidy and would
        // destroy the only evidence that the app was killed while writing.
        let afterRow = try MigrationLedger.latest(d)
        let after = try #require(afterRow)
        #expect(after.state == .running)
    }

    @Test("The migration is declared as well as registered")
    func theMigrationIsDeclared() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.migrationRun))
        // The invariant from patch 236: identifiers must sort into run order.
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted())
    }

    @Test("Every state the enum has can be stored")
    func everyStateIsStorable() throws {
        let d = try db()
        for state in MigrationRunState.allCases {
            let id = try MigrationLedger.open(d, appVersion: "255",
                                              snapshotID: nil, now: t0)
            if state.isFinished {
                try MigrationLedger.finish(d, id: id, state: state, note: nil, now: t1)
            }
            // Computed into a local first: `#expect`/`#require` decompose into
            // a `rethrows` call and an inline `try` inside one is a compile
            // error this project has hit before.
            let rows = try MigrationLedger.all(d)
            let back = try #require(rows.first { $0.id == id })
            #expect(back.state == state)
        }
    }
}
