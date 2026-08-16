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

    /// **THE GAP.** Seven read, six fed.
    @Test("The two counts have separated, and that separation is the slice")
    func theTwoCountsHaveSeparated() {
        #expect(PersistenceAuthority.Family.allCases.count == 7)
        #expect(PersistenceAuthority.hydratedFamilies.count == 6)
        #expect(PersistenceAuthority.Family.allCases.count
                > PersistenceAuthority.hydratedFamilies.count,
                "a family read before it is fed — that is what a slice is")
        #expect(!PersistenceAuthority.hydrates(.activities),
                "381 is the line that changes this, and it is one line")
    }

    /// The gap is exactly one family and it is the one this patch added. A
    /// second family falling out of `hydratedFamilies` would satisfy the
    /// counts above while meaning something completely different.
    @Test("The gap is exactly the activities and nothing else")
    func theGapIsExactlyTheActivities() {
        let read = Set(PersistenceAuthority.Family.allCases)
        let fed = PersistenceAuthority.hydratedFamilies
        #expect(read.subtracting(fed) == [.activities],
                "if anything else stopped hydrating, that is not this patch")
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
    @Test("The activity comparison is still evidence, and 381 is what ends it")
    func theActivityComparisonIsStillEvidence() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        #expect(HydratedStores.entry(for: "activities") == nil,
                "nothing feeds ActivityStore from the database yet")
        #expect(r.independentChecks.contains { $0.name == "activities" },
                "so its expectation is still read from the app's own files")
        #expect(HydratedStores.all.count == 5,
                "B1's one and B2's four; B3 adds the sixth at 381, not here")
    }
}
