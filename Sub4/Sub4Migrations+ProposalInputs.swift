//
//  Sub4Migrations+ProposalInputs.swift
//  Sub4
//
//  What a proposal actually holds — patch 225, ADR-0003 §12.7.
//
//  WHY THIS IS NEEDED AT ALL
//  -------------------------
//  `proposal` and `proposal_change` were built in 3.2b from §8's prose rather
//  than from `ReviewProposal`, the type they have to hold. Writing §12.7 before
//  the importer found five fields with nowhere to go:
//
//      Record.appVersion            — which build produced it; thresholds move
//      Change.sessionUid            — WHAT THE CHANGE APPLIES TO
//      Change.newDetail             — the replacement text
//      Change.skip                  — whether the session is dropped
//      Change.evidence              — the computed line the change rests on
//      ReviewProposal.watchFor      — an ordered list, no table at all
//
//  `review` and `review_evidence` came out closer because §8 described them in
//  more detail. That is the whole argument for writing the mapping first: the
//  gap is invisible from the schema and obvious from the type.
//
//  WHY `proposal_change` IS RECREATED RATHER THAN ALTERED
//  ------------------------------------------------------
//  `planSessionUID` must be NOT NULL — a change that does not say which session
//  it changes is not a change. SQLite cannot ADD a NOT NULL column without a
//  default, and a default of '' would let exactly the row this column exists to
//  forbid.
//
//  So the table is dropped and rebuilt. That is safe here and would not be in
//  general: `proposal_change` has never held a row on any device. Nothing in
//  the app writes proposals to the database — the only importer that exists
//  touches activities and gear — and the health screen on the one device that
//  has this schema reports `proposal_change: 0`. Both checks were made before
//  this was written rather than assumed.
//
//  If it had held data, the honest path is the twelve-step ALTER: create the
//  new shape under a temporary name, copy with a value for the new column,
//  drop, rename. There is no value to copy for `planSessionUID`, which is
//  another way of saying those rows could not have been correct.
//
//  `planSessionUID` IS NOT A FOREIGN KEY
//  -------------------------------------
//  Same rule as `user_note`, and the same reason: a plan version is replaced
//  wholesale by an app update, and an FK to `plan_session` would delete the
//  reasoning behind every past proposal the first time a week was renumbered.
//  §8.1 records this for notes; it applies identically here.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let proposalInputs = "2026-08-06-proposal-inputs"

    nonisolated static func registerProposalInputs(_ m: inout DatabaseMigrator) {
        m.registerMigration(proposalInputs) { db in

            // Which build produced the review. Thresholds move between builds,
            // so a proposal read a month later without knowing which build
            // scored it is a conclusion without its premises.
            try db.alter(table: "review") { t in
                t.add(column: "appVersion", .text)
            }

            try db.drop(table: "proposal_change")
            try db.create(table: "proposal_change") { t in
                t.primaryKey("id", .text)
                t.column("proposalID", .text).notNull()
                    .references("proposal", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")

                // Not an FK — see the header.
                t.column("planSessionUID", .text).notNull()

                // `what` and `why` keep their meaning: a rendered summary of
                // the change, and the model's reason for it. `newDetail` is the
                // raw replacement text, which is a different thing — one is for
                // reading, the other is for applying.
                t.column("what", .text).notNull()
                t.column("why", .text)
                t.column("newDetail", .text)

                // Nullable — §6. A proposal from before this was recorded has
                // NO ANSWER, which is not the same as "does not skip".
                t.column("isSkip", .boolean)

                // "Which computed line this rests on. Required — see the
                // header." — `ReviewProposal.Change`'s own words. A change
                // without its evidence is an opinion.
                t.column("evidence", .text)

                t.uniqueKey(["proposalID", "ordinal"])
            }
            try db.create(index: "proposal_change_on_session",
                          on: "proposal_change", columns: ["planSessionUID"])

            // `watchFor` is an ORDERED LIST of short strings and had no home at
            // all. A newline-joined column would have been smaller and would
            // have thrown away the one property that matters — that these are
            // separate items, in the order the model gave them.
            try db.create(table: "proposal_watch") { t in
                t.primaryKey("id", .text)
                t.column("proposalID", .text).notNull()
                    .references("proposal", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("text", .text).notNull()
                t.uniqueKey(["proposalID", "ordinal"])
            }
        }
    }
}
