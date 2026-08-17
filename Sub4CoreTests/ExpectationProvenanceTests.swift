//
//  ExpectationProvenanceTests.swift
//  Sub4CoreTests
//
//  Where a comparison's expectation came from, derived rather than declared —
//  patch 386, ADR-0003 §12.130.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  `HydratedStores` is a list, kept by hand, in a different file from the
//  comparisons it classifies. It joins to the checks BY NAME and its only
//  tripwire — `unmatchedHydratedEntries` — points one way: an ENTRY naming no
//  check. The damage runs the other way. A CHECK reading a store the database
//  feeds, which nobody added to the list, counts as evidence in silence, and
//  `activity fields` did exactly that from patch 382 to 385.
//
//  386 derives the same answer from the stores themselves and cross-checks the
//  two. It does NOT yet replace the list: `selfReferentialChecks` and
//  `independentChecks` still read `HydratedStores`, unchanged, so every
//  assertion written against them still means what it meant. What is new is
//  `undeclaredSelfReferential`, which fails `isTrustworthyEvidence` when the
//  derivation finds a self-referential comparison the list does not name.
//
//  387 makes the derivation operative and deletes the list. This patch is the
//  negative control that has to pass on the device first — the same order 381
//  and 382 were done in, and for the same reason.
//
//  THE ONE-DIRECTIONAL CHECK IS DELIBERATE, AND `theOppositeIsNotAFault` IS
//  WHERE THAT IS ASSERTED. Declared-but-not-derived is what reverting a slice
//  looks like: take `.activities` out of `hydratedFamilies` and the entry stays
//  while the store goes back to its file. Reversibility by deleting one family
//  is a property this whole ladder rests on, and a build that failed
//  verification for using the escape hatch would have no escape hatch.
//

import Testing
import Foundation
@testable import Sub4

@Suite("An expectation says where it came from")
@MainActor
struct ExpectationProvenanceTests {

    // MARK: Fixtures

    private func check(_ name: String,
                       reads: ExpectationOrigin,
                       expected: Int = 1,
                       found: Int = 1) -> VerificationCheck {
        .compare(name, table: "t", expected: expected, found: found,
                 reads: reads)
    }

    private func report(_ checks: [VerificationCheck],
                        fed: Set<ExpectationField>) -> VerificationReport {
        VerificationReport(checks: checks, seconds: 0.01,
                           sources: ExpectationSources(fedByTheDatabase: fed))
    }

    /// **ONE CHECK PER DECLARED ENTRY, SO THE CONDITION UNDER TEST IS THE ONE
    /// THAT DECIDES — patch 386a.**
    ///
    /// `isTrustworthyEvidence` has four conditions. A report built from two
    /// synthetic checks leaves all nine `HydratedStores` entries unmatched, so
    /// it is withheld by 358a's condition before this patch's is ever
    /// consulted. A test asserting `!isTrustworthyEvidence` over such a report
    /// passes whether 386 exists or not, and the two asserting the opposite
    /// fail for a reason that has nothing to do with them.
    ///
    /// §12.69, in the suite written to hold §12.69. It was wrong in the first
    /// cut of this file and the re-read found it.
    private func covering(_ extras: [VerificationCheck],
                          reading: [String: ExpectationOrigin] = [:],
                          fed: Set<ExpectationField>) -> VerificationReport {
        let declared = HydratedStores.all.map {
            check($0.check, reads: reading[$0.check] ?? .databaseAlone)
        }
        return VerificationReport(
            checks: declared + extras, seconds: 0.01,
            sources: ExpectationSources(fedByTheDatabase: fed))
    }

    // MARK: The field is the unit, and the reason is two stores

    /// **THE FINDING THAT SET THE GRANULARITY.** `ActivityStore.servedFrom`
    /// reads `.database` and that sentence is about the activities — 381 wrote
    /// the property for them. The same store also hands out the rejection
    /// receipts and the sync cursor, and both live in `UserDefaults` until B8.
    /// `AthleteStore` is split the other way round, and says so in its own
    /// `servedFrom`.
    ///
    /// A store-level derivation would move `gear` into the self-referential
    /// column and `refused recordings` and `sync position` with it. Three
    /// comparisons wrongly discounted is not better than one wrongly counted.
    @Test("A store serving two things from two places gets two answers")
    func theFieldIsTheUnitNotTheStore() {
        let fed: Set<ExpectationField> = [.activities, .zones]
        let r = report([
            check("activities", reads: .from(.activities)),
            check("refused recordings", reads: .from(.rejections)),
            check("sync position", reads: .from(.syncPosition)),
            check("heart-rate zones", reads: .from(.zones)),
            check("gear", reads: .from(.gear))
        ], fed: fed)

        #expect(Set(r.derivedSelfReferential.map(\.name))
                == ["activities", "heart-rate zones"],
                "only the two fields this build feeds")
        #expect(!r.derivedSelfReferential.contains { $0.name == "gear" },
                "gear is the file half of AthleteStore until B5")
        #expect(!r.derivedSelfReferential.contains { $0.name == "sync position" },
                "the cursor is UserDefaults until B8")
    }

    // MARK: The tripwire that 382 did not have

    /// **BROKEN ON PURPOSE — §12.69.** A comparison reading a field the
    /// database feeds, under a name `HydratedStores` does not declare. This is
    /// the shape `activity fields` had for three patches, and before 386
    /// nothing in this repository could see it.
    @Test("A self-referential comparison nobody declared fails the report")
    func theUndeclaredOneIsCaught() {
        let r = covering([
            check("gear", reads: .from(.gear)),
            check("a comparison no list names",
                  reads: .from(.activities, "the shape 382 missed"))
        ], fed: [.activities])

        #expect(r.passed, "every comparison agreed — that is not the question")
        // THE OTHER THREE CONDITIONS ARE SATISFIED, asserted rather than
        // assumed. Without these two lines the assertion below would pass over
        // a report withheld for a reason this patch did not add.
        #expect(r.unmatchedHydratedEntries.isEmpty,
                "every declared entry is present, so that is not what withholds it")
        #expect(!r.independentChecks.isEmpty,
                "and something could still have disagreed")
        #expect(r.undeclaredSelfReferential.count == 1)
        #expect(r.undeclaredSelfReferential.first?.name
                == "a comparison no list names")
        #expect(!r.isTrustworthyEvidence,
                "it agreed and it could not have disagreed, and nothing said so")
        #expect(r.withheldReason != nil)
    }

    /// And it passes when the same comparison IS declared — otherwise the test
    /// above proves only that the property is never empty.
    @Test("A declared self-referential comparison is not a disagreement")
    func theDeclaredOneIsFine() {
        let r = covering([check("gear", reads: .from(.gear))],
                         reading: ["activities": .from(.activities)],
                         fed: [.activities])

        #expect(r.derivedSelfReferential.contains { $0.name == "activities" })
        #expect(r.undeclaredSelfReferential.isEmpty)
        #expect(r.isTrustworthyEvidence, "gear could still have disagreed")
    }

    /// Declared and not derived is the escape hatch, not a fault. See the
    /// header.
    @Test("Declared but no longer fed is a reverted slice, not a defect")
    func theOppositeIsNotAFault() {
        let r = covering([check("gear", reads: .from(.gear))],
                         reading: ["activities": .from(.activities)],
                         fed: [])

        #expect(r.derivedSelfReferential.isEmpty,
                "nothing is fed from the database in this report")
        #expect(r.undeclaredSelfReferential.isEmpty,
                "and the declared list being ahead of the stores is reversal")
        #expect(r.isTrustworthyEvidence)
    }

    // MARK: The real verifier

    /// **EVERY FIELD IS NAMED BY A COMPARISON.** The mirror of
    /// `unmatchedHydratedEntries`, and the only version of it that can be
    /// derived: a field this app reads and no comparison looks at is a store
    /// nothing verifies.
    @Test("Every field except the database-alone one names a comparison")
    func everyFieldIsCompared() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [],
                                            sources: ExpectationSources.allFromFiles)

        let named = Set(r.checks.map(\.reads.field))
        // `.syncPosition` IS EXEMPT AND THE REASON IS IN `verify`: the cursor
        // check runs only `if let syncState`, and this call passes none. It is
        // the one conditional comparison in the verifier. `.databaseAlone` is
        // exempt because it names no store.
        let exempt: Set<ExpectationField> = [.databaseAlone, .syncPosition]
        for field in ExpectationField.allCases where !exempt.contains(field) {
            #expect(named.contains(field),
                    "a field the app reads and no comparison looks at")
        }
        // And the exempt one is still reachable — asserted separately so the
        // exemption cannot quietly become a field nothing ever compares.
        let withCursor = try SemanticVerifier.verify(
            db, activities: [],
            syncState: SyncState(sourceID: Sub4Import.sourceID, cursor: nil,
                                 lastSync: nil, lastResult: nil),
            sources: ExpectationSources.allFromFiles)
        #expect(withCursor.checks.contains { $0.reads.field == .syncPosition },
                "the cursor comparison names its field when it runs")
    }

    /// The four B3 comparisons, derived rather than listed. This is the
    /// assertion `ActivitiesAreReadTests` could not make, because it starts
    /// from the list.
    @Test("The four comparisons reading the activities are found by derivation")
    func theFourAreDerived() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [],
                                            sources: ExpectationSources(fedByTheDatabase: [.activities]))

        #expect(Set(r.derivedSelfReferential.map(\.name))
                == ["activities", "activity identities",
                    "activity fields", "volume by discipline"],
                "the count, the id set, the fingerprint and the sums")
        #expect(r.undeclaredSelfReferential.isEmpty,
                "and 385 declared all four, so the two mechanisms agree")
    }

    // MARK: The type's own edges

    /// A residual has no store, so it can never be self-referential — and it
    /// must not be able to get into the set by accident.
    @Test("The database-alone case cannot be fed by the database")
    func theResidualIsNeverSelfReferential() {
        let s = ExpectationSources(fedByTheDatabase: [.databaseAlone, .notes])
        #expect(!s.isFedByTheDatabase(.databaseAlone))
        #expect(s.isFedByTheDatabase(.notes))

        let r = report([check("unclaimed corrections", reads: .databaseAlone)],
                       fed: [.databaseAlone])
        #expect(r.derivedSelfReferential.isEmpty)
    }

    /// The slice each field belongs to, asserted where it is read from. These
    /// are the strings the paste prints and the strings B4, B5, B7 and B8 will
    /// each turn from a promise into a store's answer.
    @Test("Each field names the slice that owns it")
    func eachFieldNamesItsSlice() {
        #expect(ExpectationField.activities.slice == "B3")
        #expect(ExpectationField.zones.slice == "B1")
        #expect(ExpectationField.notes.slice == "B2")
        #expect(ExpectationField.details.slice == "B4")
        #expect(ExpectationField.gear.slice == "B5")
        #expect(ExpectationField.rejections.slice == "B8")
        #expect(ExpectationField.databaseAlone.slice == nil,
                "it has no store, so no slice moves it")
    }

    /// The note is what the paste would lose if the field carried everything.
    @Test("A comparison says how it used the field, not only which one")
    func theNoteSurvives() {
        let e = ExpectationOrigin.from(.activities, "as an id set")
        #expect(e.storeDescription == "ActivityStore.activities, as an id set")
        #expect(ExpectationOrigin.from(.activities).storeDescription
                == "ActivityStore.activities")
    }
}
