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

    /// A slice is under test: ITS STORES ARE FED FROM THE DATABASE, and every
    /// screen that reads them is reading rows.
    ///
    /// CORRECTED AT 345, AND THE CORRECTION IS THE DECISION. This said "its
    /// comparison runs, and production is still served from the legacy side",
    /// which describes a mode that proves nothing: the read-back already
    /// compares the two sides on demand, so a shadow that only compared would
    /// add a second copy of an existing check and leave the hydration path
    /// unexercised until B9 turned on nine of them at once.
    ///
    /// What makes it safe is not that production is untouched — it is that the
    /// switch is a compile-time constant, the read-back's other side is a
    /// fresh decode of the bundle (patch 343) rather than the store, and the
    /// acceptance criterion for every slice is that no figure on any screen
    /// moves. Reversible by setting `sliceUnderTest` back to nil.
    ///
    /// The associated value names the slice so the diagnostic can say which.
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

    /// Whether the stores take their data from rows this launch — patch 345.
    ///
    /// THE ONE PLACE THAT DECIDES, and it is deliberately not a list of slices.
    /// Which FAMILIES hydrate is `DatabaseBootstrap`'s contents; this says
    /// only whether hydration happens at all. Two lists would be two things to
    /// keep in step, and the one that drifted would be the one nobody read —
    /// §12.43.
    ///
    /// `.blocked` is false, and not because hydrating would be harmful: after
    /// activation an unreadable database means the app may not serve at all,
    /// and B9's recovery screen is the answer rather than a store full of
    /// whatever the failure left behind.
    var hydratesFromDatabase: Bool {
        switch self {
        case .shadow, .databaseAuthoritative: true
        case .legacyAuthoritative, .blocked:  false
        }
    }

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
    ///
    /// SET AT 346. THE PLAN, THE ATHLETE AND THE CONSTANTS NOW COME FROM ROWS.
    ///
    /// 345 assembled the bootstrap on every launch and wired the hydration all
    /// the way to the three stores; this constant was the only thing standing
    /// between that and the stores actually taking them. On the device at 345
    /// the bootstrap reported every read succeeded and every family holds data,
    /// against the real database, one patch before anything depended on it.
    ///
    /// **REVERSIBLE BY SETTING THIS BACK TO NIL.** Not by a migration, not by
    /// a re-import, not by anything that touches the athlete's data: the JSON
    /// files are still written, still complete, and still the source the
    /// importer seeds from. That is what makes a slice a slice.
    ///
    /// SLICES ACCUMULATE AND THIS IS NOT A LIST OF THEM. Which FAMILIES hydrate
    /// is `DatabaseBootstrap`'s contents; this says only whether hydration
    /// happens at all, and carries a label for the diagnostic. B2 adds its
    /// family to the bootstrap and extends this sentence — it does not replace
    /// it, and it cannot switch B1 off by editing a string. §12.43.
    static let sliceUnderTest: String? = "B1 — the plan, the athlete and the constants"

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

// MARK: - What the database now feeds — patch 354, ADR-0003 §12.99

/// EVERY STORE THIS BUILD HYDRATES FROM THE DATABASE, AND THE COMPARISON EACH
/// ONE INVALIDATES.
///
/// WHY THIS LIST EXISTS.
/// `SemanticVerifier` compares the database against the app's stores, and
/// `verified` is the state D7's activation reads. Every B-slice moves one more
/// store onto the database — and the moment it does, the comparison that reads
/// that store stops being evidence and becomes the database agreeing with
/// itself. §12.69: a check that cannot fail has not been tested.
///
/// It went from twenty real comparisons to nineteen at B1 and nobody noticed,
/// because nothing anywhere said which was which. At B9 it reaches zero, and
/// zero is the number a verifier must never quietly report as twenty.
///
/// WHY HERE. `sliceUnderTest` is the constant a slice already edits, so this is
/// the line the same hand is already on. Forgetting to add an entry cannot be
/// caught by anything — a store silently becomes self-referential and the
/// report reads better than the truth — which is exactly why the OPPOSITE
/// mistake is caught loudly: `VerificationReport.unmatchedHydratedEntries`
/// reports an entry naming a comparison that does not exist, and that is the
/// symptom a rename produces.
nonisolated enum HydratedStores {

    nonisolated struct Entry: Equatable, Sendable, Identifiable {
        /// `VerificationCheck.name`, EXACTLY. This is the join key.
        let check: String
        /// The store field the expectation is read from.
        let store: String
        /// The slice that moved it onto the database.
        let slice: String

        var id: String { check }

        var note: String { "\(store), hydrated at \(slice)" }
    }

    /// B1 moved the plan, the athlete's constants, the heart-rate zones and the
    /// FTP onto the database. Exactly one of those is a verifier expectation:
    /// `zones` is `AthleteStore.hrZones`, and `heart-rate zones [hr_zone]` has
    /// compared the database against itself since 346.
    ///
    /// THE PLAN IS NOT HERE AND MUST NOT BE. `SemanticVerifier` does not
    /// compare plan tables at all — `PlanRoundTrip` does, and 343 gave that one
    /// an independent side by decoding the bundle rather than asking the store.
    /// An entry here for a comparison this verifier does not make would be
    /// reported by `unmatchedHydratedEntries` and is a defect, not a note.
    ///
    /// B5 adds gear. B9 adds the rest, and takes the independent count to zero.
    nonisolated static let all: [Entry] = [
        .init(check: "heart-rate zones",
              store: "AthleteStore.hrZones",
              slice: "B1"),
    ]

    static func entry(for checkName: String) -> Entry? {
        all.first { $0.check == checkName }
    }
}
