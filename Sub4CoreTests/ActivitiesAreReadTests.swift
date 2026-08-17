//
//  ActivitiesAreReadTests.swift
//  Sub4CoreTests
//
//  The seventh family — patch 379, D7 slice B3 groundwork, ADR-0003 §12.123.
//
//  THE PROPERTY THIS SUITE EXISTS FOR, AND IT IS THE GAP
//  -----------------------------------------------------
//  `Family.allCases.count` is 7 and `hydratedFamilies.count` is 6. Every other
//  suite in this target describes a world where those two numbers are equal,
//  because between 358 and 379 they were. The gap is not an oversight to be
//  closed by the next person who notices it — it is the slice, and taking
//  `.activities` out of the bootstrap or putting it into `hydratedFamilies`
//  are both changes somebody has to make on purpose.
//
//  WHAT IS DELIBERATELY NOT HERE
//  -----------------------------
//  Nothing about hydrating. There is no `hydratableActivities`, no payload on
//  `Instruction.hydrate`, and no `ActivityStore.hydrate(from:)` — 380 builds
//  those and 381 flips the line. `theActivityComparisonIsStillEvidence` pins
//  the property 381 will invert, so that inversion is visible in a diff
//  instead of arriving as a count that quietly slid. §12.121.8 is what that
//  test is for.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The activities are read, and nothing is fed from them")
@MainActor
struct ActivitiesAreReadTests {

    // MARK: THE ONE THAT IS THE POINT

    /// **THE GAP IS CLOSED — patch 382, and this is the inversion 379 wrote
    /// this test to make visible.** Seven read, seven fed. The `>` became an
    /// `==` and the `!` went, in a diff that also contains the line that did
    /// it, which is the whole reason the two were separate patches.
    @Test("The two counts have met again, and that is the flip")
    func theTwoCountsHaveMetAgain() {
        #expect(PersistenceAuthority.Family.allCases.count == 7)
        #expect(PersistenceAuthority.hydratedFamilies.count == 7)
        #expect(PersistenceAuthority.Family.allCases.count
                == PersistenceAuthority.hydratedFamilies.count,
                "every family the bootstrap reads is now fed to a store")
        #expect(PersistenceAuthority.hydrates(.activities),
                "and the line that did it is one line in PersistenceMode")
    }

    /// **THE SET COMPARISON SURVIVES THE FLIP, AND IT IS WHY IT WAS WRITTEN
    /// AS A SET.** A count of 7 against 7 could hide one family dropping out
    /// as another joined; the two subtractions cannot.
    @Test("Nothing is read that is not fed, and nothing fed that is not read")
    func theTwoSetsAreTheSame() {
        let read = Set(PersistenceAuthority.Family.allCases)
        let fed = PersistenceAuthority.hydratedFamilies
        #expect(read.subtracting(fed).isEmpty,
                "the gap closed at 382 and nothing else opened one")
        #expect(fed.subtracting(read).isEmpty,
                "and nothing is fed that the bootstrap does not read")
    }

    // MARK: The read itself

    @Test("The seventh family is read and reaches the paste")
    func theSeventhFamilyIsRead() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(DatabaseBootstrap.fieldCount == 7)
        #expect(DatabaseBootstrap.diagnosticLineCount
                == DatabaseBootstrap.fieldCount + 6,
                "derived, so only the family term moves")
        #expect(b.activities.wasReadCleanly,
                "a migrated empty database reads the activity table cleanly")
        #expect(!b.activities.holdsContent)

        let lines = b.diagnosticLines
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)
        #expect(lines.contains(where: { $0.hasPrefix("  activities:") }),
                "a family with no line is invisible in the paste — §12.54.2")
    }

    /// §12.92, on the seventh family. One word carrying both questions is
    /// what 344 was written to end.
    @Test("A clean read of no activities is not a failed read")
    func cleanAndEmptyIsNotAFailure() {
        let empty = ActivityLoad.loaded(activities: [], skipped: 0)
        #expect(empty.wasReadCleanly)
        #expect(!empty.holdsContent, "and this is a device before its first sync")

        for bad: ActivityLoad in [.unavailable, .failed("no such table")] {
            #expect(!bad.wasReadCleanly)
            #expect(!bad.holdsContent, "a read that failed holds nothing to know")
        }
    }

    /// NAMED RATHER THAN COUNTED — §12.39, and named as ITSELF rather than as
    /// whichever family comes first.
    @Test("A failed activity read is named by the fault")
    func aFailedReadIsNamed() {
        let b = DatabaseBootstrap(
            plan: .unavailable, extras: .unavailable, athlete: .unavailable,
            authored: .unavailable, decisions: .unavailable,
            moves: .unavailable,
            activities: .failed("no such table: activity"))
        #expect(!b.wasReadCleanly)
        #expect(b.firstFault?.contains("plan") == true,
                "field order — the plan failed first and is what gets named")

        let onlyActivities = DatabaseBootstrap(
            plan: .noActiveVersion(versionsPresent: 0),
            extras: .noActiveVersion(versionsPresent: 0),
            athlete: .missing, authored: .noneWritten,
            decisions: .noneRecorded, moves: .loaded(moves: [], skipped: 0),
            activities: .failed("no such table: activity"))
        #expect(!onlyActivities.wasReadCleanly,
                "the seventh family can fail the whole verdict on its own")
        #expect(onlyActivities.firstFault?.contains("activities") == true)
        #expect(onlyActivities.firstFault?.contains("no such table") == true)
    }

    // MARK: The three lists it is deliberately absent from

    /// **A DEVICE BEFORE ITS FIRST SYNC.** A plan is imported at every launch;
    /// activities arrive from a Strava sync that may never have run. Reading
    /// "no activities" as "there is nothing here to hydrate from" would refuse
    /// the plan over the absence of something else entirely.
    @Test("No activities does not make the database unhydratable")
    func noActivitiesIsNotAnEmptyDatabase() {
        let planned = DatabaseBootstrap(
            plan: .loaded(meta: Meta(plan: "stored", week1Monday: "2026-07-27",
                                     raceDate: "2027-03-21",
                                     targetTime: "04:00:00",
                                     targetPaceSecKm: 341),
                          weeks: [], sessions: [],
                          version: PlanLoad.VersionNote(
                              sourceLabel: "test",
                              importedUTC: "2026-08-10T00:00:00Z",
                              versionsPresent: 1),
                          rows: PlanLoad.TableRows(), skipped: 0),
            extras: .loaded(fuel: nil, warmup: nil, exercises: [], skipped: 0),
            athlete: .loaded(constants: AthleteConstants(hrMaxObserved: 181,
                                                         version: 1),
                             ftp: 270,
                             zones: [.init(index: 1, min: 0, max: 115)]),
            authored: .noneWritten, decisions: .noneRecorded,
            moves: .loaded(moves: [], skipped: 0),
            activities: .loaded(activities: [], skipped: 0))

        #expect(planned.canHydrate,
                "the plan, its trimmings and the athlete are all here")
        #expect(planned.firstEmpty == nil,
                "and none of the three that answer that question is empty")
        #expect(!planned.activities.holdsContent)
    }

    /// NOT AN AUTHORED FAMILY. That list means "stores keeping a file nobody
    /// may blank", and it exists because the athlete's writing cannot be
    /// fetched again. Activities can — that is what 378's `resetCache` path is.
    @Test("The activities are not an authored family")
    func theActivitiesAreNotAuthored() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(!b.activities.holdsContent, "empty, on an empty database")
        // ONE LITERAL ON ONE LINE. It was split across two adjacent literals,
        // which is C and Python and is NOT Swift — there is no implicit
        // concatenation, and it is a compile error rather than 366b's wrong
        // message. Caught by this patch's own guard. §12.123.8
        #expect(!b.emptyAuthoredFamilies.contains("activities"),
                "an empty activity table is a device before its first sync")
        #expect(b.emptyAuthoredFamilies == ["notes and commutes",
                                            "match decisions",
                                            "plan moves"],
                "the three that are authored, and only those")
    }

    // MARK: What 381 will invert

    /// **PINNED SO THE FLIP IS VISIBLE — §12.121.8.**
    ///
    /// `activities` is an independent comparison: the verifier's expectation
    /// comes from a store the database does not feed. 381 feeds it, and on
    /// that day this is not a number that moves — it is a claim that becomes
    /// false, exactly as `session moves` was at 377.
    ///
    /// `PlanMoveImportTests` asserted the same thing about the moves and 377d
    /// had to invert it four rounds later. This test exists so that inversion
    /// is expected rather than discovered.
    /// **THE INVERSION, AND IT IS FOUR COMPARISONS RATHER THAN ONE.**
    ///
    /// 379 pinned this so the day it stopped being evidence was a claim
    /// becoming false rather than a number quietly sliding. That day is 382,
    /// and the enumeration found two more comparisons taking their expectation
    /// from the same list: the id set and the volume sums. §12.126.2.
    ///
    /// **AND IT MISSED A THIRD — `activity fields`, added at 385.** The pin did
    /// exactly what it was built for and still did not catch this, because a
    /// pin asserts that a declared claim is true and cannot assert that the
    /// declaration is complete. That is §12.129's whole subject.
    ///
    /// **THE GLOBAL COUNT LIVES HERE AND NOWHERE ELSE NOW.** `B2ActivationTests`
    /// pinned it too, which meant every future slice broke a suite about a
    /// past one — 377d's four rounds in miniature. It is rescoped there.
    @Test("Four comparisons stopped being evidence, and this is where that is said")
    func fourComparisonsStoppedBeingEvidence() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        // 385 — AND `activity fields` IS THE ONE THIS LOOP DID NOT NAME.
        // Written at 382 from an enumeration that found three. The fourth reads
        // the same list and was counted as evidence until the device printed it
        // without a mark. §12.129.
        for name in ["activities", "activity identities",
                     "volume by discipline", "activity fields"] {
            let e = HydratedStores.entry(for: name)
            #expect(e != nil, "a comparison B3 made self-referential is undeclared")
            #expect(e?.slice == "B3")
            #expect(!r.independentChecks.contains { $0.name == name },
                    "its expectation now comes from a store the database feeds")
            #expect(r.selfReferentialChecks.contains { $0.name == name })
        }
        #expect(HydratedStores.all.count == 9,
                "B1's one, B2's four, B3's four")
        #expect(r.unmatchedHydratedEntries.isEmpty,
                "and every one of them names a comparison the verifier makes")
        #expect(!r.independentChecks.isEmpty,
                "B3 is not B9 — there is still evidence left")
    }
}
