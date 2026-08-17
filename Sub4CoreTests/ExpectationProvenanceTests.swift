//
//  ExpectationProvenanceTests.swift
//  Sub4CoreTests
//
//  Where a comparison's expectation came from, derived rather than declared —
//  patch 386, ADR-0003 §12.130. THE DERIVATION IS THE ANSWER SINCE 387,
//  §12.131.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  `HydratedStores` was a list, kept by hand, in a different file from the
//  comparisons it classified. It joined to the checks BY NAME and its only
//  tripwire — `unmatchedHydratedEntries` — pointed one way: an ENTRY naming no
//  check. The damage runs the other way. A CHECK reading a store the database
//  feeds, which nobody added to the list, counted as evidence in silence, and
//  `activity fields` did exactly that from patch 382 to 385.
//
//  386 derived the same answer from the stores themselves and ran it beside the
//  list as a negative control. The device printed the two reaching the same
//  nine on 17 August, which is the evidence that patch existed to produce, and
//  387 deleted the list: `selfReferentialChecks` and `independentChecks` now
//  filter on each check's own `reads` against what the build is serving.
//
//  WHAT 387 GAVE UP AND WHAT REPLACED IT
//  -------------------------------------
//  Two conditions left `isTrustworthyEvidence` with the list —
//  `unmatchedHydratedEntries.isEmpty` and `undeclaredSelfReferential.isEmpty`.
//  Both guarded a list drifting from the checks, and with one source there is
//  nothing to drift.
//
//  `theWholeMapIsPinned` is what replaces them, and THE ASYMMETRY IS THE POINT.
//  The old list was a SUBSET, so a comparison missing from it passed in
//  silence. That map is COMPLETE: a comparison missing from it fails, and so
//  does one whose field changed. It is the protection those two conditions were
//  giving, in the one form that can actually fail.
//
//  A REVERTED SLICE IS NOT A FAULT, AND `theOppositeIsNotAFault` IS WHERE THAT
//  IS ASSERTED. Take `.activities` out of `hydratedFamilies` and the store goes
//  back to its file; the comparison returns to the evidence column, which is
//  the honest answer rather than an error. Reversibility by deleting one family
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

    /// **JUST ENOUGH TO MAKE EVERY CONDITIONAL COMPARISON RUN**, and nothing
    /// is asserted about the values. `SemanticVerifierTests` has the migrated
    /// fixture that makes them pass; copying it here would be a second thing to
    /// keep true about the importer, for a test that never looks at a count.
    private func activity(_ id: String) -> Activity {
        Activity(id: id, name: "Morning Run", sportType: "Run",
                 startLocal: "2026-07-28T09:24:06",
                 distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: 40, averageHeartrate: 142, isTrainer: nil,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T07:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func weather(_ id: String) -> ActivityWeather {
        ActivityWeather(activityId: id, tempC: 18.5, feelsLikeC: 17.1,
                        humidity: 0.62, windKmh: 14.0, windFromDegrees: 225,
                        precipitationMm: 0.4, symbolName: "cloud.sun",
                        conditionLabel: "Partly cloudy", samples: 3,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000),
                        source: .openMeteo)
    }

    /// SPLITS ARE NOT OPTIONAL HERE. `splits of one activity` picks the
    /// richest detail and skips a detail with none, so a splitless fixture
    /// would silently pin twenty-one.
    private func detail(_ id: String) -> ActivityDetail {
        ActivityDetail(activityId: id,
                       splits: (1...3).map {
                           .init(index: $0, distanceM: 1000, movingTime: 300,
                                 elapsedTime: 305, elevationDiff: nil,
                                 averageHR: nil)
                       },
                       bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    // `covering()` LIVED HERE AND DIED WITH THE LIST — 387.
    //
    // 386a added it because `isTrustworthyEvidence` had four conditions, and a
    // report built from two synthetic checks left all nine `HydratedStores`
    // entries unmatched — so 358a's condition withheld it before this file's
    // was ever consulted. A test asserting `!isTrustworthyEvidence` over such
    // a report passed whether 386 existed or not. §12.69, in the suite written
    // to hold §12.69.
    //
    // There are two conditions now and neither is about a list, so a report
    // satisfies nothing but itself and `report(_:fed:)` is enough.

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

        #expect(Set(r.selfReferentialChecks.map(\.name))
                == ["activities", "heart-rate zones"],
                "only the two fields this build feeds")
        #expect(!r.selfReferentialChecks.contains { $0.name == "gear" },
                "gear is the file half of AthleteStore until B5")
        #expect(!r.selfReferentialChecks.contains { $0.name == "sync position" },
                "the cursor is UserDefaults until B8")
    }

    // MARK: What the classification does to a report

    /// **A SELF-REFERENTIAL COMPARISON IS NOT A DISAGREEMENT AND MUST NOT
    /// WITHHOLD A REPORT.** It is the ordinary state of every slice from B1
    /// onward: some comparisons read the database on both sides, and the report
    /// is still evidence for as long as one of them does not.
    ///
    /// **THIS TEST HAD A DIFFERENT SUBJECT UNTIL 387.** It read
    /// `theDeclaredOneIsFine` and asserted that a self-referential comparison
    /// the LIST also named passed the cross-check. There is no list and no
    /// cross-check; what survives is the half that was always about the report.
    @Test("A self-referential comparison does not withhold a report")
    func aSelfReferentialCheckIsNotAWithholding() {
        let r = report([
            check("activities", reads: .from(.activities, "counted")),
            check("gear", reads: .from(.gear))
        ], fed: [.activities])

        #expect(r.selfReferentialChecks.contains { $0.name == "activities" })
        #expect(r.passed, "every comparison agreed — that is not the question")
        #expect(r.isTrustworthyEvidence, "gear could still have disagreed")
        #expect(r.withheldReason == nil)
    }

    /// A slice that has been reverted is not a fault. See the header.
    @Test("A field no longer fed is a reverted slice, not a defect")
    func theOppositeIsNotAFault() {
        let r = report([
            check("activities", reads: .from(.activities, "counted")),
            check("gear", reads: .from(.gear))
        ], fed: [])

        // **AND IT MEANS SOMETHING BETTER THAN IT DID AT 386.** The list used
        // to go on naming `activities` after the family was pulled out of
        // `hydratedFamilies`, and the cross-check had to be one-directional to
        // tolerate that. Now the comparison simply returns to the evidence
        // column, because that is what it has become.
        #expect(r.selfReferentialChecks.isEmpty,
                "nothing is fed from the database in this report")
        #expect(r.independentChecks.count == 2,
                "so both comparisons can disagree again")
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

    /// **387'S REPLACEMENT TRIPWIRE, AND THE REASON THE PATCH DOES NOT LOSE
    /// PROTECTION.**
    ///
    /// THE ASYMMETRY IS THE POINT. `HydratedStores` was a SUBSET of the
    /// comparisons — a check missing from it passed in silence, which is
    /// exactly what happened to `activity fields` for three patches (§12.129).
    /// THIS MAP IS COMPLETE. A comparison missing from it fails, a comparison
    /// whose field changed fails, and a comparison added at B4 fails until
    /// somebody writes down what it reads. That is what
    /// `unmatchedHydratedEntries` and `undeclaredSelfReferential` were
    /// providing, in the one form that can actually fail.
    ///
    /// **THE FIXTURE IS SIZED BY WHAT MAKES ALL TWENTY-TWO RUN, not by what
    /// makes them pass.** Three comparisons are conditional — `sync position`
    /// on a cursor, `splits of one activity` on a detail with splits, `one
    /// weather reading` on a reading whose activity is in the store — and a
    /// call omitting them pins nineteen while reading like a complete map,
    /// which is the shape this test exists to refuse. They compare a populated
    /// store against an empty database and therefore FAIL; that is irrelevant
    /// here and asserted nowhere. `SemanticVerifierTests` owns whether they
    /// pass.
    ///
    /// `reading the database` is not here and cannot be: it is the check
    /// `verify` returns INSTEAD of a report when the read throws, so it never
    /// appears beside another one.
    @Test("Every comparison's field is pinned, so a new one forces a decision")
    func theWholeMapIsPinned() throws {
        let db = try Sub4Database.inMemory()
        let id = "44444444"
        let r = try SemanticVerifier.verify(
            db, activities: [activity(id)],
            syncState: SyncState(sourceID: Sub4Import.sourceID,
                                 cursor: "2026-07-28T07:24:06Z",
                                 lastSync: nil, lastResult: nil),
            weather: [weather(id)],
            details: [detail(id)],
            sources: ExpectationSources.allFromFiles)

        // ANNOTATED, NOT INFERRED. A twenty-two element literal inside
        // `#expect` is one expression for the type checker to solve, and
        // §12.71.9 was bought on a smaller one than this.
        let expected: [String: ExpectationField] = [
            "activities":             .activities,
            "activity identities":    .activities,
            "activity fields":        .activities,
            "volume by discipline":   .activities,
            "gear":                   .gear,
            "notes":                  .notes,
            "match decisions":        .matchDecisions,
            "commute corrections":    .commutes,
            "session moves":          .moves,
            "reviews":                .reviews,
            "stopped asking":         .workItems,
            "refused recordings":     .rejections,
            "sync position":          .syncPosition,
            "heart-rate zones":       .zones,
            "weather readings":       .weather,
            "one weather reading":    .weather,
            "traces":                 .traces,
            "trace samples":          .traces,
            "details":                .details,
            "splits":                 .details,
            "splits of one activity": .details,
            "unclaimed corrections":  .databaseAlone,
        ]

        let map = Dictionary(uniqueKeysWithValues:
                                r.checks.map { ($0.name, $0.reads.field) })
        #expect(map == expected,
                "a comparison was added, removed, or now reads a different field")
        #expect(r.checks.count == 22,
                "and the count is the device's, so the fixture is complete")
    }

    /// The four B3 comparisons, derived rather than listed. This is the
    /// assertion `ActivitiesAreReadTests` could not make, because it starts
    /// from the list.
    @Test("The four comparisons reading the activities are found by derivation")
    func theFourAreDerived() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [],
                                            sources: ExpectationSources(fedByTheDatabase: [.activities]))

        #expect(Set(r.selfReferentialChecks.map(\.name))
                == ["activities", "activity identities",
                    "activity fields", "volume by discipline"],
                "the count, the id set, the fingerprint and the sums")
        #expect(r.independentChecks.allSatisfy { $0.reads.field != .activities },
                "and no comparison reading the activities is left in evidence")
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
        #expect(r.selfReferentialChecks.isEmpty)
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
