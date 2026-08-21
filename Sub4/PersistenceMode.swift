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
    static let sliceUnderTest: String? =
        "B1 — the plan, the athlete and the constants"
        + "; B2 — the notes, the commute decisions, the match decisions"
        + " and the plan moves"
        // PATCH 382. EXTENDS, DOES NOT REPLACE — §12.43 and this constant's
        // own doc. A label that dropped B1 and B2 would read as those slices
        // having been switched off, which is the opposite of what happened.
        + "; B3 — the activities"
        // PATCH 398. EXTENDS for 382's reason, and names both families rather
        // than "the traces": they are two entries in `Family`, they can be
        // reverted apart, and a label that said one would describe half a
        // rollback as none of one.
        + "; B4 — the details and the traces"
        // **PATCH 434 — AND B5 FLIPPED AT 430, THREE PATCHES BEFORE THIS
        // LINE MOVED.** From 430 to 433a the app told the athlete on the
        // Database screen that its weather and gear came from files, while
        // `hydratedFamilies` had been feeding both from rows since the flip.
        //
        // §12.127.5's shape once more — a sentence about what the app
        // CURRENTLY DOES, stored as a constant — and this time nothing
        // coupled it to the thing it describes. `everyHydratedFamilyIsDisclosed`
        // is that coupling, and it fails on the day a slice flips without
        // this string moving. §12.189.
        + "; B5 — the weather and the gear"

    /// WHICH FAMILIES THIS BUILD ACTUALLY HYDRATES — patch 357, §12.102.
    ///
    /// `sliceUnderTest` says which slice is being exercised; this says which
    /// stores are fed from the database while it is. They were the same thing
    /// while there was one slice and stopped being the same thing the moment
    /// B2's machinery landed before B2's flip.
    ///
    /// **THIS IS THE LINE 358 CHANGES, AND IT IS THE ONLY ONE.** 344 built B1's
    /// machinery and 346 flipped it; the flip found four failures, and they were
    /// attributable because the two were separate patches. A build with the
    /// machinery and without the flip has to be expressible for that to be
    /// possible twice.
    nonisolated enum Family: String, CaseIterable, Sendable {
        case plan, extras, athlete, authored, decisions
        /// PATCH 377. Built at 365, after this enum was written, and authored
        /// data of B2's own kind — the last of that slice still on a file.
        case moves
        /// **PATCH 379 — D7 slice B3, and the case that separates the two
        /// counts.** The bootstrap reads it as of this patch; nothing feeds a
        /// store from it, which is what `hydratedFamilies` not naming it
        /// means. 380 builds the machinery and 381 is the flip. §12.123.
        case activities
        /// **PATCH 394 — D7 slice B4, and the two that separate the counts
        /// again.** The bootstrap reads both as of this patch; nothing feeds a
        /// store from either, which is what `hydratedFamilies` not naming them
        /// means. 395 is the flip. §12.123's shape, one slice later — a family
        /// read before it is fed is what 344/346, 357/358 and 379/382 all
        /// looked like.
        case details, traces

        /// **WHICH SLICE FED THIS FAMILY — patch 434.**
        ///
        /// Exhaustive, so a new case cannot be added without answering, and it
        /// is the join `everyHydratedFamilyIsDisclosed` walks: a family that is
        /// fed must have its slice named in `sliceUnderTest`, or the app is
        /// telling the athlete something that stopped being true.
        ///
        /// **The letters are the ladder's, not this file's.** They come from
        /// `PLAN-cutover-v2.md` and appear in ADR §12 throughout; a family whose
        /// slice letter changed would be a renaming of the ladder rather than a
        /// change here.
        var slice: String {
            switch self {
            case .plan, .extras, .athlete:              "B1"
            case .authored, .decisions, .moves:         "B2"
            case .activities:                           "B3"
            case .details, .traces:                     "B4"
            case .weather, .gear:                       "B5"
            }
        }

        /// **PATCH 428 — D7 slice B5, AND TWO CASES FOR ONE READ.**
        ///
        /// `WeatherGearRepository.load` is a single `db.queue.read` returning
        /// one `WeatherGearLoad`, so the bootstrap holds ONE field for them —
        /// `fieldCount`'s rule follows the read, and either failing fails both.
        ///
        /// **The hydration is a different axis and gets two cases**, because
        /// the groundwork found the two halves at very different maturity:
        /// weather is twelve columns, eleven compared and restorable, while
        /// gear only stopped being lossy at 425–427. Rolling back half a slice
        /// is a two-character edit with two cases and impossible with one.
        case weather, gear
    }

    /// **PATCH 358 WAS THIS LINE, AND 379 IS WHERE IT STOPPED BEING THE
    /// WHOLE STORY.**
    ///
    /// At B2 every family the bootstrap read was fed to its store, so
    /// `hydratedFamilies.count` and `Family.allCases.count` met. 379 adds
    /// `.activities` to the bootstrap and NOT to this set, so they have
    /// separated: seven read, six fed. **That gap is the slice.** A family
    /// read before it is fed is what 344/346 and 357/358 both looked like, and
    /// what 377 did not — see §12.121.8 for the prediction this finally makes
    /// true.
    ///
    /// The flip is still one line: add `.activities` here. 381 does that.
    ///
    /// STILL REVERSIBLE, and by the same two edits as before: take a family out
    /// of this set, or set `sliceUnderTest` to nil. The JSON files are still
    /// written and still complete — that is what makes a slice a slice, and it
    /// is why hydration MUST NOT WRITE. See `NotesStore.hydrate(from:)`.
    /// **PATCH 382 — `.activities` JOINS, AND THE TWO COUNTS MEET AGAIN.**
    /// 379 separated them on purpose; three patches later the machinery (380)
    /// and the comparison's own read (381) are both in place, so the family
    /// can be fed without anything losing its ability to disagree. Reversible
    /// by deleting `.activities` from this line — `activities.json` is still
    /// written and still complete, which is what makes a slice a slice.
    /// **PATCH 394 LEAVES THIS LINE ALONE, AND THAT IS THE PATCH.** `.details`
    /// and `.traces` are in `Family` and in the bootstrap and are NOT here, so
    /// nine families are read and seven are fed. **That gap is the slice.** 395
    /// adds the two, and because it adds nothing else, any failure it produces
    /// is attributable — 346's four failures were, and 382's three were.
    /// **PATCH 398 ADDS THE LAST TWO, AND THE PATCH IS THIS LINE.** Everything
    /// else B4 needed was built and switched off across 388–397; nothing but
    /// these two cases changes here, so any failure the flip produces is
    /// attributable to the flip. 346's four failures were and 382's three
    /// were. **`DetailStore.init` is what reads this one**, not `Sub4Launch` —
    /// §12.139 measured why. Reversible by deleting them: `details/` and
    /// `streams/` are still written and still complete.
    /// **PATCH 430 ADDS THE LAST TWO, AND THE PATCH IS THIS LINE.** Everything
    /// B5 needed was built and switched off across 425–429: the two columns,
    /// the importer, the comparison, the read, the hydration. **Nothing but
    /// these two cases changes here**, so any failure the flip produces is
    /// attributable to the flip — 346's four were, 382's three were, 398's zero
    /// were.
    ///
    /// **Eleven read, eleven fed. The ladder's gap closes for the fourth
    /// time**, and the next one to open is B6's.
    ///
    /// Reversible by deleting them, and **by half**: `.gear` alone can go back
    /// if gear misbehaves on the device, which is why 428 spent two cases on
    /// one read. `weather.json` and `athlete.json` are still written and still
    /// complete, which is what makes a slice a slice, and it is why hydration
    /// must not write.
    static let hydratedFamilies: Set<Family> = [.plan, .extras, .athlete,
                                                .authored, .decisions, .moves,
                                                .activities, .details, .traces,
                                                .weather, .gear]

    /// Whether this build feeds a given store from the database. Asked by the
    /// planner and by nothing else — a second caller would be a second opinion
    /// about what this build does.
    static func hydrates(_ family: Family) -> Bool {
        hydratedFamilies.contains(family)
    }

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
