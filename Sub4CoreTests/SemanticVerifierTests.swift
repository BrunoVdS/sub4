//
//  SemanticVerifierTests.swift
//  Sub4CoreTests
//
//  The verifier — patch 263, plan step 3.5.
//
//  The acceptance criterion, verbatim: "deliberately deleting one row from the
//  database makes the verifier fail and name the table; a clean run reports
//  every comparison it made."
//
//  BOTH HALVES MATTER, AND THE SECOND IS THE ONE THAT USUALLY GETS SKIPPED.
//  A verifier that has only ever passed is not evidence. Every test below that
//  breaks something first is there to prove the check can fail — because a
//  check that cannot fail is a control reporting work it did not do, which is
//  the defect this project has now found six times.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct SemanticVerifierTests {

    // MARK: A migration to verify

    private func activity(_ id: String,
                          km: Double = 10,
                          name: String = "Morning Run",
                          sport: String = "Run") -> Activity {
        Activity(id: id, name: name, sportType: sport,
                 startLocal: "2026-07-28T09:24:06",
                 distance: km * 1000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: 40, averageHeartrate: 142, isTrainer: nil,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T07:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func weather(_ id: String, tempC: Double = 18.5) -> ActivityWeather {
        ActivityWeather(activityId: id, tempC: tempC, feelsLikeC: 17.1,
                        humidity: 0.62, windKmh: 14.0, windFromDegrees: 225,
                        precipitationMm: 0.4, symbolName: "cloud.sun",
                        conditionLabel: "Partly cloudy", samples: 3,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000),
                        source: .openMeteo)
    }

    private func detail(_ id: String, splits: Int = 3) -> ActivityDetail {
        ActivityDetail(activityId: id,
                       splits: (1...max(1, splits)).map {
                           .init(index: $0, distanceM: 1000, movingTime: 300,
                                 elapsedTime: 305, elevationDiff: nil, averageHR: nil)
                       },
                       bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func trace(_ id: String) -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: [0, 100, 200, 300, 400, 500, 600, 700],
                        fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// A migrated database and the stores it was migrated from, so every test
    /// compares like with like.
    private struct Fixture {
        let db: Sub4Database
        let activities: [Activity]
        let weather: [ActivityWeather]
        let details: [ActivityDetail]
        let streams: [ActivityStreams]
        let runID: String
    }

    private func migrated(label: String) throws -> Fixture {
        let db = try Sub4Database.inMemory(label: label)
        let activities = [activity("11111111"),
                          activity("22222222", km: 21.1, name: "Long Run"),
                          activity("33333333", km: 40, name: "Ride", sport: "Ride")]
        let weather = [weather("11111111"), weather("22222222", tempC: 21.0)]
        let details = [detail("11111111", splits: 3), detail("22222222", splits: 5)]
        let streams = [trace("11111111")]

        let report = try Sub4Import.run(into: db, activities: activities, shoes: [],
                                        weather: weather, streams: streams,
                                        details: details, appVersion: "263")
        #expect(report.isClean)
        return Fixture(db: db, activities: activities, weather: weather,
                       details: details, streams: streams,
                       runID: try #require(report.runID))
    }

    private func verify(_ f: Fixture) throws -> VerificationReport {
        try SemanticVerifier.verify(f.db, activities: f.activities,
                                    weather: f.weather, streams: f.streams,
                                    details: f.details)
    }

    // MARK: A clean run reports every comparison it made

    @Test("A faithful migration verifies, and says what it compared")
    func aCleanMigrationPasses() throws {
        let f = try migrated(label: "verify-clean")
        let report = try verify(f)

        #expect(report.passed, "a faithful migration failed verification")
        // The other half of the acceptance criterion. A green tick is not a
        // report; ten named comparisons are.
        #expect(report.checks.count >= 10)
        let names = Set(report.checks.map(\.name))
        #expect(names.contains("activities"))
        #expect(names.contains("activity identities"))
        #expect(names.contains("activity fields"))
        #expect(names.contains("volume by discipline"))
        #expect(names.contains("splits of one activity"))
        #expect(names.contains("one weather reading"))
        // Every check carries both figures, not a verdict.
        let bothSides = report.checks.allSatisfy {
            !$0.expected.isEmpty && !$0.found.isEmpty
        }
        #expect(bothSides)
    }

    @Test("Every check names the table it looked in")
    func everyCheckNamesItsTable() throws {
        let f = try migrated(label: "verify-tables")
        let report = try verify(f)
        // The acceptance criterion's second clause: "and name the table". A
        // failure that says only "verification failed" sends somebody through
        // fifty-one tables.
        let named = report.checks.allSatisfy { !$0.table.isEmpty }
        #expect(named)
    }

    // MARK: Deleting one row

    @Test("Deleting an activity fails the verifier and names the table")
    func aDeletedActivityIsCaught() throws {
        let f = try migrated(label: "verify-deleted-activity")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM activity WHERE id = (SELECT id FROM activity LIMIT 1)")
        }
        let report = try verify(f)

        #expect(!report.passed)
        let tables = Set(report.failures.map(\.table))
        #expect(tables.contains("activity"))
        // The count check and the identity check should BOTH notice, and the
        // identity one is the interesting half: it can say which activity.
        let names = Set(report.failures.map(\.name))
        #expect(names.contains("activities"))
        #expect(names.contains("activity identities"))
    }

    @Test("Deleting a weather row is caught, and only that")
    func aDeletedWeatherRowIsCaught() throws {
        let f = try migrated(label: "verify-deleted-weather")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM weather WHERE id = (SELECT id FROM weather LIMIT 1)")
        }
        let report = try verify(f)

        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "weather" })
        // And the activities are untouched, so their checks must still pass.
        // A verifier that reported everything failing whenever anything did
        // would be no more useful than one that reported nothing.
        let activityChecks = report.checks.filter { $0.name == "activities" }
        // Hoisted into a local: `#expect` decomposes into a `rethrows` call,
        // and a bare `allSatisfy` as the whole argument demands a `try`. Fifth
        // time this project has hit it.
        let activitiesStillAgree = activityChecks.allSatisfy(\.passed)
        #expect(activitiesStillAgree)
    }

    @Test("Deleting a split is caught — including one nothing looks at directly")
    func aDeletedSplitIsCaught() throws {
        // THIS TEST FOUND A GAP IN THE VERIFIER, AND KEPT IT.
        //
        // The domain layer compares the splits of ONE activity, chosen as the
        // richest so the check has something to fail on. `LIMIT 1` deleted a
        // split from a DIFFERENT activity, and every layer passed — which is
        // what would have happened on a real migration too. A representative
        // check misses everything it does not represent.
        //
        // So the count layer gained a total, and this test now deletes from
        // the activity the domain check is NOT looking at, deliberately.
        let f = try migrated(label: "verify-deleted-split")
        let sql = "DELETE FROM activity_split WHERE id = ("
            + "SELECT s.id FROM activity_split s "
            + "JOIN activity_detail ad ON ad.id = s.activityDetailID "
            + "JOIN activity_alias al ON al.activityID = ad.activityID "
            + "WHERE al.externalID = '11111111' LIMIT 1)"
        try f.db.queue.write { d in try d.execute(sql: sql) }

        let report = try verify(f)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "activity_split" })
        // The TOTAL is what noticed. The domain check is still looking at
        // 22222222 and still agreeing, which is why both are kept: one says a
        // split went, the other says which values are right.
        let names = Set(report.failures.map(\.name))
        #expect(names.contains("splits"))
        #expect(!names.contains("splits of one activity"))
    }

    @Test("Deleting a trace sample is caught")
    func aDeletedSampleIsCaught() throws {
        // The same gap one table over, closed at the same time. Nothing
        // compares individual samples, so without a total a trace could arrive
        // with half its points and every check would agree.
        let f = try migrated(label: "verify-deleted-sample")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM recording_sample WHERE ordinal = 3")
        }
        let report = try verify(f)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "recording_sample" })
    }

    @Test("Deleting a trace is caught")
    func aDeletedTraceIsCaught() throws {
        let f = try migrated(label: "verify-deleted-trace")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM recording")
        }
        let report = try verify(f)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "recording" })
    }

    // MARK: Rows that are there and wrong

    @Test("A row with the wrong distance is caught, though every count agrees")
    func aChangedFieldIsCaught() throws {
        // The one that counts and id sets both miss. This is why layer three
        // exists.
        let f = try migrated(label: "verify-changed-field")
        try f.db.queue.write { d in
            try d.execute(sql: """
                UPDATE activity SET distanceM = distanceM + 1
                 WHERE id = (SELECT id FROM activity LIMIT 1)
                """)
        }
        let report = try verify(f)

        #expect(!report.passed)
        let names = Set(report.failures.map(\.name))
        #expect(names.contains("activity fields"))
        // A metre of distance moves the volume total too — and that is the
        // check that corresponds to something on screen.
        #expect(names.contains("volume by discipline"))
        // The counts are all still right, which is exactly the point.
        let counts = report.checks.filter { $0.name == "activities" }
        let countsAgree = counts.allSatisfy(\.passed)
        #expect(countsAgree)
    }

    @Test("A renamed activity is caught")
    func aChangedNameIsCaught() throws {
        let f = try migrated(label: "verify-renamed")
        try f.db.queue.write { d in
            try d.execute(sql: "UPDATE activity SET name = 'Something else' WHERE id = (SELECT id FROM activity LIMIT 1)")
        }
        let report = try verify(f)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.name == "activity fields" })
    }

    @Test("A changed temperature is caught")
    func aChangedWeatherReadingIsCaught() throws {
        let f = try migrated(label: "verify-changed-weather")
        try f.db.queue.write { d in
            try d.execute(sql: "UPDATE weather SET tempC = tempC + 5")
        }
        let report = try verify(f)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.name == "one weather reading" })
    }

    @Test("An identity swapped for another is caught by the set, not the count")
    func aSwappedIdentityIsCaught() throws {
        // Two sets of equal size that disagree completely. The count check
        // passes; this is the whole reason the identity check exists.
        let f = try migrated(label: "verify-swapped-id")
        try f.db.queue.write { d in
            try d.execute(sql: """
                UPDATE activity_alias SET externalID = '99999999'
                 WHERE externalID = '11111111'
                """)
        }
        let report = try verify(f)

        #expect(!report.passed)
        let names = Set(report.failures.map(\.name))
        #expect(names.contains("activity identities"))
        let counts = report.checks.filter { $0.name == "activities" }
        let countsAgree = counts.allSatisfy(\.passed)
        #expect(countsAgree, "the count noticed, so the set proves nothing")
    }

    @Test("The verifier does not stop at the first failure")
    func everyCheckRunsRegardless() throws {
        let f = try migrated(label: "verify-many-faults")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM weather")
            try d.execute(sql: "DELETE FROM recording")
            try d.execute(sql: "DELETE FROM activity_split")
        }
        let report = try verify(f)

        #expect(!report.passed)
        // Three separate faults, three separate findings. A verifier that
        // quit on the first would turn one question into three runs.
        #expect(report.failures.count >= 3)
        #expect(report.checks.count >= 10, "checks stopped running after a failure")
    }

    // MARK: Reaching `verified`

    @Test("A passing report moves the run to verified")
    func aPassingReportIsRecorded() throws {
        let f = try migrated(label: "verify-ledger-pass")
        let report = try verify(f)
        // NO FIXED TIMESTAMP. The first version of this test stamped the
        // verification at a fixed 12:00 and the run had started at whatever
        // o'clock it actually was, so patch 255's CHECK refused a run that
        // finished before it began — `finishedUTC >= startedUTC`, working
        // exactly as written, on the test rather than on the app.
        //
        // Worth keeping the note: the schema constraint caught a defect in the
        // thing testing it, which is the argument for putting invariants in
        // the schema rather than in the code that writes to it.
        let recorded = try SemanticVerifier.record(report, for: f.runID, in: f.db)
        #expect(recorded)

        let runRow = try MigrationLedger.latest(f.db)
        let run = try #require(runRow)
        // Nothing in this app has ever been able to reach this state. Patch
        // 255 built it and said so.
        #expect(run.state == .verified)
        #expect(run.note?.contains("agreed") == true)
    }

    @Test("A failing report does NOT move the run to verified")
    func aFailingReportIsNotRecorded() throws {
        // The one line in the verifier that must never be made convenient.
        // D7 acts on this state, and a run marked verified by something that
        // verified nothing is the defect this project has found six times.
        let f = try migrated(label: "verify-ledger-fail")
        try f.db.queue.write { d in try d.execute(sql: "DELETE FROM weather") }

        let report = try verify(f)
        let recorded = try SemanticVerifier.record(report, for: f.runID, in: f.db)
        #expect(!recorded)

        let runRow = try MigrationLedger.latest(f.db)
        let run = try #require(runRow)
        #expect(run.state == .pending, "a failed verification claimed verified")
    }

    // MARK: What the paste may carry

    @Test("The diagnostic names no activity of the athlete's")
    func theDiagnosticIsRedacted() throws {
        let f = try migrated(label: "verify-redacted")
        try f.db.queue.write { d in
            try d.execute(sql: "DELETE FROM activity WHERE id = (SELECT id FROM activity LIMIT 1)")
        }
        let report = try verify(f)
        let text = report.diagnosticLines.joined(separator: "\n")

        // §12.7: the paste carries no identifiers from the athlete's history.
        // The screen shows `detail`; this shows counts and table names.
        #expect(!text.contains("11111111"))
        #expect(!text.contains("22222222"))
        #expect(!text.contains("33333333"))
        // And still says enough to act on.
        #expect(text.contains("activity"))
        #expect(text.contains("DISAGREED"))
    }

    @Test("A passing run says so in one line")
    func theLedgerNoteIsCounts() throws {
        let f = try migrated(label: "verify-note")
        let report = try verify(f)
        #expect(report.ledgerNote.contains("all agreed"))
        #expect(!report.ledgerNote.contains("11111111"))
    }

    // MARK: The empty case

    @Test("An empty migration of empty stores verifies")
    func nothingVerifiesAgainstNothing() throws {
        // A fresh install with no Strava connection yet. Zero equals zero is a
        // pass, and a verifier that treated an empty database as suspicious
        // would fail on the one phone that has nothing wrong with it.
        let db = try Sub4Database.inMemory(label: "verify-empty")
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], appVersion: "263")
        let report = try SemanticVerifier.verify(db, activities: [])
        #expect(report.passed)
        #expect(!report.checks.isEmpty)
    }
}
