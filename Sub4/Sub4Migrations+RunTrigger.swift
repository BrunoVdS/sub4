//
//  Sub4Migrations+RunTrigger.swift
//  Sub4
//
//  What started the import — patch 311, D6b groundwork §5.4, ADR-0003 §12.55.
//
//  WHAT THE DIAGNOSTICS PASTE MADE VISIBLE
//  ---------------------------------------
//  `migration_run: 45`. Forty-five ledger rows after three days of D6b, and no
//  way to tell which of them were a person pressing Import and which were the
//  app writing through on its own.
//
//  Until patch 303 the two could be told apart BY ACCIDENT: an automatic run
//  passed no snapshot id, so a NULL there meant "not a manual import". 303 fixed
//  a real defect — an automatic run does have a snapshot preceding it, and
//  recording it is accurate rather than convenient — and in doing so removed the
//  only distinction this table had. Nothing was wrong with 303. The distinction
//  was never a column; it was a side effect, and **a side effect is not a
//  record.**
//
//  THE COLUMN IS CALLED `triggeredBy`, NOT `trigger`
//  -------------------------------------------------
//  `TRIGGER` is an SQL keyword. SQLite is lenient about keywords used as
//  identifiers and would probably accept it in every statement this app writes,
//  and "probably accept it" is not a property to build a schema on — the failure
//  would be one hand-written query, months from now, in a context where the
//  parser stops being lenient. The groundwork calls it the trigger column and
//  this file is where that name meets a parser.
//
//  A NEW MIGRATION, BECAUSE THAT IS THE ONLY WAY
//  ---------------------------------------------
//  `2026-08-11-migration-run` has run on the device that holds the real ledger.
//  Its body is history: editing it would change what a FRESH install gets while
//  the phone keeps the old table, which is §12's rule and is exactly what patch
//  229 got wrong and patch 236 had to undo.
//
//  So: `ALTER TABLE ... ADD COLUMN`. The 45 existing rows get NULL, which is the
//  truth about them — nobody recorded what started them, and inventing an answer
//  now would be worse than the gap.
//
//  NULLABLE, AND NULL IS A THIRD ANSWER
//  ------------------------------------
//  NOT NULL with a default would have required choosing a value for those 45
//  rows. Every choice is a guess, and a guessed `backgrounded` is indistinguish-
//  able from a recorded one — §12.15's shape, and the eighth time this project
//  has met it. `MigrationRunTrigger.unrecordedLabel` is what a NULL prints as,
//  on screen and in the paste, so the gap says it is a gap.
//
//  THE VOCABULARY IS FROZEN HERE, LIKE EVERY OTHER ONE IN THIS SCHEMA
//  -----------------------------------------------------------------
//  Four literals written into this body, never read from `MigrationRunTrigger`.
//  Same reason as `migrationRunStates` beside it: a body that reads a live Swift
//  enum means adding a case silently changes what a fresh install gets while
//  every existing device keeps the old constraint. `DomainSchemaTests` asserts
//  the two agree; when they stop, a new migration is owed.
//
//  NO INDEX ON IT, AND THAT IS A MEASUREMENT RATHER THAN AN OMISSION
//  ----------------------------------------------------------------
//  The only query that filters on this column is the prune, which runs once per
//  import over a table `MigrationLedger.keepAutomaticRuns` holds near 200 rows.
//  `migration_run_started` already orders it. An index here would cost a write
//  on every insert to save a scan of two hundred rows.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let runTrigger = "2026-08-12-run-trigger"

    // `migrationRunTriggers` LIVED HERE UNTIL 348a AND HAD TO LEAVE.
    //
    // It mirrors the values the schema permits TODAY, and the CHECK below
    // names the values the schema permitted on 12 August. Those were the same
    // list for thirty-six patches, which is why one constant could sit beside
    // one migration and be right about both.
    //
    // 348 widened the constraint in `2026-08-17-authored-trigger`, and this
    // file's SQL correctly did not change — a migration body is history. So
    // the constant moved to the migration that most recently froze the CHECK,
    // where the list and the SQL it mirrors are readable in one glance.

    nonisolated static func registerRunTrigger(_ m: inout DatabaseMigrator) {
        m.registerMigration(runTrigger) { db in

            // The CHECK admits NULL explicitly. SQLite would admit it anyway —
            // a CHECK is satisfied unless it evaluates to false, and `NULL IN
            // (...)` is NULL — but writing the rule out is what tells the next
            // reader that the gap is intended rather than tolerated.
            try db.execute(sql: """
                ALTER TABLE migration_run
                  ADD COLUMN triggeredBy TEXT
                      CHECK (triggeredBy IS NULL
                             OR triggeredBy IN ('manual', 'backgrounded',
                                                'foregrounded', 'backgroundRefresh'))
                """)
        }
    }
}
