//
//  Sub4Migrations+RunRemoval.swift
//  Sub4
//
//  Which family a run deleted from, kept after the run itself is gone —
//  patch 415, ADR-0003 §12.160, plan topic 1C.
//
//  WHY A TABLE AND NOT ANOTHER COLUMN
//  ----------------------------------
//  `migration_run.rowsRemoved` (patch 369) answers "how many", and 1C asks
//  "from which family" — which is not one more integer, it is a row per family
//  per run. A second column could hold one family's name and would be wrong the
//  first time a manual reconciliation removed from two.
//
//  AND THE COLUMN IS NOT DURABLE, WHICH THE DEVICE PROVED ON 20 AUGUST.
//  ---------------------------------------------------------------------
//  The ledger read `runs that removed rows: 0` and `newest removal: never — no
//  run has deleted anything`. It had read `2` and `2026-08-15T15:25:27Z ·
//  authored · 1 row` the day before. `MigrationLedger` keeps the newest 200
//  successful automatic runs, which on that device is under two days, so the
//  retention prune had aged out **the record of the only two removals this
//  database has ever made**.
//
//  §5.5 said `newest removal` names the trigger, not the family. It understated
//  it: after a day it named nothing at all. A removal recorded only as a note
//  on a row that is itself prunable is not evidence, which is exactly why 1C's
//  prompt asks for a table "rather than overloading the ledger note".
//
//  SO THE RUN THAT REMOVED ROWS IS NOW NEVER PRUNED
//  ------------------------------------------------
//  The foreign key cascades, so durability could not come from the child alone;
//  it has to come from the parent surviving. `MigrationLedger.doomedIDs` now
//  spares any run with `rowsRemoved > 0`, which joins the list of what is never
//  pruned beside `manual`, `failed`, `running`, `verified` and `activated`.
//
//  That list's own comment settles the trade: *between a leak and a shredder,
//  pick the leak*. Removals are rare — two in this database's lifetime — so the
//  leak is two rows, and the shredder was destroying the only evidence that a
//  deletion ever happened.
//
//  WHY THE CASCADE IS STILL THERE
//  ------------------------------
//  It should now never fire. Keeping it means that if a run IS somehow removed
//  — a future retention rule, a repair, a hand-written statement — its removal
//  rows go with it rather than becoming orphans pointing at nothing. A
//  guarantee that is unreachable in normal operation is still the right
//  guarantee to state.
//

import GRDB

extension Sub4Migrations {

    nonisolated static let runRemoval = "2026-08-20-run-removal"

    nonisolated static func registerRunRemoval(_ m: inout DatabaseMigrator) {
        m.registerMigration(runRemoval) { db in
            try db.create(table: "migration_run_removal") { t in
                // **THE COLUMN IS NAMED, AND THE FIRST DRAFT DID NOT NAME
                // IT — §12.160.2.** `.references("migration_run", …)` binds to
                // whatever that table's PRIMARY KEY is, and `migration_run`'s
                // has not been `id` since `2026-08-16-run-recovered` rebuilt it
                // with `sequence INTEGER PRIMARY KEY AUTOINCREMENT`. GRDB
                // emitted `REFERENCES "migration_run"("sequence")`, the
                // migration ran clean, and every insert of a TEXT uuid failed
                // the foreign key at write time.
                //
                // `id TEXT NOT NULL UNIQUE` is a legal target and it is the key
                // every caller holds. **An implicit reference is a call site
                // carrying a value nobody wrote** — §12.95.4's shape, in DDL.
                t.column("runID", .text).notNull()
                    .references("migration_run", column: "id",
                                onDelete: .cascade)
                // The family's `rawValue`, a frozen literal like every
                // vocabulary inside a migration — CLAUDE.md's rule. It is
                // coupled to `RemovalFamily` by test, not by import.
                t.column("family", .text).notNull()
                t.column("rows", .integer).notNull()
                // ONE ROW PER FAMILY PER RUN. A run that removed from two
                // families writes two rows; a second write for the same pair
                // is an update, not a duplicate, so a re-record cannot inflate
                // the total.
                t.primaryKey(["runID", "family"])
                // A ROW MEANS SOMETHING WAS REMOVED. Writing `rows = 0` would
                // make "this family lost nothing" and "this family was not
                // considered" the same row, which is §12.15 in a table.
                t.check(sql: "rows > 0")
            }
            // The census reads by run and orders by the run's sequence; the
            // family totals read the whole table.
            try db.create(index: "idx_run_removal_run",
                          on: "migration_run_removal", columns: ["runID"])
        }
    }
}
