//
//  Sub4Import+Authored.swift
//  Sub4
//
//  The two stores holding work you wrote — patch 225, ADR-0003 §12.7.
//
//  THESE FIRST, AND THAT ORDERING IS A DECISION
//  --------------------------------------------
//  Activities can be re-fetched from Strava. Recordings can be re-fetched.
//  Weather can be re-requested. Notes and proposals cannot: `notes.json` is
//  thirteen months of what the athlete thought after each session, and
//  `proposals.json` is every review that has been run, with the evidence pack
//  that produced it. If exactly one store had to survive this rewrite intact it
//  would be these two, so they are imported before anything easier.
//
//  IDEMPOTENCY WITHOUT AN EXTERNAL ID
//  ----------------------------------
//  Activities have `(sourceID, externalID)` to look up. Authored content has no
//  source and no external identifier — it was never anywhere else. So each
//  needs a natural key that is stable across runs:
//
//    notes      `(accountID, planSessionUID)`. `NotesStore` holds them in a
//               dictionary keyed by session uid, so one note per session is
//               guaranteed upstream rather than assumed here.
//
//    reviews    `(accountID, ranUTC)`. `Record.id` encodes the window and a run
//               count, which is stable but is a display string; the instant the
//               review ran is the fact. Two reviews cannot start in the same
//               second, and both sides format the timestamp identically.
//
//  A CHILD ROW IS REPLACED, NOT MERGED
//  -----------------------------------
//  A review's evidence, its proposal, its changes and its watch items are all
//  deleted and rewritten when the review is refreshed. Merging them would need
//  an identity for each change, and a change has none — it is the fourth item
//  in a list. `ON DELETE CASCADE` from `proposal` makes deleting the proposal
//  enough to clear the changes and watch items with it.
//

import Foundation
import GRDB

extension Sub4Import {

    // MARK: Notes

    static func importNotes(_ d: Database,
                            notes: [NotesStore.Note],
                            now: String,
                            into report: inout Report) throws {
        for note in notes {
            report.notesSeen += 1

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM user_note
                WHERE accountID = ? AND planSessionUID = ?
                """, arguments: [accountID, note.sessionUid])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE user_note
                            SET rpe = ?, feel = ?, text = ?, editedUTC = ?
                            WHERE id = ?
                            """, arguments: [note.rpe, note.feel?.rawValue,
                                             note.text, iso8601(note.edited), id])
                    } else {
                        // `planVersionID` and `activityID` stay NULL — §12.7.1.
                        // No plan version exists until the bundled plan is
                        // imported, and resolving a note to the activity that
                        // satisfied its session is a MATCHING decision. The
                        // importer is not the matcher, the same rule that stops
                        // it merging the 21 April duplicate ride.
                        try d.execute(sql: """
                            INSERT INTO user_note
                              (id, accountID, planSessionUID, rpe, feel, text,
                               createdUTC, editedUTC)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             note.sessionUid, note.rpe,
                                             note.feel?.rawValue, note.text,
                                             iso8601(note.created),
                                             iso8601(note.edited)])
                    }
                    return .commit
                }
                if existing != nil { report.notesUpdated += 1 }
                else { report.notesImported += 1 }
            } catch {
                // The session uid, because that is the handle the athlete has
                // on a note — it is what the plan calls the session.
                report.refusals.append(.init(externalID: "note \(note.sessionUid)",
                                             reason: String(describing: error)))
            }
        }
    }

    // MARK: Reviews and proposals

    static func importProposals(_ d: Database,
                                records: [ProposalStore.Record],
                                now: String,
                                into report: inout Report) throws {
        for record in records {
            report.reviewsSeen += 1
            let ranUTC = iso8601(record.ranAt)

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM review WHERE accountID = ? AND ranUTC = ?
                """, arguments: [accountID, ranUTC])

            do {
                try d.inSavepoint {
                    let reviewID = existing ?? UUID().uuidString

                    if existing == nil {
                        try d.execute(sql: """
                            INSERT INTO review
                              (id, accountID, ranUTC, windowStartDayKey,
                               windowEndDayKey, provider, model, appVersion)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [reviewID, accountID, ranUTC,
                                             record.startDay, record.endDay,
                                             reviewProvider, record.model,
                                             record.appVersion])
                    } else {
                        try d.execute(sql: """
                            UPDATE review
                            SET windowStartDayKey = ?, windowEndDayKey = ?,
                                provider = ?, model = ?, appVersion = ?
                            WHERE id = ?
                            """, arguments: [record.startDay, record.endDay,
                                             reviewProvider, record.model,
                                             record.appVersion, reviewID])
                    }

                    // Children are replaced wholesale — see the header. The
                    // proposal's CASCADE takes the changes and watch items with
                    // it, so only two deletes are needed rather than four.
                    try d.execute(sql: "DELETE FROM review_evidence WHERE reviewID = ?",
                                  arguments: [reviewID])
                    try d.execute(sql: "DELETE FROM proposal WHERE reviewID = ?",
                                  arguments: [reviewID])

                    // ONE evidence row, and `wasSent` is true because the blob
                    // in `Record.evidence` IS what was sent to the model — that
                    // is what the field holds. `windowLabel` becomes the title,
                    // which is where §12.7's "not carried" judgement was wrong:
                    // there was a column for it after all, and it says what the
                    // pack covers better than a derived string would.
                    try d.execute(sql: """
                        INSERT INTO review_evidence
                          (id, reviewID, sectionKey, title, body, wasSent)
                        VALUES (?, ?, 'pack', ?, ?, 1)
                        """, arguments: [UUID().uuidString, reviewID,
                                         record.windowLabel, record.evidence])

                    let p = record.proposal
                    let proposalID = UUID().uuidString
                    try d.execute(sql: """
                        INSERT INTO proposal
                          (id, reviewID, verdict, summary, reasoning,
                           confidence, receivedUTC)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [proposalID, reviewID, p.verdict.rawValue,
                                         p.summary, p.reasoning, p.confidence,
                                         ranUTC])

                    for (i, change) in p.changes.enumerated() {
                        try d.execute(sql: """
                            INSERT INTO proposal_change
                              (id, proposalID, ordinal, planSessionUID,
                               what, why, newDetail, isSkip, evidence)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, proposalID, i,
                                             change.sessionUid,
                                             changeSummary(change),
                                             change.reason, change.newDetail,
                                             change.skip, change.evidence])
                    }

                    for (i, watch) in p.watchFor.enumerated() {
                        try d.execute(sql: """
                            INSERT INTO proposal_watch (id, proposalID, ordinal, text)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, proposalID, i, watch])
                    }
                    return .commit
                }
                if existing != nil { report.reviewsUpdated += 1 }
                else { report.reviewsImported += 1 }
            } catch {
                report.refusals.append(.init(externalID: "review \(ranUTC)",
                                             reason: String(describing: error)))
            }
        }
    }

    /// `what` is for reading; `newDetail` is for applying. A skip has no
    /// replacement text, so rendering `newDetail` into a NOT NULL column would
    /// write an empty string into the one field that is supposed to say what
    /// changed.
    static func changeSummary(_ c: ReviewProposal.Change) -> String {
        c.skip ? "Skip this session" : c.newDetail
    }

    /// Written rather than inferred from the model string — §12.7.2. A provider
    /// guessed from "claude-…" would be a fact invented by an import.
    static let reviewProvider = "anthropic"

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
