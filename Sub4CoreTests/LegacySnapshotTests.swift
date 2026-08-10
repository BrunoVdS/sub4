//
//  LegacySnapshotTests.swift
//  Sub4CoreTests
//
//  The protected snapshot — patch 247, migration contract item 3.
//
//  EVERY TEST HERE RUNS AGAINST A REAL TEMPORARY DIRECTORY, not a mock.
//  `LegacySnapshot` takes its base URL, its item list and its `FileManager` as
//  arguments precisely so this is possible, and the reason it matters is that
//  the thing under test IS file behaviour: copy semantics, missing files,
//  directory expansion, and a hash of bytes that actually left the disk. A fake
//  file system would test the fake.
//
//  WHAT IS DELIBERATELY NOT TESTED HERE
//  ------------------------------------
//  File protection. `FileProtection.protect` sets a `.protectionKey` attribute
//  that simply does not exist on macOS, where this suite runs, and asserting it
//  would produce a test that is green for the wrong reason on the simulator and
//  says nothing about the phone. `FileProtectionTests` already covers the
//  policy; the device is what verifies the class.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct LegacySnapshotTests {

    // MARK: A disposable Application Support

    /// A temporary directory laid out like Application Support, with whatever
    /// files a test asks for. Returned with its own `FileManager` so nothing
    /// here can touch the real container.
    private func makeBase(files: [String: String],
                          directories: [String: [String: String]] = [:]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: base.appendingPathComponent(name))
        }
        for (dir, contents) in directories {
            let d = base.appendingPathComponent(dir, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for (name, body) in contents {
                try Data(body.utf8).write(to: d.appendingPathComponent(name))
            }
        }
        return base
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A small stand-in inventory. The real one is asserted separately, in
    /// `theRealInventoryIsWhatGetsCaptured` — these shape tests want a list
    /// they can control.
    private let items: [AppSupportItem] = [
        .file("notes.json"),
        .file("weather.json"),
        .legacyFile("details.json"),
        .directory("streams"),
        .databaseDirectory("db"),
        .snapshotDirectory("snapshots")
    ]

    // MARK: Planning — what will be captured, before anything is copied

    @Test("Every declared path appears, present or not")
    func nothingDeclaredIsSkipped() throws {
        let base = try makeBase(files: ["notes.json": "{}"],
                                directories: ["streams": ["1.json": "{}"]])
        defer { remove(base) }

        let plan = LegacySnapshot.plan(base: base, items: items)
        let declared = Set(plan.map(\.declared))
        #expect(declared == ["notes.json", "weather.json", "details.json", "streams"],
                "declared set is \(declared.sorted())")
    }

    @Test("A declared file that is not there is recorded as missing, not dropped")
    func missingIsRecorded() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        let plan = LegacySnapshot.plan(base: base, items: items)
        let weather = try #require(plan.first { $0.declared == "weather.json" })
        #expect(weather.exists == false)
        #expect(weather.sha256 == nil)
        #expect(weather.bytes == nil)
        // The point of the whole row: a file that vanishes from a list reads as
        // one that was never expected.
        #expect(weather.error == nil, "absent is not an error — see contract item 2")
    }

    @Test("A missing directory is one row, not zero")
    func aMissingDirectoryStillAppears() throws {
        let base = try makeBase(files: [:])
        defer { remove(base) }

        let plan = LegacySnapshot.plan(base: base, items: items)
        let streams = plan.filter { $0.declared == "streams" }
        #expect(streams.count == 1)
        #expect(streams.first?.exists == false)
    }

    @Test("A directory becomes one row per file")
    func directoriesExpand() throws {
        let base = try makeBase(files: [:],
                                directories: ["streams": ["1.json": "a", "2.json": "b", "3.json": "c"]])
        defer { remove(base) }

        let rows = LegacySnapshot.plan(base: base, items: items)
            .filter { $0.declared == "streams" }
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.relativePath))
                == ["streams/1.json", "streams/2.json", "streams/3.json"])
    }

    @Test("The database and the snapshots themselves are never captured")
    func theOutputIsNotAnInput() throws {
        let base = try makeBase(files: [:],
                                directories: ["db": ["sub4.sqlite": "x"],
                                              "snapshots": ["old": "y"]])
        defer { remove(base) }

        let declared = Set(LegacySnapshot.plan(base: base, items: items).map(\.declared))
        #expect(declared.contains("db") == false,
                "the database is the migration's destination, not its input")
        #expect(declared.contains("snapshots") == false,
                "a capture that walks its own output grows without bound")
    }

    // MARK: Hashing

    @Test("Hashing the same file twice gives the same digest")
    func hashingIsDeterministic() throws {
        let base = try makeBase(files: ["notes.json": "the same bytes every time"])
        defer { remove(base) }

        let url = base.appendingPathComponent("notes.json")
        let a = LegacySnapshot.describe(declared: "notes.json", relative: "notes.json", url: url)
        let b = LegacySnapshot.describe(declared: "notes.json", relative: "notes.json", url: url)
        #expect(a.sha256 == b.sha256)
        #expect(a.sha256 != nil)
    }

    @Test("Different bytes hash differently — the check is not a constant")
    func hashingDiscriminates() throws {
        let base = try makeBase(files: ["notes.json": "one", "weather.json": "two"])
        defer { remove(base) }

        let a = LegacySnapshot.describe(declared: "a", relative: "a",
                                        url: base.appendingPathComponent("notes.json"))
        let b = LegacySnapshot.describe(declared: "b", relative: "b",
                                        url: base.appendingPathComponent("weather.json"))
        #expect(a.sha256 != b.sha256)
    }

    @Test("Byte count is the file's own, not the hash's")
    func bytesAreMeasured() throws {
        let body = String(repeating: "x", count: 4096)
        let base = try makeBase(files: ["notes.json": body])
        defer { remove(base) }

        let e = LegacySnapshot.describe(declared: "notes.json", relative: "notes.json",
                                        url: base.appendingPathComponent("notes.json"))
        #expect(e.bytes == 4096)
    }

    // MARK: Capturing

    @Test("The copy is byte-identical and the original stays where it was")
    func captureCopiesAndDoesNotMove() throws {
        let base = try makeBase(files: ["notes.json": "{\"w01-mon\":{}}"],
                                directories: ["streams": ["11111111.json": "[1,2,3]"]])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                           appVersion: "247",
                                           base: base, items: items)
        #expect(m.isComplete)
        #expect(m.copiedCount == 2)

        let fm = FileManager.default
        // COPY, NEVER MOVE — the contract's word, and the one that matters most.
        #expect(fm.fileExists(atPath: base.appendingPathComponent("notes.json").path))
        #expect(fm.fileExists(atPath: base.appendingPathComponent("streams/11111111.json").path))

        let folder = base.appendingPathComponent("snapshots/2026-08-05-120000", isDirectory: true)
        let copied = try Data(contentsOf: folder.appendingPathComponent("notes.json"))
        let original = try Data(contentsOf: base.appendingPathComponent("notes.json"))
        #expect(copied == original)
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("streams/11111111.json").path),
                "the directory structure was flattened")
    }

    @Test("The manifest is written beside the copies and decodes on its own")
    func theManifestIsSelfDescribing() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                       base: base, items: items)
        let url = base.appendingPathComponent("snapshots/2026-08-05-120000/manifest.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SnapshotManifest.self, from: data)
        #expect(decoded.id == "2026-08-05-120000")
        #expect(decoded.appVersion == "247")
        #expect(decoded.entries.isEmpty == false)
    }

    @Test("A snapshot survives being read back — this is the relaunch case")
    func itCanBeReadBack() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                       base: base, items: items)
        // Nothing of the capture is held in memory here. This is what the
        // health screen does on a cold launch.
        let latest = try #require(LegacySnapshot.latest(base: base))
        #expect(latest.id == "2026-08-05-120000")
        #expect(latest.presentCount == 1)
    }

    @Test("A missing file is missing IN THE MANIFEST, not absent from it")
    func theManifestKeepsTheGaps() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                           base: base, items: items)
        #expect(m.missingCount == 3, "weather.json, details.json and streams/ are all absent")
        let weather = try #require(m.entries.first { $0.declared == "weather.json" })
        #expect(weather.exists == false)
        #expect(weather.copied == false)
        // A deliberately deleted file must show as missing rather than
        // vanishing from the list. That is the acceptance criterion.
        #expect(m.entries.contains { $0.declared == "weather.json" })
    }

    @Test("Snapshots are never overwritten")
    func aSecondCaptureWithTheSameStampRefuses() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                       base: base, items: items)
        #expect(throws: SnapshotError.self) {
            try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                       base: base, items: items)
        }
    }

    @Test("Two captures are two snapshots, newest first")
    func capturesAccumulate() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                       base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000", appVersion: "247",
                                       base: base, items: items)
        #expect(LegacySnapshot.ids(base: base) == ["2026-08-05-130000", "2026-08-05-120000"])
        #expect(LegacySnapshot.latest(base: base)?.id == "2026-08-05-130000")
    }

    @Test("The second capture is not affected by the first")
    func aCaptureDoesNotCaptureTheEarlierOne() throws {
        let base = try makeBase(files: ["notes.json": "{}"],
                                directories: ["streams": ["1.json": "a", "2.json": "b"]])
        defer { remove(base) }

        let first = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "247",
                                               base: base, items: items)
        let second = try LegacySnapshot.capture(stamp: "2026-08-05-130000", appVersion: "247",
                                                base: base, items: items)
        // If `snapshots/` were walked, the second would hold the first as well
        // and every capture would be larger than the last until the disk filled.
        #expect(first.copiedCount == second.copiedCount)
        #expect(first.totalBytes == second.totalBytes)
    }

    @Test("One instant supplies both the folder id and createdUTC")
    func captureTimeHasOneSource() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }
        let instant = Date(timeIntervalSince1970: 946_684_800)

        let result = try LegacySnapshot.capture(at: instant, appVersion: "338",
                                                base: base, items: items)
        #expect(result.manifest.id == "2000-01-01-000000")
        #expect(result.manifest.createdUTC == "2000-01-01T00:00:00Z")
        #expect(result.manifest.createdDate == instant)
    }

    @Test("A third complete snapshot keeps the newest two and receipts the oldest")
    func retentionKeepsTwoVerifiedCopies() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                       appVersion: "338", base: base, items: items)
        try Data("two".utf8).write(to: base.appendingPathComponent("notes.json"))
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)
        let firstManifestURL = base.appendingPathComponent(
            "snapshots/2026-08-05-120000/manifest.json")
        let firstManifest = try Data(contentsOf: firstManifestURL)

        try Data("three".utf8).write(to: base.appendingPathComponent("notes.json"))
        let thirdDate = try #require(
            LegacySnapshot.date(fromStamp: "2026-08-05-140000"))
        let third = try LegacySnapshot.capture(at: thirdDate,
                                               appVersion: "338",
                                               base: base,
                                               items: items)

        #expect(third.retention.pruned.map(\.id) == ["2026-08-05-120000"])
        #expect(LegacySnapshot.ids(base: base)
                == ["2026-08-05-140000", "2026-08-05-130000"])
        #expect(!FileManager.default.fileExists(atPath: firstManifestURL.path))

        let receiptURL = base.appendingPathComponent(
            "snapshots/receipt-2026-08-05-120000.json")
        let receipt = try JSONDecoder().decode(
            SnapshotReceipt.self, from: Data(contentsOf: receiptURL))
        #expect(receipt.manifestSHA256 == LegacySnapshot.hex(firstManifest))
        #expect(receipt.manifest.id == "2026-08-05-120000")
        #expect(receipt.manifest.entries.contains {
            $0.relativePath == "notes.json" && $0.copied
        })
        #expect(receipt.capturedUTC == "2026-08-05T12:00:00Z")
        #expect(receipt.prunedByAppVersion == "338")
    }

    @Test("Clock rollback cannot prune the snapshot that triggered retention")
    func aNewCaptureIsAlwaysProtected() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-140000",
                                       appVersion: "338", base: base, items: items)

        // The device clock moved backwards. The new capture sorts older than
        // both existing folders, but it is the one whose success authorised
        // retention and therefore may never delete itself.
        let rolledBack = try #require(
            LegacySnapshot.date(fromStamp: "2026-08-05-120000"))
        let result = try LegacySnapshot.capture(at: rolledBack,
                                                appVersion: "338",
                                                base: base, items: items)
        let ids = LegacySnapshot.ids(base: base)
        #expect(ids.contains(result.manifest.id))
        #expect(ids == ["2026-08-05-140000", "2026-08-05-120000"])
        #expect(LegacySnapshot.hasReceipt("2026-08-05-130000", base: base))
    }

    @Test("A pruned id remains reserved by its audit receipt")
    func receiptPreventsIDReuse() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }
        for stamp in ["2026-08-05-120000", "2026-08-05-130000",
                      "2026-08-05-140000"] {
            _ = try LegacySnapshot.capture(stamp: stamp,
                                           appVersion: "338",
                                           base: base, items: items)
        }
        #expect(LegacySnapshot.hasReceipt("2026-08-05-120000", base: base))
        #expect(throws: SnapshotError.self) {
            _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                           appVersion: "338",
                                           base: base, items: items)
        }
    }

    @Test("A decodable empty manifest cannot displace a real fallback")
    func emptyManifestIsNotVerified() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                       appVersion: "338", base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)

        let emptyFolder = base.appendingPathComponent(
            "snapshots/2026-08-05-150000", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder,
                                                withIntermediateDirectories: true)
        let empty = SnapshotManifest(id: "2026-08-05-150000",
                                     createdUTC: "2026-08-05T15:00:00Z",
                                     appVersion: "338", entries: [])
        try JSONEncoder().encode(empty).write(
            to: emptyFolder.appendingPathComponent("manifest.json"))

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-140000",
                                       appVersion: "338", base: base, items: items)
        let ids = LegacySnapshot.ids(base: base)
        #expect(ids.contains("2026-08-05-150000"),
                "untrusted folders are retained for inspection")
        #expect(ids.contains("2026-08-05-140000"))
        #expect(ids.contains("2026-08-05-130000"),
                "the newest genuine fallback was not displaced")
        #expect(LegacySnapshot.hasReceipt("2026-08-05-120000", base: base))
    }

    @Test("A tampered full snapshot is retained but cannot authorise deletion")
    func tamperedPayloadDoesNotCountAsFallback() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                       appVersion: "338", base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)
        try Data("changed after capture".utf8).write(to: base.appendingPathComponent(
            "snapshots/2026-08-05-130000/notes.json"))

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-140000",
                                       appVersion: "338", base: base, items: items)
        let ids = LegacySnapshot.ids(base: base)
        #expect(ids.contains("2026-08-05-130000"),
                "the suspect folder remains available for diagnosis")
        #expect(ids.contains("2026-08-05-120000"),
                "a verified fallback is not pruned for a tampered one")
        #expect(!LegacySnapshot.hasReceipt("2026-08-05-120000", base: base))
    }

    @Test("A receipt conflict leaves the full snapshot and reports a warning")
    func receiptConflictIsNonDestructive() throws {
        let base = try makeBase(files: ["notes.json": "one"])
        defer { remove(base) }
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                       appVersion: "338", base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)
        let conflict = base.appendingPathComponent(
            "snapshots/receipt-2026-08-05-120000.json")
        try Data("existing audit data".utf8).write(to: conflict)

        let captured = try LegacySnapshot.capture(
            stamp: "2026-08-05-140000", appVersion: "338",
            base: base, items: items)
        #expect(captured.isComplete)
        #expect(LegacySnapshot.ids(base: base).contains("2026-08-05-120000"))
        let report = LegacySnapshot.enforceRetention(
            protectedID: "2026-08-05-140000", appVersion: "338", base: base)
        #expect(!report.warnings.isEmpty)
        #expect(LegacySnapshot.ids(base: base).contains("2026-08-05-120000"))
    }

    @Test("Audit receipts have their own bounded retention")
    func receiptsDoNotBecomeTheNextUnboundedStore() throws {
        let base = try makeBase(files: ["notes.json": "same"])
        defer { remove(base) }
        for minute in 0 ..< LegacySnapshot.keepReceipts + 3 {
            let stamp = String(format: "2026-08-05-12%02d00", minute)
            _ = try LegacySnapshot.capture(stamp: stamp,
                                           appVersion: "338",
                                           base: base, items: items)
        }
        let root = base.appendingPathComponent("snapshots", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let receipts = names.filter {
            $0.hasPrefix("receipt-") && $0.hasSuffix(".json")
        }
        #expect(receipts.count == LegacySnapshot.keepReceipts)
        #expect(LegacySnapshot.ids(base: base).count == LegacySnapshot.keepSnapshots)
    }

    @Test("A future receipt schema is never pruned as if this build understood it")
    func unknownReceiptVersionsArePreserved() throws {
        let base = try makeBase(files: ["notes.json": "same"])
        defer { remove(base) }
        for minute in 0 ..< 3 {
            let stamp = String(format: "2026-08-05-12%02d00", minute)
            _ = try LegacySnapshot.capture(stamp: stamp, appVersion: "338",
                                           base: base, items: items)
        }

        let root = base.appendingPathComponent("snapshots", isDirectory: true)
        let futureURL = root.appendingPathComponent(
            "receipt-2026-08-05-120000.json")
        let original = try Data(contentsOf: futureURL)
        var json = try #require(
            JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["schemaVersion"] = 999
        let future = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try future.write(to: futureURL, options: .atomic)

        for minute in 3 ..< LegacySnapshot.keepReceipts + 5 {
            let stamp = String(format: "2026-08-05-12%02d00", minute)
            _ = try LegacySnapshot.capture(stamp: stamp, appVersion: "338",
                                           base: base, items: items)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let receipts = names.filter {
            $0.hasPrefix("receipt-") && $0.hasSuffix(".json")
        }
        #expect(FileManager.default.fileExists(atPath: futureURL.path))
        #expect(receipts.count == LegacySnapshot.keepReceipts + 1,
                "twenty understood receipts plus the untouched future version")
    }

    @Test("An unreadable snapshot never displaces or deletes a verified fallback")
    func corruptSnapshotIsLeftUntouched() throws {
        let base = try makeBase(files: ["notes.json": "{}"])
        defer { remove(base) }
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                       appVersion: "338", base: base, items: items)
        _ = try LegacySnapshot.capture(stamp: "2026-08-05-130000",
                                       appVersion: "338", base: base, items: items)

        let corrupt = base.appendingPathComponent(
            "snapshots/2026-08-05-133000", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt,
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))

        _ = try LegacySnapshot.capture(stamp: "2026-08-05-140000",
                                       appVersion: "338", base: base, items: items)
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(LegacySnapshot.ids(base: base).contains("2026-08-05-133000"))
        #expect(LegacySnapshot.hasReceipt("2026-08-05-120000", base: base))
    }

    @Test("A declared empty directory is copied and the snapshot is complete")
    func emptyDirectoryIsProtected() throws {
        let base = try makeBase(files: [:], directories: ["streams": [:]])
        defer { remove(base) }
        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000",
                                           appVersion: "338", base: base,
                                           items: items)
        #expect(m.isComplete)
        let streams = try #require(m.entries.first { $0.declared == "streams" })
        #expect(streams.copied)
        var isDirectory: ObjCBool = false
        let copied = base.appendingPathComponent(
            "snapshots/2026-08-05-120000/streams")
        #expect(FileManager.default.fileExists(atPath: copied.path,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Receipt files are not mistaken for snapshot folders")
    func idsIgnoreReceipts() throws {
        let base = try makeBase(files: [:])
        defer { remove(base) }
        let root = base.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent(
            "receipt-2026-08-05-120000.json"))
        #expect(LegacySnapshot.ids(base: base).isEmpty)
    }

    @Test("Declared preferences are preserved losslessly, including Data")
    @MainActor
    func preferencesAreProtected() throws {
        let base = try makeBase(files: [:])
        defer { remove(base) }
        let binary = Data([0, 1, 2, 255])
        let date = Date(timeIntervalSince1970: 946_684_800)
        let supplement = try LegacySnapshot.preferenceSupplement(
            keys: ["strava.rejections", "detail.noStreams", "flag", "count",
                   "when", "absent"],
            values: ["strava.rejections": binary,
                     "detail.noStreams": ["16415953236"],
                     "flag": true, "count": 7, "when": date])
        let result = try LegacySnapshot.capture(
            at: Date(timeIntervalSince1970: 946_684_800), appVersion: "338",
            base: base, items: items, supplements: [supplement])
        let stored = try Data(contentsOf: base.appendingPathComponent(
            "snapshots/2000-01-01-000000/preferences.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: stored,
                                                    options: [], format: nil)
                as? [String: Any])
        let values = try #require(plist["values"] as? [String: Any])
        #expect(values["strava.rejections"] as? Data == binary)
        #expect((values["detail.noStreams"] as? [String]) == ["16415953236"])
        #expect(values["flag"] as? Bool == true)
        #expect(values["count"] as? Int == 7)
        #expect(values["when"] as? Date == date)
        #expect(values["absent"] == nil)
        #expect(result.manifest.entries.contains {
            $0.relativePath == "preferences.plist" && $0.copied
        })
    }

    @Test("A supplement cannot escape or overwrite the snapshot folder")
    func supplementalPathsAreConfined() throws {
        let base = try makeBase(files: [:])
        defer { remove(base) }
        for path in ["../outside.plist", "/absolute.plist", "manifest.json"] {
            let supplement = SnapshotSupplement(declared: "test",
                                                relativePath: path,
                                                data: Data([1]))
            #expect(throws: SnapshotError.self) {
                _ = try LegacySnapshot.capture(
                    at: Date(timeIntervalSince1970: 946_684_800),
                    appVersion: "338", base: base, items: items,
                    supplements: [supplement])
            }
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(
                "snapshots/2000-01-01-000000").path))
        }
    }

    @Test("The production preference inventory is the archive boundary")
    @MainActor
    func productionPreferenceInventoryIsDeclared() throws {
        let supplement = try LegacySnapshot.preferenceSupplement(
            keys: DataLifecycle.preferenceKeys, values: [:])
        let plist = try #require(
            PropertyListSerialization.propertyList(from: supplement.data,
                                                    options: [], format: nil)
                as? [String: Any])
        let declared = try #require(plist["declaredKeys"] as? [String])
        #expect(declared == DataLifecycle.preferenceKeys.sorted())
    }

    @Test("Legacy folder-shaped createdUTC remains readable but is not a date")
    func oldCreatedUTCIsNotInvented() {
        let old = SnapshotManifest(id: "2026-08-09-143235",
                                   createdUTC: "2026-08-09-143235",
                                   appVersion: "337b", entries: [])
        #expect(old.createdDate == nil)
    }

    // MARK: The stamp

    @Test("The stamp sorts chronologically as a string")
    func stampsSort() {
        let early = LegacySnapshot.stamp(for: Date(timeIntervalSince1970: 1_000_000))
        let late = LegacySnapshot.stamp(for: Date(timeIntervalSince1970: 2_000_000))
        #expect(early < late)
        // `ids()` sorts strings and calls the result chronological. If the
        // format ever stopped sorting that way, "the last snapshot" would
        // silently become "some snapshot".
        #expect(early.count == "yyyy-MM-dd-HHmmss".count)
    }

    @Test("The stamp is UTC and does not depend on where the phone is")
    func stampsAreUTC() {
        // 1 January 2000, 00:00:00 UTC. In Brussels that is 01:00 the same day,
        // and a stamp that moved with the reader's zone would produce two
        // different folder names for one instant.
        let instant = Date(timeIntervalSince1970: 946_684_800)
        #expect(LegacySnapshot.stamp(for: instant) == "2000-01-01-000000")
    }

    // MARK: The real inventory

    @Test("Every legacy input the inventory declares would be captured")
    @MainActor
    func theRealInventoryIsWhatGetsCaptured() throws {
        // Not a shape test — this is the acceptance criterion, against the real
        // list. A store added to `DataLifecycle` without thought is captured
        // automatically; one that is deliberately excluded has to be excluded
        // by case, in `plan`, where the reason is written down.
        let expected = Set(DataLifecycle.appSupportItems.compactMap { item -> String? in
            switch item {
            case .databaseDirectory, .snapshotDirectory: nil
            case .file(let n), .legacyFile(let n), .directory(let n): n
            }
        })
        let base = try makeBase(files: [:])
        defer { remove(base) }

        let planned = Set(LegacySnapshot.plan(base: base,
                                              items: DataLifecycle.appSupportItems).map(\.declared))
        #expect(planned == expected,
                "not planned: \(expected.subtracting(planned).sorted()); unexpected: \(planned.subtracting(expected).sorted())")
    }

    @Test("The snapshot directory is declared, so Delete local data removes it")
    @MainActor
    func theSnapshotIsDeletable() {
        let declared = DataLifecycle.appSupportItems
            .contains { if case .snapshotDirectory = $0 { return true }; return false }
        #expect(declared,
                """
                    a folder of copies of the athlete's files that no delete flow \
                    knows about is a privacy defect introduced by a privacy measure
                    """)
    }

    // MARK: The redacted diagnostic — patch 248

    @Test("The diagnostic names which declared paths are missing")
    func theDiagnosticNamesTheGaps() throws {
        let base = try makeBase(files: ["notes.json": "{}"],
                                directories: ["streams": ["1.json": "aa", "2.json": "bb"]])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "248",
                                           base: base, items: items)
        let text = m.redactedLines.joined(separator: "\n")
        // The question the five numbers on screen could not answer.
        #expect(text.contains("weather.json       NOT PRESENT"),
                "the missing file is not named:\n\(text)")
        #expect(text.contains("details.json       NOT PRESENT"))
        #expect(text.contains("notes.json         present"))
    }

    @Test("A directory is reported as a count, which is the other open question")
    func theDiagnosticCountsDirectories() throws {
        let base = try makeBase(files: [:],
                                directories: ["streams": ["1.json": "a", "2.json": "b", "3.json": "c"]])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "248",
                                           base: base, items: items)
        let text = m.redactedLines.joined(separator: "\n")
        #expect(text.contains("streams            3 files"),
                "the directory count is not reported:\n\(text)")
    }

    @Test("No file inside a directory reaches the diagnostic")
    func noPathsLeakIntoTheDiagnostic() throws {
        // `details/18883849470.json` names a Strava activity, and the screen's
        // own footer promises no dates and no session names from the athlete's
        // history. Nine hundred activity ids would break that in the most
        // literal way available, so the rule is asserted rather than intended.
        let base = try makeBase(files: [:],
                                directories: ["streams": ["18883849470.json": "a",
                                                          "11111111.json": "b"]])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "248",
                                           base: base, items: items)
        for line in m.redactedLines {
            #expect(line.contains("/") == false, "a path reached the paste: \(line)")
            #expect(line.contains("18883849470") == false,
                    "an activity id reached the paste: \(line)")
        }
    }

    @Test("The diagnostic's totals agree with the manifest's own")
    func theDiagnosticDoesNotInventNumbers() throws {
        let base = try makeBase(files: ["notes.json": "{}", "weather.json": "{}"],
                                directories: ["streams": ["1.json": "a", "2.json": "b"]])
        defer { remove(base) }

        let m = try LegacySnapshot.capture(stamp: "2026-08-05-120000", appVersion: "248",
                                           base: base, items: items)
        let header = try #require(m.redactedLines.dropFirst().first)
        #expect(header.contains("\(m.copiedCount) of \(m.presentCount) copied"))
        #expect(header.contains("\(m.missingCount) not present"))
        #expect(header.contains("\(m.failureCount) failed"))
    }

    @Test("The declared snapshot folder is the one the code writes to")
    @MainActor
    func theNameAgrees() throws {
        let item = try #require(DataLifecycle.appSupportItems.first {
            if case .snapshotDirectory = $0 { return true }; return false
        })
        #expect(item.pathComponent == LegacySnapshot.directoryName)
        #expect(item.isDirectory)
    }
}
