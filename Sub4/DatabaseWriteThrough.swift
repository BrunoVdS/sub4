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
                                  trigger: trigger)
            }.value
            last = outcome
            runs += 1
            Self.record(outcome, reason: reason)
        } while runAgainWhenDone
    }

    /// THE WORK, WITHOUT THE SINGLETON. Testable against an in-memory database
    /// and a hand-built `AppStores`, which is the only reason it is static.
    nonisolated static func writeThrough(_ db: Sub4Database,
                                         stores: AppStores,
                                         appVersion: String,
                                         snapshotID: String? = nil,
                                         trigger: MigrationRunTrigger) -> Outcome {
        var s = stores
        // See the header. Set HERE rather than at the call site so it cannot be
        // forgotten by a future trigger.
        s.reconcile = .skipped("an automatic write-through does not delete")

        let at = Sub4Import.iso8601(Date())
        do {
            return .wrote(try Sub4Import.run(into: db, stores: s,
                                             appVersion: appVersion,
                                             snapshotID: snapshotID,
                                             trigger: trigger), atUTC: at)
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

    var line: String {
        switch last {
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
}
