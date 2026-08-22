//
//  DiagnosticDatabaseCopy.swift
//  Sub4
//
//  A copy of the database that is evidence, not a spare — patch 443,
//  ADR-0003 §12.199.
//
//  WHY NOT `fm.copyItem`
//  ---------------------
//  The runbook is explicit: *a transaction-consistent diagnostic SQLite copy
//  created through the supported SQLite/GRDB backup API, **never by copying a
//  live database without its WAL state***.
//
//  A file copy of an open SQLite database is a copy of whatever the pages
//  happened to say at the instant `read` reached them. In WAL mode the
//  committed truth is split between the database and its `-wal`, so a copy of
//  the main file alone can be **older than the last commit and internally
//  consistent about it** — which is the worst failure available, because
//  `PRAGMA quick_check` on the result says `ok`.
//
//  `sqlite3_backup_*`, which GRDB exposes as `backup(to:)`, takes its own read
//  transaction on the source and copies page by page. Whatever the journal mode,
//  what lands is one commit boundary.
//
//  IT IS EVIDENCE, NOT A BACKUP
//  ----------------------------
//  Task 9 builds the authoritative backup, with retention, restore and recovery
//  guarantees. **This claims none of them**, and the file is named so that a
//  person going through a package a year from now cannot mistake it for a spare
//  to put back. That naming is the only honest defence available: nothing here
//  can stop somebody copying a file, so the file says what it is.
//
//  WHAT IT REFUSES
//  ---------------
//  1. **A destination that already exists.** Never overwrite; a package is
//     written once.
//  2. **Not enough room.** Checked BEFORE, because a backup that runs out
//     halfway leaves a file that opens.
//  3. **An incomplete backup** — `sqlite3_backup_step` not done.
//  4. **A copy whose row counts disagree with the source.** The one that
//     matters: a truncated copy still hashes, still opens, and still reports
//     `ok`. **A copy nobody counted is a file, not evidence.**
//  5. **Sidecars beside the finished artifact.** A `-wal` next to the copy
//     means the hash describes half of it.
//

import Foundation
import GRDB

nonisolated enum DiagnosticDatabaseCopy {

    /// **THE NAME IS THE DEFENCE.** `sub4.sqlite` inside a package is a file
    /// somebody eventually puts back.
    static let fileName = "database-diagnostic-copy.sqlite"

    /// **HOW OFTEN THE BACKUP CAN BE STOPPED — patch 448.**
    ///
    /// GRDB's own default is `-1`: every page in one step, which is right for
    /// consistency and made the longest stage of a capture **uninterruptible**.
    /// 256 pages is about a megabyte — roughly 37 checkpoints on this athlete's
    /// 39 MB database.
    ///
    /// **NAMED RATHER THAN WRITTEN IN THE SIGNATURE**, because the tests that
    /// drive cancellation pass their own step and could never see the default
    /// change back. `theDefaultCanBeStoppedAtAll` reads THIS.
    static let defaultPagesPerStep: CInt = 256

    /// Journal sidecars SQLite can leave beside a database.
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    // MARK: What was made

    struct Reading: Sendable, Equatable, Codable {
        let fileName: String
        let bytes: Int64
        let sha256: String
        /// The SOURCE's journal mode, recorded because the runbook's whole
        /// concern is a copy taken without its WAL state. Recording it is how
        /// a reader knows the question was asked.
        let sourceJournalMode: String
        let totalPageCount: Int
        let copiedPageCount: Int
        /// Every figure below is read from the COPY, never carried over from
        /// the source. A verification that reads its own input proves nothing.
        let quickCheck: String
        let foreignKeyViolations: Int
        let migrations: [String]
        let tables: [String: Int]
        let takenUTC: String

        /// **ALWAYS FALSE, AND STORED RATHER THAN IMPLIED.** A reader of the
        /// manifest should not have to infer it from a filename.
        let isSupportedRestoreArtifact: Bool

        var line: String {
            "\(fileName) · \(bytes) bytes · \(sha256) · "
            + "\(copiedPageCount) of \(totalPageCount) pages · "
            + "source journal \(sourceJournalMode) · integrity \(quickCheck) · "
            + "\(foreignKeyViolations) foreign-key violations · "
            + "\(tables.count) tables · \(migrations.count) migrations · "
            + "read-only evidence, not a restore artifact"
        }
    }

    // MARK: Why it will not

    enum Failure: Equatable, Sendable, Error {
        case destinationExists(String)
        case notEnoughSpace(need: Int64, free: Int64)
        case couldNotOpenSource(String)
        case couldNotCreateDestination(String)
        case backupFailed(String)
        case incomplete(copied: Int, total: Int)
        case countsDisagree([String])
        case sidecarsRemain([String])
        case unreadableAfterWriting(String)
        /// **STOPPED, AND THE HALF-WRITTEN FILE REMOVED.** Patch 448.
        case cancelled(afterPages: Int, of: Int)

        var line: String {
            switch self {
            case .destinationExists(let p):
                "REFUSED — \(p) already exists, and a package is written once"
            case .notEnoughSpace(let need, let free):
                "REFUSED — the copy needs about \(need) bytes and \(free) are free"
            case .couldNotOpenSource(let why):
                "REFUSED — the database could not be read: \(why)"
            case .couldNotCreateDestination(let why):
                "REFUSED — the copy could not be created: \(why)"
            case .backupFailed(let why):
                "FAILED — the backup stopped: \(why)"
            case .incomplete(let copied, let total):
                "FAILED — \(copied) of \(total) pages copied"
            case .countsDisagree(let what):
                "FAILED — the copy does not hold what the database holds: "
                + what.joined(separator: "; ")
            case .sidecarsRemain(let names):
                "FAILED — \(names.joined(separator: ", ")) sit beside the copy, "
                + "so its hash describes only part of it"
            case .unreadableAfterWriting(let why):
                "FAILED — the finished copy could not be read back: \(why)"
            case .cancelled(let done, let total):
                "Stopped after \(done) of \(total) pages. Nothing was left behind."
            }
        }
    }

    // MARK: Making one

    /// - Parameter freeBytes: injected so the low-space refusal can be driven.
    ///   A refusal that only fires on a full phone is a refusal nobody tests
    ///   (§12.69).
    static func write(from source: Sub4Database,
                      into directory: URL,
                      now: Date,
                      spareFactor: Double = 1.2,
                      shouldCancel: @escaping @Sendable () -> Bool = { false },
                      pagesPerStep: CInt = Self.defaultPagesPerStep,
                      freeBytes: (URL) -> Int64? = Self.freeBytesOnVolume,
                      fm: FileManager = .default) -> Result<Reading, Failure> {

        let destination = directory.appendingPathComponent(fileName)
        guard !fm.fileExists(atPath: destination.path) else {
            return .failure(.destinationExists(fileName))
        }
        for suffix in sidecarSuffixes {
            let sidecar = directory.appendingPathComponent(fileName + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                return .failure(.destinationExists(fileName + suffix))
            }
        }

        // 1. What the source is, and what it holds.
        let sourceState: (journalMode: String, bytes: Int64, tables: [String: Int])
        do {
            sourceState = try source.queue.read { db in
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
                let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return (mode, pages * pageSize, try counts(db))
            }
        } catch {
            return .failure(.couldNotOpenSource(String(describing: error)))
        }

        // 2. Room, BEFORE. A backup that runs out halfway leaves a file that
        //    opens and is missing pages.
        let need = Int64(Double(sourceState.bytes) * spareFactor)
        if let free = freeBytes(directory), free < need {
            return .failure(.notEnoughSpace(need: need, free: free))
        }

        // 3. The file exists and carries the protection class BEFORE SQLite
        //    writes a byte into it, so there is no unprotected window — the
        //    same order `DataLifecycleCoordinator.write` uses for the export.
        guard fm.createFile(atPath: destination.path, contents: nil,
                            attributes: [.protectionKey: FileProtection.attribute])
        else {
            return .failure(.couldNotCreateDestination("the file could not be created"))
        }

        // 4. Copy, verify and close — all inside, so the queue is released
        //    before anything hashes the file.
        let verified: Result<(Reading, [String]), Failure>
        do {
            verified = try copyAndVerify(from: source, to: destination,
                                         sourceState: sourceState, now: now,
                                         shouldCancel: shouldCancel,
                                         pagesPerStep: pagesPerStep)
        } catch {
            try? fm.removeItem(at: destination)
            return .failure(.backupFailed(String(describing: error)))
        }
        guard case .success(let (partial, disagreements)) = verified else {
            try? fm.removeItem(at: destination)
            for suffix in sidecarSuffixes {
                try? fm.removeItem(at: destination.appendingPathExtension(suffix))
            }
            if case .failure(let why) = verified { return .failure(why) }
            return .failure(.backupFailed("unknown"))
        }
        guard disagreements.isEmpty else {
            try? fm.removeItem(at: destination)
            return .failure(.countsDisagree(disagreements))
        }

        // 5. One file, not three.
        let strays = sidecarSuffixes
            .map { fileName + $0 }
            .filter { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard strays.isEmpty else { return .failure(.sidecarsRemain(strays)) }

        // 6. Hash what is actually on disk, now that nothing holds it open.
        guard let data = try? Data(contentsOf: destination) else {
            return .failure(.unreadableAfterWriting("the copy could not be re-read"))
        }
        FileProtection.protect(directory: destination, using: fm)

        return .success(Reading(fileName: partial.fileName,
                                bytes: Int64(data.count),
                                sha256: LegacySnapshot.hex(data),
                                sourceJournalMode: partial.sourceJournalMode,
                                totalPageCount: partial.totalPageCount,
                                copiedPageCount: partial.copiedPageCount,
                                quickCheck: partial.quickCheck,
                                foreignKeyViolations: partial.foreignKeyViolations,
                                migrations: partial.migrations,
                                tables: partial.tables,
                                takenUTC: partial.takenUTC,
                                isSupportedRestoreArtifact: false))
    }

    /// The backup itself, and the read-back. Split out so the destination queue
    /// is deinitialised at the end of this function rather than at the end of
    /// `write` — the hash has to be taken with nothing holding the file.
    private static func copyAndVerify(
        from source: Sub4Database,
        to destination: URL,
        sourceState: (journalMode: String, bytes: Int64, tables: [String: Int]),
        now: Date,
        shouldCancel: @escaping @Sendable () -> Bool,
        pagesPerStep: CInt
    ) throws -> Result<(Reading, [String]), Failure> {

        let dest = try DatabaseQueue(path: destination.path,
                                     configuration: Sub4Database.configuration(
                                        label: "sub4-diagnostic-copy"))

        var last: DatabaseBackupProgress?
        var stopped = false
        struct Cancelled: Error {}
        do {
            // **CHUNKED SINCE 448, AND IT COSTS NOTHING IN CONSISTENCY.**
            //
            // GRDB's default is one step, and it made the longest stage of a
            // capture uninterruptible — 39 MB with no way to stop, which is
            // what the device found. `backup(to:)` holds ONE read transaction
            // on the source across every step (GRDB wraps the whole thing in
            // `read`), so chunking changes when we can look up, not what lands.
            //
            // **THE STEP SIZE IS THE GRANULARITY OF "CAN I STOP".** 256 pages
            // is about a megabyte — roughly 37 checkpoints on this athlete's
            // 39 MB database. The first draft used 512 and the CONTROLS caught
            // it: a 174-page test database finished in a single step, the
            // callback fired once with `isCompleted`, and nothing could ever
            // be stopped. A step size larger than the database is a checkpoint
            // that never happens.
            //
            // The progress callback is the documented place to abort: throwing
            // from it while the backup is incomplete aborts and rethrows.
            try source.queue.backup(to: dest, pagesPerStep: pagesPerStep) { progress in
                last = progress
                if shouldCancel() && !progress.isCompleted {
                    stopped = true
                    throw Cancelled()
                }
            }
        } catch {
            try? dest.close()
            if stopped {
                return .failure(.cancelled(afterPages: last?.completedPageCount ?? 0,
                                           of: last?.totalPageCount ?? 0))
            }
            return .failure(.backupFailed(String(describing: error)))
        }

        guard let progress = last, progress.isCompleted else {
            try? dest.close()
            return .failure(.incomplete(copied: last?.completedPageCount ?? 0,
                                        total: last?.totalPageCount ?? 0))
        }

        // ONE FILE. Whatever the source's journal mode, the artifact is not
        // allowed to carry a `-wal`, because its hash would then describe half
        // of it and a validator reading the file alone would see an older
        // database that reports `ok`.
        do {
            try dest.writeWithoutTransaction { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
            }
        } catch {
            try? dest.close()
            return .failure(.backupFailed("the copy's journal could not be folded in: "
                                        + String(describing: error)))
        }

        // EVERY FIGURE FROM THE COPY. A verification that reads its own input
        // proves nothing — §12.129's shape, and 411 shipped exactly that bug
        // for a day in `CommuteRepository.delete`.
        let reading: Reading
        var disagreements: [String] = []
        do {
            reading = try dest.read { db in
                let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
                let migrations = try String.fetchAll(db, sql: """
                    SELECT identifier FROM grdb_migrations ORDER BY identifier
                    """)
                let tables = try counts(db)
                disagreements = Self.disagreements(source: sourceState.tables, copy: tables)
                return Reading(fileName: fileName,
                               bytes: 0, sha256: "",     // filled by the caller
                               sourceJournalMode: sourceState.journalMode,
                               totalPageCount: progress.totalPageCount,
                               copiedPageCount: progress.completedPageCount,
                               quickCheck: quick,
                               foreignKeyViolations: violations,
                               migrations: migrations,
                               tables: tables,
                               takenUTC: EvidenceBarrier.iso8601(now),
                               isSupportedRestoreArtifact: false)
            }
        } catch {
            try? dest.close()
            return .failure(.unreadableAfterWriting(String(describing: error)))
        }

        try? dest.close()
        return .success((reading, disagreements))
    }

    // MARK: Reading the world

    /// **THE DECISION, SPLIT FROM THE READ — §12.162.3.**
    ///
    /// The branch that calls this cannot be driven through the public API, and
    /// that is a good thing: it would need `sqlite3_backup_*` to be wrong. But
    /// a guard that cannot fail has not been tested (§12.69), so the RULE is a
    /// pure function the suite drives directly with counts nobody had to
    /// corrupt a database to produce.
    static func disagreements(source: [String: Int], copy: [String: Int]) -> [String] {
        var out: [String] = []
        for name in Set(copy.keys).union(source.keys).sorted() {
            let a = copy[name], b = source[name]
            if a != b {
                out.append("\(name): the database holds "
                    + "\(b.map(String.init) ?? "no such table") and the copy holds "
                    + "\(a.map(String.init) ?? "no such table")")
            }
        }
        return out
    }

    private static func counts(_ db: Database) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let names = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%' ORDER BY name
            """)
        for name in names {
            out[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
        }
        return out
    }

    /// **"IMPORTANT USAGE", NOT "FREE".** iOS will purge caches to satisfy an
    /// important write, and the plain free-space figure is smaller than what is
    /// actually available. Asking the wrong one would refuse captures that
    /// would have succeeded.
    static func freeBytesOnVolume(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
