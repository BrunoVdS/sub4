//
//  MatchDecisionTests.swift
//  Sub4CoreTests
//
//  The match override becomes a record, and reaches its table — patch 272,
//  ADR-0003 §12.19. D4's database half, first of three.
//
//  TWO HALVES, AND THEY FAIL DIFFERENTLY
//  -------------------------------------
//  The store half is a MIGRATION, which runs exactly once per device and can
//  therefore never be observed again on the phone it mattered on. That is why
//  `Matcher(defaults:)` exists at all: a migration nobody can run twice is a
//  migration that has to be proved somewhere other than the device.
//
//  The import half is the same re-keying weather needed in §12.9 — the store
//  holds a Strava activity id and `match_decision.activityID` references the
//  canonical one. If that resolution silently failed, every decision would
//  land in `matchDecisionsUnresolved` and the screen would report a tidy
//  zero-refusal import that stored nothing.
//
//  WHAT IS DELIBERATELY HELD BACK RATHER THAN WRITTEN
//  --------------------------------------------------
//  A decision naming an activity the database does not have could be written
//  with a NULL `activityID` — the column allows it. It is not, because NULL
//  already means "the athlete said nothing satisfied this session". Writing
//  "he named an activity we cannot find" into the same shape would make the
//  database state something the athlete never said, which is a worse outcome
//  than the database staying silent and a counter saying so.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct MatchDecisionTests {

    // MARK: Fixtures

    private func activity(_ id: String, name: String = "Morning Run") -> Activity {
        Activity(id: id, name: name, sportType: "Run",
                 startLocal: "2026-07-28T09:24:06", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: 40, averageHeartrate: 142, isTrainer: nil,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T07:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// A whole second, so the ISO-8601 round trip is lossless. `.iso8601`
    /// carries no fraction, and a fixture with one would fail on a difference
    /// the app does not have.
    private let when = Date(timeIntervalSince1970: 1_785_000_000)

    private func decision(_ uid: String,
                          _ activityId: String?,
                          dateIsKnown: Bool = true) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: activityId,
                      decided: when, dateIsKnown: dateIsKnown)
    }

    /// Its own defaults domain per test, removed on the way in AND on the way
    /// out. On the way in because a previous crashed run leaves its domain
    /// behind, and a test that inherits one is a test that passes for the
    /// wrong reason.
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: suite(name))
        return try #require(UserDefaults(suiteName: suite(name)))
    }

    private func suite(_ name: String) -> String { "sub4.tests.\(name)" }

    private func forget(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite(name))
    }

    // MARK: The inventory

    /// The same shape as `loadThresholdKeysAreCoveredAtTheirSource`, and here
    /// for the same reason one patch earlier in the failure: this patch
    /// CHANGES a preference key, which is precisely when a hand-written list
    /// and the thing it describes come apart. Asking `Matcher` means a third
    /// key would be covered the moment it is added.
    @Test("The keys Matcher writes are the keys the inventory covers")
    func matcherKeysAreCoveredAtTheirSource() {
        let covered = Set(DataLifecycle.preferenceKeys)
        let missing = Matcher.preferenceKeys.filter { !covered.contains($0) }
        #expect(missing.isEmpty, "not covered by any category: \(missing)")
        #expect(Matcher.preferenceKeys.count == 2)
    }

    // MARK: The store — the migration

    @Test("The retired [uid: id] shape is read once and then removed")
    func theRetiredShapeIsMigratedAndRemoved() throws {
        let defaults = try freshDefaults("migrate")
        defer { forget("migrate") }

        defaults.set(["w01-tue": "19580875358", "w01-thu": ""],
                     forKey: "match.overrides")

        let matcher = Matcher(defaults: defaults)

        #expect(matcher.decisions.count == 2)
        #expect(matcher.decisions["w01-tue"]?.activityId == "19580875358")
        // THE OLD KEY IS GONE. Leaving it would leave a second copy of
        // authored data on disk that nothing reads and "Delete local data"
        // would have to be told about twice.
        #expect(defaults.object(forKey: "match.overrides") == nil)
        #expect(defaults.data(forKey: "match.decisions") != nil)
    }

    @Test("A migrated decision says its date is not known")
    func aMigratedDecisionSaysItsDateIsNotKnown() throws {
        let defaults = try freshDefaults("undated")
        defer { forget("undated") }

        defaults.set(["w01-tue": "19580875358"], forKey: "match.overrides")
        let matcher = Matcher(defaults: defaults)

        let migrated = try #require(matcher.decisions["w01-tue"])
        #expect(migrated.dateIsKnown == false)
    }

    @Test("The empty string becomes a real absence")
    func anEmptyStringBecomesARealAbsence() throws {
        let defaults = try freshDefaults("absence")
        defer { forget("absence") }

        defaults.set(["w01-thu": ""], forKey: "match.overrides")
        let matcher = Matcher(defaults: defaults)

        let migrated = try #require(matcher.decisions["w01-thu"])
        #expect(migrated.activityId == nil)
    }

    @Test("A new decision carries its date and survives a relaunch")
    func aNewDecisionCarriesItsDateAndSurvivesARelaunch() throws {
        let defaults = try freshDefaults("relaunch")
        defer { forget("relaunch") }

        let first = Matcher(defaults: defaults)
        first.setOverride(sessionUid: "w02-sat", activityId: "19580875358", now: when)

        let second = Matcher(defaults: defaults)
        let read = try #require(second.decisions["w02-sat"])
        #expect(read.activityId == "19580875358")
        #expect(read.decided == when)
        #expect(read.dateIsKnown)
    }

    @Test("Clearing an override removes it from the blob, not just from memory")
    func clearingRemovesItFromTheBlob() throws {
        let defaults = try freshDefaults("clear")
        defer { forget("clear") }

        let first = Matcher(defaults: defaults)
        first.setOverride(sessionUid: "w02-sat", activityId: "19580875358", now: when)
        first.clearOverride(sessionUid: "w02-sat")

        #expect(Matcher(defaults: defaults).decisions.isEmpty)
    }

    // MARK: The import

    @Test("The Strava key is resolved through the alias to the canonical activity")
    func theStravaKeyIsResolvedThroughTheAlias() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("19580875358")],
                                        shoes: [],
                                        matchDecisions: [decision("w01-tue", "19580875358")])

        #expect(report.matchDecisionsSeen == 1)
        #expect(report.matchDecisionsImported == 1)
        #expect(report.matchDecisionsUnresolved == 0)

        let (stored, canonical) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT activityID FROM match_decision"),
             try String.fetchOne(d, sql: "SELECT id FROM activity"))
        }
        let activityID = try #require(stored)
        #expect(activityID == canonical)
        // The point of the alias: what lands is NOT the Strava id.
        #expect(activityID != "19580875358")
    }

    @Test("Explicitly nothing is written as a NULL activity")
    func explicitlyNothingIsWrittenAsNull() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("19580875358")],
                                        shoes: [],
                                        matchDecisions: [decision("w01-thu", nil)])

        #expect(report.matchDecisionsImported == 1)
        #expect(report.matchDecisionsUnresolved == 0)

        let rows = try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM match_decision WHERE activityID IS NULL
                """)
        }
        #expect(rows == 1)
    }

    @Test("A decision naming an activity that is not there is held back, not nulled")
    func aDecisionNamingAnAbsentActivityIsHeldBack() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("19580875358")],
                                        shoes: [],
                                        matchDecisions: [decision("w01-tue", "99999999999")])

        #expect(report.matchDecisionsSeen == 1)
        #expect(report.matchDecisionsUnresolved == 1)
        #expect(report.matchDecisionsImported == 0)
        // AND NOT AS A NULL. This is the assertion the header is about: a row
        // here would make the database say the athlete decided "nothing".
        let rows = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM match_decision")
        }
        #expect(rows == 0)
        // Not a refusal either — the import is clean, the counter is the
        // report.
        #expect(report.isClean)
    }

    @Test("A decision on an excluded recording is a decision, not a gap")
    func aDecisionOnAnExcludedRecordingIsNotAGap() throws {
        let db = try Sub4Database.inMemory()
        // The Romania ride — `DataCorrections.ignoredActivities`, §12.12.6.
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("19580875358")],
                                        shoes: [],
                                        matchDecisions: [decision("w01-tue", "18883849470")])

        #expect(report.matchDecisionsIgnored == 1)
        // NEVER COUNTED AS SEEN — the same rule as `weatherIgnored` in patch
        // 257. "Seen" is work attempted; this was declined at the door.
        #expect(report.matchDecisionsSeen == 0)
        #expect(report.matchDecisionsUnresolved == 0)
    }

    @Test("Importing twice leaves one row and calls the second a refresh")
    func importingTwiceLeavesOneRow() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        let decisions = [decision("w01-tue", "19580875358")]

        let first = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                       matchDecisions: decisions)
        let second = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        matchDecisions: decisions)

        #expect(first.matchDecisionsImported == 1)
        #expect(second.matchDecisionsImported == 0)
        #expect(second.matchDecisionsUpdated == 1)

        let rows = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM match_decision")
        }
        #expect(rows == 1)
    }

    // MARK: The verifier

    @Test("A faithful import of a decision verifies")
    func aFaithfulImportVerifies() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        let decisions = [decision("w01-tue", "19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               matchDecisions: decisions)

        let report = try SemanticVerifier.verify(db, activities: acts,
                                                 matchDecisions: decisions)
        #expect(report.passed, "a faithful migration failed verification")
        let tables = Set(report.checks.map(\.table))
        #expect(tables.contains("match_decision"))
    }

    @Test("Deleting a decision is caught, and names its table")
    func deletingADecisionIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        let decisions = [decision("w01-tue", "19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               matchDecisions: decisions)

        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM match_decision")
        }

        let report = try SemanticVerifier.verify(db, activities: acts,
                                                 matchDecisions: decisions)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "match_decision" })
    }

    @Test("A held-back decision is not counted as expected either")
    func aHeldBackDecisionIsNotExpected() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        // One that resolves, one that cannot. The importer writes one row; the
        // verifier has to expect one, not two — otherwise every device with a
        // stale override reports a permanent disagreement.
        let decisions = [decision("w01-tue", "19580875358"),
                         decision("w01-thu", "99999999999")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               matchDecisions: decisions)

        let report = try SemanticVerifier.verify(db, activities: acts,
                                                 matchDecisions: decisions)
        #expect(report.passed)
    }
}
