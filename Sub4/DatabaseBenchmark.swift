//
//  DatabaseBenchmark.swift
//  Sub4
//
//  The measurement that decides the recording shape — patch 206, plan steps
//  3.2.6 and 3.2.7, ADR-0003 §9 question 3.
//
//  WHAT THIS IS FOR, AND WHY IT IS NOT OPTIONAL
//  -------------------------------------------
//  `recording_sample` stores one row per sample. That was taken PROVISIONALLY:
//  §9 question 3 recorded "normalised, benchmark at 10,000 in 3.2", and plan
//  step 3.2.7 says the simpler option is retained "only if it meets
//  storage/import/query budgets". Nobody has measured it.
//
//  At roughly 300 samples an activity, 10,000 activities is three million rows.
//  If that fails the budget, the fix is a new migration AND a rewritten
//  importer — and 3.3 is the importer. So this runs before 3.3, not after.
//
//  IT NEVER TOUCHES THE REAL DATABASE
//  ----------------------------------
//  Every run builds a fresh database in a temporary directory and deletes it
//  afterwards. A benchmark that wrote three million rows into the file holding
//  the athlete's training would be a benchmark nobody should press.
//
//  DETERMINISTIC FIXTURES, NO RANDOMNESS
//  -------------------------------------
//  Every value is derived from its index. Two runs of the same size produce
//  byte-identical databases, so a difference between runs is the machine or the
//  schema and never the data. Randomised fixtures would make the
//  normalised-versus-chunked comparison unfalsifiable: any gap could be
//  explained away as a different draw.
//
//  WHAT "CHUNKED" MEANS HERE
//  -------------------------
//  One row per recording, each series packed as a blob of little-endian
//  Float64 — which is essentially what `ActivityStreams` already does in JSON,
//  minus the text encoding. It is deliberately NOT created by a migration:
//  shipping a table for the option that might lose would be committing to both.
//  It exists inside the benchmark's temporary database only.
//

import Foundation
import GRDB

nonisolated enum DatabaseBenchmark {

    // MARK: What comes out

    struct Measurement: Sendable, Equatable, Identifiable {
        let name: String
        let seconds: Double
        /// Rows returned, or rows written for an import measurement.
        let rows: Int

        var id: String { name }

        /// Microseconds per row. The figure that survives a change of fixture
        /// size, and therefore the one worth comparing across runs.
        var microsecondsPerRow: Double {
            rows == 0 ? 0 : (seconds * 1_000_000) / Double(rows)
        }

        var label: String {
            seconds < 0.001
                ? String(format: "%.2f ms", seconds * 1000)
                : String(format: "%.0f ms", seconds * 1000)
        }
    }

    /// §9 question 3, as numbers.
    struct StorageComparison: Sendable, Equatable {
        let activities: Int
        let samplesPerActivity: Int
        let normalisedBytes: Int64
        let chunkedBytes: Int64
        let normalisedImportSeconds: Double
        let chunkedImportSeconds: Double
        let normalisedReadSeconds: Double
        let chunkedReadSeconds: Double

        var sampleRows: Int { activities * samplesPerActivity }
        var storageRatio: Double {
            chunkedBytes == 0 ? 0 : Double(normalisedBytes) / Double(chunkedBytes)
        }
        var importRatio: Double {
            chunkedImportSeconds == 0 ? 0 : normalisedImportSeconds / chunkedImportSeconds
        }
        var readRatio: Double {
            chunkedReadSeconds == 0 ? 0 : normalisedReadSeconds / chunkedReadSeconds
        }

        /// The verdict, stated rather than left to the reader.
        ///
        /// NOT A RECOMMENDATION — a reading of the budget in plan step 3.2.7:
        /// keep the simpler shape unless it costs materially more. "Materially"
        /// is defined here as more than three times the storage or more than
        /// three times the read cost, and the number is written down so that a
        /// later disagreement is with the threshold rather than with the
        /// arithmetic.
        var normalisedIsAffordable: Bool {
            storageRatio <= 3.0 && readRatio <= 3.0
        }
    }

    struct Result: Sendable {
        let activities: Int
        let samplesPerActivity: Int
        let buildSeconds: Double
        let queries: [Measurement]
        let storage: StorageComparison
        /// Bytes of the whole benchmark database, minus the empty baseline.
        /// Absolute size is dominated by the ~400 KB of root pages a schema
        /// with 31 tables and 60-odd indexes costs before a single row exists,
        /// which is not what anybody is trying to measure.
        let growthBytes: Int64
    }

    // MARK: Running

    /// Builds a database of `activities` activities and measures it.
    ///
    /// `progress` is called on the calling thread with a line at each stage.
    /// Ten thousand activities with their recordings is three million rows and
    /// takes long enough that a screen with no output looks hung.
    static func run(activities: Int,
                    samplesPerActivity: Int = 300,
                    progress: (String) -> Void = { _ in }) throws -> Result {

        // A DIRECTORY PER RUN, NOT PER SIZE — patch 208.
        //
        // This was `sub4-benchmark-\(activities)`, which is a shared name, and
        // Swift Testing runs a suite's tests in parallel. Four tests calling
        // `run(activities: 40)` got the same directory; each one's cleanup
        // deleted a sibling's open database, and SQLite said so:
        //
        //   BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised
        //   by API violation: vnode unlinked while in use
        //
        // The same shape as the export race in patch 184, which has a
        // `@Suite(.serialized)` and a comment about it two files away. A unique
        // directory is the fix that also holds outside the tests: the health
        // screen can be opened twice, and two runs must not share a path.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("bench.sqlite")
        let queue = try DatabaseQueue(path: file.path,
                                      configuration: Sub4Database.configuration(label: "bench"))
        // CLOSED BEFORE THE DIRECTORY GOES, and the order matters. `defer`
        // blocks run last-in-first-out, so this one runs before the removal
        // above it. Without it the directory is unlinked while SQLite still
        // holds the file open — which is the second half of the same warning,
        // and would happen even with no concurrency at all.
        defer { try? queue.close() }

        try Sub4Migrations.migrator.migrate(queue)
        let baseline = fileSize(file)

        progress("Building \(activities) activities…")
        let clock = ContinuousClock()
        let build = try clock.measure {
            try insertActivities(queue, count: activities)
        }

        progress("Measuring queries…")
        let queries = try measureQueries(queue, activities: activities)

        progress("Comparing recording shapes…")
        let storage = try compareRecordingShapes(queue, file: file,
                                                 activities: activities,
                                                 samplesPerActivity: samplesPerActivity,
                                                 progress: progress)

        return Result(activities: activities,
                      samplesPerActivity: samplesPerActivity,
                      buildSeconds: seconds(build),
                      queries: queries,
                      storage: storage,
                      growthBytes: max(0, fileSize(file) - baseline))
    }

    // MARK: Fixtures

    /// Deterministic, index-derived. See the header on why nothing here is
    /// random.
    private static func insertActivities(_ queue: DatabaseQueue, count: Int) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, label, createdUTC)
                VALUES ('BENCH', 'Benchmark', '2020-01-01T00:00:00Z')
                """)

            let disciplines = Sub4Migrations.initialDisciplines
            for i in 0..<count {
                // Spread across roughly ten years of days so the day and week
                // queries have realistic selectivity rather than every row
                // landing on one date.
                let day = dayKey(offsetDays: i / 3)
                let discipline = disciplines[i % disciplines.count]
                let args: StatementArguments = [
                    "A\(i)", day, "\(day)T07:00:00", "\(day)T05:00:00Z",
                    discipline, Double(5_000 + (i % 20) * 500),
                    2_000 + (i % 40) * 60, 2_100 + (i % 40) * 60
                ]
                try db.execute(sql: """
                    INSERT INTO activity
                      (id, accountID, dayKey, startLocal, startUTC, discipline, name,
                       distanceM, movingSeconds, elapsedSeconds, createdUTC, updatedUTC)
                    VALUES (?, 'BENCH', ?, ?, ?, ?, 'Session',
                            ?, ?, ?, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')
                    """, arguments: args)

                try db.execute(sql: """
                    INSERT INTO activity_source_record
                      (id, activityID, accountID, sourceID, externalID, firstSeenUTC, lastSeenUTC)
                    VALUES (?, ?, 'BENCH', ?, ?, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')
                    """, arguments: ["S\(i)", "A\(i)",
                                     i % 4 == 0 ? "appleHealth" : "strava", "X\(i)"])

                // A third of activities carry a correction, so "unmatched" has
                // something to exclude rather than returning everything.
                if i % 3 == 0 {
                    try db.execute(sql: """
                        INSERT INTO match_decision
                          (id, accountID, planSessionUID, activityID, decidedUTC)
                        VALUES (?, 'BENCH', ?, ?, '2020-01-01T00:00:00Z')
                        """, arguments: ["M\(i)", "s-\(i)", "A\(i)"])
                }
            }
        }
    }

    // MARK: The six query shapes — plan step 3.2.6

    private static func measureQueries(_ queue: DatabaseQueue,
                                       activities: Int) throws -> [Measurement] {
        let clock = ContinuousClock()
        let midDay = dayKey(offsetDays: activities / 6)
        let weekEnd = dayKey(offsetDays: activities / 6 + 7)

        func measure(_ name: String, _ sql: String,
                     _ args: StatementArguments = []) throws -> Measurement {
            var rows = 0
            let d = try clock.measure {
                rows = try queue.read { try Row.fetchAll($0, sql: sql, arguments: args).count }
            }
            return Measurement(name: name, seconds: seconds(d), rows: rows)
        }

        var out: [Measurement] = []
        out.append(try measure("day",
            "SELECT * FROM activity WHERE dayKey = ?", [midDay]))
        out.append(try measure("week",
            "SELECT * FROM activity WHERE dayKey >= ? AND dayKey < ? ORDER BY startUTC",
            [midDay, weekEnd]))
        out.append(try measure("source", """
            SELECT a.* FROM activity a
            JOIN activity_source_record r ON r.activityID = a.id
            WHERE r.sourceID = 'strava'
            """))
        out.append(try measure("sport",
            "SELECT * FROM activity WHERE discipline = 'run' ORDER BY startUTC DESC"))
        // The one with no index to lean on, and therefore the one worth
        // watching: an anti-join over the whole history.
        out.append(try measure("unmatched", """
            SELECT a.* FROM activity a
            LEFT JOIN match_decision m ON m.activityID = a.id
            WHERE m.id IS NULL
            """))
        out.append(try measure("detail", """
            SELECT a.*, r.sourceID, r.externalID FROM activity a
            LEFT JOIN activity_source_record r ON r.activityID = a.id
            WHERE a.id = ?
            """, ["A\(activities / 2)"]))
        return out
    }

    // MARK: Normalised versus chunked — plan step 3.2.7

    private static func compareRecordingShapes(_ queue: DatabaseQueue,
                                               file: URL,
                                               activities: Int,
                                               samplesPerActivity: Int,
                                               progress: (String) -> Void) throws -> StorageComparison {
        let clock = ContinuousClock()

        // The chunked table lives only here. See the header.
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE recording_chunk (
                  recordingID TEXT PRIMARY KEY,
                  activityID TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                  sampleCount INTEGER NOT NULL,
                  distanceM BLOB NOT NULL,
                  heartRate BLOB,
                  speedMS BLOB,
                  altitudeM BLOB
                )
                """)
        }

        let series = sampleSeries(count: samplesPerActivity)
        let before = fileSize(file)

        progress("Importing normalised…")
        let normalisedImport = try clock.measure {
            try insertNormalised(queue, activities: activities, series: series)
        }
        let afterNormalised = fileSize(file)

        progress("Importing chunked…")
        let chunkedImport = try clock.measure {
            try insertChunked(queue, activities: activities, series: series)
        }
        let afterChunked = fileSize(file)

        // A representative read: one activity's full trace, which is what
        // drawing a stream chart costs.
        let target = "R\(activities / 2)"
        let normalisedRead = try clock.measure {
            _ = try queue.read { db in
                try Double.fetchAll(db, sql: """
                    SELECT distanceM FROM recording_sample
                    WHERE recordingID = ? ORDER BY ordinal
                    """, arguments: [target])
            }
        }
        let chunkedRead = try clock.measure {
            _ = try queue.read { db in
                let blob = try Data.fetchOne(db, sql: """
                    SELECT distanceM FROM recording_chunk WHERE recordingID = ?
                    """, arguments: [target])
                return blob.map(unpack) ?? []
            }
        }

        return StorageComparison(
            activities: activities,
            samplesPerActivity: samplesPerActivity,
            normalisedBytes: max(0, afterNormalised - before),
            chunkedBytes: max(0, afterChunked - afterNormalised),
            normalisedImportSeconds: seconds(normalisedImport),
            chunkedImportSeconds: seconds(chunkedImport),
            normalisedReadSeconds: seconds(normalisedRead),
            chunkedReadSeconds: seconds(chunkedRead))
    }

    private static func insertNormalised(_ queue: DatabaseQueue,
                                         activities: Int,
                                         series: Series) throws {
        try queue.write { db in
            for i in 0..<activities {
                try db.execute(sql: """
                    INSERT INTO recording (id, activityID, fetchedUTC, sampleCount, sourceID)
                    VALUES (?, ?, '2020-01-01T00:00:00Z', ?, 'strava')
                    """, arguments: ["R\(i)", "A\(i)", series.distance.count])

                let statement = try db.makeStatement(sql: """
                    INSERT INTO recording_sample
                      (recordingID, ordinal, distanceM, heartRate, speedMS, altitudeM)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """)
                for (j, d) in series.distance.enumerated() {
                    let args: StatementArguments = ["R\(i)", j, d,
                                                    series.heartRate[j],
                                                    series.speed[j],
                                                    series.altitude[j]]
                    try statement.execute(arguments: args)
                }
            }
        }
    }

    private static func insertChunked(_ queue: DatabaseQueue,
                                      activities: Int,
                                      series: Series) throws {
        let distance = pack(series.distance)
        let heartRate = pack(series.heartRate)
        let speed = pack(series.speed)
        let altitude = pack(series.altitude)
        try queue.write { db in
            for i in 0..<activities {
                let args: StatementArguments = ["C\(i)", "A\(i)", series.distance.count,
                                                distance, heartRate, speed, altitude]
                try db.execute(sql: """
                    INSERT INTO recording_chunk
                      (recordingID, activityID, sampleCount, distanceM, heartRate,
                       speedMS, altitudeM)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: args)
            }
        }
    }

    // MARK: Deterministic sample data

    struct Series: Sendable {
        let distance: [Double]
        let heartRate: [Double]
        let speed: [Double]
        let altitude: [Double]
    }

    /// A plausible trace, entirely index-derived: distance climbs, heart rate
    /// drifts up and oscillates, altitude rolls. The point is not realism — it
    /// is that the same bytes go into both shapes.
    static func sampleSeries(count: Int) -> Series {
        var distance: [Double] = [], heartRate: [Double] = []
        var speed: [Double] = [], altitude: [Double] = []
        distance.reserveCapacity(count)
        heartRate.reserveCapacity(count)
        speed.reserveCapacity(count)
        altitude.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i)
            distance.append(t * 33.7)
            heartRate.append(128 + 18 * sin(t / 21) + t / 60)
            speed.append(3.1 + 0.4 * sin(t / 13))
            altitude.append(12 + 7 * sin(t / 37))
        }
        return Series(distance: distance, heartRate: heartRate,
                      speed: speed, altitude: altitude)
    }

    /// Little-endian Float64, which is what the platform already is — so this
    /// is a copy rather than a conversion, and the comparison is not measuring
    /// a byte-swapping loop.
    static func pack(_ values: [Double]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Double>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: Double.self),
                count: count))
        }
    }

    // MARK: Small helpers

    private static func dayKey(offsetDays: Int) -> String {
        // Index-derived and calendar-free: a fixture date does not need to be a
        // real calendar day, it needs to sort and to spread. Using `Calendar`
        // here would put the benchmark's fixtures at the mercy of the device's
        // time zone, which is the exact class of bug §4.5 was about.
        let year = 2016 + offsetDays / 365
        let dayOfYear = offsetDays % 365
        let month = dayOfYear / 30 + 1
        let day = dayOfYear % 30 + 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
