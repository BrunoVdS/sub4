//
//  Sub4Launch.swift
//  Sub4
//
//  Who owns launch — patch 215, plan step 3.3.1.
//
//  THE PROBLEM THIS EXISTS TO SOLVE
//  -------------------------------
//  Every disk-backed store in this app loads synchronously inside its own
//  `private init()`, and those inits fire while SwiftUI is initialising
//  `ContentView`'s stored properties — BEFORE `body` is ever called.
//  `StravaAuth` reads the Keychain and `ActivityStore` reads `activities.json`
//  before anything has been drawn. By the time any `.task` runs, every legacy
//  store has already loaded.
//
//  So a migration engine cannot live in a `.task`, and it cannot live in
//  `ContentView`. It has to run before `ContentView` is CONSTRUCTED, which in
//  SwiftUI means: put `ContentView()` inside a branch that is not taken until
//  the migration has finished. `RootView` is that branch. A `ViewBuilder` does
//  not construct the arm it does not take, so `ContentView.init` — and with it
//  every store's `init` — is deferred until `state` leaves `.opening`.
//
//  WHY NOT `Sub4App.init()`
//  ------------------------
//  It runs early enough, and that is its only virtue. It is synchronous and on
//  the main thread, so a migration of any size blocks the first frame; and it
//  has nowhere to put a failure except a crash. A migration that fails is a
//  thing the athlete should be told about, not a thing that kills the app on
//  launch with no explanation.
//
//  FAILING OPEN, AND THE DATE THAT STOPS BEING RIGHT
//  -------------------------------------------------
//  Today NOTHING in the app reads the database — 3.2 built the schema and the
//  health screen, and that is all. Blocking the whole app because an unused
//  database failed to migrate would turn a contained problem into a dead app,
//  which is a worse outcome than the problem.
//
//  `migrationFailureBlocksTheApp` is therefore `false`, and it is a stored
//  constant rather than an implicit choice so that flipping it is a decision
//  somebody makes on purpose. IT MUST BECOME `true` IN 3.3.3, the moment the
//  first store reads its data from the database instead of from JSON: from
//  then on, carrying on after a failed migration means showing the athlete an
//  empty training history, and an empty history that looks like real data is
//  the worst failure this app has available.
//

import Foundation
import Observation

@MainActor
@Observable
final class Sub4Launch {

    static let shared = Sub4Launch()

    enum State: Sendable, Equatable {
        case opening
        case ready
        /// Migration threw. The message is `String(describing:)` rather than
        /// `localizedDescription`, which drops GRDB's SQL and SQLite result
        /// code — the two things worth having.
        case failed(String)
    }

    private(set) var state: State = .opening

    /// The one connection the app uses. Opened here so nothing else opens a
    /// second `DatabaseQueue` against the same file.
    private(set) var database: Sub4Database?

    /// See the header — AND THE HEADER IS NOW OUT OF DATE, corrected here at
    /// 342 rather than left to be believed.
    ///
    /// It says this must become `true` "the moment the first store reads its
    /// data from the database". That describes a design that was considered
    /// and NOT adopted. A3 §2.2 settled the other one on 10 August 2026: every
    /// D7 slice keeps a selectable legacy path, and the flip happens at **B9**,
    /// after all eight slices, together with the first call to
    /// `MigrationLedger.activateVerified`.
    ///
    /// What makes that safe is not this flag. It is `PersistenceMode`, which
    /// decides where reads come from ONCE, from facts about the database, and
    /// can never be reached by a repository returning empty. This flag governs
    /// only what a failed MIGRATION does; that type governs what a failed OPEN
    /// does, and the second is the one D7 turns on.
    nonisolated static let migrationFailureBlocksTheApp = false

    /// WHERE PRODUCTION READS COME FROM THIS LAUNCH — D7 slice B0, patch 342.
    ///
    /// Computed once, in `begin()`, on both the success and the failure branch.
    /// Nothing consumes it yet: B1 is the first slice to act on it, and that
    /// is deliberate — a value nothing reads is a value that can be wrong
    /// without consequence, which is what makes B0 checkable on its own.
    ///
    /// `.legacyAuthoritative` before it is computed rather than an optional,
    /// because every caller from B1 onward wants an answer and "not yet known"
    /// is not one of the four states the app can be in. The window in which it
    /// holds that value is `RootView`'s `preparing` screen, which serves
    /// nothing. §12.90.
    private(set) var persistence: PersistenceMode = .legacyAuthoritative

    /// How many runs this launch found open and closed — patch 338. Zero on
    /// every clean launch, and the number is worth having rather than merely
    /// the act: three of these accumulated unremarked before an off-device read
    /// of the container found them.
    private(set) var interruptedAtLaunch = 0
    /// Non-fatal because the database is still a shadow read source, but never
    /// silent: Settings and the diagnostic paste surface the exact failure.
    private(set) var ledgerRecoveryFailure: String?

    var isFinished: Bool { state != .opening }

    var failureMessage: String? {
        if case .failed(let m) = state { return m }
        return nil
    }

    /// Held while the open is in flight, so a second caller waits for the
    /// first rather than starting its own — patch 307.
    ///
    /// `begin()` had exactly one caller until 307, and one caller cannot race
    /// itself. `BackgroundRefresh.run()` is the second, and the guard below has
    /// a suspension point after it: two callers could both pass `case .opening`
    /// and both open a `DatabaseQueue` on the same file, which is the one thing
    /// `DatabaseHealthView.load()` is careful not to do.
    ///
    /// Reachable rather than observed. Writing it down as a race that 307
    /// CREATED, not one that has happened.
    private var opening: Task<Void, Never>?

    /// Idempotent: `RootView`'s `.task` can be re-entered when the scene is
    /// rebuilt, and re-migrating on every scene change would be wasted work at
    /// best and a second connection at worst.
    func begin() async {
        // A second caller waits for the first and gets the same database,
        // rather than returning early to find `database` still nil.
        if let opening { return await opening.value }
        guard case .opening = state else { return }

        let work = Task { @MainActor in
            // OFF THE MAIN ACTOR. On an existing install this is a few
            // milliseconds — `DatabaseMigrator` reads `grdb_migrations` and
            // finds nothing to do. On a fresh install it creates thirty-one
            // tables and their indexes. Neither belongs on the thread that
            // draws the first frame, and the second one is measurably not free.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                do { return .opened(try Sub4Database.open()) }
                catch { return .threw(String(describing: error)) }
            }.value

            switch outcome {
            case .opened(let db):
                // PATCH 338 — THE ONE MOMENT `running` IS UNAMBIGUOUS.
                //
                // Every `migration_run` row still open belongs to a process
                // that no longer exists: this launch has not opened one yet,
                // and no previous launch survives. So the rows can be closed as
                // `interrupted` with no timeout, no clock comparison and no
                // guess. Anywhere later in the app this call would close the
                // live run instead — which is why it is here and not in a
                // maintenance routine somebody could move. §12.86.
                //
                do {
                    self.interruptedAtLaunch =
                        try MigrationLedger.closeInterrupted(db).count
                    self.ledgerRecoveryFailure = nil
                } catch {
                    // The database is still a shadow source before D7, so this
                    // bookkeeping failure does not block training screens. It
                    // is retained as an explicit health finding rather than
                    // disappearing behind `try?`.
                    self.interruptedAtLaunch = 0
                    self.ledgerRecoveryFailure = String(describing: error)
                }
                self.database = db
                self.state = .ready
                // PATCH 342. AFTER the ledger recovery above, because an
                // activated run is a ledger fact and the ledger has just been
                // touched. Read through `census`, which 340 gave the
                // activated-or-verified query — §12.43, do not write a second
                // one.
                let activated = (try? MigrationLedger.census(db))?
                    .newestVerified?.state == .activated
                self.persistence = PersistenceAuthority.derive(
                    activatedRun: activated,
                    databaseOpened: true,
                    everActivated: PersistenceAuthority.everActivated())
            case .threw(let message):
                self.state = .failed(message)
                // THE DATABASE DID NOT OPEN, so the ledger cannot be asked
                // whether this install was activated. The mirror is the only
                // thing that can say so, and it may only withhold — it turns
                // this into `.blocked` and can never produce
                // `.databaseAuthoritative`. See `PersistenceMode`'s header.
                self.persistence = PersistenceAuthority.derive(
                    activatedRun: false,
                    databaseOpened: false,
                    everActivated: PersistenceAuthority.everActivated())
            }
        }
        // Assigned with no suspension point between, so on the main actor this
        // and the line above are one step and a second caller cannot slip in.
        opening = work
        await work.value
    }


    private enum Outcome: Sendable {
        case opened(Sub4Database)
        case threw(String)
    }
}
