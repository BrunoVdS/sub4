//
//  Sub4Migrations+MigrationRun.swift
//  Sub4
//
//  The import ledger — patch 255, migration contract item 11, ADR-0003 §12.15.
//
//  ONE ROW PER IMPORT, AND IT IS NOT A LOG
//  ---------------------------------------
//  `lifecycle_event` already records what the athlete did to his data. This
//  records what the MIGRATION did, which is a different question with a
//  different reader: a log is read by a person after something went wrong, and
//  this is read by the app before it is allowed to do something. D7 switches
//  reads to the database only when a run reached `verified`, and that sentence
//  needs a row to be true of.
//
//  THE VOCABULARY IS FROZEN HERE, LIKE EVERY OTHER ONE IN THIS SCHEMA
//  -----------------------------------------------------------------
//  `state` is CHECKed against five literals written into this migration body
//  and never read from `MigrationRunState`. The reason is the one in
//  `Sub4Migrations`' header: a body that reads a live Swift enum means adding a
//  case silently changes what a fresh install gets while every existing device
//  keeps the old constraint — two different databases under one migration
//  identifier. `SchemaAgreementTests` asserts the two agree; when they stop, a
//  new migration is owed.
//
//  TWO INVARIANTS THE SCHEMA CAN STATE, AND ONE IT CANNOT
//  -----------------------------------------------------
//  It can say a finished run has a finish time and an unfinished one does not,
//  and it can say the finish is not before the start. Both are CHECKs below.
//
//  It cannot say that at most one run is `activated` — that is a partial unique
//  index over a column that does not exist yet, because "activated" is a
//  property of the app, not of a run. When D7 arrives it will need one, and the
//  shape is already in this schema: `plan_version_one_active`.
//
//  NO FOREIGN KEY TO THE SNAPSHOT, DELIBERATELY
//  --------------------------------------------
//  `snapshotID` names a folder on disk, not a row. The snapshot is a directory
//  of copies with a `manifest.json` beside it and nothing in the database, so
//  there is nothing to reference. Recording the name means a run can be traced
//  back to the bytes it read; a folder deleted by hand leaves a name pointing
//  at nothing, which is the truth and is better than a cascade that would erase
//  the run.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let migrationRun = "2026-08-11-migration-run"

    /// The five states, frozen at 5 August 2026. Compared against
    /// `MigrationRunState.allCases` by test; a mismatch means a new migration
    /// is owed rather than an edit to this line.
    nonisolated static let migrationRunStates =
        ["running", "pending", "verified", "activated", "failed"]

    nonisolated static func registerMigrationRun(_ m: inout DatabaseMigrator) {
        m.registerMigration(migrationRun) { db in

            try db.execute(sql: """
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

                    -- A finished run has a finish time and an unfinished one
                    -- does not. Written as an equivalence rather than two
                    -- separate rules so neither half can be satisfied alone.
                    CHECK ((state = 'running') = (finishedUTC IS NULL)),

                    -- Both are ISO-8601, so string comparison is chronological.
                    CHECK (finishedUTC IS NULL OR finishedUTC >= startedUTC)
                )
                """)

            // The only query this table has: newest first. Small forever — one
            // row per import — but the index costs nothing and the ordering is
            // load-bearing for "the last run", which is what every reader wants.
            try db.execute(sql: """
                CREATE INDEX migration_run_started
                    ON migration_run (startedUTC DESC)
                """)
        }
    }
}
