//
//  Sub4Migrations+OpenTopZone.swift
//  Sub4
//
//  The top zone has no ceiling — patch 228, ADR-0003 §12.10.
//
//  TWO DEFECTS, ONE AT EACH END OF THE ZONE SET
//  --------------------------------------------
//  The second was found by the first one's test failing: `minBpm > 0` refuses
//  the BOTTOM zone, which starts at zero. `HRZone.range` says so in its own
//  comment — "The bottom zone starts at zero, and '0–115 bpm' is a range whose
//  lower bound describes being dead" — and Strava returns Z1 as `min: 0`.
//
//  So of five zones the schema would have taken three. Z1 refused for starting
//  at zero, Z5 refused for having no ceiling, and Z2–Z4 imported: a zone set
//  missing both ends, which `zone(forHR:)` would answer from without complaint
//  for every heart rate below 116 or above 172.
//
//  The importer writes the set inside one savepoint, so in practice the whole
//  set was refused rather than three-fifths of it landing. That was a guess
//  when it was written and is now a measured fact: the test asserting five
//  zones reported zero, not three.
//
//  THE FLOOR IS NOT FIXED IN THIS MIGRATION. It was, briefly and wrongly — see
//  the note further down — and the correction now lives in
//  `2026-08-08-zone-floor-zero`.
//
//  THE FIRST DEFECT
//  ----------------
//  `hr_zone.maxBpm` was built NOT NULL. `AthleteStore.HRZone.max` is `Int?`,
//  and the comment beside it says what the nil means:
//
//      let max: Int?           // nil = open-ended top zone
//
//  Strava returns the top zone as `min: 168, max: -1`, and the app models that
//  absence honestly. The schema cannot hold it. So of five zones, Z1–Z4 would
//  import and Z5 would be refused by a NOT NULL constraint — the one zone every
//  hard session finishes in, and the one `topZoneFloor` reads to sanity-check
//  the observed maximum.
//
//  Found by writing §12.10 against `HRZone` before writing the importer, which
//  is now four for four: activity inputs, gear references, proposal changes,
//  and this. The schema was written from §8's prose; the prose said "zone
//  boundaries" and the type says one of them is missing on purpose.
//
//  WHY A SENTINEL WAS NOT USED
//  ---------------------------
//  220, or 250, or any number meaning "no ceiling" would satisfy the column and
//  put a lie in it. Every query asking "which zone contains 205 bpm" would then
//  get a defensible answer from a value nobody measured, and there would be no
//  way afterwards to tell a real ceiling from the placeholder. NULL is the
//  correct representation of an absent bound, and the CHECK is rewritten to
//  admit it rather than the data being bent to fit.
//
//  WHY THE TABLE IS DROPPED RATHER THAN ALTERED
//  --------------------------------------------
//  SQLite cannot relax NOT NULL on an existing column; the shape has to be
//  rebuilt. Same call as `proposal_change` in 225, and safe for the same
//  reason: `hr_zone` has never held a row on any device. Nothing in the app
//  writes it — this patch's importer is the first thing that ever will — so
//  there is nothing to copy across. If it had held rows the honest path is the
//  twelve-step ALTER, and the difference is worth stating rather than assuming.
//
//  THIS BODY WAS EDITED AFTER IT HAD ALREADY RUN. THAT WAS A MISTAKE.
//  ------------------------------------------------------------------
//  Patch 229 changed `minBpm > 0` to `>= 0` in place, on the stated grounds
//  that this migration had never been applied to a persistent database —
//  "checked before editing rather than assumed". It was not checked. It was
//  inferred from the fact that only tests had been run, and the inference was
//  wrong: the app had been launched from Xcode on the device while patch 228
//  was installed. That launch applied this migration with `> 0` and recorded
//  the identifier, so every later edit to this file was dead code on that
//  phone while the test suite — which builds a fresh in-memory database every
//  time — went on passing.
//
//  The visible cost: `hr_zone` refused all five zones on the device with
//  `CHECK constraint failed: minBpm > 0` while eight tests asserting the
//  opposite were green.
//
//  The line is now restored to what actually ran, and the fix lives in
//  `2026-08-08-zone-floor-zero`. Two devices must not hold two different
//  schemas under one identifier.
//
//  `ordinal` IS STRAVA'S ZONE NUMBER, 1…5
//  --------------------------------------
//  Not an array index. `HRZone.index` is 1-based and every label in the app
//  reads "Z\(index)", so storing a 0-based ordinal here would make the database
//  disagree with every screen by one. The CHECK stays `ordinal >= 0` — it is
//  the migration's frozen text and 1…5 satisfies it.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let openTopZone = "2026-08-07-open-top-zone"

    nonisolated static func registerOpenTopZone(_ m: inout DatabaseMigrator) {
        m.registerMigration(openTopZone) { db in

            try db.drop(table: "hr_zone")
            try db.create(table: "hr_zone") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")

                // `> 0`, WHICH IS WRONG, AND STAYS WRONG. Z1 starts at zero,
                // so this refuses the bottom zone — see
                // `Sub4Migrations+ZoneFloorZero.swift`, which fixes it.
                //
                // Restored to the text that actually ran. Patch 229 edited
                // this line in place on the belief that the migration had
                // never touched a persistent database. It had: the app was
                // launched from Xcode on patch 228 before 229 was written.
                // A migration body that differs from what ran gives two
                // devices two different schemas under one identifier, which
                // is the exact failure the never-edit rule exists to prevent.
                t.column("minBpm", .integer).notNull().check(sql: "minBpm > 0")

                // THE CHANGE. Nullable, and the table-level CHECK below admits
                // the nil rather than comparing against it — `maxBpm >= minBpm`
                // alone evaluates to NULL for the top zone, which SQLite treats
                // as a pass, but only by accident. Stating it is the difference
                // between a constraint that works and one that happens to.
                t.column("maxBpm", .integer)
                t.check(sql: "maxBpm IS NULL OR maxBpm >= minBpm")

                t.uniqueKey(["accountID", "ordinal"])
            }
        }
    }
}
