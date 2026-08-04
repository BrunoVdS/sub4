//
//  Sub4Migrations+Inputs.swift
//  Sub4
//
//  The five activity columns 3.2 did not build — patch 217, plan step 3.3,
//  ADR-0003 §12.3.
//
//  WHY THIS MIGRATION EXISTS AT ALL
//  --------------------------------
//  §12 was written before the importer, and writing it found that
//  `activities.json` holds five fields with no column anywhere in the
//  thirty-one tables 3.2 built: `gearId`, `averageWatts`, `deviceWatts`,
//  `isTrainer`, `maxSpeed`.
//
//  None of them is decorative. `deviceWatts` and `isTrainer` feed `PowerLoad`
//  and through it `TrainingLoad` — the CTL/ATL/TSB model this whole app is
//  about. A cutover without them would have moved the load model onto data
//  missing its power inputs and NOTHING WOULD HAVE LOOKED BROKEN: the curve
//  would simply have been different, quietly, for reasons nobody could trace
//  three weeks later. `isTrainer` also drives `isOutdoor`, which is what stops
//  the app asking for weather on an indoor session.
//
//  That is the failure §12 exists to catch, and it caught it before a row was
//  written rather than after.
//
//  A SEPARATE MIGRATION, NOT AN EDIT TO THE DOMAIN ONE
//  ---------------------------------------------------
//  `2026-08-04-domain` has run on a real phone. A shipped migration is history
//  and is never edited — editing it would give a fresh install a different
//  database from an existing one under the same identifier, which is the trap
//  recorded in §11 about seeding from a live enum. This is additive and new.
//
//  NAMED FOR WHAT THEY MEAN, NOT FOR WHAT STRAVA CALLS THEM
//  --------------------------------------------------------
//  `device_watts` becomes `hasPowerMeter`; `trainer` becomes `isIndoor`. The
//  database is source-neutral by §3, and a column named after one provider's
//  JSON key is a small piece of that provider embedded in the schema. When
//  Apple Health arrives at 4A it will have its own words for both.
//
//  WHY THESE CHECKS ARE LOOSER THAN §7's
//  -------------------------------------
//  `distanceM` and `elapsedSeconds` carry UPPER bounds because the August 2025
//  artifact — 199 km in 694,865 seconds — was a session that was wrong. The
//  bound rejects a row that is not a real training session.
//
//  `maxSpeedMS` and `averageWatts` get no upper bound, deliberately. A GPS
//  spike in max speed does not make the run untrue, and a CHECK that refuses it
//  would cost the whole activity: the insert fails, the row lands in
//  `rejection`, and a real session disappears over a field nobody reads
//  closely. The bound is only worth having where the suspect value IS the
//  session being wrong.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let activityInputs = "2026-08-05-activity-inputs"

    nonisolated static func registerActivityInputs(_ m: inout DatabaseMigrator) {
        m.registerMigration(activityInputs) { db in

            try db.alter(table: "activity") { t in

                // The canonical gear id, NOT Strava's — §3.1 and §12.3.
                // `gear` mints its own ids and keeps the provider's in
                // `externalID`, so the importer has to resolve
                // (sourceID, externalID) → gear.id before it can write this,
                // which means gear imports BEFORE activities or every value
                // here lands null.
                //
                // SET NULL rather than CASCADE: retiring a pair of shoes must
                // not delete the runs done in them.
                t.add(column: "gearID", .text)
                    .references("gear", onDelete: .setNull)

                // Only ever from a meter. Strava's estimate for a ride without
                // one is a model output, and storing it beside real readings
                // would make the two indistinguishable a year from now.
                t.add(column: "averageWatts", .double)
                    .check(sql: "averageWatts IS NULL OR averageWatts > 0")

                // Nullable on purpose — §6. An activity from before the app
                // recorded this has NO ANSWER, which is not the same as "no
                // power meter". `PowerLoad` must be able to tell those apart.
                t.add(column: "hasPowerMeter", .boolean)

                // Likewise. Absent is not "outdoors": `Weather` uses this to
                // decide whether to ask for conditions at all, and guessing
                // false would send it looking for the weather in a gym.
                t.add(column: "isIndoor", .boolean)

                t.add(column: "maxSpeedMS", .double)
                    .check(sql: "maxSpeedMS IS NULL OR maxSpeedMS >= 0")
            }

            // Gear attribution is a per-session question — "which shoes was
            // this run in" — and after the cutover it is answered by a join
            // rather than by a dictionary lookup in `AthleteStore`.
            try db.create(index: "activity_on_gear", on: "activity",
                          columns: ["gearID"])
        }
    }
}
