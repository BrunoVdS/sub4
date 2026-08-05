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
