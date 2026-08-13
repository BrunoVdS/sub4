//
//  VerificationIndependenceTests.swift
//  Sub4CoreTests
//
//  A check that reads a store the database feeds is not evidence —
//  patch 354, ADR-0003 §12.99.
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
//  THE ONE THAT WILL FIRE AT B5.
//  `everyDeclaredEntryNamesARealComparison` runs the real verifier over an
//  empty database and requires every `HydratedStores` entry to match a check
//  that actually exists. The list joins BY NAME. A typo, or a check renamed on
//  one side only, moves a self-referential comparison quietly back into the
//  evidence column — and this is the test that stops it.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Only a comparison that could fail is evidence")
@MainActor
struct VerificationIndependenceTests {

    // MARK: Fixtures

    private func check(_ name: String,
                       table: String = "t",
                       expected: Int = 1,
                       found: Int = 1) -> VerificationCheck {
        .compare(name, table: table, expected: expected, found: found)
    }

    private func report(_ checks: [VerificationCheck]) -> VerificationReport {
        VerificationReport(checks: checks, seconds: 0.01)
    }

    // MARK: The list

    /// PINNED. `heart-rate zones` is the name `countChecks` gives the
    /// comparison and `AthleteStore.hrZones` is what B1 hydrated. If either
    /// moves, this fails here rather than on a device six weeks from now.
    @Test("The list names the comparison B1 made self-referential")
    func theListNamesTheZoneCheck() {
        #expect(HydratedStores.all.count == 1,
                "B5 and B9 will each add one, on purpose")
        let e = HydratedStores.entry(for: "heart-rate zones")
        #expect(e != nil)
        #expect(e?.store == "AthleteStore.hrZones")
        #expect(e?.slice == "B1")
        #expect(HydratedStores.entry(for: "activities") == nil,
                "activities are read from the app's own files and still can")
    }

    /// **THE TRIPWIRE.** The real verifier, over an empty database, produces
    /// the real set of check names. Every declared entry must match one.
    @Test("Every declared entry names a comparison the verifier actually makes")
    func everyDeclaredEntryNamesARealComparison() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        #expect(r.unmatchedHydratedEntries.isEmpty,
                "an entry naming no comparison is a rename nobody finished")
        #expect(!r.checks.isEmpty)
        #expect(r.selfReferentialChecks.count == HydratedStores.all.count)
        #expect(r.independentChecks.count
                == r.checks.count - HydratedStores.all.count)
        #expect(r.selfReferentialChecks.first?.name == "heart-rate zones")
    }

    // MARK: The split

    @Test("The zone check is counted as self-referential and nothing else is")
    func theSplitIsWhereItShouldBe() {
        let r = report([check("activities"), check("gear"), check("notes"),
                        check("heart-rate zones")])
        #expect(r.independentChecks.count == 3)
        #expect(r.selfReferentialChecks.count == 1)
        #expect(r.selfReferentialChecks.first?.name == "heart-rate zones")
        #expect(r.passed)
        #expect(r.isTrustworthyEvidence)
        #expect(r.withheldReason == nil)
    }

    /// **B9, AND THE REASON THE PATCH EXISTS.** Every comparison reads a store
    /// the database feeds. Every one of them agrees. None of it is evidence.
    @Test("A report of nothing but self-referential checks passes and is not believed")
    func nothingButSelfReferentialIsNotBelieved() {
        let r = report([check("heart-rate zones")])
        #expect(r.passed, "every comparison agreed — that much is true")
        #expect(r.independentChecks.isEmpty)
        #expect(!r.isTrustworthyEvidence, "and none of them could have failed")
        #expect(r.withheldReason?.contains("could have disagreed") == true)
    }

    /// The rename case. The entry is declared, the check it names is gone, and
    /// everything downstream would read better than the truth.
    @Test("An entry naming no comparison withholds the whole report")
    func anEntryNamingNothingWithholdsIt() {
        let r = report([check("activities"), check("gear")])
        #expect(r.passed)
        #expect(r.unmatchedHydratedEntries.count == 1)
        #expect(r.unmatchedHydratedEntries.first?.check == "heart-rate zones")
        #expect(!r.isTrustworthyEvidence)
        #expect(r.withheldReason?.contains("does not contain") == true)
    }

    /// A FAILING report is not a withheld one, and saying so would send
    /// somebody to look at the verifier instead of at the data.
    @Test("A failing report reports its failure and withholds nothing")
    func aFailureIsNotAWithholding() {
        let r = report([check("activities", expected: 689, found: 688),
                        check("heart-rate zones")])
        #expect(!r.passed)
        #expect(r.failures.count == 1)
        #expect(r.withheldReason == nil, "the failure is the story")
        #expect(!r.isTrustworthyEvidence)
    }

    // MARK: What is written down

    @Test("The ledger note carries how much of it was evidence")
    func theLedgerNoteCarriesTheCount() {
        let good = report([check("activities"), check("gear"),
                           check("heart-rate zones")])
        #expect(good.ledgerNote == "3 comparisons, all agreed · 2 independent")

        let bad = report([check("activities", expected: 1, found: 2)])
        #expect(bad.ledgerNote == "1 of 1 comparisons disagreed",
                "a failing note is unchanged — it was never misleading")
    }

    /// §12.54.2. Both lines print on a healthy run, which is the case they
    /// exist for: twenty ticks and no independent count cannot be told from a
    /// verified migration.
    @Test("The paste says it on a healthy run, and marks the check")
    func thePasteSaysItUnconditionally() {
        let lines = report([check("activities"), check("heart-rate zones")])
            .diagnosticLines
        #expect(lines.contains(where: { $0.contains("1 independent") }))
        #expect(lines.contains(where: { $0.contains("may be believed: yes") }))
        #expect(lines.contains(where: {
            $0.contains("heart-rate zones") && $0.contains("self-referential")
        }))
        #expect(lines.contains(where: {
            $0.contains("activities") && !$0.contains("self-referential")
        }), "a real comparison is not marked")
    }

    @Test("A withheld report says so in the paste, with the reason")
    func aWithheldReportSaysSoInThePaste() {
        let lines = report([check("heart-rate zones")]).diagnosticLines
        #expect(lines.contains(where: { $0.contains("may be believed: no") }))
        #expect(lines.contains(where: { $0.contains("could have disagreed") }))
        #expect(lines.contains(where: { $0.contains("0 independent") }))
    }

    @Test("An unmatched entry is named in the paste in capitals")
    func anUnmatchedEntryIsNamedInThePaste() {
        let lines = report([check("activities")]).diagnosticLines
        #expect(lines.contains(where: {
            $0.contains("DECLARED HYDRATED AND NOT COMPARED")
                && $0.contains("heart-rate zones")
        }))
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
