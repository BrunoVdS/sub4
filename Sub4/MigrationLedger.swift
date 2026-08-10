//
//  MigrationLedger.swift
//  Sub4
//
//  Every import, and how it ended — step 3.3, patch 255, migration contract
//  item 11, ADR-0003 §12.15 and §12.55.
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
//  IT IS NO LONGER "ONE ROW PER IMPORT" — patch 311
//  ------------------------------------------------
//  `Sub4Migrations+MigrationRun.swift` says, in its own comment, "small forever
//  — one row per import". That was true for two hundred patches and stopped
//  being true the day D6b landed: a background/foreground cycle writes TWO rows
//  on its own, and iOS adds more. Forty-five rows in three days, and the number
//  only grows.
//
//  So this file now does three things it did not do at 255: it records WHAT
//  STARTED each run, it trims the ones that are only ever counted, and `stale`
//  asks the whole table rather than the first page of it. Each is below with its
//  own argument.
//

import Foundation
import GRDB

/// The six states of an import. Frozen in migration bodies as CHECKs, and
/// held to this enum by `migrationRunStatesMatch`.
nonisolated enum MigrationRunState: String, CaseIterable, Codable, Sendable {
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
    /// The previous process died with the write open. A later launch records
    /// when it recovered the row; the unknowable finish time stays nil.
    case interrupted

    var label: String {
        switch self {
        case .running:     "Running"
        case .pending:     "Imported, not verified"
        case .verified:    "Verified"
        case .activated:   "Active"
        case .failed:      "Failed"
        case .interrupted: "Interrupted"
        }
    }

    /// Whether import execution is no longer open. Pending and verified rows
    /// may still advance through later gate states; an interrupted run is over
    /// even though its exact finish instant is unknowable.
    var isFinished: Bool {
        switch self {
        case .running: false
        case .pending, .verified, .activated, .failed, .interrupted: true
        }
    }

    var recordsFinishTime: Bool {
        switch self {
        case .pending, .verified, .activated, .failed: true
        case .running, .interrupted: false
        }
    }
}

/// WHAT STARTED A RUN — patch 311, groundwork §5.4.
///
/// Frozen in `Sub4Migrations+RunTrigger` as a CHECK and held to this enum by
/// `migrationRunTriggersMatch`. Adding a case here is a new migration, not an
/// edit — see that file's header.
///
/// FOUR VALUES AND NOT FIVE. The Database screen's Import button, its Write
/// through now button, and Settings' Run the task now button are all `manual`,
/// because the question this column answers is *did a person cause this*, and
/// all three have the same answer. Which button it was lives in the failure
/// journal's `reason`, which is a sentence rather than a value a query groups
/// by — §12.39.2, and §12.48's "a timestamp that is a name is not a time"
/// pointing the other way.
nonisolated enum MigrationRunTrigger: String, CaseIterable, Codable, Sendable {
    /// A person pressed something.
    case manual
    /// The app went to the background. Best-effort, under a background-task
    /// assertion — §12.49.
    case backgrounded
    /// The app came back. The catch-up that makes a missed backgrounding run
    /// late rather than lost — §12.50.
    case foregrounded
    /// iOS woke the app for a `BGAppRefreshTask` — §12.51.
    case backgroundRefresh

    /// For a screen. Reads after "Started by".
    var label: String {
        switch self {
        case .manual:            "you"
        case .backgrounded:      "leaving the app"
        case .foregrounded:      "coming back to the app"
        case .backgroundRefresh: "a background refresh"
        }
    }

    /// What a NULL prints as. The 45 rows written before this patch have no
    /// answer, and a guessed one would be indistinguishable from a recorded
    /// one — §12.15.
    static let unrecordedLabel = "not recorded (before patch 311)"
}

nonisolated struct MigrationRun: Identifiable, Hashable, Sendable {
    let sequence: Int64
    let id: String
    let startedUTC: String
    let finishedUTC: String?
    let recoveredUTC: String?
    let state: MigrationRunState
    /// The protected snapshot taken before this run, if there was one. The link
    /// between contract items 3 and 11: a run whose inputs were not copied
    /// first is a run with nothing to go back to.
    let snapshotID: String?
    let appVersion: String
    /// Patch 311. Nil for every row written before it, and for a row written by
    /// a caller that had no answer — see `MigrationRunTrigger.unrecordedLabel`.
    let triggeredBy: MigrationRunTrigger?
    let note: String?

    /// Never nil, so the screen has a row it can always draw. §12.54.2: a field
    /// that vanishes when it has nothing to say is indistinguishable from a
    /// field nobody wired in.
    var triggerLabel: String {
        triggeredBy?.label ?? MigrationRunTrigger.unrecordedLabel
    }

    /// One line for a diagnostic. No dates from the athlete's history — the
    /// only timestamps here are when the import ran.
    ///
    /// The trigger goes in as its RAW VALUE rather than its label, because a
    /// paste is read by a query as often as by a person and the raw value is
    /// the frozen vocabulary.
    var line: String {
        var parts = [startedUTC, state.rawValue,
                     triggeredBy?.rawValue ?? "trigger not recorded",
                     "patch \(appVersion)"]
        if let snapshotID { parts.append("snapshot \(snapshotID)") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// THE WHOLE TABLE, COUNTED — patch 311.
///
/// `migration_run: 45` in the table counts is what made this patch necessary,
/// and a number with no breakdown is the thing that made it invisible for three
/// days. Every trigger is named every time, including at zero — §12.54.2, and
/// `total` is the denominator that makes each of them evidence (§12.54.3).
nonisolated struct LedgerCensus: Equatable, Sendable {
    let total: Int
    /// Rows still open in this launch.
    let openNow: Int
    /// Prior-process runs recovered into the terminal interrupted state.
    let interrupted: Int
    /// Rows whose trigger is NULL.
    let unrecorded: Int
    /// Keyed by raw value, so an unknown string in the column would show up as
    /// a key nobody prints and a `total` that does not add up — which is the
    /// visible failure, and better than a silent bucket.
    let byTrigger: [String: Int]

    var diagnosticLines: [String] {
        var lines = ["Import ledger: \(total) rows"]
        for t in MigrationRunTrigger.allCases {
            lines.append("  \(t.rawValue): \(byTrigger[t.rawValue] ?? 0)")
        }
        lines.append("  trigger not recorded: \(unrecorded)")
        lines.append("  open right now: \(openNow)")
        lines.append("  interrupted, recovered at a later launch: \(interrupted)")
        lines.append("  retention: newest \(MigrationLedger.keepAutomaticRuns) "
                     + "successful automatic runs and newest "
                     + "\(MigrationLedger.keepAutomaticInterruptedRuns) automatic "
                     + "interruptions; manual and unclassified evidence is kept")
        return lines
    }
}

nonisolated enum MigrationLedger {

    // MARK: Retention

    /// How many successful AUTOMATIC runs the ledger keeps.
    ///
    /// NOT A SIZE LIMIT — a shape. The question these rows answer is "what has
    /// this app been doing lately", and at two per app switch, 200 is a few
    /// weeks of them. 45 rows appeared in three days; nothing was going to stop
    /// that on its own.
    static let keepAutomaticRuns = 200
    static let keepAutomaticInterruptedRuns = 20

    /// The triggers a SUCCESSFUL run may be pruned for.
    ///
    /// FAILS TOWARDS KEEPING, and that is the whole design of this list. A
    /// trigger added later and forgotten here makes the table grow, which shows
    /// up in the census above. One added here by mistake deletes evidence,
    /// which shows up nowhere. Between a leak and a shredder, pick the leak.
    ///
    /// This is deliberately NOT `allCases.filter { $0 != .manual }`. That
    /// expression fails towards deleting. `prunableIsEveryAutomaticTrigger`
    /// asserts the two agree TODAY, so adding a case is a decision somebody has
    /// to make rather than one that gets made for them.
    static let prunableTriggers: [MigrationRunTrigger] =
        [.backgrounded, .foregrounded, .backgroundRefresh]

    /// WHAT IS NEVER PRUNED, stated as a list because it is the important half:
    ///
    ///   · `manual`    — the athlete did it on purpose
    ///   · `failed`    — the reason anybody reads this table
    ///   · `running`   — an interrupted run is evidence the app was killed
    ///   · `verified` / `activated` — D7 decides on the strength of these
    ///   · a NULL trigger — the 45 rows from before patch 311 cannot be
    ///     identified as automatic, so they are not treated as if they were
    ///
    /// The last one means those 45 stay forever. That is a bounded, one-time
    /// cost and the honest reading of a column that says "not recorded".
    @discardableResult
    static func prune(_ db: Sub4Database,
                      keeping: Int = keepAutomaticRuns,
                      keepingInterrupted: Int = keepAutomaticInterruptedRuns) throws -> Int {
        try db.queue.write {
            try pruneInside($0, keeping: keeping,
                            keepingInterrupted: keepingInterrupted)
        }
    }

    /// The same delete, for a caller that already holds a write. `open` uses
    /// this so a row is never inserted without the trim, and so the ledger's
    /// housekeeping does not cost a second transaction on every import.
    @discardableResult
    fileprivate static func pruneInside(_ d: Database,
                                        keeping: Int,
                                        keepingInterrupted: Int) throws -> Int {
        let successful = try doomedIDs(d, state: .pending, keeping: keeping)
        let interrupted = try doomedIDs(d, state: .interrupted,
                                        keeping: keepingInterrupted)
        let doomed = successful + interrupted
        guard !doomed.isEmpty else { return 0 }
        // Chunked because SQLite's bound-variable limit is finite and this list
        // is not. In steady state it is one id; on the first run after a long
        // gap it could be hundreds.
        for chunk in stride(from: 0, to: doomed.count, by: 400).map({
            Array(doomed[$0 ..< min($0 + 400, doomed.count)])
        }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            try d.execute(sql: "DELETE FROM migration_run WHERE id IN (\(marks))",
                          arguments: StatementArguments(chunk))
        }
        return doomed.count
    }

    /// Everything past the newest `keeping` successful automatic runs.
    ///
    /// `LIMIT -1 OFFSET n` is SQLite for "all rows after the first n", which is
    /// the query this needs stated once rather than a count and a subtraction.
    private static func doomedIDs(_ d: Database,
                                  state: MigrationRunState,
                                  keeping: Int) throws -> [String] {
        let raws = prunableTriggers.map(\.rawValue)
        guard !raws.isEmpty else { return [] }
        let marks = raws.map { _ in "?" }.joined(separator: ", ")
        var args: [DatabaseValue] = [state.rawValue.databaseValue]
        args += raws.map { $0.databaseValue }
        args.append(max(0, keeping).databaseValue)
        return try String.fetchAll(d, sql: """
            SELECT id FROM migration_run
             WHERE state = ?
               AND triggeredBy IN (\(marks))
             ORDER BY sequence DESC
             LIMIT -1 OFFSET ?
            """, arguments: StatementArguments(args))
    }

    // MARK: Writing

    /// Opens a run and returns its id. Its own transaction — see the header.
    ///
    /// THE PRUNE RIDES ALONG, in the same transaction. Two reasons. A row is
    /// never inserted without the trim, so the table cannot grow past its shape
    /// even if a later import throws; and a prune that failed would fail the
    /// import loudly rather than being swallowed, which is what a `DELETE`
    /// refusing on a table we just inserted into deserves.
    ///
    /// The row being opened is `running`, so it is never in its own doomed set.
    @discardableResult
    static func open(_ db: Sub4Database,
                     appVersion: String,
                     snapshotID: String?,
                     trigger: MigrationRunTrigger? = nil,
                     now: String) throws -> String {
        let id = UUID().uuidString
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, state, snapshotID, appVersion,
                   triggeredBy, note)
                VALUES (?, ?, NULL, ?, ?, ?, ?, NULL)
                """, arguments: [id, now, MigrationRunState.running.rawValue,
                                 snapshotID, appVersion, trigger?.rawValue])
            try pruneInside(d, keeping: keepAutomaticRuns,
                            keepingInterrupted: keepAutomaticInterruptedRuns)
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
        // Import execution has exactly two terminal outcomes. Verification is
        // deliberately a separate pending -> verified transition below; if
        // this accepted `.verified`, a caller could bypass the semantic gate.
        guard state == .pending || state == .failed else {
            throw MigrationLedgerError.invalidTransition(id: id, target: state)
        }
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE migration_run
                   SET finishedUTC = ?, state = ?, note = ?
                 WHERE id = ? AND state = ?
                """, arguments: [now, state.rawValue, note, id,
                                 MigrationRunState.running.rawValue])
            let changed = try Int.fetchOne(d, sql: "SELECT changes()") ?? 0
            guard changed == 1 else {
                throw MigrationLedgerError.invalidTransition(id: id, target: state)
            }
        }
    }

    /// A verifier may bless only the newest run, while it is still a completed
    /// pending import. The conditional update also closes the race with a newer
    /// write-through. `finishedUTC` remains the import finish time.
    @discardableResult
    static func verifyPending(_ db: Sub4Database,
                              id: String,
                              note: String?) throws -> Bool {
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE migration_run
                   SET state = ?, note = ?
                 WHERE id = ?
                   AND state = ?
                   AND finishedUTC IS NOT NULL
                   AND sequence = (SELECT MAX(sequence) FROM migration_run)
                """, arguments: [MigrationRunState.verified.rawValue, note, id,
                                 MigrationRunState.pending.rawValue])
            return (try Int.fetchOne(d, sql: "SELECT changes()") ?? 0) == 1
        }
    }

    /// D7's eventual activation transition. Kept separate from both import
    /// completion and verification so no API can jump over a rung.
    @discardableResult
    static func activateVerified(_ db: Sub4Database,
                                 id: String,
                                 note: String? = nil) throws -> Bool {
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE migration_run
                   SET state = ?, note = COALESCE(?, note)
                 WHERE id = ?
                   AND state = ?
                   AND finishedUTC IS NOT NULL
                   AND sequence = (SELECT MAX(sequence) FROM migration_run)
                """, arguments: [MigrationRunState.activated.rawValue, note, id,
                                 MigrationRunState.verified.rawValue])
            return (try Int.fetchOne(d, sql: "SELECT changes()") ?? 0) == 1
        }
    }

    // MARK: Reading

    static func latest(_ db: Sub4Database) throws -> MigrationRun? {
        try all(db, limit: 1).first
    }

    /// Newest first by a monotonic insertion sequence. Same-second imports are
    /// common enough that UUID lexical order has already returned the wrong row.
    static func all(_ db: Sub4Database, limit: Int = 20) throws -> [MigrationRun] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT sequence, id, startedUTC, finishedUTC, recoveredUTC,
                       state, snapshotID, appVersion, triggeredBy, note
                  FROM migration_run
                 ORDER BY sequence DESC
                 LIMIT ?
                """, arguments: [limit])
            .compactMap(row)
        }
    }

    /// Called once immediately after database open and before this process can
    /// open a run. At that boundary every existing `running` row belongs to a
    /// dead process, so no timeout or clock heuristic is needed. The actual
    /// finish instant remains unknown; `recoveredUTC` records this later fact.
    @discardableResult
    static func closeInterrupted(_ db: Sub4Database,
                                 now: String = Sub4Import.iso8601(Date()),
                                 note: String = interruptedNote) throws -> [String] {
        try db.queue.write { d in
            let ids = try String.fetchAll(d, sql: """
                SELECT id FROM migration_run
                 WHERE state = ?
                 ORDER BY sequence
                """, arguments: [MigrationRunState.running.rawValue])
            guard !ids.isEmpty else { return [] }
            try d.execute(sql: """
                UPDATE migration_run
                   SET state = ?, recoveredUTC = ?, note = COALESCE(note, ?)
                 WHERE state = ?
                """, arguments: [MigrationRunState.interrupted.rawValue, now, note,
                                 MigrationRunState.running.rawValue])
            try pruneInside(d, keeping: keepAutomaticRuns,
                            keepingInterrupted: keepAutomaticInterruptedRuns)
            return ids
        }
    }

    static let interruptedNote =
        "the app stopped before this run closed — recovered at the next launch"

    static func interruptedCount(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM migration_run WHERE state = ?
                """, arguments: [MigrationRunState.interrupted.rawValue]) ?? 0
        }
    }

    /// Runs currently open. At launch, prior-process rows are first recovered
    /// into `.interrupted`, so a remaining row belongs to this process.
    ///
    /// A DEFECT FIXED HERE — patch 311. This used to read
    /// `all(db, limit: 100).filter { $0.state == .running }`, which asks the
    /// newest hundred rows and then looks for interrupted ones among them. At
    /// 255 that was the whole table. At D6b it is about a day: an interrupted
    /// run from two days ago was already invisible, and the screen would have
    /// said "Interrupted runs: 0" with complete confidence.
    ///
    /// **A count taken from a page is not a count of the table.** It asks the
    /// database the question now, with no limit, which is the only version that
    /// stays true as the table grows.
    static func stale(_ db: Sub4Database) throws -> [MigrationRun] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT sequence, id, startedUTC, finishedUTC, recoveredUTC,
                       state, snapshotID, appVersion, triggeredBy, note
                  FROM migration_run
                 WHERE state = ?
                 ORDER BY sequence DESC
                """, arguments: [MigrationRunState.running.rawValue])
            .compactMap(row)
        }
    }

    /// Every row, tallied by what started it. See `LedgerCensus`.
    static func census(_ db: Sub4Database) throws -> LedgerCensus {
        try db.queue.read { d in
            var byTrigger: [String: Int] = [:]
            var unrecorded = 0
            var total = 0
            for r in try Row.fetchAll(d, sql: """
                SELECT triggeredBy AS t, COUNT(*) AS n
                  FROM migration_run
                 GROUP BY triggeredBy
                """) {
                let n = (r["n"] as Int?) ?? 0
                total += n
                if let raw = r["t"] as String? { byTrigger[raw] = n } else { unrecorded = n }
            }
            func count(_ state: MigrationRunState) throws -> Int {
                try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM migration_run WHERE state = ?
                    """, arguments: [state.rawValue]) ?? 0
            }
            return LedgerCensus(total: total,
                                openNow: try count(.running),
                                interrupted: try count(.interrupted),
                                unrecorded: unrecorded, byTrigger: byTrigger)
        }
    }

    /// A row whose `triggeredBy` holds a string this app does not know reads
    /// back as nil, which prints as "not recorded" — the same as a NULL.
    ///
    /// That collapse is safe only because the migration's CHECK makes an
    /// unknown string impossible to store, and `migrationRunTriggersMatch` is
    /// what keeps the CHECK and the enum saying the same four words. If either
    /// of those is ever removed, this line starts lying.
    private static func row(_ r: Row) -> MigrationRun? {
        guard let sequence = r["sequence"] as Int64?,
              let id = r["id"] as String?,
              let started = r["startedUTC"] as String?,
              let raw = r["state"] as String?,
              let state = MigrationRunState(rawValue: raw),
              let version = r["appVersion"] as String? else { return nil }
        return MigrationRun(sequence: sequence,
                            id: id,
                            startedUTC: started,
                            finishedUTC: r["finishedUTC"] as String?,
                            recoveredUTC: r["recoveredUTC"] as String?,
                            state: state,
                            snapshotID: r["snapshotID"] as String?,
                            appVersion: version,
                            triggeredBy: (r["triggeredBy"] as String?)
                                .flatMap { MigrationRunTrigger(rawValue: $0) },
                            note: r["note"] as String?)
    }
}

nonisolated enum MigrationLedgerError: LocalizedError, Equatable {
    case invalidTransition(id: String, target: MigrationRunState)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let id, let target):
            "Import run \(id) could not move to \(target.rawValue) from its current state."
        }
    }
}
