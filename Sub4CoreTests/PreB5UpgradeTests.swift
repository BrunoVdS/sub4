//
//  PreB5UpgradeTests.swift
//  Sub4CoreTests
//
//  Patch 436, ADR-0003 §12.191. Task 0A tranche 3 of
//  docs/PLAN-post-B5-database-cutover-execution.md.
//
//  WHAT WAS MISSING, AND WHY IT MATTERS MORE THAN IT SOUNDS
//  --------------------------------------------------------
//  Every B5 test so far starts from `Sub4Database.inMemory()`, which runs the
//  WHOLE migrator — so `gear` has had `kind` and `isRetired` from the first
//  statement, and every assertion about "the default" was made against a table
//  that never existed without them.
//
//  **The device does not work like that.** Bruno's database was created in
//  August and carried eleven gear rows written by an importer that named six
//  columns. The two B5 migrations ran over live data, and the first thing the
//  app did afterwards was read those rows and believe them.
//
//  So this migrates to `2026-08-20-run-removal` — the last pre-B5 migration —
//  populates it the way the old importer did, and only then applies B5. It is
//  the only test in the suite where `ALTER TABLE` runs over rows.
//
//  IT ALSO PROVES THE ORDER OF THE TWO ANSWERS
//  -------------------------------------------
//  §12.175.4 and §12.176.2 argue that `unknown` and `false` are HONEST for a
//  row written before the fact existed, and that reconciliation supplies the
//  truth afterwards. Those are two claims about two moments, and a test that
//  starts from a full migration can only ever see the second.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct PreB5UpgradeTests {

    /// The last migration before B5. Named rather than computed: a test that
    /// derived "the one before the new ones" would silently follow B6 along and
    /// stop testing this upgrade.
    private let lastPreB5 = "2026-08-20-run-removal"

    /// A database at the pre-B5 schema, populated the way the pre-426 importer
    /// populated it — six columns, and no opinion about kind or retirement.
    private func populatedPreB5() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(
            configuration: Sub4Database.configuration(label: "pre-b5"))
        try Sub4Migrations.migrator.migrate(queue, upTo: lastPreB5)

        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO account (id, label, createdUTC)
                VALUES (?, 'local', '2026-08-01T00:00:00Z')
                """, arguments: [Sub4Import.accountID])
            // **EXACTLY THE SIX COLUMNS THE OLD IMPORTER NAMED, `sourceID`
            // INCLUDED.** The first draft left it null, and `importGear`
            // matches on `accountID AND sourceID AND externalID` — so the
            // reconciliation test inserted three NEW rows beside the three it
            // was supposed to correct, and reported three insertions where the
            // device reported eleven refreshes. **A fixture that is nearly the
            // production write is a fixture that tests a path production never
            // takes.** Writing `kind` here, on the other hand, would be writing
            // the future into the past and would make the whole test vacuous.
            for (id, ext, name, km) in [("g-1", "g14536649", "Novablast", 534.0),
                                        ("g-2", "b6932581", "Gravel bike", 4_000.0),
                                        ("g-3", "g99999999", "Old pair", 812.0)] {
                try d.execute(sql: """
                    INSERT INTO gear (id, accountID, sourceID, externalID, name, distanceM)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [id, Sub4Import.accountID, Sub4Import.sourceID,
                                      ext, name, km * 1000])
            }
        }
        return queue
    }

    private func gearRows(_ queue: DatabaseQueue) throws -> [Row] {
        try queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT externalID, name, distanceM, kind, isRetired, retiredUTC
                  FROM gear ORDER BY externalID
                """)
        }
    }

    // MARK: The upgrade itself

    /// **THE ONE THE RUNBOOK ASKED FOR.** Rows written before the columns
    /// existed survive the two `ALTER TABLE`s intact.
    @Test("Gear written before B5 survives both migrations")
    func populatedRowsSurviveTheUpgrade() throws {
        let queue = try populatedPreB5()
        // READ ONLY THE COLUMNS THAT EXIST YET. `gearRows` names `kind`, and
        // asking a pre-B5 database for it is a fixture error dressed as a
        // failure — the point of the "before" snapshot is the old shape.
        let before = try queue.read { d in
            try Row.fetchAll(d, sql: "SELECT name FROM gear ORDER BY externalID")
                .map { $0["name"] as String? }
        }
        #expect(before.count == 3)

        try Sub4Migrations.migrator.migrate(queue)

        let after = try gearRows(queue)
        #expect(after.count == 3, "the upgrade lost rows")
        #expect(after.map { $0["name"] as String? } == before)
        #expect(after.map { $0["distanceM"] as Double? }
                == [4_000_000, 534_000, 812_000],
                "a distance moved across the upgrade")
    }

    /// **`unknown`, NOT `shoe` — §12.175.4.** Two of these three genuinely ARE
    /// shoes and the default would have been right for them, which is exactly
    /// what makes guessing dangerous rather than merely wrong.
    @Test("Every upgraded row reads unknown and not retired")
    func theDefaultsAreHonest() throws {
        let queue = try populatedPreB5()
        try Sub4Migrations.migrator.migrate(queue)

        for row in try gearRows(queue) {
            #expect(row["kind"] as String? == "unknown",
                    "the migration invented a kind for a row written without one")
            #expect(row["isRetired"] as Bool? == false)
            #expect(row["retiredUTC"] as String? == nil)
        }
    }

    @Test("The upgraded schema is the current one")
    func theSchemaLandsComplete() throws {
        let queue = try populatedPreB5()
        let partial = try queue.read { d in
            try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(!partial.contains(Sub4Migrations.gearKind),
                "the fixture is not a pre-B5 database")
        #expect(!partial.contains(Sub4Migrations.gearRetired))

        try Sub4Migrations.migrator.migrate(queue)
        let applied = try queue.read { d in
            try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(Set(applied) == Set(Sub4Migrations.all),
                "the upgraded database is not at the current schema")
    }

    /// The upgrade must not disturb what it does not own. `activity_gear_reference`
    /// is the join `retiredUTC` is derived through, and a rebuild of `gear`
    /// would be the likeliest thing to take it with it.
    @Test("The upgrade touches nothing but gear")
    func nothingElseMoves() throws {
        let queue = try populatedPreB5()
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO source (id, label) VALUES ('s-x', 'a second source')
                """)
        }
        let before = try queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM source") ?? -1
        }
        try Sub4Migrations.migrator.migrate(queue)
        let after = try queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM source") ?? -1
        }
        #expect(after == before)
    }

    // MARK: And then reconciliation supplies the facts

    /// **THE SECOND MOMENT, AND THE ONE THE DEVICE LIVED THROUGH.** After the
    /// upgrade the rows are honestly ignorant; the first import from a store
    /// that knows is what corrects them. §12.176.6 predicted `gearRefreshed`
    /// would be large exactly once, and the phone reported 11 on 21 August.
    @Test("The first import after the upgrade supplies kind and retirement")
    func reconciliationCorrectsTheDefaults() throws {
        let queue = try populatedPreB5()
        try Sub4Migrations.migrator.migrate(queue)
        let db = Sub4Database(queue: queue, location: .inMemory)

        let report = try Sub4Import.run(into: db, activities: [], shoes: [
            AthleteStore.Shoe(id: "g14536649", name: "Novablast",
                              distanceM: 534_000, primary: false,
                              kind: .shoe, retired: false),
            AthleteStore.Shoe(id: "b6932581", name: "Gravel bike",
                              distanceM: 4_000_000, primary: false,
                              kind: .bike, retired: false),
            AthleteStore.Shoe(id: "g99999999", name: "Old pair",
                              distanceM: 812_000, primary: false,
                              kind: .unknown, retired: true)])

        // Nothing new: these are the same three rows, corrected in place.
        #expect(report.gearInserted == 0, "the upgrade's rows were not recognised")
        #expect(report.gearAlreadyPresent == 3)
        #expect(report.gearRefreshed == 3, "the honest defaults were left standing")

        let rows = try gearRows(queue)
        #expect(rows.map { $0["kind"] as String? } == ["bike", "shoe", "unknown"])
        #expect(rows.map { $0["isRetired"] as Bool? } == [false, false, true])
        // Retired, and no activity in this database names it, so the date is
        // unknown and `isRetired` is what carries the fact — §12.176.2.
        #expect(report.gearRetirementUndated == 1)
        #expect(rows.last?["retiredUTC"] as String? == nil)
    }
}
