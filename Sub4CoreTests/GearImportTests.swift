//
//  GearImportTests.swift
//  Sub4CoreTests
//
//  Patch 426, ADR-0003 §12.176, D7 slice B5.
//
//  TWO OF THESE ARE THE PATCH, AND THEY CAME OUT OF THE INVESTIGATION RATHER
//  THAN OUT OF THE PROMPT.
//
//  `aGearOnlyImportDoesNotEraseTheDate` — `retiredUTC` is DERIVED, and a
//  derived column is recomputed. `Sub4Import.run(activities: [])` is a real
//  call that the authored write-through makes, and a plain assignment would
//  find no activities and write NULL over a correct date, destroying a fact on
//  an import that was not about gear at all.
//
//  `retiredGearWithNoActivityIsStillRetired` — a derived date can be unknown,
//  and if the date were the only marker then "retired, last use unknown" and
//  "not retired" would be the same NULL. That collision is §12.15 and this
//  project has paid for it four times.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct GearImportTests {

    private func gear(_ id: String, _ name: String, km: Double,
                      kind: GearKind?, retired: Bool?) -> AthleteStore.Shoe {
        AthleteStore.Shoe(id: id, name: name, distanceM: km * 1000,
                          primary: false, kind: kind, retired: retired)
    }

    /// `startUTC` IS NOT OPTIONAL IN PRACTICE. The importer refuses an
    /// activity without one — "no start instant (startUTC is missing)" — and a
    /// fixture that omits it produces a report full of zeros rather than a
    /// failure anyone can read. Cost this patch one probe.
    private func activity(_ id: String, gear: String?, day: String) -> Activity {
        Activity(id: id, name: "Run", sportType: "Run",
                 startLocal: "\(day)T09:00:00", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_000,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: gear, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "\(day)T07:00:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func row(_ db: Sub4Database, _ externalID: String) throws -> Row? {
        try db.queue.read { d in
            try Row.fetchOne(d, sql: """
                SELECT kind, isRetired, retiredUTC, name FROM gear
                WHERE externalID = ?
                """, arguments: [externalID])
        }
    }

    // MARK: The two facts reach the row

    @Test("A bike is stored as a bike and a shoe as a shoe")
    func theKindReachesTheRow() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("s1", "Novablast", km: 534, kind: .shoe, retired: false),
            gear("b1", "Gravel", km: 4_000, kind: .bike, retired: false)])

        #expect(try row(db, "s1")?["kind"] as String? == "shoe")
        #expect(try row(db, "b1")?["kind"] as String? == "bike")
    }

    @Test("Retired gear is stored as retired")
    func retirementReachesTheRow() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("s1", "Novablast", km: 534, kind: .shoe, retired: false),
            gear("r1", "Old pair", km: 812, kind: .unknown, retired: true)])

        #expect(try row(db, "s1")?["isRetired"] as Bool? == false)
        #expect(try row(db, "r1")?["isRetired"] as Bool? == true)
    }

    /// A store that does not know must not teach the database something it
    /// invented. `nil` is a pre-425 file, not a shoe.
    @Test("Gear whose kind the store does not know is stored as unknown")
    func anUnknownKindIsNotGuessed() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("x1", "Something", km: 10, kind: nil, retired: nil)])
        #expect(try row(db, "x1")?["kind"] as String? == "unknown")
        #expect(try row(db, "x1")?["isRetired"] as Bool? == false)
    }

    /// The first import after 426 corrects every row the migration defaulted.
    @Test("A refresh corrects a kind the migration defaulted")
    func theRefreshCorrectsTheDefault() throws {
        let db = try Sub4Database.inMemory()
        // First run: the store does not know what it is.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("b1", "Gravel", km: 4_000, kind: nil, retired: nil)])
        #expect(try row(db, "b1")?["kind"] as String? == "unknown")

        // Second run, after `loadFromCache` recovered the kind.
        let report = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("b1", "Gravel", km: 4_000, kind: .bike, retired: false)])
        #expect(try row(db, "b1")?["kind"] as String? == "bike")
        #expect(report.gearRefreshed == 1,
                "a kind that changed did not count as a refresh")
    }

    @Test("A refresh with nothing to change stays quiet")
    func anUnchangedRefreshIsSilent() throws {
        let db = try Sub4Database.inMemory()
        let shoes = [gear("s1", "Novablast", km: 534, kind: .shoe, retired: false)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: shoes)
        let second = try Sub4Import.run(into: db, activities: [], shoes: shoes)
        #expect(second.gearRefreshed == 0,
                "a counter that cannot go quiet cannot report that the refresh stopped")
    }

    // MARK: The date

    @Test("Retired gear is dated by the newest activity naming it")
    func theDateIsTheNewestActivity() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db,
            activities: [activity("1", gear: "r1", day: "2025-03-01"),
                         activity("2", gear: "r1", day: "2025-09-14"),
                         activity("3", gear: "s1", day: "2026-08-01")],
            shoes: [gear("s1", "Novablast", km: 534, kind: .shoe, retired: false),
                    gear("r1", "Old pair", km: 812, kind: .unknown, retired: true)])

        let dated = try row(db, "r1")?["retiredUTC"] as String?
        #expect(dated?.hasPrefix("2025-09-14") == true,
                "the date is not the newest activity naming the gear")
        #expect(report.gearRetirementDated == 1)
        #expect(report.gearRetirementUndated == 0)
        // Gear the athlete still holds is not dated at all.
        #expect(try row(db, "s1")?["retiredUTC"] as String? == nil)
    }

    /// **THE COLLISION THIS PATCH ADDED A COLUMN TO AVOID.** If the date were
    /// the only marker, this row would be indistinguishable from active gear.
    @Test("Retired gear with no activity is still retired, and says the date is unknown")
    func retiredGearWithNoActivityIsStillRetired() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("r1", "Old pair", km: 812, kind: .unknown, retired: true)])

        #expect(try row(db, "r1")?["isRetired"] as Bool? == true,
                "retirement was expressed only by a date, and the date is unknown")
        #expect(try row(db, "r1")?["retiredUTC"] as String? == nil)
        #expect(report.gearRetirementUndated == 1,
                "an undated retirement was not reported")
        #expect(report.gearRetirementDated == 0)
    }

    /// **THE ONE THAT PROTECTS A FACT FROM A RUN THAT WAS NOT ABOUT IT.**
    /// `Sub4Import.run(activities: [])` is what the authored write-through
    /// calls on every note, decision and move.
    ///
    /// **IT DOES NOT DISCRIMINATE WHICH GUARD DID IT, AND SAYS SO.** Two
    /// things stop the erasure — the `guard let newest`, which is the intended
    /// one, and the `retiredUTC <> ?` clause, which is NULL-safe by accident of
    /// three-valued logic. Removing either alone leaves this test green.
    /// `retiredGearWithNoActivityIsStillRetired` is the one that notices,
    /// through the counter. Recorded rather than hidden — 409's control 4 is
    /// the precedent (§12.153).
    @Test("A gear-only import does not erase a date it cannot recompute")
    func aGearOnlyImportDoesNotEraseTheDate() throws {
        let db = try Sub4Database.inMemory()
        let shoes = [gear("r1", "Old pair", km: 812, kind: .unknown, retired: true)]
        _ = try Sub4Import.run(
            into: db,
            activities: [activity("1", gear: "r1", day: "2025-09-14")],
            shoes: shoes)
        let dated = try row(db, "r1")?["retiredUTC"] as String?
        #expect(dated != nil)

        // A write-through with no activities. It must find nothing to derive
        // from and leave the derived value alone.
        _ = try Sub4Import.run(into: db, activities: [], shoes: shoes)
        #expect(try row(db, "r1")?["retiredUTC"] as String? == dated,
                "an import with no activities erased a correct date")
    }

    /// **RETIREMENT SURVIVES THE FILE, AND NOTHING ELSE TESTED IT.**
    ///
    /// Found by sabotage: deleting the retirement half of `kinded` left every
    /// test in this file green, because they all pass `retired:` explicitly.
    /// The path a device actually takes is `athlete.json` → `loadFromCache` →
    /// `allGear` → the importer, and the fact is array membership until the
    /// first of those.
    @Test("Retirement is recovered from the file and reaches the row")
    func retirementSurvivesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A pre-425 file: three arrays, and not one `kind` or `retired` key.
        let cache = AthleteStore.Cache(
            zones: [],
            shoes: [gear("s1", "Novablast", km: 534, kind: nil, retired: nil)],
            bikes: [gear("b1", "Gravel", km: 4_000, kind: nil, retired: nil)],
            retired: [gear("r1", "Old pair", km: 812, kind: nil, retired: nil)],
            fetched: nil, ftp: nil)
        try JSONEncoder().encode(cache)
            .write(to: dir.appendingPathComponent("athlete.json"))

        let store = AthleteStore(directory: dir)
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: store.allGear)

        #expect(try row(db, "s1")?["isRetired"] as Bool? == false)
        #expect(try row(db, "b1")?["isRetired"] as Bool? == false)
        #expect(try row(db, "r1")?["isRetired"] as Bool? == true,
                "the retirement did not survive the file, the flattening and the importer")
        #expect(try row(db, "r1")?["kind"] as String? == "unknown")
        #expect(try row(db, "b1")?["kind"] as String? == "bike")
    }

    /// The join goes through `activity_gear_reference`, which is written for
    /// every activity naming gear — including before the gear row existed.
    @Test("An activity imported before its gear still dates the retirement")
    func theReferenceSurvivesTheOrdering() throws {
        let db = try Sub4Database.inMemory()
        // Run one: the activity names gear the profile does not hold.
        let first = try Sub4Import.run(
            into: db,
            activities: [activity("1", gear: "r1", day: "2025-09-14")],
            shoes: [])
        #expect(first.gearUnresolved == 1)

        // Run two: the gear is resolved, and the reference from run one is
        // what dates it.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            gear("r1", "Old pair", km: 812, kind: .unknown, retired: true)])
        let dated = try row(db, "r1")?["retiredUTC"] as String?
        #expect(dated?.hasPrefix("2025-09-14") == true,
                "the date was taken from activity.gearID, which run one left null")
    }
}
