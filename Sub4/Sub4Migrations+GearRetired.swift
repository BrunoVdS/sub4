//
//  Sub4Migrations+GearRetired.swift
//  Sub4
//
//  WHETHER, beside WHEN — patch 426, ADR-0003 §12.176, D7 slice B5.
//
//  425 ADDED HALF THE MAPPING AND THIS IS THE OTHER HALF.
//  ------------------------------------------------------
//  425 gave `gear` a `kind`, on the finding that the kind is which of
//  `shoes`/`bikes`/`retired` an item sits in and that `allGear` flattens it
//  away before the importer is reached. **Retirement is flattened by exactly
//  the same line and 425 did not carry it.** A `Shoe` in the `retired` array
//  arrives at `importGear` indistinguishable from one in `shoes`.
//
//  A NEW MIGRATION RATHER THAN AN EDIT TO `2026-08-21-gear-kind`, because a
//  migration is history and 425 is committed. CLAUDE.md's rule has no
//  exception for "it has probably not run yet".
//
//  WHY A BOOLEAN WHEN THERE IS ALREADY A DATE
//  ------------------------------------------
//  `retiredUTC` has existed since patch 205 and B5's decision 3 gives it a
//  meaning: **the newest activity naming this gear.** It is derived, and that
//  is what makes it insufficient on its own.
//
//  1. **A DERIVED DATE CAN BE UNKNOWN.** Retired gear with no surviving
//     activity yields no maximum. If the date were the only marker, "retired,
//     last use unknown" and "not retired" would be the same NULL — §12.15,
//     and this project has paid for that collision at §12.15, §12.54.2,
//     §12.153.9 and §12.155.
//
//  2. **AND A DERIVED VALUE IS RECOMPUTED.** `Sub4Import.run(activities: [])`
//     is a real call — the authored write-through uses it — and the date's
//     query would find no activities and write NULL over a value that was
//     correct. **A fact would be destroyed by an import that was not about
//     gear at all.** `isRetired` is stated rather than derived, so it cannot
//     be recomputed away, and the date update is additionally forbidden from
//     overwriting a known value with an unknown one.
//
//  WHETHER and WHEN come apart, so they are two columns. That is not
//  redundancy; it is the difference between a fact and a measurement of it.
//
//  THE DEFAULT IS 0, AND THAT ONE IS SAFE
//  --------------------------------------
//  Unlike `kind`, where every existing row genuinely lacked the fact and
//  `unknown` was the only honest default, "not retired" IS what an unmarked row
//  means: the importer has only ever been handed gear the athlete holds, and
//  before `retired` was appended to `allGear` at patch 268 it could not have
//  written a retired item at all. Rows written since then get corrected on the
//  next import, because the refresh compares this column like any other.
//

import GRDB

extension Sub4Migrations {

    nonisolated static let gearRetired = "2026-08-21-gear-retired"

    nonisolated static func registerGearRetired(_ m: inout DatabaseMigrator) {
        m.registerMigration(gearRetired) { db in
            try db.alter(table: "gear") { t in
                t.add(column: "isRetired", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
