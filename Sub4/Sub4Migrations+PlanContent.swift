//
//  Sub4Migrations+PlanContent.swift
//  Sub4
//
//  Everything in plan.json that had nowhere to go — patch 237, ADR-0003 §12.11.
//
//  WHAT §8 BUILT AND WHAT plan.json ACTUALLY HOLDS
//  -----------------------------------------------
//  `plan`, `plan_version`, `plan_week`, `plan_session` and `plan_exercise` were
//  written from §8's prose. Read against `Models.swift`, `Fuel.swift` and
//  `Warmup.swift`, four things in the file have no column anywhere:
//
//    Week.stats            37 weeks × 5 figures. The SOURCE DOCUMENT's own
//                          weekly totals — runs, ride, swims, km, h.
//    Session.swimDetail    26 swim sessions.
//    Session.strengthDetail 56 strength sessions.
//                          Together 82 sessions and 634 blocks: the entire
//                          prescription of every swim and strength session.
//                          `plan_session.detail` holds the one-line summary
//                          from the week card and nothing else.
//    Plan.fuel             3 products, 7 per-session targets, a 5-step ladder,
//                          a caution, and the race-day schema.
//    Plan.warmup           9 timeline steps, 7 circuit movements, 4 weather
//                          conditions, a caution.
//
//  Fifth mapping written before an importer, and the fifth to find missing
//  schema. The pattern is stable enough to state plainly: a schema written from
//  prose describes what the prose thought was there. Reading it against the
//  TYPE is what finds the rest.
//
//  WHY THE WEEK STATS ARE STORED WHEN THE APP COMPUTES ITS OWN
//  -----------------------------------------------------------
//  `PlanStore.plannedVolume` derives weekly volume from the sessions. These are
//  the numbers the plan DOCUMENT claims for the same week. They are not
//  redundant: holding both is what makes disagreement between them visible, and
//  a plan whose stated 42 km week contains 38 km of sessions is worth knowing
//  about. Stored as key/value because the set of keys is the document's, not
//  this app's — a column per statistic would freeze a vocabulary that belongs
//  to a file that gets replaced.
//
//  WHY FUEL AND WARM-UP GET REAL COLUMNS RATHER THAN A BLOB
//  --------------------------------------------------------
//  Both are ordered lists of short labelled strings, and the lazy shape is one
//  generic table with columns called c1…c4. That stores the data and destroys
//  the meaning: a column named `c2` cannot be read six months later without the
//  code that wrote it. Every field below is named after the field it holds,
//  which costs eight small tables and buys a database that explains itself.
//
//  ORDINALS EVERYWHERE, BECAUSE ORDER IS CONTENT
//  ----------------------------------------------
//  A warm-up timeline out of order is a different warm-up. A fuelling ladder
//  out of order is wrong advice. None of these lists carry a key of their own —
//  `Fuel.Product.id` is its name, which is a display convenience, not an
//  identity — so position is the only thing that preserves them, and it is
//  stored rather than left to the order rows happen to come back in.
//
//  ALL FOREIGN KEYS CASCADE FROM `plan_version`
//  ---------------------------------------------
//  A plan version is one immutable object: the bundle is replaced wholesale on
//  app update and a new version row is written. Deleting a version has to take
//  its entire content with it, or the next import inherits half of a plan that
//  no longer exists. `plan_session_block` cascades through
//  `plan_session_detail`, which cascades through `plan_session`.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let planContent = "2026-08-09-plan-content"

    /// The two shapes a session breakdown comes in. FROZEN, like every other
    /// vocabulary inside a migration — `Session.swimDetail` and
    /// `strengthDetail` are separate fields on the type, and this is the column
    /// that records which one a row came from.
    nonisolated static let planDetailKinds = ["swim", "strength"]

    nonisolated static func registerPlanContent(_ m: inout DatabaseMigrator) {
        m.registerMigration(planContent) { db in

            // MARK: The document's own weekly totals

            try db.create(table: "plan_week_stat") { t in
                t.primaryKey("id", .text)
                t.column("planWeekID", .text).notNull()
                    .references("plan_week", onDelete: .cascade)
                t.column("key", .text).notNull()
                // REAL, not INTEGER: the plan writes 8.0 hours and 42.0 km, and
                // `Week.stats` is `[String: Double]`. Narrowing here would make
                // a half-hour week unrepresentable.
                t.column("value", .double).notNull()
                t.uniqueKey(["planWeekID", "key"])
            }

            // MARK: What a swim or strength session actually is

            try db.create(table: "plan_session_detail") { t in
                t.primaryKey("id", .text)
                // Unique: a session has at most one breakdown. `Session.breakdown`
                // returns `swimDetail ?? strengthDetail`, so two would mean one
                // is unreachable in the app and present in the database.
                t.column("planSessionID", .text).notNull().unique()
                    .references("plan_session", onDelete: .cascade)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN (\(quoted(planDetailKinds)))")
                t.column("total", .text)
                t.column("tag", .text)
                t.column("focus", .text)
            }

            try db.create(table: "plan_session_block") { t in
                t.primaryKey("id", .text)
                t.column("planSessionDetailID", .text).notNull()
                    .references("plan_session_detail", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                // `Block`'s fields are `d`, `t`, `x`, `u` in the JSON — one
                // letter each because the extractor writes them 634 times. The
                // database is read by people, so they get their names back.
                t.column("duration", .text)
                t.column("title", .text)
                t.column("cue", .text)
                t.column("videoURL", .text)
                t.uniqueKey(["planSessionDetailID", "ordinal"])
            }

            // MARK: Fuelling — section 09

            try db.create(table: "plan_fuel") { t in
                t.primaryKey("id", .text)
                t.column("planVersionID", .text).notNull().unique()
                    .references("plan_version", onDelete: .cascade)
                t.column("intro", .text)
                t.column("timingRule", .text)
                t.column("cautionTag", .text)
                t.column("cautionText", .text)
                // The race-day schema is a single object on `Fuel.RaceDay`, so
                // its scalars live here rather than in a one-row table of their
                // own. Its two LISTS get tables below.
                t.column("raceIntro", .text)
                t.column("raceTotals", .text)
                t.column("raceHydration", .text)
                t.column("racePacing", .text)
                t.column("raceCautionTag", .text)
                t.column("raceCautionText", .text)
            }

            try db.create(table: "plan_fuel_product") { t in
                t.primaryKey("id", .text)
                t.column("planFuelID", .text).notNull()
                    .references("plan_fuel", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("name", .text)
                t.column("carbs", .text)
                t.column("caffeine", .text)
                t.column("use", .text)
                t.uniqueKey(["planFuelID", "ordinal"])
            }

            try db.create(table: "plan_fuel_target") { t in
                t.primaryKey("id", .text)
                t.column("planFuelID", .text).notNull()
                    .references("plan_fuel", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("session", .text)
                t.column("target", .text)
                t.column("take", .text)
                t.uniqueKey(["planFuelID", "ordinal"])
            }

            try db.create(table: "plan_fuel_ladder") { t in
                t.primaryKey("id", .text)
                t.column("planFuelID", .text).notNull()
                    .references("plan_fuel", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("run", .text)
                t.column("carbs", .text)
                t.column("take", .text)
                t.uniqueKey(["planFuelID", "ordinal"])
            }

            /// `RaceDay.before` is `[String]` — carb-load, the day before,
            /// breakfast, the gel at −15 min. A list of plain lines, so one
            /// column and an ordinal.
            try db.create(table: "plan_fuel_race_before") { t in
                t.primaryKey("id", .text)
                t.column("planFuelID", .text).notNull()
                    .references("plan_fuel", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("text", .text).notNull()
                t.uniqueKey(["planFuelID", "ordinal"])
            }

            try db.create(table: "plan_fuel_race_step") { t in
                t.primaryKey("id", .text)
                t.column("planFuelID", .text).notNull()
                    .references("plan_fuel", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("time", .text)
                t.column("dist", .text)
                t.column("take", .text)
                t.column("total", .text)
                t.uniqueKey(["planFuelID", "ordinal"])
            }

            // MARK: The warm-up — section 10b

            try db.create(table: "plan_warmup") { t in
                t.primaryKey("id", .text)
                t.column("planVersionID", .text).notNull().unique()
                    .references("plan_version", onDelete: .cascade)
                t.column("intro", .text)
                t.column("circuitNote", .text)
                t.column("cautionTag", .text)
                t.column("cautionText", .text)
            }

            try db.create(table: "plan_warmup_step") { t in
                t.primaryKey("id", .text)
                t.column("planWarmupID", .text).notNull()
                    .references("plan_warmup", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("time", .text)
                t.column("action", .text)
                t.column("detail", .text)
                t.uniqueKey(["planWarmupID", "ordinal"])
            }

            try db.create(table: "plan_warmup_movement") { t in
                t.primaryKey("id", .text)
                t.column("planWarmupID", .text).notNull()
                    .references("plan_warmup", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("movement", .text)
                t.column("dose", .text)
                t.uniqueKey(["planWarmupID", "ordinal"])
            }

            try db.create(table: "plan_warmup_condition") { t in
                t.primaryKey("id", .text)
                t.column("planWarmupID", .text).notNull()
                    .references("plan_warmup", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("condition", .text)
                t.column("what", .text)
                t.uniqueKey(["planWarmupID", "ordinal"])
            }
        }
    }
}
