//
//  VerificationIndependenceTests.swift
//  Sub4CoreTests
//
//  A check that reads a store the database feeds is not evidence —
//  patch 354, ADR-0003 §12.99. Derived rather than declared since 387,
//  §12.131.
//
//  WHAT IS TESTED HERE AND WHAT IS GUARDED INSTEAD
//  ----------------------------------------------
//  `SemanticVerifier.record` gates on `isTrustworthyEvidence`, and that one
//  line is the only route to `verified`. It is NOT tested here, deliberately: a
//  test would have to build a ledger row to make the positive case reachable,
//  and the negative case would pass whether the guard existed or not —
//  `verifyPending` returns false for a run id that is not there, so a test
//  asserting `record(...) == false` could not fail. §12.69 again, one level up.
//
//  So the line is held by `apply-354.py`, which greps for it by name and fails
//  the patch if it is relaxed back to `passed`. What IS tested here is the
//  thing that decides the answer, which is pure and exhaustible.
//
//  387 REWROTE THIS FILE ROUND THE DERIVATION, AND `covering()` DIED WITH THE
//  LIST.
//  358a built that fixture because `unmatchedHydratedEntries` withheld any
//  report not naming every declared entry, so every fixture here broke each
//  time `HydratedStores` grew. There is no list now: `selfReferentialChecks`
//  filters on each check's own `reads` against what the build is serving, and a
//  report satisfies nothing but itself.
//
//  THE THREE TESTS THAT WENT, AND WHY EACH STOPPED BEING POSSIBLE.
//  `everyDeclaredEntryNamesARealComparison` — there are no declared entries.
//  `ExpectationProvenanceTests.everyFieldIsCompared` is its derived successor
//  and already existed at 386. `anEntryNamingNothingWithholdsIt` — an entry
//  naming nothing cannot occur. `anUnmatchedEntryIsNamedInThePaste` — the line
//  it asserted is gone from `diagnosticLines`.
//
//  THE CLASSIFICATION NOW DEPENDS ON `sources`, AND THAT IS THE POINT.
//  `verify(db, activities: [])` in a test process finds NOTHING
//  self-referential, because nothing is hydrated in a test process. Every test
//  below that wants a comparison counted as self-referential says so, by
//  passing the fields this notional build feeds. Those tests used to lean on a
//  compile-time constant to simulate a runtime state. §12.131.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Only a comparison that could fail is evidence")
@MainActor
struct VerificationIndependenceTests {

    // MARK: Fixtures

    /// `reads:` HAS NO DEFAULT ON THE REAL TYPE — patch 386 — **AND IT NO LONGER
    /// HAS ONE HERE EITHER, WHICH IS A DEFECT REMOVED RATHER THAN A TIDY-UP.**
    ///
    /// It defaulted to `.databaseAlone`, and the comment above it said that
    /// meant *"the check reads no store at all, so it is independent under every
    /// `fed:` set below"*. Since 388 a residual is NOT independent — it is its
    /// own third bucket — so that default would hand a caller who wanted an
    /// ordinary check a report with an EMPTY evidence column, and every
    /// assertion about `isTrustworthyEvidence` in it would pass or fail for a
    /// reason that had nothing to do with its subject.
    ///
    /// That is exactly §12.130.7: three tests in the provenance suite turned on
    /// a condition they had already tripped, and the compiler could not see it.
    /// Every call in this file passed `reads:` explicitly already, so removing
    /// the default costs nothing and closes the door. §12.43's own argument
    /// about a default argument being a call site nobody writes — §12.95.4.
    private func check(_ name: String,
                       table: String = "t",
                       expected: Int = 1,
                       found: Int = 1,
                       reads: ExpectationOrigin) -> VerificationCheck {
        .compare(name, table: table, expected: expected, found: found,
                 reads: reads)
    }

    /// **WHAT THIS BUILD WOULD BE SERVING**, stated per test rather than read
    /// off a constant. `fed: []` is the honest default and it is what a test
    /// process really is.
    private func report(_ checks: [VerificationCheck],
                        fed: Set<ExpectationField> = []) -> VerificationReport {
        VerificationReport(checks: checks, seconds: 0.01,
                           sources: ExpectationSources(fedByTheDatabase: fed))
    }

    // MARK: The comparison B1 spent

    /// PINNED, AND AT ITS SOURCE NOW. `heart-rate zones` is the name
    /// `countChecks` gives the comparison; what B1 hydrated is `.zones`, and
    /// the check itself is what says so. This asserted a `HydratedStores` entry
    /// until 387 — a hand-written row in another file, joined to this name.
    ///
    /// **THE OLD VERSION ALSO PINNED THE TOTAL, AND THAT TOTAL WAS ONCE WRONG.**
    /// It went 5 → 8 at 382 and every assertion in this file passed over a list
    /// one entry short, because a pin asserts that a declaration is TRUE and
    /// cannot assert it is COMPLETE. §12.129. There is no total to pin now;
    /// completeness is `ExpectationProvenanceTests.theWholeMapIsPinned`, which
    /// holds every comparison's field and fails on one that is missing.
    @Test("The comparison B1 made self-referential says so itself")
    func theZoneCheckNamesItsField() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])
        let zones = try #require(r.checks.first { $0.name == "heart-rate zones" })

        #expect(zones.reads.field == .zones,
                "the expectation is AthleteStore.hrZones and the check says so")
        #expect(ExpectationField.zones.slice == "B1")
        #expect(ExpectationField.zones.storeDescription == "AthleteStore.hrZones")
        // AND IT IS NOT SELF-REFERENTIAL HERE, which is the honest answer in a
        // test process: nothing is hydrated, so nothing reads the database.
        // Before 387 this same call reported nine self-referential checks off a
        // compile-time list, whatever the process had actually loaded.
        #expect(!zones.isSelfReferential(given: .allFromFiles))
        #expect(zones.isSelfReferential(
            given: ExpectationSources(fedByTheDatabase: [.zones])))
    }

    // MARK: The split

    /// **THE SPLIT FOLLOWS THE SOURCES AND NOTHING ELSE.** Every check here is
    /// the same shape; the only thing deciding which side it lands on is the
    /// field it reads and whether this build feeds that field.
    @Test("The split follows the sources and nothing else")
    func theSplitIsWhereItShouldBe() {
        let r = report([
            check("notes", reads: .from(.notes)),
            check("activities", reads: .from(.activities, "counted")),
            check("weather readings", reads: .from(.weather)),
            check("gear", reads: .from(.gear))
        ], fed: [.notes, .activities])

        #expect(Set(r.independentChecks.map(\.name))
                == ["weather readings", "gear"],
                "both still read the app's own files")
        #expect(Set(r.selfReferentialChecks.map(\.name))
                == ["notes", "activities"],
                "and both of those read a field this build feeds")

        // B2, NAMED. `notes` was an independent comparison in this suite until
        // the flip; it reads `NotesStore.notes`, which comes out of `user_note`
        // now. Asserted separately from the set above, because that set would
        // go on passing if the field had never been fed at all.
        #expect(!r.independentChecks.contains { $0.name == "notes" },
                "notes stopped being evidence at B2")

        #expect(r.passed)
        #expect(r.isTrustworthyEvidence, "two comparisons could still fail")
        #expect(r.withheldReason == nil)
    }

    /// **B9, AND THE REASON THE ACCOUNTING EXISTS.** Every comparison reads a
    /// store the database feeds. Every one of them agrees. None of it is
    /// evidence.
    ///
    /// THIS FIXTURE HOLDS NO RESIDUAL, so it is the arm of `withheldReason` that
    /// says *every comparison reads a store the database feeds* — which is true
    /// here and false of a real B9 report. `CorrectionFamilyTests
    /// .aResidualAloneIsNotEvidence` owns the other arm, and the two exist
    /// separately because the sentences send a reader to different places.
    @Test("A report of nothing but self-referential checks passes and is not believed")
    func nothingButSelfReferentialIsNotBelieved() {
        let r = report([
            check("notes", reads: .from(.notes)),
            check("activities", reads: .from(.activities, "counted")),
            check("heart-rate zones", reads: .from(.zones))
        ], fed: [.notes, .activities, .zones])

        #expect(r.passed, "every comparison agreed — that much is true")
        #expect(r.independentChecks.isEmpty)
        #expect(r.residualChecks.isEmpty, "so the general arm is the right one")
        #expect(!r.isTrustworthyEvidence, "and none of them could have failed")
        #expect(r.withheldReason?.contains("could have disagreed") == true)
        #expect(r.withheldReason?.contains("no store at all") == false,
                "that arm belongs to a report holding a residual")
    }

    // MARK: The third bucket — patch 388, §12.132

    /// **THE THREE BUCKETS PARTITION THE CHECKS, AND THE PASTE'S OWN LINE IS
    /// WHAT MADE THIS WORTH ASSERTING.** Two numbers over three buckets is a
    /// line whose parts do not sum to its total, and a reader checking 12 + 9
    /// against 22 goes looking for a comparison that is not missing.
    @Test("Independent, self-referential and residual partition the checks")
    func theThreeBucketsPartitionTheChecks() {
        let r = report([
            check("notes", reads: .from(.notes)),
            check("gear", reads: .from(.gear)),
            check("unclaimed corrections", expected: 0, found: 0,
                  reads: .databaseAlone)
        ], fed: [.notes])

        #expect(r.independentChecks.map(\.name) == ["gear"])
        #expect(r.selfReferentialChecks.map(\.name) == ["notes"])
        #expect(r.residualChecks.map(\.name) == ["unclaimed corrections"])
        #expect(r.independentChecks.count + r.selfReferentialChecks.count
                + r.residualChecks.count == r.checks.count)
        // AND THE BUCKETS DO NOT OVERLAP, which the sum alone would not catch:
        // three collections of the right total sizes could still double-count
        // one check and drop another.
        let named = Set(r.independentChecks.map(\.name))
            .union(r.selfReferentialChecks.map(\.name))
            .union(r.residualChecks.map(\.name))
        #expect(named.count == r.checks.count, "no check is in two buckets")
    }

    /// A residual is not reclassified by what the build happens to be serving.
    /// `ExpectationSources` refuses to hold `.databaseAlone` at all, so there is
    /// no `fed:` set that can move this check anywhere.
    @Test("No set of fed fields can move a residual out of its bucket")
    func aResidualIsUnmovable() {
        let everything = Set(ExpectationField.allCases)
        let r = report([check("unclaimed corrections", expected: 0, found: 0,
                              reads: .databaseAlone)],
                       fed: everything)

        #expect(r.residualChecks.count == 1)
        #expect(r.independentChecks.isEmpty)
        #expect(r.selfReferentialChecks.isEmpty)
        #expect(!r.isTrustworthyEvidence,
                "a report of nothing but residuals proves nothing about the app")
    }

    /// The paste prints the third number, and it prints at zero — §12.54.2. A
    /// count that appears only when it is interesting cannot be told from a
    /// count nobody wired in.
    @Test("The paste carries the residual count, including when it is zero")
    func thePasteCarriesTheResidualCount() {
        // HOISTED, NOT WRITTEN INSIDE `#expect` — §12.71.9. A `+` of literals
        // inside a macro argument is one more expression for the type checker,
        // and this project has paid for that on a smaller one.
        let expectedWith = "  comparisons: 2 — 1 independent, 0 reading a store "
                         + "the database feeds, 1 reading no store at all"
        let expectedWithout = "  comparisons: 1 — 1 independent, 0 reading a "
                            + "store the database feeds, 0 reading no store at all"

        let with = report([
            check("gear", reads: .from(.gear)),
            check("unclaimed corrections", expected: 0, found: 0,
                  reads: .databaseAlone)
        ]).diagnosticLines
        #expect(with.contains(expectedWith))

        let without = report([check("gear", reads: .from(.gear))]).diagnosticLines
        #expect(without.contains(expectedWithout))
    }

    /// A FAILING report is not a withheld one, and saying so would send
    /// somebody to look at the verifier instead of at the data.
    @Test("A failing report reports its failure and withholds nothing")
    func aFailureIsNotAWithholding() {
        // THE FAILING CHECK IS INDEPENDENT AND THE SECOND ONE IS TOO, so the
        // ONLY thing wrong with this report is the failure. A report whose one
        // independent comparison is the failing one would still be withheld if
        // it passed, and the assertion below would be testing the wrong
        // sentence. 382 made this mistake in the other direction. §12.69.
        let r = report([
            check("weather readings", expected: 689, found: 688,
                  reads: .from(.weather)),
            check("gear", reads: .from(.gear)),
            check("notes", reads: .from(.notes))
        ], fed: [.notes])

        #expect(!r.passed)
        #expect(r.failures.count == 1)
        #expect(r.withheldReason == nil, "the failure is the story")
        #expect(!r.isTrustworthyEvidence)
    }

    // MARK: What is written down

    @Test("The ledger note carries how much of it was evidence")
    func theLedgerNoteCarriesTheCount() {
        // A PLAIN COUNT OF THIS FIXTURE'S OWN CHECKS — 387. It read
        // `HydratedStores.all.count + 2`, which was derived from the list so
        // that B5 and B9 could not break a test about a sentence. The fixture
        // states its own contents now, so there is nothing left to derive
        // from and nothing that can go stale.
        let good = report([
            check("notes", reads: .from(.notes)),
            check("weather readings", reads: .from(.weather)),
            check("gear", reads: .from(.gear))
        ], fed: [.notes])
        #expect(good.ledgerNote == "3 comparisons, all agreed · 2 independent")

        let bad = report([check("weather readings", expected: 1, found: 2,
                                reads: .from(.weather))])
        #expect(bad.ledgerNote == "1 of 1 comparisons disagreed",
                "a failing note is unchanged — it was never misleading")
    }

    /// §12.54.2. Every one of these lines prints on a healthy run, which is the
    /// case they exist for: twenty ticks and no independent count cannot be
    /// told from a verified migration.
    @Test("The paste says it on a healthy run, and marks the check")
    func thePasteSaysItUnconditionally() {
        let lines = report([
            check("heart-rate zones", reads: .from(.zones)),
            check("weather readings", reads: .from(.weather))
        ], fed: [.zones]).diagnosticLines

        #expect(lines.contains(where: { $0.contains("1 independent") }))
        #expect(lines.contains(where: { $0.contains("may be believed: yes") }))
        #expect(lines.contains(where: {
            $0.contains("heart-rate zones") && $0.contains("self-referential")
        }))
        #expect(lines.contains(where: {
            $0.contains("weather readings") && !$0.contains("self-referential")
        }), "a real comparison is not marked")

        // THE MARK CARRIES THE STORE AND THE SLICE, both derived. 386a's paste
        // read `· self-referential: AthleteStore.hrZones, hydrated at B1` off a
        // hand-written note; this is the same sentence from the field itself.
        #expect(lines.contains(where: {
            $0.contains("· self-referential: AthleteStore.hrZones, hydrated at B1")
        }))
    }

    /// **387'S REPLACEMENT FOR 386'S CROSS-CHECK LINE, AND IT IS A REPLACEMENT
    /// RATHER THAN A DELETION ON PURPOSE.** `derived from the stores: … agrees
    /// with the declared list` had nothing left to agree with. A row that
    /// vanishes cannot be told from a row nobody wired in — §12.54.2 — so the
    /// derivation states its own answer in the same place.
    @Test("The paste says which fields the database feeds, sorted")
    func thePasteNamesTheFedFields() {
        let lines = report([check("notes", reads: .from(.notes))],
                           fed: [.zones, .notes, .activities]).diagnosticLines

        #expect(lines.contains(
            "  fields fed by the database: 3 of 14 — activities, notes, zones"),
                "sorted, so two runs compare")

        // AND THE DENOMINATOR IS DERIVED. 14 is every field a comparison can
        // read — `allCases` less `.databaseAlone`, which names no store — so
        // B4 adding a field moves it without anybody editing this.
        #expect(ExpectationField.allCases.filter { $0 != .databaseAlone }.count
                == 14)
    }

    /// THE ZERO CASE, and it is not cosmetic: a build feeding nothing is what
    /// this project looked like before B1 and what it looks like after a
    /// revert. The line must still print, without a dangling dash.
    @Test("The fed-fields line prints when nothing is fed")
    func theFedFieldsLinePrintsAtZero() {
        let lines = report([check("gear", reads: .from(.gear))]).diagnosticLines
        #expect(lines.contains("  fields fed by the database: 0 of 14"))
    }

    @Test("A withheld report says so in the paste, with the reason")
    func aWithheldReportSaysSoInThePaste() {
        let lines = report([check("notes", reads: .from(.notes))],
                           fed: [.notes]).diagnosticLines
        #expect(lines.contains(where: { $0.contains("may be believed: no") }))
        #expect(lines.contains(where: { $0.contains("could have disagreed") }))
        #expect(lines.contains(where: { $0.contains("0 independent") }))
    }

    // MARK: The sixth ledger sentence

    @Test("The sixth answer exists, says the reason, and is not agreement")
    func theSixthAnswerExists() {
        let l = VerificationResult.Ledger.noIndependentEvidence(
            "every comparison reads a store the database feeds")
        #expect(!l.agreed, "only `marked` is agreement")
        #expect(l.line.contains("was not believed"))
        #expect(l.line.contains("every comparison reads a store"))
        #expect(l != .reportDidNotPass,
                "the report DID pass — saying otherwise sends somebody to the data")
    }
}
