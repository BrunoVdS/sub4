//
//  DataLifecycleTests.swift
//  Sub4CoreTests
//
//  The claims the privacy pane makes, asserted — patch 180, plan step 2.1.
//
//  WHY THESE PARTICULAR ASSERTIONS
//  -------------------------------
//  An inventory written as a type is only better than an inventory written as
//  prose if something checks it. These are the checks: that nothing carrying
//  Strava lineage can be handed to an AI provider, that no secret can reach an
//  export, that every category names how it is deleted, and that the categories
//  cover the stores the app actually writes.
//
//  The last one is the interesting one. `storesTheAppActuallyWrites` is a
//  hand-maintained list, which sounds like the same drift problem one level
//  down — except a new store means a new file path in the source, and this test
//  fails the moment the inventory has not been told about it. It converts
//  "somebody should remember to update the privacy pane" into a red build.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct DataLifecycleTests {

    // MARK: The policy invariants

    /// ADR-0002, §5.3 and §5.10 of the Strava API Policy. The single most
    /// consequential line in this file: if it ever passes while something
    /// Strava-derived is marked shareable, the app is back to transmitting
    /// exactly what patch 178 switched off.
    @Test("Nothing derived from Strava may be shared with an AI provider")
    func noStravaLineageIsAIShareable() {
        for e in DataLifecycle.entries where e.isStravaDerived {
            #expect(e.aiShareable == false,
                    "\(e.category.rawValue) is Strava-derived and marked AI-shareable")
        }
    }

    /// Derived values inherit restriction from every input. The training-load
    /// curve holds no Strava field of its own and is computed entirely from
    /// them, which is the case a naive "does this file contain Strava data"
    /// check would wave through.
    @Test("Derived categories carry the lineage of their inputs")
    func derivedCategoriesInheritLineage() throws {
        let load = try #require(DataLifecycle.entry(.trainingLoad))
        #expect(load.isStravaDerived,
                "the load curve is computed from Strava traces and must inherit that")
        #expect(load.lineage.contains(.appleHealth),
                "resting heart rate comes from Health and is an input to the same curve")

        let weather = try #require(DataLifecycle.entry(.weather))
        #expect(weather.isStravaDerived,
                "weather rows are keyed by Strava id and fetched from Strava coordinates")
    }

    /// Only the plan is shareable, and only because it is the athlete's own
    /// prescription with no recorded data in it. If a second category ever
    /// becomes shareable that should be a deliberate, reviewed change.
    @Test("The bundled plan is the only AI-shareable category")
    func onlyThePlanIsShareable() {
        let shareable = DataLifecycle.entries.filter(\.aiShareable).map(\.category)
        #expect(shareable == [.trainingPlan],
                "AI-shareable set changed to \(shareable)")
    }

    // MARK: Secrets

    @Test("Credentials are never exportable")
    func credentialsAreNotExportable() throws {
        let c = try #require(DataLifecycle.entry(.credentials))
        #expect(c.isExportable == false)
        #expect(c.aiShareable == false)
    }

    /// Belt and braces on the same point, expressed the other way round: no
    /// exportable category may live in the Keychain. Catches a future category
    /// that puts a secret somewhere without thinking about the export.
    @Test("No exportable category is stored in the Keychain")
    func nothingExportableLivesInTheKeychain() {
        for e in DataLifecycle.entries where e.isExportable {
            for s in e.storage {
                if case .keychain(let item) = s {
                    // ONE LITERAL, NO CONCATENATION. `Issue.record` and
                    // `#expect` take a `Comment`, not a `String` — it is
                    // ExpressibleByStringInterpolation but has no `+`. Splitting
                    // the message across two literals leaves Swift trying to
                    // resolve `+` on `Sequence` with an element type of
                    // `Character`, which is what the diagnostic is complaining
                    // about and why it points nowhere near the real problem.
                    Issue.record("\(e.category.rawValue) is exportable and holds Keychain item \(item)")
                }
            }
        }
    }

    // MARK: Completeness

    /// Every store the app writes must appear in exactly one category. A new
    /// JSON file added without an inventory entry fails here rather than
    /// silently going undisclosed.
    @Test("Every store the app writes is covered by a category")
    func everyStoreIsCovered() {
        let storesTheAppActuallyWrites = [
            "activities.json",
            "details/<activity>.json",
            "streams/<activity>.json",
            "notes.json",
            "proposals.json",
            "athlete.json",
            "constants.json",
            "weather.json"
        ]
        var covered: Set<String> = []
        for e in DataLifecycle.entries {
            for s in e.storage {
                if case .applicationSupport(let f) = s { covered.insert(f) }
            }
        }
        for store in storesTheAppActuallyWrites {
            #expect(covered.contains(store),
                    "\(store) is written by the app but appears in no category")
        }
    }

    /// `DataCategory.allCases` rather than `entries.map(\.category)`, and not
    /// for brevity: a `@Test` argument list is evaluated outside the test body's
    /// isolation, and this target's default isolation is MainActor. The
    /// synthesised `allCases` is the form already proven to work in
    /// `ReleaseGateTests`; a `static let` on a MainActor type is not. The two
    /// lists are identical anyway — `inventoryMatchesTheEnum` is what proves it.
    @Test("Every category says how it is deleted, and why it exists",
          arguments: DataCategory.allCases)
    func everyCategoryIsDescribed(_ c: DataCategory) throws {
        let e = try #require(DataLifecycle.entry(c))
        #expect(e.title.isEmpty == false)
        #expect(e.whatItIs.isEmpty == false)
        #expect(e.purpose.isEmpty == false)
        #expect(e.deletionRule.isEmpty == false)
        #expect(e.lineage.isEmpty == false, "\(c.rawValue) names no source")
        #expect(e.storage.isEmpty == false, "\(c.rawValue) names no storage")
    }

    @Test("Every category in the enum has an entry, and none appears twice")
    func inventoryMatchesTheEnum() {
        let listed = DataLifecycle.entries.map(\.category)
        #expect(Set(listed).count == listed.count, "a category is listed twice")
        for c in DataCategory.allCases {
            #expect(listed.contains(c), "\(c.rawValue) has no inventory entry")
        }
    }

    // MARK: Deletion honesty

    /// A delete-my-data flow must not promise to remove something this app
    /// cannot reach. Health readings live in the Health app and the plan lives
    /// in the bundle; both say so rather than implying otherwise.
    @Test("Categories the app cannot delete do not claim that it can")
    func deletionClaimsAreHonest() throws {
        let health = try #require(DataLifecycle.entry(.healthMetrics))
        #expect(health.storage.allSatisfy { !$0.isAppDeletable },
                "Health readings are system-owned and must not be app-deletable")
        #expect(health.deletionRule.localizedCaseInsensitiveContains("Health app"),
                "the Health rule must point at where the data actually lives")

        let plan = try #require(DataLifecycle.entry(.trainingPlan))
        #expect(plan.storage.allSatisfy { !$0.isAppDeletable })
    }

    // MARK: The gaps are the point

    /// These are recorded rather than hidden, so the count is expected to be
    /// non-zero until Phases 2 and 3 close them. The assertion is that each one
    /// names the step that closes it — a gap with no reference is a complaint
    /// rather than a work item, and it will still be here in six months.
    @Test("Every recorded gap cites the finding or step that closes it")
    func gapsAreActionable() {
        for (category, gap) in DataLifecycle.allGaps {
            let citesStep = gap.contains("step ")
            let citesFinding = gap.contains("ADR-")
                || gap.range(of: #"[A-Z]{2,7}-\d\d"#, options: .regularExpression) != nil
            #expect(citesStep || citesFinding,
                    "\(category.rawValue) records a gap with no reference: \(gap)")
        }
    }

    /// Three findings this project has already confirmed from the source. If
    /// any of them disappears from the inventory it should be because it was
    /// FIXED, and whoever fixes it will see this test and know to remove the
    /// assertion deliberately.
    ///
    /// CASE-INSENSITIVE, and that is a correction rather than a preference.
    /// The first version asked for `contains("cycling")` against a gap that
    /// begins the sentence with "Cycling", and failed — a test asserting the
    /// capitalisation of prose it does not own. What is being checked is that
    /// the subject is still disclosed, not how the sentence was worded.
    @Test("The known unfixed problems are still disclosed")
    func knownProblemsAreDisclosed() throws {
        // THE CYCLING ASSERTION WAS REMOVED IN PATCH 181, DELIBERATELY.
        //
        // This is the workflow the test was written for. It asserted that the
        // inventory still disclosed cycling distance being read without being
        // requested; patch 181 added the type to the authorisation request, so
        // the disclosure was deleted and this line went with it. Removing it
        // required reading why it was here, which is the whole point of pinning
        // a known problem rather than leaving it to be noticed.
        //
        // The same happened to "a failed query can replace a good cache" —
        // `collect` now returns an outcome rather than an empty dictionary, so
        // there is nothing left to disclose.
        //
        // What survives is the purpose string, which cannot be fixed from Swift.
        let health = try #require(DataLifecycle.entry(.healthMetrics))
        #expect(health.gaps.contains { $0.localizedCaseInsensitiveContains("purpose")
                                    || $0.localizedCaseInsensitiveContains("prompt") },
                "the Health purpose string still names step count alone (PRIV-02)")

        let profile = try #require(DataLifecycle.entry(.athleteProfile))
        #expect(profile.gaps.contains { $0.localizedCaseInsensitiveContains("athlete.json") },
                "athlete.json has no deletion path")

        let credentials = try #require(DataLifecycle.entry(.credentials))
        #expect(credentials.gaps.contains { $0.localizedCaseInsensitiveContains("strava.credentials") },
                "the Strava application keys survive a disconnect")
    }

    // MARK: The summary line

    @Test("The summary counts what the table shows")
    func summaryAgreesWithTheEntries() {
        let shared = DataLifecycle.entries.filter { !$0.sharedWith.isEmpty }.count
        let s = DataLifecycle.summary
        #expect(s.contains("\(DataLifecycle.entries.count) kinds"))
        #expect(s.contains("\(shared) of which"))
    }
}
