//
//  Sub4Database.swift
//  Sub4
//
//  The connection — patch 195, plan step 3.2a, ADR-0003 §2 and §7.
//
//  WHAT THIS IS AND WHAT IT DELIBERATELY IS NOT
//  -------------------------------------------
//  This is the door: how the database is opened, where it lives, what
//  configuration every connection is given, and how to ask it whether it is
//  still intact. It holds no queries, no repositories and no model types. Those
//  arrive in 3.2b and 3.3 once the foundation is proven to build and to be
//  testable.
//
//  Nothing in the app opens it yet. That is on purpose: 3.2a ships the
//  foundation and its tests, and the health screen that makes it visible on a
//  device comes with 3.2b. Six of the eleven defects found in Phase 2 were only
//  reachable on hardware, so a step that cannot be seen on hardware is a step
//  that has not been verified — and saying so is better than implying the
//  opposite by wiring a launch path nothing reads.
//
//  WHY A STRUCT AND NOT A SINGLETON
//  -------------------------------
//  `DatabaseQueue` is already the serialisation point; wrapping it in a shared
//  mutable object adds a second lifetime to reason about and makes the
//  in-memory database the tests need a special case rather than an ordinary
//  one. `open()` returns a value. Whoever owns the app's instance decides that
//  in 3.2b, when there is something to own it for.
//
//  WHY `nonisolated`
//  -----------------
//  This target compiles with default MainActor isolation, so a type says
//  nothing about concurrency and gets MainActor anyway. A database that can
//  only be touched from the main actor is the opposite of the point: the whole
//  reason for `DatabaseQueue` is that imports and migrations run off it. Every
//  member here is reachable from any actor, and `DatabaseQueue` is `Sendable`,
//  so the type is too.
//
//  FILE PROTECTION IS APPLIED TO A DIRECTORY, NOT A FILE
//  ----------------------------------------------------
//  SQLite does not write one file. It writes the database plus, depending on
//  journal mode, `-journal`, `-wal` and `-shm` alongside it, and it creates
//  them itself — after the app has stopped looking. Protecting only the
//  `.sqlite` file leaves the journal, which contains the same rows, at whatever
//  class the system chose.
//
//  So the database gets its own directory, the directory carries the protection
//  class, and everything SQLite creates inside it inherits. This also makes
//  deletion a single `removeItem` on the directory, which cannot leave a
//  sidecar behind — the failure mode that made `details.json` outlive four
//  versions of this app.
//

import Foundation
import GRDB

// MARK: - Errors

nonisolated enum Sub4DatabaseError: Error, LocalizedError, Equatable {
    case applicationSupportUnavailable
    case couldNotCreateDirectory(String)
    /// Carried forward from `Sub4Launch` — patch 215. The launch gate already
    /// tried and failed, so the health screen reports THAT failure rather than
    /// opening a second connection and possibly succeeding, which would show a
    /// healthy database on a launch that did not get one.
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is not reachable, so there is nowhere to keep the database."
        case .couldNotCreateDirectory(let why):
            "The database folder could not be created: \(why)"
        case .launchFailed(let why):
            "The database could not be prepared when the app started: \(why)"
        }
    }
}

// MARK: - The connection

nonisolated struct Sub4Database: Sendable {

    /// Where the database sits under Application Support. A directory rather
    /// than a bare file — see the header.
    static let directoryName = "db"
    static let fileName = "sub4.sqlite"

    enum Location: Sendable, Equatable {
        case onDisk(URL)
        case inMemory

        var isInMemory: Bool { self == .inMemory }
    }

    let queue: DatabaseQueue
    let location: Location

    // MARK: Opening

    /// The configuration every connection gets, on disk and in memory alike.
    ///
    /// SHARED BETWEEN THE TWO ON PURPOSE. A test database configured differently
    /// from the real one tests a different database. Foreign keys being on in
    /// the tests and off in the app is the exact shape of that mistake, and it
    /// is the one ADR-0003 §7 names as "the single most common way a schema with
    /// declared relationships turns out never to have enforced them".
    static func configuration(label: String) -> Configuration {
        var c = Configuration()
        c.label = label

        // GRDB defaults this to true. Set anyway, and asserted by test:
        // a default is a decision somebody else made and can change, and this
        // one is load-bearing for every relationship in §8.
        c.foreignKeysEnabled = true

        // A writer blocked by another connection waits rather than failing.
        // With a single `DatabaseQueue` this should never fire; it costs
        // nothing and turns a future pool migration's first surprise into a
        // pause instead of an error.
        c.busyMode = .timeout(5)

        return c
    }

    /// Opens — creating if needed — the database in Application Support, and
    /// migrates it to the current schema.
    static func open(using fm: FileManager = .default) throws -> Sub4Database {
        let dir = try directoryURL(using: fm)
        let file = dir.appendingPathComponent(fileName)

        let queue = try DatabaseQueue(path: file.path,
                                      configuration: configuration(label: "sub4"))
        try Sub4Migrations.migrator.migrate(queue)

        // After migration, not before: the migration is what creates the file
        // and its journal. Applying the class to a directory that is still
        // empty protects nothing SQLite has not yet written.
        protectEverything(in: dir, using: fm)

        return Sub4Database(queue: queue, location: .onDisk(file))
    }

    /// A migrated, empty database that never touches disk. What the tests use,
    /// and what a benchmark at 10,000 activities (§9.3) will use for its
    /// control run.
    static func inMemory(label: String = "sub4-test") throws -> Sub4Database {
        let queue = try DatabaseQueue(configuration: configuration(label: label))
        try Sub4Migrations.migrator.migrate(queue)
        return Sub4Database(queue: queue, location: .inMemory)
    }

    // MARK: Where it lives

    static func directoryURL(using fm: FileManager = .default) throws -> URL {
        guard let base = AppSupportItem.container else {
            throw Sub4DatabaseError.applicationSupportUnavailable
        }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.protectionKey: FileProtection.attribute])
            } catch {
                throw Sub4DatabaseError.couldNotCreateDirectory(error.localizedDescription)
            }
        }
        return dir
    }

    /// The directory and everything SQLite has put in it.
    ///
    /// The directory attribute governs files created afterwards; this sweep
    /// catches the ones already there, including any `-wal` and `-shm` written
    /// before this patch existed. Same reasoning, and the same idempotence, as
    /// `FileProtection.applyToExistingFiles`.
    @discardableResult
    static func protectEverything(in dir: URL, using fm: FileManager = .default) -> Int {
        try? fm.setAttributes([.protectionKey: FileProtection.attribute],
                              ofItemAtPath: dir.path)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var touched = 0
        for name in names {
            let p = dir.appendingPathComponent(name).path
            if (try? fm.setAttributes([.protectionKey: FileProtection.attribute],
                                      ofItemAtPath: p)) != nil {
                touched += 1
            }
        }
        return touched
    }

    // MARK: Is it still there

    /// What the database says about itself.
    ///
    /// WHY BOTH CHECKS AND NOT ONE. `quick_check` reads the pages and finds
    /// structural damage — a torn write, a truncated file, an index that does
    /// not match its table. `foreign_key_check` finds the other kind: pages
    /// that are perfectly well formed and describe a note attached to an
    /// activity that no longer exists. A database can pass either one and fail
    /// the other, and only the second is a bug this app could have caused.
    struct IntegrityReport: Sendable, Equatable {
        /// SQLite's own word. `"ok"` is the only healthy answer.
        let quickCheck: String
        /// Rows referencing a parent that is not there. Must be zero.
        let foreignKeyViolations: Int
        /// Whether the connection actually has foreign keys switched on. Asked
        /// rather than assumed, because §7 is a claim about every connection
        /// and a claim nobody verifies is a hope.
        let foreignKeysEnabled: Bool
        /// The migrations this file has had applied, in order.
        let appliedMigrations: [String]
        /// Bytes, or nil for an in-memory database.
        let bytesOnDisk: Int64?

        var isHealthy: Bool {
            quickCheck == "ok"
                && foreignKeyViolations == 0
                && foreignKeysEnabled
                && appliedMigrations == Sub4Migrations.all
        }

        /// One line, for the health screen in 3.2b and for a bug report.
        var summary: String {
            if isHealthy {
                let size = bytesOnDisk.map {
                    " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? " · in memory"
                return "Healthy · \(appliedMigrations.count) migration"
                     + "\(appliedMigrations.count == 1 ? "" : "s")\(size)"
            }
            var problems: [String] = []
            if quickCheck != "ok" { problems.append("integrity: \(quickCheck)") }
            if foreignKeyViolations > 0 {
                problems.append("\(foreignKeyViolations) orphaned row"
                              + "\(foreignKeyViolations == 1 ? "" : "s")")
            }
            if !foreignKeysEnabled { problems.append("foreign keys are OFF") }
            let missing = Sub4Migrations.all.filter { !appliedMigrations.contains($0) }
            if !missing.isEmpty { problems.append("not migrated: \(missing.joined(separator: ", "))") }
            return problems.joined(separator: " · ")
        }
    }

    /// Row counts, every table, ordered as `sqlite_master` holds them.
    ///
    /// COUNTS AND NOTHING ELSE, deliberately. This is what the diagnostics text
    /// is built from, and a diagnostic a person is invited to paste into a
    /// message must not carry a session name, a coordinate or a date. A count
    /// is the most that can be said about a table without saying anything about
    /// the athlete.
    ///
    /// `COUNT(*)` per table rather than a stored figure: on an empty database
    /// it costs nothing, and on a full one a stale cached number is worse than
    /// a slow accurate one on a screen whose whole job is to be believed.
    /// Tables that exist to run the database rather than to hold the athlete's
    /// training, and are therefore not what a screen headed "Rows" is about.
    ///
    /// `grdb_migrations` is the one that is easy to miss: it carries no
    /// `sqlite_` prefix, so a filter written against that prefix alone lets it
    /// through — and it holds one row per applied migration, so a database with
    /// nothing in it reports two rows and reads as not-empty. Found by the test
    /// that asserted a fresh database is empty, which is exactly the assertion
    /// that would have been quietly deleted as "obviously true".
    ///
    /// What it would tell a reader is already on the screen, spelled out, as
    /// the list of applied migrations.
    nonisolated static let bookkeepingTables: Set<String> = ["grdb_migrations"]

    /// Tables a migration fills, rather than an import.
    ///
    /// `source` is seeded with one row per known source by
    /// `2026-08-03-initial`, so a database that has never held a single
    /// activity still reports six rows. That is correct and it is not data —
    /// and a screen that reported "6 rows in total" for an empty database would
    /// leave the reader unable to tell reference data from training history,
    /// which is the one question that screen exists to answer before 3.3.
    ///
    /// Found by the same assertion that caught `grdb_migrations`: "a fresh
    /// database is empty". It has now been wrong twice for two different
    /// reasons, which is a better argument for keeping it than any reasoning
    /// about what it might catch.
    nonisolated static let seededTables: Set<String> = ["source"]

    func tableCounts() throws -> [(table: String, rows: Int)] {
        try queue.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """).filter { !Self.bookkeepingTables.contains($0) }
            return try names.map { name in
                // The name comes from `sqlite_master`, so it cannot be
                // attacker-supplied — but it is still interpolated into SQL,
                // and quoting it costs one character.
                let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
                return (table: name, rows: n)
            }
        }
    }

    func integrityReport(using fm: FileManager = .default) throws -> IntegrityReport {
        let bytes: Int64? = {
            guard case .onDisk(let url) = location,
                  let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return (attrs[.size] as? NSNumber)?.int64Value
        }()

        return try queue.read { db in
            // quick_check returns one row per problem, and exactly one row
            // reading "ok" when there is none. Joined rather than first-only:
            // reporting the first of nine problems and calling it the answer is
            // how a diagnostic becomes misleading.
            let rows = try String.fetchAll(db, sql: "PRAGMA quick_check")
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            let fkOn = (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1
            let applied = try Sub4Migrations.migrator.appliedIdentifiers(db)

            return IntegrityReport(
                quickCheck: rows.isEmpty ? "no answer" : rows.joined(separator: "; "),
                foreignKeyViolations: violations,
                foreignKeysEnabled: fkOn,
                appliedMigrations: Sub4Migrations.all.filter { applied.contains($0) },
                bytesOnDisk: bytes)
        }
    }
}
