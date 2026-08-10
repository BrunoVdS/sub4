//
//  DatabaseBootstrapTests.swift
//  Sub4CoreTests
//
//  D7 slice B1a, patch 343 / 343c.
//
//  THREE THINGS ARE UNDER TEST AND ONLY ONE OF THEM IS NEW CODE
//  -----------------------------------------------------------
//  `DatabaseBootstrap` is the read-direction mirror of `AppStores`, and its
//  tests are `AppStoresTests`' argument: pinning a field count does not prove
//  the forwarding, it makes adding a family something somebody has to
//  acknowledge.
//
//  The second is `PlanStore.decodeBundle`, and the assertion that matters there
//  is not that it works — it is that **it produces exactly what the singleton
//  holds**. That equality is what makes 343 a no-op today, and 343 being a
//  no-op today is the only reason it can be checked before 344 changes what
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
//  when there is simply no plan YET. So 343c removes the verdicts rather than
//  ship them meaning neither thing, and `theSiblingLoadsDisagree` below pins
//  the disagreement so that whoever resolves it in 344 does so on purpose.
//
//  WHAT IS DELIBERATELY NOT ASSERTED HERE: that the bundle is never used as a
//  fallback. That is a property of code 344 has not written yet, and asserting
//  it now would be a test of an absence — which passes for the wrong reason
//  until the thing it forbids could exist. It belongs in 344 beside the
//  hydration. §12.91.3.
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
    }

    // MARK: What an empty database produces

    /// A migrated database with no plan and no athlete rows.
    ///
    /// THIS ASSERTS THE SHAPE AND NOT A VERDICT. At 343 the bootstrap carries
    /// three loads and says nothing about them; whether an empty database is a
    /// launch this app can proceed from is 344's question, asked beside the
    /// code that acts on the answer.
    @Test("An empty database reads, and produces one load per family")
    func anEmptyDatabaseStillProducesEveryFamily() throws {
        let d = try db()
        let boot = DatabaseBootstrapReader.read(d)

        // Not `.loaded` — nothing has been imported — and not a failure
        // either. Each load names which it is, and the sentence proves it.
        #expect(boot.plan.weeks == nil, "an empty database holds no weeks to hand over")
        #expect(boot.athlete.constants == nil, "and no athlete profile")
        #expect(boot.diagnosticLines.count == DatabaseBootstrap.fieldCount + 1)
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
                "PlanLoad.noActiveVersion is not — same database, opposite answer, and 344 must name both questions")
        #expect(!boot.extras.isTrustworthy,
                "PlanExtrasLoad follows PlanLoad")
    }

    /// UNCONDITIONAL, one line per family, and the count matches the fields —
    /// §12.54.2. A family added without a line would be invisible in the paste.
    @Test("Every family reaches the paste")
    func everyFamilyHasALine() throws {
        let d = try db()
        let lines = DatabaseBootstrapReader.read(d).diagnosticLines
        #expect(lines.count == DatabaseBootstrap.fieldCount + 1,
                "a header and one line per family")
        let text = lines.joined(separator: "\n")
        #expect(text.contains("plan:"))
        #expect(text.contains("plan trimmings:"))
        #expect(text.contains("athlete:"))
    }

    // MARK: The failure the paste must not flatten

    /// WITH NO VERDICT ON THE TYPE, THE PASTE IS THE WHOLE INTERFACE — so the
    /// thing to prove is that a failed read still says so, in its own family's
    /// line, and does not read like an empty database.
    ///
    /// A bootstrap whose three unhappy paths printed the same sentence would
    /// send somebody through three repositories. §12.39.
    @Test("A failed read says so, per family, and does not read as empty")
    func aFailureIsVisiblePerFamily() {
        let boot = DatabaseBootstrap(plan: .unavailable,
                                     extras: .unavailable,
                                     athlete: .unavailable)
        let lines = boot.diagnosticLines
        #expect(lines.count == DatabaseBootstrap.fieldCount + 1)

        for line in lines.dropFirst() {
            #expect(line.contains("not open"),
                    "every family names the failure rather than reporting nothing")
        }

        let empty = DatabaseBootstrap(plan: .noActiveVersion(versionsPresent: 0),
                                      extras: .noActiveVersion(versionsPresent: 0),
                                      athlete: .missing)
        #expect(empty.diagnosticLines != lines,
                "an unreadable database must not paste identically to an empty one")
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

    // MARK: `decodeBundle` — the independence 344 depends on

    /// THE EQUALITY THAT MAKES 343 A NO-OP.
    ///
    /// The read-back now decodes the bundle itself instead of reading the
    /// store. Today those must be the same plan, because the store IS the
    /// decoded bundle — and that is precisely why this patch can be checked
    /// before 344 changes what the store serves. If this ever fails, the
    /// read-back has silently started comparing against something else.
    @MainActor
    @Test("The extracted decode equals what the store holds")
    func theDecodeEqualsTheStore() {
        let decoded = PlanStore.decodeBundle()
        #expect(decoded.error == nil, "the bundled plan must decode")

        let store = PlanStore.shared
        #expect(store.loadError == nil)
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
