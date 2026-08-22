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

    /// **THE TRAP THAT MAKES BOTH EXEMPTIONS SAFE.** `hidden-for-test/` and
    /// `evidence/` are left out of the export because everything in them
    /// duplicates a file the export already carries. That argument only holds
    /// if the reader can check it, so the manifest must NAME each omission —
    /// and a silent omission is the exact defect the manifest exists to
    /// prevent.
    @Test("The export names every duplicate it leaves out")
    func theExportNamesEveryDuplicateItLeavesOut() throws {
        let plan = try DataLifecycleCoordinator.plan(includingSensorTraces: false)
        let manifest = try JSONSerialization.jsonObject(with: plan.manifest) as? [String: Any]
        let excluded = manifest?["excluded"] as? [String] ?? []

        for folder in [LegacyFileTest.directoryName, EvidencePackage.directoryName] {
            #expect(excluded.contains { $0.contains(folder) },
                    "the export omits \(folder) without saying so: \(excluded)")
            #expect(plan.directories[folder] == nil)
            #expect(plan.singles[folder] == nil)
        }
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

// MARK: - Clearing the leftover — patch 441, §12.196

/// **FOUR REFUSALS, EACH DRIVEN, PLUS THE ONE THAT MADE THE OTHERS POSSIBLE.**
///
/// The runbook's Task 0A asks for a scoped removal that refuses unless nothing
/// is hidden, the live counterpart exists AND reads, the path is on an
/// allow-list rather than a glob, and a verified snapshot holds a copy. A
/// refusal nothing drives is a refusal nobody has tested — §12.69 — and this
/// control deletes a copy of the athlete's own data.
@Suite("Removing one internal-test leftover")
@MainActor
struct TestArtifactRemovalTests {

    private let version = "patch 441 (test)"
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    /// **A REAL `athlete.json`, NOT `{}`.** The first draft used an empty
    /// object and every happy-path assertion failed with
    /// *"the file reads as JSON but not as this store\'s data"* — which is the
    /// classifier being right. Refusal 2 is that the live file READS, and a
    /// fixture that does not read cannot exercise the path where it does.
    private nonisolated static let liveAthlete = #"{"zones":[],"shoes":[]}"#

    /// A truncated one, for the case where the live file exists and is broken.
    private nonisolated static let brokenAthlete = #"{"zones":[{"index":1,"min":100"#

    /// A container with the folder, and whatever the case needs in it.
    ///
    /// `liveAthlete` is `nonisolated` because it is a DEFAULT ARGUMENT, and a
    /// default argument is evaluated at the CALL SITE rather than inside the
    /// function — §12.95.4's rule, showing up here as a Swift 6 warning rather
    /// than as a missed grep.
    private func container(live: String? = liveAthlete,
                           leftover: String? = "{\"written\":true}",
                           stranger: String? = nil,
                           hidden: Bool = false,
                           snapshot: Bool = true) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("removal-\(UUID().uuidString)")
        let dir = base.appendingPathComponent(LegacyFileTest.directoryName,
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let live { try Data(live.utf8).write(to: base.appendingPathComponent("athlete.json")) }
        if let leftover {
            try Data(leftover.utf8)
                .write(to: dir.appendingPathComponent("athlete.json.written-while-hidden"))
        }
        if let stranger {
            try Data(stranger.utf8).write(to: dir.appendingPathComponent("notes.txt"))
        }
        // THE SNAPSHOT IS TAKEN BY THE REAL CAPTURE, not by hand-writing a
        // manifest. A fixture manifest would prove the reader parses JSON; this
        // proves the removal accepts what `LegacySnapshot` actually produces.
        if snapshot {
            _ = try LegacySnapshot.capture(stamp: "2026-08-22-070000",
                                           appVersion: version,
                                           base: base,
                                           items: [.file("athlete.json")])
        }
        if hidden { _ = LegacyFileTest.hide(in: base) }
        return base
    }

    private func clean(_ base: URL) { try? FileManager.default.removeItem(at: base) }

    // MARK: The allow-list is a construction

    /// **NOT A GLOB.** `*.written-while-hidden` would delete whatever a future
    /// patch puts in this folder under that suffix for a different reason.
    @Test("What may be removed is derived from the vocabulary")
    func theAllowListComesFromTheNames() {
        #expect(TestArtifactRemoval.removableNames
                == Set(LegacyFileTest.names.map { "\($0).written-while-hidden" }))
        #expect(TestArtifactRemoval.counterpart(of: "athlete.json.written-while-hidden")
                == "athlete.json")
        #expect(TestArtifactRemoval.counterpart(of: "anything-else.written-while-hidden") == nil)
        #expect(TestArtifactRemoval.counterpart(of: "athlete.json") == nil)
    }

    // MARK: The happy path — and it has to exist, or every refusal below is vacuous

    @Test("With every check satisfied it removes exactly one file and receipts it")
    func itRemovesAndReceipts() throws {
        let base = try container()
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(preview.canProceed, "\(preview.lines)")
        #expect(preview.counterpart == "athlete.json")
        #expect(preview.snapshotID == "2026-08-22-070000")
        let target = try #require(preview.target)
        #expect(target.path == "hidden-for-test/athlete.json.written-while-hidden")

        let outcome = TestArtifactRemoval.remove(confirming: preview, in: base,
                                                 now: now, appVersion: version)
        let receipt = try #require(try? outcome.get(), "refused: \(outcome)")
        #expect(receipt.verifiedAbsent, "the removal did not check its own work")
        #expect(receipt.sha256 == target.sha256)
        #expect(receipt.bytes == target.bytes)
        #expect(receipt.snapshotID == "2026-08-22-070000")

        // The file is gone, read off the disk rather than from the receipt.
        let gone = base.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("athlete.json.written-while-hidden")
        #expect(!FileManager.default.fileExists(atPath: gone.path))

        // THE LIVE FILE IS UNTOUCHED. The whole hazard in one assertion.
        let stillLive = base.appendingPathComponent("athlete.json")
        #expect(FileManager.default.fileExists(atPath: stillLive.path))
    }

    /// **THE BUG THIS CAUGHT BEFORE IT SHIPPED.** The receipt is written into
    /// the folder it cleaned. Without its own status it would classify as
    /// `unrecognised`, and the control refuses when the folder holds anything
    /// unrecognised — so the first successful removal would have left behind
    /// the exact file that made every later removal impossible.
    @Test("A removal does not poison the next one")
    func theReceiptIsNotAStranger() throws {
        let base = try container()
        defer { clean(base) }

        _ = TestArtifactRemoval.remove(confirming: TestArtifactRemoval.preview(in: base),
                                       in: base, now: now, appVersion: version)

        let held = LegacyFileTest.inventory(in: base)
        #expect(held.count == 1)
        #expect(held.first?.status == .removalReceipt, "\(held)")

        let again = TestArtifactRemoval.preview(in: base)
        #expect(again.refusals == [.nothingToRemove],
                "a receipt from the last removal blocks the next: \(again.lines)")
    }

    // MARK: Refusal 1 — nothing may be hidden

    /// While a test is running the live file is ABSENT and this folder holds
    /// the only copy of it.
    @Test("It refuses while a test is running")
    func itRefusesWhileSomethingIsHidden() throws {
        let base = try container(hidden: true)
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(!preview.canProceed)
        #expect(preview.refusals.contains(.somethingIsHidden(["athlete.json"])),
                "\(preview.refusals)")
    }

    // MARK: Refusal 2 — the live counterpart must exist AND read

    @Test("It refuses when the live file is not there")
    func itRefusesWithNoLiveCounterpart() throws {
        let base = try container(live: nil, snapshot: false)
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(preview.refusals.contains(.liveCounterpartMissing("athlete.json")),
                "\(preview.refusals)")
    }

    /// **EXISTS IS NOT READS.** A live `athlete.json` that stops part way makes
    /// the leftover the best copy on the phone, and that is the moment not to
    /// delete it. The reason is the classifier's own sentence — the same one
    /// the survey row shows (§12.43).
    @Test("It refuses when the live file is there and broken")
    func itRefusesWhenTheLiveFileIsBroken() throws {
        let base = try container(live: Self.brokenAthlete)
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        let refused = preview.refusals.contains { r in
            if case .liveCounterpartUnreadable(let name, _) = r { return name == "athlete.json" }
            return false
        }
        #expect(refused, "a truncated live file did not stop the removal: \(preview.refusals)")
    }

    // MARK: Refusal 3 — an allow-list, not a wildcard

    /// Something this control did not write is NAMED and left alone, rather
    /// than swept up with the rest — §12.132, over a delete.
    @Test("It refuses when the folder holds something it did not write")
    func itRefusesOverAStranger() throws {
        let base = try container(stranger: "left by something else")
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(preview.refusals.contains(.notAllowListed(["hidden-for-test/notes.txt"])),
                "\(preview.refusals)")
        #expect(!preview.canProceed)

        // And it really does not remove it.
        _ = TestArtifactRemoval.remove(confirming: preview, in: base,
                                       now: now, appVersion: version)
        let stranger = base.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("notes.txt")
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    // MARK: Refusal 4 — a verified snapshot holding this file

    @Test("It refuses without a complete snapshot holding the live file")
    func itRefusesWithNoSnapshot() throws {
        let base = try container(snapshot: false)
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(preview.refusals.contains(.noVerifiedSnapshot("athlete.json")),
                "\(preview.refusals)")
    }

    // MARK: The confirmation is a permission, not a lock

    /// **`remove` RE-EVALUATES.** A preview can be minutes old, and a test can
    /// have started in between.
    @Test("A stale confirmation does not carry")
    func aStaleConfirmationIsRefused() throws {
        let base = try container()
        defer { clean(base) }

        let preview = TestArtifactRemoval.preview(in: base)
        #expect(preview.canProceed)

        // The world moves after the reader agreed.
        _ = LegacyFileTest.hide(in: base)

        let outcome = TestArtifactRemoval.remove(confirming: preview, in: base,
                                                 now: now, appVersion: version)
        guard case .failure(let why) = outcome else {
            Issue.record("a stale confirmation removed a file while a test was running")
            return
        }
        #expect(why == .somethingIsHidden(["athlete.json"]))

        // And the leftover is still there.
        let kept = base.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("athlete.json.written-while-hidden")
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    // MARK: The preview always says something

    /// A preview that renders nothing when it cannot proceed reads like a
    /// permission — §12.15 over a delete button.
    @Test("Every preview state produces a line")
    func thePreviewIsUnconditional() throws {
        let empty = TestArtifactRemoval.preview(in: nil)
        #expect(empty.lines.count == 1)
        #expect(empty.lines[0].contains("unreachable"))

        let base = try container(leftover: nil)
        defer { clean(base) }
        let nothing = TestArtifactRemoval.preview(in: base)
        #expect(nothing.lines.contains { $0.contains("nothing to remove") },
                "\(nothing.lines)")

        let ready = try container()
        defer { clean(ready) }
        let lines = TestArtifactRemoval.preview(in: ready).lines
        #expect(lines.contains { $0.contains("would remove") })
        #expect(lines.contains { $0.contains("every check passed") })
        // The hash is in the preview, so the reader confirms a specific file
        // rather than a description of one.
        #expect(lines.contains { $0.count > 64 && $0.contains("bytes") })
    }
}
