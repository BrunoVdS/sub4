//
//  Sub4Import+WorkQueue.swift
//  Sub4
//
//  What the app has stopped asking for — D5 slice 2, patch 276, §12.23.
//
//  A CORRECTION FIRST: NEITHER SET IS A RETRY QUEUE
//  ------------------------------------------------
//  `detail.failed` and `detail.noStreams` look like a retry queue from their
//  names and from the table they were headed for. Reading `DetailStore` says
//  otherwise, and it changes what this patch is:
//
//    failed      ids Strava answered 404 for — deleted, or private. The
//                declaration says "never retried automatically, otherwise a
//                single dead id burns a queue slot on every launch, forever."
//    noStreams   200 with nothing usable, or 404 on the streams call. A manual
//                entry, or an indoor session with no distance track.
//
//  **Both are terminal verdicts, not work waiting to happen.** A transient
//  failure — a timeout, a 429, a closed gate — is never persisted at all: it
//  returns `.transient` or `.stop` and the id goes back into an in-memory
//  queue that is rebuilt from scratch every launch.
//
//  So there is no attempt count to carry, no backoff to preserve, and nothing
//  in this app to reshape. An earlier note in this session said `DetailStore`
//  would need restructuring first, the way `Matcher` did in §12.19. It does
//  not: the sets already hold everything the columns need, once you accept
//  what the columns mean.
//
//  THE MAPPING, AND WHY `noStreams` IS `done` RATHER THAN `failed`
//  ---------------------------------------------------------------
//    detail.failed      kind "detail", state FAILED — the fetch did not
//                       produce the thing it went for
//    detail.noStreams   kind "stream",  state DONE  — the fetch SUCCEEDED and
//                       the honest answer was "there is nothing here"
//
//  Filing `noStreams` as `failed` would record a fault where the source simply
//  had no trace to give. `done` means the queue is finished with the item,
//  which is precisely true of both, and the distinction between them survives
//  in `state`.
//
//  THE FIRST RUN WROTE TWO ROWS, NOT TWENTY-THREE
//  ----------------------------------------------
//  668 activities carry a detail and 645 carry a trace, so 23 have none — and
//  this file's first version said all 23 would have read as failures. The
//  device said 2.
//
//  The other 21 were never asked. `needsStreams` requires
//  `a.distance >= minStreamDistance`, which is 500 m, and a strength session
//  is 0 m. So there is a THIRD state — not eligible, never attempted, never
//  will be — and `work_queue`'s four frozen states cannot express it: `done`
//  would claim work happened, `pending` would claim work is coming.
//
//  No row is the right answer, and the gap is real: 21 activities have no
//  trace and no verdict, and nothing anywhere says why. That belongs on the
//  health screen next to the count, not in this table.
//
//  `attempts` IS 1, AND 1 IS A FLOOR
//  ---------------------------------
//  An id reaches either set by being asked for at least once — that is the
//  only way in. The app has never counted, so 1 is the minimum known to be
//  true rather than a number invented to fill a column. Said out loud because
//  a reader would otherwise take it for a measurement.
//
//  `createdUTC` IS WHEN THE DATABASE LEARNED, NOT WHEN THE FETCH HAPPENED
//  ----------------------------------------------------------------------
//  Neither set records a time and nothing else in the app remembers. §12.19.3
//  refused to invent a date for a match decision; this is the case where the
//  same trade goes the other way, and §8's own group 9 header is the licence:
//  "Bookkeeping, not history. Everything here can be thrown away and rebuilt
//  by re-syncing, which is the test for whether something belongs in this
//  group." The column says when the ROW was created, which is exactly what
//  this is, and losing the real time costs a re-fetch rather than a fact.
//
//  THIS IMPORTER PRUNES ITS OWN KINDS, WHICH §12.21 REFUSED TO DO FOR NOTES
//  ------------------------------------------------------------------------
//  It owns `detail` and `stream` entirely and receives the complete set every
//  run, so an id no longer present has genuinely been forgotten — by
//  `resetCache`, or by a schema bump clearing the cache. It deletes those rows.
//
//  That is safe here for two reasons that did NOT hold for notes. The source
//  is a `UserDefaults` string array with no decode step, so "empty" cannot
//  mean "unreadable" the way a corrupt `notes.json` can — the failure mode
//  §12.20 was built to catch does not exist on this path. And the whole table
//  is rebuildable by re-syncing, so the worst case is a re-fetch rather than a
//  loss. Neither is true of a note.
//

import Foundation
import GRDB

/// The states migration 2 froze into `work_queue`'s CHECK constraint.
///
/// FROZEN LITERALS, coupled to this enum by test. The migration hard-codes the
/// four rather than reading `quoted(...)` from a constant, and it is history
/// now — so the test asserts the enum still says what the schema was born
/// saying, which is the only direction the coupling can run.
nonisolated enum WorkState: String, CaseIterable, Sendable {
    case pending, running, failed, done
}

/// What kind of work the row is about. Free text in the schema — no CHECK —
/// so this is a Swift convention rather than a contract, and it is an enum so
/// that two importers cannot spell the same kind differently.
nonisolated enum WorkKind: String, CaseIterable, Sendable {
    case detail, stream
}

nonisolated struct WorkItem: Equatable, Sendable {
    let kind: WorkKind
    let subjectID: String
    let state: WorkState
    /// See the header: a floor, not a measurement.
    let attempts: Int
    let lastError: String?
}

extension Sub4Import {

    /// Copies the verdicts, and removes the ones the store has forgotten.
    nonisolated static func importWorkQueue(
        _ d: Database,
        items: [WorkItem],
        now: String,
        into report: inout Report
    ) throws {
        for item in items {
            report.workItemsSeen += 1

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM work_queue WHERE kind = ? AND subjectID = ?
                """, arguments: [item.kind.rawValue, item.subjectID])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        // `createdUTC` IS NOT TOUCHED. It says when this row
                        // was made, and a refresh does not remake it.
                        try d.execute(sql: """
                            UPDATE work_queue
                            SET state = ?, attempts = ?, lastError = ?, updatedUTC = ?
                            WHERE id = ?
                            """, arguments: [item.state.rawValue, item.attempts,
                                             item.lastError, now, id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO work_queue
                              (id, kind, subjectID, state, attempts,
                               notBeforeUTC, lastError, createdUTC, updatedUTC)
                            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)
                            """, arguments: [UUID().uuidString, item.kind.rawValue,
                                             item.subjectID, item.state.rawValue,
                                             item.attempts, item.lastError,
                                             now, now])
                    }
                    return .commit
                }
                if existing != nil { report.workItemsUpdated += 1 }
                else { report.workItemsImported += 1 }
            } catch {
                report.refusals.append(
                    .init(externalID: "\(item.kind.rawValue) \(item.subjectID)",
                          reason: String(describing: error)))
            }
        }

        report.workItemsRemoved = try prune(d, keeping: items)
    }

    /// Removes rows of the kinds this importer owns whose subject is no longer
    /// in the store. See the header for why this is safe here and was not for
    /// notes.
    private nonisolated static func prune(_ d: Database,
                                          keeping items: [WorkItem]) throws -> Int {
        let keep = Set(items.map { "\($0.kind.rawValue)\u{1F}\($0.subjectID)" })
        var removed = 0

        for kind in WorkKind.allCases {
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, subjectID FROM work_queue WHERE kind = ?
                """, arguments: [kind.rawValue])

            for row in rows {
                let subject: String? = row["subjectID"]
                // A NULL subject belongs to no store and is left alone: this
                // importer only claims rows it could have written.
                guard let subject else { continue }
                guard !keep.contains("\(kind.rawValue)\u{1F}\(subject)") else { continue }
                let id: String = row["id"]
                try d.execute(sql: "DELETE FROM work_queue WHERE id = ?",
                              arguments: [id])
                removed += 1
            }
        }
        return removed
    }
}
