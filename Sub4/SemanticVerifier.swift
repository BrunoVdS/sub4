//
//  SemanticVerifier.swift
//  Sub4
//
//  Does the database say the same thing as the stores — step 3.5, patch 263,
//  ADR-0003 §12.16.
//
//  THE SENTENCE THIS FILE EXISTS FOR
//  --------------------------------
//  `migration_run` has had a `verified` state since patch 255 and nothing has
//  ever been able to reach it. Every successful import stops at `pending`,
//  which the ledger's own header calls "the honest answer: the verifier is the
//  next patch". This is that patch, eight patches later.
//
//  D7 switches the app's reads to the database. That decision cannot be made
//  from an import report, because an import report says what the importer
//  believes it did. This says whether it is true.
//
//  IT DOES NOT STOP AT THE FIRST FAILURE
//  -------------------------------------
//  A verifier that quits on the first mismatch tells you one thing when you
//  need all of them, and turns "what is wrong with this migration" into a
//  sequence of runs. Every check runs, every check reports, and the report
//  carries both figures — not a tick.
//
//  THE EXPECTATIONS COME FROM THE STORES, NEVER FROM THE EXCLUSION RULES
//  --------------------------------------------------------------------
//  A weather reading, a trace and a detail are only expected in the database
//  if their activity is IN THE STORE. That is the whole rule, and it is
//  deliberately not "…unless `DataCorrections` excludes it".
//
//  The difference matters. Excluded activities never reach `ActivityStore` —
//  `ExcludedRecordingTests` asserts that — so deriving the expectation from
//  the store's own contents gets the exclusions right for free, WITHOUT this
//  file knowing the exclusion policy exists. A verifier that imported the
//  policy would agree with the importer about anything the policy got wrong,
//  which is the one class of error a verifier is for.
//
//  WHAT IS DELIBERATELY NOT HERE: CTL
//  ----------------------------------
//  The plan names "CTL on a chosen day" among the representative domain
//  outputs, and it is not in this patch. `PMC.build` takes `[DailyLoad]`, and
//  the code that produces those reads `Activity` values. Comparing CTL both
//  ways would mean writing a SECOND `DailyLoad` builder against SQL — and a
//  disagreement between two builders is ambiguous in exactly the wrong way:
//  nobody could tell whether the data diverged or the second builder is wrong.
//
//  The right place for it is D6 shadow parity, where the app grows a
//  database-backed activity reader and the SAME `PMC` runs over both sides.
//  Then a divergence means the data diverged, which is the question being
//  asked. Recorded here rather than quietly skipped.
//

import Foundation
import GRDB

// MARK: - One comparison

nonisolated struct VerificationCheck: Equatable, Identifiable {
    /// What was compared, in the terms the athlete would use.
    let name: String
    /// The table it lives in. THE ACCEPTANCE CRITERION: a failure names this,
    /// because "the verifier failed" sends somebody looking through fifty-one
    /// tables.
    let table: String
    let expected: String
    let found: String
    let passed: Bool
    /// What to look at, when a count is not enough. May carry the athlete's
    /// own identifiers, so it goes on the screen and never in the paste.
    let detail: String?

    var id: String { name }

    static func compare(_ name: String, table: String,
                        expected: Int, found: Int,
                        detail: String? = nil) -> VerificationCheck {
        .init(name: name, table: table,
              expected: "\(expected)", found: "\(found)",
              passed: expected == found, detail: detail)
    }
}

// MARK: - The whole run

nonisolated struct VerificationReport: Equatable {
    let checks: [VerificationCheck]
    let seconds: Double

    /// Passing means every comparison passed. There is no partial credit and
    /// no "mostly" — `verified` is a state D7 acts on.
    var passed: Bool {
        let failures = checks.filter { !$0.passed }
        return failures.isEmpty
    }

    var failures: [VerificationCheck] { checks.filter { !$0.passed } }

    /// One line for the ledger. Counts only — this is stored in the database
    /// and read back into the redacted paste.
    var ledgerNote: String {
        passed
            ? "\(checks.count) comparisons, all agreed"
            : "\(failures.count) of \(checks.count) comparisons disagreed"
    }

    /// COUNTS AND TABLE NAMES ONLY, like §12.9e's survey and for the same
    /// reason: `detail` can carry an activity id or a session uid, and §12.7
    /// promises the paste carries neither.
    var diagnosticLines: [String] {
        var out = [String(format: "Verification: %.2f s — %@", seconds,
                          passed ? "agreed" : "DISAGREED")]
        for c in checks {
            out.append("  \(c.passed ? "ok" : "NO") \(c.name) [\(c.table)]: "
                       + "expected \(c.expected), found \(c.found)")
        }
        return out
    }
}

// MARK: - The verifier

@MainActor
enum SemanticVerifier {

    /// Everything the migration claims to have carried, compared.
    ///
    /// Takes the same inputs `Sub4Import.run` takes, so the two are looking at
    /// the same stores rather than at two readings of them taken at different
    /// moments.
    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       weather: [ActivityWeather] = [],
                       zones: [AthleteStore.HRZone] = [],
                       streams: [ActivityStreams] = [],
                       details: [ActivityDetail] = []) throws -> VerificationReport {

        let clock = ContinuousClock()
        var checks: [VerificationCheck] = []

        let elapsed = try clock.measure {
            // The id every other expectation is derived from.
            let storeIDs = Set(activities.map(\.id))

            try db.queue.read { d in
                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    weather: weather, zones: zones, streams: streams,
                    details: details, storeIDs: storeIDs))
                checks.append(try identityCheck(d, storeIDs: storeIDs))
                checks.append(try fingerprintCheck(d, activities: activities))
                checks.append(contentsOf: try domainChecks(
                    d, activities: activities, weather: weather,
                    details: details, storeIDs: storeIDs))
            }
        }

        return VerificationReport(checks: checks, seconds: seconds(elapsed))
    }

    /// `verify`, for a caller that has nowhere to put a thrown error.
    ///
    /// RETURNS A FAILED REPORT RATHER THAN NIL. A database that cannot be read
    /// is the most serious answer this screen can give, and returning nil would
    /// render as an empty section — indistinguishable from not having pressed
    /// the button. So it comes back as one check, failed, saying so.
    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        weather: [ActivityWeather] = [],
                        zones: [AthleteStore.HRZone] = [],
                        streams: [ActivityStreams] = [],
                        details: [ActivityDetail] = []) -> VerificationReport {
        do {
            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, weather: weather, zones: zones,
                              streams: streams, details: details)
        } catch {
            return VerificationReport(checks: [
                .init(name: "reading the database", table: "—",
                      expected: "readable", found: "failed",
                      passed: false, detail: String(describing: error))
            ], seconds: 0)
        }
    }

    // MARK: 1 — Counts

    /// The cheapest layer, and the one the acceptance criterion is written
    /// against: delete a row by hand and exactly one of these must fail and
    /// name its table.
    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],
                                    weather: [ActivityWeather],
                                    zones: [AthleteStore.HRZone],
                                    streams: [ActivityStreams],
                                    details: [ActivityDetail],
                                    storeIDs: Set<String>) throws -> [VerificationCheck] {

        // Only records whose activity is in the store are expected. See the
        // header: this is how the exclusions come out right without this file
        // knowing they exist.
        let expectedWeather = weather.filter { storeIDs.contains($0.activityId) }.count
        let keptStreams = streams.filter { storeIDs.contains($0.activityId) }
        let keptDetails = details.filter { storeIDs.contains($0.activityId) }
        let expectedStreams = keptStreams.count
        let expectedDetails = keptDetails.count

        // THE CHILD ROWS, COUNTED IN TOTAL — added after the tests found the
        // gap. The domain layer compares the splits of ONE activity, chosen as
        // the richest so the check has something to fail on. That is a
        // representative check by design, and a representative check misses
        // everything it does not represent: a split deleted from any other
        // activity passed every layer.
        //
        // A total is the cheap complement. It cannot say WHICH split went, and
        // the domain check cannot say that a split went at all unless it was
        // the chosen one. Together they cover it.
        let expectedSplits = keptDetails.reduce(0) { $0 + $1.splits.count }
        let expectedSamples = keptStreams.reduce(0) { $0 + $1.count }

        return [
            .compare("activities", table: "activity",
                     expected: activities.count, found: try count(d, "activity")),
            .compare("gear", table: "gear",
                     expected: shoes.count, found: try count(d, "gear")),
            .compare("notes", table: "user_note",
                     expected: notes.count, found: try count(d, "user_note")),
            .compare("weather readings", table: "weather",
                     expected: expectedWeather, found: try count(d, "weather")),
            .compare("traces", table: "recording",
                     expected: expectedStreams, found: try count(d, "recording")),
            .compare("details", table: "activity_detail",
                     expected: expectedDetails, found: try count(d, "activity_detail")),
            .compare("splits", table: "activity_split",
                     expected: expectedSplits, found: try count(d, "activity_split")),
            .compare("trace samples", table: "recording_sample",
                     expected: expectedSamples, found: try count(d, "recording_sample")),
            .compare("heart-rate zones", table: "hr_zone",
                     expected: zones.count, found: try count(d, "hr_zone")),
        ]
    }

    // MARK: 2 — Identity

    /// THE SAME 667, not merely 667.
    ///
    /// Two sets of equal size can disagree completely, and the count check
    /// above would pass on both. This is the one that would catch an activity
    /// imported twice under two ids while another was dropped.
    private static func identityCheck(_ d: Database,
                                      storeIDs: Set<String>) throws -> VerificationCheck {
        let rows = try String.fetchAll(d, sql: """
            SELECT externalID FROM activity_alias WHERE sourceID = ?
            """, arguments: [Sub4Import.sourceID])
        let dbIDs = Set(rows)

        let missing = storeIDs.subtracting(dbIDs).sorted()
        let extra = dbIDs.subtracting(storeIDs).sorted()
        let ok = missing.isEmpty && extra.isEmpty

        var detail: String?
        if !ok {
            // Named, and capped. A list of six hundred is not a diagnosis, and
            // the count beside it says the list is not the whole story.
            detail = """
                missing \(missing.count): \(missing.prefix(5).joined(separator: ", ")) · \
                unexpected \(extra.count): \(extra.prefix(5).joined(separator: ", "))
                """
        }
        return .init(name: "activity identities", table: "activity_alias",
                     expected: "\(storeIDs.count) ids",
                     found: "\(dbIDs.count) ids, \(missing.count) missing, \(extra.count) unexpected",
                     passed: ok, detail: detail)
    }

    // MARK: 3 — Content

    /// A row that exists with the wrong distance passes both layers above.
    ///
    /// Seven fields per activity: the ones every screen in the app reads and
    /// every training figure is computed from. Not every column — `createdUTC`
    /// is written by the importer and has nothing to compare against.
    private static func fingerprintCheck(_ d: Database,
                                         activities: [Activity]) throws -> VerificationCheck {
        var stored: [String: String] = [:]
        let rows = try Row.fetchAll(d, sql: """
            SELECT al.externalID  AS ext,
                   a.startLocal   AS startLocal,
                   a.dayKey       AS dayKey,
                   a.discipline   AS discipline,
                   a.name         AS name,
                   a.distanceM    AS distanceM,
                   a.movingSeconds  AS movingSeconds,
                   a.elapsedSeconds AS elapsedSeconds
              FROM activity a
              JOIN activity_alias al
                ON al.activityID = a.id AND al.sourceID = ?
            """, arguments: [Sub4Import.sourceID])

        for r in rows {
            guard let ext = r["ext"] as String? else { continue }
            stored[ext] = fingerprint(startLocal: r["startLocal"] as String? ?? "",
                                      dayKey: r["dayKey"] as String? ?? "",
                                      discipline: r["discipline"] as String? ?? "",
                                      name: r["name"] as String? ?? "",
                                      distanceM: r["distanceM"] as Double? ?? 0,
                                      moving: r["movingSeconds"] as Int? ?? 0,
                                      elapsed: r["elapsedSeconds"] as Int? ?? 0)
        }

        var differing: [String] = []
        for a in activities {
            let mine = fingerprint(startLocal: a.startLocal,
                                   dayKey: a.dayKey,
                                   discipline: (a.discipline ?? .other).rawValue,
                                   name: a.name,
                                   distanceM: a.distance,
                                   moving: a.movingTime,
                                   elapsed: a.elapsedTime)
            // An activity with no row at all is the identity check's finding,
            // not this one. Reporting it twice would make one fault look like
            // two.
            guard let theirs = stored[a.id] else { continue }
            if theirs != mine { differing.append(a.id) }
        }

        return .init(name: "activity fields", table: "activity",
                     expected: "\(activities.count) matching",
                     found: "\(activities.count - differing.count) matching, \(differing.count) different",
                     passed: differing.isEmpty,
                     detail: differing.isEmpty ? nil
                             : differing.prefix(5).joined(separator: ", "))
    }

    private static func fingerprint(startLocal: String, dayKey: String,
                                    discipline: String, name: String,
                                    distanceM: Double, moving: Int,
                                    elapsed: Int) -> String {
        // Distance to the millimetre. `Double` round-trips exactly through
        // SQLite's REAL, so this is not a tolerance — it is a format, and a
        // tolerance here would hide the rounding bug it looks like it prevents.
        String(format: "%@|%@|%@|%@|%.3f|%d|%d",
               startLocal, dayKey, discipline, name, distanceM, moving, elapsed)
    }

    // MARK: 4 — Domain outputs

    /// Counts, ids and fields can all agree while a figure the app SHOWS comes
    /// out different. These are the three that are computable on both sides
    /// today without writing a second implementation of anything.
    private static func domainChecks(_ d: Database,
                                     activities: [Activity],
                                     weather: [ActivityWeather],
                                     details: [ActivityDetail],
                                     storeIDs: Set<String>) throws -> [VerificationCheck] {
        var out: [VerificationCheck] = []

        // 4a. Volume by discipline — what Today and History add up.
        var storeVolume: [String: (m: Double, s: Int)] = [:]
        for a in activities {
            let k = (a.discipline ?? .other).rawValue
            var v = storeVolume[k] ?? (0, 0)
            v.m += a.distance
            v.s += a.movingTime
            storeVolume[k] = v
        }
        var dbVolume: [String: (m: Double, s: Int)] = [:]
        for r in try Row.fetchAll(d, sql: """
            SELECT discipline, SUM(distanceM) AS m, SUM(movingSeconds) AS s
              FROM activity GROUP BY discipline
            """) {
            guard let k = r["discipline"] as String? else { continue }
            dbVolume[k] = (r["m"] as Double? ?? 0, r["s"] as Int? ?? 0)
        }
        let storeLine = volumeLine(storeVolume)
        let dbLine = volumeLine(dbVolume)
        out.append(.init(name: "volume by discipline", table: "activity",
                         expected: storeLine, found: dbLine,
                         passed: storeLine == dbLine, detail: nil))

        // 4b. One activity's splits. The richest one, so the check has
        // something to fail on — a detail with no splits proves nothing.
        let candidates = details.filter { storeIDs.contains($0.activityId) }
        let deepest = candidates.max { $0.splits.count < $1.splits.count }
        if let deepest, !deepest.splits.isEmpty {
            let stored = try Row.fetchOne(d, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(s.distanceM), 0) AS m
                  FROM activity_split s
                  JOIN activity_detail ad ON ad.id = s.activityDetailID
                  JOIN activity_alias al ON al.activityID = ad.activityID
                                        AND al.sourceID = ?
                 WHERE al.externalID = ?
                """, arguments: [Sub4Import.sourceID, deepest.activityId])
            let n = stored?["n"] as Int? ?? 0
            let m = stored?["m"] as Double? ?? 0
            let mine = String(format: "%d splits, %.1f m", deepest.splits.count,
                              deepest.splits.reduce(0) { $0 + $1.distanceM })
            let theirs = String(format: "%d splits, %.1f m", n, m)
            out.append(.init(name: "splits of one activity", table: "activity_split",
                             expected: mine, found: theirs,
                             passed: mine == theirs,
                             detail: mine == theirs ? nil : deepest.activityId))
        }

        // 4c. One weather reading. Chosen by sorted id rather than at random,
        // so two runs over one database compare the same reading and a
        // difference between runs means the data moved.
        let readable = weather.filter { storeIDs.contains($0.activityId) }
            .sorted { $0.activityId < $1.activityId }
        if let first = readable.first {
            let stored = try Row.fetchOne(d, sql: """
                SELECT w.tempC AS t, w.samples AS n
                  FROM weather w
                  JOIN activity_alias al ON al.activityID = w.activityID
                                        AND al.sourceID = ?
                 WHERE al.externalID = ?
                """, arguments: [Sub4Import.sourceID, first.activityId])
            let mine = String(format: "%.2f °C, %d samples", first.tempC, first.samples)
            let theirs = stored.map {
                String(format: "%.2f °C, %d samples",
                       $0["t"] as Double? ?? 0, $0["n"] as Int? ?? 0)
            } ?? "no row"
            out.append(.init(name: "one weather reading", table: "weather",
                             expected: mine, found: theirs,
                             passed: mine == theirs,
                             detail: mine == theirs ? nil : first.activityId))
        }

        return out
    }

    private static func volumeLine(_ v: [String: (m: Double, s: Int)]) -> String {
        v.keys.sorted().map { k in
            let e = v[k] ?? (0, 0)
            return String(format: "%@ %.1fm/%ds", k, e.m, e.s)
        }.joined(separator: " · ")
    }

    // MARK: Reaching `verified`

    /// Moves a run to `verified`, and ONLY on a report that passed.
    ///
    /// The one line in this file that must never be made convenient. A run
    /// marked `verified` by something that verified nothing is the defect this
    /// project has found six times, and D7 acts on this state.
    @discardableResult
    static func record(_ report: VerificationReport,
                       for runID: String,
                       in db: Sub4Database,
                       now: String = Sub4Import.iso8601(Date())) throws -> Bool {
        guard report.passed else { return false }
        try MigrationLedger.finish(db, id: runID, state: .verified,
                                   note: report.ledgerNote, now: now)
        return true
    }

    // MARK: Small

    private static func count(_ d: Database, _ table: String) throws -> Int {
        // The table name is a literal from `countChecks` and never from input.
        try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
