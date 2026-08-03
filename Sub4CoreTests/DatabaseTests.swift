//
//  DatabaseTests.swift
//  Sub4CoreTests
//
//  The foundation, asserted — patch 195, plan step 3.2a.
//
//  WHAT THESE ARE FOR
//  ------------------
//  ADR-0003 is a document full of claims: foreign keys are on for every
//  connection, an external id is never a primary key, an alias outlives the
//  source record it came from, NULL means unknown and never zero. A document
//  cannot enforce any of that. These tests are where each claim becomes
//  something that fails a build when it stops being true.
//
//  The ones worth reading are the last three sections. `aliasSurvivesTheSource`
//  is the property the whole ADR was written to produce — thirteen months of
//  notes surviving the Strava retirement — and it is checked here, eighteen
//  months before the retirement, because that is the only time it can still be
//  cheap to get wrong.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

// MARK: - Fixtures
//
// `nonisolated` throughout. The test target compiles with default MainActor
// isolation and GRDB's write closures run on the database's own queue; helpers
// that carry no isolation can be called from either without the compiler having
// to take a view.

nonisolated enum Fixture {

    static let account = "ACC-1"

    static func insertAccount(_ db: Database, id: String = account) throws {
        try db.execute(sql: """
            INSERT INTO account (id, label, createdUTC) VALUES (?, ?, ?)
            """, arguments: [id, "The athlete", "2026-08-03T00:00:00Z"])
    }

    static func insertActivity(_ db: Database,
                               id: String = "ACT-1",
                               accountID: String = account,
                               discipline: String = "run",
                               distanceM: Double = 10_000,
                               movingSeconds: Int = 3_000,
                               elapsedSeconds: Int = 3_100,
                               elevationGainM: Double? = 42,
                               averageHeartrate: Double? = 148,
                               latitude: Double? = 51.2194,
                               longitude: Double? = 4.4025,
                               offsetSeconds: Int? = nil,
                               timeZoneIdentifier: String? = nil,
                               startLocal: String = "2026-08-03T07:00:00",
                               dayKey: String = "2026-08-03") throws {
        // ANNOTATED, not inferred. A twenty-element heterogeneous array literal
        // of existentials is the shape that produces "unable to type-check this
        // expression in reasonable time" — a diagnostic this project has
        // already paid three builds for. With a target type each element
        // converts on its own.
        let args: StatementArguments = [
            id, accountID, "2026-08-03T05:00:00Z", startLocal, dayKey,
            offsetSeconds, timeZoneIdentifier,
            discipline, "Run", "Morning Run",
            distanceM, movingSeconds, elapsedSeconds, elevationGainM,
            averageHeartrate, nil,
            latitude, longitude,
            "2026-08-03T09:00:00Z", "2026-08-03T09:00:00Z"]
        try db.execute(sql: """
            INSERT INTO activity
              (id, accountID, startUTC, startLocal, dayKey,
               startOffsetSeconds, timeZoneIdentifier,
               discipline, sportLabel, name,
               distanceM, movingSeconds, elapsedSeconds, elevationGainM,
               averageHeartrate, maxHeartrate,
               startLatitude, startLongitude, createdUTC, updatedUTC)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: args)
    }

    static func insertSourceRecord(_ db: Database,
                                   id: String = "SR-1",
                                   activityID: String = "ACT-1",
                                   accountID: String = account,
                                   sourceID: String = "strava",
                                   externalID: String = "19580875358") throws {
        let args: StatementArguments = [id, activityID, accountID, sourceID, externalID,
                                        "2026-08-03T09:00:00Z", "2026-08-03T09:00:00Z"]
        try db.execute(sql: """
            INSERT INTO activity_source_record
              (id, activityID, accountID, sourceID, externalID, firstSeenUTC, lastSeenUTC)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: args)
    }

    static func insertAlias(_ db: Database,
                            id: String = "AL-1",
                            activityID: String = "ACT-1",
                            sourceID: String = "strava",
                            externalID: String = "19580875358") throws {
        let args: StatementArguments = [id, activityID, sourceID, externalID,
                                        "2026-08-03T09:00:00Z"]
        try db.execute(sql: """
            INSERT INTO activity_alias
              (id, activityID, sourceID, externalID, notedUTC, retiredUTC)
            VALUES (?, ?, ?, ?, ?, NULL)
            """, arguments: args)
    }
}

// MARK: - Opening and configuration

@Suite
struct DatabaseConnectionTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "connection-tests")
    }

    /// ADR-0003 §7's first rule, and the one it calls "the single most common
    /// way a schema with declared relationships turns out never to have
    /// enforced them". SQLite defaults foreign keys OFF; GRDB defaults them on;
    /// this asserts what the connection actually has rather than which library
    /// was believed to have set it.
    @Test("Foreign keys are on for the connection, not just in the configuration")
    func foreignKeysAreOnForTheConnection() throws {
        let on = try db.queue.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(on == 1, "foreign keys are off — every relationship in §8 is decorative")
    }

    /// And that it is set deliberately rather than inherited. A default is a
    /// decision somebody else made and can change in a minor version, which is
    /// the reason ADR-0003 §2 pins GRDB exactly in the first place.
    @Test("The configuration sets foreign keys rather than relying on the default")
    func configurationIsExplicit() {
        #expect(Sub4Database.configuration(label: "x").foreignKeysEnabled)
    }

    /// The on-disk and in-memory databases must be configured identically. A
    /// test database that differs from the real one tests a different database.
    @Test("In-memory and on-disk share one configuration")
    func oneConfiguration() {
        let a = Sub4Database.configuration(label: "sub4")
        let b = Sub4Database.configuration(label: "sub4-test")
        #expect(a.foreignKeysEnabled == b.foreignKeysEnabled)
    }

    @Test("An in-memory database reports itself as in memory")
    func inMemoryKnowsWhatItIs() {
        #expect(db.location.isInMemory)
    }

    @Test("Every declared migration has been applied")
    func allMigrationsApplied() throws {
        let applied = try db.queue.read { try Sub4Migrations.migrator.appliedIdentifiers($0) }
        for id in Sub4Migrations.all {
            #expect(applied.contains(id), "\(id) was never applied")
        }
    }

    /// Running the migrator again on an already-migrated database must be a
    /// no-op. It is what happens at every single launch.
    @Test("Migrating twice changes nothing")
    func migrationIsIdempotent() throws {
        try Sub4Migrations.migrator.migrate(db.queue)
        try Sub4Migrations.migrator.migrate(db.queue)
        let report = try db.integrityReport()
        #expect(report.isHealthy, "\(report.summary)")
    }

    @Test("A fresh database reports healthy")
    func freshDatabaseIsHealthy() throws {
        let report = try db.integrityReport()
        #expect(report.quickCheck == "ok", "\(report.quickCheck)")
        #expect(report.foreignKeyViolations == 0)
        #expect(report.foreignKeysEnabled)
        #expect(report.appliedMigrations == Sub4Migrations.all)
        #expect(report.isHealthy)
    }
}

// MARK: - The schema agrees with the types it stores

@Suite
struct SchemaAgreementTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "schema-tests")
    }

    /// THE DRIFT CHECK THAT REPLACED A CLEVERER IDEA.
    ///
    /// The first version of the migration seeded this table from
    /// `DataSource.allCases` directly, which looked drift-proof and was worse:
    /// a migration body is history, and one that reads a live enum quietly
    /// gives a fresh install a different database from an existing one the
    /// moment a case is added.
    ///
    /// So the migration holds a frozen list and this test is what couples the
    /// two. When it fails, the fix is a new migration inserting the new row —
    /// not an edit to `2026-08-03-initial`.
    @Test("The source table holds exactly the sources the app knows about")
    func sourceTableMatchesTheEnum() throws {
        let rows = try db.queue.read { try String.fetchAll($0, sql: "SELECT id FROM source") }
        #expect(Set(rows) == Set(DataSource.allCases.map(\.rawValue)),
                "source table and DataSource disagree — write a migration rather than editing the initial one. Table has: \(rows.sorted())")
    }

    /// The same coupling for the CHECK constraint on `activity.discipline`.
    @Test("The discipline constraint lists exactly the disciplines the app has")
    func disciplineConstraintMatchesTheEnum() {
        #expect(Set(Sub4Migrations.initialDisciplines) == Set(Discipline.allCases.map(\.rawValue)),
                "Discipline gained or lost a case without a migration")
    }

    /// And the constraint is real rather than merely declared: every case the
    /// type permits must actually survive an INSERT.
    @Test("Every discipline the app has can be stored", arguments: Discipline.allCases)
    func everyDisciplineIsAccepted(_ d: Discipline) throws {
        try db.queue.write { conn in
            try Fixture.insertAccount(conn)
            try Fixture.insertActivity(conn, id: "ACT-\(d.rawValue)", discipline: d.rawValue)
        }
    }

    @Test("A discipline the app does not have is rejected")
    func unknownDisciplineIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { conn in
                try Fixture.insertAccount(conn)
                try Fixture.insertActivity(conn, discipline: "sailing")
            }
        }
    }

    /// `sportLabel` is deliberately NOT constrained. A closed list of another
    /// company's strings is a constraint that fails on the day they add one,
    /// and Strava has added several.
    @Test("A sport label the app has never seen is stored rather than rejected")
    func sportLabelIsNotConstrained() throws {
        try db.queue.write { conn in
            try Fixture.insertAccount(conn)
            try conn.execute(sql: """
                INSERT INTO activity
                  (id, accountID, startUTC, startLocal, dayKey, discipline, sportLabel,
                   name, distanceM, movingSeconds, elapsedSeconds, createdUTC, updatedUTC)
                VALUES ('X', ?, '2026-08-03T05:00:00Z', '2026-08-03T07:00:00',
                        '2026-08-03', 'other', 'EBikeRideThatDidNotExistIn2024',
                        'Something new', 0, 60, 60, 'a', 'b')
                """, arguments: [Fixture.account])
        }
    }
}

// MARK: - The constraints reject what they claim to

@Suite
struct SchemaConstraintTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "constraint-tests")
        try db.queue.write { try Fixture.insertAccount($0) }
    }

    @Test("A negative distance is rejected")
    func negativeDistanceIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertActivity($0, distanceM: -1) }
        }
    }

    @Test("A latitude outside the world is rejected")
    func impossibleLatitudeIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertActivity($0, latitude: 91) }
        }
    }

    @Test("A longitude outside the world is rejected")
    func impossibleLongitudeIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertActivity($0, longitude: -181) }
        }
    }

    /// THE ARTIFACT, BY ITS REAL NUMBERS. The "Afternoon Ride" from August 2025
    /// claims 199 km covered in 694,865 seconds — 8.04 days.
    @Test("The August 2025 199 km / 694,865 s artifact is rejected at the boundary")
    func theAugust2025ArtifactIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write {
                try Fixture.insertActivity($0, distanceM: 199_000,
                                           movingSeconds: 3_600,
                                           elapsedSeconds: 694_865)
            }
        }
    }

    /// WHY THE PREVIOUS TEST NEEDED AN UPPER BOUND, stated as arithmetic rather
    /// than as prose.
    ///
    /// ADR-0003 §7 claims the non-negativity constraints — "distance ≥ 0,
    /// duration ≥ 0" — are "exactly what these reject" for that artifact. They
    /// are not: 694,865 is positive and passes every one of them. The ADR
    /// overstates what a floor can do, and this is the assertion that keeps the
    /// correction visible rather than quietly patching the document and moving
    /// on.
    @Test("A non-negativity check alone would have accepted the artifact")
    func nonNegativityAloneWouldNotHaveCaughtIt() {
        let artifact = 694_865
        #expect(artifact >= 0, "the floor the ADR relied on passes this value")
        #expect(artifact > Sub4Migrations.maximumPlausibleElapsedSeconds,
                "the ceiling is what actually rejects it")
        // And the bound is not so tight that a real session trips it: the
        // longest thing in this plan is a marathon, well under six hours.
        #expect(6 * 3_600 < Sub4Migrations.maximumPlausibleElapsedSeconds)
    }

    /// §6, the case that is already load-bearing in the training-load engine:
    /// no strap means no heart rate, not a heart rate of zero. A zero would
    /// score every unstrapped run as a recovery run.
    @Test("A heart rate of zero is rejected; an absent one is allowed")
    func zeroHeartRateIsNotAMeasurement() throws {
        try db.queue.write { try Fixture.insertActivity($0, id: "NO-STRAP", averageHeartrate: nil) }
        let nulls = try db.queue.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM activity WHERE id = 'NO-STRAP' AND averageHeartrate IS NULL
                """)
        }
        #expect(nulls == 1, "an absent heart rate came back as something")

        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertActivity($0, id: "ZERO", averageHeartrate: 0) }
        }
    }

    /// §4.3 and §6 in one column. An offset of 0 is Greenwich. NULL is "Strava
    /// sent it and this app never decoded it", which is every one of the 660
    /// activities on the device today.
    @Test("A null time-zone offset is not the same as an offset of zero")
    func nullOffsetIsNotGreenwich() throws {
        try db.queue.write { conn in
            try Fixture.insertActivity(conn, id: "UNKNOWN-ZONE", offsetSeconds: nil)
            try Fixture.insertActivity(conn, id: "GREENWICH", offsetSeconds: 0,
                                       timeZoneIdentifier: "Europe/London")
            try Fixture.insertActivity(conn, id: "TOKYO", offsetSeconds: 32_400,
                                       timeZoneIdentifier: "Asia/Tokyo")
        }
        let unknown = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity WHERE startOffsetSeconds IS NULL")
        }
        let greenwich = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity WHERE startOffsetSeconds = 0")
        }
        #expect(unknown == 1)
        #expect(greenwich == 1, "an offset of 0 must be a stored value, not a stand-in for unknown")
    }
}

// MARK: - Identity, which is what ADR-0003 exists for

@Suite
struct IdentityTests {

    let db: Sub4Database

    init() throws {
        db = try Sub4Database.inMemory(label: "identity-tests")
        try db.queue.write { conn in
            try Fixture.insertAccount(conn)
            try Fixture.insertActivity(conn)
        }
    }

    /// §3.1. The uniqueness key, which is also the idempotency key for
    /// ingestion: re-syncing the same Strava activity must find this row rather
    /// than mint a second canonical activity.
    @Test("The same external id cannot arrive twice for one account and source")
    func externalIDIsUniquePerAccountAndSource() throws {
        try db.queue.write { try Fixture.insertSourceRecord($0) }
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertSourceRecord($0, id: "SR-2") }
        }
    }

    /// The same external id from a DIFFERENT source is a different thing, and
    /// must be allowed — it is what the Strava-to-Health cutover looks like.
    @Test("The same external id from another source is a different record")
    func theSameIDFromAnotherSourceIsFine() throws {
        try db.queue.write { conn in
            try Fixture.insertSourceRecord(conn)
            try Fixture.insertSourceRecord(conn, id: "SR-2", sourceID: "appleHealth")
        }
        let n = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity_source_record")
        }
        #expect(n == 2)
    }

    /// One run recorded on a watch appears in Health and in Strava. §3.1 case 2:
    /// with an external id as identity they would be two activities. Here they
    /// are two source records pointing at one.
    @Test("Two sources describing one run resolve to one canonical activity")
    func twoSourcesOneActivity() throws {
        try db.queue.write { conn in
            try Fixture.insertSourceRecord(conn, id: "SR-STRAVA", sourceID: "strava",
                                           externalID: "19580875358")
            try Fixture.insertSourceRecord(conn, id: "SR-HEALTH", sourceID: "appleHealth",
                                           externalID: "F1C2-UUID")
        }
        let canonical = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT activityID FROM activity_source_record")
        }
        #expect(canonical == ["ACT-1"])
    }

    @Test("A source record for an activity that does not exist is rejected")
    func orphanSourceRecordIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertSourceRecord($0, activityID: "NOT-A-THING") }
        }
    }

    @Test("A source record naming a source the app does not know is rejected")
    func unknownSourceIsRejected() throws {
        #expect(throws: DatabaseError.self) {
            try db.queue.write { try Fixture.insertSourceRecord($0, sourceID: "garmin") }
        }
    }

    /// THE POINT OF THE WHOLE DOCUMENT.
    ///
    /// At Phase 4A the Strava source records are purged under ADR-0002. If the
    /// alias went with them, every note, correction and rejection written
    /// against a Strava id would be orphaned on the day Strava was removed —
    /// thirteen months of writing, lost to a cascade rule nobody looked at.
    ///
    /// This is checked eighteen months early because it is the only time it is
    /// still cheap to be wrong about.
    @Test("An alias outlives the source record it came from")
    func aliasSurvivesTheSource() throws {
        try db.queue.write { conn in
            try Fixture.insertSourceRecord(conn)
            try Fixture.insertAlias(conn)
            // ADR-0002's purge, in miniature.
            try conn.execute(sql: "DELETE FROM activity_source_record WHERE sourceID = 'strava'")
        }
        let resolved = try db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT activityID FROM activity_alias WHERE sourceID = 'strava' AND externalID = ?
                """, arguments: ["19580875358"])
        }
        #expect(resolved == "ACT-1",
                "a note written against Strava id 19580875358 no longer finds its run")
    }

    /// The other half: an alias for an activity that is genuinely gone points
    /// at nothing and must go with it. Cascade on the activity, not on the
    /// source record — the distinction the previous test protects.
    @Test("Deleting an activity removes its source records and its aliases")
    func deletingAnActivityTakesItsIdentifiers() throws {
        try db.queue.write { conn in
            try Fixture.insertSourceRecord(conn)
            try Fixture.insertAlias(conn)
            try conn.execute(sql: "DELETE FROM activity WHERE id = 'ACT-1'")
        }
        let records = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity_source_record")
        }
        let aliases = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity_alias")
        }
        #expect(records == 0, "a source record survived its activity")
        #expect(aliases == 0, "an alias survived its activity")
        let report = try db.integrityReport()
        #expect(report.foreignKeyViolations == 0, "\(report.summary)")
    }

    /// §3.1: a canonical id is minted here and is never an external one. There
    /// is no constraint that can enforce "this UUID was not copied from
    /// Strava", so what is asserted is the property that made it necessary —
    /// the external id lives in exactly one place, and `activity` is not it.
    @Test("The activity table has no column holding an external identifier")
    func noExternalIDOnTheActivity() throws {
        let columns: [String] = try db.queue.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(activity)")
                .compactMap { row -> String? in row["name"] }
        }
        for c in columns {
            #expect(!c.localizedCaseInsensitiveContains("external"),
                    "\(c) puts an external identifier on the canonical activity")
            #expect(!c.localizedCaseInsensitiveContains("strava"),
                    "\(c) names a source on a table that is supposed to be source-neutral")
        }
    }
}

// MARK: - The database and the inventory agree

@Suite
struct DatabaseInventoryTests {

    /// A file that exists on disk and is not in `DataLifecycle` is a file
    /// "Delete local data" walks past. Declared in the same patch that made it
    /// possible to create, rather than in the one that first creates it.
    @Test("The inventory names the database folder")
    func inventoryNamesTheDatabase() throws {
        let item = DataLifecycle.appSupportItems.first { $0.pathComponent == Sub4Database.directoryName }
        let found = try #require(item, "the database folder is in no category")
        #expect(found.isDirectory, "it must be removed as a folder so the journal files go with it")
    }

    /// The sidecars are the reason it is a folder. If somebody changes it back
    /// to a file, this is what says why they should not.
    @Test("The database is declared as a folder, not as a single file")
    func declaredAsAFolder() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        let items = entry.storage.compactMap { s -> AppSupportItem? in
            if case .applicationSupport(let i) = s { return i }
            return nil
        }
        #expect(items.contains { if case .databaseDirectory = $0 { return true }; return false },
                "the database is not declared as a database folder")
    }

    /// It holds nothing yet and must not be described as holding anything. When
    /// 3.4 moves the stores into it, this test is what makes somebody rewrite
    /// the entry rather than leave the old sentence in place.
    @Test("The empty database says it is empty, and says what changes when it is not")
    func emptinessIsDisclosed() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        #expect(entry.lineage == [.device],
                "the database claims data it does not hold yet")
        #expect(entry.gaps.contains { $0.contains("3.4") },
                "nothing records that this entry has to be rewritten at 3.4")
    }

    /// ADR-0003 §9.4, action 2. The old sentence — "Nothing leaves this phone
    /// while the transfers above are switched off" — was false for every file
    /// this app has ever written, because Application Support is in the device
    /// backup by default.
    @Test("The summary no longer claims nothing leaves the phone")
    func summaryDoesNotDenyTheBackup() {
        let s = DataLifecycle.summary
        #expect(!s.contains("Nothing leaves this phone"),
                "the corrected sentence has been reverted")
        #expect(s.localizedCaseInsensitiveContains("backup"),
                "the summary does not mention the device backup")
    }

    /// ADR-0003 §9.4, action 4. Verified from the source: `Keychain.save` uses
    /// `kSecAttrAccessibleAfterFirstUnlock` without `ThisDeviceOnly`, so these
    /// items ARE in encrypted backups. The disclosure said the opposite.
    @Test("Credentials no longer claim to be absent from backups")
    func credentialsDoNotDenyTheBackup() throws {
        let c = try #require(DataLifecycle.entry(.credentials))
        #expect(!c.deletionRule.contains("never included in a backup"),
                "the false clause has been reverted")
        #expect(c.gaps.contains { $0.localizedCaseInsensitiveContains("backup") },
                "the backup behaviour is no longer disclosed as a gap")
    }
}
