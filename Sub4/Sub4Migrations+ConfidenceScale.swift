//
//  Sub4Migrations+ConfidenceScale.swift
//  Sub4
//
//  One column, one contract — patch 334, ADR-0003 §12.82.
//
//  THE CONTRADICTION, AND HOW LONG IT STOOD
//  ----------------------------------------
//  `proposal.confidence` was created at `2026-08-06-proposal-inputs` with
//  `CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 100))`.
//
//  `ProposalView` draws it as five pips — `i <= proposal.confidence` over
//  1...5. `ReviewRehearsalTests` asserts `p.confidence >= 1 && p.confidence
//  <= 5`. And `AuthoredImportTests` has been writing **70** since patch 225,
//  which satisfies the column and overflows the view.
//
//  Three places, two contracts, and the column was the one that admitted
//  everything. §12.71.4 recorded it at 327 and declined to decide; 334 decides.
//
//  WHY 1–5 AND NOT 0–100
//  ---------------------
//  Because five levels is what the athlete is actually shown and what the
//  model is actually asked for. Nothing anywhere reads a percentage, nothing
//  draws one, and no evidence says five was too coarse. The 0–100 range was a
//  column written wider than its subject — the easy direction to get wrong,
//  because a wide CHECK never refuses anything and therefore never complains.
//
//  WHY A NEW MIGRATION AND NOT AN EDIT
//  -----------------------------------
//  §12.10.2's rule, and `Sub4Migrations+ZoneFloorZero`'s scar. Patch 229 edited
//  a registered migration's body in place on the reasoning that it had never
//  run against a persistent database. It had. GRDB had recorded the identifier,
//  the edited body never ran again anywhere, eight tests stayed green and the
//  phone refused all five zones. **A migration is history.**
//
//  SQLite CANNOT ALTER A CHECK, so the table is rebuilt — the standard
//  twelve-step, not a drop.
//
//  ZoneFloorZero dropped `hr_zone` outright because it held zero rows on the
//  only device with that schema, verified rather than assumed. `proposal`,
//  `proposal_change` and `proposal_watch` also read zero on this device today
//  — the 9 August wipe took the eleven rehearsal records with them. **This
//  migration still copies rather than drops**, because a migration runs on
//  whatever database reaches it, and "it was empty on the machine I wrote it
//  on" is a fact about that machine.
//
//  AN OUT-OF-RANGE VALUE BECOMES NULL, AND THAT IS DELIBERATE
//  ---------------------------------------------------------
//  A stored 70 cannot be re-scaled into 1–5 without inventing a number. 70 out
//  of 100 is not 4 out of 5 — it is a value written under a contract that has
//  been retired, and the honest translation of "I no longer know what this
//  meant" is NULL, which the column has always permitted and which
//  `ReviewRoundTrip` already reports as `confidence range seen: —`.
//
//  Nulling silently would be worse than refusing, so it is stated here, in the
//  ADR, and the count is visible on the Database screen the moment a read-back
//  runs: a proposal whose confidence went from 70 to nothing shows as a field
//  difference, not as agreement.
//
//  `foreignKeyChecks: .deferred` IS LOAD-BEARING
//  --------------------------------------------
//  `proposal_change` and `proposal_watch` both reference `proposal` with
//  `onDelete: .cascade`. With foreign keys enforced, `DROP TABLE proposal`
//  performs an implicit delete and takes every child row with it — on a
//  database that has any. Deferred checks disable enforcement for the body and
//  re-verify at the end, which is the whole reason GRDB offers the parameter.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let confidenceScale = "2026-08-13-confidence-scale"

    nonisolated static func registerConfidenceScale(_ m: inout DatabaseMigrator) {
        m.registerMigration(confidenceScale, foreignKeyChecks: .deferred) { db in

            // The same table, one CHECK narrower. Every other column and
            // constraint is copied verbatim from `2026-08-06-proposal-inputs`
            // — a rebuild that quietly changed a second thing would be a
            // migration nobody could read afterwards.
            try db.create(table: "proposal_rebuilt") { t in
                t.primaryKey("id", .text)
                t.column("reviewID", .text).notNull()
                    .references("review", onDelete: .cascade)
                t.column("verdict", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("confidence", .integer)
                    .check(sql: "confidence IS NULL OR (confidence >= 1 AND confidence <= 5)")
                t.column("receivedUTC", .text).notNull()
                // NULL while undecided. A proposal the athlete has neither
                // accepted nor rejected is a real and common state.
                t.column("decision", .text)
                    .check(sql: "decision IS NULL OR decision IN ('accepted', 'rejected')")
                t.column("decidedUTC", .text)
            }

            try db.execute(sql: """
                INSERT INTO proposal_rebuilt
                  (id, reviewID, verdict, summary, reasoning,
                   confidence, receivedUTC, decision, decidedUTC)
                SELECT id, reviewID, verdict, summary, reasoning,
                       CASE WHEN confidence BETWEEN 1 AND 5
                            THEN confidence ELSE NULL END,
                       receivedUTC, decision, decidedUTC
                FROM proposal
                """)

            try db.drop(table: "proposal")
            try db.rename(table: "proposal_rebuilt", to: "proposal")
        }
    }
}
