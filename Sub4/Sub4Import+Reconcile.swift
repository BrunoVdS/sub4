//
//  Sub4Import+Reconcile.swift
//  Sub4
//
//  What the athlete deleted — D4 step 5, patch 274, ADR-0003 §12.21.
//
//  THE IMPORTER HAS BEEN ADDITIVE-ONLY SINCE IT WAS WRITTEN
//  --------------------------------------------------------
//  Found on the device on 5 August: `review` held 1, `proposal` 1,
//  `proposal_change` 2, `proposal_watch` 2 — the rehearsal record from patch
//  269, deleted from `proposals.json` hours earlier and still in the database.
//
//  Every `DELETE` in the six importer files is a replace-the-children-of-this-
//  parent delete: zones, a review's evidence and proposal, a trace, a detail,
//  an activity's gear references. Nothing anywhere noticed a record that had
//  disappeared from a store. So *Back to automatic* on a match, deleting a
//  note, and deleting a review all left rows behind — the first two making the
//  verifier disagree for ever, the third invisible because the verifier does
//  not check reviews.
//
//  WHAT IS RECONCILED, AND WHY THE LIST IS SHORT
//  ---------------------------------------------
//  Only the three the athlete can delete from, and only ever within his own
//  account:
//
//    user_note        keyed by planSessionUID
//    match_decision   keyed by planSessionUID
//    review           keyed by ranUTC — and its four children go with it,
//                     because `review_evidence` and `proposal` cascade from
//                     `review`, and `proposal_change` and `proposal_watch`
//                     cascade from `proposal`
//
//  Activities, gear, weather, traces, details, the plan and the profile are
//  NOT reconciled. They are fetched or bundled, so an empty store means a sync
//  that has not run rather than a decision to remove something — and the
//  athlete cannot delete them one at a time in the first place. A pass that
//  treated "Strava is unreachable" as "the athlete deleted 668 activities"
//  would be the worst defect this project has ever shipped.
//
//  THE GATE IS NOT OPTIONAL AND IT IS NOT COMPUTED HERE
//  ----------------------------------------------------
//  `Sub4Import` is `nonisolated` end to end and `StoreReadJournal` is on the
//  main actor, so the caller asks and passes the answer in. That is the right
//  shape anyway: the decision to delete belongs to the screen that knows what
//  was read, not to the code doing the deleting.
//
//  `Reconciliation` carries the REASON rather than a Bool, so "a store could
//  not be read" and "the caller did not ask" are different words on the health
//  screen. A single false would have made a forgotten argument look exactly
//  like the gate doing its job.
//
//  IT DELETES ROW BY ROW, WHICH IS NOT THE OBVIOUS SQL
//  ---------------------------------------------------
//  `DELETE … WHERE key NOT IN (…)` is one statement and would be shorter. It
//  also cannot express an empty keep-set without special-casing it into
//  `DELETE FROM …`, which is the single most dangerous statement in this file
//  written as a fallthrough; it binds one parameter per note, against a limit
//  that is a build setting of SQLite rather than a promise; and it cannot
//  count what it removed. Fetching the keys and deleting by id costs one extra
//  read on tables holding single digits.
//

import Foundation
import GRDB

/// Whether the reconciliation pass ran, and if not, why not.
nonisolated enum Reconciliation: Equatable, Sendable {

    case run

    /// Carries the reason so the health screen can print it. See the header:
    /// "a store could not be read" and "the caller did not ask for it" are
    /// both refusals and only one of them is the gate working.
    case skipped(String)

    var isRunning: Bool { self == .run }

    var line: String {
        switch self {
        case .run:               "yes"
        case .skipped(let why):  "skipped — \(why)"
        }
    }
}

extension Sub4Import {

    /// Removes rows whose record is no longer in the store.
    ///
    /// Runs INSIDE the import's own write, so a throw here rolls the whole
    /// import back rather than leaving a half-reconciled database. That is
    /// also why it runs last: everything above it has already put the current
    /// records in, so what is left over is genuinely left over.
    nonisolated static func reconcileAuthored(
        _ d: Database,
        notes: [NotesStore.Note],
        proposals: [ProposalStore.Record],
        matchDecisions: [MatchDecision],
        into report: inout Report
    ) throws {

        report.notesRemoved = try removeMissing(
            d, from: "user_note", keyedBy: "planSessionUID",
            keep: Set(notes.map(\.sessionUid)))

        report.matchDecisionsRemoved = try removeMissing(
            d, from: "match_decision", keyedBy: "planSessionUID",
            // THE STORE'S UIDS, NOT THE IMPORTED ONES. A decision the importer
            // held back — one naming an activity that is not here, or an
            // excluded recording — is still a decision the athlete made, and
            // its uid is in this set. So the pass leaves it alone instead of
            // reading "no row was written" as "he deleted it".
            keep: Set(matchDecisions.map(\.sessionUid)))

        report.reviewsRemoved = try removeMissing(
            d, from: "review", keyedBy: "ranUTC",
            // The same key `importProposals` matches on, formatted by the same
            // function. If those two ever disagreed, every import would delete
            // every review and write it back — which is why they are one line
            // apart in the same file rather than two conventions.
            keep: Set(proposals.map { iso8601($0.ranAt) }))
    }

    /// The one-table pass.
    ///
    /// `table` and `keyedBy` are interpolated into SQL and are compile-time
    /// literals from this file — there is no path by which anything the
    /// athlete typed reaches them. Said out loud because string-interpolated
    /// SQL earns the question every time.
    private nonisolated static func removeMissing(
        _ d: Database,
        from table: String,
        keyedBy keyColumn: String,
        keep: Set<String>
    ) throws -> Int {

        let rows = try Row.fetchAll(d, sql: """
            SELECT id, \(keyColumn) AS reconcileKey FROM \(table)
            WHERE accountID = ?
            """, arguments: [accountID])

        var removed = 0
        for row in rows {
            let key: String = row["reconcileKey"]
            guard !keep.contains(key) else { continue }
            let id: String = row["id"]
            try d.execute(sql: "DELETE FROM \(table) WHERE id = ?",
                          arguments: [id])
            removed += 1
        }
        return removed
    }
}
