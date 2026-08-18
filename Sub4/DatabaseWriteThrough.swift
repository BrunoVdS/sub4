//
//  DatabaseWriteThrough.swift
//  Sub4
//
//  D6b step 2 — patch 302, ADR-0003 §12.46.
//
//  NO DIRTY FLAG, AND THAT IS THE DESIGN
//  --------------------------------------
//  `D6B-WRITE-THROUGH-GROUNDWORK.md` §5.1 said to raise a flag in
//  `StoreWriteJournal.attempt`, "which every store already passes through".
//  That was wrong, and reading the source is what said so. There are THREE
//  write paths in this app:
//
//    1. `StoreWriteJournal.attempt`  — six stores: activities.json,
//       constants.json, athlete.json, details/ and streams/, proposals.json,
//       weather.json
//    2. `StoreWrite.encode`, thrown  — the WATCHED writes that roll back:
//       notes.json, commutes.json (§12.17)
//    3. `UserDefaults.set`           — match decisions, rejection receipts,
//       the detail store's skip lists, the sync cursor
//
//  A flag raised in (1) would miss notes and match decisions — the two things
//  in this app that CANNOT be re-fetched from anywhere.
//
//  The deeper point is the failure mode. A dirty flag fails SILENTLY: a store
//  that forgets to mark is a store that never reaches the database, and nothing
//  says so. A whole-world run fails by being LATE: a missed trigger is picked
//  up by the next one, because the run does not depend on knowing what changed.
//
//  And the flag would be buying almost nothing. The import is idempotent and
//  takes 0.325 s on this phone (§12.42.3), because it already skips a trace
//  whose stored `fetchedUTC` matches. **A dirty flag is an optimisation with a
//  silent failure mode, bought against a third of a second.** Don't.
//
//  AUTOMATIC RUNS DO NOT DELETE
//  ----------------------------
//  `AppStores.current()` sets `reconcile` to `.run` when the four gated stores
//  read trustworthily, and reconciliation DELETES rows the app no longer has.
//  Doing that by hand with the report on screen is one thing; doing it
//  unattended, several times a day, is a different blast radius.
//
//  So this overrides it to `.skipped`. The manual button on the Database screen
//  still reconciles, and the difference is stated on screen rather than left to
//  be discovered.
//
//  THE COST OF THAT, OWNED RATHER THAN HIDDEN: a note or a match decision
//  deleted in the app stays in the database until somebody presses Import. The
//  three read-backs would not notice — they report what the store has and the
//  database does not, never the reverse. Surplus rows are D6c's question and
//  this makes them more likely; it is written down in §12.46.3 so the next
//  person to see one knows why.
//

import Foundation
import UIKit

@MainActor
@Observable
final class DatabaseWriteThrough {

    static let shared = DatabaseWriteThrough()

    private init() {}

    /// What the last run did. `.never` is not a failure and not a success —
    /// the sixth instance of §12.15's shape, and the reason this is an enum
    /// rather than an optional report.
    enum Outcome: Sendable, Equatable {
        case never
        case wrote(Sub4Import.Report, atUTC: String)
        /// The launch gate never opened one. Not the same as a write failing.
        case noDatabase
        case failed(String, atUTC: String)
    }

    private(set) var isRunning = false
    private(set) var last: Outcome = .never
    /// Runs since this launch. In memory on purpose: the question it answers is
    /// "is this thing firing at all", which is about now and not about history.
    private(set) var runs = 0

    /// A trigger that arrives mid-run does not queue a second run and is not
    /// dropped — it makes the current run repeat once when it finishes. That is
    /// the whole of the coalescing, and it needs no timer.
    private var runAgainWhenDone = false

    // MARK: Running

    /// The assertion held while a backgrounding run finishes. `.invalid` when
    /// none — see `runOnBackgrounding`.
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    /// Set on the way out, cleared by `runOnReturn`. This is the fact 305's
    /// `previous == .background` was reaching for and could not see — see
    /// `runOnReturn`.
    private var wentToBackground = false

    /// THE TRIGGER, WITH THE TIME TO FINISH — patch 305.

    ///
    /// Synchronous on purpose. 302 called `Task { await run(…) }` straight from
    /// the scene-phase change; that task suspends at its first `await` and has
    /// no claim on the process, so iOS is free to suspend the app before it
    /// ever resumes. It usually completed, because the run is a third of a
    /// second. **Usually is not a mechanism.**
    ///
    /// `beginBackgroundTask` is taken here, BEFORE any suspension point, which
    /// is the only ordering that works: an assertion requested after the first
    /// `await` is an assertion requested from code that may never run.
    ///
    /// The expiration handler is UIKit's promise that it will tell us before it
    /// kills us. If it fires, the run is abandoned mid-flight and leaves a
    /// `running` row the ledger already reports as an interrupted run — which
    /// is the honest outcome and is why that row exists.
    func runOnBackgrounding() {
        // BEFORE the assertion, and before the early return below. A declined
        // assertion is exactly the case the catch-up exists for, so the flag
        // must be set even when nothing is attempted here.
        wentToBackground = true

        guard assertion == .invalid else { return }


        assertion = UIApplication.shared
            .beginBackgroundTask(withName: "sub4.write-through") { [weak self] in
                // Documented to arrive on the main thread. `assumeIsolated`
                // rather than a new `Task`, because scheduling work at
                // expiration is scheduling work that will not run.
                MainActor.assumeIsolated { self?.releaseAssertion() }
            }
        guard assertion != .invalid else {
            // iOS declined. Not an error and not a failure to write — nothing
            // was attempted, and the catch-up on the way back will do it.
            return
        }

        Task {
            await run(reason: "the app went to the background",
                      trigger: .backgrounded)
            releaseAssertion()
        }
    }

    /// The catch-up, on the way back in.
    ///
    /// GUARDED ON HAVING BEEN AWAY, not on the phase transition. `.active`
    /// arrives from `.inactive` every time — after a notification banner, after
    /// Control Centre, after a glance at the app switcher — and running a
    /// write-through on each of those would be several a minute for nothing.
    ///
    /// This is where the guarantee lives. The backgrounding run is best-effort
    /// however good the assertion is; this one happens with the app awake and
    /// unhurried, which is what makes "a missed run is late rather than lost"
    /// a property rather than a hope. §12.50.
    func runOnReturn() {
        guard wentToBackground else { return }
        wentToBackground = false
        Task { await run(reason: "the app came back to the foreground",
                         trigger: .foregrounded) }
    }

    private func releaseAssertion() {

        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    /// TWO PARAMETERS FOR ONE EVENT, ON PURPOSE — patch 311.
    ///
    /// `trigger` is a stored value from a frozen four-word vocabulary that a
    /// query groups by. `reason` is a sentence a person reads in the unsaved-
    /// stores list when a write fails, and it distinguishes things the
    /// vocabulary deliberately does not — the Database screen's button from
    /// Settings' button, both of which are `manual`.
    ///
    /// Collapsing them would mean either the journal losing that detail or the
    /// vocabulary growing a fifth case meaning "manual, but from the other
    /// button". §12.39.2: a field name that carries detail is not a field name.
    /// A STORE JUST SAVED SOMETHING THE ATHLETE WROTE — patch 348, §12.94.
    ///
    /// THE WINDOW THIS CLOSES. Until D7 the legacy files were what the app
    /// read, so a save reaching disk was the end of the story and the database
    /// catching up on backgrounding was housekeeping. From B1 the stores are
    /// hydrated from rows at launch, which means a save that has not reached
    /// the database is a save the next launch discards — with the newer value
    /// sitting in a file nothing reads any more. ADR §12.93.5 named that; this
    /// closes it.
    ///
    /// FIRE AND FORGET, DELIBERATELY. The caller is a `save()` that has just
    /// succeeded and has nothing useful to do with a failure here: the file is
    /// written, the value is in memory, and a database that did not catch up is
    /// caught up by the next trigger. `run` reports its own outcome on the
    /// health screen, which is where a persistent failure becomes visible.
    ///
    /// NO DIRTY FLAG AND NO NARROW WRITE — the header's argument, unchanged. A
    /// whole-world run fails by being LATE; a targeted write fails by being
    /// FORGOTTEN, and a store that forgets is a store nothing says anything
    /// about. The run is a third of a second and coalesces, so a burst of saves
    /// costs one run and at most one repeat.
    func noteAuthoredChange(_ what: String) {
        Task { await run(reason: what, trigger: .authored) }
    }

    func run(reason: String, trigger: MigrationRunTrigger) async {
        if isRunning { runAgainWhenDone = true; return }

        guard let db = Sub4Launch.shared.database else {
            last = .noDatabase
            return
        }

        isRunning = true
        defer { isRunning = false }

        repeat {
            runAgainWhenDone = false
            let stores = AppStores.current()
            let version = AppVersion.patchLabel
            // OFF THE MAIN ACTOR. 0.325 s of SQLite on the thread that draws is
            // 0.325 s of dropped frames, and `AppStores` was made `Sendable` at
            // 301 so this line would be available.
            let outcome = await Task.detached(priority: .utility) {
                // THE SNAPSHOT ID, AND IT IS NOT A FUDGE — patch 303.
                //
                // Contract item 11 asks every run to record which snapshot of
                // its inputs was taken first. An automatic run does not take
                // one, but one EXISTS, and it is genuinely the snapshot that
                // preceded this run — so recording it is accurate rather than
                // convenient.
                //
                // 302 passed nil, and the ledger renders a missing snapshot in
                // RED. Every backgrounding therefore left the newest ledger row
                // flagged for a problem it did not have, which is §12.42.2's
                // shape: a red row that is correct by rule, wrong in meaning,
                // and constant enough to train somebody to ignore the colour.
                //
                // File I/O, so it belongs inside this closure and not on the
                // main actor that called it.
                Self.writeThrough(db, stores: stores, appVersion: version,
                                  snapshotID: LegacySnapshot.latest()?.id,
                                  trigger: trigger, cause: reason)
            }.value
            last = outcome
            runs += 1
            Self.record(outcome, reason: reason)
            // PATCH 360 — AND `LastImport`'s OWN HEADER ASKED FOR IT.
            //
            // It says it answers *"what did the newest import of ANY kind
            // write"*, and that "the two are written from the two call sites of
            // `Sub4Import.run`". It was written from ONE: the button on the
            // health screen, with `trigger: .manual`. Every automatic run — the
            // ones carrying what the athlete just wrote — has been absent from
            // `Last import report:` since 341.
            //
            // That is why the 15 August defect took three device round-trips.
            // The paste showed a manual run's `reconciled: yes` a few lines
            // above a ledger entry for an authored run, and the number the
            // diagnosis needed belonged to neither. §12.15, in the block a
            // paste is read for.
            //
            // `DatabaseWriteThrough.last` still answers its own question — is
            // the automatic trigger firing, and did it fail — and is still fed
            // only from here. The duplication the two headers describe is now
            // real rather than claimed.
            switch outcome {
            case .wrote(let report, let at):
                LastImport.shared.record(report, trigger: trigger, atUTC: at)
            case .failed(let why, let at):
                LastImport.shared.recordFailure(why, atUTC: at)
            case .never, .noDatabase:
                break
            }
        } while runAgainWhenDone
    }

    /// THE WORK, WITHOUT THE SINGLETON. Testable against an in-memory database
    /// and a hand-built `AppStores`, which is the only reason it is static.
    nonisolated static func writeThrough(_ db: Sub4Database,
                                         stores: AppStores,
                                         appVersion: String,
                                         snapshotID: String? = nil,
                                         trigger: MigrationRunTrigger,
                                         // PATCH 406 — THE SENTENCE THIS TYPE
                                         // ALREADY HAD AND THREW AWAY. §12.150:
                                         // `noteAuthoredChange` writes it,
                                         // `run(reason:)` carried it, and
                                         // `record` used it on FAILURE only —
                                         // so every run that worked was
                                         // anonymous in the one table that
                                         // records what touched the database.
                                         cause: String) -> Outcome {
        var s = stores
        // PATCH 360 — THE RULE SPLIT, AND B2 IS WHY.
        //
        // This read `.skipped("an automatic write-through does not delete")`
        // for every trigger, and until 358 that was right: the blob was what
        // the app read, the database was a shadow, and a row the athlete had
        // deleted sat there until somebody ran a reconciled import. The blanket
        // refusal is what stood between a store that transiently failed to
        // decode and thirteen months of deleted notes — 274's argument, still
        // true.
        //
        // B2 INVERTED THE CONSEQUENCE. `Matcher`, `NotesStore` and
        // `CommuteStore` are hydrated FROM the database at launch, so a row
        // this refuses to delete is not stale: it comes back, the store serves
        // it, and the next save persists it over the file. Measured on the
        // device on 15 August — a "Back to automatic" cleared the blob, this
        // run fired, `match_decision` kept the row, and the next launch handed
        // it back.
        //
        // THE SPLIT IS BY WHO CAUSED THE RUN. `.authored` is fired by
        // `NotesStore.save`, `Matcher.persist` and `CommuteStore`: the athlete
        // wrote something and the stores are exactly as they left them. The
        // other three fire at a moment nobody chose, with the stores in
        // whatever state they happen to be in — `resetCache` exists, and 274's
        // guard was earned there. So the run you caused may delete; the runs
        // the system causes may not.
        //
        // **IT STILL PASSES THROUGH `canReconcile`.** This widens WHICH RUNS
        // MAY ASK, not what the answer is: `stores.reconcile` is the gate's own
        // verdict, computed in `AppStores.current()`, and a store that did not
        // read cleanly still deletes nothing. `theGateStillRefuses` is the test.
        //
        // Still set HERE rather than at the call site, for the original reason:
        // a future trigger cannot forget it, and it cannot quietly inherit
        // permission by defaulting.
        s.reconcile = trigger == .authored
            ? stores.reconcile
            : .skipped("an automatic write-through does not delete")

        let at = Sub4Import.iso8601(Date())
        do {
            return .wrote(try Sub4Import.run(into: db, stores: s,
                                             appVersion: appVersion,
                                             snapshotID: snapshotID,
                                             trigger: trigger,
                                             cause: cause), atUTC: at)
        } catch {
            return .failed(String(describing: error), atUTC: at)
        }
    }

    /// A failed write-through goes in the SAME journal as a failed file write,
    /// because it is the same sentence: something the app holds is not on disk.
    /// Settings already shows that list and the tab badge already lights for it.
    ///
    /// No recursion to worry about — nothing here marks anything dirty, because
    /// there is no dirty flag. See the header.
    private static func record(_ outcome: Outcome, reason: String) {
        switch outcome {
        case .wrote:
            _ = StoreWriteJournal.shared.attempt(Sub4Database.fileName) { }
        case .failed(let why, _):
            _ = StoreWriteJournal.shared.attempt(Sub4Database.fileName) {
                throw StoreWriteError(store: Sub4Database.fileName,
                                      stage: .writing,
                                      reason: "\(reason): \(why)")
            }
        case .noDatabase, .never:
            // NOT recorded as an unsaved store. The launch gate having no
            // database is its own condition with its own screen, and filing it
            // here would put a permanent row in a list whose whole job is to be
            // empty.
            break
        }
    }

    // MARK: Reading

    var line: String { Self.line(last) }

    /// **PURE SINCE 391, AND THE BODY IS UNCHANGED.** Two of these four states
    /// — `.noDatabase` and `.failed` — cannot be produced on a device on
    /// demand, so as an instance property this sentence had two arms nothing
    /// could exercise. `PersistenceMode.derive` and `ActivityStore
    /// .lateArrivalLine` are the same move for the same reason.
    nonisolated static func line(_ outcome: Outcome) -> String {
        switch outcome {
        case .never:
            "Not run since this launch."
        case .wrote(let r, let at):
            // LOCAL — patch 304. This used to slice the `Z` off the ISO string
            // and print `10:50:39`, which looked exactly like a wall clock and
            // was two hours out. A time that is obviously wrong gets
            // questioned; a time that is quietly wrong gets believed. §12.48.
            "\(AppTime.local(at) ?? at) — \(r.activitiesSeen) activities, "
            + String(format: "%.3f s", r.seconds)
        case .noDatabase:
            "The database is not open, so nothing was written."
        case .failed(_, let at):
            "\(AppTime.local(at) ?? at) — the write failed."
        }
    }


    /// The failure text in full, for the screen. Separate from `line` because
    /// one belongs in a row and the other in a paragraph.
    var failureDetail: String? {
        if case .failed(let why, _) = last { return why }
        return nil
    }

    var isHealthy: Bool {
        switch last {
        case .never, .wrote: true
        case .noDatabase, .failed: false
        }
    }

    /// **THE ONLY SECTION ON THE DATABASE SCREEN THAT HAS NEVER REACHED THE
    /// PASTE — patch 391, §12.135.**
    ///
    /// The other twenty-two all end up in `diagnosticsText`, most of them
    /// through a `diagnosticLines` of their own. This one had none, so the
    /// mechanism that carries every change made outside an import into the
    /// database could only be read by somebody holding the phone with the
    /// sheet open — which is §12.57's evaporation on the one row that says
    /// whether the database is keeping up at all.
    ///
    /// UNCONDITIONAL, all four lines. "Not run since this launch" and "runs: 0"
    /// are the answer this section exists to give on a launch where nothing has
    /// changed; a block that appeared only after a write could not be told from
    /// a block nobody wired in. §12.54.2.
    ///
    /// `line` carries a LOCAL time for `.wrote`, which is an app event rather
    /// than anything from the training history — the same class of fact as the
    /// import ledger's ISO stamps, which this paste has carried since 255.
    /// §12.7 is untouched.
    var diagnosticLines: [String] {
        Self.diagnosticLines(last, runs: runs, isRunning: isRunning)
    }

    /// **PURE, FOR `ActivityStore.lateArrivalLine`'s AND
    /// `PersistenceMode.derive`'s REASON.** This type is a singleton with a
    /// `private init`, and two of its four states — `.noDatabase` and
    /// `.failed` — are exactly the ones a device cannot be made to produce on
    /// demand. A sentence only a broken phone can exercise is a sentence
    /// nobody checks.
    ///
    /// The instance property above is one line that calls this, so there is one
    /// wording and a test can drive all four states. §12.43.
    nonisolated static func diagnosticLines(_ outcome: Outcome,
                                            runs: Int,
                                            isRunning: Bool) -> [String] {
        let healthy: Bool
        var why: String?
        switch outcome {
        case .never, .wrote:      healthy = true
        case .noDatabase:         healthy = false
        case .failed(let text, _): healthy = false; why = text
        }
        return ["Write-through: \(line(outcome))",
                "  runs this launch: \(runs)",
                "  running right now: \(isRunning ? "yes" : "no")",
                "  healthy: \(healthy ? "yes" : "no")"
                + (why.map { " — \($0)" } ?? "")]
    }
}
