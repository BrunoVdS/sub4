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

    /// **THE GAP IS CLOSED FOR B3 — patch 382, and this is the inversion 379
    /// wrote this test to make visible.** `.activities` is read AND fed, and
    /// the line that did it is one line in `PersistenceMode`.
    ///
    /// **RESCOPED AT 394, AND IT IS §12.126.6 HAPPENING TO THE SUITE THAT
    /// QUOTED IT.** This asserted `Family.allCases.count ==
    /// hydratedFamilies.count` and called it "the flip" — a GLOBAL claim in a
    /// suite about one slice. It was true from 382 to 393 and B4's groundwork
    /// makes it false on purpose: nine families read, seven fed, and **that gap
    /// IS the slice**. 382 wrote exactly this criticism of `B2ActivationTests`
    /// ("four global figures in a suite about one slice… every later slice
    /// breaks all four, and the breakage says nothing about B2") and then left
    /// the same shape here.
    ///
    /// What B3 owns is that ITS family is read and fed. The global counts have
    /// one home — RULE 5, which derives both from the source.
    @Test("The activities are read and fed, and that is the flip")
    func theActivitiesAreReadAndFed() {
        #expect(PersistenceAuthority.Family.allCases.contains(.activities))
        #expect(PersistenceAuthority.hydrates(.activities),
                "and the line that did it is one line in PersistenceMode")
    }

    /// **NOTHING IS FED THAT IS NOT READ, AND THAT DIRECTION STILL HOLDS FOR
    /// EVER.** The other one does not: a family read before it is fed is what
    /// every slice looks like between its groundwork and its flip, and 394 has
    /// two of them.
    ///
    /// So the subtraction that survives is the one whose emptiness is a real
    /// invariant — a store fed from a family the bootstrap never read would be
    /// a store hydrating from nothing, which is `Sub4Launch`'s worst failure.
    /// The other subtraction is now NAMED rather than asserted empty, because
    /// what it holds is the slice in flight.
    /// **398 CLOSED THE GAP AND THIS ASSERTION INVERTED**, which is what a
    /// slice looks like from a test's side. It read `[.details, .traces]` from
    /// 394 to 397 and reads empty now. Kept as an inversion rather than deleted:
    /// the day B5 declares `.gear` without feeding it, this fails and names it.
    @Test("Nothing is fed that is not read, and nothing read is unfed")
    func nothingIsFedThatIsNotRead() {
        let read = Set(PersistenceAuthority.Family.allCases)
        let fed = PersistenceAuthority.hydratedFamilies
        #expect(fed.subtracting(read).isEmpty,
                "a store fed from a family nobody read hydrates from nothing")
        #expect(read.subtracting(fed).isEmpty,
                "B4 closed at 398 — a family declared and not fed is the next slice in flight")
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
        let r = try SemanticVerifier.verify(
            db, activities: [],
            sources: ExpectationSources(fedByTheDatabase: [.activities]))

        // 385 — AND `activity fields` IS THE ONE THIS LOOP DID NOT NAME.
        // Written at 382 from an enumeration that found three. The fourth reads
        // the same list and was counted as evidence until the device printed it
        // without a mark. §12.129.
        //
        // 387 — IT ASKS THE CHECK NOW, NOT A LIST. `HydratedStores.entry(for:)`
        // joined this name to a row somebody typed in another file; the check
        // carries the answer at its own construction site and the compiler will
        // not let a new one omit it.
        for name in ["activities", "activity identities",
                     "volume by discipline", "activity fields"] {
            let c = r.checks.first { $0.name == name }
            #expect(c != nil, "a comparison B3 made self-referential is missing")
            #expect(c?.reads.field == .activities,
                    "its expectation comes from a store the database feeds")
            #expect(!r.independentChecks.contains { $0.name == name })
            #expect(r.selfReferentialChecks.contains { $0.name == name })
        }
        // THE TOTAL WENT WITH THE LIST — 387. It read
        // `HydratedStores.all.count == 9`, and that number was the LIST's, not
        // the verifier's: it stood at 8 for three patches while nine
        // comparisons read a hydrated store, and every assertion in this file
        // passed over it. §12.129, and `theWholeMapIsPinned` is the successor
        // that can fail on incompleteness.
        #expect(ExpectationField.activities.slice == "B3",
                "the activities are B3's")
        #expect(r.selfReferentialChecks.count == 4,
                "and this build feeds one field, which four comparisons read")
        #expect(!r.independentChecks.isEmpty,
                "B3 is not B9 — there is still evidence left")
    }
}
