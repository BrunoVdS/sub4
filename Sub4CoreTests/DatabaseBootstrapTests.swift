//
//  DatabaseBootstrapTests.swift
//  Sub4CoreTests
//
//  D7 slice B1a, patches 343 / 343c / 344.
//
//  FOUR THINGS ARE UNDER TEST AND ONLY ONE OF THEM IS NEW CODE
//  -----------------------------------------------------------
//  `DatabaseBootstrap` is the read-direction mirror of `AppStores`, and its
//  tests are `AppStoresTests`' argument: pinning a field count does not prove
//  the forwarding, it makes adding a family something somebody has to
//  acknowledge.
//
//  The second is `PlanStore.decodeBundle`, and the assertion that matters there
//  is not that it works — it is that **it produces exactly what the singleton
//  holds**. That equality is what makes 343 a no-op today, and 343 being a
//  no-op today is the only reason it can be checked before 345 changes what
//  the store serves.
//
//  THE THIRD ARRIVED BY FAILING. 343 gave the bootstrap an `isTrustworthy` and
//  a `firstFailure`, and `anEmptyDatabaseIsTrustworthy` failed on a freshly
//  migrated in-memory database — because the three sibling loads do not agree
//  about what the word means:
//
//      AthleteLoad.missing                     → isTrustworthy TRUE
//      PlanLoad.noActiveVersion(present: 0)    → isTrustworthy FALSE
//
//  Same empty database, opposite answers. Both are defensible against the
//  question `ReadBacks` asks each load in isolation, and twelve files depend on
//  that reading, so neither is being changed. What cannot survive is `&&`-ing
//  them: a launch must stop when the plan could not be READ and must not stop
//  when there is simply no plan YET.
//
//  THE FOURTH IS 344's ANSWER — `wasReadCleanly` and `canHydrate`, the two
//  questions spelled out with two names, on all three loads and on the value
//  that carries them. `theSiblingLoadsDisagree` stays, so the older word cannot
//  quietly change meaning underneath them.
//
//  WHAT IS DELIBERATELY NOT ASSERTED HERE: that the bundle is never used as a
//  fallback at launch. That is a property of code 345 has not written yet, and
//  asserting it now would be a test of an absence — which passes for the wrong
//  reason until the thing it forbids could exist. §12.91.3.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("The read direction assembles once")
struct DatabaseBootstrapTests {

    private func db() throws -> Sub4Database {
        try Sub4Database.inMemory(label: "bootstrap")
    }

    // MARK: The field count

    /// THE NUMBER A TEST HOLDS — `AppStores.fieldCount` makes the same
    /// argument in the write direction, where a forgotten field was a table
    /// that quietly stopped being imported. Here it would be a store that
    /// hydrates from nothing.
    ///
    /// ONE STRING LITERAL, NOT A CONCATENATION — `Comment` is
    /// `ExpressibleByStringLiteral` and `"a" + "b"` is an expression, not a
    /// literal, so it does not convert. Patch 343b.
    @Test("Three families at B1, and adding one is a decision")
    func theFieldCountIsPinned() {
        #expect(DatabaseBootstrap.fieldCount == 3,
                "plan, plan trimmings, athlete — bump this in the patch that adds a family")
        #expect(DatabaseBootstrap.diagnosticLineCount == 8,
                "a header, one line per family, and the four verdict lines")
    }

    // MARK: What an empty database produces

    /// A migrated database with no plan and no athlete rows.
    ///
    /// THE TWO VERDICTS SEPARATE HERE AND NOWHERE ELSE. Every read succeeded;
    /// no family holds anything. Before 344 those two facts shared one boolean
    /// and the pair could not both be told.
    @Test("An empty database reads cleanly and holds nothing")
    func anEmptyDatabaseReadsCleanlyAndHoldsNothing() throws {
        let d = try db()
        let boot = DatabaseBootstrapReader.read(d)

        #expect(boot.wasReadCleanly,
                "a successful read of an empty database is not a failure")
        #expect(boot.firstFault == nil)

        #expect(!boot.canHydrate, "and there is nothing here to hydrate from")
        #expect(boot.firstEmpty == "the plan", "in field order")

        #expect(boot.hydratablePlan == nil)
        #expect(boot.plan.weeks == nil, "no weeks to hand over")
        #expect(boot.athlete.constants == nil, "and no athlete profile")
    }

    /// THE FINDING, PINNED.
    ///
    /// This test exists to fail the day somebody changes one of the three
    /// `isTrustworthy` implementations. It is not endorsing the disagreement —
    /// it is making sure the resolution is visible in a diff rather than
    /// arriving as a launch that stops on a fresh install, or worse, one that
    /// does not stop on an unreadable plan. §12.15.
    @Test("The three sibling loads disagree about an empty database")
    func theSiblingLoadsDisagree() throws {
        let d = try db()
        let boot = DatabaseBootstrapReader.read(d)

        #expect(boot.athlete.isTrustworthy,
                "AthleteLoad.missing is trustworthy — its own comment says a fresh database is not a fault")
        #expect(!boot.plan.isTrustworthy,
                "PlanLoad.noActiveVersion is not — same database, opposite answer")
        #expect(!boot.extras.isTrustworthy,
                "PlanExtrasLoad follows PlanLoad")

        // And the 344 pair agrees with itself across all three.
        #expect(boot.plan.wasReadCleanly && boot.extras.wasReadCleanly
                && boot.athlete.wasReadCleanly,
                "the read succeeded on every family")
        #expect(!boot.plan.holdsContent && !boot.extras.holdsContent
                && !boot.athlete.holdsContent,
                "and no family holds anything")
    }

    // MARK: The verdicts on states a device has never been in

    /// `.noActiveVersion(versionsPresent: 3)` is NOT a clean read. Three
    /// versions stored and none active is a state somebody has to resolve,
    /// which is why the case carries the count rather than being a bare
    /// `.empty`.
    @Test("Versions stored with none active is a fault, not an empty database")
    func storedButInactiveIsAFault() {
        let boot = DatabaseBootstrap(plan: .noActiveVersion(versionsPresent: 3),
                                     extras: .noActiveVersion(versionsPresent: 3),
                                     athlete: .missing)
        #expect(!boot.wasReadCleanly)
        #expect(boot.firstFault?.contains("plan") == true)
        #expect(!boot.canHydrate)
    }

    /// A failure in a later family is still named, and named as ITSELF.
    @Test("The fault names the family it is in, not the first family")
    func theFaultNamesItsOwnFamily() {
        let boot = DatabaseBootstrap(plan: .noActiveVersion(versionsPresent: 0),
                                     extras: .noActiveVersion(versionsPresent: 0),
                                     athlete: .failed("disk I/O error"))
        #expect(!boot.wasReadCleanly)
        #expect(boot.firstFault?.contains("athlete") == true)
        #expect(boot.firstFault?.contains("disk I/O error") == true)
    }

    // MARK: The plan is two loads and one store

    /// ALL OR NOTHING. `PlanRepository` and `PlanExtrasRepository` are two
    /// families that can fail separately and one store. Hydrating with half
    /// would blank the Fuelling & race-day screen while every other figure
    /// stayed right — which is worse than not hydrating, because it looks fine.
    @Test("Half a plan is no plan")
    func halfAPlanIsNoPlan() {
        let loadedPlan = PlanLoad.loaded(
            meta: Meta(plan: "stored", week1Monday: "2026-07-27",
                       raceDate: "2027-03-21", targetTime: "04:00:00",
                       targetPaceSecKm: 341),
            weeks: [], sessions: [],
            version: PlanLoad.VersionNote(sourceLabel: "test",
                                          importedUTC: "2026-08-10T00:00:00Z",
                                          versionsPresent: 1),
            rows: PlanLoad.TableRows(), skipped: 0)

        let noExtras = DatabaseBootstrap(plan: loadedPlan,
                                         extras: .noActiveVersion(versionsPresent: 0),
                                         athlete: .missing)
        #expect(noExtras.hydratablePlan == nil,
                "the trimmings are missing, so there is no whole plan to give")

        let whole = DatabaseBootstrap(
            plan: loadedPlan,
            extras: .loaded(fuel: nil, warmup: nil, exercises: [], skipped: 0),
            athlete: .missing)
        // Bound rather than chained: `whole.hydratablePlan?.fuel` is a
        // `Fuel??`, and comparing THAT to nil asks about the outer optional —
        // the plan, not the fuelling section. Two different questions wearing
        // one `nil`.
        guard let assembled = whole.hydratablePlan else {
            Issue.record("both halves loaded, so a whole plan must assemble")
            return
        }
        #expect(assembled.meta.plan == "stored")
        #expect(assembled.fuel == nil,
                "a stored plan with no fuelling section is a real state, not an absence")
    }

    // MARK: The paste

    /// UNCONDITIONAL, one line per family plus the verdicts — §12.54.2. A
    /// family added without a line would be invisible in the paste.
    @Test("Every family and every verdict reaches the paste")
    func everyFamilyHasALine() throws {
        let d = try db()
        let lines = DatabaseBootstrapReader.read(d).diagnosticLines
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)
        let text = lines.joined(separator: "\n")
        #expect(text.contains("plan:"))
        #expect(text.contains("plan trimmings:"))
        #expect(text.contains("athlete:"))
        #expect(text.contains("every read succeeded: yes"))
        #expect(text.contains("every family holds data: no"))
        #expect(text.contains("first family with nothing: the plan"))
    }

    /// WITH NO STORE WIRED IN YET, THE PASTE IS THE WHOLE INTERFACE — so the
    /// thing to prove is that a failed read still says so, in its own family's
    /// line, and does not read like an empty database.
    @Test("A failed read says so, per family, and does not read as empty")
    func aFailureIsVisiblePerFamily() {
        let boot = DatabaseBootstrap(plan: .unavailable,
                                     extras: .unavailable,
                                     athlete: .unavailable)
        let lines = boot.diagnosticLines
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)

        for line in lines.dropFirst().prefix(DatabaseBootstrap.fieldCount) {
            #expect(line.contains("not open"),
                    "every family names the failure rather than reporting nothing")
        }

        let empty = DatabaseBootstrap(plan: .noActiveVersion(versionsPresent: 0),
                                      extras: .noActiveVersion(versionsPresent: 0),
                                      athlete: .missing)
        #expect(empty.diagnosticLines != lines,
                "an unreadable database must not paste identically to an empty one")
        #expect(empty.wasReadCleanly && !boot.wasReadCleanly,
                "and the verdicts must not read identically either")
    }

    /// `.failed` carries its reason all the way to the paste. A diagnostic that
    /// swallowed the underlying error would be §12.15's first instance again.
    @Test("A failed read carries its reason into the paste")
    func aFailedReadCarriesItsReason() {
        let boot = DatabaseBootstrap(plan: .failed("disk I/O error"),
                                     extras: .unavailable,
                                     athlete: .unavailable)
        #expect(boot.diagnosticLines.joined(separator: "\n").contains("disk I/O error"))
    }

    // MARK: `decodeBundle` — the independence 345 depends on

    /// THE EQUALITY THAT MAKES 343 A NO-OP.
    ///
    /// The read-back decodes the bundle itself instead of reading the store.
    /// Today those must be the same plan, because the store IS the decoded
    /// bundle — and that is precisely why this can be checked before 345
    /// changes what the store serves. If this ever fails, the read-back has
    /// silently started comparing against something else.
    @MainActor
    @Test("The extracted decode equals what the store holds")
    func theDecodeEqualsTheStore() {
        let decoded = PlanStore.decodeBundle()
        #expect(decoded.error == nil, "the bundled plan must decode")

        let store = PlanStore.shared
        #expect(store.loadError == nil)
        #expect(store.servedFrom == .files,
                "nothing hydrates the singleton until 345 wires the launch")
        #expect(decoded.plan.weeks.count == store.plan.weeks.count)
        #expect(decoded.plan.sessions.count == store.plan.sessions.count)
        #expect(decoded.plan.meta.raceDate == store.plan.meta.raceDate)
    }

    /// Two decodes of one resource agree. Cheap, and it is the property the
    /// read-back relies on every time it runs.
    @MainActor
    @Test("Decoding twice gives the same plan")
    func decodingIsStable() {
        let a = PlanStore.decodeBundle()
        let b = PlanStore.decodeBundle()
        #expect(a.error == nil && b.error == nil)
        #expect(a.plan.sessions.count == b.plan.sessions.count)
        #expect(a.plan.weeks.count == b.plan.weeks.count)
    }

    /// The bundled plan is not empty, so the read-back's other half is real.
    /// A decode that quietly produced `Plan.empty` would give the comparison
    /// nothing to disagree with — zero compared to zero, again.
    @MainActor
    @Test("The bundled plan is not empty")
    func theBundledPlanIsReal() {
        let decoded = PlanStore.decodeBundle()
        #expect(decoded.plan.weeks.count > 0)
        #expect(decoded.plan.sessions.count > 0)
    }
}
