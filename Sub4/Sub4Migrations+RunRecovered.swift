//
//  Sub4Migrations+RunRecovered.swift
//  Sub4
//
//  A recovery time, and a sequence — patch 339, ADR-0003 §12.88.
//
//  WHY THIS IS A SECOND REBUILD OF A TABLE REBUILT YESTERDAY
//  ---------------------------------------------------------
//  `2026-08-15-interrupted-run` added the sixth state and recorded the moment a
//  later launch noticed a killed run in `finishedUTC`. That is wrong, and its
//  sibling file now says so: a killed process cannot report when it stopped, so
//  a finish time it never had is a fiction the schema was asserting.
//
//  The correction was first written into 08-15's own body. It could not stay
//  there. That identifier had already run on the phone holding this project's
//  only training history, and GRDB records an identifier once — editing the
//  body changes what a FRESH install gets while the device keeps what it built,
//  and the two diverge silently under one name.
//
//  It was not hypothetical. Every write-through on the device began failing
//  with `no such column: sequence` while every test passed, because a test
//  database is built from nothing and has no history to disagree with.
//
//  So the shape moves here. A device that ran 08-15 runs this and arrives; a
//  fresh install runs both and arrives at the same place.
//
//  THE `CASE` IS THE WHOLE PATCH
//  -----------------------------
//  Three rows on the device are already `interrupted` and already carry the
//  `finishedUTC` that 08-15 wrote. Under the invariant below they are illegal.
//
//  They are not dropped and they are not repaired by hand: the timestamp is
//  REINTERPRETED as what it always was — the moment a later launch found the
//  run, which is exactly `recoveredUTC`. The copy moves it across for
//  `interrupted` rows and leaves every other row alone.
//
//  Tested against a copy of the device's own database before this was written:
//  with the CASE, all 56 rows copy; without it, `CHECK constraint failed`. No
//  test database can catch that, because none of them holds such a row.
//
//  `recoveredUTC` IS DELIBERATELY NOT ORDERED AGAINST `startedUTC`
//  ---------------------------------------------------------------
//  `finishedUTC >= startedUTC` is kept: a run that finished did so after it
//  began. Recovery is different — the phone's wall clock can be corrected
//  backwards between two processes, and a recovery must record the value that
//  was observed rather than fail or invent a later one. A constraint that turns
//  a corrected clock into a refused launch protects nothing at the cost of the
//  thing it guards.
//
//  `sequence` REPLACES `startedUTC` AS THE ORDER
//  ---------------------------------------------
//  Two runs can start in the same second — `migration_run` is written on every
//  app switch — and "the last run" is the question this table exists to answer.
//  The same class of mistake as keying a review on its run time, which cost
//  patch 337. `id` stays UNIQUE, so every lookup by id is unchanged.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let runRecovered = "2026-08-16-run-recovered"

    nonisolated static func registerRunRecovered(_ m: inout DatabaseMigrator) {
        m.registerMigration(runRecovered, foreignKeyChecks: .deferred) { db in

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
                                                           'backgroundRefresh')),

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

            try db.execute(sql: """
                INSERT INTO migration_run_rebuilt
                  (id, startedUTC, finishedUTC, recoveredUTC, state,
                   snapshotID, appVersion, note, triggeredBy)
                SELECT id, startedUTC,
                       CASE WHEN state = 'interrupted' THEN NULL
                            ELSE finishedUTC END,
                       CASE WHEN state = 'interrupted' THEN finishedUTC
                            ELSE NULL END,
                       state, snapshotID, appVersion, note, triggeredBy
                  FROM migration_run
                 ORDER BY rowid
                """)

            try db.drop(table: "migration_run")
            try db.rename(table: "migration_run_rebuilt", to: "migration_run")

            try db.execute(sql: """
                CREATE INDEX migration_run_started
                    ON migration_run (startedUTC DESC, sequence DESC)
                """)
        }
    }
}
