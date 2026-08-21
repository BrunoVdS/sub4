//
//  Sub4Migrations+GearKind.swift
//  Sub4
//
//  What a piece of gear IS, and the day it was last used — patch 425,
//  ADR-0003 §12.175, D7 slice B5.
//
//  THE FACT WAS NEVER DISCARDED. IT WAS NEVER TOLD.
//  ------------------------------------------------
//  `AthleteStore` keeps three arrays — `shoes`, `bikes`, `retired` — and the
//  kind of a piece of gear IS which array it is in. `AppStores` then sets
//  `s.gear = AthleteStore.shared.allGear`, which is `shoes + bikes + retired`,
//  and hands that to `importGear`. **By the time the importer runs, the fact
//  has already been flattened away.** The importer names six columns and none
//  of them could have carried it.
//
//  AND BECAUSE BOTH SIDES OF THE ROUND TRIP SEE THE FLAT LIST, NOTHING
//  DISAGREED. `WeatherGearRoundTrip` compares two fields per item — the name
//  and the distance — and its `approved` list records `Shoe.primary` and
//  `gear.retiredUTC` as known gaps. There is no entry for the kind, because a
//  difference that cannot be expressed appears on no list. §12.132's shape in a
//  comparison rather than in a category.
//
//  WHY IT HAS TO BE NOW
//  --------------------
//  §12.68 already made this argument for one field: ADR-0002 retires Strava,
//  and whatever is in `gear.distanceM` on that day is the mileage FOR EVER,
//  because there is no second copy to reconcile against afterwards. Patch 325
//  fixed distance for exactly that reason.
//
//  **The athlete endpoint is the only thing that has ever said which gear is a
//  bike.** It is free today and unrecoverable later.
//
//  THREE VALUES, AND THE THIRD IS NOT A TIDY-UP
//  --------------------------------------------
//  `unknown` exists because retirement is INFERRED rather than reported.
//  `AthleteStore.resolveRetiredGear` finds gear ids that activities name and
//  the profile no longer holds, then fetches each one — and `fetchGear`'s
//  `DetailedGear` decodes `id`, `name`, `distance` and `primary`, with **no
//  type**. So a retired bike arrives indistinguishable from a retired shoe.
//
//  Guessing `shoe` there would put `Shoe.wear`'s 600/800 km running thresholds
//  on a bicycle. A category defined as "not the other one" swallows something
//  that is neither (§12.132); this is the third bucket, and it is printed.
//
//  THE DEFAULT IS `unknown` AND NOT `shoe`
//  ---------------------------------------
//  Every row already in this table was written without the fact. `unknown` is
//  what that is. Defaulting to `shoe` would invent complete confidence about a
//  past nothing recorded — and it would be right for most rows, which is what
//  makes it dangerous rather than merely wrong.
//
//  `retiredUTC` — WHAT IT HOLDS, WRITTEN DOWN
//  ------------------------------------------
//  The column has existed since patch 205 and the importer has never written
//  it. Strava reports no retirement date and there is no reason to think one
//  exists: gear stops being listed, and that is all that ever happens.
//
//  So the value is **the day the gear was last used** — the newest activity
//  naming it — and non-null means retired. That is a real fact derived from
//  data this app owns, rather than a timestamp recording when the app happened
//  to look, which is what "the day we noticed" would be (§12.15 as a date).
//
//  **It is a definition and not an inference from the name**, which is why it
//  is written here, in the migration, where it cannot drift from the column.
//

import GRDB

extension Sub4Migrations {

    nonisolated static let gearKind = "2026-08-21-gear-kind"

    /// The frozen vocabulary. A migration is history and this literal can never
    /// be edited — `GearKind` is coupled to it by test, exactly as
    /// `WorkQueueTests.theFrozenStatesStillMatchTheSchema` couples
    /// `work_queue.state`. CLAUDE.md's rule, and the only way the assertion can
    /// run: the enum must still say what the schema was born saying.
    nonisolated static let gearKinds = ["shoe", "bike", "unknown"]

    nonisolated static func registerGearKind(_ m: inout DatabaseMigrator) {
        m.registerMigration(gearKind) { db in
            // ADDITIVE, and both columns land on a table that already exists.
            // Nothing already applied is edited — §12.1.
            try db.alter(table: "gear") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "unknown")
            }
            // A CHECK cannot be added by ALTER in SQLite, and rebuilding the
            // table to get one would rewrite history for a constraint. The
            // vocabulary is held by `theFrozenGearKindsMatchTheSchema` instead,
            // which is where `work_queue`'s would have to live too if its
            // CHECK had not been there from the start.
            //
            // SAID PLAINLY BECAUSE IT IS A REAL DIFFERENCE: `work_queue.state`
            // is enforced by the database and this is enforced by a test.
        }
    }
}
