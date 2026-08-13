//
//  DataLifecycleCoordinatorTests.swift
//  Sub4CoreTests
//
//  Export and deletion, asserted — patch 183, plan steps 2.1.3 and 2.1.4.
//
//  WHAT IS AND IS NOT TESTED HERE
//  -----------------------------
//  These tests do NOT run `deleteEverything`. It removes the real Application
//  Support directory of whatever process calls it, and in a test bundle hosted
//  by the app that is the simulator's actual store — a passing test suite that
//  wipes the app's data every time it runs would be a worse bug than anything
//  it caught. What is tested is everything that can be tested without that:
//  that the inventory resolves to the paths the stores really use, that the
//  exportable set is what it claims, that nothing secret can reach an export,
//  and that the receipt's arithmetic holds.
//
//  The file operations themselves are exercised against a temporary directory
//  through `byteSize`, which is the only part with logic worth doubting.
//

import Testing
import Foundation
@testable import Sub4

/// SERIALIZED, and not for a shared-mutable-state reason — for a shared FILE.
///
/// An export is named for the day it was built, deliberately: two exports on
/// one day overwrite each other rather than leaving a trail of near-identical
/// files in `tmp`. Three tests here build a summary export, and Swift Testing
/// runs them concurrently, so all three wrote the same path and each one's
/// cleanup deleted the file the others were still reading. The first to finish
/// passed and the rest failed with ENOENT — which reads like a broken export
/// and is nothing of the kind.
///
/// The alternative was a `destination:` parameter on `plan` existing only so
/// tests could avoid colliding. Serialising is the smaller lie.
@Suite(.serialized)
@MainActor
struct DataLifecycleCoordinatorTests {

    // MARK: The inventory resolves to the real paths

    /// The whole design rests on this: the locations the privacy pane prints
    /// are the locations the coordinator deletes. If a name here drifts from
    /// what a store actually writes, the pane keeps looking correct and the
    /// delete quietly misses a file.
    ///
    /// These strings are copied from the stores — `ActivityStore.fileURL`,
    /// `DetailStore.detailsDir`, and so on. That is deliberate duplication:
    /// two lists that must agree, with a test in between, beats one list that
    /// nobody checks.
    @Test("Every declared store resolves to a path under Application Support")
    func everyItemResolves() throws {
        let base = try #require(AppSupportItem.container)
        for item in DataLifecycle.appSupportItems {
            let url = try #require(item.url, "\(item.displayName) resolves to nothing")
            #expect(url.path.hasPrefix(base.path),
                    "\(item.displayName) resolves outside Application Support: \(url.path)")
            #expect(url.lastPathComponent == item.pathComponent)
        }
    }

    /// The exact set, pinned. A store added without a category fails
    /// `everyStoreIsCovered`; a category added with a MISSPELLED path fails
    /// here. Those are different mistakes and the second one is the quiet one.
    @Test("The declared paths are exactly the ones the stores write")
    func declaredPathsMatchTheStores() {
        let declared = Set(DataLifecycle.appSupportItems.map(\.pathComponent))
        let written: Set<String> = [
            "activities.json",   // ActivityStore
            "details",           // DetailStore.detailsDir
            "streams",           // DetailStore.streamsDir
            "details.json",      // DetailStore.legacyDetailURL
            "streams.json",      // DetailStore.legacyStreamsURL
            "notes.json",        // NotesStore
            "proposals.json",    // ProposalStore
            "athlete.json",      // AthleteStore
            "constants.json",    // ConstantsStore
            "weather.json",      // WeatherStore
            "commutes.json",     // CommuteStore — patch 251
            // DECLARED BEFORE ANYTHING WRITES IT — patch 195, and the only line
            // in this list that is not true yet.
            //
            // `Sub4Database` creates this folder and nothing in the app calls
            // it until 3.2b. Declaring it early is the deliberate choice: the
            // alternative leaves a window in which the database exists on disk
            // and "Delete local data" walks straight past it — which is exactly
            // how `details.json` outlived four versions of this app. A declared
            // path with no file behind it costs one receipt line reading
            // "Nothing stored", which `LocationOutcome` already treats as a
            // normal answer rather than a failure.
            "db",                // Sub4Database.directoryName
            // Patch 247, and declared before the first capture for exactly the
            // reason spelled out above `db`: a folder holding copies of every
            // file in this list is the last thing a delete flow may walk past.
            "snapshots"          // LegacySnapshot.directoryName
        ]
        #expect(declared == written,
                "missing: \(written.subtracting(declared)); undeclared: \(declared.subtracting(written))")
    }

    /// `details` and `streams` are directories of per-activity files, and `db`
    /// is a directory for a different reason: SQLite writes `-wal`, `-shm` and
    /// `-journal` beside the database, creates them itself, and they hold the
    /// same rows. Naming only the `.sqlite` would leave the user's data in
    /// files the receipt never mentions.
    ///
    /// Getting any of these wrong means `removeItem` is pointed at a path that
    /// does not exist, and the receipt reports "nothing stored" for a directory
    /// holding four hundred sessions.
    @Test("Directories are declared as directories")
    func directoriesAreDirectories() {
        let dirs = Set(DataLifecycle.appSupportItems.filter(\.isDirectory).map(\.pathComponent))
        #expect(dirs == ["details", "streams", "db", "snapshots"],
                "directory set is \(dirs)")
    }

    // MARK: Preference keys

    /// The finding that prompted the `appSettings` category. Before 183 the
    /// inventory named seven preference keys and the app wrote twenty-four, so
    /// a delete built from the inventory would have left seventeen behind —
    /// including every release-gate switch and the record of which recordings
    /// the app had refused.
    ///
    /// Hand-maintained, like `storesTheAppActuallyWrites`, and for the same
    /// reason: a new key is a new string literal in a store, and this test is
    /// what turns forgetting to classify it into a red build.
    @Test("Every UserDefaults key the app writes is covered by a category")
    func everyPreferenceKeyIsCovered() {
        let written = [
            // ActivityStore
            "strava.cursor", "strava.lastSync", "strava.cutoffUsed",
            "strava.rejections", "strava.rejectedByRule", "strava.geoBackfill",
            "strava.powerBackfill", "strava.speedBackfill",
            // DetailStore
            "streams.schema", "detail.failed", "detail.noStreams",
            // NotesStore, ProposalStore
            "notes.schema", "proposals.schema",
            // HealthStore
            "health.authVersion", "health.authorized",
            // WeatherStore writes no preference key. `weather.unavailable`
            // was listed here until patch 276 and the app has deleted it on
            // every launch since 130 — so this list asserted coverage of a key
            // nothing writes, which is the opposite of what the test is for.
            // BackgroundRefresh
            "bg.lastRun", "bg.runCount", "bg.lastResult", "bg.scheduleError",
            // Matcher — `match.decisions` since patch 272. Both are listed:
            // the old key still exists on any device that has not launched
            // this build, and the inventory is what "Delete local data" reads.
            "match.decisions", "match.overrides",
            // Display
            "appearance.selected", "discipline.selected",
            "volume.unit", "zones.window",
            // Consent — patch 193, PRIV-04. Separate from the gate it guards:
            // "the feature is on" and "somebody agreed to the transfer" are
            // different facts, and a delete must remove the second.
            "consent.locationToWeather",
            // LoadThresholds — MISSING UNTIL PATCH 214, and the reason this
            // test is weaker than its name suggests. See the two below.
            "load.rampWarn", "load.rampNote", "load.tsbDeep",
            "load.tsbDeepDays", "load.monotonyHigh"
        ]
        let covered = Set(DataLifecycle.preferenceKeys)
        for k in written {
            #expect(covered.contains(k), "\(k) is written by the app but appears in no category")
        }
    }

    /// THE VERSION OF THE TEST ABOVE THAT CANNOT DRIFT.
    ///
    /// `everyPreferenceKeyIsCovered` compares a HAND-WRITTEN array against the
    /// inventory. Both lists were written the same day by the same person, and
    /// both forgot `LoadThresholds` — so a test called "Every UserDefaults key
    /// the app writes is covered by a category" passed while five written keys
    /// were covered by nothing, and `Delete local data` left the athlete's tuned
    /// thresholds in place without the receipt naming them as survivors.
    ///
    /// `noStoreIsMissedByTheMemoryDrop` could not have caught it either: that
    /// one pins against stores declaring an Application Support location, and
    /// `LoadThresholds` declares no file. A preferences-only store is the blind
    /// spot in both checks.
    ///
    /// This asks the type that WRITES the keys, so a sixth threshold is covered
    /// the moment it is added and no array needs updating.
    @Test("The keys LoadThresholds writes are the keys the inventory covers")
    func loadThresholdKeysAreCoveredAtTheirSource() {
        let covered = Set(DataLifecycle.preferenceKeys)
        let missing = LoadThresholds.preferenceKeys.filter { !covered.contains($0) }
        #expect(missing.isEmpty, "not covered by any category: \(missing)")
        #expect(LoadThresholds.preferenceKeys.count == 5)
    }

    /// Dropping in memory must not write the defaults back into the keys the
    /// delete has just removed.
    ///
    /// `deleteEverything` removes preference keys first and calls
    /// `dropAllInMemory()` after, so a plain `reset()` would fire all five
    /// `didSet`s and re-create the keys holding default values. Deleted-and-
    /// recreated is not deleted, and nothing about the app's behaviour would
    /// look wrong — which is why this is a test and not a comment.
    @Test("Dropping thresholds in memory writes nothing back")
    func droppingThresholdsDoesNotRecreateTheKeys() {
        let d = UserDefaults.standard
        let t = LoadThresholds.shared

        t.rampWarn = 9.5                                   // persists, as designed
        #expect(d.object(forKey: "load.rampWarn") != nil)

        for k in LoadThresholds.preferenceKeys { d.removeObject(forKey: k) }
        t.dropInMemory()

        let recreated = LoadThresholds.preferenceKeys.filter { d.object(forKey: $0) != nil }
        #expect(recreated.isEmpty, "dropInMemory wrote back: \(recreated)")
        #expect(t.isDefault, "the in-memory values were not returned to defaults")
    }

    /// The gate keys are COMPUTED — `"gate." + rawValue` — so a gate renamed in
    /// the enum silently orphans the literal in the inventory, leaving a record
    /// of consent that no delete removes.
    @Test("Every release gate's key is covered by a category")
    func everyGateKeyIsCovered() {
        let covered = Set(DataLifecycle.preferenceKeys)
        for gate in ReleaseGate.allCases {
            #expect(covered.contains(ReleaseGates.key(gate)),
                    "\(ReleaseGates.key(gate)) stores a consent decision and is not in the inventory")
        }
    }

    // MARK: Export

    /// The rule that keeps secrets out — NARROWED IN 195, and the narrowing is
    /// the point rather than a way past a red test.
    ///
    /// What it said was: no Application Support item may belong to any category
    /// that is not exportable. That was one assertion doing two jobs, and the
    /// database is what made them come apart.
    ///
    /// The job worth keeping is about SECRECY. Credentials are
    /// `isExportable == false` because they must never be handed out, and if an
    /// Application Support file ever belonged to them the export would skip it
    /// for a reason invisible from the file list.
    ///
    /// The database is not exportable for a different reason entirely: the
    /// export writes JSON and a SQLite file is not JSON. That is a FORMAT
    /// limitation, it is recorded as a gap on the category, and the export
    /// manifest names the file in `excluded` with the reason — so nothing is
    /// skipped silently, which is what the original assertion was defending.
    ///
    /// Collapsing the two would mean either shipping a file no delete flow
    /// covers, or exporting a binary blob wrapped as unreadable text. So they
    /// are separated here, and the exemption comes with the trap below it.
    @Test("No Application Support file belongs to a secret-bearing category")
    func exportSkipsNonExportableStores() {
        // Exempt on FORMAT grounds. Anything else that is not exportable is
        // withheld on secrecy grounds and must not hold a file at all.
        let exemptOnFormatGrounds: Set<DataCategory> = [.database]

        for item in DataLifecycle.appSupportItems {
            let owners = DataLifecycle.categories(holding: item)
            #expect(owners.isEmpty == false, "\(item.displayName) belongs to no category")
            let secretive = owners.filter {
                DataLifecycle.entry($0)?.isExportable == false
                    && !exemptOnFormatGrounds.contains($0)
            }
            #expect(secretive.isEmpty,
                    "\(item.displayName) is held by \(secretive.map(\.rawValue)) and would be skipped with no visible reason")
        }
    }

    /// THE TRAP THAT MAKES THE EXEMPTION ABOVE SAFE — RE-AIMED IN 281.
    ///
    /// It guarded on `lineage != [.device]`: the database may be left out of
    /// the export only while it is EMPTY. Patch 281 makes that guard fall
    /// through, and the assertion behind it — that the database must therefore
    /// be in the export — would fail.
    ///
    /// IT WOULD FAIL FOR THE WRONG REASON, which is why this is a re-aim and
    /// not a deletion. The export writes JSON out of the STORES, and the stores
    /// are still the originals; the database holds a copy of them. Omitting a
    /// copy omits nothing. The premise this test defends — "an export that
    /// omits the database omits everything" — becomes true not when the
    /// database holds rows, but when it holds the ONLY rows.
    ///
    /// So the guard moves to the marker for that: `migrationFailureBlocksTheApp`,
    /// flipped at step 3.7 by whoever makes the database authoritative. On that
    /// day this and `theDisconnectRuleIsCoupledToActivation` fail together,
    /// which is the correct pair — a database that cannot be exported and
    /// cannot be selectively deleted is not one the app may depend on.
    @Test("The database may be left out of the export only while it is a copy")
    func theDatabaseExemptionExpiresWhenItBecomesAuthoritative() throws {
        let entry = try #require(DataLifecycle.entry(.database))

        guard Sub4Launch.migrationFailureBlocksTheApp else {
            // Still a copy. The export takes the same data from the stores, and
            // the manifest names this file in `excluded` with the reason.
            #expect(entry.isExportable == false,
                    "nothing reads the database, so the export takes the stores instead")
            return
        }

        #expect(entry.isExportable,
                "the database is now the only copy of your training and must be in the export")
    }

    /// An export that runs on a device with no data must still be a valid file
    /// with a manifest, not an empty one. A person who exports before syncing
    /// anything should get an answer, and the answer is "nothing yet".
    @Test("An export is written and parses, even with nothing stored")
    func exportProducesValidJSON() async throws {
        let url = try await DataLifecycleCoordinator.export()
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(obj as? [String: Any])
        let manifest = try #require(dict["manifest"] as? [String: Any])

        #expect(manifest["app"] != nil)
        #expect(manifest["exportedAt"] != nil)
        // The manifest must account for what was left out, or an export looks
        // complete when it is not — see the note in the coordinator.
        #expect(manifest["notIncluded"] != nil)
        #expect(manifest["heldElsewhere"] != nil)
        #expect(manifest["sensorTraces"] != nil)
    }

    /// THE 184 REGRESSION, and the reason the whole export was rewritten to
    /// stream: the first version assembled every store into one dictionary and
    /// serialised it in one go, with every sensor sample resident in memory. It
    /// is written a store at a time now, so this checks the hand-built JSON is
    /// actually well formed — a stray comma would produce a file that looks
    /// right and parses nowhere.
    @Test("A streamed export is valid JSON with traces included")
    func exportWithTracesIsValidJSON() async throws {
        let url = try await DataLifecycleCoordinator.export(includingSensorTraces: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(obj is [String: Any])
    }

    /// Sensor traces are opt-out by default, and the manifest has to SAY so.
    /// An export that quietly omits the largest thing it holds is the same
    /// dishonesty as a delete that silently skips a file.
    @Test("Leaving traces out is disclosed in the manifest")
    func omittedTracesAreDisclosed() async throws {
        let url = try await DataLifecycleCoordinator.export(includingSensorTraces: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifest = try #require(dict["manifest"] as? [String: Any])
        let note = try #require(manifest["sensorTraces"] as? String)
        #expect(note.localizedCaseInsensitiveContains("not included"))
        #expect(dict["streams"] == nil, "traces were excluded but streams were written anyway")
    }

    /// The plan is what the UI shows and what the writer consumes; the two must
    /// agree about the filename before a single byte is written.
    @Test("A full export is named differently from a summary export")
    func fullExportIsNamedDifferently() throws {
        let summary = try DataLifecycleCoordinator.plan(includingSensorTraces: false)
        let full = try DataLifecycleCoordinator.plan(includingSensorTraces: true)
        #expect(summary.destination != full.destination,
                "both exports would overwrite the same file")
        #expect(full.destination.lastPathComponent.contains("full"))
    }

    /// Naming a file after the day it was made is the difference between an
    /// export a person can find later and one more `export.json` in Files.
    @Test("The export is named with a date")
    func exportIsNamedWithADate() async throws {
        let url = try await DataLifecycleCoordinator.export()
        defer { try? FileManager.default.removeItem(at: url) }
        let name = url.lastPathComponent
        #expect(name.hasPrefix("Sub4-export-"))
        #expect(name.hasSuffix(".json"))
        #expect(name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil,
                "no date in \(name)")
    }

    // MARK: Sizes

    @Test("Byte size counts a file")
    func byteSizeOfAFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.json")
        try Data(repeating: 0x41, count: 512).write(to: f)
        #expect(DataLifecycleCoordinator.byteSize(of: f) == 512)
    }

    /// The case that matters: `details/` is a directory, and reporting 0 bytes
    /// for four hundred sessions would make the receipt say nothing was there.
    @Test("Byte size counts a whole directory")
    func byteSizeOfADirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<4 {
            try Data(repeating: 0x42, count: 100)
                .write(to: dir.appendingPathComponent("\(i).json"))
        }
        #expect(DataLifecycleCoordinator.byteSize(of: dir) == 400)
    }

    @Test("A missing path is zero bytes rather than a crash")
    func byteSizeOfNothing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-does-not-exist-\(UUID().uuidString)")
        #expect(DataLifecycleCoordinator.byteSize(of: missing) == 0)
    }

    // MARK: The receipt

    /// `.absent` must not read as an error. A device that never ran a review has
    /// no `proposals.json`, and a receipt full of red for an ordinary install
    /// teaches the reader to ignore it.
    @Test("Nothing-stored is not a failure")
    func absentIsNotFailure() {
        #expect(LocationOutcome.absent.isFailure == false)
        #expect(LocationOutcome.absent.didRemove == false)
        #expect(LocationOutcome.removed(bytes: 0).isFailure == false)
        #expect(LocationOutcome.removed(bytes: 0).didRemove)
        #expect(LocationOutcome.failed("disk").isFailure)
        #expect(LocationOutcome.notOurs("held by Apple Health").isFailure == false)
    }

    @Test("Every outcome can describe itself")
    func everyOutcomeHasALabel() {
        let all: [LocationOutcome] = [
            .removed(bytes: 0), .removed(bytes: 4_096), .absent,
            .failed("permission denied"), .notOurs("held by Apple Health")
        ]
        for o in all { #expect(o.label.isEmpty == false) }
    }

    @Test("The receipt totals what its lines say")
    func receiptArithmetic() {
        let r = LifecycleReceipt(operation: .deleteEverything, lines: [
            ReceiptLine(what: "a", categories: [.routes], outcome: .removed(bytes: 100)),
            ReceiptLine(what: "b", categories: [.weather], outcome: .removed(bytes: 250)),
            ReceiptLine(what: "c", categories: [.sessionNotes], outcome: .absent),
            ReceiptLine(what: "d", categories: [.healthMetrics], outcome: .notOurs("held by Apple Health")),
            ReceiptLine(what: "e", categories: [.credentials], outcome: .failed("nope"))
        ])
        #expect(r.removedCount == 2)
        #expect(r.bytesRemoved == 350)
        #expect(r.failures.count == 1)
        #expect(r.retained.count == 1)
    }

    /// A failure has to be the first thing the summary says. Burying it after
    /// a success count is how a delete that half-worked gets read as one that
    /// worked.
    @Test("A failure leads the summary")
    func failureLeadsTheSummary() {
        let r = LifecycleReceipt(operation: .deleteEverything, lines: [
            ReceiptLine(what: "a", categories: [], outcome: .removed(bytes: 10)),
            ReceiptLine(what: "b", categories: [], outcome: .failed("busy"))
        ])
        #expect(r.summary.hasPrefix("1 item could not be removed"),
                "summary was: \(r.summary)")
    }

    /// And the honest case with nothing wrong still has to mention what it did
    /// not touch, because Health is the thing a reader assumes was included.
    @Test("A clean delete still names what it did not touch")
    func cleanDeleteNamesSurvivors() {
        let r = LifecycleReceipt(operation: .deleteEverything, lines: [
            ReceiptLine(what: "a", categories: [], outcome: .removed(bytes: 10)),
            ReceiptLine(what: "Health", categories: [.healthMetrics],
                        outcome: .notOurs("Held by Apple Health — remove it there"))
        ])
        #expect(r.summary.localizedCaseInsensitiveContains("not this app"),
                "summary was: \(r.summary)")
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
