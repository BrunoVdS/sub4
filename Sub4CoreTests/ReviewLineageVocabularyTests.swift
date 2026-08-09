//
//  ReviewLineageVocabularyTests.swift
//  Sub4CoreTests
//
//  Patch 335. The list is frozen literals; this is what keeps them honest.
//
//  `Sub4Migrations` freezes its vocabularies the same way and asserts the
//  agreement with the Swift enums by test rather than by derivation — its
//  header argues that deriving them looks drift-proof and is the opposite.
//  `ReviewLineage` follows that, with a second reason on top: `DataSource`
//  takes the module's MainActor default and the importer that reads this is
//  nonisolated end to end.
//
//  So the freezing needs a guard, and this is it. A typo, a renamed case, or a
//  source id that never existed all fail here rather than at the database's
//  foreign key on a device.
//
//  NOT `ReviewLineageTests` — patch 335a. That name was taken, by the suite in
//  `DomainSchemaTests` that exercises ADR-0002's purge as the query it will
//  actually be: delete the evidence with Strava lineage, leave the verdict
//  standing. The two are complementary and the pair is the whole obligation —
//  that one proves the purge WORKS on rows, this one proves the rows the
//  importer writes are the right ones. It is worth reading both together.
//
//  The collision is also a rule half-applied. §12.61.9 says grep
//  `Sub4CoreTests/` before the zip, and 335 did — for the strings and the
//  fields it was changing. It did not grep the type name it was about to
//  declare, which is a fourth shape belonging on that list.
//

import Testing
@testable import Sub4

@MainActor
@Suite("Review lineage vocabulary")
struct ReviewLineageVocabularyTests {

    /// EVERY ID IS A REAL SOURCE. The FK is `onDelete: .restrict` against a
    /// `source` table seeded by `2026-08-03-initial`, so an id that is not a
    /// `DataSource` would refuse at the door — on the phone, in August, during
    /// the first real review. Here instead.
    @Test func everySourceIDNamesARealDataSource() {
        let known = Set(DataSource.allCases.map(\.rawValue))
        for id in ReviewLineage.sourceIDs {
            #expect(known.contains(id), "\(id) is not a DataSource")
        }
    }

    /// SORTED AND DISTINCT. `evidenceSourceSQL` orders by `sourceID`, and the
    /// read-back compares the two as sequences — an unsorted list here would
    /// report a difference on every review for ever.
    @Test func theListIsSortedAndHasNoDuplicates() {
        #expect(ReviewLineage.sourceIDs == ReviewLineage.sourceIDs.sorted())
        #expect(Set(ReviewLineage.sourceIDs).count == ReviewLineage.sourceIDs.count)
    }

    /// WHAT THE BUILDER ACTUALLY CONSULTS, pinned so that adding a store to
    /// `ReviewBuilder.build` without adding its source is a red test rather
    /// than a lineage row that is quietly too small.
    ///
    /// It cannot enforce that — no test can watch what a function reads — but
    /// it can make the omission cost something. The four stores today are
    /// `PlanStore` (bundled), `Matcher` and `DetailStore` (strava) and
    /// `NotesStore` (authored).
    @Test func theListIsTheThreeSourcesTheBuilderConsults() {
        #expect(ReviewLineage.sourceIDs == ["authored", "bundled", "strava"])
    }

    /// NOT APPLE HEALTH, and this is the one worth stating outright. Claiming
    /// a source the builder never read would make ADR-0002's purge delete
    /// evidence it has no business touching — a lineage that over-reports is
    /// worse than one that is absent, because absence is visible.
    @Test func itClaimsNoSourceTheBuilderDoesNotRead() {
        #expect(!ReviewLineage.sourceIDs.contains("appleHealth"))
        #expect(!ReviewLineage.sourceIDs.contains("weatherProvider"))
        #expect(!ReviewLineage.sourceIDs.contains("device"))
    }
}
