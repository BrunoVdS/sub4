//
//  Sub4Migrations+ZoneFloorZero.swift
//  Sub4
//
//  The bottom zone starts at zero — patch 236, ADR-0003 §12.10.2.
//
//  WHY THIS IS A SECOND MIGRATION AND NOT AN EDIT
//  ----------------------------------------------
//  Because the edit was tried, and it failed in the way the rule predicts.
//
//  `2026-08-07-open-top-zone` built `hr_zone` with `minBpm > 0`. Patch 229
//  changed that line to `>= 0` in place, on the stated grounds that the
//  migration had never run against a persistent database. That was an
//  inference, not a check, and it was wrong: the app had already been launched
//  on the device from Xcode while patch 228 was installed. GRDB had recorded
//  the identifier, so the edited body never ran again anywhere.
//
//  What that looked like: eight tests asserting the bottom zone stores a floor
//  of zero, all green, on every run — because each builds a fresh in-memory
//  database from the current source. And on the phone, all five zones refused
//  with `CHECK constraint failed: minBpm > 0`, `hr_zone` at 0 rows, and a
//  screen reporting `Heart-rate zones: 0 of 5`.
//
//  A green suite cannot see this class of defect. The suite tests the schema
//  the source describes; a device holds the schema its migration history
//  built. They are the same thing only if no migration body has ever been
//  edited after running — which is what the rule is for.
//
//  WHAT IS WRONG WITH `> 0`
//  ------------------------
//  `AthleteStore.HRZone.range` states it: "The bottom zone starts at zero, and
//  '0–115 bpm' is a range whose lower bound describes being dead." Strava
//  returns Z1 as `min: 0`. A floor of zero is a real number the app holds and
//  prints, so the constraint admits it rather than the data being bent to fit.
//
//  `>= 0` and not a nullable column: a nil ceiling means "no upper bound" and
//  is a distinction `HRZone` makes; a nil floor is not, because `min` is not
//  optional there.
//
//  STILL SAFE TO DROP
//  ------------------
//  `hr_zone` holds 0 rows on the one device that has this schema — verified on
//  the health screen after the import that produced the refusal, not assumed.
//  Nothing has ever successfully written it, which is the whole point.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let zoneFloorZero = "2026-08-08-zone-floor-zero"

    nonisolated static func registerZoneFloorZero(_ m: inout DatabaseMigrator) {
        m.registerMigration(zoneFloorZero) { db in

            try db.drop(table: "hr_zone")
            try db.create(table: "hr_zone") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")

                // THE CHANGE, and the only one. Everything else below is
                // carried over from `2026-08-07-open-top-zone` unaltered.
                t.column("minBpm", .integer).notNull().check(sql: "minBpm >= 0")

                t.column("maxBpm", .integer)
                t.check(sql: "maxBpm IS NULL OR maxBpm >= minBpm")

                t.uniqueKey(["accountID", "ordinal"])
            }
        }
    }
}
