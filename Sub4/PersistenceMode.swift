//
//  PersistenceMode.swift
//  Sub4
//
//  Where the app reads from, decided once — D7 slice B0, patch 342,
//  ADR-0003 §12.90.
//
//  THE QUESTION THIS TYPE EXISTS TO ANSWER ONCE
//  --------------------------------------------
//  Today "where does this store read from" is not a question: it reads JSON,
//  because that is the only code there is. From B1 it becomes a question with
//  two answers, asked by nine stores. Nine answers that can disagree is
//  §12.43's rule with the highest stakes it has had — eleven applications so
//  far, and the worst of them was five copies of "done of total" disagreeing
//  on two tabs for 230 patches.
//
//  So it is asked once, at launch, and handed out.
//
//  THE RULE THE WHOLE STAGE RESTS ON
//  ---------------------------------
//  **Nothing may derive "read from JSON" from a repository returning empty.**
//  After activation an empty database IS the answer and must be shown as one.
//  A fallback triggered by emptiness would serve an empty training history as
//  though it were real, and `Sub4Launch`'s own header names that as the worst
//  failure this app has available.
//
//  `derive` is therefore a pure function of three facts, none of which is a
//  repository result: did the database open, does the ledger hold an activated
//  run, and has this install ever been activated.
//
//  THE THIRD FACT, AND WHY IT IS NOT A SECOND AUTHORITY
//  ----------------------------------------------------
//  The plan says one activation authority: the newest verified `migration_run`
//  becomes `activated` in a checked transaction, and no preference may
//  independently claim activation. That is right, and it leaves a hole this
//  file has to close.
//
//  **A database that will not open cannot tell you whether it was activated.**
//  So at the one moment the distinction matters most — an activated install
//  whose database is corrupt — `.blocked` and `.legacyAuthoritative` are
//  indistinguishable from the ledger, because the ledger is inside the thing
//  that failed.
//
//  `everActivated` is a mirror in `UserDefaults`, written only AFTER the ledger
//  transaction commits, and it is **not a second authority** because of the one
//  property asserted by test: it can only ever make the outcome MORE
//  conservative. It can turn a failed open into `.blocked`. It can never
//  produce `.databaseAuthoritative` — that still requires the ledger row, read
//  out of an open database.
//
//  The direction is the point. A mirror that could grant permission would be a
//  second authority and the plan forbids it. A mirror that can only withhold it
//  fails towards refusing to serve data, which is the harmless side — the same
//  argument `MigrationLedger.prunableTriggers` makes about a leak and a
//  shredder.
//
//  WHAT B0 DELIBERATELY DOES NOT DO
//  --------------------------------
//  Nothing reads this yet. No store changes, no screen changes, no behaviour
//  changes. `Sub4Launch` computes it and holds it, and B1 is the first slice to
//  act on it. That is what makes B0 checkable on its own: if it is wrong, it is
//  wrong in a value nothing consumes.
//

import Foundation

/// Where production reads come from, for this launch.
nonisolated enum PersistenceMode: Equatable, Sendable {

    /// No activated run. The JSON stores are authoritative and the database is
    /// a shadow — every launch up to and including patch 342.
    case legacyAuthoritative

    /// A slice is under test. Its repository hydrates, its comparison runs,
    /// and production is still served from the legacy side. The associated
    /// value names the slice so the diagnostic can say which.
    case shadow(String)

    /// An activated run exists and the database opened. Reads come from SQLite.
    case databaseAuthoritative

    /// An activated install whose database did not open.
    ///
    /// THE STATE THE WHOLE STAGE RESTS ON. It is not a failure to recover from
    /// by reading JSON: after activation the JSON mirror is frozen and stale,
    /// and serving it would show an old training history as the current one.
    /// The app holds. §12.90.
    case blocked(String)

    var isDatabaseAuthoritative: Bool { self == .databaseAuthoritative }

    /// Whether production may serve anything at all. `false` is the recovery
    /// screen, and B9 is where `RootView` learns to draw one.
    var mayServe: Bool {
        if case .blocked = self { return false }
        return true
    }

    /// UNCONDITIONAL, and it names the slice or the reason rather than
    /// vanishing — §12.54.2.
    var line: String {
        switch self {
        case .legacyAuthoritative:  "the app's own files (the database is a shadow)"
        case .shadow(let slice):    "the app's own files, with \(slice) under test"
        case .databaseAuthoritative: "the database"
        case .blocked(let why):     "nothing — \(why)"
        }
    }
}

nonisolated enum PersistenceAuthority {

    /// WHICH SLICE IS UNDER TEST, or nil when none is.
    ///
    /// A stored constant rather than an implicit choice, exactly like
    /// `Sub4Launch.migrationFailureBlocksTheApp` — so moving to the next slice
    /// is a decision somebody makes on purpose and a reviewer can see in the
    /// diff. Nil at B0 because B0 changes no reads.
    static let sliceUnderTest: String? = nil

    /// The mirror. See the header: it may only ever withhold.
    ///
    /// The key is namespaced and never reused. `DataLifecycle` must remove it
    /// with everything else — a flag that survived "Delete local data" would
    /// block a reinstalled app over a database that no longer exists.
    static let activationMirrorKey = "sub4.persistence.everActivated"

    static func everActivated(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: activationMirrorKey)
    }

    /// Written by B9 AFTER the ledger transaction commits, never before. If the
    /// transaction fails, the mirror must not claim what the ledger refused.
    static func recordActivation(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: activationMirrorKey)
    }

    /// THE DERIVATION, PURE, AND ITS THREE INPUTS ARE ALL FACTS ABOUT THE
    /// DATABASE RATHER THAN ABOUT ANY REPOSITORY'S RESULT.
    ///
    /// - `activatedRun`: does the ledger hold a run in `activated`. Nil
    ///   whenever the database did not open, because it cannot be known.
    /// - `databaseOpened`: did `Sub4Database.open()` succeed.
    /// - `everActivated`: the mirror.
    ///
    /// Pure so that every combination can be driven from a test without a
    /// device — which matters, because two of the four states have never
    /// occurred and one of them never should.
    static func derive(activatedRun: Bool,
                       databaseOpened: Bool,
                       everActivated: Bool,
                       sliceUnderTest: String? = sliceUnderTest) -> PersistenceMode {
        if databaseOpened {
            if activatedRun { return .databaseAuthoritative }
            if let sliceUnderTest { return .shadow(sliceUnderTest) }
            return .legacyAuthoritative
        }
        // THE DATABASE DID NOT OPEN, so the ledger cannot be consulted and
        // `activatedRun` is necessarily false. The mirror is the only thing
        // that can say this install was ever activated, and it may only
        // withhold: it turns a failed open into `.blocked` and can never
        // produce `.databaseAuthoritative` — that branch is above and requires
        // `databaseOpened`.
        if everActivated {
            return .blocked("the database is activated and could not be opened")
        }
        return .legacyAuthoritative
    }
}
