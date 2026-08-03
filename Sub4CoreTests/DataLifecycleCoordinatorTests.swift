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

@Suite
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
            "weather.json"       // WeatherStore
        ]
        #expect(declared == written,
                "missing: \(written.subtracting(declared)); undeclared: \(declared.subtracting(written))")
    }

    /// `details` and `streams` are directories of per-activity files; the rest
    /// are single files. Getting this wrong means `removeItem` is pointed at a
    /// path that does not exist, and the receipt reports "nothing stored" for
    /// a directory holding four hundred sessions.
    @Test("Directories are declared as directories")
    func directoriesAreDirectories() {
        let dirs = Set(DataLifecycle.appSupportItems.filter(\.isDirectory).map(\.pathComponent))
        #expect(dirs == ["details", "streams"], "directory set is \(dirs)")
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
            "strava.rejectedByRule", "strava.geoBackfill",
            "strava.powerBackfill", "strava.speedBackfill",
            // DetailStore
            "streams.schema", "detail.failed", "detail.noStreams",
            // NotesStore, ProposalStore
            "notes.schema", "proposals.schema",
            // HealthStore
            "health.authVersion", "health.authorized",
            // WeatherStore
            "weather.unavailable",
            // BackgroundRefresh
            "bg.lastRun", "bg.runCount", "bg.lastResult", "bg.scheduleError",
            // Matcher
            "match.overrides",
            // Display
            "appearance.selected", "discipline.selected",
            "volume.unit", "zones.window"
        ]
        let covered = Set(DataLifecycle.preferenceKeys)
        for k in written {
            #expect(covered.contains(k), "\(k) is written by the app but appears in no category")
        }
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

    /// The rule that keeps secrets out. Credentials are `isExportable == false`
    /// and live only in the Keychain, so no Application Support item should
    /// ever belong to them.
    @Test("No exportable file belongs to a non-exportable category")
    func exportSkipsNonExportableStores() {
        for item in DataLifecycle.appSupportItems {
            let owners = DataLifecycle.categories(holding: item)
            #expect(owners.isEmpty == false, "\(item.displayName) belongs to no category")
            let mixed = owners.contains { DataLifecycle.entry($0)?.isExportable == false }
            #expect(mixed == false,
                    "\(item.displayName) is shared with a non-exportable category and would be skipped")
        }
    }

    /// An export that runs on a device with no data must still be a valid file
    /// with a manifest, not an empty one. A person who exports before syncing
    /// anything should get an answer, and the answer is "nothing yet".
    @Test("An export is written and parses, even with nothing stored")
    func exportProducesValidJSON() throws {
        let url = try DataLifecycleCoordinator.export()
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
    }

    /// Naming a file after the day it was made is the difference between an
    /// export a person can find later and one more `export.json` in Files.
    @Test("The export is named with a date")
    func exportIsNamedWithADate() throws {
        let url = try DataLifecycleCoordinator.export()
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
