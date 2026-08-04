//
//  ActivityInputTests.swift
//  Sub4CoreTests
//
//  The five columns 3.2 missed — patch 217, ADR-0003 §12.3.
//
//  THE TEST THAT MATTERS HERE IS `everyFieldTheImporterCarriesHasAColumn`.
//  The others check the constraints behave; that one checks the SCHEMA IS
//  COMPLETE for the cutover, which is the thing that was wrong. Five fields
//  that feed `PowerLoad`, `TrainingLoad` and `Weather` had nowhere to go, and
//  every existing test passed anyway — because they all asked "does what is
//  declared work" and none asked "is what is declared enough".
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct ActivityInputTests {

    private func fixture(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO account (id, label, createdUTC)
            VALUES ('A', 'Test', '2026-01-01T00:00:00Z')
            """)
        try db.execute(sql: """
            INSERT INTO gear (id, accountID, sourceID, externalID, name, distanceM)
            VALUES ('G1', 'A', 'strava', 'g29433600', 'Novablast 5 TR', 340000)
            """)
    }

    private func insertActivity(_ db: Database, id: String = "ACT",
                                gearID: String? = nil,
                                averageWatts: Double? = nil,
                                hasPowerMeter: Bool? = nil,
                                isIndoor: Bool? = nil,
                                maxSpeedMS: Double? = nil) throws {
        try db.execute(sql: """
            INSERT INTO activity
              (id, accountID, startUTC, startLocal, dayKey, discipline, name,
               distanceM, movingSeconds, elapsedSeconds, createdUTC, updatedUTC,
               gearID, averageWatts, hasPowerMeter, isIndoor, maxSpeedMS)
            VALUES (?, 'A', '2026-07-28T05:24:06Z', '2026-07-28T07:24:06',
                    '2026-07-28', 'run', 'Session', 10000, 3000, 3100,
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
                    ?, ?, ?, ?, ?)
            """, arguments: [id, gearID, averageWatts, hasPowerMeter, isIndoor, maxSpeedMS])
    }

    /// THE ONE THAT WOULD HAVE CAUGHT THE GAP.
    ///
    /// Every field `activities.json` holds must have somewhere to land, or the
    /// cutover drops it silently. `deviceWatts` and `isTrainer` feed the
    /// training-load model; losing them changes CTL/ATL/TSB with nothing
    /// looking broken.
    @Test("Every field the importer carries has a column")
    func everyFieldTheImporterCarriesHasAColumn() throws {
        let db = try Sub4Database.inMemory()
        let columns = try db.queue.read { d in
            try d.columns(in: "activity").map(\.name)
        }
        for required in ["gearID", "averageWatts",
                         "hasPowerMeter", "isIndoor", "maxSpeedMS"] {
            #expect(columns.contains(required), "activity has no column for \(required)")
        }
    }

    @Test("The new migration is declared as well as registered")
    func theMigrationIsDeclared() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.activityInputs))
        #expect(Sub4Migrations.all.contains(Sub4Migrations.gearReference))
        #expect(Sub4Migrations.all.last == Sub4Migrations.gearReference,
                "a migration added out of order will apply out of order")
        let db = try Sub4Database.inMemory()
        let applied = try db.integrityReport().appliedMigrations
        #expect(applied.contains(Sub4Migrations.activityInputs))
    }

    /// Absent is not false — §6. `PowerLoad` has to tell "no power meter" apart
    /// from "this activity predates the app recording it", and `Weather` must
    /// not read a missing `isIndoor` as "outdoors" and go asking for conditions
    /// in a gym.
    @Test("The flags are nullable, and null is a third answer")
    func theFlagsDistinguishAbsentFromFalse() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try fixture(d)
            try insertActivity(d, id: "UNKNOWN")
            try insertActivity(d, id: "KNOWN", hasPowerMeter: false, isIndoor: false)
        }
        let (unknown, known) = try db.queue.read { d in
            (try Bool.fetchOne(d, sql: "SELECT hasPowerMeter FROM activity WHERE id = 'UNKNOWN'"),
             try Bool.fetchOne(d, sql: "SELECT hasPowerMeter FROM activity WHERE id = 'KNOWN'"))
        }
        #expect(unknown == nil, "absent was stored as a value")
        #expect(known == false)
    }

    @Test("Gear can be attributed, and retiring shoes does not delete the runs")
    func retiringGearKeepsTheActivity() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try fixture(d)
            try insertActivity(d, gearID: "G1")
            try d.execute(sql: "DELETE FROM gear WHERE id = 'G1'")
        }
        let (rows, gear) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity") ?? -1,
             try String.fetchOne(d, sql: "SELECT gearID FROM activity WHERE id = 'ACT'"))
        }
        #expect(rows == 1, "deleting a pair of shoes deleted the runs done in them")
        #expect(gear == nil, "the reference was left dangling")
    }

    @Test("A gear id that names no gear is rejected")
    func gearMustExist() throws {
        let db = try Sub4Database.inMemory()
        #expect(throws: (any Error).self) {
            try db.queue.write { d in
                try fixture(d)
                try insertActivity(d, gearID: "NOT-A-GEAR")
            }
        }
    }

    @Test("Zero watts is rejected; absent watts is allowed")
    func zeroWattsIsNotAReading() throws {
        let db = try Sub4Database.inMemory()
        #expect(throws: (any Error).self) {
            try db.queue.write { d in
                try fixture(d)
                try insertActivity(d, averageWatts: 0)
            }
        }
        try db.queue.write { d in
            try fixture(d)
            try insertActivity(d, averageWatts: nil)
        }
    }

    /// DELIBERATELY LOOSER THAN §7's BOUNDS, and this pins the reasoning.
    ///
    /// `distanceM` and `elapsedSeconds` have upper bounds because the August
    /// 2025 artifact was a session that was wrong. A GPS spike in max speed
    /// does not make the run untrue, and refusing it would cost the whole
    /// activity — the insert fails, the row lands in `rejection`, and a real
    /// session disappears over a field nobody reads closely.
    @Test("An implausible max speed does not cost the session")
    func maxSpeedHasNoUpperBound() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try fixture(d)
            try insertActivity(d, maxSpeedMS: 900)      // a GPS spike, not a run
        }
        let stored = try db.queue.read { d in
            try Double.fetchOne(d, sql: "SELECT maxSpeedMS FROM activity WHERE id = 'ACT'")
        }
        #expect(stored == 900)

        // Negative is still refused: that is not a spike, it is nonsense.
        let db2 = try Sub4Database.inMemory()
        #expect(throws: (any Error).self) {
            try db2.queue.write { d in
                try fixture(d)
                try insertActivity(d, maxSpeedMS: -1)
            }
        }
    }
}
