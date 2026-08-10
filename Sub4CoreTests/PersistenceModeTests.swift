//
//  PersistenceModeTests.swift
//  Sub4CoreTests
//
//  D7 slice B0, patch 342. The guard the whole stage rests on.
//
//  WHAT THESE ARE FOR
//  ------------------
//  A3 settled that every slice keeps a selectable legacy path through D7 and
//  the flag flips at B9. That decision is only safe if the selection is made in
//  one place, from facts about the database, and can never be reached by a
//  repository returning empty.
//
//  Two of the four states have never occurred on any device and one of them
//  never should. That is exactly why `derive` is pure: every combination can be
//  driven here, and §12.69's rule applies — a guard that cannot fail has not
//  been tested, so the tests that matter below are the ones that force the
//  failure and assert the refusal.
//
//  THE THREE WITH TEETH
//  --------------------
//  · `anActivatedInstallWithAClosedDatabaseIsBlocked` — the state the whole
//    stage rests on. After activation the JSON mirror is frozen, so falling
//    back to it would serve an old training history as the current one.
//  · `theMirrorCanNeverGrantTheDatabase` — the mirror exists because a database
//    that will not open cannot say whether it was activated. It may only ever
//    withhold. This drives every input combination and asserts the mirror
//    appears in no path that returns `.databaseAuthoritative`.
//  · `everyCombinationIsCovered` — eight inputs, eight answers, none of them
//    accidental. An account beats a list.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Where the app reads from")
struct PersistenceModeTests {

    // MARK: The steady state, today

    /// Patch 342 itself: nothing activated, the database opens, the JSON stores
    /// are authoritative and the database is a shadow.
    @Test("With no activated run the app reads its own files")
    func todayIsLegacyAuthoritative() {
        let mode = PersistenceAuthority.derive(activatedRun: false,
                                               databaseOpened: true,
                                               everActivated: false,
                                               sliceUnderTest: nil)
        #expect(mode == .legacyAuthoritative)
        #expect(mode.mayServe)
        #expect(!mode.isDatabaseAuthoritative)
    }

    /// B0 ships with no slice under test, and that is asserted rather than
    /// assumed — a constant that quietly named a slice would put the app in
    /// shadow mode with nothing shadowing it.
    @Test("B0 names no slice under test")
    func b0NamesNoSlice() {
        #expect(PersistenceAuthority.sliceUnderTest == nil)
    }

    @Test("A slice under test is named, and still serves the legacy side")
    func aSliceUnderTestIsNamed() {
        let mode = PersistenceAuthority.derive(activatedRun: false,
                                               databaseOpened: true,
                                               everActivated: false,
                                               sliceUnderTest: "B1 plan and athlete")
        #expect(mode == .shadow("B1 plan and athlete"))
        #expect(mode.mayServe, "a shadow slice still serves the app")
        #expect(!mode.isDatabaseAuthoritative)
        #expect(mode.line.contains("B1 plan and athlete"),
                "the diagnostic says which slice, or it says nothing useful")
    }

    // MARK: After activation

    @Test("An activated run over an open database reads the database")
    func activatedAndOpenReadsTheDatabase() {
        let mode = PersistenceAuthority.derive(activatedRun: true,
                                               databaseOpened: true,
                                               everActivated: true)
        #expect(mode == .databaseAuthoritative)
        #expect(mode.mayServe)
    }

    /// THE STATE THE WHOLE STAGE RESTS ON. After activation the JSON mirror is
    /// frozen and stale. Falling back to it would show an old training history
    /// as the current one, which is worse than showing nothing.
    @Test("An activated install whose database will not open is blocked")
    func anActivatedInstallWithAClosedDatabaseIsBlocked() {
        let mode = PersistenceAuthority.derive(activatedRun: false,
                                               databaseOpened: false,
                                               everActivated: true)
        guard case .blocked = mode else {
            Issue.record("a failed open after activation must block, got \(mode)")
            return
        }
        #expect(!mode.mayServe, "blocked means the app does not serve")
        #expect(mode != .legacyAuthoritative)
    }

    /// The other half. A database that will not open on an install that was
    /// never activated is today's situation and must stay survivable — the
    /// database is a shadow and blocking over it would turn a contained problem
    /// into a dead app.
    @Test("A failed open before activation is survivable")
    func aFailedOpenBeforeActivationIsSurvivable() {
        let mode = PersistenceAuthority.derive(activatedRun: false,
                                               databaseOpened: false,
                                               everActivated: false)
        #expect(mode == .legacyAuthoritative)
        #expect(mode.mayServe)
    }

    // MARK: The mirror, and the one property that keeps it from being a second authority

    /// THE MIRROR MAY ONLY EVER WITHHOLD.
    ///
    /// The plan says one activation authority: the ledger. The mirror exists
    /// because a database that will not open cannot be asked. It is not a
    /// second authority as long as it can never GRANT — so this drives every
    /// combination and asserts that no result of `.databaseAuthoritative` is
    /// reachable without the database having opened AND the ledger agreeing.
    @Test("The mirror can never grant the database")
    func theMirrorCanNeverGrantTheDatabase() {
        for activatedRun in [true, false] {
            for databaseOpened in [true, false] {
                for everActivated in [true, false] {
                    let mode = PersistenceAuthority.derive(
                        activatedRun: activatedRun,
                        databaseOpened: databaseOpened,
                        everActivated: everActivated,
                        sliceUnderTest: nil)
                    if mode == .databaseAuthoritative {
                        #expect(databaseOpened,
                                "the database must have opened")
                        #expect(activatedRun,
                                "the LEDGER must say activated, not the mirror")
                    }
                }
            }
        }
    }

    /// Turning the mirror on may only ever move an answer towards refusing.
    /// Nothing it does may make the app serve MORE than it would without it.
    @Test("The mirror only ever makes the answer more conservative")
    func theMirrorOnlyWithholds() {
        for activatedRun in [true, false] {
            for databaseOpened in [true, false] {
                let without = PersistenceAuthority.derive(
                    activatedRun: activatedRun, databaseOpened: databaseOpened,
                    everActivated: false, sliceUnderTest: nil)
                let with = PersistenceAuthority.derive(
                    activatedRun: activatedRun, databaseOpened: databaseOpened,
                    everActivated: true, sliceUnderTest: nil)
                if !without.mayServe {
                    #expect(!with.mayServe,
                            "the mirror may not grant service that was refused")
                }
                if with != without {
                    #expect(!with.mayServe,
                            "the only difference the mirror may make is blocking")
                }
            }
        }
    }

    /// AN ACCOUNT BEATS A LIST. Eight input combinations, eight stated answers.
    /// A branch added later without a decision shows up here as a mismatch
    /// rather than as a state nobody named.
    @Test("Every combination has a stated answer")
    func everyCombinationIsCovered() {
        // activatedRun, databaseOpened, everActivated → expected
        let table: [(Bool, Bool, Bool, PersistenceMode)] = [
            (true,  true,  true,  .databaseAuthoritative),
            (true,  true,  false, .databaseAuthoritative),
            (false, true,  true,  .legacyAuthoritative),
            (false, true,  false, .legacyAuthoritative),
            (true,  false, true,  .blocked("the database is activated and could not be opened")),
            (true,  false, false, .legacyAuthoritative),
            (false, false, true,  .blocked("the database is activated and could not be opened")),
            (false, false, false, .legacyAuthoritative)
        ]
        #expect(table.count == 8, "three booleans, eight rows")
        for (run, opened, mirror, expected) in table {
            let mode = PersistenceAuthority.derive(activatedRun: run,
                                                   databaseOpened: opened,
                                                   everActivated: mirror,
                                                   sliceUnderTest: nil)
            #expect(mode == expected,
                    "run \(run), opened \(opened), mirror \(mirror)")
        }
    }

    // MARK: The mirror's own storage

    /// Its own suite name, so it cannot see or disturb the real defaults.
    private func defaults() throws -> UserDefaults {
        let name = "persistence-mode-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("A fresh install has never been activated")
    func aFreshInstallHasNoMirror() throws {
        let d = try defaults()
        #expect(!PersistenceAuthority.everActivated(d))
    }

    @Test("Recording activation sets the mirror and it survives a re-read")
    func recordingActivationSetsTheMirror() throws {
        let d = try defaults()
        PersistenceAuthority.recordActivation(d)
        #expect(PersistenceAuthority.everActivated(d))
    }

    /// The key is namespaced and stated, because `DataLifecycle` has to remove
    /// it with everything else. A flag that survived "Delete local data" would
    /// block a reinstalled app over a database that no longer exists.
    @Test("The mirror key is namespaced")
    func theMirrorKeyIsNamespaced() {
        #expect(PersistenceAuthority.activationMirrorKey
                    == "sub4.persistence.everActivated")
        #expect(PersistenceAuthority.activationMirrorKey.hasPrefix("sub4."))
    }

    // MARK: What B0 must not have changed

    /// B0 computes a value and nothing consumes it. The flag stays false until
    /// B9, and this is the assertion that says B0 did not quietly become B9.
    @Test("B0 does not flip the flag")
    func b0DoesNotFlipTheFlag() {
        #expect(Sub4Launch.migrationFailureBlocksTheApp == false,
                "the flip is B9, after every slice — A3 §2.2")
    }
}
