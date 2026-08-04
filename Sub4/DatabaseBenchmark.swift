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
        /// Total across `readsSampled` reads, not one read. Divide before
        /// quoting a per-chart figure.
        let normalisedReadSeconds: Double
        let chunkedReadSeconds: Double

        /// How many recordings each shape was asked for — patch 211.
        let readsSampled: Int
        let normalisedValuesRead: Int
        let chunkedValuesRead: Int

        /// THE CHECK THAT WOULD HAVE CAUGHT PATCH 209's DEFECT IN A SECOND.
        ///
        /// Both shapes hold the same series, so twenty reads must return
        /// twenty × `samplesPerActivity` values on each side. A key that
        /// matches nothing returns zero, and zero is very fast — which is
        /// exactly how a read of nothing passed for a read worth quoting.
        var readsAgree: Bool {
            let expected = readsSampled * samplesPerActivity
            return normalisedValuesRead == expected && chunkedValuesRead == expected
        }

        var readCheckLabel: String {
            readsAgree
                ? "\(readsSampled) reads, \(normalisedValuesRead) values each side"
                : "MISMATCH — normalised \(normalisedValuesRead), chunked \(chunkedValuesRead), expected \(readsSampled * samplesPerActivity)"
        }

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

        /// The comparison as lines, for the copy button and for the ADR.
        ///
        /// Shared with the screen rather than formatted twice: a diagnostic
        /// that says something different from what the reader is looking at is
        /// worse than no diagnostic.
        var diagnosticLines: [String] {
            let n = Double(max(1, readsSampled))
            return [
                "Samples: \(sampleRows) (\(activities) × \(samplesPerActivity))",
                String(format: "Normalised: %lld bytes, import %.2f s, read %.3f ms/recording",
                       normalisedBytes, normalisedImportSeconds, normalisedReadSeconds * 1000 / n),
                String(format: "Chunked:    %lld bytes, import %.2f s, read %.3f ms/recording",
                       chunkedBytes, chunkedImportSeconds, chunkedReadSeconds * 1000 / n),
                String(format: "Ratios (reported, not deciding): storage ×%.2f, import ×%.2f, read ×%.2f",
                       storageRatio, importRatio, readRatio),
                "Read check: \(readCheckLabel)"
            ] + budgetChecks.map {
                "Budget \($0.passes ? "PASS" : "FAIL") — \($0.name): \($0.measured) against \($0.budget)"
            } + [
                readsAgree
                    ? "Verdict: normalised is \(normalisedIsAffordable ? "affordable" : "NOT affordable")"
                    : "Verdict: WITHHELD — the read measurement is not valid"
            ]
        }

        // MARK: The verdict — rewritten in patch 212

        /// Per recording, not per run.
        var normalisedReadMillisecondsPerRecording: Double {
            readsSampled == 0 ? 0 : normalisedReadSeconds * 1000 / Double(readsSampled)
        }
        var chunkedReadMillisecondsPerRecording: Double {
            readsSampled == 0 ? 0 : chunkedReadSeconds * 1000 / Double(readsSampled)
        }

        /// Per activity, because that is how importing actually arrives —
        /// a handful of new sessions at a time, not ten thousand at once.
        var normalisedImportMillisecondsPerActivity: Double {
            activities == 0 ? 0 : normalisedImportSeconds * 1000 / Double(activities)
        }

        /// Sample storage scaled to the design target, so a 500-activity run
        /// and a 10,000-activity run are judged against the same number.
        var normalisedBytesAtDesignTarget: Int64 {
            activities == 0 ? 0
                : Int64(Double(normalisedBytes) / Double(activities)
                        * Double(Budget.designTargetActivities))
        }

        var budgetChecks: [BudgetCheck] {
            [
                BudgetCheck(name: "Read a trace",
                            measured: String(format: "%.2f ms", normalisedReadMillisecondsPerRecording),
                            budget: String(format: "< %.0f ms", Budget.readMillisecondsPerRecording),
                            passes: normalisedReadMillisecondsPerRecording < Budget.readMillisecondsPerRecording),
                BudgetCheck(name: "Import an activity",
                            measured: String(format: "%.2f ms", normalisedImportMillisecondsPerActivity),
                            budget: String(format: "< %.0f ms", Budget.importMillisecondsPerActivity),
                            passes: normalisedImportMillisecondsPerActivity < Budget.importMillisecondsPerActivity),
                BudgetCheck(name: "Storage at \(Budget.designTargetActivities.formatted())",
                            measured: ByteCountFormatter.string(fromByteCount: normalisedBytesAtDesignTarget,
                                                                countStyle: .file),
                            budget: "< " + ByteCountFormatter.string(fromByteCount: Budget.storageBytes,
                                                                     countStyle: .file),
                            passes: normalisedBytesAtDesignTarget < Budget.storageBytes)
            ]
        }

        /// THE VERDICT, AND WHY IT IS NO LONGER A RATIO — patch 212.
        ///
        /// Patch 206 said "keep normalised unless it costs more than three
        /// times the storage or three times the read". Three runs on the phone
        /// gave read ratios of ×5.04, ×4.73 and ×2.73, so the same rule on the
        /// same hardware answered "chunk it" and "keep normalised" on
        /// consecutive runs. A verdict that flips between identical runs is not
        /// a verdict.
        ///
        /// The fault was measuring one shape against the other instead of
        /// against what the app needs. Reading a trace takes 0.165 ms
        /// normalised and 0.060 ms chunked; chunked is nearly three times
        /// faster and BOTH are irrelevant next to a frame at 16 ms. A ratio
        /// between two numbers that do not matter is still a number, and it
        /// was steering the decision.
        ///
        /// These budgets are absolute, tied to what the app does, and stated
        /// so that a later disagreement is with the budget rather than with
        /// the arithmetic. Ratios are still reported — they are the right way
        /// to describe the difference — they just no longer decide.
        ///
        /// Import is in here because it was the largest real difference (×28)
        /// and the old rule ignored it entirely.
        enum Budget {
            /// One activity's full trace, which is what drawing a stream chart
            /// costs. Well inside a 16 ms frame with room for the drawing.
            static let readMillisecondsPerRecording = 5.0
            /// Fifty new sessions after a long gap should import in about two
            /// seconds, so fifty milliseconds each.
            static let importMillisecondsPerActivity = 50.0
            /// Half a gigabyte of samples on a phone is the point at which
            /// this stops being a personal app's business.
            static let storageBytes: Int64 = 500_000_000
            static let designTargetActivities = 10_000
        }

        struct BudgetCheck: Sendable, Equatable, Identifiable {
            let name: String
            let measured: String
            let budget: String
            let passes: Bool
            var id: String { name }
        }

        var normalisedIsAffordable: Bool {
            readsAgree && budgetChecks.allSatisfy(\.passes)
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

        var diagnosticLines: [String] {
            var lines = ["Benchmark: \(activities) activities, \(samplesPerActivity) samples each",
                         String(format: "Build: %.2f s", buildSeconds)]
            for m in queries {
                // %ld, not %d: `Int` is 64-bit here and `%d` reads 32 of them.
                lines.append(String(format: "  %@: %@ — %ld rows, %.2f µs/row",
                                    m.name, m.label, m.rows, m.microsecondsPerRow))
            }
            lines.append("Growth over empty schema: \(growthBytes) bytes")
            lines.append(contentsOf: storage.diagnosticLines)
            return lines
        }
    }

    // MARK: Running

    /// ACTIVITIES PER TRANSACTION — patch 209.
    ///
    /// Ten thousand activities at 300 samples is three million `recording_sample`
    /// rows. Writing them in ONE transaction, which is what patch 206 did, keeps
    /// the whole rollback journal alive until the commit; on a phone that is a
    /// memory-pressure kill rather than a measurement, and it is not how the
    /// importer in 3.3 will work either.
    ///
    /// The SAME size is used for both storage shapes, which is what keeps the
    /// comparison honest — batching changes both sides equally, so the ratio
    /// that §9 question 3 turns on is unaffected by the number chosen here.
    static let batchSize = 250

    /// Recordings read per shape when measuring read cost — patch 211.
    ///
    /// One was not enough. At 500 activities a single read of one recording
    /// runs in half a millisecond, which is inside the noise of anything else
    /// the phone is doing, and it decides half of §9 question 3.
    static let readSamples = 20

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
            try insertActivities(queue, count: activities, progress: progress)
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
    private static func insertActivities(_ queue: DatabaseQueue, count: Int,
                                         progress: (String) -> Void) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, label, createdUTC)
                VALUES ('BENCH', 'Benchmark', '2020-01-01T00:00:00Z')
                """)
        }

        let disciplines = Sub4Migrations.initialDisciplines
        try eachBatch(of: count, in: queue, label: "Building activities",
                      progress: progress) { db, range in
            for i in range {
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

    /// Walks `0..<count` in `batchSize` chunks, checking for cancellation at
    /// each boundary.
    ///
    /// CANCELLATION IS CHECKED HERE AND NOWHERE ELSE, deliberately. A phone
    /// run of ten thousand takes long enough that the athlete will want a way
    /// out, and a batch boundary is the only place where stopping leaves a
    /// consistent database — which does not matter for a temporary file that is
    /// about to be deleted, but does mean the abandoned transaction is small.
    /// One transaction per batch, which is also why the write lives here rather
    /// than at the call sites: a caller that opened its own transaction around
    /// the whole loop would silently undo the batching.
    private static func eachBatch(of count: Int,
                                  in queue: DatabaseQueue,
                                  label: String,
                                  progress: (String) -> Void,
                                  _ body: (Database, Range<Int>) throws -> Void) throws {
        var start = 0
        while start < count {
            try Task.checkCancellation()
            let end = min(start + batchSize, count)
            try queue.write { db in try body(db, start..<end) }
            if count > batchSize { progress("\(label) \(end)/\(count)…") }
            start = end
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
            try insertNormalised(queue, activities: activities, series: series,
                                 progress: progress)
        }
        let afterNormalised = fileSize(file)

        progress("Importing chunked…")
        let chunkedImport = try clock.measure {
            try insertChunked(queue, activities: activities, series: series,
                              progress: progress)
        }
        let afterChunked = fileSize(file)

        // THE READ COST — REBUILT IN PATCH 211, BECAUSE THE FIRST VERSION
        // MEASURED NOTHING.
        //
        // It read BOTH shapes with `"R\(activities / 2)"`. `insertChunked`
        // writes its key as `"C\(i)"`, so the chunked side was a lookup for a
        // row that does not exist: it timed a miss and unpacked an empty blob.
        // The phone reported "Read cost ×0.28" and the number was furniture.
        // No test caught it because no test asserted the read returned
        // anything — the same omission as every other defect in this file's
        // history.
        //
        // Three changes. Each shape reads its OWN key. Twenty recordings
        // rather than one, because a single sub-millisecond sample is noise
        // and this figure decides half of §9 question 3. And both sides count
        // what they got back, so a miss can never again pass for a fast read.
        //
        // Spread across the fixture on purpose: reading R0 twenty times would
        // measure a page that stayed hot after the first touch, which is not
        // what drawing twenty different activities' charts costs.
        let step = max(1, activities / readSamples)
        let indices = Array(stride(from: 0, to: activities, by: step).prefix(readSamples))

        var normalisedValues = 0
        let normalisedRead = try clock.measure {
            try queue.read { db in
                for i in indices {
                    normalisedValues += try Double.fetchAll(db, sql: """
                        SELECT distanceM FROM recording_sample
                        WHERE recordingID = ? ORDER BY ordinal
                        """, arguments: ["R\(i)"]).count
                }
            }
        }

        var chunkedValues = 0
        let chunkedRead = try clock.measure {
            try queue.read { db in
                for i in indices {
                    let blob = try Data.fetchOne(db, sql: """
                        SELECT distanceM FROM recording_chunk WHERE recordingID = ?
                        """, arguments: ["C\(i)"])
                    chunkedValues += unpack(blob ?? Data()).count
                }
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
            chunkedReadSeconds: seconds(chunkedRead),
            readsSampled: indices.count,
            normalisedValuesRead: normalisedValues,
            chunkedValuesRead: chunkedValues)
    }

    private static func insertNormalised(_ queue: DatabaseQueue,
                                         activities: Int,
                                         series: Series,
                                         progress: (String) -> Void) throws {
        try eachBatch(of: activities, in: queue, label: "Importing normalised",
                      progress: progress) { db, range in
            for i in range {
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
                                      series: Series,
                                      progress: (String) -> Void) throws {
        let distance = pack(series.distance)
        let heartRate = pack(series.heartRate)
        let speed = pack(series.speed)
        let altitude = pack(series.altitude)
        try eachBatch(of: activities, in: queue, label: "Importing chunked",
                      progress: progress) { db, range in
            for i in range {
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
