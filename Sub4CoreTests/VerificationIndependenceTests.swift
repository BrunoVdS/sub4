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

    /// PATCH 386 — `reads:` HAS NO DEFAULT ON THE REAL TYPE, and this fixture
    /// gives it one so the suite keeps testing what it was written to test:
    /// the DECLARED classification, which is unchanged. `.databaseAlone` means
    /// these synthetic checks read no store, so the derivation says nothing
    /// about them and the cross-check stays silent here. The derivation has its
    /// own suite — `ExpectationProvenanceTests`.
    private func check(_ name: String,
                       table: String = "t",
                       expected: Int = 1,
                       found: Int = 1,
                       reads: ExpectationOrigin = .databaseAlone) -> VerificationCheck {
        .compare(name, table: table, expected: expected, found: found,
                 reads: reads)
    }

    private func report(_ checks: [VerificationCheck]) -> VerificationReport {
        VerificationReport(checks: checks, seconds: 0.01)
    }

    /// **A REPORT CONTAINING ONE CHECK PER DECLARED ENTRY, DERIVED FROM THE
    /// LIST — patch 358a.**
    ///
    /// `unmatchedHydratedEntries` is `HydratedStores.all` minus the checks this
    /// report contains, and `withheldReason` reports it before anything else.
    /// So a fixture that does not name every declared entry is a report
    /// withholding itself for a reason the test is not about — which is what
    /// happened to five tests in this file the day B2 declared three more.
    ///
    /// DERIVED RATHER THAN LISTED, and that is the whole point. `HydratedStores`
    /// grows again at B5 and at B9. A hand-listed fixture goes stale on each
    /// growth; this one does not, and neither do the assertions below it, which
    /// are written against `HydratedStores.all` rather than against a number.
    ///
    /// `omitting:` is for the ONE test that wants an unmatched entry. It takes a
    /// name rather than an index so the test reads as what it means, and the
    /// caller derives that name from the list rather than writing
    /// `heart-rate zones` — so a reordering does not break it either.
    private func covering(_ extra: [VerificationCheck] = [],
                          omitting: String? = nil) -> VerificationReport {
        report(HydratedStores.all.map(\.check)
                .filter { $0 != omitting }
                .map { check($0) }
               + extra)
    }

    // MARK: The list

    /// PINNED. `heart-rate zones` is the name `countChecks` gives the
    /// comparison and `AthleteStore.hrZones` is what B1 hydrated. If either
    /// moves, this fails here rather than on a device six weeks from now.
    ///
    /// THE COUNT MOVED AT 358 AND THIS TEST DID NOT CHANGE SHAPE. B2 declared
    /// three more; which three, and that they name real comparisons, is
    /// `B2ActivationTests`' business. What this suite still owns is B1's entry
    /// and the machinery around it.
    /// 5 UNTIL 382, WHICH DECLARED THREE — AND 9 AT 385, WHICH FOUND B3'S
    /// FOURTH. This is the suite that owns the total, and it is the second home
    /// the number has had — the first was `B2ActivationTests`, which had no
    /// business holding it.
    ///
    /// **THIS NUMBER MOVING IS NOT THE SAME AS THIS NUMBER BEING RIGHT.** It
    /// went 5 → 8 at 382 and every assertion in this file passed, over a list
    /// that was one short. Nothing here joins the other way — see
    /// `unmatchedHydratedEntries`, which reports an entry naming no comparison
    /// and has no counterpart reporting a comparison naming no entry. §12.129.
    @Test("The list names the comparison B1 made self-referential")
    func theListNamesTheZoneCheck() {
        #expect(HydratedStores.all.count == 9,
                "one from B1, four from B2, four from B3; B5 and B9 add more")
        let e = HydratedStores.entry(for: "heart-rate zones")
        #expect(e != nil)
        #expect(e?.store == "AthleteStore.hrZones")
        #expect(e?.slice == "B1")
        // 382 — WAS `== nil`. The activities are fed from the database now;
        // what this suite still owns is that B1's entry did not move.
        #expect(HydratedStores.entry(for: "activities")?.slice == "B3",
                "the activities are B3's, and B1's entry is untouched")
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
        // A SET, NOT A FIRST — patch 358. `selfReferentialChecks` filters
        // `checks`, so "first" is whichever declared comparison `countChecks`
        // happens to emit earliest. At B1 there was one entry and the two were
        // the same sentence; at B2 there are four and `notes` comes first,
        // which says nothing about anything. Pinning an emission order is how a
        // test starts failing for a reordering that changed no behaviour.
        #expect(Set(r.selfReferentialChecks.map(\.name))
                .contains("heart-rate zones"))
    }

    // MARK: The split

    /// PATCH 358 MOVED THIS AND THE MOVE IS THE EVIDENCE. `notes` was an
    /// independent comparison in this exact report until the flip; it reads
    /// `NotesStore.notes`, which now comes out of `user_note`. The same four
    /// checks, one fewer of them worth anything.
    @Test("The split follows the declared list and nothing else")
    func theSplitIsWhereItShouldBe() {
        // 382 — `activities` LEFT THIS FIXTURE, AND THE REASON IS THE PATCH.
        // These extras are the checks that are NOT declared hydrated, so that
        // the split has something to put on each side. `activities` was one
        // until this patch declared it; leaving it here would have added a
        // second check by that name, put both on the self-referential side,
        // and quietly emptied the independent one. `weather readings` is a
        // real comparison and stays independent — only its id FILTER moved.
        // §12.126.3.
        let r = covering([check("weather readings"), check("gear")])

        #expect(Set(r.independentChecks.map(\.name))
                == ["weather readings", "gear"],
                "both still read the app's own files")
        #expect(Set(r.selfReferentialChecks.map(\.name))
                == Set(HydratedStores.all.map(\.check)),
                "and the split is the declared list, not a copy of it")
        #expect(r.selfReferentialChecks.count == HydratedStores.all.count)

        // B2, NAMED. `notes` was an independent comparison in this suite until
        // the flip; it reads `NotesStore.notes`, which now comes out of
        // `user_note`. Asserted separately from the set above, because that set
        // would go on passing if `notes` had never been declared at all.
        #expect(!r.independentChecks.contains { $0.name == "notes" },
                "notes stopped being evidence at B2")

        #expect(r.passed)
        #expect(r.isTrustworthyEvidence, "two comparisons could still fail")
        #expect(r.withheldReason == nil)
    }

    /// **B9, AND THE REASON THE PATCH EXISTS.** Every comparison reads a store
    /// the database feeds. Every one of them agrees. None of it is evidence.
    @Test("A report of nothing but self-referential checks passes and is not believed")
    func nothingButSelfReferentialIsNotBelieved() {
        // EVERY DECLARED ENTRY AND NOTHING ELSE — which is what B9 is. Naming
        // one of them and leaving the rest unmatched would withhold the report
        // for the rename reason instead, and this test would pass on the wrong
        // sentence.
        let r = covering()
        #expect(r.passed, "every comparison agreed — that much is true")
        #expect(r.independentChecks.isEmpty)
        #expect(!r.isTrustworthyEvidence, "and none of them could have failed")
        #expect(r.withheldReason?.contains("could have disagreed") == true)
    }

    /// The rename case. The entry is declared, the check it names is gone, and
    /// everything downstream would read better than the truth.
    @Test("An entry naming no comparison withholds the whole report")
    func anEntryNamingNothingWithholdsIt() {
        // EXACTLY ONE MISSING, and which one is taken from the list rather than
        // written down. The test is about a name existing on one side only; it
        // is not about the zones, and it should not start failing because the
        // list was reordered.
        guard let gone = HydratedStores.all.first?.check else {
            Issue.record("nothing is declared hydrated, so nothing can be lost")
            return
        }
        let r = covering([check("weather readings"), check("gear")],
                         omitting: gone)
        #expect(r.passed)
        #expect(r.unmatchedHydratedEntries.count == 1)
        #expect(r.unmatchedHydratedEntries.first?.check == gone)
        #expect(!r.isTrustworthyEvidence)
        #expect(r.withheldReason?.contains("does not contain") == true)
    }

    /// A FAILING report is not a withheld one, and saying so would send
    /// somebody to look at the verifier instead of at the data.
    @Test("A failing report reports its failure and withholds nothing")
    func aFailureIsNotAWithholding() {
        // COVERING — patch 358a. The old fixture named `heart-rate zones` for
        // no reason and would have carried three unmatched entries after B2, so
        // it could have gone on passing on the wrong sentence. Now the ONLY
        // thing wrong with this report is the failure, which is what it is for.
        // 382 — `weather readings` FOR `activities`, and it is not cosmetic.
        // A failing check that is also DECLARED would leave this report with
        // no independent comparison at all, so `withheldReason` would name the
        // emptiness rather than being nil — and the assertion below would fail
        // for a reason that has nothing to do with what this test is about.
        let r = covering([check("weather readings", expected: 689, found: 688)])
        #expect(!r.passed)
        #expect(r.failures.count == 1)
        #expect(r.withheldReason == nil, "the failure is the story")
        #expect(!r.isTrustworthyEvidence)
    }

    // MARK: What is written down

    @Test("The ledger note carries how much of it was evidence")
    func theLedgerNoteCarriesTheCount() {
        // DERIVED — patch 358a, and this one was a real latent break rather
        // than a stale fixture. "3 comparisons · 2 independent" is only right
        // while exactly ONE of the three is declared. B5 declares gear; this
        // would then read "3 comparisons · 1 independent" and fail on a patch
        // that changed nothing whatever about the ledger note.
        // 382 — SAME SUBSTITUTION AS ABOVE. This note reads "N comparisons
        // · 2 independent", and 2 is the number of extras that are NOT
        // declared. `activities` became declared in this patch, so leaving it
        // here would make the note read 1 and fail a test about the ledger
        // sentence rather than about the list.
        let good = covering([check("weather readings"), check("gear")])
        #expect(good.ledgerNote
                == "\(HydratedStores.all.count + 2) comparisons, all agreed "
                 + "· 2 independent")

        let bad = report([check("weather readings", expected: 1, found: 2)])
        #expect(bad.ledgerNote == "1 of 1 comparisons disagreed",
                "a failing note is unchanged — it was never misleading")
    }

    /// §12.54.2. Both lines print on a healthy run, which is the case they
    /// exist for: twenty ticks and no independent count cannot be told from a
    /// verified migration.
    @Test("The paste says it on a healthy run, and marks the check")
    func thePasteSaysItUnconditionally() {
        // 382 — the one extra has to be a check the database does not feed,
        // or "1 independent" becomes 0 and the marked/unmarked assertion
        // below tests nothing.
        let lines = covering([check("weather readings")]).diagnosticLines
        #expect(lines.contains(where: { $0.contains("1 independent") }))
        #expect(lines.contains(where: { $0.contains("may be believed: yes") }))
        #expect(lines.contains(where: {
            $0.contains("heart-rate zones") && $0.contains("self-referential")
        }))
        #expect(lines.contains(where: {
            $0.contains("weather readings") && !$0.contains("self-referential")
        }), "a real comparison is not marked")
    }

    @Test("A withheld report says so in the paste, with the reason")
    func aWithheldReportSaysSoInThePaste() {
        let lines = covering().diagnosticLines
        #expect(lines.contains(where: { $0.contains("may be believed: no") }))
        #expect(lines.contains(where: { $0.contains("could have disagreed") }))
        #expect(lines.contains(where: { $0.contains("0 independent") }))
    }

    @Test("An unmatched entry is named in the paste in capitals")
    func anUnmatchedEntryIsNamedInThePaste() {
        let lines = report([check("weather readings")]).diagnosticLines
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
