//
//  Sub4Import+Correction.swift
//  Sub4
//
//  Which rides are commutes — D5 slice 4, patch 280, ADR-0003 §12.26.
//
//  THE ONLY SOURCE THAT NEEDED NO RESHAPE
//  --------------------------------------
//  `match_decision` needed a date the store did not have (§12.19).
//  `rejection` needed six fields hidden inside a rendered sentence (§12.24).
//  `commutes.json` needed nothing, and its header says why in as many words:
//
//    "A DECISION CARRIES ITS DATE. Not decoration: the `correction` table in
//     ADR-0003 §8 wants provenance for exactly this kind of row, and a decision
//     with no timestamp cannot be reconciled against a later one."
//
//  Patch 251 wrote that seven weeks before this importer existed. It is the
//  only place in this project where a store was built for a table that had not
//  been filled yet and turned out to fit on the first try.
//
//  THE MAPPING
//  -----------
//    subjectKind   "activity"
//    subjectID     the CANONICAL id, resolved through `activity_alias` — the
//                  store is keyed by Strava id, like weather and the traces
//    field         "isCommute"
//    value         "true" / "false"
//    authoredUTC   `CommuteDecision.decided`, exactly as recorded
//
//  `reason` IS PROVENANCE HERE, NOT AN ARGUMENT
//  --------------------------------------------
//  §8 says the column is NOT NULL because "every correction in the app today
//  carries a written reason — 'chip time, official results' — and one that
//  does not is indistinguishable from a mistake". Every correction in the app
//  *at that time* was a `DataCorrections` entry, where the reason is the case
//  for overriding a recorded number.
//
//  A commute decision has no such case, and needs none. Patch 251's position
//  is that the commute IS the athlete's decision — "not Strava's and not a
//  threshold's" — so the answer is not evidence for the correction, it is the
//  correction. The reason states where it came from, which is the only thing
//  there is to say and is true of every row without exception.
//
//  WHAT WAS DELIBERATELY NOT WRITTEN THERE. The obvious richer version is
//  "the athlete said commute; the distance rule said otherwise" — computable
//  from `Activity.commuteByDistance`. It is not written because it would bake
//  today's `MatchRules.minRideKm` into a stored sentence: change the threshold
//  next year and every historic reason becomes a claim about a rule that no
//  longer exists. `CommuteStore.overrides(in:)` computes that comparison live,
//  which is where a moving rule belongs.
//
//  IT PRUNES, AND ONLY ITS OWN FIELD
//  ---------------------------------
//  `CommuteStore.clear(_:)` exists and is reachable — "I have no opinion" is a
//  real answer, distinct from `false` — so rows can go stale. `commutes.json`
//  is an authored store with a decode step, so the §12.20 hazard is real here
//  and the prune runs only when `Reconciliation` says so, on the same gate as
//  notes, reviews and match decisions.
//
//  It claims only `field = 'isCommute'`. A `DataCorrections` row landing in
//  this table later is somebody else's and must survive.
//
//  And it runs only when every decision was ACCOUNTED FOR — see the guard. A
//  decision the database could not place cannot protect its own row, so one
//  unresolved ride is enough to hold the whole prune back.
//

import Foundation
import GRDB

extension Sub4Import {

    /// The field this importer owns. A literal in one place, because the
    /// import and the prune must agree about it and a typo in either would be
    /// silent — the prune would spare nothing, or delete everything.
    nonisolated static let commuteField = "isCommute"

    nonisolated static func importCorrections(
        _ d: Database,
        decisions: [CommuteDecision],
        reconcile: Reconciliation,
        now: String,
        into report: inout Report
    ) throws {
        var keep: Set<String> = []

        for decision in decisions {
            // BEFORE IT IS COUNTED AS SEEN — patch 257's rule, fourth store.
            if DataCorrections.isIgnored(id: decision.activityId) {
                report.correctionsIgnored += 1
                continue
            }

            report.correctionsSeen += 1

            guard let activityID = try canonicalActivity(
                d, externalID: decision.activityId) else {
                report.correctionsUnresolved += 1
                continue
            }
            keep.insert(activityID)

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM correction
                WHERE accountID = ? AND subjectKind = 'activity'
                  AND subjectID = ? AND field = ?
                """, arguments: [accountID, activityID, commuteField])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE correction
                            SET value = ?, reason = ?, authoredUTC = ?
                            WHERE id = ?
                            """, arguments: [String(decision.isCommute),
                                             Self.commuteReason,
                                             iso8601(decision.decided), id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO correction
                              (id, accountID, subjectKind, subjectID, field,
                               value, reason, authoredUTC)
                            VALUES (?, ?, 'activity', ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             activityID, commuteField,
                                             String(decision.isCommute),
                                             Self.commuteReason,
                                             iso8601(decision.decided)])
                    }
                    return .commit
                }
                if existing != nil { report.correctionsUpdated += 1 }
                else { report.correctionsImported += 1 }
            } catch {
                report.refusals.append(
                    .init(externalID: "commute \(decision.activityId)",
                          reason: String(describing: error)))
            }
        }

        guard reconcile.isRunning else { return }

        // AND ONLY WHEN EVERY DECISION WAS ACCOUNTED FOR. `keep` is built from
        // the ids that RESOLVED, so a decision the database could not place —
        // an excluded recording, or an activity that is not here — cannot
        // protect its own row. Pruning while any is outstanding would delete a
        // correction the athlete still holds an opinion about.
        //
        // Both counters are zero on a healthy device, so this is a guard
        // against a state rather than a common path.
        guard report.correctionsUnresolved == 0,
              report.correctionsIgnored == 0 else { return }

        report.correctionsRemoved = try pruneCommutes(d, keeping: keep)
    }

    /// See the header: provenance, not an argument, and true of every row.
    nonisolated static let commuteReason =
        "The athlete's own answer, given on the ride."

    /// Removes `isCommute` corrections whose ride the store no longer has an
    /// opinion about. Scoped to this one field — a `DataCorrections` row in
    /// this table is not ours to delete.
    private nonisolated static func pruneCommutes(_ d: Database,
                                                  keeping keep: Set<String>) throws -> Int {
        let rows = try Row.fetchAll(d, sql: """
            SELECT id, subjectID FROM correction
            WHERE accountID = ? AND subjectKind = 'activity' AND field = ?
            """, arguments: [accountID, commuteField])

        var removed = 0
        for row in rows {
            let subject: String = row["subjectID"]
            guard !keep.contains(subject) else { continue }
            let id: String = row["id"]
            try d.execute(sql: "DELETE FROM correction WHERE id = ?",
                          arguments: [id])
            removed += 1
        }
        return removed
    }
}
