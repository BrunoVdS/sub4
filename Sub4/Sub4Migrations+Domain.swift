//
//  Sub4Migrations+Domain.swift
//  Sub4
//
//  The remaining eight table groups — patch 202, plan step 3.2.2, ADR-0003 §8.
//
//  A SEPARATE FILE BECAUSE THE FIRST MIGRATION IS HISTORY
//  -----------------------------------------------------
//  `2026-08-03-initial` has run. Its body is now a record of what a device
//  already has, and the surest way to keep it that way is to stop opening the
//  file it lives in. Every migration from here gets its own.
//
//  WHAT IS IN THIS ONE
//  -------------------
//  Groups 2 and 4 through 10 of ADR-0003 §8: the plan seed, recordings, what
//  the athlete authored, thresholds, the review trail, weather, operational
//  state, and lifecycle receipts. Group 1 and 3 shipped in the initial
//  migration.
//
//  Nothing reads or writes any of it yet. 3.3 builds the migration engine that
//  fills these tables from the JSON stores, and 3.4 moves the app onto them.
//  Creating the schema first is the order ADR-0003 §1 argues for: the shape is
//  cheap to get wrong now and expensive once an importer is written against it.
//
//  THREE PLACES THIS DEPARTS FROM §8, EACH DELIBERATE
//  -------------------------------------------------
//  1. §8 group 6 names a `constants` table. There is no such thing here. The
//     contents of `AthleteConstants` are a maximum heart rate, a resting
//     override, a sex coefficient, and a dictionary of resting rates by month —
//     which is a profile, three scalars, and a time series. A table called
//     `constants` holding a bag of unrelated values is a transport shape, and
//     the first line of §8 forbids exactly that. They land as columns on
//     `athlete_profile` and as `resting_month`.
//
//  2. §8 group 5 lists `proposal` under "authored". The athlete does not author
//     a proposal — a model does, inside a review, and the whole reason it is
//     kept is the audit trail. It is created here with a foreign key to
//     `review`, where it belongs, and §8's paragraph is the thing that is
//     wrong rather than this table.
//
//  3. §8 group 10 says `lifecycle_event` holds "deletion and export receipts".
//     A delete receipt cannot be one of them, and patch 186 already worked out
//     why: a record of the deletion that survives the deletion is a record the
//     person did not ask to keep. It could not survive here in any case — the
//     database lives inside the folder that "Delete local data" removes. So
//     this table holds exports and disconnects, both of which leave the
//     database standing, and the delete receipt stays in memory where 186 put
//     it. Recorded because the discrepancy will otherwise read as an omission.
//

import Foundation
import GRDB

extension Sub4Migrations {

    static let domain = "2026-08-04-domain"

    /// Frozen at `2026-08-04-domain`, for the reason given beside
    /// `initialDisciplines`. Held to `Intensity` by test.
    static let domainIntensities = ["easy", "long", "threshold", "marathon_pace"]

    /// Frozen. Held to `NotesStore.Note.Feel` by test.
    static let domainFeels = ["easier", "expected", "harder"]

    /// Frozen. Held to `WeatherSource` by test.
    static let domainWeatherProviders = ["appleWeather", "openMeteo"]

    static func registerDomain(_ m: inout DatabaseMigrator) {
        m.registerMigration(domain) { db in

            // MARK: - Group 2 — the plan seed
            //
            // VERSIONED BY CONTENT HASH, per §8. The plan ships in the app
            // bundle and is replaced wholesale by an update, so "which plan is
            // this" cannot be answered by a version number somebody remembers
            // to bump. The hash of the seed answers it, and it answers it the
            // same way on every device.
            //
            // This matters more than it sounds. A note is keyed to a session
            // uid; if a plan update renumbers a session, the note has to be
            // able to say which plan it was written against.

            try db.create(table: "plan") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("week1Monday", .text).notNull()
                t.column("raceDate", .text).notNull()
                t.column("targetTime", .text).notNull()
                t.column("targetPaceSecKm", .integer).notNull()
                    .check(sql: "targetPaceSecKm > 0")
                t.column("createdUTC", .text).notNull()
            }

            try db.create(table: "plan_version") { t in
                t.primaryKey("id", .text)
                t.column("planID", .text).notNull()
                    .references("plan", onDelete: .cascade)
                t.column("contentHash", .text).notNull().unique()
                t.column("sourceLabel", .text).notNull()
                t.column("importedUTC", .text).notNull()
                // NULL means never activated. A boolean `isActive` would need a
                // rule nobody enforces that exactly one row is true; a
                // timestamp says WHEN as well as WHETHER, and the partial index
                // below is what makes "exactly one" a property of the schema.
                t.column("activatedUTC", .text)
            }

            // At most one active version per plan. A partial unique index is
            // the only way SQLite can state that, and it is written as SQL
            // because it is a SQLite feature rather than a GRDB one.
            try db.execute(sql: """
                CREATE UNIQUE INDEX plan_version_one_active
                ON plan_version(planID) WHERE activatedUTC IS NOT NULL
                """)

            try db.create(table: "plan_week") { t in
                t.primaryKey("id", .text)
                t.column("planVersionID", .text).notNull()
                    .references("plan_version", onDelete: .cascade)
                t.column("uid", .text).notNull()
                // NULL for the logged prologue weeks P1–P3, which have a label
                // and no number. §6: absent, not zero.
                t.column("weekNo", .integer).check(sql: "weekNo IS NULL OR weekNo > 0")
                t.column("label", .text).notNull()
                t.column("startDate", .text)
                t.column("dateRange", .text)
                t.column("tag", .text)
                t.column("badge", .text)
                t.column("kind", .text)
                t.column("logged", .boolean).notNull()
                t.uniqueKey(["planVersionID", "uid"])
            }

            try db.create(table: "plan_session") { t in
                t.primaryKey("id", .text)
                t.column("planVersionID", .text).notNull()
                    .references("plan_version", onDelete: .cascade)
                t.column("planWeekID", .text).notNull()
                    .references("plan_week", onDelete: .cascade)
                t.column("uid", .text).notNull()
                t.column("day", .text)
                t.column("date", .text)
                t.column("discipline", .text).notNull()
                    .check(sql: "discipline IN (\(quoted(initialDisciplines)))")
                t.column("intensity", .text)
                    .check(sql: "intensity IS NULL OR intensity IN (\(quoted(domainIntensities)))")
                t.column("title", .text)
                t.column("detail", .text)
                t.column("fuel", .text)
                t.column("prep", .text)
                t.column("seq", .integer).notNull().check(sql: "seq >= 0")
                t.uniqueKey(["planVersionID", "uid"])
            }

            try db.create(index: "plan_session_on_week",
                          on: "plan_session", columns: ["planWeekID"])
            try db.create(index: "plan_session_on_date",
                          on: "plan_session", columns: ["date"])

            try db.create(table: "plan_exercise") { t in
                t.primaryKey("id", .text)
                t.column("planVersionID", .text).notNull()
                    .references("plan_version", onDelete: .cascade)
                t.column("uid", .text).notNull()
                t.column("name", .text).notNull()
                t.column("videoURL", .text).notNull()
                t.column("cue", .text)
                t.column("uses", .integer).notNull().check(sql: "uses >= 0")
                t.uniqueKey(["planVersionID", "uid"])
            }

            // MARK: - Group 4 — recordings
            //
            // NORMALISED — one row per sample — which is §9 question 3's
            // answer, taken provisionally and due to be confirmed by the
            // benchmark in 3.2d. If chunked storage wins there, the replacement
            // is a new migration and an importer that reads this shape, which
            // is why the shape is written down rather than left open.
            //
            // `ActivityStreams` resamples to about 300 points, so 10,000
            // activities is roughly three million rows. That is the number the
            // benchmark has to survive.

            try db.create(table: "recording") { t in
                t.primaryKey("id", .text)
                t.column("activityID", .text).notNull()
                    .references("activity", onDelete: .cascade)
                t.column("fetchedUTC", .text).notNull()
                t.column("sampleCount", .integer).notNull()
                    .check(sql: "sampleCount >= 0")
                // One recording per activity today. Stated as a constraint so
                // that the day a second source records the same session, the
                // failure is an insert that will not go in rather than a chart
                // drawn from two traces at once.
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.uniqueKey(["activityID", "sourceID"])
            }

            try db.create(table: "recording_sample") { t in
                t.column("recordingID", .text).notNull()
                    .references("recording", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")

                // The x axis. Cumulative metres, never negative, never
                // decreasing — the second of those is not expressible as a
                // column CHECK and belongs to the importer.
                t.column("distanceM", .double).notNull().check(sql: "distanceM >= 0")

                // Every one of these is nullable and NULL means the trace did
                // not carry it — §6. A run with no strap has no heart rate;
                // zero would make it a corpse.
                t.column("heartRate", .double)
                    .check(sql: "heartRate IS NULL OR heartRate > 0")
                t.column("speedMS", .double)
                    .check(sql: "speedMS IS NULL OR speedMS >= 0")
                t.column("altitudeM", .double)
                t.column("gradePercent", .double)
                // Watts, and only ever from a meter — Strava's estimate is
                // refused at ingest, and this column inherits that rule from
                // `ActivityStreams.power` rather than restating it.
                t.column("watts", .double)
                    .check(sql: "watts IS NULL OR watts >= 0")
                t.column("latitude", .double)
                    .check(sql: "latitude IS NULL OR (latitude >= -90 AND latitude <= 90)")
                t.column("longitude", .double)
                    .check(sql: "longitude IS NULL OR (longitude >= -180 AND longitude <= 180)")

                // Composite, so the samples of one recording are stored and
                // read in order without a second index. WITHOUT ROWID would
                // save more; it is a benchmark variable in 3.2d rather than a
                // guess here.
                t.primaryKey(["recordingID", "ordinal"])
            }

            // MARK: - Group 5 — what the athlete authored
            //
            // The category the whole project is careful with. These survive a
            // Strava disconnect, they survive the 4A retirement, and ADR-0002
            // says so. What follows is the shape that lets them.

            try db.create(table: "user_note") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)

                // NOT A FOREIGN KEY, AND THAT IS THE POINT.
                //
                // A note is written against a session uid from the plan that
                // was current when it was written. Plan versions come and go
                // with app updates; the note does not. A foreign key to
                // `plan_session` would delete thirteen months of writing the
                // first time a plan update renumbered a week — which is the
                // same failure `activity_alias` exists to prevent, one table
                // over.
                t.column("planSessionUID", .text).notNull()
                // The plan version it was written against, for resolving the
                // uid later. Nullable: a note imported from the JSON store has
                // no record of which version was live.
                t.column("planVersionID", .text)
                    .references("plan_version", onDelete: .setNull)
                // Set when the note is about a recorded session as well as a
                // planned one. SET NULL rather than cascade — deleting an
                // activity must not delete what you wrote about it.
                t.column("activityID", .text)
                    .references("activity", onDelete: .setNull)

                t.column("rpe", .integer)
                    .check(sql: "rpe IS NULL OR (rpe >= 1 AND rpe <= 10)")
                t.column("feel", .text)
                    .check(sql: "feel IS NULL OR feel IN (\(quoted(domainFeels)))")
                t.column("text", .text).notNull()
                t.column("createdUTC", .text).notNull()
                t.column("editedUTC", .text).notNull()

                t.uniqueKey(["accountID", "planSessionUID"])
            }

            try db.create(index: "user_note_on_activity",
                          on: "user_note", columns: ["activityID"])

            // Where the athlete overrode the matcher. `activityID` NULL means
            // "explicitly nothing" — the empty string the JSON store uses for
            // the same idea, expressed as a real absence.
            try db.create(table: "match_decision") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("planSessionUID", .text).notNull()
                t.column("activityID", .text)
                    .references("activity", onDelete: .setNull)
                t.column("decidedUTC", .text).notNull()
                t.uniqueKey(["accountID", "planSessionUID"])
            }

            // A field-level override of a recorded value: the official race
            // splits, the recordings whose moving time is wrong, the ones to
            // ignore. All of it is compile-time constants today, which is why
            // it has never been editable.
            try db.create(table: "correction") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("subjectKind", .text).notNull()
                    .check(sql: "subjectKind IN ('activity', 'planSession')")
                t.column("subjectID", .text).notNull()
                t.column("field", .text).notNull()
                t.column("value", .text)
                // NOT NULL on purpose. Every correction in the app today
                // carries a written reason — "chip time, official results" —
                // and one that does not is indistinguishable from a mistake.
                t.column("reason", .text).notNull()
                t.column("authoredUTC", .text).notNull()
                t.uniqueKey(["accountID", "subjectKind", "subjectID", "field"])
            }

            // What a rule declined to import, and enough to recognise it.
            //
            // OUTLIVES THE THING IT DESCRIBES, deliberately and disclosed:
            // `strava.rejectedByRule` is named as a gap in `DataLifecycle`
            // because it keeps date, name, distance and duration of recordings
            // the app refused. Keeping it is what stops the same recording
            // being re-offered and re-refused every sync.
            try db.create(table: "rejection") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.column("externalID", .text).notNull()
                t.column("rule", .text).notNull()
                t.column("noticedUTC", .text).notNull()
                t.column("name", .text)
                t.column("dayKey", .text)
                t.column("distanceM", .double)
                    .check(sql: "distanceM IS NULL OR distanceM >= 0")
                t.column("elapsedSeconds", .integer)
                    .check(sql: "elapsedSeconds IS NULL OR elapsedSeconds >= 0")
                t.uniqueKey(["accountID", "sourceID", "externalID"])
            }

            // MARK: - Group 6 — thresholds
            //
            // See the header on §8's `constants`: this group is a profile,
            // three scalars and a time series, and it is written as those.

            try db.create(table: "athlete_profile") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull().unique()
                    .references("account", onDelete: .cascade)

                // Typed by the athlete. Beats anything derived, always.
                t.column("hrMaxOverride", .integer)
                    .check(sql: "hrMaxOverride IS NULL OR hrMaxOverride > 0")

                // Read off recorded activities, and therefore Strava-derived
                // until 4A. `onStravaDisconnect` clears all three of these
                // together — see `DataLifecycle.athleteProfile`.
                t.column("hrMaxObserved", .integer)
                    .check(sql: "hrMaxObserved IS NULL OR hrMaxObserved > 0")
                t.column("hrMaxObservedOnDayKey", .text)
                t.column("hrMaxObservedActivityID", .text)
                    .references("activity", onDelete: .setNull)

                t.column("restOverride", .integer)
                    .check(sql: "restOverride IS NULL OR restOverride > 0")

                // Banister's coefficient — 1.92 or 1.67. NOT a preference: it
                // is an exponent, and the wrong one rescales every training
                // load the app has ever computed. NOT NULL with the default
                // that is in force today, because there is no such thing as an
                // activity scored without one.
                t.column("sexCoefficient", .double).notNull().defaults(to: 1.92)
                    .check(sql: "sexCoefficient > 0")

                t.column("ftpWatts", .integer)
                    .check(sql: "ftpWatts IS NULL OR ftpWatts > 0")
                t.column("updatedUTC", .text).notNull()
            }

            try db.create(table: "hr_zone") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("minBpm", .integer).notNull().check(sql: "minBpm > 0")
                t.column("maxBpm", .integer).notNull().check(sql: "maxBpm > 0")
                t.check(sql: "maxBpm >= minBpm")
                t.uniqueKey(["accountID", "ordinal"])
            }

            try db.create(table: "gear") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("sourceID", .text)
                    .references("source", onDelete: .restrict)
                // Nullable because gear survives the source it came from —
                // shoes keep their mileage after Strava is gone.
                t.column("externalID", .text)
                t.column("name", .text).notNull()
                t.column("distanceM", .double).notNull().defaults(to: 0)
                    .check(sql: "distanceM >= 0")
                t.column("retiredUTC", .text)
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX gear_on_source_external
                ON gear(accountID, sourceID, externalID)
                WHERE externalID IS NOT NULL
                """)

            // Resting heart rate by calendar month — the denominator of every
            // TRIMP the app computes. A month rather than a day because that is
            // the resolution the model uses: a January session is scored
            // against January.
            try db.create(table: "resting_month") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("month", .text).notNull()      // "yyyy-MM"
                t.column("bpm", .integer).notNull().check(sql: "bpm > 0")
                t.column("computedUTC", .text).notNull()
                t.uniqueKey(["accountID", "month"])
            }

            // MARK: - Group 7 — the review trail

            try db.create(table: "review") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("ranUTC", .text).notNull()
                t.column("windowStartDayKey", .text).notNull()
                t.column("windowEndDayKey", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("model", .text)
                t.check(sql: "windowEndDayKey >= windowStartDayKey")
            }

            // What the model was told. Kept so a proposal can be judged later
            // against the evidence it was given rather than against memory.
            try db.create(table: "review_evidence") { t in
                t.primaryKey("id", .text)
                t.column("reviewID", .text).notNull()
                    .references("review", onDelete: .cascade)
                t.column("sectionKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                // False for a section that was built and withheld — an opt-in
                // the athlete did not choose, or one blocked by lineage. The
                // audit trail has to show what was NOT sent as well.
                t.column("wasSent", .boolean).notNull()
                t.uniqueKey(["reviewID", "sectionKey"])
            }

            // LINEAGE AS A JOIN TABLE, not a comma-separated column.
            //
            // ADR-0002's purge has to find every stored piece of evidence with
            // Strava lineage and remove it while leaving the verdict standing.
            // That is a query, so lineage has to be queryable; a string of
            // source names in one column would make the purge a LIKE and the
            // correctness of a data-deletion obligation depend on substring
            // matching.
            try db.create(table: "review_evidence_source") { t in
                t.column("evidenceID", .text).notNull()
                    .references("review_evidence", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.primaryKey(["evidenceID", "sourceID"])
            }

            try db.create(index: "review_evidence_source_on_source",
                          on: "review_evidence_source", columns: ["sourceID"])

            // What came back. See the header — §8 files this under "authored",
            // which it is not.
            try db.create(table: "proposal") { t in
                t.primaryKey("id", .text)
                t.column("reviewID", .text).notNull()
                    .references("review", onDelete: .cascade)
                t.column("verdict", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("confidence", .integer)
                    .check(sql: "confidence IS NULL OR (confidence >= 0 AND confidence <= 100)")
                t.column("receivedUTC", .text).notNull()
                // NULL while undecided. A proposal the athlete has neither
                // accepted nor rejected is a real and common state.
                t.column("decision", .text)
                    .check(sql: "decision IS NULL OR decision IN ('accepted', 'rejected')")
                t.column("decidedUTC", .text)
            }

            try db.create(table: "proposal_change") { t in
                t.primaryKey("id", .text)
                t.column("proposalID", .text).notNull()
                    .references("proposal", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("what", .text).notNull()
                t.column("why", .text)
                t.uniqueKey(["proposalID", "ordinal"])
            }

            // MARK: - Group 8 — weather
            //
            // KEYED CANONICALLY, which is the whole point of the group.
            // `weather.json` is keyed by Strava activity id today, and
            // `DataLifecycle` records that as a gap: the KEY itself carries
            // Strava lineage, so the cache cannot survive 4A. Here the key is
            // the canonical activity, and the identifier that came from a
            // provider is nowhere in it.

            try db.create(table: "weather") { t in
                t.primaryKey("id", .text)
                t.column("activityID", .text).notNull().unique()
                    .references("activity", onDelete: .cascade)
                t.column("provider", .text).notNull()
                    .check(sql: "provider IN (\(quoted(domainWeatherProviders)))")
                t.column("tempC", .double).notNull()
                t.column("feelsLikeC", .double).notNull()
                t.column("humidity", .double).notNull()
                    .check(sql: "humidity >= 0 AND humidity <= 1")
                t.column("windKmh", .double).notNull().check(sql: "windKmh >= 0")
                t.column("windFromDegrees", .double).notNull()
                    .check(sql: "windFromDegrees >= 0 AND windFromDegrees <= 360")
                t.column("precipitationMm", .double).notNull()
                    .check(sql: "precipitationMm >= 0")
                t.column("symbolName", .text).notNull()
                t.column("conditionLabel", .text).notNull()
                // How many hourly samples the session overlapped. Zero would
                // mean the reading was reduced from nothing.
                t.column("samples", .integer).notNull().check(sql: "samples > 0")
                t.column("fetchedUTC", .text).notNull()
            }

            // MARK: - Group 9 — operational state
            //
            // Bookkeeping, not history. Everything here can be thrown away and
            // rebuilt by re-syncing, which is the test for whether something
            // belongs in this group.

            try db.create(table: "sync_state") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                // OPAQUE, and typed as text for that reason. Strava's cursor is
                // an epoch and Health's is an anchor; a column typed to one of
                // them would be a transport shape. Plan step 3.6.3 already
                // records that a cursor must be an exact source timestamp
                // rather than something reconstructed from a local day.
                t.column("cursor", .text)
                t.column("lastSyncUTC", .text)
                t.column("lastResult", .text)
                t.uniqueKey(["accountID", "sourceID"])
            }

            try db.create(table: "work_queue") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("subjectID", .text)
                t.column("state", .text).notNull()
                    .check(sql: "state IN ('pending', 'running', 'failed', 'done')")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                    .check(sql: "attempts >= 0")
                t.column("notBeforeUTC", .text)
                t.column("lastError", .text)
                t.column("createdUTC", .text).notNull()
                t.column("updatedUTC", .text).notNull()
            }

            // The index the queue is actually read through: what is due now.
            try db.create(index: "work_queue_due",
                          on: "work_queue", columns: ["state", "notBeforeUTC"])

            // Whether a thing has changed since it was last seen, without
            // re-reading it. What lets a re-sync skip an activity whose content
            // is identical rather than rewriting it and every row that hangs
            // off it.
            try db.create(table: "content_revision") { t in
                t.primaryKey("id", .text)
                t.column("entity", .text).notNull()
                t.column("entityID", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("seenUTC", .text).notNull()
                t.uniqueKey(["entity", "entityID"])
            }

            // MARK: - Group 10 — lifecycle receipts
            //
            // Exports and disconnects. Not deletions — see the header.

            try db.create(table: "lifecycle_event") { t in
                t.primaryKey("id", .text)
                t.column("operation", .text).notNull()
                    .check(sql: "operation IN ('export', 'disconnect')")
                t.column("startedUTC", .text).notNull()
                t.column("finishedUTC", .text)
                t.column("summary", .text).notNull()
            }

            try db.create(table: "lifecycle_line") { t in
                t.primaryKey("id", .text)
                t.column("eventID", .text).notNull()
                    .references("lifecycle_event", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check(sql: "ordinal >= 0")
                t.column("what", .text).notNull()
                // The four outcomes `LocationOutcome` already distinguishes.
                // "absent" is not a failure and never was — a device that never
                // ran a review has no proposals to remove.
                t.column("outcome", .text).notNull()
                    .check(sql: "outcome IN ('removed', 'absent', 'failed', 'notOurs')")
                t.column("bytes", .integer).notNull().defaults(to: 0)
                    .check(sql: "bytes >= 0")
                t.column("detail", .text)
                t.uniqueKey(["eventID", "ordinal"])
            }
        }
    }

    /// A DELIBERATE DUPLICATE of `quotedList` in the initial migration, and the
    /// duplication is the lesser evil.
    ///
    /// Sharing one helper would mean editing the body of `2026-08-03-initial`
    /// to call it. The output is byte-identical, so nothing would break — and a
    /// rule that says "a shipped migration body is never edited" which takes an
    /// exception the first time it is mildly inconvenient is not a rule. The
    /// cost is eight duplicated lines; the cost of the exception is that the
    /// next person to want one has a precedent.
    static func quoted(_ values: [String]) -> String {
        values
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
    }
}
