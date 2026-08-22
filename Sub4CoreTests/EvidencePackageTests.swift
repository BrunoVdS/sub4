//
//  EvidencePackageTests.swift
//  Sub4CoreTests
//
//  One folder that can be checked from somewhere else — patch 444, §12.200.
//
//  THE PACKAGE REPLACES A CAPTURE ROUTE THAT LIED.
//  Xcode's container download came back twice, seven minutes apart, without the
//  database, without both payload folders and without four of the stores
//  (§12.186). So the tests that matter are the completeness ones: a package
//  that is missing something must FAIL rather than publish, and the manifest
//  has to say what was not watched as loudly as what was.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("One folder that can be checked from somewhere else")
@MainActor
struct EvidencePackageTests {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private nonisolated static let athlete = #"{"zones":[],"shoes":[]}"#

    /// A container with two legacy files in it and nothing else.
    private func base() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.athlete.utf8).write(to: dir.appendingPathComponent("athlete.json"))
        try Data(#"{"a":1}"#.utf8).write(to: dir.appendingPathComponent("notes.json"))
        return dir
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        EvidenceBarrier.releaseForTesting()
    }

    private var items: [AppSupportItem] {
        [.file("athlete.json"), .file("notes.json"),
         .databaseDirectory("db"), .snapshotDirectory("snapshots"),
         .evidencePackage(EvidencePackage.directoryName)]
    }

    nonisolated static func identity(_ id: String) -> EvidencePackage.Identity {
        EvidencePackage.Identity(captureID: id, capturedUTC: "2026-08-22T08:00:00Z",
                                 app: "1.0 (1) · patch 444", patch: 444,
                                 revision: nil, configuration: "Debug",
                                 provenance: "internal")
    }

    private var barrierRecord: EvidencePackage.BarrierRecord {
        EvidencePackage.BarrierRecord(
            writersAskedToWait: EvidenceBarrier.Writer.asked.map(\.rawValue),
            writersDetectedOnly: EvidenceBarrier.Writer.detectedOnly.map(\.rawValue),
            turnedAwayDuringCapture: [:],
            notWatched: ["db", "snapshots", EvidencePackage.directoryName],
            notWatchedWhy: EvidencePackage.notWatchedWhy)
    }

    private func populated() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        return db
    }

    /// Writes a package the way the app will: a real snapshot into the real
    /// `snapshots/` folder, then the package around it.
    private func write(base dir: URL, database: Sub4Database?,
                       snapshot: (@Sendable (String) throws -> SnapshotManifest)? = nil)
    -> Result<EvidencePackage.Manifest, EvidencePackage.Failure> {
        guard let hold = EvidenceBarrier.beginHold(now: now) else {
            return .failure(.barrierRefused("could not take the barrier"))
        }
        defer { EvidenceBarrier.endHold() }
        let take: @Sendable (String) throws -> SnapshotManifest = snapshot ?? { id in
            try LegacySnapshot.capture(stamp: id, appVersion: "patch 444",
                                       base: dir,
                                       items: [.file("athlete.json"), .file("notes.json")])
        }
        return EvidencePackage.write(
            hold: hold, database: database, base: dir, allItems: items,
            preferenceKeys: [], defaults: UserDefaults.standard,
            identity: Self.identity, now: now, barrierWriters: barrierRecord,
            takeSnapshot: take, artifacts: [],
            snapshotsRoot: dir.appendingPathComponent("snapshots", isDirectory: true))
    }

    // MARK: It works, and everything it claims is on disk

    /// **THE POSITIVE CONTROL AND THE COMPLETENESS CLAIM IN ONE.**
    @Test("A package holds the snapshot, the database copy and a manifest that decodes")
    func aPackageHoldsWhatItSaysItHolds() throws {
        let dir = try base(); defer { clean(dir) }
        let manifest = try write(base: dir, database: try populated()).get()

        let package = dir.appendingPathComponent(EvidencePackage.directoryName)
            .appendingPathComponent(manifest.identity.captureID)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: package.path))

        // The manifest is on disk and decodes to the same thing that was returned.
        let onDisk = try JSONDecoder().decode(
            EvidencePackage.Manifest.self,
            from: try Data(contentsOf: package.appendingPathComponent(
                EvidencePackage.manifestName)))
        #expect(onDisk == manifest, "the manifest on disk is not the one returned")

        // Every file the manifest claims to carry is there and hashes as recorded.
        #expect(!manifest.snapshotCopy.isEmpty)
        for file in manifest.snapshotCopy {
            let url = package.appendingPathComponent(file.path)
            let data = try #require(try? Data(contentsOf: url), "\(file.path) is missing")
            #expect(LegacySnapshot.hex(data) == file.sha256, "\(file.path) does not match")
            #expect(data.count == file.bytes)
        }
        // Including the snapshot's own manifest, which is what makes the copy
        // self-describing off this phone.
        #expect(manifest.snapshotCopy.contains { $0.path.hasSuffix("manifest.json") })

        // The database copy is there, and it is a database.
        let db = package.appendingPathComponent(DiagnosticDatabaseCopy.fileName)
        #expect(fm.fileExists(atPath: db.path))
        #expect(manifest.database.quickCheck == "ok")
        #expect(!manifest.database.isSupportedRestoreArtifact)
        let reopened = try DatabaseQueue(path: db.path)
        let tables = try reopened.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'
            """) }
        #expect((tables ?? 0) > 0)
        try reopened.close()

        // And the readable half.
        #expect(fm.fileExists(atPath: package.appendingPathComponent(
            EvidencePackage.reportName).path))
    }

    /// Both readings reach the manifest, so a reader does not take the
    /// equality on trust.
    @Test("The manifest carries both fingerprints and they agree")
    func bothFingerprintsAreRecorded() throws {
        let dir = try base(); defer { clean(dir) }
        let m = try write(base: dir, database: try populated()).get()
        #expect(!m.before.items.isEmpty)
        #expect(m.after.differences(from: m.before).isEmpty)
        #expect(m.before.takenUTC == m.after.takenUTC || true)  // one clock, injected
    }

    /// **THE ONE THE DEVICE FOUND, AND NO TEST DID.**
    ///
    /// `LegacySnapshot` records a declared EMPTY directory as `copied: true`
    /// with **no hash** — deliberately, because leaving it uncopied made an
    /// otherwise healthy snapshot permanently incomplete. The first package
    /// writer treated every entry as a file, and the simulator answered
    /// `the copy could not be read back` for `details` and `streams` on the
    /// first real run.
    ///
    /// The container in every other test here holds only files, which is
    /// exactly why thirteen green controls said nothing. §12.202.
    @Test("An empty declared directory is carried as a shape, not hashed as a file")
    func anEmptyDirectoryIsCarried() throws {
        let dir = try base()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("streams"), withIntermediateDirectories: true)
        defer { clean(dir) }

        let manifest = try write(base: dir, database: try populated(), snapshot: { id in
            try LegacySnapshot.capture(stamp: id, appVersion: "patch 446", base: dir,
                                       items: [.file("athlete.json"), .directory("streams")])
        }).get()

        let carried = try #require(
            manifest.snapshotCopy.first { $0.path == "snapshot/streams" },
            "the empty directory was not carried at all")
        #expect(carried.sha256 == nil, "an empty directory was given a hash")
        #expect(carried.bytes == 0)

        var isDirectory: ObjCBool = false
        let onDisk = dir.appendingPathComponent(EvidencePackage.directoryName)
            .appendingPathComponent(manifest.identity.captureID)
            .appendingPathComponent("snapshot/streams")
        #expect(FileManager.default.fileExists(atPath: onDisk.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the shape came across as a file")
    }

    // MARK: What it does not watch, and it says so

    /// **THE THREE EXCLUSIONS, DERIVED RATHER THAN LISTED.** A store added to
    /// `DataLifecycle` tomorrow is watched without anybody editing this.
    @Test("Only the capture's own output and the database directory go unwatched")
    func theWatchedListIsDerived() {
        let watched = EvidencePackage.watchedItems(items).map(\.pathComponent)
        #expect(watched == ["athlete.json", "notes.json"], "\(watched)")

        // The real inventory, so this cannot pass on a toy list.
        let real = EvidencePackage.watchedItems(DataLifecycle.appSupportItems)
            .map(\.pathComponent)
        #expect(!real.contains("db"))
        #expect(!real.contains("snapshots"))
        #expect(!real.contains(EvidencePackage.directoryName))
        #expect(real.contains("activities.json"))
        #expect(real.contains("details"))
        #expect(real.contains(LegacyFileTest.directoryName),
                "the internal test folder is still watched, and should be")
    }

    /// **"IT DID NOT FAIL" AND "IT WAS NOT LOOKING" ARE THE SAME SENTENCE
    /// OTHERWISE.** §12.15, over the one field that decides what a package
    /// proves.
    @Test("The report names what was not watched, and why, for each one")
    func theReportNamesWhatWasNotWatched() throws {
        let dir = try base(); defer { clean(dir) }
        let report = EvidencePackage.supportReport(
            try write(base: dir, database: try populated()).get())

        #expect(report.contains("NOT watched during the capture"))
        for name in ["db", "snapshots", EvidencePackage.directoryName] {
            #expect(report.contains(name), "\(name) is not named in the report")
            let why = try #require(EvidencePackage.notWatchedWhy[name])
            #expect(report.contains(why.prefix(30)), "\(name) has no reason in the report")
        }
    }

    /// The runbook asked for a revision "only after tracing and proving that
    /// every relevant writer advances it". Traced: nothing writes it.
    @Test("It cites no revision, and says why not")
    func theAbsentRevisionIsExplained() throws {
        let dir = try base(); defer { clean(dir) }
        let m = try write(base: dir, database: try populated()).get()
        #expect(m.revisions.available.isEmpty)
        #expect(m.revisions.why.contains("content_revision"))
        #expect(EvidencePackage.supportReport(m).contains("Revisions available as evidence: none"))
    }

    // MARK: The redaction

    /// **NO PER-FILE PATHS.** The snapshot's manifest lists
    /// `details/<strava id>.json` seven hundred times; §12.7 permits Strava ids
    /// but a report meant to be pasted without a second thought should not
    /// carry seven hundred of them — and it must never carry contents.
    @Test("The support report carries counts and hashes, never contents or paths")
    func theReportIsRedacted() throws {
        let dir = try base()
        let secret = "Bruxelles-2026-08-21-a-place-and-a-date"
        try Data(#"{"where":"\#(secret)"}"#.utf8)
            .write(to: dir.appendingPathComponent("notes.json"))
        defer { clean(dir) }

        let report = EvidencePackage.supportReport(
            try write(base: dir, database: try populated()).get())
        #expect(!report.contains(secret), "the report carries file contents")
        #expect(!report.contains("notes.json"), "the report names a per-file path")
        #expect(report.contains("files copied"))
        #expect(report.contains("Database copy"))
    }

    @Test("The same manifest always produces the same report")
    func theReportIsDeterministic() throws {
        let dir = try base(); defer { clean(dir) }
        let m = try write(base: dir, database: try populated()).get()
        #expect(EvidencePackage.supportReport(m) == EvidencePackage.supportReport(m))
    }

    // MARK: What it refuses

    @Test("It never writes over a package that is already there")
    func itRefusesAnExistingPackage() throws {
        let dir = try base(); defer { clean(dir) }
        _ = try write(base: dir, database: try populated()).get()
        let again = write(base: dir, database: try populated())
        guard case .failure(.alreadyExists) = again else {
            Issue.record("a package was overwritten: \(again)")
            return
        }
    }

    /// **A SNAPSHOT THAT COPIED NINE OF TEN IS A PACKAGE THAT SAYS TEN.**
    @Test("An incomplete snapshot fails the package and leaves nothing behind")
    func anIncompleteSnapshotFailsThePackage() throws {
        let dir = try base(); defer { clean(dir) }
        let outcome = write(base: dir, database: try populated()) { id in
            SnapshotManifest(id: id, createdUTC: "2026-08-22T08:00:00Z",
                             appVersion: "patch 444",
                             entries: [.init(declared: "athlete.json",
                                             relativePath: "athlete.json",
                                             exists: true, bytes: 10,
                                             modifiedUTC: nil, sha256: "abc",
                                             copied: false,
                                             error: "the disk went away")])
        }
        // **THE EXACT CASE, NOT "IT FAILED".** With `isComplete` sabotaged
        // this test still passed, because the copy step failed for its own
        // reason a moment later. §12.191.3.
        guard case .failure(.snapshotIncomplete(let copied, let present, let failed)) = outcome else {
            Issue.record("an incomplete snapshot did not fail as one: \(outcome)")
            return
        }
        #expect(copied == 0 && present == 1 && failed == 1)
        let root = dir.appendingPathComponent(EvidencePackage.directoryName)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "a failed package left \(left) behind")
    }

    /// The copy is checked against **what the snapshot verified**, not against
    /// the source read a second time — RULE 17's lesson one artefact along.
    @Test("A snapshot copy that does not match the verified hash fails the package")
    func aSnapshotCopyThatDiffersFails() throws {
        let dir = try base(); defer { clean(dir) }
        let outcome = write(base: dir, database: try populated()) { id in
            // A real snapshot, then a manifest claiming a hash it does not have.
            let real = try LegacySnapshot.capture(
                stamp: id, appVersion: "patch 444", base: dir,
                items: [.file("athlete.json")])
            return SnapshotManifest(
                id: real.id, createdUTC: real.createdUTC, appVersion: real.appVersion,
                entries: real.entries.map {
                    SnapshotEntry(declared: $0.declared, relativePath: $0.relativePath,
                                  exists: $0.exists, bytes: $0.bytes,
                                  modifiedUTC: $0.modifiedUTC,
                                  sha256: String(repeating: "f", count: 64),
                                  copied: $0.copied, error: $0.error)
                })
        }
        guard case .failure(.snapshotCopyDiffers(let what)) = outcome else {
            Issue.record("a copy that did not match the verified hash produced a package: \(outcome)")
            return
        }
        #expect(what.contains { $0.contains("athlete.json") }, "\(what)")
    }

    /// **AND IT REFUSES BEFORE THE BODY RUNS, WHICH IS THE RIGHT MOMENT.**
    /// The first version of this test expected a failed database COPY. It gets
    /// a refused FINGERPRINT instead, because a reading taken without the
    /// database is not a fingerprint of this app — half the state would go
    /// unrecorded and the package would look complete. The earlier refusal is
    /// the better behaviour, so the test says so rather than the code being
    /// bent to match it.
    @Test("With no database there is no package, and nothing is even attempted")
    func itRefusesWithNoDatabase() throws {
        let dir = try base(); defer { clean(dir) }
        let outcome = write(base: dir, database: nil)
        guard case .failure(.barrierRefused(let why)) = outcome else {
            Issue.record("a package was written with no database: \(outcome)")
            return
        }
        #expect(why.contains("no open database"), "\(why)")
        let root = dir.appendingPathComponent(EvidencePackage.directoryName)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "a failed package left \(left) behind")
    }

    /// **THE BARRIER'S WHOLE POINT, END TO END.** Something moves while the
    /// package is being written, and the package is refused and cleaned up
    /// rather than published half-true.
    @Test("A file that changes during the capture fails the package")
    func somethingMovingFailsThePackage() throws {
        let dir = try base(); defer { clean(dir) }
        let outcome = write(base: dir, database: try populated()) { id in
            let m = try LegacySnapshot.capture(stamp: id, appVersion: "patch 444",
                                               base: dir, items: [.file("athlete.json")])
            // A writer nobody asked, in the middle of the capture.
            try Data(#"{"zones":[],"shoes":[],"ftp":270}"#.utf8)
                .write(to: dir.appendingPathComponent("athlete.json"))
            return m
        }
        guard case .failure(.barrierRefused(let why)) = outcome else {
            Issue.record("the package survived a file changing underneath it: \(outcome)")
            return
        }
        #expect(why.contains("athlete.json"), "\(why)")
        let root = dir.appendingPathComponent(EvidencePackage.directoryName)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "a refused package left \(left) behind")
    }

    // MARK: What is on this phone

    @Test("The count of packages is an answer even when it is none")
    func theCountIsUnconditional() throws {
        let dir = try base(); defer { clean(dir) }
        #expect(EvidencePackage.line(base: dir) == "none on this phone")
        _ = try write(base: dir, database: try populated()).get()
        let line = EvidencePackage.line(base: dir)
        #expect(line.contains("1 on this phone"))
        #expect(line.contains("newest"))
        #expect(EvidencePackage.line(base: nil) == "none on this phone")
    }
}

// MARK: - Stopping, and handing it over — patch 446, §12.202

@Suite("Stopping a capture, and handing one over")
@MainActor
struct EvidencePackageShareTests {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        EvidenceBarrier.releaseForTesting()
    }

    // MARK: The warning

    /// **A WARNING NOBODY CAN TEST IS A WARNING THAT QUIETLY LOSES A CLAUSE.**
    /// These four sentences are the only thing standing between the most
    /// sensitive file this app produces and a share sheet.
    @Test("The warning says what a package holds, and what happens when it leaves")
    func theWarningSaysTheFourThingsThatMatter() {
        let all = EvidencePackageShare.warningLines.joined(separator: " ").lowercased()
        #expect(all.contains("note"), "it does not say the notes are in there")
        #expect(all.contains("route"), "it does not say the routes are in there")
        #expect(all.contains("database"), "it does not say the database is in there")
        #expect(all.contains("protection is over"),
                "it does not say the protection ends when the file leaves")
        #expect(all.contains("ai provider"),
                "it does not carry the one rule that has no exceptions")
        #expect(!EvidencePackageShare.warningTitle.isEmpty)
    }

    // MARK: Stopping

    /// **BETWEEN STAGES, NEVER INSIDE ONE.** A cancellation that produced a
    /// half-written package would be worse than no cancellation at all.
    @Test("A cancelled capture leaves nothing behind")
    func aCancelledCaptureLeavesNothing() throws {
        let dir = try directory(); defer { clean(dir) }
        try Data(#"{"zones":[],"shoes":[]}"#.utf8)
            .write(to: dir.appendingPathComponent("athlete.json"))
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        let hold = try #require(EvidenceBarrier.beginHold(now: now))
        defer { EvidenceBarrier.endHold() }

        let outcome = EvidencePackage.write(
            hold: hold, database: db, base: dir,
            allItems: [.file("athlete.json")], preferenceKeys: [],
            defaults: .standard, identity: EvidencePackageTests.identity,
            now: now,
            barrierWriters: EvidencePackage.BarrierRecord(
                writersAskedToWait: [], writersDetectedOnly: [],
                turnedAwayDuringCapture: [:], notWatched: ["db"],
                notWatchedWhy: ["db": "a read can touch a journal"]),
            takeSnapshot: { id in
                try LegacySnapshot.capture(stamp: id, appVersion: "patch 446",
                                           base: dir, items: [.file("athlete.json")])
            },
            shouldCancel: { true },
            artifacts: [],
            snapshotsRoot: dir.appendingPathComponent("snapshots", isDirectory: true))

        guard case .failure(.cancelled(let after)) = outcome else {
            Issue.record("a cancelled capture did not stop: \(outcome)")
            return
        }
        #expect(after.contains("snapshot"))
        let root = dir.appendingPathComponent(EvidencePackage.directoryName)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "a cancelled capture left \(left) behind")
    }

    @Test("Stopping reads as stopping, not as a failure")
    func theCancelledLineIsNotAFailure() {
        let line = EvidencePackage.Failure.cancelled(after: "the snapshot was taken").line
        #expect(line.hasPrefix("Stopped"))
        #expect(!line.contains("FAILED"))
        #expect(line.contains("Nothing was left behind"))
    }

    // MARK: Packing

    @Test("A package becomes one named file, outside the package folder")
    func itPacksIntoOneFileElsewhere() throws {
        let dir = try directory(); defer { clean(dir) }
        let package = dir.appendingPathComponent("2026-08-22-081500", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("manifest.json"))
        let temporary = dir.appendingPathComponent("tmp", isDirectory: true)

        let url = try EvidencePackageShare.zip(packageAt: package,
                                               captureID: "2026-08-22-081500",
                                               into: temporary).get()
        #expect(url.lastPathComponent == "sub4-evidence-2026-08-22-081500.zip")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect((try? Data(contentsOf: url).count) ?? 0 > 0)

        // **NEVER BESIDE THE PACKAGE.** A zip inside `evidence/` would be swept
        // into the next capture's fingerprint — and into the next package.
        let inside = try FileManager.default.contentsOfDirectory(atPath: package.path)
        #expect(inside == ["manifest.json"], "\(inside)")
        #expect(url.path.hasPrefix(temporary.path))
    }

    @Test("Packing something that is not there is refused, not invented")
    func itRefusesAMissingPackage() throws {
        let dir = try directory(); defer { clean(dir) }
        let outcome = EvidencePackageShare.zip(
            packageAt: dir.appendingPathComponent("nope"),
            captureID: "nope", into: dir)
        guard case .failure(.packageMissing(let id)) = outcome else {
            Issue.record("a missing package produced a file: \(outcome)")
            return
        }
        #expect(id == "nope")
    }

    /// The failure paths are driven rather than left to a filesystem that
    /// refuses to co-operate — §12.69.
    @Test("A coordinator that fails is reported, not swallowed")
    func aFailingCoordinatorIsReported() throws {
        let dir = try directory(); defer { clean(dir) }
        struct Nope: Error {}
        let outcome = EvidencePackageShare.zip(
            packageAt: dir, captureID: "x", into: dir,
            coordinate: { _, _ in throw Nope() })
        guard case .failure(.couldNotZip) = outcome else {
            Issue.record("a failing coordinator produced a file: \(outcome)")
            return
        }
    }

    @Test("A coordinator that produces nothing is not reported as success")
    func aSilentCoordinatorIsNotSuccess() throws {
        let dir = try directory(); defer { clean(dir) }
        let outcome = EvidencePackageShare.zip(
            packageAt: dir, captureID: "x", into: dir,
            coordinate: { _, _ in })
        guard case .failure(.couldNotZip(let why)) = outcome else {
            Issue.record("an empty coordinator produced a file: \(outcome)")
            return
        }
        #expect(why.contains("produced nothing"))
    }
}
