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

    /// The other half of the same key, and it had no name until 361.
    ///
    /// `subjectKind` and `field` TOGETHER are what says "this row is a commute
    /// decision". `field` went through a constant from the day the importer was
    /// written; `subjectKind` was spelled `'activity'` inline in three
    /// statements in this file, which was harmless while this file was the only
    /// reader of them.
    ///
    /// `SemanticVerifier` is now a second reader. A verifier holding its own
    /// copy of a writer's key is §12.43's failure with the worst possible
    /// symptom: it would not throw, it would count zero, and a comparison that
    /// counts zero forever agrees with an empty store forever.
    nonisolated static let commuteSubject = "activity"

    // MARK: The second claimant — patch 363

    /// `subjectKind` for a moved plan session. The other value the CREATE TABLE
    /// has always permitted, and until 363 nothing wrote it.
    nonisolated static let moveSubject = "planSession"

    /// The field a move overrides: `Session.date`. Named for the column it
    /// stands in for, because that is what a reader of the row needs to know.
    nonisolated static let moveField = "date"

    /// See `commuteReason`: provenance, not an argument, and true of every row.
    nonisolated static let moveReason =
        "The athlete recorded this session as done on another day."

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
                WHERE accountID = ? AND subjectKind = ?
                  AND subjectID = ? AND field = ?
                """, arguments: [accountID, commuteSubject, activityID,
                                 commuteField])

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
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             Self.commuteSubject,
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

        guard reconcile.permits(.commutes) else { return }

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

    // MARK: The moves — patch 363

    /// Writes one `correction` row per moved session.
    ///
    /// **THERE IS NOTHING TO RESOLVE, AND THAT SHAPES THE WHOLE FUNCTION.**
    /// `importCorrections` above resolves each decision's Strava id through
    /// `activity_alias` because `correction.subjectID` holds the CANONICAL
    /// activity id — a lookup that can fail, which is what
    /// `correctionsUnresolved` counts and why the commute prune refuses to run
    /// while any is outstanding.
    ///
    /// `PlanMove.sessionUid` is the plan's own identifier and `subjectID` holds
    /// that same identifier verbatim. No lookup, no failure, no held-back
    /// records — so `keep` contains every move the store holds, every held move
    /// protects its own row, and the prune below is safe unconditionally.
    ///
    /// **AN ORPHAN IS COUNTED AND KEPT.** `plan_session.uid` carries the
    /// session's position within its day (§12.96.3), so a plan revision
    /// reissues uids and a move naming an old one names nothing. It is still
    /// the athlete's decision and the database is not entitled to overrule it:
    /// the row is written, it protects itself, and `movesOrphaned` says how
    /// many there are. Groundwork §8.2, turned into a number.
    ///
    /// THE ORPHAN QUERY RUNS ONCE, AND ONLY WHEN THERE IS SOMETHING TO ASK
    /// ABOUT. `SELECT DISTINCT uid FROM plan_session` is the same question
    /// `ReviewRepository` asks of a `proposal_change` — one shape, two callers,
    /// rather than two opinions about which uids exist.
    /// NO `now:` PARAMETER, unlike `importCorrections` beside it. Every
    /// timestamp written here is `move.decided` — the moment the athlete said
    /// so — and a parameter nothing reads is a parameter a future reader has to
    /// check before believing the rest. `importCorrections` carries the same
    /// unused argument and is left alone: changing the signature of a function
    /// this patch does not otherwise touch would put a rename in a diff about
    /// a second claimant.
    nonisolated static func importMoves(
        _ d: Database,
        moves: [PlanMove],
        reconcile: Reconciliation,
        into report: inout Report
    ) throws {
        var keep: Set<String> = []

        let known: Set<String> = moves.isEmpty ? []
            : Set(try String.fetchAll(
                d, sql: "SELECT DISTINCT uid FROM plan_session"))

        for move in moves {
            report.movesSeen += 1
            if !known.contains(move.sessionUid) { report.movesOrphaned += 1 }
            // BEFORE THE WRITE CAN FAIL, and deliberately. A row this importer
            // could not write is still a move the athlete holds, and dropping
            // it out of `keep` would let the prune delete the row that IS there
            // from a previous run.
            keep.insert(move.sessionUid)

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM correction
                WHERE accountID = ? AND subjectKind = ?
                  AND subjectID = ? AND field = ?
                """, arguments: [accountID, moveSubject, move.sessionUid,
                                 moveField])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE correction
                            SET value = ?, reason = ?, authoredUTC = ?
                            WHERE id = ?
                            """, arguments: [move.movedTo, Self.moveReason,
                                             iso8601(move.decided), id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO correction
                              (id, accountID, subjectKind, subjectID, field,
                               value, reason, authoredUTC)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             Self.moveSubject, move.sessionUid,
                                             Self.moveField, move.movedTo,
                                             Self.moveReason,
                                             iso8601(move.decided)])
                    }
                    return .commit
                }
                if existing != nil { report.movesUpdated += 1 }
                else { report.movesImported += 1 }
            } catch {
                report.refusals.append(
                    .init(externalID: "move \(move.sessionUid)",
                          reason: String(describing: error)))
            }
        }

        guard reconcile.permits(.moves) else { return }

        // NO SECOND GUARD, unlike `importCorrections`. Its guard exists because
        // an unresolved decision cannot protect its own row; nothing here can
        // be unresolved. A guard that cannot fail would be §12.69 in the one
        // place this project can least afford it — the line that deletes.
        report.movesRemoved = try pruneMoves(d, keeping: keep)
    }

    /// Removes moved-session corrections the store no longer holds. Scoped to
    /// `subjectKind = 'planSession' AND field = 'date'`, so a future
    /// plan-session correction on any other field is not ours to delete — the
    /// same claim `pruneCommutes` makes one family over.
    private nonisolated static func pruneMoves(_ d: Database,
                                               keeping keep: Set<String>) throws -> Int {
        let rows = try Row.fetchAll(d, sql: """
            SELECT id, subjectID FROM correction
            WHERE accountID = ? AND subjectKind = ? AND field = ?
            """, arguments: [accountID, moveSubject, moveField])

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

    /// Removes `isCommute` corrections whose ride the store no longer has an
    /// opinion about. Scoped to this one field — a `DataCorrections` row in
    /// this table is not ours to delete.
    private nonisolated static func pruneCommutes(_ d: Database,
                                                  keeping keep: Set<String>) throws -> Int {
        let rows = try Row.fetchAll(d, sql: """
            SELECT id, subjectID FROM correction
            WHERE accountID = ? AND subjectKind = ? AND field = ?
            """, arguments: [accountID, commuteSubject, commuteField])

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
