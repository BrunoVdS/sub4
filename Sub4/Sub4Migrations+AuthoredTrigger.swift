//
//  Sub4Migrations+AuthoredTrigger.swift
//  Sub4
//
//  A fifth trigger — patch 348, ADR-0003 §12.94.
//
//  WHY A MIGRATION FOR ONE STRING
//  ------------------------------
//  `triggeredBy` carries a CHECK listing the four triggers, frozen inside
//  `2026-08-12-run-trigger` and rebuilt into the table by
//  `2026-08-16-run-recovered`. A migration body is history: the list in those
//  files describes what the schema was on the day they ran and must not change
//  when a Swift enum does. `DomainSchemaTests` holds the enum to the constraint
//  from the other side, so adding a case fails the build until a migration
//  widens it. That is the mechanism working, and this is the migration.
//
//  SQLite cannot alter a CHECK. The table is rebuilt, which is what 339 did to
//  the same table one week ago and why this file is close to a copy of
//  `Sub4Migrations+RunRecovered`: a rebuild that has already run once on the
//  only install that exists is a rebuild whose shape is known.
//
//  WHAT `authored` MEANS, AND WHAT IT DOES NOT
//  -------------------------------------------
//  A store holding data the athlete created saved it, and asked for the
//  database to catch up. It is NOT `manual`: nobody pressed Import, and
//  `manual` is the one trigger whose successful runs are kept for ever
//  precisely because a person chose to make them.
//
//  It IS automatic, and its successful runs ARE disposable — there will be one
//  per note, per commute decision, per match decision, per typed constant. It
//  joins `prunableTriggers` in the same patch, which is the question
//  `prunableIsEveryAutomaticTrigger` exists to force.
//
//  `sequence` IS NOT COPIED, AND IS RENUMBERED — as at 339, and for the same
//  reason: it is `AUTOINCREMENT` and the rebuild is what assigns it. The ORDER
//  is preserved by `ORDER BY sequence`, which is all anything reads it for —
//  `newestVerified` takes the largest, and `runsSinceVerified` is a difference
//  between two of them. A gap closed by renumbering shortens that difference by
//  the number of rows that were pruned between them, which is a truer answer
//  than the one it replaces.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let authoredTrigger = "2026-08-17-authored-trigger"

    /// THE VOCABULARY THE SCHEMA PERMITS TODAY — moved here at 348a.
    ///
    /// It lived in `Sub4Migrations+RunTrigger.swift` and had to leave. That
    /// file's CHECK names four triggers and always will: a migration body is
    /// history and describes what the schema was on 12 August. A five-element
    /// list sitting three lines above a four-element constraint is exactly the
    /// drift this constant exists to catch, one level up.
    ///
    /// **IT LIVES BESIDE THE MIGRATION THAT MOST RECENTLY FROZE THE CHECK**, so
    /// the list and the SQL it mirrors are always readable in one glance, and
    /// the next widening moves it again. That movement is a signal rather than
    /// churn: a patch that adds a trigger without moving this has not written
    /// the migration that licenses it.
    ///
    /// `DomainSchemaTests.migrationRunTriggersMatch` compares it to
    /// `MigrationRunTrigger.allCases`. Its own doc says the honest thing about
    /// what a mismatch means: a new migration is owed rather than an edit to
    /// this line. 348 wrote that migration; this is the edit it licensed.
    nonisolated static let migrationRunTriggers =
        ["manual", "backgrounded", "foregrounded", "backgroundRefresh",
         "authored"]

    nonisolated static func registerAuthoredTrigger(_ m: inout DatabaseMigrator) {
        m.registerMigration(authoredTrigger, foreignKeyChecks: .deferred) { db in

            // EVERY COLUMN AND EVERY OTHER CHECK, VERBATIM from
            // `2026-08-16-run-recovered`. The single difference is `'authored'`
            // in the `triggeredBy` list; anything else different here would be
            // a schema change smuggled into a patch about a string.
            try db.execute(sql: """
                CREATE TABLE migration_run_rebuilt (
                    sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
                    id           TEXT NOT NULL UNIQUE,
                    startedUTC   TEXT NOT NULL,
                    finishedUTC  TEXT,
                    recoveredUTC TEXT,
                    state        TEXT NOT NULL
                                 CHECK (state IN ('running', 'pending', 'verified',
                                                  'activated', 'failed',
                                                  'interrupted')),
                    snapshotID   TEXT,
                    appVersion   TEXT NOT NULL,
                    note         TEXT,
                    triggeredBy  TEXT
                                 CHECK (triggeredBy IS NULL
                                        OR triggeredBy IN ('manual', 'backgrounded',
                                                           'foregrounded',
                                                           'backgroundRefresh',
                                                           'authored')),

                    CHECK (
                        (state = 'running'
                         AND finishedUTC IS NULL AND recoveredUTC IS NULL)
                        OR
                        (state = 'interrupted'
                         AND finishedUTC IS NULL AND recoveredUTC IS NOT NULL)
                        OR
                        (state NOT IN ('running', 'interrupted')
                         AND finishedUTC IS NOT NULL AND recoveredUTC IS NULL)
                    ),
                    CHECK (finishedUTC IS NULL OR finishedUTC >= startedUTC)
                )
                """)

            // A STRAIGHT COPY. 339 needed `CASE` expressions because it was
            // splitting `finishedUTC` into two columns; this changes no value
            // in any row, so a transform here would be a bug rather than a
            // migration.
            //
            // `ORDER BY sequence` and not `rowid`: since 339 the sequence IS
            // the order, and the two agree only until a prune leaves a gap.
            try db.execute(sql: """
                INSERT INTO migration_run_rebuilt
                  (id, startedUTC, finishedUTC, recoveredUTC, state,
                   snapshotID, appVersion, note, triggeredBy)
                SELECT id, startedUTC, finishedUTC, recoveredUTC, state,
                       snapshotID, appVersion, note, triggeredBy
                  FROM migration_run
                 ORDER BY sequence
                """)

            try db.drop(table: "migration_run")
            try db.rename(table: "migration_run_rebuilt", to: "migration_run")

            // Dropped with the old table, so it is recreated here — exactly as
            // at 339. An index that quietly stops existing is a table scan
            // nobody notices until the ledger is long.
            try db.execute(sql: """
                CREATE INDEX migration_run_started
                    ON migration_run (startedUTC DESC, sequence DESC)
                """)
        }
    }
}
