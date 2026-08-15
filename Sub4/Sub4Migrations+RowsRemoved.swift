//
//  Sub4Migrations+RowsRemoved.swift
//  Sub4
//
//  What a run deleted, kept — patch 369, ADR-0003 §12.113.
//
//  WHY THIS EXISTS
//  ---------------
//  360 made `.authored` the only trigger permitted to delete, and §12.20 says
//  nothing deletes on the strength of a read nobody checked. Neither claim
//  could be audited after the fact: `rows removed in total` lives in the import
//  REPORT, the paste prints only the newest report, and the ledger — which
//  keeps 241 rows — had nowhere to put it.
//
//  On 15 August an authored run pruned a plan move. It showed "moves withdrawn
//  1" on one screen for as long as that screen was open and left nothing behind
//  anywhere: not the count, not the trigger, not the time. The only delete this
//  app has ever performed is unauditable.
//
//  ALTER, NOT REBUILD
//  ------------------
//  Every migration since `2026-08-15-interrupted-run` has rebuilt this table,
//  because each was widening a CHECK and SQLite cannot alter one. This adds a
//  nullable column and changes no constraint, so `ALTER TABLE … ADD COLUMN` is
//  both sufficient and safer: `sequence` is `AUTOINCREMENT` and load-bearing —
//  `runsSinceVerified` is derived from it precisely so the retention prune
//  cannot flatter the number — and a rebuild is exactly the operation that
//  would have to re-establish it by hand.
//
//  NULLABLE, AND NOT `DEFAULT 0`
//  -----------------------------
//  A default of 0 would make all 241 existing rows claim they deleted nothing.
//  That is a claim none of them made: they finished before anything counted.
//  NULL says "not recorded"; 0 says "recorded, and it was none". §12.54.2 — a
//  value that cannot tell those apart is a value that reads as evidence and is
//  not.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let rowsRemoved = "2026-08-18-rows-removed"

    nonisolated static func registerRowsRemoved(_ m: inout DatabaseMigrator) {
        m.registerMigration(rowsRemoved) { db in
            // NO `foreignKeyChecks: .deferred`. Its neighbours pass it because
            // they drop and recreate a table other rows reference; nothing is
            // dropped here.
            try db.execute(sql: """
                ALTER TABLE migration_run ADD COLUMN rowsRemoved INTEGER
                """)
        }
    }
}
