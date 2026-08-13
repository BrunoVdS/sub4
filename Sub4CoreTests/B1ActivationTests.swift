//
//  B1ActivationTests.swift
//  Sub4CoreTests
//
//  D7 slice B1, the flip — patch 346.
//
//  WHAT A TEST CAN AND CANNOT PROVE ABOUT THIS PATCH
//  -------------------------------------------------
//  346 changes one constant. What that constant does — three stores fed from
//  rows instead of files — was proved by test at 344 (the hydration) and 345
//  (the decision), and proved on the device at 345 (the bootstrap reading every
//  family cleanly out of the real database).
//
//  So this suite does not re-prove the machinery. It holds the three things
//  that are true only because the constant moved, and that nothing else would
//  notice if they stopped being true:
//
//    1. the constant is set, and names the slice
//    2. the activation mirror is declared, so "Delete local data" removes it
//    3. the inventory shown to the athlete does not claim nothing reads the
//       database
//
//  THE THIRD IS A STRING CHECK AND IT IS NOT BENEATH THIS PROJECT. Patch 281 is
//  the record: `weather` and `sessionNotes` started feeding the database at 265
//  and 271, and `[.device]` went on being the declared lineage for sixteen
//  patches. That half had a type behind it and still drifted. The prose half —
//  the sentences a person actually reads before deciding whether they are
//  comfortable — has nothing behind it at all.
//
//  WHAT PROVES THE HYDRATION ITSELF IS NOT HERE, IT IS ON THE DEVICE, and the
//  sharpest check was already built by somebody else: `Sub4Import.importPlan`
//  hashes the plan it is given and skips the write when a `plan_version` with
//  that hash exists. `AppStores.plan` is `PlanStore.shared.plan`, which is now
//  the HYDRATED plan. So the first import after this patch re-hashes the plan
//  that came out of the database and compares it against the hash of the plan
//  that went in. A lossy hydration writes a second version; `plan_version: 1`
//  in the paste is 261 sessions and 634 blocks agreeing, checked by code that
//  knows nothing about D7.
//

import Testing
import Foundation
@testable import Sub4

@Suite("B1 is switched on")
struct B1ActivationTests {

    // MARK: The constant

    /// THE LINE THIS PATCH IS. A slice that is on but unnamed would produce
    /// `shadow("")` in the diagnostic, which reads as a bug in the diagnostic
    /// rather than as a slice under test.
    @Test("The slice under test is set and names itself")
    func theSliceIsSet() {
        let slice = PersistenceAuthority.sliceUnderTest
        #expect(slice != nil, "346 is the flip — nil means it did not happen")
        #expect(slice?.contains("B1") == true, "the diagnostic has to say which")
        #expect(slice?.isEmpty == false)
    }

    /// The constant reaches the mode, and the mode says hydrate. Driven through
    /// `derive` rather than asserted about the constant alone, because the path
    /// from one to the other is what 346 turns on.
    @Test("An open database with no activated run now hydrates")
    func anOpenDatabaseHydrates() {
        let mode = PersistenceAuthority.derive(activatedRun: false,
                                               databaseOpened: true,
                                               everActivated: false)
        #expect(mode.hydratesFromDatabase, "this is what the constant buys")
        guard case .shadow(let slice) = mode else {
            Issue.record("an open, unactivated database with a slice set is shadow")
            return
        }
        #expect(slice.contains("B1"))
    }

    /// AND THE FLIP DID NOT REACH B9's FLAG. A3 §2.2 settled that every slice
    /// keeps a selectable legacy path and the app fails closed only after all
    /// eight. A patch that moved both would be B9 arriving eight slices early,
    /// with no recovery screen written.
    @Test("The slice flip is not the activation flip")
    func theSliceFlipIsNotTheActivationFlip() {
        #expect(!Sub4Launch.migrationFailureBlocksTheApp,
                "B9 flips this, after all eight slices, with a recovery screen")
        #expect(!PersistenceAuthority.derive(activatedRun: false,
                                             databaseOpened: true,
                                             everActivated: false)
            .isDatabaseAuthoritative,
                "a slice under test is not an activated database")
    }

    // MARK: The mirror that would have survived a delete

    /// `PersistenceMode`'s header states this as a requirement — "`DataLifecycle`
    /// must remove it with everything else — a flag that survived 'Delete local
    /// data' would block a reinstalled app over a database that no longer
    /// exists" — and until 346 nothing implemented it.
    ///
    /// Latent rather than harmless: `recordActivation` has no caller until B9,
    /// so the key is never written yet. A requirement stated in one file and
    /// implemented in none is the drift this inventory exists to stop.
    @Test("The activation mirror is declared, so a delete removes it")
    func theActivationMirrorIsDeclared() {
        #expect(DataLifecycle.preferenceKeys
            .contains(PersistenceAuthority.activationMirrorKey),
                "a flag that survived a delete would block a reinstalled app")
    }

    /// It belongs to the DATABASE and not to preferences-in-general, because it
    /// describes the database's own state and has to go when the folder goes.
    @Test("The mirror is filed under the database")
    func theMirrorIsFiledUnderTheDatabase() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        let keys = entry.storage.flatMap { s -> [String] in
            if case .preferences(let k) = s { return k }
            return []
        }
        #expect(keys.contains(PersistenceAuthority.activationMirrorKey))
    }

    // MARK: The inventory the athlete reads

    /// THE PROSE GUARD, AND IT HAS NO TYPE BEHIND IT.
    ///
    /// This entry told the athlete "No screen in the app reads from it yet;
    /// they all still read the files above" for as long as that was true. From
    /// 346 the Plan, Week and Today screens draw the plan out of these rows.
    /// A disclosure that is false is worse than no disclosure, because it is
    /// believed.
    ///
    /// Keyed on `sliceUnderTest` rather than on `migrationFailureBlocksTheApp`:
    /// those are two different questions and this is the one about READING.
    /// The disconnect rule and the export exemption stay keyed on the other,
    /// which is the one about the database holding the ONLY copy — see
    /// `theDisconnectRuleIsCoupledToActivation`.
    @Test("The inventory does not claim nothing reads the database")
    func theInventoryDoesNotClaimNothingReadsTheDatabase() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        guard PersistenceAuthority.sliceUnderTest != nil
                || Sub4Launch.migrationFailureBlocksTheApp else { return }

        let prose = ([entry.whatItIs] + entry.gaps).joined(separator: "\n")
        #expect(!prose.contains("No screen in the app reads from it"),
                "three stores read from it")
        #expect(!prose.contains("nothing reads them"),
                "the plan, the zones, the FTP and the resting figures are read")
        #expect(entry.whatItIs.contains("READ from it"),
                "and it says so, in the sentence a person actually reads")
    }

    /// STILL A COPY, AND THE TWO RULES THAT DEPEND ON THAT ARE UNCHANGED.
    ///
    /// Every row the three stores read also still exists in a file above, and
    /// every one of those files is still written — `hydrate` does not save, and
    /// the importer still seeds from them. So `.removeEverything` on disconnect
    /// and `isExportable: false` are both still correct at 346, for the reason
    /// they were always correct and not for the reason the old prose gave.
    @Test("The database is still a copy, so its two rules do not move")
    func theDatabaseIsStillACopy() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        #expect(entry.onStravaDisconnect == .removeEverything,
                "the rows are a copy of files that are still written")
        #expect(entry.isExportable == false,
                "the export takes the stores, which hold the same data")
    }
}
