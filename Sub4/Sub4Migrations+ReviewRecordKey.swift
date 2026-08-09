//
//  Sub4Migrations+ReviewRecordKey.swift
//  Sub4
//
//  A review gets the app's own identity — patch 337, ADR-0003 §12.85.
//
//  WHAT WENT WRONG, AND HOW IT WAS FOUND
//  -------------------------------------
//  Patch 327 chose `(accountID, ranUTC)` as the handle the importer looks a
//  review up by, and wrote the reason down as an approved difference:
//
//      "the app keys a review by window label and run count; the database
//       mints a UUID and keys on (accountID, ranUTC). No column, and none is
//       wanted — patch 327."
//
//  On 9 August 2026 the rehearsal wrote six review records and two of them
//  carried the same `ranAt` to the second. The importer found the first row
//  when it looked up the sixth record, took the UPDATE branch, and replaced
//  that row's evidence, proposal, changes and watch items with the sixth
//  record's. Nothing errored. The diagnostics paste said `review: 5` beside
//  six records in the app, and the only reason anybody noticed is that
//  `ReviewRoundTrip` had been built to REPORT a run-time collision rather than
//  resolve it — `duplicateRunTimes`, patch 327, written for exactly this and
//  never fired until now.
//
//  So the approved difference was wrong, and the way it was wrong is the
//  ordinary way: `ranUTC` is a fact ABOUT a review, and it was being asked to
//  BE the review. One second of resolution is enough to hold that job right up
//  until it is not.
//
//  WHY THIS MATTERS MORE THAN THE SIX RECORDS
//  ------------------------------------------
//  D7 repoints the stores at the repositories. After it, the database is the
//  read path and `proposals.json` is no longer the other side of a comparison
//  that would notice. A key that can silently absorb one review into another
//  is survivable while a second copy exists and is checked every launch; it is
//  not survivable afterwards. This is the last patch in which the mistake is
//  cheap.
//
//  `ProposalStore.Record.id` IS ALREADY THE RIGHT KEY
//  --------------------------------------------------
//  It reads `"{startDay}_{endDay}_{n}-{six hex}"` and its own comment says why
//  the UUID suffix is there: "deleting record 1 would make the next add produce
//  id 2 again and collide in the list." The app solved this problem for itself
//  in patch 269 and the database was never told. Nothing is invented here; a
//  value that already exists, is already unique, is already `Codable`, and is
//  already in every `proposals.json` on disk simply gets a column.
//
//  WHY NULLABLE, AND WHY NO BACKFILL
//  ---------------------------------
//  Rows written before this migration have no key and cannot be given one from
//  inside a migration: the value lives in `proposals.json`, which SQL cannot
//  read. So the column is nullable and the IMPORTER adopts: an unkeyed row
//  whose `ranUTC` matches a record claims that record's key, once, on the next
//  import. After one import every row is keyed and `recordKey IS NULL` becomes
//  a state that only a bug can produce.
//
//  That leaves a window in which both keys are live, which is why
//  `ReviewRoundTrip` prints how many reviews it paired each way rather than
//  just how many it paired. A count that cannot say which rule produced it
//  cannot show the window closing — §12.15.
//
//  THE UNIQUE INDEX ADMITS NULLS ON PURPOSE
//  ----------------------------------------
//  SQLite treats NULLs as distinct in a unique index, so the five unkeyed rows
//  on this device coexist under it without a partial-index clause. The `WHERE
//  recordKey IS NOT NULL` is written anyway — not because it changes what the
//  index permits, but because a reader should not have to know that rule to
//  know this index is not claiming the unkeyed rows are unique.
//
//  NO TABLE REBUILD
//  ----------------
//  `ADD COLUMN` of a nullable column is a legal ALTER in SQLite, and the
//  twelve-step rebuild `2026-08-13-confidence-scale` needed was forced by a
//  CHECK, which cannot be altered. There is no CHECK here and no NOT NULL, so
//  the cheap path is also the honest one. `2026-08-06-proposal-inputs` added
//  `review.appVersion` exactly this way.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let reviewRecordKey = "2026-08-14-review-record-key"

    nonisolated static func registerReviewRecordKey(_ m: inout DatabaseMigrator) {
        m.registerMigration(reviewRecordKey) { db in

            // The app's own identity for the run that produced this review.
            // NULL means "written before patch 337 and not yet adopted", which
            // the importer resolves and `ReviewRoundTrip` counts out loud.
            try db.alter(table: "review") { t in
                t.add(column: "recordKey", .text)
            }

            // Raw SQL rather than `db.create(index:)` so the partial clause is
            // visible in `sqlite_master` exactly as written — that is the
            // string `ReviewRecordKeyTests` reads back, and a test that asks
            // the schema what it built beats one that asks the source what it
            // meant to build.
            try db.execute(sql: """
                CREATE UNIQUE INDEX review_on_record_key
                    ON review (accountID, recordKey)
                 WHERE recordKey IS NOT NULL
                """)
        }
    }
}
