//
//  HydrationDecisionTests.swift
//  Sub4CoreTests
//
//  D7 slice B1 — patch 345.
//
//  WHY THE DECISION IS A PURE FUNCTION
//  -----------------------------------
//  `PersistenceAuthority.derive` was made pure at 342 for a stated reason: two
//  of its four states have never occurred on a device and one of them never
//  should. The same is true here, more sharply. Reaching `.fault` on a real
//  phone means corrupting a 37 MB database on purpose; reaching `.nothingStored`
//  means deleting the plan rows out from under the app. Neither is a thing to
//  do to somebody's training record to find out whether a branch works.
//
//  So `Sub4Launch` holds no branch. It calls `decide` and does what it says,
//  and every combination is driven from here.
//
//  THE ONE THAT MATTERS MOST is `aFailedPlanReadIsRefusedAndCarriesNoPlan` —
//  §12.91.3's negative control, and the reason 344 could not write it. The
//  bundled plan is a SEED and never a FALLBACK: the database may hold a
//  different plan version, and every note, match decision and review change is
//  written against `plan_session.uid` values from the stored one. A rescue read
//  of `plan.json` after a failed database read would resolve those uids against
//  a plan nobody chose, and it would look completely harmless in a diff because
//  it is the same file the importer seeded from.
//
//  Testable now because the thing it forbids could finally exist: 345 is the
//  first patch in which a launch decides whether to give a store a plan.
//

import Testing
import Foundation
@testable import Sub4

@Suite("What a launch decides to do with what it read")
struct HydrationDecisionTests {

    // MARK: Fixtures

    /// Everything present and readable — the state Bruno's device is in.
    private func whole() -> DatabaseBootstrap {
        DatabaseBootstrap(plan: HydrationFixtures.loadedPlan(), extras: HydrationFixtures.loadedExtras(),
                          athlete: HydrationFixtures.loadedAthlete(),
                          authored: .noneWritten, decisions: .noneRecorded,
                          moves: .loaded(moves: [], skipped: 0),
                          activities: .loaded(activities: [], skipped: 0))
    }

    /// A migrated database nobody has imported into.
    private func empty() -> DatabaseBootstrap {
        DatabaseBootstrap(plan: .noActiveVersion(versionsPresent: 0),
                          extras: .noActiveVersion(versionsPresent: 0),
                          athlete: .missing,
                          authored: .noneWritten, decisions: .noneRecorded,
                          moves: .loaded(moves: [], skipped: 0),
                          activities: .loaded(activities: [], skipped: 0))
    }

    private func isHydrate(_ i: HydrationPlanner.Instruction) -> Bool {
        if case .hydrate = i { return true }
        return false
    }

    private func outcome(_ i: HydrationPlanner.Instruction) -> HydrationOutcome? {
        if case .leaveOnFiles(let o) = i { return o }
        return nil
    }

    // MARK: The gate

    /// FOUR MODES, AND ONLY TWO OF THEM HYDRATE.
    @Test("Which modes take their data from rows")
    func whichModesHydrate() {
        #expect(PersistenceMode.shadow("B1").hydratesFromDatabase)
        #expect(PersistenceMode.databaseAuthoritative.hydratesFromDatabase)
        #expect(!PersistenceMode.legacyAuthoritative.hydratesFromDatabase)
        // ONE LITERAL. `Comment` is ExpressibleByStringLiteral and a
        // concatenation is an expression, not a literal — patch 343b, and the
        // apply script now refuses this shape rather than trusting me.
        #expect(!PersistenceMode.blocked("corrupt").hydratesFromDatabase,
                "after activation an unreadable database is B9's recovery screen")
    }

    /// THE STATE EVERY LAUNCH IS IN UNTIL 346. A perfectly readable database,
    /// every family loaded, and the stores keep their files — because the
    /// constant says so and nothing else gets a vote.
    @Test("Legacy leaves the stores alone however good the database is")
    func legacyLeavesTheStoresAlone() {
        let i = HydrationPlanner.decide(mode: .legacyAuthoritative,
                                        bootstrap: whole())
        #expect(!isHydrate(i))
        guard case .notWanted(let why)? = outcome(i) else {
            Issue.record("legacy must leave the stores on their files")
            return
        }
        #expect(why.contains("the app's own files"),
                "and it carries the mode's own sentence, so the paste stands alone")
    }

    @Test("A blocked launch hydrates nothing")
    func blockedHydratesNothing() {
        let i = HydrationPlanner.decide(mode: .blocked("the database is activated "
                                                       + "and could not be opened"),
                                        bootstrap: whole())
        #expect(!isHydrate(i))
        if case .notWanted? = outcome(i) {} else {
            Issue.record("blocked is not a hydration and not a fault")
        }
    }

    // MARK: The happy path

    @Test("A slice under test takes the stored plan and the stored athlete")
    func aSliceUnderTestHydrates() {
        let i = HydrationPlanner.decide(mode: .shadow("B1 — the plan, the athlete "
                                                      + "and the constants"),
                                        bootstrap: whole())
        guard case .hydrate(let plan, let constants, let zones, let ftp,
                            let authored, let decisions,
                            _, let storedActivities) = i else {
            Issue.record("every family loaded, so the stores must be fed")
            return
        }
        // PATCH 358, AND THESE TWO LINES CHANGED MEANING WITHOUT CHANGING.
        //
        // At 357b nil had two causes — the build did not hydrate these
        // families, and the fixture held nothing. The flip removed the first,
        // so what they pin now is the SECOND ON ITS OWN: a family that read
        // cleanly and holds nothing reaches the planner as nil rather than as
        // an empty payload, EVEN THOUGH THIS BUILD WANTS IT.
        //
        // That check is the only thing standing between an empty database and
        // a blanked `notes.json`, and until the flip it could not be tested in
        // isolation because the build refused the family anyway. §12.8.1.
        // `B2ActivationTests.anEmptyFamilyStillHandsOverNil` tests it from the
        // bootstrap end; this is the planner end.
        #expect(authored == nil,
                "clean and empty is not something to hydrate a store from")
        #expect(decisions == nil, "the same, for the match decisions")
        // PATCH 380. THE FOURTH PAYLOAD, NIL FOR THE FIRST OF THOSE TWO
        // REASONS RATHER THAN THE SECOND: this build does not feed the
        // activities at all, and 381 is the line that changes that.
        //
        // PATTERN-MATCHED RATHER THAN `== nil`. `[Activity]?` compared to nil
        // is a call to `Optional.==` and needs `Activity: Equatable`, whose
        // synthesised conformance is MainActor-isolated in this target —
        // `ActivityLoad`'s header records that at 289a, and 322a is what
        // ignoring it costs. This suite is not MainActor.
        if case .some = storedActivities {
            Issue.record("this build must not feed the activities yet")
        }
        #expect(plan.meta.plan == "stored", "the STORED plan, not the bundled one")
        #expect(plan.sessions.count == 1)
        #expect(constants.hrMaxObserved == 181)
        #expect(zones.count == 2)
        #expect(ftp == 270)
    }

    @Test("An activated database hydrates by the same route")
    func activatedHydratesToo() {
        #expect(isHydrate(HydrationPlanner.decide(mode: .databaseAuthoritative,
                                                  bootstrap: whole())),
                "B9 changes which mode is reached, not what happens in it")
    }

    // MARK: §12.91.3 — the negative control

    /// **THE ONE THAT MATTERS.** A failed plan read produces NO plan, and
    /// nothing in the instruction can be mistaken for one.
    ///
    /// The bundle is a seed and never a fallback. A rescue read of `plan.json`
    /// here would resolve every stored note, match decision and review change
    /// against a plan version nobody chose — and would look harmless in a diff,
    /// because it is the same file the importer seeded from. The apply script
    /// guards the call sites; this guards the decision.
    @Test("A failed plan read is refused and carries no plan")
    func aFailedPlanReadIsRefusedAndCarriesNoPlan() {
        let broken = DatabaseBootstrap(plan: .failed("database disk image is malformed"),
                                       extras: HydrationFixtures.loadedExtras(),
                                       athlete: HydrationFixtures.loadedAthlete(),
                                       authored: .noneWritten,
                                       decisions: .noneRecorded,
                                       moves: .loaded(moves: [], skipped: 0),
                                       activities: .loaded(activities: [], skipped: 0))
        let i = HydrationPlanner.decide(mode: .shadow("B1"), bootstrap: broken)

        #expect(!isHydrate(i), "no plan may leave this function")
        guard case .fault(let why)? = outcome(i) else {
            Issue.record("an unreadable plan is a fault, not an empty database")
            return
        }
        #expect(why.contains("plan"))
        #expect(why.contains("malformed"), "and it carries the reason")
        #expect(outcome(i)?.isFault == true, "which is what B9 blocks on")
    }

    /// ORDER MATTERS. Broken AND empty is a FAULT — the two sentences send a
    /// reader to completely different places, and "nothing stored" would point
    /// at an import that has not run rather than at a database that cannot be
    /// read. §12.15.
    @Test("A fault outranks an empty family")
    func aFaultOutranksAnEmptyFamily() {
        let both = DatabaseBootstrap(plan: .failed("I/O error"),
                                     extras: .noActiveVersion(versionsPresent: 0),
                                     athlete: .missing,
                                     authored: .noneWritten,
                                     decisions: .noneRecorded,
                                     moves: .loaded(moves: [], skipped: 0),
                                     activities: .loaded(activities: [], skipped: 0))
        let i = HydrationPlanner.decide(mode: .shadow("B1"), bootstrap: both)
        #expect(outcome(i)?.isFault == true)
    }

    // MARK: Nothing stored is not a fault

    @Test("An empty database is refused without being called a failure")
    func anEmptyDatabaseIsNotAFailure() {
        let i = HydrationPlanner.decide(mode: .shadow("B1"), bootstrap: empty())
        #expect(!isHydrate(i))
        guard case .nothingStored(let who)? = outcome(i) else {
            Issue.record("a fresh install is not a fault")
            return
        }
        #expect(who == "the plan", "named, in field order")
        #expect(outcome(i)?.isFault == false)
    }

    /// HALF A PLAN IS NO PLAN. The trimmings failing to be there blanks the
    /// Fuelling & race-day screen while every other figure stays right — worse
    /// than not hydrating, because it looks fine.
    @Test("A plan with no trimmings is not hydrated")
    func aPlanWithNoTrimmingsIsNotHydrated() {
        let half = DatabaseBootstrap(plan: HydrationFixtures.loadedPlan(),
                                     extras: .noActiveVersion(versionsPresent: 0),
                                     athlete: HydrationFixtures.loadedAthlete(),
                                     authored: .noneWritten,
                                     decisions: .noneRecorded,
                                     moves: .loaded(moves: [], skipped: 0),
                                     activities: .loaded(activities: [], skipped: 0))
        let i = HydrationPlanner.decide(mode: .shadow("B1"), bootstrap: half)
        #expect(!isHydrate(i))
        #expect(outcome(i)?.isFault == false, "absent trimmings are not a read failure")
    }

    /// The plan is fine and the athlete has never been imported. Still refused,
    /// because `apply` feeds three stores in one step and a launch that fed two
    /// of them would leave the app in a state no test describes.
    @Test("A stored plan with no athlete is not hydrated either")
    func aStoredPlanWithNoAthleteIsNotHydrated() {
        let i = HydrationPlanner.decide(
            mode: .shadow("B1"),
            bootstrap: DatabaseBootstrap(plan: HydrationFixtures.loadedPlan(),
                                         extras: HydrationFixtures.loadedExtras(),
                                         athlete: .missing,
                                         authored: .noneWritten,
                                         decisions: .noneRecorded,
                                         moves: .loaded(moves: [], skipped: 0),
                                         activities: .loaded(activities: [], skipped: 0)))
        #expect(!isHydrate(i))
        guard case .nothingStored(let who)? = outcome(i) else {
            Issue.record("a missing profile is not a fault")
            return
        }
        #expect(who == "the athlete")
    }

    // MARK: The paste

    /// FOUR OUTCOMES, FOUR DIFFERENT SENTENCES — §12.54.2. Two outcomes that
    /// read alike in a paste are one outcome as far as anybody reading it is
    /// concerned, and three of these four mean "the stores kept their files".
    @Test("Every outcome says something a reader can act on")
    func everyOutcomeReadsDifferently() {
        let lines = [
            HydrationOutcome.notWanted("the app's own files").line,
            HydrationOutcome.fault("the plan — could not be read").line,
            HydrationOutcome.nothingStored("the plan").line,
            HydrationOutcome.hydrated("the plan and the athlete").line,
        ]
        #expect(Set(lines).count == 4, "no two outcomes paste identically")
        for l in lines { #expect(!l.isEmpty) }
        #expect(lines[1].contains("REFUSED"),
                "the one that means something is wrong looks like it")
    }

    /// Only one of the four is a fault, and `isFault` is what B9 will block on.
    /// Getting it wrong in either direction is a launch that stops on a fresh
    /// install, or one that does not stop on an unreadable database.
    @Test("Exactly one outcome is a fault")
    func exactlyOneOutcomeIsAFault() {
        #expect(HydrationOutcome.fault("x").isFault)
        #expect(!HydrationOutcome.notWanted("x").isFault)
        #expect(!HydrationOutcome.nothingStored("x").isFault)
        #expect(!HydrationOutcome.hydrated("x").isFault)
    }
}
