//
//  CorrectionTests.swift
//  Sub4CoreTests
//
//  Which rides are commutes — patch 280, ADR-0003 §12.26. D5 slice 4.
//
//  `theStravaKeyIsResolvedThroughTheAlias` is the same assertion weather needed
//  in §12.9 and match decisions needed in §12.19: the store is keyed by Strava
//  id and the column holds the canonical one. If that resolution silently
//  failed, every decision would land in `correctionsUnresolved` and the screen
//  would report a tidy zero-refusal import that stored nothing.
//
//  `thePruneWaitsForAFullAccounting` is the one with teeth. The keep-set is
//  built from the ids that RESOLVED, so a decision the database cannot place
//  is a decision that cannot protect its own row — and deleting a correction
//  the athlete still holds would be the §12.20 failure with a different name.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct CorrectionTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_785_000_000)

    private func ride(_ id: String, km: Double = 4.0) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: km * 1000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func decision(_ id: String, _ isCommute: Bool) -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: isCommute, decided: decidedAt)
    }

    private func row(_ db: Sub4Database) throws -> Row? {
        try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM correction")
        }
    }

    private func count(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM correction") ?? 0
        }
    }

    // MARK: The row

    @Test("The Strava key is resolved through the alias to the canonical activity")
    func theStravaKeyIsResolvedThroughTheAlias() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [ride("19580875358")],
                                        shoes: [],
                                        commutes: [decision("19580875358", true)])

        #expect(report.correctionsSeen == 1)
        #expect(report.correctionsImported == 1)
        #expect(report.correctionsUnresolved == 0)

        let fetched = try row(db)
        let r = try #require(fetched)
        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT id FROM activity")
        }
        #expect(r["subjectID"] as String? == canonical)
        #expect(r["subjectID"] as String? != "19580875358")
    }

    @Test("Every column says what it should")
    func theCorrectionArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride("19580875358")],
                               shoes: [], commutes: [decision("19580875358", true)])

        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["subjectKind"] as String? == "activity")
        #expect(r["field"] as String? == "isCommute")
        #expect(r["value"] as String? == "true")
        // Provenance, not an argument — §12.26. The same sentence on every row.
        #expect(r["reason"] as String? == Sub4Import.commuteReason)
        // THE DATE THE ATHLETE DECIDED, not the date of the import. This is the
        // one store that already carried it.
        #expect((r["authoredUTC"] as String? ?? "").hasPrefix("2026-"))
    }

    @Test("Not a commute is a decision, not an absence")
    func falseIsStoredAsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride("19580875358")],
                               shoes: [], commutes: [decision("19580875358", false)])

        let fetched = try row(db)
        let r = try #require(fetched)
        // "I have no opinion" is `clear`, which writes no row at all. `false`
        // is the athlete saying this is NOT a commute, and it survives a change
        // to the distance rule — which is the whole point of the toggle.
        #expect(r["value"] as String? == "false")
    }

    @Test("A decision on an activity that is not here is held back")
    func anUnresolvedDecisionIsHeldBack() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [ride("19580875358")],
                                        shoes: [],
                                        commutes: [decision("99999999999", true)])
        #expect(report.correctionsSeen == 1)
        #expect(report.correctionsUnresolved == 1)
        let n = try count(db)
        #expect(n == 0)
        #expect(report.isClean)
    }

    @Test("A decision on an excluded recording is not a gap")
    func anIgnoredDecisionIsNotAGap() throws {
        let db = try Sub4Database.inMemory()
        // The Romania ride — `DataCorrections.ignoredActivities`, §12.12.6.
        let report = try Sub4Import.run(into: db, activities: [ride("19580875358")],
                                        shoes: [],
                                        commutes: [decision("18883849470", true)])
        #expect(report.correctionsIgnored == 1)
        #expect(report.correctionsSeen == 0)
        #expect(report.correctionsUnresolved == 0)
    }

    @Test("Importing twice keeps one row and calls the second a refresh")
    func importingTwiceKeepsOneRow() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        let commutes = [decision("19580875358", true)]
        let first = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                       commutes: commutes)
        let second = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        commutes: commutes)
        #expect(first.correctionsImported == 1)
        #expect(second.correctionsUpdated == 1)
        let n = try count(db)
        #expect(n == 1)
    }

    @Test("Changing your mind rewrites the row rather than adding one")
    func changingYourMindRewrites() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: [decision("19580875358", true)])
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: [decision("19580875358", false)])

        let n = try count(db)
        #expect(n == 1)
        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["value"] as String? == "false")
    }

    // MARK: The prune

    @Test("Clearing an opinion removes the row, when permitted")
    func aClearedOpinionIsRemoved() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: [decision("19580875358", true)],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        let before = try count(db)
        #expect(before == 1)

        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        commutes: [], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.correctionsRemoved == 1)
        let after = try count(db)
        #expect(after == 0)
    }

    @Test("Without permission the prune removes nothing")
    func thePruneNeedsPermission() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: [decision("19580875358", true)],
                               reconcile: .run(Set(ReconcileFamily.allCases)))

        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        commutes: [])
        #expect(report.correctionsRemoved == 0)
        let n = try count(db)
        #expect(n == 1)
    }

    /// THE ONE WITH TEETH.
    @Test("The prune waits for a full accounting")
    func thePruneWaitsForAFullAccounting() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: [decision("19580875358", true)],
                               reconcile: .run(Set(ReconcileFamily.allCases)))

        // The store still holds the first decision AND one the database cannot
        // place. The unresolved one cannot protect its own row, so nothing may
        // be pruned at all — not even rows the resolved set would have spared.
        let report = try Sub4Import.run(
            into: db, activities: acts, shoes: [],
            commutes: [decision("19580875358", true), decision("99999999999", false)],
            reconcile: .run(Set(ReconcileFamily.allCases)))

        #expect(report.correctionsUnresolved == 1)
        #expect(report.correctionsRemoved == 0)
        let n = try count(db)
        #expect(n == 1)
    }

    /// The prune claims one field. Anything else in this table is somebody
    /// else's — `DataCorrections` lands here one day.
    @Test("A correction on another field is not claimed by the prune")
    func anotherFieldSurvives() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO account (id, label, createdUTC)
                VALUES ('local', 'This phone', '2026-08-05T00:00:00Z')
                """)
            try d.execute(sql: """
                INSERT INTO correction
                  (id, accountID, subjectKind, subjectID, field, value,
                   reason, authoredUTC)
                VALUES ('other', 'local', 'activity', 'x', 'scoringSeconds',
                        '4486', 'chip time', '2026-06-14T00:00:00Z')
                """)
        }

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        commutes: [], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.correctionsRemoved == 0)
        let n = try count(db)
        #expect(n == 1)
    }

    // MARK: The verifier

    @Test("A faithful set of corrections verifies")
    func aFaithfulSetVerifies() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        let commutes = [decision("19580875358", true)]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [], commutes: commutes)

        let report = try SemanticVerifier.verify(db, activities: acts, commutes: commutes)
        #expect(report.passed, "faithful corrections failed verification")
        let tables = Set(report.checks.map(\.table))
        #expect(tables.contains("correction"))
    }

    @Test("Deleting a correction is caught, and names its table")
    func deletingACorrectionIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        let commutes = [decision("19580875358", true)]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [], commutes: commutes)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM correction")
        }

        let report = try SemanticVerifier.verify(db, activities: acts, commutes: commutes)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "correction" })
    }
}
