//
//  MigrationLedger.swift
//  Sub4
//
//  Every import, and how it ended — step 3.3, patch 255, migration contract
//  item 11, ADR-0003 §12.15.
//
//  THE SENTENCE THIS FILE EXISTS FOR
//  --------------------------------
//  "Record `pending`, `running`, `verified`, `activated` or `failed` in
//  `migration_run`; rerunning after termination must be safe."
//
//  Nothing in this app has ever been able to be `verified` or `activated`,
//  because no such state existed. The import ran, produced a report on a screen,
//  and left nothing behind. A second run could not tell whether the first had
//  finished, failed halfway, or never happened — and D7 cannot switch reads to
//  the database on the strength of a number somebody remembers seeing.
//
//  WHAT `pending` MEANS HERE, BECAUSE THE WORD IS AMBIGUOUS
//  -------------------------------------------------------
//  It means PENDING VERIFICATION, not "not yet started". A run is created
//  `running` and never sits in a queue, so "not yet started" is a state this
//  app has no use for.
//
//  So the ladder is: `running` while the write is open, `pending` when the
//  write committed and nothing has checked it, `verified` when the semantic
//  verifier agrees, `activated` when reads are switched to the database, and
//  `failed` when the write threw.
//
//  Today every successful run stops at `pending`, and that is the honest
//  answer: the verifier is the next patch. A run marked `verified` by an
//  importer that verified nothing would be exactly the defect this project has
//  found five times — a control reporting work it did not do.
//
//  THE LEDGER WRITE CANNOT BE INSIDE THE TRANSACTION IT RECORDS
//  -----------------------------------------------------------
//  `Sub4Import.run` does its whole import in one `db.queue.write`. A `failed`
//  row written inside that block would be rolled back by the very throw it was
//  recording, and the ledger would show `running` forever — the exact state the
//  acceptance criterion forbids.
//
//  So there are three transactions, not one: open, the import, close. The cost
//  is that a process killed between them leaves a `running` row, which is
//  correct and is what `stale` is for — an interrupted run is a fact, and the
//  alternative is a ledger that quietly forgets the crash.
//

import Foundation
import GRDB

/// The five states of an import. Frozen in the migration body as a CHECK, and
/// held to this enum by `theStateVocabularyAgrees`.
nonisolated enum MigrationRunState: String, CaseIterable, Codable {
    /// The write is open. A row left here is an interrupted run.
    case running
    /// Committed, and nothing has checked it. Where every successful run stops
    /// until the semantic verifier exists.
    case pending
    /// The verifier compared the database against the stores and agreed.
    case verified
    /// Reads are served from the database. D7.
    case activated
    /// The write threw. `note` carries what it said.
    case failed

    var label: String {
        switch self {
        case .running:   "Running"
        case .pending:   "Imported, not verified"
        case .verified:  "Verified"
        case .activated: "Active"
        case .failed:    "Failed"
        }
    }

    /// Whether the run is over. Drives the schema's own invariant: a finished
    /// run has a finish time and an unfinished one does not.
    var isFinished: Bool {
        switch self {
        case .running:                              false
        case .pending, .verified, .activated, .failed: true
        }
    }
}

nonisolated struct MigrationRun: Identifiable, Hashable {
    let id: String
    let startedUTC: String
    let finishedUTC: String?
    let state: MigrationRunState
    /// The protected snapshot taken before this run, if there was one. The link
    /// between contract items 3 and 11: a run whose inputs were not copied
    /// first is a run with nothing to go back to.
    let snapshotID: String?
    let appVersion: String
    let note: String?

    /// One line for a diagnostic. No dates from the athlete's history — the
    /// only timestamps here are when the import ran.
    var line: String {
        var parts = [startedUTC, state.rawValue, "patch \(appVersion)"]
        if let snapshotID { parts.append("snapshot \(snapshotID)") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum MigrationLedger {

    /// Opens a run and returns its id. Its own transaction — see the header.
    @discardableResult
    static func open(_ db: Sub4Database,
                     appVersion: String,
                     snapshotID: String?,
                     now: String) throws -> String {
        let id = UUID().uuidString
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, state, snapshotID, appVersion, note)
                VALUES (?, ?, NULL, ?, ?, ?, NULL)
                """, arguments: [id, now, MigrationRunState.running.rawValue,
                                 snapshotID, appVersion])
        }
        return id
    }

    /// Closes a run. Its own transaction, so a rollback of the import cannot
    /// take the record of the failure with it.
    static func finish(_ db: Sub4Database,
                       id: String,
                       state: MigrationRunState,
                       note: String?,
                       now: String) throws {
        precondition(state.isFinished, "finish() called with \(state.rawValue)")
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE migration_run
                   SET finishedUTC = ?, state = ?, note = ?
                 WHERE id = ?
                """, arguments: [now, state.rawValue, note, id])
        }
    }

    // MARK: Reading

    static func latest(_ db: Sub4Database) throws -> MigrationRun? {
        try all(db, limit: 1).first
    }

    /// Newest first. `startedUTC` is ISO-8601, so it sorts chronologically as
    /// text — the same property the snapshot stamp relies on.
    static func all(_ db: Sub4Database, limit: Int = 20) throws -> [MigrationRun] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, startedUTC, finishedUTC, state, snapshotID, appVersion, note
                  FROM migration_run
                 ORDER BY startedUTC DESC, id DESC
                 LIMIT ?
                """, arguments: [limit])
            .compactMap(row)
        }
    }

    /// Runs left `running` — a process that died mid-import.
    ///
    /// NOT REPAIRED AUTOMATICALLY. Rewriting them to `failed` on the next
    /// launch would be tidy and would destroy the only evidence that the app
    /// was killed while writing. They are counted and shown; what to do about
    /// one is a decision, and the verifier is what will make it.
    static func stale(_ db: Sub4Database) throws -> [MigrationRun] {
        try all(db, limit: 100).filter { $0.state == .running }
    }

    private static func row(_ r: Row) -> MigrationRun? {
        guard let id = r["id"] as String?,
              let started = r["startedUTC"] as String?,
              let raw = r["state"] as String?,
              let state = MigrationRunState(rawValue: raw),
              let version = r["appVersion"] as String? else { return nil }
        return MigrationRun(id: id,
                            startedUTC: started,
                            finishedUTC: r["finishedUTC"] as String?,
                            state: state,
                            snapshotID: r["snapshotID"] as String?,
                            appVersion: version,
                            note: r["note"] as String?)
    }
}
