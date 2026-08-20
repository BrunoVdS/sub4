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
    /// A store holding data the athlete created saved it — patch 348, §12.94.
    ///
    /// NOT `manual`, and the distinction is the point. `manual` means somebody
    /// pressed Import and its successful runs are kept for ever on that basis.
    /// This is the app noticing a save and catching the database up on its own,
    /// which is automatic in every sense that matters to retention.
    ///
    /// It exists as its own case rather than folding into `backgrounded`
    /// because the question the census answers — "is the write-through firing
    /// when I write something" — is unanswerable if the two share a number.
    /// §12.15, in the row that says whether a mechanism is working.
    case authored

    /// For a screen. Reads after "Started by".
    var label: String {
        switch self {
        case .manual:            "you"
        case .backgrounded:      "leaving the app"
        case .foregrounded:      "coming back to the app"
        case .backgroundRefresh: "a background refresh"
        case .authored:          "something you wrote"
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

    /// **WHY THIS RUN HAPPENED — patch 406, §12.150.**
    ///
    /// Nil for every row written before the column existed, and for any caller
    /// with no answer. NOT the same field as `note`: verification and
    /// activation own that one, and a second meaning in it would make every
    /// reader ask which kind of row it had before it could read the value.
    ///
    /// A KIND of change — "a session note was saved" — never a note's text or a
    /// session uid. The strings are literals at their call sites and
    /// `causeIsAConstantSentence` keeps them so, which is what makes §12.7 hold
    /// for a column that reaches the paste.
    let cause: String?

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
        // PATCH 406 — WHY, BESIDE WHAT. §12.150: on 18 August the ledger said an
        // authored run had fired four minutes earlier and could not say what
        // caused it, and the answer decided whether patch 405 had worked.
        //
        // CONDITIONAL, unlike `triggerLabel` above it, and the difference is
        // real: every row HAS a trigger, so a missing one is a caller that
        // forgot. Rows written before this column exist in their hundreds, and
        // printing "cause not recorded" against all of them would be noise
        // rather than a finding. The census below says how many are unrecorded.
        if let cause, !cause.isEmpty { parts.append("because \(cause)") }
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
/// The newest run the verifier blessed — patch 340.
///
/// A WHOLE ROW RATHER THAN A NOTE STRING, and that is §12.15's rule applied to
/// the one fact D7's gate is written against. `verifyPending` is allowed to
/// record a nil note, so `String.fetchOne(note)` would return nil for a
/// verified run that simply said nothing — which is indistinguishable from
/// there being no verified run at all. Two opposite facts wearing one
/// appearance is the shape that cost this project patch 339.
nonisolated struct VerifiedRun: Equatable, Sendable {
    /// The monotonic insertion sequence. Carried so the census can say how
    /// much has happened since, and it is not printed.
    let sequence: Int64
    let startedUTC: String
    let appVersion: String
    /// `verified`, or `activated` once D7 has moved it on.
    let state: MigrationRunState
    /// What the verifier recorded, or nil when it recorded nothing. NOT the
    /// same as there being no verified run — see the header.
    let note: String?

    init(sequence: Int64, startedUTC: String, appVersion: String,
         state: MigrationRunState, note: String?) {
        self.sequence = sequence
        self.startedUTC = startedUTC
        self.appVersion = appVersion
        self.state = state
        self.note = note
    }

    init?(row r: Row) {
        guard let sequence = r["sequence"] as Int64?,
              let started = r["startedUTC"] as String?,
              let version = r["appVersion"] as String?,
              let raw = r["state"] as String?,
              let state = MigrationRunState(rawValue: raw) else { return nil }
        self.init(sequence: sequence, startedUTC: started, appVersion: version,
                  state: state, note: r["note"] as String?)
    }

    /// One line for the paste. The timestamp is when an import ran and the
    /// note is the verifier's own count sentence — nothing from the athlete's
    /// history, so §12.7's promise is untouched.
    var line: String {
        var said = "no note recorded"
        if let note, !note.isEmpty { said = note }
        return "\(startedUTC) · \(state.rawValue) · patch \(appVersion) · \(said)"
    }
}

nonisolated struct LedgerCensus: Equatable, Sendable {
    let total: Int
    /// Rows still open in this launch.
    let openNow: Int
    /// Prior-process runs recovered into the terminal interrupted state.
    let interrupted: Int
    /// RUNS THAT REACHED `verified`, INCLUDING ANY LATER ACTIVATED — patch 340,
    /// and this is the sentence D7's entry gate is written against.
    ///
    /// Nothing in this app could state it before 340. The census counted five
    /// things and this was not one of them, so *"a verified run exists over the
    /// current data"* was readable only from the newest row — and every import,
    /// every backgrounding and every return to the app writes a newer one.
    ///
    /// `activated` IS COUNTED HERE, and that is not a conflation.
    /// `activateVerified` refuses every source state but `verified`, so an
    /// activated run is a verified run that went one rung further. Counting
    /// only `verified` would make this read "never" the moment D7 succeeds,
    /// which is §12.54.2 arriving on schedule rather than by surprise.
    let everVerified: Int
    /// The newest of them, or nil when there is none.
    let newestVerified: VerifiedRun?
    /// How many runs have been OPENED since that one, or nil when there is no
    /// verified run.
    ///
    /// FROM THE SEQUENCE, NOT FROM A COUNT OF ROWS. `sequence` is
    /// AUTOINCREMENT and never reuses a value, so this figure survives the
    /// retention prune that deletes the rows themselves. Counting rows would
    /// under-report by exactly the number pruned, on the one line whose job is
    /// to say whether the verification still describes the newest thing the
    /// ledger knows about.
    ///
    /// WHAT IT DOES NOT SAY, and §12.87 is emphatic: zero runs since means the
    /// LEDGER has not moved. It does not mean the stores have not. Import and
    /// Verify each read the stores live, so binding a run to a dataset
    /// fingerprint is still open work and this line is not a substitute for
    /// it — it is the ledger half of the question, said out loud.
    let runsSinceVerified: Int?
    /// Runs that deleted something — patch 369.
    ///
    /// Only rows where `rowsRemoved` is greater than zero. A run that recorded
    /// zero is not one of these and is not missing either; see `notRecorded`.
    let runsThatRemoved: Int

    /// Every row those runs deleted, summed.
    let rowsRemovedEver: Int

    /// **THE LINE THAT MAKES THE OTHER TWO READABLE.** Runs that reached a
    /// terminal state before `rowsRemoved` existed, so their count is unknown
    /// rather than zero.
    ///
    /// Without it, `runs that removed rows: 0` cannot be told from "we started
    /// counting this morning" — §12.54.2 reintroduced one level above the
    /// column it was written to protect.
    let notRecorded: Int

    /// The newest run that deleted anything, with the trigger that did it.
    ///
    /// THE TRIGGER IS THE POINT. 360 permits deletion on `.authored` alone;
    /// this is the only place that claim can be checked after the fact.
    let newestRemoval: Removal?

    /// **THE DURABLE ACCOUNT — patch 415, §12.160.** One entry per family that
    /// has ever lost a row, summed over `migration_run_removal` rather than
    /// over `migration_run.rowsRemoved`.
    ///
    /// The two answer different questions now. The column is per run and its
    /// run is prunable for every row written before 415; the table's runs are
    /// never pruned, so this is the figure that survives a day. Printed
    /// unconditionally, every family, including the zeros — a family that
    /// vanishes at zero cannot be told from one nobody wired in (§12.54.2).
    let removedByFamily: [ReconcileFamily: Int]

    nonisolated struct Removal: Equatable, Sendable {
        let startedUTC: String
        let trigger: String
        let rows: Int
        /// **WHICH FAMILIES, WHICH §5.5 ASKED FOR SINCE 369.** Empty for a run
        /// that predates `migration_run_removal`, and the line says so rather
        /// than printing a removal that appears to have come from nowhere.
        let families: [ReconcileFamily: Int]

        var line: String {
            let base = "\(startedUTC) · \(trigger) · \(rows) row"
                     + (rows == 1 ? "" : "s")
            guard !families.isEmpty else {
                return base + " · family not recorded — the run predates 415"
            }
            let named = families.sorted { $0.key.rawValue < $1.key.rawValue }
                                .map { "\($0.key.label) \($0.value)" }
                                .joined(separator: ", ")
            return base + " · \(named)"
        }
    }

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
        // PATCH 340. UNCONDITIONAL, all three, and the second says "never"
        // rather than being absent — §12.54.2. These three lines are the only
        // durable answer to D7's entry criterion.
        lines.append("  runs ever verified: \(everVerified)")
        lines.append("  newest verified run: "
                     + (newestVerified?.line
                        ?? "never — nothing on this database has been verified"))
        lines.append("  runs opened since it: "
                     + (runsSinceVerified.map { "\($0)" }
                        ?? "not applicable — none verified"))
        // PATCH 369, and all four are unconditional. A delete that leaves no
        // durable trace is 360's rule and §12.20's rule both unauditable; a
        // set of lines that appeared only after the first delete would make
        // "nothing has ever been deleted" indistinguishable from "nobody wired
        // this in".
        lines.append("  runs that removed rows: \(runsThatRemoved)")
        lines.append("  rows removed in all runs: \(rowsRemovedEver)")
        // PATCH 415. UNCONDITIONAL AND EVERY FAMILY, including the zeros: a
        // family that only appears once it has lost something cannot be told
        // from one nobody wired in. §12.54.2.
        lines.append("  removed by family, durably: "
                     + ReconcileFamily.allCases
                         .map { "\($0.label) \(removedByFamily[$0] ?? 0)" }
                         .joined(separator: ", "))
        lines.append("  newest removal: "
                     + (newestRemoval?.line
                        ?? "never — no run has deleted anything"))
        lines.append("  runs that finished before this was recorded: "
                     + "\(notRecorded)")
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
        [.backgrounded, .foregrounded, .backgroundRefresh, .authored]

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
        // **A RUN THAT DELETED SOMETHING IS NEVER PRUNED — patch 415, §12.160.**
        //
        // The device proved why on 20 August: the ledger read `newest removal:
        // never — no run has deleted anything` having read `2` and a dated
        // authored row the day before. Two hundred automatic runs is under two
        // days here, so the prune had aged out the record of the only two
        // removals this database has ever made.
        //
        // `migration_run_removal` cascades from this table, so the child cannot
        // be durable while the parent is disposable. This is where the
        // durability actually comes from.
        //
        // It joins `manual`, `failed`, `running`, `verified` and `activated` on
        // the list above of what is never pruned, and the same sentence
        // settles the trade: **between a leak and a shredder, pick the leak.**
        // Two rows in this database's lifetime against the only evidence that
        // a deletion ever happened.
        return try String.fetchAll(d, sql: """
            SELECT id FROM migration_run
             WHERE state = ?
               AND triggeredBy IN (\(marks))
               AND (rowsRemoved IS NULL OR rowsRemoved = 0)
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
                     // PATCH 406 — WHY THIS RUN HAPPENED, §12.150. `nil` is
                     // "not recorded", which is what 257 existing rows hold and
                     // what the column stores as NULL. NOT §12.95.4's trap: that
                     // is about a default supplying a REAL value nobody typed,
                     // and this default supplies an absence.
                     cause: String? = nil,
                     now: String) throws -> String {
        let id = UUID().uuidString
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, state, snapshotID, appVersion,
                   triggeredBy, note, cause)
                VALUES (?, ?, NULL, ?, ?, ?, ?, NULL, ?)
                """, arguments: [id, now, MigrationRunState.running.rawValue,
                                 snapshotID, appVersion, trigger?.rawValue,
                                 cause])
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

    /// **WHAT THIS RUN DELETED — patch 369.**
    ///
    /// SEPARATE FROM `finish`, and not because it was easier. `finish` has
    /// fourteen call sites in the test target; a new parameter means editing
    /// all of them or giving it a default, and §12.95.4 is explicit that a
    /// default argument is a call site carrying a value nobody wrote — on the
    /// one field whose entire purpose is telling "nobody wrote it" apart from
    /// "zero".
    ///
    /// It is also the better shape: `finish` closes a run; this states a fact
    /// about what the run did.
    ///
    /// CALLED BEFORE `finish`, AND ITS FAILURE PROPAGATES. A run whose count
    /// could not be written becomes a run that failed, rather than one that
    /// reads afterwards as though it predated the column.
    ///
    /// UNCONDITIONAL, including when the answer is zero. §12.54.2: a column
    /// written only when something was deleted cannot be told from one nobody
    /// wired in, and that is the defect this patch exists to end.
    /// **PATCH 415 — THE TOTAL AND ITS DECOMPOSITION, IN ONE TRANSACTION.**
    ///
    /// `rowsRemoved` is 369's column and stays: it answers "how many" for every
    /// run including the ones that predate the table. `migration_run_removal`
    /// answers "from which family", one row per family that lost something.
    ///
    /// **ONE WRITE, NOT TWO.** A total without its families, or families
    /// without their total, is a state no reader should have to interpret —
    /// and a caller that wrote one and threw before the other would produce
    /// exactly that. `finish` runs after this and makes the run terminal, so
    /// a throw here is a failed run, which is the honest outcome (§12.113).
    static func recordRemovals(_ db: Sub4Database,
                               id: String,
                               rows: Int,
                               families: [(family: ReconcileFamily, rows: Int)] = []) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE migration_run SET rowsRemoved = ? WHERE id = ?
                """, arguments: [rows, id])
            let changed = try Int.fetchOne(d, sql: "SELECT changes()") ?? 0
            guard changed == 1 else {
                throw MigrationLedgerError.invalidTransition(id: id,
                                                             target: .running)
            }
            // UPSERT, because `recordRemovals` may be called twice for one run
            // — `RowsRemovedTests` does exactly that — and a second call must
            // correct the record rather than double it.
            for entry in families where entry.rows > 0 {
                try d.execute(sql: """
                    INSERT INTO migration_run_removal (runID, family, rows)
                    VALUES (?, ?, ?)
                    ON CONFLICT(runID, family) DO UPDATE SET rows = excluded.rows
                    """, arguments: [id, entry.family.rawValue, entry.rows])
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
                       state, snapshotID, appVersion, triggeredBy, note,
                       cause
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
                       state, snapshotID, appVersion, triggeredBy, note,
                       cause
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
            // THE ROW, NOT THE NOTE COLUMN. See `VerifiedRun`'s header:
            // a verified run that recorded no note and no verified run at all
            // are opposite facts, and reading the column alone gives both of
            // them nil.
            let newestVerified = try Row.fetchOne(d, sql: """
                SELECT sequence, startedUTC, appVersion, state, note
                  FROM migration_run
                 WHERE state IN (?, ?)
                 ORDER BY sequence DESC
                 LIMIT 1
                """, arguments: [MigrationRunState.verified.rawValue,
                                 MigrationRunState.activated.rawValue])
                .flatMap(VerifiedRun.init(row:))

            // FROM THE SEQUENCE, so the prune cannot flatter it. See
            // `runsSinceVerified`.
            let topSequence = try Int64.fetchOne(d, sql: """
                SELECT MAX(sequence) FROM migration_run
                """) ?? 0
            let runsSince = newestVerified.map { Int(topSequence - $0.sequence) }

            // HOISTED. `try` may not appear to the right of a non-assignment
            // operator, so `try count(.verified) + try count(.activated)` does
            // not compile — the same rule 337 hit with a ternary.
            let verifiedRows = try count(.verified)
            let activatedRows = try count(.activated)

            // PATCH 369. `rowsRemoved IS NULL` on a row that FINISHED is a run
            // that predates the column; on a running or failed row it is
            // simply a run that never got there, which is not the same fact and
            // is not counted.
            let removalRow = try Row.fetchOne(d, sql: """
                SELECT COUNT(*) AS runs, COALESCE(SUM(rowsRemoved), 0) AS rows
                  FROM migration_run
                 WHERE rowsRemoved > 0
                """)
            let notRecorded = try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM migration_run
                 WHERE rowsRemoved IS NULL
                   AND state IN (?, ?, ?)
                """, arguments: [MigrationRunState.pending.rawValue,
                                 MigrationRunState.verified.rawValue,
                                 MigrationRunState.activated.rawValue]) ?? 0
            // PATCH 415. The id comes back too, so the families can be read
            // for exactly this run rather than for the newest row in the
            // removal table — those are the same run today and would stop
            // being so the moment a removal is recorded out of order.
            let newestRemoval = try Row.fetchOne(d, sql: """
                SELECT id, startedUTC, triggeredBy, rowsRemoved
                  FROM migration_run
                 WHERE rowsRemoved > 0
                 ORDER BY sequence DESC
                 LIMIT 1
                """).map { row -> LedgerCensus.Removal in
                    let id = (row["id"] as String?) ?? ""
                    var families: [ReconcileFamily: Int] = [:]
                    let rows = (try? Row.fetchAll(d, sql: """
                        SELECT family, rows FROM migration_run_removal
                         WHERE runID = ?
                        """, arguments: [id])) ?? []
                    for r in rows {
                        guard let name = r["family"] as String?,
                              let f = ReconcileFamily(rawValue: name) else { continue }
                        families[f] = (r["rows"] as Int?) ?? 0
                    }
                    return LedgerCensus.Removal(
                        startedUTC: (row["startedUTC"] as String?) ?? "—",
                        trigger: (row["triggeredBy"] as String?)
                            ?? "trigger not recorded",
                        rows: (row["rowsRemoved"] as Int?) ?? 0,
                        families: families)
                }

            // **THE ACCOUNT THAT SURVIVES — patch 415.** Over the removal
            // table, whose runs are never pruned, rather than over the column,
            // whose runs are.
            var removedByFamily: [ReconcileFamily: Int] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT family, SUM(rows) AS total
                  FROM migration_run_removal
                 GROUP BY family
                """) {
                guard let name = r["family"] as String?,
                      let f = ReconcileFamily(rawValue: name) else { continue }
                removedByFamily[f] = (r["total"] as Int?) ?? 0
            }

            return LedgerCensus(total: total,
                                openNow: try count(.running),
                                interrupted: try count(.interrupted),
                                everVerified: verifiedRows + activatedRows,
                                newestVerified: newestVerified,
                                runsSinceVerified: runsSince,
                                runsThatRemoved:
                                    (removalRow?["runs"] as Int?) ?? 0,
                                rowsRemovedEver:
                                    (removalRow?["rows"] as Int?) ?? 0,
                                notRecorded: notRecorded,
                                newestRemoval: newestRemoval,
                                removedByFamily: removedByFamily,
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
                            note: r["note"] as String?,
                            cause: r["cause"] as String?)
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
