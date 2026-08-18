//
//  Sub4Migrations+RunCause.swift
//  Sub4
//
//  Why a run happened, kept — patch 406, ADR-0003 §12.150.
//
//  WHY THIS EXISTS
//  ---------------
//  On 18 August at 04:02 the ledger said an authored run had fired four minutes
//  earlier and could not say what caused it. The question mattered: patch 405
//  had just stopped restores announcing, and the run could equally have been a
//  restore press that proved the fix had failed, or `AthleteStore.save`
//  catching up an athlete cache after a launch-time sync. Two exports either
//  side of a press settled it by elimination — three presses would have shown
//  three more runs — but elimination is inference, and the table that records
//  what touched the database should not need any.
//
//  `DatabaseWriteThrough.record(outcome:reason:)` already HAD the sentence.
//  `noteAuthoredChange("a session note was saved")` passes it, `run(reason:)`
//  carries it, and then it was used on FAILURE only and dropped on success —
//  so every run that worked became anonymous. §12.15: a diagnostic that cannot
//  say why it has no answer will be read as having one, and this one could not
//  say why it happened at all.
//
//  ALTER, NOT REBUILD
//  ------------------
//  `2026-08-18-rows-removed` made the same call for the same reason and its
//  argument is unchanged: a nullable column that alters no constraint needs no
//  rebuild, and `sequence` is `AUTOINCREMENT` and load-bearing —
//  `runsSinceVerified` derives from it precisely so a retention prune cannot
//  flatter the number, and a rebuild is the one operation that would have to
//  re-establish it by hand.
//
//  NULLABLE, AND NOT `DEFAULT ''`
//  ------------------------------
//  257 rows exist that never recorded a cause. An empty string would say
//  "recorded, and it was nothing"; NULL says "not recorded". §12.54.2 — the
//  same distinction `rowsRemoved` drew between a run that deleted none and a
//  run that finished before anything counted.
//
//  NOT THE `note` COLUMN, and that is deliberate. Verification and activation
//  own `note`; putting a second meaning in it would make every reader ask which
//  kind of row it was looking at before it could read the value. One column,
//  one question.
//
//  WHAT IT MAY NOT CARRY
//  ---------------------
//  The sentences are written at the call sites and are all of the form "a
//  session note was saved". They name a KIND of change, never a note's text, a
//  session uid or an activity. §12.7 holds because the strings are literals in
//  the source — `causeIsAConstantSentence` is the test that keeps them so.
//

import GRDB

extension Sub4Migrations {

    nonisolated static let runCause = "2026-08-19-run-cause"

    nonisolated static func registerRunCause(_ m: inout DatabaseMigrator) {
        m.registerMigration(runCause) { db in
            // NO `foreignKeyChecks: .deferred` — nothing is dropped here.
            try db.execute(sql: """
                ALTER TABLE migration_run ADD COLUMN cause TEXT
                """)
        }
    }
}
