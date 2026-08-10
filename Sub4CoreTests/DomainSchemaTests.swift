//
//  DomainSchemaTests.swift
//  Sub4CoreTests
//
//  The remaining eight table groups, asserted — patch 202, plan step 3.2.2.
//
//  WHAT IS WORTH READING HERE
//  --------------------------
//  Most of these tables will not be written to until 3.3. That makes it exactly
//  the moment to pin the rules, because a schema with no importer yet is a
//  schema nobody has bent to fit a bug.
//
//  Three groups of assertion:
//
//  1. DRIFT — the frozen vocabularies against the Swift enums they came from.
//     A case added to `Intensity` or `Feel` fails here, and the fix is a new
//     migration rather than an edit to a shipped one.
//
//  2. SURVIVAL — the delete rules that decide what a person keeps. A note
//     survives its activity. Gear survives its source. A rejection outlives the
//     recording it describes. These are the ones ADR-0002 turns into promises.
//
//  3. REFUSAL — what the constraints reject. A resting rate of zero, a review
//     window that ends before it starts, two active plan versions.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

// MARK: - Fixtures for the domain tables

nonisolated enum DomainFixture {

    static func account(_ db: Database, id: String = Fixture.account) throws {
        try Fixture.insertAccount(db, id: id)
    }

    static func plan(_ db: Database, id: String = "PLAN-1") throws {
        try db.execute(sql: """
            INSERT INTO plan (id, name, week1Monday, raceDate, targetTime,
                              targetPaceSecKm, createdUTC)
            VALUES (?, 'Operation Sub-4', '2026-07-27', '2027-03-21',
                    '04:00:00', 341, '2026-08-04T00:00:00Z')
            """, arguments: [id])
    }

    static func planVersion(_ db: Database, id: String = "PV-1",
                            planID: String = "PLAN-1",
                            hash: String = "abc123",
                            activated: String? = "2026-08-04T00:00:00Z") throws {
        let args: StatementArguments = [id, planID, hash, activated]
        try db.execute(sql: """
            INSERT INTO plan_version (id, planID, contentHash, sourceLabel,
                                      importedUTC, activatedUTC)
            VALUES (?, ?, ?, 'bundled plan.json', '2026-08-04T00:00:00Z', ?)
            """, arguments: args)
    }

    static func planWeek(_ db: Database, id: String = "PW-1",
                         versionID: String = "PV-1",
                         uid: String = "wk-02",
                         weekNo: Int? = 2) throws {
        let args: StatementArguments = [id, versionID, uid, weekNo]
        try db.execute(sql: """
            INSERT INTO plan_week (id, planVersionID, uid, weekNo, label,
                                   startDate, logged)
            VALUES (?, ?, ?, ?, '02', '2026-08-03', 0)
            """, arguments: args)
    }

    static func planSession(_ db: Database, id: String = "PS-1",
                            versionID: String = "PV-1",
                            weekID: String = "PW-1",
                            uid: String = "wk-02-tue-run",
                            discipline: String = "run",
                            intensity: String? = "easy") throws {
        let args: StatementArguments = [id, versionID, weekID, uid, discipline, intensity]
        try db.execute(sql: """
            INSERT INTO plan_session (id, planVersionID, planWeekID, uid,
                                      discipline, intensity, seq)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """, arguments: args)
    }

    static func note(_ db: Database, id: String = "N-1",
                     sessionUID: String = "wk-02-tue-run",
                     activityID: String? = "ACT-1",
                     rpe: Int? = 6, feel: String? = "expected") throws {
        let args: StatementArguments = [id, Fixture.account, sessionUID, activityID, rpe, feel]
        try db.execute(sql: """
            INSERT INTO user_note (id, accountID, planSessionUID, activityID,
                                   rpe, feel, text, createdUTC, editedUTC)
            VALUES (?, ?, ?, ?, ?, ?, 'Legs felt heavy for the first 3 km.',
                    '2026-08-04T18:00:00Z', '2026-08-04T18:00:00Z')
            """, arguments: args)
    }
}

// MARK: - The vocabularies have not drifted

@Suite
struct DomainVocabularyTests {

    let db: Sub4Database

    init() throws { db = try Sub4Database.inMemory(label: "domain-vocab") }

    /// Same rule as `initialDisciplines`: the migration holds a frozen list
    /// because a migration body is history, and this is what couples it to the
    /// type. When it fails, write a migration — do not edit `2026-08-04-domain`.
    @Test("The intensity constraint lists exactly the intensities the plan has")
    func intensitiesMatch() {
        #expect(Set(Sub4Migrations.domainIntensities)
                == Set(Intensity.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.domainIntensities)")
    }

    @Test("The feel constraint lists exactly the feelings a note can carry")
    func feelsMatch() {
        #expect(Set(Sub4Migrations.domainFeels)
                == Set(NotesStore.Note.Feel.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.domainFeels)")
    }

    @Test("The state vocabulary lists exactly the states an import can be in")
    func migrationRunStatesMatch() {
        // Patch 255 froze five literals here and said adding a sixth should be
        // a red build and a new migration rather than an edit to history.
        // PATCH 338 IS THAT SIXTH, and it worked exactly as designed: this
        // assertion failed, `2026-08-15-interrupted-run` was written, and the
        // list this reads moved to the newest migration's.
        //
        // `Sub4Migrations.migrationRunStates` IS DELIBERATELY NOT UPDATED. It
        // is what the 11 August body wrote and it is history — the assertion
        // below is what the CURRENT schema admits, and the line after it is
        // what makes the old list still mean something.
        #expect(Set(Sub4Migrations.migrationRunStatesWithInterrupted)
                == Set(MigrationRunState.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.migrationRunStatesWithInterrupted)")
        #expect(Set(Sub4Migrations.migrationRunStates)
                    .isSubset(of: Set(Sub4Migrations.migrationRunStatesWithInterrupted)),
                "a rebuild may add states, never drop one a device has stored")
    }

    @Test("The trigger vocabulary lists exactly the ways a run can start")
    func migrationRunTriggersMatch() {
        // Patch 311, and the same rule as the five states above it. The
        // migration body freezes four literals in a CHECK; this is what makes
        // adding a fifth a red build and a new migration rather than an edit to
        // history.
        //
        // It is also what `MigrationLedger.row` depends on: an unknown string
        // in that column would read back as nil and print as "not recorded",
        // which is only safe because the CHECK makes it impossible to store.
        #expect(Set(Sub4Migrations.migrationRunTriggers)
                == Set(MigrationRunTrigger.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.migrationRunTriggers)")
    }

    @Test("The weather provider constraint lists exactly the providers in use")
    func weatherProvidersMatch() {
        #expect(Set(Sub4Migrations.domainWeatherProviders)
                == Set(WeatherSource.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.domainWeatherProviders)")
    }

    /// Every intensity the type permits must actually store.
    @Test("Every plan intensity can be stored", arguments: Intensity.allCases)
    func everyIntensityIsAccepted(_ i: Intensity) throws {
        let intensity = i.rawValue
        try db.queue.write { conn in
            try DomainFixture.account(conn)
            try DomainFixture.plan(conn)
            try DomainFixture.planVersion(conn)
            try DomainFixture.planWeek(conn)
            try DomainFixture.planSession(conn, id: "PS-\(intensity)",
                                          uid: "u-\(intensity)", intensity: intensity)
        }
    }

    @Test("An intensity the plan does not have is rejected")
    func unknownIntensityIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try DomainFixture.account(conn)
                try DomainFixture.plan(conn)
                try DomainFixture.planVersion(conn)
                try DomainFixture.planWeek(conn)
                try DomainFixture.planSession(conn, intensity: "sprint")
            }
        }
    }

    /// Every table §8 names exists, spelled the way §8 spells it. The cheap
    /// check that catches a group quietly left out.
    @Test("Every table ADR-0003 §8 names exists")
    func everyGroupIsPresent() throws {
        let expected = [
            "account", "source",
            "plan", "plan_version", "plan_week", "plan_session", "plan_exercise",
            "activity", "activity_source_record", "activity_alias",
            "recording", "recording_sample",
            "user_note", "proposal", "match_decision", "correction", "rejection",
            "athlete_profile", "hr_zone", "gear", "resting_month",
            "review", "review_evidence",
            "weather",
            "sync_state", "work_queue", "content_revision",
            "lifecycle_event"
        ]
        let present = try db.queue.read { conn in
            try String.fetchSet(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in expected {
            #expect(present.contains(table), "\(table) is named in §8 and does not exist")
        }
    }
}

// MARK: - What survives what

@Suite
struct DomainSurvivalTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "domain-survival")
        try db.queue.write { conn in
            try DomainFixture.account(conn)
            try Fixture.insertActivity(conn)
            try DomainFixture.plan(conn)
            try DomainFixture.planVersion(conn)
            try DomainFixture.planWeek(conn)
            try DomainFixture.planSession(conn)
        }
    }

    /// THE ONE THAT MATTERS MOST IN THIS PATCH.
    ///
    /// A note is written against a plan session uid, and plan versions are
    /// replaced wholesale by an app update. A foreign key from `user_note` to
    /// `plan_session` would delete thirteen months of writing the first time an
    /// update renumbered a week.
    @Test("A note survives the plan version it was written against")
    func noteSurvivesThePlanVersion() throws {
        try db.queue.write { conn in
            try DomainFixture.note(conn)
            // An app update replacing the seed.
            try conn.execute(sql: "DELETE FROM plan_version WHERE id = 'PV-1'")
        }
        let text = try db.queue.read {
            try String.fetchOne($0, sql: "SELECT text FROM user_note WHERE id = 'N-1'")
        }
        #expect(text != nil, "a session note went with the plan version")
        // And the session it was about is still identifiable.
        let uid = try db.queue.read {
            try String.fetchOne($0, sql: "SELECT planSessionUID FROM user_note WHERE id = 'N-1'")
        }
        #expect(uid == "wk-02-tue-run")
    }

    /// Deleting an activity must not delete what you wrote about it. SET NULL,
    /// not cascade — the note is about a session you did, and it stays true
    /// when the recording of it is removed.
    @Test("A note survives its activity, keeping everything but the link")
    func noteSurvivesItsActivity() throws {
        try db.queue.write { conn in
            try DomainFixture.note(conn)
            try conn.execute(sql: "DELETE FROM activity WHERE id = 'ACT-1'")
        }
        let row = try db.queue.read {
            try Row.fetchOne($0, sql: "SELECT text, activityID FROM user_note WHERE id = 'N-1'")
        }
        let found = try #require(row)
        let activityID: String? = found["activityID"]
        let text: String? = found["text"]
        #expect(activityID == nil, "the link survived the activity it pointed at")
        #expect(text?.isEmpty == false, "the note was cascaded away with the activity")
    }

    /// A correction the athlete made outlives the recording it corrected, for
    /// the same reason and by the same rule.
    @Test("A match decision survives the activity it pointed at")
    func matchDecisionSurvivesItsActivity() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO match_decision (id, accountID, planSessionUID, activityID, decidedUTC)
                VALUES ('MD-1', ?, 'wk-02-tue-run', 'ACT-1', '2026-08-04T18:00:00Z')
                """, arguments: [Fixture.account])
            try conn.execute(sql: "DELETE FROM activity WHERE id = 'ACT-1'")
        }
        let n = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM match_decision")
        }
        #expect(n == 1, "a correction was deleted with the thing it corrected")
    }

    /// Recordings are not authored, and they do go. A trace whose activity is
    /// gone describes nothing.
    @Test("A recording and its samples go with the activity")
    func recordingCascades() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO recording (id, activityID, fetchedUTC, sampleCount, sourceID)
                VALUES ('R-1', 'ACT-1', '2026-08-04T18:00:00Z', 2, 'strava')
                """)
            try conn.execute(sql: """
                INSERT INTO recording_sample (recordingID, ordinal, distanceM, heartRate)
                VALUES ('R-1', 0, 0, 120), ('R-1', 1, 250.0, 141)
                """)
            try conn.execute(sql: "DELETE FROM activity WHERE id = 'ACT-1'")
        }
        let samples = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_sample")
        }
        #expect(samples == 0, "samples outlived the activity they describe")
        let report = try db.integrityReport()
        #expect(report.foreignKeyViolations == 0, "\(report.summary)")
    }

    /// A rejection is what stops the same refused recording being offered and
    /// refused on every sync, so it has to outlast the sync that made it.
    @Test("A rejection is keyed by source and external id, not by activity")
    func rejectionStandsAlone() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO rejection (id, accountID, sourceID, externalID, rule, noticedUTC,
                                       name, dayKey, distanceM, elapsedSeconds)
                VALUES ('REJ-1', ?, 'strava', '19580875358', 'selfContradictoryDistance',
                        '2026-08-04T18:00:00Z', 'Afternoon Ride', '2025-08-24', 199000, 694865)
                """, arguments: [Fixture.account])
            try conn.execute(sql: "DELETE FROM activity WHERE id = 'ACT-1'")
        }
        let n = try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rejection") }
        #expect(n == 1)
    }
}

// MARK: - What the constraints refuse

@Suite
struct DomainConstraintTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "domain-constraints")
        try db.queue.write { conn in
            try DomainFixture.account(conn)
            try Fixture.insertActivity(conn)
            try DomainFixture.plan(conn)
        }
    }

    /// Two plan versions cannot both be active. Expressed as a partial unique
    /// index because "exactly one" is otherwise a rule in somebody's head.
    @Test("Only one plan version can be active at a time")
    func onlyOneActiveVersion() throws {
        try db.queue.write { try DomainFixture.planVersion($0, id: "PV-1", hash: "a") }
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try DomainFixture.planVersion($0, id: "PV-2", hash: "b") }
        }
        // But any number of inactive ones.
        try db.queue.write {
            try DomainFixture.planVersion($0, id: "PV-3", hash: "c", activated: nil)
        }
        try db.queue.write {
            try DomainFixture.planVersion($0, id: "PV-4", hash: "d", activated: nil)
        }
    }

    /// The seed is identified by its content, so the same content cannot be
    /// imported twice as two versions.
    @Test("The same plan content cannot be imported twice")
    func contentHashIsUnique() throws {
        try db.queue.write { try DomainFixture.planVersion($0, id: "PV-1", hash: "same") }
        #expect(throws: DatabaseError.self) {
            try db.queue.write {
                try DomainFixture.planVersion($0, id: "PV-2", hash: "same", activated: nil)
            }
        }
    }

    /// §6 at the threshold layer. A resting heart rate of zero is not a
    /// measurement, and it is the denominator of every TRIMP the app computes.
    @Test("A resting heart rate of zero is rejected")
    func zeroRestingIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO resting_month (id, accountID, month, bpm, computedUTC)
                    VALUES ('RM-1', ?, '2026-08', 0, '2026-08-04T00:00:00Z')
                    """, arguments: [Fixture.account])
            }
        }
    }

    /// A heart-rate zone that ends below where it starts is not a zone.
    @Test("A heart-rate zone cannot end below its start")
    func invertedZoneIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO hr_zone (id, accountID, ordinal, minBpm, maxBpm)
                    VALUES ('Z-1', ?, 0, 160, 120)
                    """, arguments: [Fixture.account])
            }
        }
    }

    /// A review window that ends before it starts would silently produce an
    /// empty evidence set and a verdict about nothing.
    @Test("A review window cannot end before it starts")
    func invertedReviewWindowIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO review (id, accountID, ranUTC, windowStartDayKey,
                                        windowEndDayKey, provider)
                    VALUES ('RV-1', ?, '2026-08-04T00:00:00Z', '2026-08-31',
                            '2026-08-01', 'anthropic')
                    """, arguments: [Fixture.account])
            }
        }
    }

    /// Humidity is a fraction, not a percentage. The unit error that looks
    /// plausible either way until a number is 87 instead of 0.87.
    @Test("Humidity outside 0…1 is rejected")
    func humidityIsAFraction() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO weather (id, activityID, provider, tempC, feelsLikeC,
                                         humidity, windKmh, windFromDegrees,
                                         precipitationMm, symbolName, conditionLabel,
                                         samples, fetchedUTC)
                    VALUES ('W-1', 'ACT-1', 'openMeteo', 18, 17, 87, 12, 220, 0,
                            'cloud', 'Cloudy', 2, '2026-08-04T18:00:00Z')
                    """)
            }
        }
    }

    /// A weather reading reduced from no samples is not a reading. This is what
    /// `WeatherStore.reduce` returning nil looks like as a constraint.
    @Test("A weather reading built from no samples is rejected")
    func zeroSampleWeatherIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO weather (id, activityID, provider, tempC, feelsLikeC,
                                         humidity, windKmh, windFromDegrees,
                                         precipitationMm, symbolName, conditionLabel,
                                         samples, fetchedUTC)
                    VALUES ('W-1', 'ACT-1', 'openMeteo', 18, 17, 0.6, 12, 220, 0,
                            'cloud', 'Cloudy', 0, '2026-08-04T18:00:00Z')
                    """)
            }
        }
    }

    /// One reading per activity. Two would mean the card has to choose, and
    /// choosing silently is how a provider fallback becomes a lottery.
    @Test("An activity cannot hold two weather readings")
    func oneWeatherPerActivity() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO weather (id, activityID, provider, tempC, feelsLikeC,
                                     humidity, windKmh, windFromDegrees,
                                     precipitationMm, symbolName, conditionLabel,
                                     samples, fetchedUTC)
                VALUES ('W-1', 'ACT-1', 'openMeteo', 18, 17, 0.6, 12, 220, 0,
                        'cloud', 'Cloudy', 2, '2026-08-04T18:00:00Z')
                """)
        }
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO weather (id, activityID, provider, tempC, feelsLikeC,
                                         humidity, windKmh, windFromDegrees,
                                         precipitationMm, symbolName, conditionLabel,
                                         samples, fetchedUTC)
                    VALUES ('W-2', 'ACT-1', 'appleWeather', 19, 18, 0.6, 12, 220, 0,
                            'sun', 'Clear', 2, '2026-08-04T18:00:00Z')
                    """)
            }
        }
    }

    /// The weather cache's Strava-lineage gap, closed by construction: there is
    /// no column here that could hold a source's identifier.
    @Test("The weather table has no column holding an external identifier")
    func weatherIsKeyedCanonically() throws {
        let columns: [String] = try db.queue.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(weather)")
                .compactMap { row -> String? in row["name"] }
        }
        for c in columns {
            #expect(!c.localizedCaseInsensitiveContains("external"), "\(c)")
            #expect(!c.localizedCaseInsensitiveContains("strava"), "\(c)")
        }
    }

    /// A work item in a state the queue does not run is a work item nothing
    /// will ever pick up.
    @Test("A work item cannot be in an unknown state")
    func unknownWorkStateIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO work_queue (id, kind, state, createdUTC, updatedUTC)
                    VALUES ('WQ-1', 'fetchDetail', 'maybe',
                            '2026-08-04T00:00:00Z', '2026-08-04T00:00:00Z')
                    """)
            }
        }
    }

    /// §8 group 10 says deletion receipts. They cannot live here — the database
    /// is inside the folder a delete removes — so the constraint says what the
    /// table actually holds rather than leaving the discrepancy to be found.
    @Test("A lifecycle event cannot claim to be a deletion receipt")
    func deletionReceiptsAreNotStored() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try conn.execute(sql: """
                    INSERT INTO lifecycle_event (id, operation, startedUTC, summary)
                    VALUES ('LE-1', 'delete', '2026-08-04T00:00:00Z', '16 removed')
                    """)
            }
        }
        // Exports and disconnects do go in.
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO lifecycle_event (id, operation, startedUTC, summary)
                VALUES ('LE-2', 'export', '2026-08-04T00:00:00Z', '9 files')
                """)
        }
    }
}

// MARK: - Lineage is queryable, because a purge is a query

@Suite
struct ReviewLineageTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "domain-lineage")
        try db.queue.write { conn in
            try DomainFixture.account(conn)
            try conn.execute(sql: """
                INSERT INTO review (id, accountID, ranUTC, windowStartDayKey,
                                    windowEndDayKey, provider)
                VALUES ('RV-1', ?, '2026-08-04T00:00:00Z', '2026-07-01',
                        '2026-07-31', 'anthropic')
                """, arguments: [Fixture.account])
            for (id, key, sent) in [("EV-1", "volume", true), ("EV-2", "notes", true)] {
                try conn.execute(sql: """
                    INSERT INTO review_evidence (id, reviewID, sectionKey, title, body, wasSent)
                    VALUES (?, 'RV-1', ?, 'Section', 'body text', ?)
                    """, arguments: [id, key, sent])
            }
            try conn.execute(sql: """
                INSERT INTO review_evidence_source (evidenceID, sourceID)
                VALUES ('EV-1', 'strava'), ('EV-2', 'authored')
                """)
        }
    }

    /// ADR-0002's purge, as the query it will actually be: find the evidence
    /// with Strava lineage, remove it, leave the verdict standing. This is why
    /// lineage is a join table rather than a comma-separated column — a
    /// deletion obligation whose correctness depends on substring matching is
    /// not an obligation anyone should sign.
    @Test("Strava-derived evidence can be found and purged, leaving the review")
    func stravaEvidenceIsPurgeable() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                DELETE FROM review_evidence
                WHERE id IN (SELECT evidenceID FROM review_evidence_source
                             WHERE sourceID = 'strava')
                """)
        }
        let remaining = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT sectionKey FROM review_evidence ORDER BY sectionKey")
        }
        #expect(remaining == ["notes"], "got \(remaining)")

        let reviews = try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review") }
        #expect(reviews == 1, "the review itself was purged with its evidence")

        // And no orphaned lineage rows behind it.
        let orphans = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_evidence_source")
        }
        #expect(orphans == 1, "lineage rows outlived the evidence they described")
    }

    /// A section that was built and withheld is part of the audit trail. An
    /// export that only recorded what was sent could not answer "what did you
    /// decide not to tell it".
    @Test("Evidence records whether it was actually sent")
    func withheldEvidenceIsRecorded() throws {
        try db.queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO review_evidence (id, reviewID, sectionKey, title, body, wasSent)
                VALUES ('EV-3', 'RV-1', 'routes', 'Routes', 'withheld', 0)
                """)
        }
        let withheld = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT sectionKey FROM review_evidence WHERE wasSent = 0")
        }
        #expect(withheld == ["routes"])
    }
}
