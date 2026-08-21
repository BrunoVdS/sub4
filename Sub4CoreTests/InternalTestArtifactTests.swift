//
//  InternalTestArtifactTests.swift
//  Sub4CoreTests
//
//  `hidden-for-test/` has a role — patch 439, ADR-0003 §12.194.
//
//  WHAT WAS WRONG
//  --------------
//  433 gave the app a way to move its legacy files aside so a slice could be
//  asked whether it still needed them. It renames, it never deletes, and it is
//  correct. What nobody wrote down is what the resulting DIRECTORY is.
//
//  So it was in no inventory: not `appSupportItems`, so "Delete local data"
//  walked past it; not the disconnect rules; not the export manifest; not a
//  snapshot; not a receipt. **And while a test is running it holds the ONLY
//  copy of `athlete.json` and `weather.json`** — the athlete's gear, zones and
//  606 weather readings. A privacy flow that leaves those on the phone is the
//  same defect `details.json` was, arriving through a test control instead of
//  an old version of the app.
//
//  WHAT THIS SUITE ASKS
//  --------------------
//  The role is `nonAuthoritativeInternalTestArtifact`, and it cuts four ways:
//  covered by the delete, excluded from snapshots, excluded from source parity,
//  excluded from the export — and NEVER excluded in silence.
//
//  ONE LIMITATION, STATED RATHER THAN HIDDEN — §12.164.
//  These tests do not run `deleteEverything`; this target's header says why,
//  and it has been true since 183: it removes the real Application Support
//  directory of whatever is running it. So the delete coverage is asserted
//  through the list that function's single loop walks, which is the ingredient
//  and not the function. Every other property below drives the real code.
//

import Testing
import Foundation
@testable import Sub4

@Suite("hidden-for-test has a declared role")
@MainActor
struct InternalTestArtifactTests {

    private var item: AppSupportItem {
        .internalTestArtifact(LegacyFileTest.directoryName)
    }

    // MARK: Declared, so the delete flow can see it

    @Test("The folder is an Application Support directory the inventory names")
    func theFolderIsDeclared() throws {
        #expect(DataLifecycle.appSupportItems.contains(item),
                "hidden-for-test/ is in no category, so Delete local data walks past it")
        #expect(item.isDirectory)
        let owners = DataLifecycle.categories(holding: item)
        #expect(owners == [.internalTestArtifacts])
        let e = try #require(DataLifecycle.entry(.internalTestArtifacts))
        // `isAppDeletable` is what makes the receipt say "Removed" rather than
        // "Not ours" — the difference between the app clearing the athlete's
        // data and the app explaining why it cannot.
        // Hoisted: `allSatisfy` is `rethrows`, and the #expect macro's rewrite
        // of a rethrowing call reads as throwing whatever the closure is.
        let everyLocationIsOurs = e.storage.allSatisfy { $0.isAppDeletable }
        #expect(everyLocationIsOurs)
    }

    /// The name is not typed twice. A folder declared as `hidden-for-tests`
    /// would resolve to a path nothing writes to, and the receipt would read
    /// "Nothing stored" over a directory holding the athlete's only athlete
    /// file — §12.54.2 where it costs something.
    @Test("The declared path is the one the control writes")
    func theDeclaredPathIsTheRealOne() {
        #expect(item.pathComponent == LegacyFileTest.directoryName)
        #expect(item.pathComponent == "hidden-for-test")
    }

    // MARK: Not authoritative — three exclusions, each driven

    /// EXCLUDED BY CASE, and this drives `plan` rather than reading its source.
    /// The folder holds copies of the very files a snapshot captures, so a
    /// capture that walked into it would put two `athlete.json`s in one
    /// manifest with nothing saying which the app reads.
    @Test("A snapshot never captures it, even with a file inside")
    func theSnapshotExcludesIt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-exclusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let hidden = base.appendingPathComponent(LegacyFileTest.directoryName,
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: hidden.appendingPathComponent("athlete.json"))
        try Data("{}".utf8).write(to: base.appendingPathComponent("weather.json"))

        let planned = LegacySnapshot.plan(
            base: base,
            items: [item, .file("weather.json")])

        // The ordinary file is captured; the copy is not — a positive control
        // beside the negative one, so "nothing was planned at all" cannot pass
        // as an exclusion.
        #expect(planned.map(\.declared) == ["weather.json"],
                "planned: \(planned.map(\.relativePath))")
    }

    /// `hidden-for-test/athlete.json` parses, decodes and looks exactly like
    /// the input it is a copy of, so parity reading it would compare the
    /// database against a file the app moved aside — and agree, and prove
    /// nothing (§12.125's shape).
    @Test("No legacy store names it, so source parity cannot read it")
    func parityCannotReachIt() {
        for store in LegacyStore.allCases {
            #expect(store.item != item,
                    "\(store) reads the internal test folder as a source of truth")
        }
    }

    @Test("It is never exportable")
    func itIsNotExportable() throws {
        let e = try #require(DataLifecycle.entry(.internalTestArtifacts))
        #expect(e.isExportable == false)
        // aiShareable is a CONSEQUENCE here rather than a promise: the lineage
        // includes Strava, and `noStravaLineageIsAIShareable` refuses true for
        // anything that does.
        #expect(e.aiShareable == false)
        #expect(e.isStravaDerived, "the hidden athlete.json is Strava-derived")
    }

    /// **EXCLUDED, AND SAID.** The whole argument for leaving it out is that
    /// everything inside is a duplicate of a file the export already carries —
    /// which the reader can only check if the manifest names the omission.
    @Test("The export plan names the exclusion rather than dropping it quietly")
    func theExportNamesTheExclusion() throws {
        let plan = try DataLifecycleCoordinator.plan(includingSensorTraces: false)
        #expect(plan.singles[LegacyFileTest.directoryName] == nil)
        #expect(plan.directories[LegacyFileTest.directoryName] == nil)

        let manifest = try JSONSerialization.jsonObject(with: plan.manifest) as? [String: Any]
        let excluded = manifest?["excluded"] as? [String] ?? []
        let named = excluded.contains { $0.contains(LegacyFileTest.directoryName) }
        #expect(named, "the export omits hidden-for-test/ without saying so: \(excluded)")
    }

    // MARK: A disconnect keeps it, and the reason is the last-copy guard

    /// The naive answer is `.removeEverything` — the folder carries Strava
    /// lineage — and it would be wrong in the one direction that cannot be
    /// undone. While a test is running the live `athlete.json` is ABSENT.
    @Test("A Strava disconnect does not touch it, and says why")
    func aDisconnectKeepsIt() throws {
        let e = try #require(DataLifecycle.entry(.internalTestArtifacts))
        guard case .keep(let why) = e.onStravaDisconnect else {
            Issue.record("a disconnect alters the only copy of the athlete file: \(e.onStravaDisconnect)")
            return
        }
        #expect(why.localizedCaseInsensitiveContains("only copy"),
                "the reason does not name the hazard: \(why)")
        #expect(e.gaps.isEmpty == false,
                "keeping Strava-derived bytes is a gap and must be recorded as one")
    }

    // MARK: The redacted inventory — path, hash, bytes, status

    private func makeContainer(_ files: [String: String]) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-inventory-\(UUID().uuidString)")
        let dir = base.appendingPathComponent(LegacyFileTest.directoryName,
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        return base
    }

    @Test("Every file gets a path, a hash, a byte count and a status")
    func theInventoryAnswersInFourTerms() throws {
        let base = try makeContainer([
            "athlete.json": "{\"gear\":1}",
            "weather.json.written-while-hidden": "{}",
            "stray.txt": "left by something else"
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let found = LegacyFileTest.inventory(in: base)
        #expect(found.count == 3)
        #expect(found.map(\.path) == ["hidden-for-test/athlete.json",
                                      "hidden-for-test/stray.txt",
                                      "hidden-for-test/weather.json.written-while-hidden"])
        // THREE STATUSES, AND THE THIRD IS THE POINT. A folder that classified
        // everything it did not recognise as one of the two it did would
        // swallow whatever arrives next — §12.132.
        #expect(found.map(\.status) == [.hiddenOriginal, .unrecognised,
                                        .keptFromAnEarlierTest])
        for a in found {
            #expect(a.sha256.count == 64, "\(a.path) has no hash")
            #expect(a.bytes > 0)
        }
        // The hash is the real one, not a placeholder.
        let athlete = try #require(found.first)
        #expect(athlete.sha256 == LegacySnapshot.hex(Data("{\"gear\":1}".utf8)))
    }

    /// **§12.7 IS WHAT THIS DEFENDS.** A paste may carry Strava ids and field
    /// names; it may not carry session names, places or dates. `weather.json`
    /// is 606 readings taken at places and times, and the whole reason the
    /// inventory reports a HASH is that a hash is an identity rather than a
    /// disclosure.
    @Test("The inventory never carries the contents")
    func theInventoryIsRedacted() throws {
        let secret = "Bruxelles-2026-08-21-a-place-and-a-date"
        let base = try makeContainer(["athlete.json": "{\"where\":\"\(secret)\"}"])
        defer { try? FileManager.default.removeItem(at: base) }

        for line in LegacyFileTest.inventoryLines(in: base) {
            #expect(!line.contains(secret), "the paste carries file contents: \(line)")
        }
    }

    /// A section that renders nothing when the folder is empty cannot be told
    /// from one nobody wired in — §12.54.2, over the athlete's own data.
    @Test("It says 'none' rather than nothing")
    func theEmptyAnswerIsStated() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let lines = LegacyFileTest.inventoryLines(in: base)
        #expect(lines.count == 1)
        #expect(lines[0].contains("none"), "\(lines)")
        // And with no container at all — the reachability answer, which is a
        // different thing from an empty folder.
        #expect(LegacyFileTest.inventory(in: nil).isEmpty)
    }
}
