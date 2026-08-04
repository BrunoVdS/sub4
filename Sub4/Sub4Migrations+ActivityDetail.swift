//
//  Sub4Migrations+ActivityDetail.swift
//  Sub4
//
//  What a recorded session says about itself — patch 243, ADR-0003 §12.12.
//
//  §12.4 SAID "details/ AND streams/ → recording + recording_sample".
//  THAT IS WRONG, AND IT IS THE SIXTH MAPPING TO FIND IT SO.
//  ------------------------------------------------------------------
//  `recording` and `recording_sample` hold `ActivityStreams` — the trace, one
//  row per sample. They have a column for every field of it and are correct.
//
//  `details/` is a different store. `ActivityDetail` holds NONE of the same
//  things, and has no table anywhere in the schema:
//
//      calories, descriptionText, averageCadence, averageWatts, maxWatts,
//      deviceName, polyline, fetched
//      splits      index, distanceM, movingTime, elapsedTime,
//                  elevationDiff, averageHR
//      laps        index, distanceM, movingTime, averageHR
//      bestEfforts name, seconds
//
//  The splits are the ones that matter most. `closingPace(km:)` reads them to
//  answer the question the plan actually asks — "last 4 km at marathon pace" —
//  and there was nowhere to put a single one of them.
//
//  ONE DETAIL PER ACTIVITY PER SOURCE
//  ----------------------------------
//  Same shape as `recording`, and for the same reason: two sources describing
//  one session is a thing that will happen at 4A, and the failure should be an
//  insert that will not go in rather than a split table drawn from two devices
//  at once.
//
//  THE POLYLINE IS NOT REDUNDANT WITH THE SAMPLES
//  ----------------------------------------------
//  `recording_sample` carries latitude and longitude per sample, so an activity
//  with a trace has its route twice. It is kept anyway, because most activities
//  have NO trace — the trace is fetched per activity and there are roughly
//  sixty of them — while the detail, and therefore the route, exists far more
//  widely. Dropping the polyline would lose the route for every activity
//  without a trace, which is most of them.
//
//  ELAPSED IS ON SPLITS AND NOT ON LAPS, WHICH IS NOT AN OMISSION
//  --------------------------------------------------------------
//  `Split` carries both moving and elapsed time; `Lap` carries only moving.
//  That is what Strava returns and what `LapDTO` decodes. A nullable
//  `elapsedSeconds` on `activity_lap` would be a column that is NULL on every
//  row this app will ever write.
//

import Foundation
import GRDB

extension Sub4Migrations {

    nonisolated static let activityDetail = "2026-08-10-activity-detail"

    nonisolated static func registerActivityDetail(_ m: inout DatabaseMigrator) {
        m.registerMigration(activityDetail) { db in

            try db.create(table: "activity_detail") { t in
                t.primaryKey("id", .text)
                t.column("activityID", .text).notNull()
                    .references("activity", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)

                t.column("calories", .double)
                    .check(sql: "calories IS NULL OR calories >= 0")
                t.column("descriptionText", .text)
                t.column("averageCadence", .double)
                    .check(sql: "averageCadence IS NULL OR averageCadence >= 0")

                // Strava's own summary figure, which `activity.averageWatts`
                // also carries — from the SUMMARY endpoint rather than this
                // one. Kept in both places on purpose: they are two answers
                // from two calls, and a later disagreement is a fact worth
                // being able to see rather than one to have silently resolved
                // by whichever import ran last.
                t.column("averageWatts", .double)
                    .check(sql: "averageWatts IS NULL OR averageWatts >= 0")
                t.column("maxWatts", .double)
                    .check(sql: "maxWatts IS NULL OR maxWatts >= 0")

                t.column("deviceName", .text)
                t.column("polyline", .text)
                t.column("fetchedUTC", .text).notNull()

                t.uniqueKey(["activityID", "sourceID"])
            }

            // The kilometre splits. THE REASON THIS MIGRATION EXISTS.
            try db.create(table: "activity_split") { t in
                t.primaryKey("id", .text)
                t.column("activityDetailID", .text).notNull()
                    .references("activity_detail", onDelete: .cascade)

                // Strava's `split` index is 1-based and the app prints it as
                // the kilometre number. Stored as it arrives — a 0-based
                // ordinal here would make the database disagree with the split
                // table on screen by one, the same trap as `hr_zone.ordinal`.
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")

                t.column("distanceM", .double).notNull()
                    .check(sql: "distanceM >= 0")
                t.column("movingSeconds", .integer).notNull()
                    .check(sql: "movingSeconds >= 0")
                t.column("elapsedSeconds", .integer).notNull()
                    .check(sql: "elapsedSeconds >= 0")
                t.column("elevationDiffM", .double)
                t.column("averageHeartrate", .double)
                    .check(sql: "averageHeartrate IS NULL OR averageHeartrate > 0")

                t.uniqueKey(["activityDetailID", "ordinal"])
            }

            try db.create(table: "activity_lap") { t in
                t.primaryKey("id", .text)
                t.column("activityDetailID", .text).notNull()
                    .references("activity_detail", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("distanceM", .double).notNull()
                    .check(sql: "distanceM >= 0")
                t.column("movingSeconds", .integer).notNull()
                    .check(sql: "movingSeconds >= 0")
                t.column("averageHeartrate", .double)
                    .check(sql: "averageHeartrate IS NULL OR averageHeartrate > 0")
                t.uniqueKey(["activityDetailID", "ordinal"])
            }

            /// "Best 1k", "Best 5k", "Half-Marathon" — a name and a time.
            ///
            /// `ordinal` as well as `name`, because the order Strava returns
            /// them in is shortest-first and that is the order the app shows.
            /// Uniqueness is on the ordinal rather than the name: two efforts
            /// with the same name in one activity would be Strava's problem,
            /// and refusing the row would lose the whole detail over it.
            try db.create(table: "activity_best_effort") { t in
                t.primaryKey("id", .text)
                t.column("activityDetailID", .text).notNull()
                    .references("activity_detail", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("name", .text).notNull()
                t.column("seconds", .integer).notNull().check(sql: "seconds > 0")
                t.uniqueKey(["activityDetailID", "ordinal"])
            }
        }
    }
}
