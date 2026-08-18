//
//  InterruptedRunTests.swift
//  Sub4CoreTests
//
//  Patch 338. A run nobody closed says so.
//
//  WHAT THESE ARE FOR
//  ------------------
//  `closeInterrupted` is the one function in this project whose correctness is
//  entirely a fact about WHERE IT IS CALLED: at launch every open row belongs
//  to a dead process, and anywhere else it closes the live run. A test cannot
//  assert a call site, so these assert the two halves it can — that the state
//  exists and is terminal, and that the function closes exactly the open rows
//  and nothing else.
//
//  The call site is guarded instead by `Sub4Launch`'s own comment and by the
//  fact that `MigrationLedger.open` is the only other writer of `running`.
//
//  NO `Sub4Migrations.all.last ==` ASSERTION — CLAUDE.md's rule.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A run the app was killed during")
struct InterruptedRunTests {

    private func db() throws -> Sub4Database { try Sub4Database.inMemory() }
    private let t0 = "2026-08-09T14:33:49Z"
    private let t1 = "2026-08-09T15:00:00Z"

    // MARK: The schema

    @Test func theMigrationIsRegisteredInBothPlaces() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.interruptedRun))
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted())
    }

    /// Asks the database what it built. A rebuilt table is the one case where
    /// reading the source tells you least.
    @Test func theCheckAdmitsTheSixthStateAndKeepsTheOthers() throws {
        let d = try db()
        let sql = try d.queue.read {
            try String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master
                 WHERE type = 'table' AND name = 'migration_run'
                """)
        }
        let schema = try #require(sql)
        for state in Sub4Migrations.migrationRunStatesWithInterrupted {
            #expect(schema.contains("'\(state)'"), "\(state) missing from the CHECK")
        }
        // The neighbours a rebuild could have dropped without anybody noticing.
        #expect(schema.contains("triggeredBy"))
        #expect(schema.contains("'backgroundRefresh'"))
        #expect(schema.contains("finishedUTC >= startedUTC"))
        #expect(schema.contains("sequence"))
        #expect(schema.contains("AUTOINCREMENT"))
        #expect(schema.contains("recoveredUTC"))
    }

    /// The index goes with the table in a twelve-step rebuild and has to be
    /// recreated by name. Losing it would slow "the last run" and break
    /// nothing, which is the kind of regression no other test would catch.
    @Test func theIndexSurvivedTheRebuild() throws {
        let d = try db()
        let n = try d.queue.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'index' AND name = 'migration_run_started'
                """)
        }
        #expect(n == 1)
    }

    /// An interruption has no honest finish time. It is valid only with the
    /// later instant at which a launch recovered it.
    @Test func interruptedWithoutARecoveryTimeIsRefused() throws {
        let d = try db()
        #expect(throws: DatabaseError.self) {
            try d.queue.write {
                try $0.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, NULL, 'interrupted', '338')
                    """, arguments: [t0])
            }
        }
    }

    @Test func theStateIsTerminal() {
        #expect(MigrationRunState.interrupted.isFinished)
        #expect(!MigrationRunState.running.isFinished)
    }

    // MARK: Closing

    @Test func anOpenRunIsClosedAsInterrupted() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "337b",
                                          snapshotID: nil, now: t0)

        let closed = try MigrationLedger.closeInterrupted(d, now: t1)
        #expect(closed == [id])

        let rows = try MigrationLedger.all(d)
        let back = try #require(rows.first { $0.id == id })
        #expect(back.state == .interrupted)
        #expect(back.finishedUTC == nil, "the killed process did not report a finish")
        #expect(back.recoveredUTC == t1)
    }

    @Test func recoverySurvivesAClockCorrectionBackwards() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "338",
                                          snapshotID: nil, now: t1)
        let closed = try MigrationLedger.closeInterrupted(d, now: t0)
        #expect(closed == [id])
        let rows = try MigrationLedger.all(d)
        let run = try #require(rows.first { $0.id == id })
        #expect(run.state == .interrupted)
        #expect(run.recoveredUTC == t0,
                "record the observed clock value; do not invent a duration")
    }

    /// A CLOSED RUN IS NOT TOUCHED — the half that would be silently wrong.
    /// A `closeInterrupted` that swept `pending` rows would rewrite the ledger
    /// on every launch and every test above would still pass.
    @Test func finishedRunsAreLeftAlone() throws {
        let d = try db()
        let done = try MigrationLedger.open(d, appVersion: "337b",
                                            snapshotID: nil, now: t0)
        try MigrationLedger.finish(d, id: done, state: .pending,
                                   note: "678 activities", now: t0)
        let open = try MigrationLedger.open(d, appVersion: "337b",
                                            snapshotID: nil, now: t0)

        let closed = try MigrationLedger.closeInterrupted(d, now: t1)
        #expect(closed == [open])

        // HOISTED — CLAUDE.md: never put `try` inside `#expect` / `#require`.
        let rows = try MigrationLedger.all(d)
        let doneRow = try #require(rows.first { $0.id == done })
        let openRow = try #require(rows.first { $0.id == open })
        #expect(doneRow.state == .pending)
        #expect(openRow.state == .interrupted)
    }

    /// A run that described itself before dying keeps its note. Overwriting it
    /// with the generic sentence would trade a fact for a tidier display, which
    /// is the trade this patch exists to stop making.
    @Test func anExistingNoteSurvives() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "337b",
                                          snapshotID: nil, now: t0)
        try d.queue.write {
            try $0.execute(sql: "UPDATE migration_run SET note = ? WHERE id = ?",
                           arguments: ["got as far as the traces", id])
        }
        _ = try MigrationLedger.closeInterrupted(d, now: t1)

        let rows = try MigrationLedger.all(d)
        let back = try #require(rows.first { $0.id == id })
        #expect(back.note == "got as far as the traces")
    }

    @Test func aRunWithNoNoteGetsTheExplanation() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "337b",
                                          snapshotID: nil, now: t0)
        _ = try MigrationLedger.closeInterrupted(d, now: t1)
        let rows = try MigrationLedger.all(d)
        let back = try #require(rows.first { $0.id == id })
        #expect(back.note == MigrationLedger.interruptedNote)
    }

    /// Nothing open is a normal launch and must not be an error or a write.
    @Test func aCleanLaunchClosesNothing() throws {
        let d = try db()
        let closed = try MigrationLedger.closeInterrupted(d, now: t1)
        let n = try MigrationLedger.interruptedCount(d)
        #expect(closed.isEmpty)
        #expect(n == 0)
    }

    /// The device state on 9 August: three rows open at once, from three dead
    /// processes. All three close, in one statement.
    @Test func everyOpenRunClosesTogether() throws {
        let d = try db()
        var ids: [String] = []
        for i in 0..<3 {
            ids.append(try MigrationLedger.open(d, appVersion: "337b",
                                                snapshotID: nil,
                                                now: "2026-08-09T14:3\(i):00Z"))
        }
        let closed = try MigrationLedger.closeInterrupted(d, now: t1)
        let n = try MigrationLedger.interruptedCount(d)
        let open = try MigrationLedger.stale(d)
        #expect(Set(closed) == Set(ids))
        #expect(n == 3)
        #expect(open.isEmpty, "nothing is open any more")
    }

    // MARK: The two counts are two questions — §12.54.2

    @Test func theCensusSeparatesOpenNowFromInterrupted() throws {
        let d = try db()
        let old = try MigrationLedger.open(d, appVersion: "337b",
                                           snapshotID: nil, now: t0)
        _ = try MigrationLedger.closeInterrupted(d, now: t1)
        let live = try MigrationLedger.open(d, appVersion: "338",
                                            snapshotID: nil, now: t1)

        let c = try MigrationLedger.census(d)
        #expect(c.interrupted == 1)
        #expect(c.openNow == 1)
        #expect(c.total == 2)
        #expect(old != live)

        let text = c.diagnosticLines.joined(separator: "\n")
        #expect(text.contains("open right now: 1"))
        #expect(text.contains("interrupted, recovered at a later launch: 1"))
    }

    /// Both lines print at zero. A count that vanishes when it is zero cannot
    /// be told from one nobody wired in — §12.54.2, and the paste is where
    /// somebody who cannot see the screen reads this.
    @Test func bothLinesPrintAtZero() throws {
        let d = try db()
        let text = try MigrationLedger.census(d).diagnosticLines.joined(separator: "\n")
        #expect(text.contains("open right now: 0"))
        #expect(text.contains("interrupted, recovered at a later launch: 0"))
    }

    // MARK: An existing phone database, not only a fresh schema

    @Test func populatedFiveStateTableUpgradesWithoutLosingAField() throws {
        let queue = try DatabaseQueue(
            configuration: Sub4Database.configuration(label: "ledger-upgrade"))
        try queue.write { d in
            try d.execute(sql: """
                CREATE TABLE migration_run (
                    id          TEXT PRIMARY KEY NOT NULL,
                    startedUTC  TEXT NOT NULL,
                    finishedUTC TEXT,
                    state       TEXT NOT NULL
                                CHECK (state IN ('running', 'pending', 'verified',
                                                 'activated', 'failed')),
                    snapshotID  TEXT,
                    appVersion  TEXT NOT NULL,
                    note        TEXT,
                    triggeredBy TEXT
                                CHECK (triggeredBy IS NULL
                                       OR triggeredBy IN ('manual', 'backgrounded',
                                                          'foregrounded',
                                                          'backgroundRefresh')),
                    CHECK ((state = 'running') = (finishedUTC IS NULL)),
                    CHECK (finishedUTC IS NULL OR finishedUTC >= startedUTC)
                );
                CREATE INDEX migration_run_started
                    ON migration_run (startedUTC DESC, id DESC)
                """)
            let states = ["running", "pending", "verified", "activated", "failed"]
            for (offset, state) in states.enumerated() {
                let finished: String? = state == "running" ? nil : t1
                try d.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, snapshotID,
                       appVersion, note, triggeredBy)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: ["old-\(offset)", t0, finished, state,
                                     "snapshot-\(offset)", "337b", "note-\(offset)",
                                     MigrationRunTrigger.backgrounded.rawValue])
            }
        }

        var migrator = DatabaseMigrator()
        Sub4Migrations.registerInterruptedRun(&migrator)
        Sub4Migrations.registerRunRecovered(&migrator)
        // PATCH 406. `MigrationLedger.all` selects `cause` now, so a database
        // that stops before this migration cannot be read at all — which a real
        // upgrade never does, and which this test deliberately models.
        // Registering it keeps the test about the five-state table's upgrade
        // rather than about a column the reader needs. §12.150.
        Sub4Migrations.registerRunCause(&migrator)
        try migrator.migrate(queue)
        let upgraded = Sub4Database(queue: queue, location: .inMemory)
        let rows = try MigrationLedger.all(upgraded, limit: 20)

        #expect(rows.count == 5)
        #expect(rows.map(\.id) == ["old-4", "old-3", "old-2", "old-1", "old-0"])
        #expect(rows.map(\.sequence) == [5, 4, 3, 2, 1])
        for n in 0 ..< 5 {
            let row = try #require(rows.first { $0.id == "old-\(n)" })
            #expect(row.snapshotID == "snapshot-\(n)")
            #expect(row.appVersion == "337b")
            #expect(row.note == "note-\(n)")
            #expect(row.triggeredBy == .backgrounded)
            #expect(row.recoveredUTC == nil)
            // NULL, NOT "". These rows were written before anything recorded a
            // cause; an empty string would say "recorded, and it was nothing".
            // §12.54.2, the distinction `rowsRemoved` drew at 369.
            #expect(row.cause == nil, "a row that predates the column claims nothing")
        }
        #expect(rows.last?.state == .running)

        let recovered = try MigrationLedger.closeInterrupted(upgraded, now: t1)
        #expect(recovered == ["old-0"])
        let open = try MigrationLedger.stale(upgraded)
        #expect(open.isEmpty)
    }
}
