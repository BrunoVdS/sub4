//
//  Sub4Migrations+InterruptedRun.swift
//  Sub4
//
//  A sixth state for a run nobody closed — patch 338, ADR-0003 §12.86.
//
//  WHAT `running` WAS BEING ASKED TO MEAN
//  -------------------------------------
//  Two things, and nothing on the row could say which:
//
//      the write is open RIGHT NOW, in this process
//      the write WAS open when the process was killed
//
//  `MigrationLedger`'s header is right that the second is a fact worth keeping
//  — "the alternative is a ledger that quietly forgets the crash" — and
//  `stale()` is right to refuse to rewrite them to `failed`, because `failed`
//  means the write threw and a crash is not a throw.
//
//  But leaving them in `running` keeps the fact by keeping the AMBIGUITY, and
//  the count grows without bound: an off-device read of the container on
//  9 August found three rows in `running`, one of them opened forty-six seconds
//  earlier and genuinely live. Nothing could tell the reader that.
//
//  `interrupted` is the state that keeps the fact and drops the ambiguity. It
//  is terminal, it carries a finish time, and it says what happened.
//
//  WHEN THE AMBIGUITY RESOLVES, AND WHY IT IS FREE
//  -----------------------------------------------
//  At launch. By construction no run from a previous process can still be open,
//  so every row in `running` at that moment was interrupted, with no heuristic,
//  no timeout and no clock comparison. `Sub4Launch` closes them immediately
//  after the database opens and before anything else touches it.
//
//  WHY A TABLE REBUILD RATHER THAN A LOOSER CHECK
//  ----------------------------------------------
//  SQLite cannot alter a CHECK, and `migration_run.state` carries three of
//  them. Same twelve-step rebuild as `2026-08-13-confidence-scale`, and cheap
//  for the same reason it was cheap there: the table holds tens of rows, not
//  thousands, because `MigrationLedger` prunes it on every insert.
//
//  The alternative — dropping the CHECK so any string is admissible — trades a
//  rebuild for a column that can hold a typo forever. `Sub4Migrations`' whole
//  argument about frozen vocabularies is that the constraint is the point.
//
//  THE TWO NEIGHBOURING CHECKS ARE COPIED VERBATIM
//  -----------------------------------------------
//  `(state = 'running') = (finishedUTC IS NULL)` still holds after this change
//  and is what makes `interrupted` unable to exist without a finish time —
//  which is the entire behavioural difference between the new state and the old
//  one. And `triggeredBy`'s CHECK comes back with it, because a rebuild that
//  silently dropped a constraint added by a later migration would be a schema
//  nobody could read from the source.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let interruptedRun = "2026-08-15-interrupted-run"

    /// The SIX states, frozen at 9 August 2026 — was five from 5 August.
    /// `DomainSchemaTests` compares this against `MigrationRunState.allCases`;
    /// a mismatch means a new migration is owed rather than an edit here.
    ///
    /// `migrationRunStates` beside it in `Sub4Migrations+MigrationRun` is NOT
    /// updated. That list is what the 11 August migration wrote, it is history,
    /// and the test that reads it must read the newest list — which is this one.
    nonisolated static let migrationRunStatesWithInterrupted =
        ["running", "pending", "verified", "activated", "failed", "interrupted"]

    nonisolated static func registerInterruptedRun(_ m: inout DatabaseMigrator) {
        m.registerMigration(interruptedRun, foreignKeyChecks: .deferred) { db in

            try db.execute(sql: """
                CREATE TABLE migration_run_rebuilt (
                    id          TEXT PRIMARY KEY NOT NULL,
                    startedUTC  TEXT NOT NULL,
                    finishedUTC TEXT,
                    state       TEXT NOT NULL
                                CHECK (state IN ('running', 'pending', 'verified',
                                                 'activated', 'failed',
                                                 'interrupted')),
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
                )
                """)

            // EVERY ROW CARRIED ACROSS UNCHANGED, `running` INCLUDED.
            //
            // The rows already stuck open are NOT converted here. A migration
            // runs inside the launch that is about to open its own run, and it
            // cannot tell — from SQL — which of the open rows belongs to the
            // process it is running in. `Sub4Launch` can, because it runs
            // before any run is opened. Converting here would have been one
            // line and would have been a guess.
            try db.execute(sql: """
                INSERT INTO migration_run_rebuilt
                  (id, startedUTC, finishedUTC, state, snapshotID, appVersion,
                   note, triggeredBy)
                SELECT id, startedUTC, finishedUTC, state, snapshotID, appVersion,
                       note, triggeredBy
                  FROM migration_run
                """)

            try db.drop(table: "migration_run")
            try db.rename(table: "migration_run_rebuilt", to: "migration_run")

            // The index goes with the table and has to be rebuilt by name. The
            // ordering is load-bearing for "the last run", which every reader
            // of this table wants.
            try db.execute(sql: """
                CREATE INDEX migration_run_started
                    ON migration_run (startedUTC DESC)
                """)
        }
    }
}
