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

    /// WHAT THIS LAUNCH READ OUT OF THE DATABASE — D7 slice B1, patch 345.
    ///
    /// Assembled on every launch the database opens, whether or not anything is
    /// hydrated from it, so the paste can answer "would B1 work on this device"
    /// before B1 is switched on. Nil only when the open failed.
    private(set) var bootstrap: DatabaseBootstrap?

    /// **WHAT THE BOOTSTRAP COST THIS LAUNCH — patch 394, §12.138.**
    ///
    /// The read below is awaited BEFORE `.ready`, so this is time in front of
    /// first paint. B4 adds the two largest families the app has; the number is
    /// taken rather than estimated, and it is taken on the launch that reads
    /// them and feeds nothing from them — before anything depends on it.
    private(set) var bootstrapTiming = BootstrapTiming()

    /// WHAT THIS LAUNCH DID ABOUT IT, and why — patch 345.
    ///
    /// §12.54.2. A launch that decided not to hydrate and said nothing would
    /// read exactly like one where the hydration was never wired in, which is
    /// the failure this project keeps finding in its own diagnostics. The
    /// default carries the reason rather than an empty string, because a launch
    /// that never reached the decision has still not hydrated.
    private(set) var hydration: HydrationOutcome =
        .notWanted("the launch has not decided yet")

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

                // PATCH 345 — ASSEMBLED ON EVERY LAUNCH, HYDRATED ONLY WHEN
                // THE MODE ASKS FOR IT.
                //
                // Assembling unconditionally costs three repository reads off
                // the main actor — about 1,200 plan rows, the same reads the
                // read-back already does on demand — and buys the one thing
                // that cannot be bought later: the diagnostic paste says on
                // EVERY launch whether the bootstrap would work on this
                // device, before anything depends on it. A bootstrap first
                // exercised on the launch that also starts depending on it is
                // a bootstrap nobody has seen succeed.
                let read = await Task.detached(priority: .userInitiated) {
                    DatabaseBootstrapReader.timed(db)
                }.value
                let boot = read.bootstrap
                self.bootstrap = boot
                self.bootstrapTiming = read.timing
                self.hydration = Self.apply(
                    HydrationPlanner.decide(mode: self.persistence,
                                            bootstrap: boot))

                // `.ready` IS LAST, AND THAT IS A DEFECT FIX — ADR §12.92.6.
                //
                // It used to be set immediately after `database`, three
                // statements before `persistence` was derived. That was
                // correct only by accident: nothing suspended in between, so
                // the main actor ran to the end of this block before the run
                // loop turned and `RootView` could build `ContentView`.
                //
                // The `await` above breaks that accident. With `.ready` where
                // it was, `ContentView` — and with it every store's `init` —
                // would be constructed while the bootstrap was still being
                // read, so the stores would serve their files and be hydrated
                // a frame later. Under `.databaseAuthoritative` after B9 that
                // is the legacy plan shown and then swapped, which
                // `Sub4Launch`'s own header calls the worst failure this app
                // has available.
                //
                // `PlanStore` not being `@Observable` depends on this line
                // being here: it publishes nothing because, by the time a view
                // exists, there is nothing left to publish.
                self.state = .ready
            case .threw(let message):
                // NO BOOTSTRAP AND NO HYDRATION — there is no database to read.
                // `hydration` keeps its `.notWanted` default carrying the mode
                // derived below, which on this branch is `.legacyAuthoritative`
                // or `.blocked`; either way the stores keep their files, which
                // is what they were already doing.
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


    /// Does what `HydrationPlanner` said, and nothing else.
    ///
    /// NO BRANCH OF ITS OWN. Every question — does the mode want it, did the
    /// reads succeed, is there anything stored — is answered in one pure
    /// function that a test can drive through all of its outcomes without a
    /// database. A second place deciding whether to hydrate is a second place
    /// that can disagree, and this file is where that would be hardest to see.
    /// §12.43.
    ///
    /// THE THREE CALLS ARE THE WHOLE OF IT, and they happen in one main-actor
    /// step with no suspension between them: three stores cannot be observed
    /// half-hydrated, because nothing gets to look until this returns and
    /// `state` becomes `.ready`.
    ///
    /// Touching `.shared` here is also what CONSTRUCTS these stores, which is
    /// the right moment — before `ContentView` exists rather than during its
    /// initialisation.
    @MainActor
    private static func apply(_ instruction: HydrationPlanner.Instruction)
        -> HydrationOutcome {
        // PATCH 365 — THE MOVES ARE HANDED IN HERE, ON BOTH PATHS.
        //
        // `PlanStore` deliberately does not read `PlanMoveStore.shared` (see
        // its `init`), so this is where the athlete's corrections meet the plan
        // — and it is the same main-actor step as the hydration above, with no
        // suspension inside it, so nothing gets to observe a plan that has been
        // hydrated and not yet corrected.
        //
        // It also makes `moves.json` a LAUNCH-TIME read like every other
        // authored store. Until 365 the store was a lazy singleton first
        // touched by `AppStores.current()`, which meant an unreadable file did
        // not reach Settings until the first import of the session.
        // PATCH 377 — THE HOISTED READ IS GONE, AND THAT IS THE PATCH.
        //
        // 365 read `PlanMoveStore.shared.all` once here, before the switch,
        // which was right while the store could only ever hold the file's
        // moves. Since 377 the hydrate path REPLACES them first, and a value
        // captured above the switch would have been the file's answer applied
        // over a store that had just been given the database's.
        //
        // Each path now asks at the moment it has an answer. Still one
        // main-actor step with no suspension inside it — 365's requirement,
        // unchanged: nothing observes a plan hydrated and not yet corrected.
        switch instruction {
        case .leaveOnFiles(let outcome):
            // THE PLAN IS THE BUNDLE ON THIS PATH and the moves still apply.
            // A move is the athlete's, not the database's; refusing to honour
            // it because a slice is off would be the app quietly disagreeing
            // with something he wrote.
            PlanStore.shared.applyMoves(PlanMoveStore.shared.all)
            return outcome
        case .hydrate(let plan, let constants, let zones, let ftp,
                      let authored, let decisions, let storedMoves,
                      let storedActivities):
            PlanStore.shared.hydrate(from: plan)
            // BEFORE `applyMoves`, NOT AFTER. The plan is corrected FROM this
            // store, so a store hydrated afterwards would be right and the
            // served plan would be wrong until the next launch — the quietest
            // possible version of this bug. Patch 377.
            if let storedMoves { PlanMoveStore.shared.hydrate(from: storedMoves) }
            PlanStore.shared.applyMoves(PlanMoveStore.shared.all)
            ConstantsStore.shared.hydrate(from: constants)
            AthleteStore.shared.hydrate(zones: zones, ftp: ftp)
            var what = "the plan, its trimmings, the athlete and the constants"
            // PATCH 358. NO LONGER NIL — `hydratedFamilies` lists both families
            // and the device holds rows for both. NIL IS STILL REACHABLE and
            // still means something: a family that read cleanly and holds
            // nothing hands over nil rather than an empty payload, because
            // hydrating from it would blank the file that is the legacy side's
            // only copy. §12.8.1.
            //
            // The sentence grows with WHAT ACTUALLY MOVED rather than with what
            // this code is capable of — which is why it is built here from the
            // payloads instead of being written out at the flip. A paste that
            // reports and a paste that advertises look identical on a device
            // where everything worked.
            if let authored {
                NotesStore.shared.hydrate(from: authored.notes)
                CommuteStore.shared.hydrate(from: authored.commutes)
                what += ", the notes and the commute decisions"
            }
            if let decisions {
                Matcher.shared.hydrate(from: decisions)
                what += ", the match decisions"
            }
            // AFTER the others in the sentence and BEFORE them in the code,
            // because the sentence lists what moved and the code has an
            // ordering constraint. Patch 377.
            if storedMoves != nil { what += ", the plan moves" }
            // PATCH 380 — THE MACHINERY, AND IT IS UNREACHABLE UNTIL 381.
            //
            // `storedActivities` is nil in this build because
            // `hydratedFamilies` does not name `.activities`. The planner asks
            // that question; this file has no branch of its own and gains none
            // here. Written now so that the flip is one line somewhere else,
            // which is what made 346's four failures attributable. §12.103.
            //
            // **TOUCHING `ActivityStore.shared` IS WHAT CONSTRUCTS IT**, and
            // from 381 that happens HERE, before `.ready`, rather than when
            // the first view asks for it. The store reads `activities.json` in
            // its own `init` and this replaces the result: file first, rows
            // over it, inside the one main-actor step with no suspension in
            // it, so nothing observes the intermediate state.
            if let storedActivities {
                ActivityStore.shared.hydrate(from: storedActivities)
                what += ", the activities"
            }
            // **THE DETAILS AND THE TRACES ARE NOT HYDRATED FROM HERE, AND
            // 394 IS WHY — patch 395, §12.139.**
            //
            // 394 put them in the bootstrap and measured it: **3.963 s before
            // `.ready`, of which 3.730 s was 668 recordings over 199,848
            // sample rows.** Taking them out again returns this launch to
            // 0.038 s.
            //
            // The cost was never the read; it was WHERE the read was. Every
            // other store in this ladder is constructed while `ContentView`'s
            // stored properties initialise, so hydrating it here costs the
            // launch nothing it was not already spending. `DetailStore` is the
            // one that is NOT — nothing in this file touches it, and its first
            // caller is `LoadStore.recomputeIfNeeded` inside a `.task`, after
            // the first frame. Hydrating it from here would have CONSTRUCTED
            // it: 1,362 files and 19.1 MB decoded, then thrown away and
            // replaced by rows read a second time.
            //
            // So this store reads for itself, at the moment it is built, and
            // 396 changes which source it reads. `hydratedFamilies` is still
            // the switch; `DetailStore.init` is what now consults it.
            return .hydrated(what)
        }
    }

    private enum Outcome: Sendable {
        case opened(Sub4Database)
        case threw(String)
    }
}
