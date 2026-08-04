//
//  Sub4Migrations+GearReference.swift
//  Sub4
//
//  Where an unresolved gear reference lives — patch 223, ADR-0003 §3.1 and §12.6.
//
//  WHAT THE FIRST REAL IMPORT SHOWED
//  ---------------------------------
//  662 activities imported. 404 named gear `AthleteStore` does not hold, and
//  patch 221 made the report say which:
//
//      b6932581    284 activities
//      b13458344    60
//      g15316986    51
//      b10348095     9
//
//  Three bikes and one shoe. `AthleteStore` decodes only the `shoes` array from
//  Strava's `/athlete`, so bike gear has never existed in this app; and
//  `/athlete` returns only ACTIVE gear, so a retired pair — g15316986, 51 runs —
//  cannot be resolved from the profile at all.
//
//  `activities.json` holds `gearId` for all 404 and the database held NULL: a
//  field present in the source and absent after the cutover, which is the exact
//  failure §12 exists to prevent.
//
//  WHY A TABLE AND NOT A COLUMN — AND THE TEST THAT SETTLED IT
//  -----------------------------------------------------------
//  The first attempt (patch 222) added `activity.gearExternalID`, reasoning
//  that `sportLabel` already keeps a raw value beside a mapped one.
//  `IdentityTests.noExternalIDOnTheActivity` refused it: no column on `activity`
//  may have "external" in its name, because §3.1 says an external identifier
//  lives in exactly one kind of place and the canonical activity is not it.
//
//  The guard was right and the reasoning behind the column was not. "It is only
//  a reference to another entity" is the same argument that would justify
//  `stravaActivityID` on `activity`; the rule holds because every exception to
//  it sounds reasonable.
//
//  So this mirrors `activity_alias`, which exists for precisely this shape:
//  external identifiers live in their own table, pointing at the canonical row.
//
//  WRITTEN WHETHER OR NOT IT RESOLVES
//  ----------------------------------
//  Not a "pending" list. This is the record of what the source said, and it
//  stays true after the gear is known — the same way `activity_source_record`
//  keeps Strava's activity id after the canonical id exists. `activity.gearID`
//  answers "which gear row is this"; this table answers "what did the source
//  call it", and only the second survives a source that has forgotten.
//
//  THIS MIGRATION IDENTIFIER WAS REUSED, DELIBERATELY
//  --------------------------------------------------
//  Patch 222 shipped `2026-08-05-gear-reference` as an ALTER TABLE. It never
//  ran against a persistent database — the test suite failed before the app was
//  built, so the only databases that applied it were the in-memory ones inside
//  the test runner, which are discarded. Rewriting the body is therefore safe
//  and leaves no device holding a column nothing references.
//
//  Had it reached the phone, this would have had to be a NEW migration that
//  dropped the column, because a migration that has run against real data is
//  history. The check before installing was the migration count on the health
//  screen: three, not four.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let gearReference = "2026-08-05-gear-reference"

    nonisolated static func registerGearReference(_ m: inout DatabaseMigrator) {
        m.registerMigration(gearReference) { db in

            try db.create(table: "activity_gear_reference") { t in
                t.primaryKey("id", .text)

                // CASCADE: the reference is a property of the activity and has
                // no meaning without it.
                t.column("activityID", .text).notNull()
                    .references("activity", onDelete: .cascade)

                // RESTRICT, matching `gear` and `activity_source_record`: a
                // source cannot be deleted while records still name it.
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)

                // No foreign key to `gear`, and that is the entire point — this
                // records a name the source used, which may match no row here
                // and may never match one.
                t.column("externalID", .text).notNull()

                t.column("notedUTC", .text).notNull()
            }

            // One gear per activity per source. Strava gives an activity a
            // single `gear_id`; a second row for the same pair would mean the
            // import wrote twice rather than that the athlete wore two pairs.
            try db.create(index: "activity_gear_reference_unique",
                          on: "activity_gear_reference",
                          columns: ["activityID", "sourceID"], unique: true)

            // "Which activities used b6932581" — the question that produced
            // this table, and the one asked when the bikes are eventually
            // fetched and the references become resolvable.
            try db.create(index: "activity_gear_reference_on_external",
                          on: "activity_gear_reference",
                          columns: ["sourceID", "externalID"])
        }
    }
}
