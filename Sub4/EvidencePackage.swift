//
//  EvidencePackage.swift
//  Sub4
//
//  One folder that can be checked from somewhere else — patch 444,
//  ADR-0003 §12.200.
//
//  WHAT IT REPLACES
//  ----------------
//  Xcode's "Download Container", which on 21 August came back **twice, seven
//  minutes apart, without the 39 MB database, without `details/` and
//  `streams/`, and without four of the stores** — in both build configurations
//  — while the app's own snapshot counted 1,380 of 1,380 files a minute
//  earlier (§12.186). A capture route that silently omits most of what it is
//  capturing cannot be the authoritative input to anything.
//
//  So the app makes the package itself, and says exactly what is in it.
//
//  WHAT IS IN ONE
//  --------------
//  `evidence/<captureID>/`
//    · `snapshot/`                        a verified copy of a fresh protected
//                                         snapshot — every legacy file plus the
//                                         declared preferences, re-hashed here
//                                         against the snapshot's own manifest
//    · `database-diagnostic-copy.sqlite`  one commit boundary, through SQLite's
//                                         backup API (§12.199)
//    · `manifest.json`                    the private record binding them
//    · `support-report.txt`               the same facts with nothing private
//                                         in them, safe to paste
//
//  THE THREE DIRECTORIES THE FINGERPRINT DOES NOT WATCH, AND WHY
//  -------------------------------------------------------------
//  The barrier refuses a package when anything moved during the capture. Three
//  declared locations are excluded from that watch, and each for its own
//  reason — stated here because "it did not fail" and "it was not looking" are
//  the same sentence otherwise (§12.15):
//
//  1. **`evidence/`** — the capture's own output. Watching it would fail every
//     package for the crime of having been written.
//  2. **`snapshots/`** — also the capture's own output: taking a snapshot
//     writes a folder and prunes older ones.
//  3. **`db/`** — deliberately, and this one is a strengthening rather than a
//     hole. **A read alone can touch a WAL journal**, so byte-watching the
//     directory would fail captures at random; the database's CONTENT is
//     watched by row counts, integrity and the migration list instead, which
//     is what actually matters and what a byte comparison could never say.
//
//  The manifest records the exclusions BY NAME. A reader who cannot see what
//  was not watched cannot judge what the package proves.
//

import Foundation

nonisolated enum EvidencePackage {

    static let directoryName = "evidence"
    static let snapshotFolderName = "snapshot"
    static let manifestName = "manifest.json"
    static let reportName = "support-report.txt"
    static let schemaVersion = 1

    // MARK: What a package says about itself

    struct Identity: Codable, Sendable, Equatable {
        let captureID: String
        let capturedUTC: String
        let app: String
        let patch: Int
        let revision: String?
        let configuration: String
        let provenance: String
    }

    /// **THE HONEST ABSENCE — and the runbook asked for it in as many words.**
    ///
    /// It says to use a current revision as supporting evidence *"only after
    /// tracing and proving that every relevant writer advances it"*. Traced:
    /// `content_revision` has a table and **zero writers** — the only mention
    /// in the app is the `CREATE TABLE` in `2026-08-09-plan-content`. So there
    /// is no such revision, the package cites none, and it says why rather than
    /// leaving the field out. B8 is where one gets an authority.
    struct Revisions: Codable, Sendable, Equatable {
        let available: [String]
        let why: String

        static let asOfTaskZeroB = Revisions(
            available: [],
            why: "content_revision exists as a table and nothing writes it — "
               + "the only mention in the app is its CREATE TABLE. No revision "
               + "is advanced by every relevant writer, so this package cites "
               + "none. B8 is where operational state gets an authority.")
    }

    struct BarrierRecord: Codable, Sendable, Equatable {
        let writersAskedToWait: [String]
        let writersDetectedOnly: [String]
        let turnedAwayDuringCapture: [String: Int]
        /// Named, never implied. See the header.
        let notWatched: [String]
        let notWatchedWhy: [String: String]
    }

    struct CopiedFile: Codable, Sendable, Equatable {
        let path: String
        /// **NIL MEANS A DIRECTORY, AND THAT IS NOT A SHORTCUT.**
        ///
        /// `LegacySnapshot` records a declared EMPTY directory as copied with
        /// no hash — deliberately, because leaving it `copied == false` made an
        /// otherwise healthy snapshot permanently incomplete. So the package
        /// has to carry the shape without inventing a hash for it. The first
        /// draft did not, treated `details/` as a file, and the device answered
        /// `the copy could not be read back` on the first real run.
        let sha256: String?
        let bytes: Int
    }

    struct Manifest: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let identity: Identity
        let snapshotID: String
        let snapshot: SnapshotManifest
        /// The snapshot as it sits INSIDE the package, re-hashed here. A
        /// manifest that only carried the original's hashes would describe a
        /// folder somewhere else.
        let snapshotCopy: [CopiedFile]
        let database: DiagnosticDatabaseCopy.Reading
        let testArtifacts: [LegacyFileTest.Artifact]
        let revisions: Revisions
        let barrier: BarrierRecord
        let before: EvidenceBarrier.Fingerprint
        let after: EvidenceBarrier.Fingerprint
    }

    // MARK: Why it will not

    enum Failure: Equatable, Sendable, Error {
        case containerUnreachable
        case alreadyExists(String)
        case couldNotCreate(String)
        case snapshotFailed(String)
        case snapshotIncomplete(copied: Int, present: Int, failed: Int)
        case snapshotCopyDiffers([String])
        case databaseCopyFailed(String)
        case barrierRefused(String)
        case couldNotWriteManifest(String)
        /// **THE ATHLETE CHANGED THEIR MIND, AND NOTHING IS LEFT BEHIND.**
        case cancelled(after: String)

        var line: String {
            switch self {
            case .containerUnreachable:
                "REFUSED — Application Support is unreachable"
            case .alreadyExists(let id):
                "REFUSED — a package called \(id) is already there, and a package is written once"
            case .couldNotCreate(let why):
                "REFUSED — the package folder could not be created: \(why)"
            case .snapshotFailed(let why):
                "FAILED — the snapshot could not be taken: \(why)"
            case .snapshotIncomplete(let copied, let present, let failed):
                "FAILED — the snapshot copied \(copied) of \(present) files with \(failed) failures"
            case .snapshotCopyDiffers(let what):
                "FAILED — the snapshot inside the package does not match the one "
                + "that was verified: " + what.joined(separator: "; ")
            case .databaseCopyFailed(let why):
                "FAILED — \(why)"
            case .barrierRefused(let why):
                why
            case .couldNotWriteManifest(let why):
                "FAILED — the manifest could not be written: \(why)"
            case .cancelled(let after):
                "Stopped after \(after). Nothing was left behind."
            }
        }
    }

    // MARK: What the fingerprint watches

    /// **DERIVED, NOT LISTED.** Every declared location except the three the
    /// header names — so a store added to `DataLifecycle` tomorrow is watched
    /// without anybody remembering to add it here (§12.131.4).
    static func watchedItems(_ all: [AppSupportItem]) -> [AppSupportItem] {
        all.filter { item in
            switch item {
            case .databaseDirectory, .snapshotDirectory, .evidencePackage: false
            case .file, .directory, .legacyFile, .internalTestArtifact:    true
            }
        }
    }

    static let notWatchedWhy: [String: String] = [
        "evidence": "the capture's own output — watching it would fail every "
                  + "package for having been written",
        "snapshots": "also the capture's own output: taking a snapshot writes a "
                   + "folder and prunes older ones",
        "db": "a READ alone can touch a WAL journal, so byte-watching the "
            + "directory would fail captures at random. The database's content "
            + "is watched by row counts, integrity and the migration list "
            + "instead — which is what matters and what bytes could not say"
    ]

    // MARK: Making one

    /// - Parameter takeSnapshot: injected, so a test can drive the incomplete
    ///   and failed snapshot paths without needing a broken filesystem. §12.69.
    static func write(hold: EvidenceBarrier.Hold,
                      database: Sub4Database?,
                      base: URL?,
                      allItems: [AppSupportItem],
                      preferenceKeys: [String],
                      defaults: UserDefaults,
                      identity: @Sendable (String) -> Identity,
                      now: Date,
                      barrierWriters: BarrierRecord,
                      takeSnapshot: @Sendable (String) throws -> SnapshotManifest,
                      shouldCancel: @escaping @Sendable () -> Bool = { false },
                      /// The database copy's cancellation granularity. Passed
                      /// through rather than hidden, so the stopped-in-the-
                      /// backup path is drivable — a fixture database is a few
                      /// hundred pages and the production step is 256.
                      databasePagesPerStep: CInt = DiagnosticDatabaseCopy.defaultPagesPerStep,
                      artifacts: [LegacyFileTest.Artifact],
                      snapshotsRoot: URL?,
                      fm: FileManager = .default) -> Result<Manifest, Failure> {

        guard let base else { return .failure(.containerUnreachable) }
        let captureID = LegacySnapshot.stamp(for: now)
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        let dir = root.appendingPathComponent(captureID, isDirectory: true)
        guard !fm.fileExists(atPath: dir.path) else {
            return .failure(.alreadyExists(captureID))
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(.couldNotCreate(String(describing: error)))
        }
        FileProtection.protect(directory: root, using: fm)
        FileProtection.protect(directory: dir, using: fm)

        // **THE EXACT REASON SURVIVES THE BARRIER — patch 444.**
        //
        // The body throws, and the barrier wraps anything that is not its own
        // `Refusal` as `.couldNotRead(String(describing:))`. The first draft
        // tried to recover the case by matching that string, and it was lossy:
        // an incomplete snapshot came back as a generic failure, so the control
        // for it passed while checking a DIFFERENT path (§12.191.3 — a test
        // that fails for the wrong reason is a test that will pass when it
        // should not). Sabotaging `isComplete` proved it: nothing noticed.
        //
        // So the reason is carried out in a variable and the throw is only a
        // signal to stop.
        var innerFailure: Failure?
        struct Stop: Error {}

        let outcome = EvidenceBarrier.runInside(
            hold: hold,
            base: base,
            items: watchedItems(allItems),
            preferenceKeys: preferenceKeys,
            database: database,
            defaults: defaults,
            now: { now }
        ) { _ -> (SnapshotManifest, [CopiedFile], DiagnosticDatabaseCopy.Reading) in

            // 1. A fresh snapshot, in its usual place, where retention manages it.
            let snapshot: SnapshotManifest
            do { snapshot = try takeSnapshot(captureID) }
            catch {
                innerFailure = .snapshotFailed(String(describing: error))
                throw Stop()
            }

            // **COMPLETE, OR THE PACKAGE IS NOT WORTH WRITING.** A snapshot
            // that copied nine of ten files is a package that says ten.
            guard snapshot.isComplete else {
                innerFailure = .snapshotIncomplete(copied: snapshot.copiedCount,
                                                   present: snapshot.presentCount,
                                                   failed: snapshot.failureCount)
                throw Stop()
            }

            // **CHECKED BETWEEN STAGES, NOT INSIDE THEM.** Stopping halfway
            // through a file copy leaves a partial file; stopping between
            // stages leaves a folder this function then removes whole. A
            // cancellation that produced a half-package would be worse than no
            // cancellation at all.
            if shouldCancel() {
                innerFailure = .cancelled(after: "the snapshot was taken")
                throw Stop()
            }

            // 2. The snapshot, copied in and RE-HASHED here. A manifest
            //    carrying only the original's hashes would describe a folder
            //    somewhere else.
            let copied: [CopiedFile]
            do { copied = try copySnapshot(snapshot, from: snapshotsRoot,
                                           into: dir, fm: fm) }
            catch let f as Failure { innerFailure = f; throw Stop() }

            if shouldCancel() {
                innerFailure = .cancelled(after: "the snapshot was copied in")
                throw Stop()
            }

            // 3. The database, one commit boundary.
            guard let database else {
                innerFailure = .databaseCopyFailed("there is no database")
                throw Stop()
            }
            let reading: DiagnosticDatabaseCopy.Reading
            switch DiagnosticDatabaseCopy.write(from: database, into: dir, now: now,
                                                shouldCancel: shouldCancel,
                                                pagesPerStep: databasePagesPerStep,
                                                fm: fm) {
            case .success(let r): reading = r
            case .failure(.cancelled(let done, let total)):
                // **THE STAGE THAT HAD NO CHECKPOINT UNTIL 448.** It is the
                // longest one, so it is the one a person actually presses Stop
                // during — and it said nothing.
                innerFailure = .cancelled(after: "\(done) of \(total) database pages")
                throw Stop()
            case .failure(let why):
                innerFailure = .databaseCopyFailed(why.line)
                throw Stop()
            }
            return (snapshot, copied, reading)
        }

        let captured: EvidenceBarrier.Capture<(SnapshotManifest, [CopiedFile], DiagnosticDatabaseCopy.Reading)>
        switch outcome {
        case .success(let c): captured = c
        case .failure(let why):
            try? fm.removeItem(at: dir)
            // The body's own reason first — `barrierRefused` is only for the
            // barrier's own verdicts, and conflating them would report a
            // failed database copy as something moving underneath.
            if let innerFailure { return .failure(innerFailure) }
            return .failure(.barrierRefused(why.line))
        }

        let (snapshot, copied, database) = captured.value
        let manifest = Manifest(schemaVersion: schemaVersion,
                                identity: identity(captureID),
                                snapshotID: snapshot.id,
                                snapshot: snapshot,
                                snapshotCopy: copied,
                                database: database,
                                testArtifacts: artifacts,
                                revisions: .asOfTaskZeroB,
                                barrier: barrierWriters,
                                before: captured.before,
                                after: captured.after)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            let url = dir.appendingPathComponent(manifestName)
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.protectionKey: FileProtection.attribute])
            try data.write(to: url, options: .atomic)

            let report = Data(supportReport(manifest).utf8)
            let reportURL = dir.appendingPathComponent(reportName)
            fm.createFile(atPath: reportURL.path, contents: nil,
                          attributes: [.protectionKey: FileProtection.attribute])
            try report.write(to: reportURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: dir)
            return .failure(.couldNotWriteManifest(String(describing: error)))
        }
        return .success(manifest)
    }

    private static func copySnapshot(_ snapshot: SnapshotManifest,
                                     from snapshotsRoot: URL?,
                                     into packageDir: URL,
                                     fm: FileManager) throws -> [CopiedFile] {
        guard let snapshotsRoot else {
            throw Failure.snapshotCopyDiffers(["the snapshots folder is unreachable"])
        }
        let source = snapshotsRoot.appendingPathComponent(snapshot.id, isDirectory: true)
        let destination = packageDir.appendingPathComponent(snapshotFolderName,
                                                            isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var out: [CopiedFile] = []
        var problems: [String] = []
        // An entry with no hash is a declared EMPTY DIRECTORY, not a file.
        let hashless = Set(snapshot.entries.filter { $0.copied && $0.sha256 == nil }
                                           .map(\.relativePath))
        var names = snapshot.entries.filter { $0.copied }.map(\.relativePath)
        names.append("manifest.json")

        for relative in names.sorted() {
            let from = source.appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: to)
            } catch {
                problems.append("\(relative): \(error)")
                continue
            }
            if hashless.contains(relative) {
                // The SHAPE is carried; there is nothing to hash. Recorded so
                // the validator can require a directory rather than a file.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: to.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    problems.append("\(relative): the snapshot recorded an empty "
                                  + "directory and the package holds something else")
                    continue
                }
                out.append(CopiedFile(path: "\(snapshotFolderName)/\(relative)",
                                      sha256: nil, bytes: 0))
                continue
            }
            guard let data = try? Data(contentsOf: to) else {
                problems.append("\(relative): the copy could not be read back")
                continue
            }
            let hash = LegacySnapshot.hex(data)
            // **AGAINST THE SNAPSHOT'S OWN MANIFEST**, not against the source
            // file read a second time — a copy compared with its origin proves
            // the copy happened; compared with what was VERIFIED, it proves the
            // package holds the thing that was verified. RULE 17's lesson.
            if let entry = snapshot.entries.first(where: { $0.relativePath == relative }),
               let expected = entry.sha256, expected != hash {
                problems.append("\(relative): the snapshot recorded \(expected) "
                              + "and the copy hashes \(hash)")
                continue
            }
            out.append(CopiedFile(path: "\(snapshotFolderName)/\(relative)",
                                  sha256: hash, bytes: data.count))
        }
        guard problems.isEmpty else { throw Failure.snapshotCopyDiffers(problems) }
        FileProtection.protect(directory: destination, using: fm)
        return out
    }

    // MARK: The half that is safe to send

    /// **NOTHING PRIVATE, AND NOTHING THAT NEEDS REDACTING LATER.**
    ///
    /// Counts, hashes, ids and verdicts. **No per-file paths** — the snapshot's
    /// manifest lists `details/<strava id>.json` 699 times, and while §12.7
    /// permits Strava ids, a report meant to be pasted without a second thought
    /// should not carry seven hundred of them.
    static func supportReport(_ m: Manifest) -> String {
        var l: [String] = []
        l.append("Sub4 evidence package \(m.identity.captureID)")
        l.append("\(m.identity.app) · \(m.identity.configuration) · \(m.identity.provenance)")
        l.append("Captured \(m.identity.capturedUTC)")
        l.append("Schema version \(m.schemaVersion)")
        l.append("")
        l.append("Snapshot \(m.snapshotID)")
        l.append("  \(m.snapshot.copiedCount) of \(m.snapshot.presentCount) files copied, "
               + "\(m.snapshot.missingCount) declared and not present, "
               + "\(m.snapshot.failureCount) failed")
        l.append("  complete: \(m.snapshot.isComplete ? "yes" : "NO")")
        l.append("  files carried into this package: \(m.snapshotCopy.count)")
        l.append("  bytes carried: \(m.snapshotCopy.reduce(0) { $0 + $1.bytes })")
        l.append("")
        l.append("Database copy")
        l.append("  \(m.database.line)")
        l.append("  tables: \(m.database.tables.count) · rows: "
               + "\(m.database.tables.values.reduce(0, +))")
        l.append("")
        l.append("Revisions available as evidence: "
               + (m.revisions.available.isEmpty ? "none" : m.revisions.available.joined(separator: ", ")))
        l.append("  \(m.revisions.why)")
        l.append("")
        l.append("Internal test artifacts: \(m.testArtifacts.count)")
        for a in m.testArtifacts { l.append("  \(a.line)") }
        l.append("")
        l.append("The barrier")
        l.append("  asked to wait: \(m.barrier.writersAskedToWait.joined(separator: ", "))")
        l.append("  detected only: \(m.barrier.writersDetectedOnly.joined(separator: ", "))")
        l.append("  turned away during this capture: "
               + (m.barrier.turnedAwayDuringCapture.isEmpty
                  ? "none"
                  : m.barrier.turnedAwayDuringCapture.sorted { $0.key < $1.key }
                        .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
        // NAMED, NEVER IMPLIED. "It did not fail" and "it was not looking" are
        // the same sentence otherwise.
        l.append("  NOT watched during the capture: "
               + m.barrier.notWatched.sorted().joined(separator: ", "))
        for name in m.barrier.notWatched.sorted() {
            l.append("    \(name): \(m.barrier.notWatchedWhy[name] ?? "no reason recorded")")
        }
        l.append("")
        l.append("Nothing moved while it was taken")
        l.append("  locations watched: \(m.before.items.count)")
        l.append("  tables counted: \(m.before.tables.count)")
        l.append("  preferences watched: \(m.before.preferences.count)")
        l.append("  integrity: \(m.before.quickCheck) · "
               + "\(m.before.foreignKeyViolations) foreign-key violations")
        l.append("  differences between the two readings: "
               + "\(m.after.differences(from: m.before).count)")
        return l.joined(separator: "\n") + "\n"
    }

    // MARK: What is on this phone

    /// Package ids, newest first. Unconditional callers only — an empty list is
    /// an answer.
    static func ids(base: URL?, fm: FileManager = .default) -> [String] {
        guard let base else { return [] }
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >)
    }

    static func line(base: URL?, fm: FileManager = .default) -> String {
        let found = ids(base: base, fm: fm)
        guard !found.isEmpty else { return "none on this phone" }
        return "\(found.count) on this phone · newest \(found[0])"
    }
}
