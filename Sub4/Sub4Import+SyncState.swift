//
//  Sub4Import+SyncState.swift
//  Sub4
//
//  Where the sync has got to — D5 slice 1, patch 275, ADR-0003 §12.22.
//
//  D5 IS "OUT OF UserDefaults INTO TYPED ROWS", AND THIS IS THE SMALLEST PIECE
//  ---------------------------------------------------------------------------
//  `strava.cursor` and `strava.lastSync` are two preference keys holding the
//  position of a sync that has run 668 activities through it. `sync_state` has
//  had a row waiting for them since the schema was written.
//
//  Nothing moves. The keys stay where they are and stay authoritative — D7 is
//  where the database starts being read. This copies, exactly as every other
//  importer does.
//
//  THE COLUMN IS OPAQUE ON PURPOSE
//  -------------------------------
//  §8's own comment: "Strava's cursor is an epoch and Health's is an anchor; a
//  column typed to one of them would be a transport shape." So the epoch goes
//  in verbatim, as the `Double` the store holds, rendered by Swift's own
//  shortest-round-trip description. Reformatting it to ISO-8601 would be
//  readable and would be this app inventing a representation for a value it
//  does not own — plan step 3.6.3 asks for "an exact source timestamp rather
//  than something reconstructed".
//
//  AND THE APP'S CURSOR STOPPED BEING A CURSOR IN PATCH 249
//  --------------------------------------------------------
//  Worth stating where the value is copied rather than only where it is
//  computed. `ActivityStore.cursor` was the query bound, `after=` filtered by
//  START date, and any activity uploaded late was skipped for ever. 249 made
//  the read unconditional. The variable survives as a HIGH-WATER MARK — the
//  instrument for detecting the very problem it used to cause — so what lands
//  in this column is "the latest start we have seen", not "where the next
//  request begins". The column name predates that change.
//
//  WHAT `lastResult` HOLDS, AND WHAT IT DELIBERATELY DOES NOT
//  ----------------------------------------------------------
//  The error the last sync had to report, and NULL when it had nothing to
//  report. "Whether a sync ran" is `lastSyncUTC`'s job, so writing "ok" here
//  would be inventing a word the app never said in order to fill a column.
//
//  `lastGateNotice` is excluded. §179 separated a deliberate refusal from an
//  outage because a closed gate is not a broken connection — and a closed gate
//  means the sync did NOT run, which `lastSyncUTC` already says by not moving.
//  Folding the two into one column would put the distinction back where 179
//  took it out of.
//

import Foundation
import GRDB

/// One source's position, as the store holds it.
nonisolated struct SyncState: Equatable, Sendable {

    /// Matches a row in `source` — the column is a restricted foreign key, so
    /// an id this app has not seeded is refused rather than stored.
    let sourceID: String

    /// Opaque. See the header: verbatim from the source, never reformatted.
    let cursor: String?

    let lastSync: Date?

    /// What the last sync had to report. NULL means it had nothing to.
    let lastResult: String?
}

extension Sub4Import {

    /// Copies one source's position into `sync_state`.
    ///
    /// Keyed by `(accountID, sourceID)`, which is the table's own unique key —
    /// so a second source at Phase 4A gets its own row rather than fighting
    /// this one for a single global position.
    nonisolated static func importSyncState(
        _ d: Database,
        state: SyncState?,
        now: String,
        into report: inout Report
    ) throws {
        guard let state else { return }
        report.syncStateSeen += 1

        let existing = try String.fetchOne(d, sql: """
            SELECT id FROM sync_state WHERE accountID = ? AND sourceID = ?
            """, arguments: [accountID, state.sourceID])

        let lastSyncUTC = state.lastSync.map { iso8601($0) }

        do {
            try d.inSavepoint {
                if let id = existing {
                    try d.execute(sql: """
                        UPDATE sync_state
                        SET cursor = ?, lastSyncUTC = ?, lastResult = ?
                        WHERE id = ?
                        """, arguments: [state.cursor, lastSyncUTC,
                                         state.lastResult, id])
                } else {
                    try d.execute(sql: """
                        INSERT INTO sync_state
                          (id, accountID, sourceID, cursor, lastSyncUTC, lastResult)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, accountID,
                                         state.sourceID, state.cursor,
                                         lastSyncUTC, state.lastResult])
                }
                return .commit
            }
            if existing != nil { report.syncStateUpdated += 1 }
            else { report.syncStateImported += 1 }
        } catch {
            // The source, because that is what the row is about and it is not
            // the athlete's data.
            report.refusals.append(.init(externalID: "sync \(state.sourceID)",
                                         reason: String(describing: error)))
        }
    }
}
