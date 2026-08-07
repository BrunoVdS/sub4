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

    /// See the header. Flip in 3.3.3, when a store first reads from the
    /// database, and change `RootView` to hold at the failure screen.
    nonisolated static let migrationFailureBlocksTheApp = false

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
                self.database = db
                self.state = .ready
            case .threw(let message):
                self.state = .failed(message)
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
