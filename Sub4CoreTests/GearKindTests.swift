//
//  GearKindTests.swift
//  Sub4CoreTests
//
//  Patch 425, ADR-0003 §12.175, D7 slice B5.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Until this patch the kind of a piece of gear was carried by WHICH ARRAY it
//  sat in, and `allGear` — `shoes + bikes + retired` — flattened all three
//  before anything downstream saw them. Nothing was discarding the fact; the
//  importer was never told it.
//
//  Every test below fails without 425. Two of them fail in a way worth naming:
//  `aPreExistingFileKeepsItsKind` fails if the kind is invented from the array
//  unconditionally, and `retiredGearIsNotCalledAShoe` fails if `unknown` is
//  quietly folded into `shoe` — which would be right most of the time, and
//  that is exactly what makes it dangerous.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct GearKindVocabularyTests {

    /// **THE FROZEN VOCABULARY, AND THE COUPLING IS ALL THERE IS.**
    ///
    /// `2026-08-21-gear-kind` names these three in a `DEFAULT` and a migration
    /// is history. SQLite cannot add a CHECK by `ALTER`, and rebuilding `gear`
    /// to get one would rewrite history for a constraint — so unlike
    /// `work_queue.state`, which the database enforces, this vocabulary is
    /// enforced HERE and nowhere else. Said plainly because it is a real
    /// difference in how much the two are protected.
    @Test("The frozen gear kinds still match the schema")
    func theFrozenGearKindsMatchTheSchema() {
        let kinds = GearKind.allCases.map(\.rawValue)
        #expect(Set(kinds) == Set(Sub4Migrations.gearKinds),
                "GearKind drifted from what 2026-08-21-gear-kind froze")
        #expect(Set(Sub4Migrations.gearKinds) == Set(["shoe", "bike", "unknown"]),
                "the migration's literal moved, and a migration is history")
    }

    @Test("The migration is registered, in order, and applies")
    func theMigrationApplies() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.gearKind))
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted(),
                "the identifiers no longer sort into run order")
        let db = try Sub4Database.inMemory()
        let applied = try db.queue.read { d in
            try Row.fetchAll(d, sql: "PRAGMA table_info(gear)")
                .compactMap { $0["name"] as String? }
        }
        #expect(applied.contains("kind"), "gear.kind is missing")
        #expect(applied.contains("retiredUTC"),
                "retiredUTC went away — it has been there since patch 205")
    }

    /// The default is what every row written before today gets.
    @Test("A row inserted without a kind reads unknown, not shoe")
    func theDefaultIsUnknown() throws {
        let db = try Sub4Database.inMemory()
        // The account comes from the importer, because `gear.accountID`
        // references it — an empty database has no rows to hang gear on.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        let kind: String? = try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO gear (id, accountID, name, distanceM)
                VALUES ('g', ?, 'Old pair', 100)
                """, arguments: [Sub4Import.accountID])
            return try Row.fetchOne(d, sql: "SELECT kind FROM gear WHERE id = 'g'")?["kind"]
        }
        // NOT `shoe`. Defaulting to the common answer would invent complete
        // confidence about a past nothing recorded.
        #expect(kind == "unknown",
                "the default invents a fact about rows written before 425")
    }
}


@Suite
@MainActor
struct GearKindModelTests {

    private func shoe(_ id: String, kind: GearKind? = nil) -> AthleteStore.Shoe {
        AthleteStore.Shoe(id: id, name: id, distanceM: 700_000,
                          primary: false, kind: kind)
    }

    /// **THE ONE THAT FAILS WITHOUT THE PATCH, AND IT GOES THROUGH THE FILE.**
    ///
    /// `allGear` is what `AppStores` hands the importer, and before 425 every
    /// item in it looked identical. Driven through `init(directory:)` and a
    /// real `athlete.json` rather than through a test-only setter: the seam
    /// already exists (RULE 13 counts it), and this way the test covers
    /// `loadFromCache`'s recovery of the kind as well as the flattening — which
    /// is the actual path a device takes.
    @Test("allGear carries the kind through the flattening")
    func allGearIsNoLongerLossy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // NO `kind` KEY AT ALL — this is a file written before 425, which is
        // every file on every device today.
        let cache = AthleteStore.Cache(
            zones: [], shoes: [shoe("s")], bikes: [shoe("b")],
            retired: [shoe("r")], fetched: nil, ftp: nil)
        try JSONEncoder().encode(cache)
            .write(to: dir.appendingPathComponent("athlete.json"))

        let store = AthleteStore(directory: dir)
        let kinds = store.allGear.map { $0.kind }
        #expect(kinds == [.shoe, .bike, .unknown],
                "the kind is lost the moment the three arrays are concatenated")
    }

    /// A file written before 425 carries `kind: nil` on every item — and the
    /// fact is not gone, it is in which key the item decoded from.
    @Test("A pre-425 file recovers its kinds from the arrays it decoded from")
    func aPreExistingFileKeepsItsKind() {
        let kinded = AthleteStore.kinded([shoe("a"), shoe("b")], .bike)
        #expect(kinded.allSatisfy { $0.kind == .bike })
    }

    /// `kinded` may only fill a gap. Overwriting would make the array the
    /// authority over the item, and `retired` is where those two disagree.
    @Test("A kind already set is never overwritten")
    func anExistingKindSurvives() {
        let kinded = AthleteStore.kinded([shoe("a", kind: .bike)], .shoe)
        #expect(kinded.first?.kind == .bike,
                "the array overwrote a kind the item already knew")
    }

    /// **RETIRED GEAR IS THE LIST WHOSE KIND WAS NEVER KNOWN.** `fetchGear`
    /// decodes id, name, distance and primary and no type, so calling it a shoe
    /// would be a guess that is usually right.
    @Test("Retired gear with no kind stays unknown")
    func retiredGearIsNotCalledAShoe() {
        let kinded = AthleteStore.kinded([shoe("r")], .unknown)
        #expect(kinded.first?.kind == .unknown)
        #expect(kinded.first?.wearIsMeaningful == false,
                "a wear bar on gear of unknown kind puts 600/800 km of running-shoe thresholds on something nobody identified")
    }

    /// The thresholds are running-shoe numbers, and 267 split `bikes` off for
    /// exactly this reason. 425 is where that reason becomes readable from a
    /// `Shoe` rather than from which array holds it.
    @Test("Wear means something for a shoe and nothing for a bike")
    func wearIsForShoes() {
        #expect(shoe("s", kind: .shoe).wearIsMeaningful)
        #expect(!shoe("b", kind: .bike).wearIsMeaningful)
        #expect(!shoe("u", kind: .unknown).wearIsMeaningful)
        // nil is a pre-425 file, and those were all rendered as shoes. The
        // default preserves what the screen did rather than changing it in a
        // patch that is only supposed to carry a fact.
        #expect(shoe("old", kind: nil).wearIsMeaningful)
    }

    /// A `Shoe` that has been through the file must come back the same.
    @Test("The kind survives a JSON round trip")
    func theKindSurvivesTheFile() throws {
        let original = shoe("b", kind: .bike)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(AthleteStore.Shoe.self, from: data)
        #expect(back.kind == .bike)
        #expect(back == original)
    }

    /// **THE DECODE HAZARD THIS FIELD WAS MADE OPTIONAL FOR.** A synthesised
    /// `init(from:)` ignores Swift default values, so a non-optional `kind`
    /// would fail to decode every `athlete.json` written before today — taking
    /// the zones, the FTP and the whole shoe history with it.
    @Test("A file written before 425 still decodes")
    func anOlderFileStillDecodes() throws {
        let json = Data("""
        {"id":"s1","name":"Novablast","distanceM":534000,"primary":true}
        """.utf8)
        let back = try JSONDecoder().decode(AthleteStore.Shoe.self, from: json)
        #expect(back.id == "s1")
        #expect(back.kind == nil, "nil is 'not recorded', which is not 'unknown'")
    }
}
