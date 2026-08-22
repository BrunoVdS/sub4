//
//  EvidenceBarrier.swift
//  Sub4
//
//  Nothing moved while we were looking — patch 442, ADR-0003 §12.198.
//
//  WHAT TASK 0B NEEDS AND WHY THIS IS THE HARD HALF
//  ------------------------------------------------
//  The runbook asks for a starting-evidence package: a protected snapshot of
//  every legacy file, a transaction-consistent copy of the database, and one
//  manifest binding them. **Those are two captures taken at two different
//  moments**, and a package whose halves describe different states is worse
//  than no package — it looks complete and is quietly inconsistent.
//
//  So the runbook's actual requirement is a barrier: *capture pre-state
//  hashes, fingerprints and counts; make the copies; recalculate the same
//  values; and fail the package rather than publish mismatched evidence.*
//
//  QUIESCE WHAT CAN BE ASKED, DETECT WHAT CANNOT
//  ---------------------------------------------
//  Proving that every writer in the app stood down is not achievable and never
//  will be — the next patch adds a writer nobody told this file about. **The
//  guarantee therefore comes from DETECTION, not from cooperation.** Asking the
//  machine-initiated writers to wait is politeness that stops a capture failing
//  for a reason nobody would call a defect; the pre/post comparison is what
//  makes an *unowned* writer fail the package, which is the property the
//  runbook actually names.
//
//  That is why `Writer` has two buckets and a third answer — and §12.132 is why
//  the third exists as a stated thing rather than as silence.
//
//  ONE DELIBERATE DEPARTURE FROM THE RUNBOOK'S WORDING
//  ---------------------------------------------------
//  It says "drain/pause/refuse every currently known source refresh, background
//  job, queue claim **and authored writer**". This refuses the first three and
//  **NOT the authored writers**, on purpose:
//
//  > **Refusing the athlete's own save to protect an evidence capture is the
//  > wrong trade.** A note typed during a capture and silently dropped is lost
//  > data; a package that fails and is retried costs thirty seconds.
//
//  Authored writes are therefore DETECTED. The package fails, says which family
//  moved, and the answer is to take it again. §12.8.1's rule — never destroy
//  authored data to tidy up a read — pointed the same way.
//
//  WHAT IT DOES NOT DO
//  -------------------
//  It does not hash `details/` and `streams/` file by file. That is 1,371 files
//  and 19 MB, the snapshot already hashes and verifies every one of them, and
//  doing it twice more to answer "did anything move in the last four seconds"
//  would triple the capture for no new fact. Directories are TALLIED — count,
//  bytes, newest modification — and the reading says which it did. A summary
//  presented as a hash would be the dishonest version of the same shortcut.
//

import Foundation
import GRDB

/// Held while an evidence capture is running.
///
/// **MAIN-ACTOR, BECAUSE EVERY WRITER THAT CONSULTS IT IS.** A flag reachable
/// from anywhere would need synchronisation this app has nowhere else, and the
/// six writers below are all main-actor entry points.
@MainActor
enum EvidenceBarrier {

    // MARK: Who writes

    /// **THE WRITERS THIS APP KNOWS ABOUT.** Declared rather than discovered,
    /// because the point of the list is to be *checkable* — RULE 16 fails the
    /// build when a case that claims it can be asked is not consulted anywhere.
    nonisolated enum Writer: String, CaseIterable, Sendable {

        /// iOS wakes the app and it syncs. The one writer that can start with
        /// nobody holding the phone.
        case backgroundRefresh
        /// The activity sync, from the foreground or from the wake above.
        case activitySync
        /// The trace backfill, which runs for minutes and writes constantly.
        case detailBackfill
        /// Weather lookups for activities that have none.
        case weatherBackfill
        /// Zones, FTP and gear from Strava.
        case athleteRefresh
        /// Taking a snapshot prunes older ones and writes receipts.
        case snapshotRetention

        /// The four authored stores. **Detected, never refused** — see the
        /// header. Listed so the vocabulary is complete rather than convenient.
        case authoredNotes
        case authoredCommutes
        case authoredMoves
        case authoredMatchDecisions

        /// Whether this writer is ASKED to stand down, or only DETECTED.
        ///
        /// A `false` here is not an omission. It is the decision written in the
        /// header: an athlete's save outranks an evidence capture.
        var isAskedToWait: Bool {
            switch self {
            case .backgroundRefresh, .activitySync, .detailBackfill,
                 .weatherBackfill, .athleteRefresh, .snapshotRetention:
                true
            case .authoredNotes, .authoredCommutes, .authoredMoves,
                 .authoredMatchDecisions:
                false
            }
        }

        var label: String {
            switch self {
            case .backgroundRefresh:      "the background refresh"
            case .activitySync:           "the activity sync"
            case .detailBackfill:         "the trace backfill"
            case .weatherBackfill:        "the weather backfill"
            case .athleteRefresh:         "the zones and gear refresh"
            case .snapshotRetention:      "snapshot retention"
            case .authoredNotes:          "your session notes"
            case .authoredCommutes:       "your commute corrections"
            case .authoredMoves:          "your moved sessions"
            case .authoredMatchDecisions: "your match decisions"
            }
        }

        static var asked: [Writer] { allCases.filter(\.isAskedToWait) }
        static var detectedOnly: [Writer] { allCases.filter { !$0.isAskedToWait } }
    }

    // MARK: The hold

    private(set) static var heldSince: Date?
    static var isHeld: Bool { heldSince != nil }

    /// Every writer that was turned away while the barrier was up, counted.
    ///
    /// **NOT A BOOL, AND 409a IS WHY.** "Did anything try" and "nothing tried"
    /// are different facts from "the barrier was never up", and a flag that
    /// cannot tell them apart is §12.15's fifteenth instance wearing a new hat.
    private(set) static var refusals: [Writer: Int] = [:]

    /// Called by each asked writer. Returns `true` when the caller must stop.
    ///
    /// **IT RECORDS THE REFUSAL.** A writer that turned back and said nothing
    /// leaves a capture looking uneventful when it was in fact contended.
    static func shouldWait(_ writer: Writer) -> Bool {
        guard isHeld else { return false }
        refusals[writer, default: 0] += 1
        return true
    }

    /// **UNCONDITIONAL, AND IT NAMES THE VOCABULARY.** A barrier nobody can see
    /// is a barrier nobody can check — and the count of writers that are only
    /// detected is the number a reader most needs, because those are the ones
    /// that can still fail a capture.
    static var line: String {
        let asked = Writer.asked.count
        let detected = Writer.detectedOnly.count
        let state = isHeld
            ? "HELD since \(ISO8601DateFormatter().string(from: heldSince ?? Date()))"
            : "not held"
        let turned = refusals.values.reduce(0, +)
        let tail = turned == 0
            ? "no writer has been turned away this launch"
            : "turned away this launch: " + refusals.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) ×\($0.value)" }.joined(separator: ", ")
        return "\(state) · \(asked) writers asked to wait, \(detected) detected only · \(tail)"
    }

    // MARK: Refusals

    nonisolated enum Refusal: Equatable, Sendable, Error {
        case alreadyHeld(since: String)
        case containerUnreachable
        case noDatabase
        /// The pre and post readings disagree. **The whole point.**
        case movedDuringCapture([String])
        case couldNotRead(String)
        case cancelled

        var line: String {
            switch self {
            case .alreadyHeld(let since):
                "REFUSED — a capture has been running since \(since)"
            case .containerUnreachable:
                "REFUSED — Application Support is unreachable"
            case .noDatabase:
                "REFUSED — there is no open database to fingerprint"
            case .movedDuringCapture(let what):
                "REFUSED — something changed while the capture was running: "
                + what.joined(separator: "; ")
            case .couldNotRead(let why):
                "REFUSED — the state could not be read: \(why)"
            case .cancelled:
                "REFUSED — the capture was cancelled"
            }
        }
    }

    // MARK: The reading

    /// One declared location, as it was at a moment.
    nonisolated struct ItemReading: Equatable, Sendable, Codable {
        let path: String
        let kind: Kind

        /// **THREE ANSWERS AND A FOURTH FOR "COULD NOT LOOK".** §12.15: absent
        /// and unreadable are different, and a fingerprint that collapses them
        /// would compare equal across a file that vanished and a file that
        /// broke.
        enum Kind: Equatable, Sendable, Codable {
            /// A single file, hashed whole.
            case hashed(sha256: String, bytes: Int)
            /// A directory, summarised. See the header for why it is not hashed.
            case tallied(files: Int, bytes: Int64, newestUTC: String?)
            case absent
            case unreadable(String)
        }

        var line: String {
            switch kind {
            case .hashed(let h, let b):        "\(path) · \(b) bytes · \(h)"
            case .tallied(let f, let b, let n): "\(path) · \(f) files · \(b) bytes · newest \(n ?? "—")"
            case .absent:                      "\(path) · absent"
            case .unreadable(let why):         "\(path) · UNREADABLE — \(why)"
            }
        }
    }

    nonisolated struct Fingerprint: Equatable, Sendable, Codable {
        let takenUTC: String
        let items: [ItemReading]
        /// Table name to row count, every table.
        let tables: [String: Int]
        let migrations: [String]
        let quickCheck: String
        let foreignKeyViolations: Int
        /// Preference key to a hash of its value's stable description. The
        /// values themselves are the athlete's settings and consent record and
        /// have no business in a fingerprint.
        let preferences: [String: String]

        /// **EVERYTHING EXCEPT `takenUTC`.** Two readings of an unchanging app
        /// must compare equal, and they are taken seconds apart by definition.
        func differences(from other: Fingerprint) -> [String] {
            var out: [String] = []

            let mine = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let theirs = Dictionary(other.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for path in Set(mine.keys).union(theirs.keys).sorted() {
                switch (mine[path], theirs[path]) {
                case (let a?, let b?) where a != b:
                    out.append("\(path): was \(b.line), now \(a.line)")
                case (nil, .some):  out.append("\(path): no longer read at all")
                case (.some, nil):  out.append("\(path): was not read before")
                default: break
                }
            }

            for table in Set(tables.keys).union(other.tables.keys).sorted() {
                let a = tables[table], b = other.tables[table]
                if a != b {
                    out.append("\(table): was \(b.map(String.init) ?? "not counted"), "
                             + "now \(a.map(String.init) ?? "not counted")")
                }
            }

            if migrations != other.migrations { out.append("the applied migrations changed") }
            if quickCheck != other.quickCheck {
                out.append("integrity: was \(other.quickCheck), now \(quickCheck)")
            }
            if foreignKeyViolations != other.foreignKeyViolations {
                out.append("foreign-key violations: was \(other.foreignKeyViolations), "
                         + "now \(foreignKeyViolations)")
            }
            for key in Set(preferences.keys).union(other.preferences.keys).sorted() {
                if preferences[key] != other.preferences[key] {
                    out.append("preference \(key) changed")
                }
            }
            return out
        }
    }

    // MARK: Taking one

    /// **NONISOLATED, SO IT CAN RUN OFF THE ACTOR.** It reads the disk and the
    /// database and touches no store — which is also the runbook's rule that an
    /// export must never construct normal stores as a side effect.
    /// `base` is a PARAMETER and has no default, for the reason
    /// `LegacySnapshot.capture` gives about `items`: the container is a
    /// main-actor read, this runs off the actor, and a default argument is
    /// evaluated at the call site. Passing it in also makes the whole thing
    /// drivable against a temporary directory, which is the only way the
    /// "something moved" path can be tested at all.
    nonisolated static func fingerprint(base: URL,
                                        items: [AppSupportItem],
                                        preferenceKeys: [String],
                                        database: Sub4Database?,
                                        defaults: UserDefaults,
                                        now: Date,
                                        fm: FileManager = .default)
    -> Result<Fingerprint, Refusal> {
        guard let database else { return .failure(.noDatabase) }

        let readings = items
            .sorted { $0.pathComponent < $1.pathComponent }
            .map { read($0, base: base, fm: fm) }

        var tables: [String: Int] = [:]
        var migrations: [String] = []
        var quickCheck = ""
        var violations = 0
        do {
            try database.queue.read { db in
                let names = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table'
                      AND name NOT LIKE 'sqlite_%' ORDER BY name
                    """)
                for name in names {
                    tables[name] = try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
                }
                migrations = try String.fetchAll(db, sql: """
                    SELECT identifier FROM grdb_migrations ORDER BY identifier
                    """)
                quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
                violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            }
        } catch {
            return .failure(.couldNotRead(String(describing: error)))
        }

        var prefs: [String: String] = [:]
        for key in preferenceKeys.sorted() {
            guard let value = defaults.object(forKey: key) else { continue }
            prefs[key] = LegacySnapshot.hex(Data(String(describing: value).utf8))
        }

        return .success(Fingerprint(takenUTC: iso8601(now),
                                    items: readings,
                                    tables: tables,
                                    migrations: migrations,
                                    quickCheck: quickCheck,
                                    foreignKeyViolations: violations,
                                    preferences: prefs))
    }

    private nonisolated static func read(_ item: AppSupportItem, base: URL,
                                         fm: FileManager) -> ItemReading {
        let url = base.appendingPathComponent(item.pathComponent,
                                              isDirectory: item.isDirectory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return ItemReading(path: item.pathComponent, kind: .absent)
        }
        if isDir.boolValue {
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else {
                return ItemReading(path: item.pathComponent,
                                   kind: .unreadable("the directory could not be listed"))
            }
            var bytes: Int64 = 0
            var newest: Date?
            for name in names where !name.hasPrefix(".") {
                let child = url.appendingPathComponent(name)
                guard let a = try? fm.attributesOfItem(atPath: child.path) else { continue }
                bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
                if let m = a[.modificationDate] as? Date, m > (newest ?? .distantPast) {
                    newest = m
                }
            }
            return ItemReading(path: item.pathComponent,
                               kind: .tallied(files: names.filter { !$0.hasPrefix(".") }.count,
                                              bytes: bytes,
                                              newestUTC: newest.map(iso8601)))
        }
        guard let data = try? Data(contentsOf: url) else {
            return ItemReading(path: item.pathComponent,
                               kind: .unreadable("the file could not be read"))
        }
        return ItemReading(path: item.pathComponent,
                           kind: .hashed(sha256: LegacySnapshot.hex(data), bytes: data.count))
    }

    // MARK: Holding it

    /// Take the barrier, fingerprint, run `body`, fingerprint again, and refuse
    /// the whole thing if anything moved.
    ///
    /// **THE HOLD IS RELEASED ON EVERY PATH.** A barrier left up after a throw
    /// would silently stop the sync, the backfill and the background refresh
    /// for the rest of the launch — a far worse outcome than a failed capture,
    /// and exactly the shape `scripts/lock.sh` was written to avoid.
    /// **BOTH READINGS, NOT JUST THE FIRST — patch 444.**
    ///
    /// A manifest recording only the pre-state says *this is what it was*. The
    /// package's claim is stronger and needs both: *this is what it was, this
    /// is what it still was afterwards, and they are the same.* A reader who
    /// has only one of them has to take the equality on trust.
    nonisolated struct Capture<T: Sendable>: Sendable {
        let value: T
        let before: Fingerprint
        let after: Fingerprint
    }

    /// **A TOKEN ONLY `beginHold` CAN MAKE.**
    ///
    /// The package writer does 60 MB of file work and must not run on the main
    /// actor; the hold flag must, because every writer that consults it does.
    /// Splitting them leaves a hole — a caller could do the work without ever
    /// taking the hold — so the work REQUIRES one of these, and nothing outside
    /// this file can build one. A rule enforced by the compiler needs no rule
    /// in `check-invariants.py`.
    nonisolated struct Hold: Sendable {
        fileprivate init() {}
    }

    /// Takes the barrier, or `nil` when somebody already has it.
    static func beginHold(now: Date = Date()) -> Hold? {
        guard !isHeld else { return nil }
        heldSince = now
        return Hold()
    }

    /// **CALL IT ON EVERY PATH.** A barrier left up stops the sync, the
    /// backfill and the background refresh for the rest of the launch.
    static func endHold() { heldSince = nil }

    static func capture<T: Sendable>(base: URL?,
                                     items: [AppSupportItem],
                                     preferenceKeys: [String],
                                     database: Sub4Database?,
                                     defaults: UserDefaults = .standard,
                                     now: @Sendable () -> Date = { Date() },
                                     body: (Fingerprint) throws -> T)
    -> Result<Capture<T>, Refusal> {
        guard let hold = beginHold(now: now()) else {
            return .failure(.alreadyHeld(since: iso8601(heldSince ?? Date())))
        }
        defer { endHold() }
        guard let base else { return .failure(.containerUnreachable) }
        return runInside(hold: hold, base: base, items: items,
                         preferenceKeys: preferenceKeys, database: database,
                         defaults: defaults, now: now, body: body)
    }

    /// **NONISOLATED, AND IT NEEDS A `Hold`.** This is the half that does the
    /// work, so it runs off the main actor — and the token is what stops it
    /// running without the barrier up.
    nonisolated static func runInside<T: Sendable>(
        hold: Hold,
        base: URL,
        items: [AppSupportItem],
        preferenceKeys: [String],
        database: Sub4Database?,
        defaults: UserDefaults,
        now: () -> Date,
        body: (Fingerprint) throws -> T
    ) -> Result<Capture<T>, Refusal> {
        _ = hold
        let before = fingerprint(base: base, items: items,
                                 preferenceKeys: preferenceKeys,
                                 database: database, defaults: defaults, now: now())
        guard case .success(let pre) = before else {
            return .failure(refusal(of: before))
        }

        let produced: T
        do { produced = try body(pre) }
        catch let refusal as Refusal { return .failure(refusal) }
        catch { return .failure(.couldNotRead(String(describing: error))) }

        let after = fingerprint(base: base, items: items,
                                preferenceKeys: preferenceKeys,
                                database: database, defaults: defaults, now: now())
        guard case .success(let post) = after else {
            return .failure(refusal(of: after))
        }

        let moved = post.differences(from: pre)
        guard moved.isEmpty else { return .failure(.movedDuringCapture(moved)) }
        return .success(Capture(value: produced, before: pre, after: post))
    }

    private nonisolated static func refusal(of result: Result<Fingerprint, Refusal>) -> Refusal {
        if case .failure(let r) = result { return r }
        return .couldNotRead("unknown")
    }

    // MARK: Time

    nonisolated static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    /// For the tests, which need a barrier that is definitely down.
    static func releaseForTesting() { heldSince = nil; refusals = [:] }
}
