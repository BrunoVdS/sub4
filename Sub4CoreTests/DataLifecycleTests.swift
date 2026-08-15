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
        // PATH COMPONENTS, not display names — patch 183. A location used to be
        // the string `"streams/<activity>.json"`, which was prose pretending to
        // be a path. It is now an `AppSupportItem` that resolves to a real URL,
        // and this list is what the stores actually name.
        let storesTheAppActuallyWrites = [
            "activities.json",
            "details",          // a directory of per-activity files
            "streams",
            "details.json",     // written by versions before the split
            "streams.json",
            "notes.json",
            "proposals.json",
            "athlete.json",
            "constants.json",
            "weather.json",
            "commutes.json",    // CommuteStore — patch 251
            // DECLARED BEFORE ANYTHING WRITES IT — patch 362, and the second
            // line in this project's history to be true here before it is true
            // on disk. See `db` in `DataLifecycleCoordinatorTests` for the
            // first, and for the argument.
            "moves.json"        // PlanMoveStore — patch 362
        ]
        let covered = Set(DataLifecycle.appSupportItems.map(\.pathComponent))
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
        // NARROWED IN 183, and the narrowing is the point rather than a
        // convenience. The category gained `health.authVersion` and
        // `health.authorized` — two preference keys the app writes and can
        // therefore delete. The original assertion said nothing in this
        // category is app-deletable, which stopped being true.
        //
        // What must stay true is the thing the assertion was protecting: the
        // READINGS are Apple's, and no delete flow may imply otherwise. So the
        // check moves to the system-owned location itself.
        let health = try #require(DataLifecycle.entry(.healthMetrics))
        let readings = health.storage.filter { if case .systemOwned = $0 { return true }; return false }
        #expect(readings.isEmpty == false, "the Health readings are no longer declared system-owned")
        #expect(readings.allSatisfy { !$0.isAppDeletable },
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
        // AND THE PURPOSE STRING WENT IN 182, for the same reason: it was
        // fixed. That one is worth a note, because it is the only gap so far
        // that was closed outside this project's source — the text is a build
        // setting. Deleting the disclosure would have left nothing watching it,
        // so `usageDescriptionNamesEveryTypeRead` in HealthTypeTests took over:
        // it reads the string out of the built product and holds it to
        // `typesRead`. A disclosure was traded for an assertion, which is the
        // right direction.
        //
        // healthMetrics now records no gaps at all. That is deliberate and it
        // is checked — `gapsAreActionable` iterates whatever is there, and an
        // empty list is a legitimate answer.
        let profile = try #require(DataLifecycle.entry(.athleteProfile))
        #expect(profile.gaps.contains { $0.localizedCaseInsensitiveContains("athlete.json") },
                "athlete.json has no deletion path")

        let credentials = try #require(DataLifecycle.entry(.credentials))
        #expect(credentials.gaps.contains { $0.localizedCaseInsensitiveContains("strava.credentials") },
                "the Strava application keys survive a disconnect")
    }

    // MARK: The database is a copy of everything, and said it was empty

    /// THE ASSERTION THIS PATCH EXISTS FOR — patch 281, ADR-0003 §12.27.
    ///
    /// `.removeEverything` is the right rule for a database nothing reads: the
    /// rows are a copy, the files above are the originals, and after a
    /// disconnect neither should survive. It becomes the WRONG rule the moment
    /// a kept category's data lives only in here.
    ///
    /// `migrationFailureBlocksTheApp` is this project's declared marker for
    /// that moment, and it is a stored constant precisely so that flipping it
    /// is a decision somebody makes on purpose. This test makes that decision
    /// fail the build until the disconnect has been taught to delete rows.
    ///
    /// PATCH 346 — THIS QUOTED THE WRONG SENTENCE, AND THE SENTENCE NO LONGER
    /// EXISTS. It cited `Sub4Launch`'s header saying the flag "MUST BECOME
    /// `true` IN 3.3.3, the moment the first store reads its data from the
    /// database instead of from JSON". Patch 342 corrected that header: A3 §2.2
    /// settled that every D7 slice keeps a selectable legacy path and the flip
    /// happens at B9, after all eight.
    ///
    /// The distinction is the whole of this test. At 346 three stores DO read
    /// from the database — and `.removeEverything` is still correct, because
    /// every row they read also still exists in a file above and every one of
    /// those files is still written. The rule turns on whether the database
    /// holds the ONLY copy, not on whether anything reads it. Same conclusion,
    /// and it now says so for the reason that is actually true.
    ///
    /// So the person who activates the database reads is the same person who
    /// gets told what they now owe. That is the whole design: the act that
    /// makes the work necessary is the act that surfaces it.
    @Test("The disconnect rule is coupled to whether anything reads the database")
    func theDisconnectRuleIsCoupledToActivation() throws {
        let db = try #require(DataLifecycle.entry(.database))

        // HOISTED, and not for readability — patch 278b. `#expect`'s second
        // argument is `Comment?`, which a string LITERAL converts to and a
        // `String` value does not. `"a " + "b"` is a value, so writing the
        // sentence across two quoted pieces fails to compile with a diagnostic
        // that names the type and not the cause.
        let activated = "a store now reads from the database, so a disconnect "
            + "may no longer remove the whole folder — it holds the only copy "
            + "of notes, corrections and reviews that other categories promise "
            + "to keep. See ADR-0003 §12.27 and step 3.7."
        let shadow = "nothing reads the database, so its rows are a copy of "
            + "the files above and a disconnect must take them too"

        if Sub4Launch.migrationFailureBlocksTheApp {
            #expect(db.onStravaDisconnect != .removeEverything, "\(activated)")
        } else {
            #expect(db.onStravaDisconnect == .removeEverything, "\(shadow)")
        }
    }

    /// The literal cannot be computed — an entry cannot read the array it lives
    /// in — so it is held to the union instead. This is the test that would
    /// have caught the original defect: `weather` and `sessionNotes` started
    /// feeding the database at patches 265 and 271, and `[.device]` went on
    /// being the declared answer.
    ///
    /// `.device` is added here rather than taken from `.database`'s own entry,
    /// which would make this circular. It is in the set for `migration_run`.
    @Test("The database's lineage is the union of what feeds it")
    func databaseLineageIsTheUnionOfItsInputs() throws {
        let db = try #require(DataLifecycle.entry(.database))

        var expected: Set<DataSource> = [.device]
        for c in DataLifecycle.databaseContributors {
            let e = try #require(DataLifecycle.entry(c),
                                 "\(c.rawValue) is named as a contributor and has no entry")
            expected.formUnion(e.lineage)
        }

        let missing = expected.subtracting(db.lineage).map(\.rawValue).sorted()
        let extra = db.lineage.subtracting(expected).map(\.rawValue).sorted()
        #expect(db.lineage == expected,
                "the database's lineage is wrong — missing \(missing), unexpected \(extra)")
    }

    /// THE WEAKEST OF THE THREE, and recorded as such.
    ///
    /// It asserts the absence of two sentences, which is a test about prose —
    /// the thing `knownProblemsAreDisclosed` had to be corrected for once
    /// already. It earns its place on the same grounds as that test does in
    /// reverse: those two claims were read by a person deciding whether to
    /// disconnect, they were false for sixteen patches, and if they ever come
    /// back it should be because somebody deleted this test on purpose.
    @Test("The database no longer claims to be empty")
    func theDatabaseDoesNotClaimToBeEmpty() throws {
        let db = try #require(DataLifecycle.entry(.database))
        #expect(!db.whatItIs.localizedCaseInsensitiveContains("no training data"))
        #expect(!db.whatItIs.localizedCaseInsensitiveContains("empty schema"))
        #expect(db.lineage.contains(.strava),
                "the database holds 668 Strava activities and must say so")
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
