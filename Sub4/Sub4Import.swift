//
//  Sub4Import.swift
//  Sub4
//
//  The cutover, first half — patch 218, plan step 3.3.2, ADR-0003 §9.7 and §12.
//
//  WHERE THE ROWS COME FROM, AND WHY NOT THE FILE
//  ----------------------------------------------
//  `activities.json` and `ActivityStore.activities` are NOT the same list. The
//  store applies a gate on load: `DataCorrections.ignoredActivities` (a curated
//  exclusion — one 2025 swim recording 400 m across 45 minutes) and the
//  self-contradiction rule. Rows the file holds and the app has decided are not
//  real never reach the screen.
//
//  A cutover's target is what the app SHOWS, not what the file happens to hold.
//  Importing straight from the file would resurrect activities Bruno has
//  already excluded, and re-implementing the gate here would give two copies of
//  a rule that has changed once already. So the import reads the stores.
//
//  The cost is stated plainly: this runs after the stores have loaded, so it
//  cannot be the thing that runs at launch before them. That is correct for
//  3.3.2, where the import is a button. When 3.3.3 makes the database
//  authoritative, the direction reverses and the stores read from here.
//
//  IDEMPOTENT BY LOOKUP, NOT BY LUCK — §12.1
//  -----------------------------------------
//  Every activity is looked up by `(sourceID, externalID)` in
//  `activity_source_record` before anything is written. Found means already
//  imported. Not found means mint a fresh opaque id.
//
//  Minting a `UUID()` unconditionally would look idempotent and duplicate the
//  whole history on every press, and NOTHING IN THE SCHEMA WOULD STOP IT —
//  nothing there knows two rows describe one session. The uniqueness that saves
//  us is `(accountID, sourceID, externalID)` on `activity_source_record`, and
//  it is the reason that constraint exists.
//
//  A REFUSED ROW DOES NOT ABORT THE IMPORT — §12.2
//  -----------------------------------------------
//  The CHECK constraints will refuse at least one row: the August 2025 artifact
//  at 199 km / 694,865 s. Each activity is therefore written inside its own
//  SAVEPOINT. A constraint violation rolls back that one activity and the loop
//  continues; the refusal is recorded with the reason SQLite gave.
//
//  Without the savepoint the first bad row would roll back the entire write and
//  the database would be left empty, with the screen reporting a failure whose
//  cause is one row out of six hundred.
//

import Foundation
import GRDB

nonisolated enum Sub4Import {

    // MARK: What comes out

    struct Refusal: Sendable, Equatable, Identifiable {
        /// The source's id, because that is the only handle the athlete has on
        /// a row that did not make it — it is what Strava's URL ends with.
        let externalID: String
        let reason: String
        var id: String { externalID }
    }

    struct Report: Sendable, Equatable {
        /// The `migration_run` row this import opened — patch 255. Carried on
        /// the report so a caller can find the ledger entry without guessing
        /// which row is the newest.
        var runID: String?
        var activitiesSeen = 0
        var activitiesInserted = 0
        /// Rows already present, refreshed from the source rather than skipped.
        /// The name changed in patch 220 with the behaviour: "already present"
        /// described something that did nothing.
        var activitiesUpdated = 0
        var gearInserted = 0
        var gearAlreadyPresent = 0
        /// Rows whose name or distance was rewritten because Strava's figure
        /// had moved. A SUBSET of `gearAlreadyPresent`, not a sibling of it —
        /// the row was present either way, and this says whether it changed.
        ///
        /// Expected to be small and non-zero on any device that runs: a shoe
        /// gains distance every time it is worn. Zero on every import for weeks
        /// would mean the refresh has stopped working, which is the state this
        /// counter exists to make visible. Patch 325.
        var gearRefreshed = 0
        /// Activities naming gear the athlete profile does not hold. Counted
        /// rather than refused: a missing shoe is not a reason to lose a run.
        var gearUnresolved = 0

        // Patch 225 — the authored stores. Counted separately because losing a
        // note and losing an activity are not the same loss: one can be
        // re-fetched from Strava and the other cannot.
        var notesSeen = 0
        var notesImported = 0
        var notesUpdated = 0
        var reviewsSeen = 0
        var reviewsImported = 0
        var reviewsUpdated = 0

        // Patch 272 — D4's database half, first of three. The athlete's
        // match overrides, which have lived in UserDefaults since the app's
        // first week and had nowhere in the database until now.
        var matchDecisionsSeen = 0
        var matchDecisionsImported = 0
        var matchDecisionsUpdated = 0
        /// A decision naming a recording the app excludes on purpose — the
        /// same shape as `weatherIgnored`, and never counted as seen: "seen"
        /// is work attempted, and this was declined at the door.
        var matchDecisionsIgnored = 0
        /// A decision naming an activity the database does not have, and
        /// nobody knows why.
        ///
        /// HELD BACK RATHER THAN WRITTEN WITH A NULL. The column allows NULL
        /// and it would be the easy thing to write — but NULL already means
        /// "the athlete said nothing satisfied this session". Reusing it here
        /// would make the database state something he never said. Anything
        /// above zero is news, exactly like `weatherUnmatched`.
        var matchDecisionsUnresolved = 0

        // Patch 226. `weatherUnmatched` is NOT a refusal: the schema is
        // correctly declining to hold a reading about an activity that is not
        // here.
        //
        // EXPECTED TO BE 0 SINCE PATCH 257. It was 1 for thirty-one patches —
        // the August 2025 artifact, whose activity the schema refused, so its
        // weather had nothing to attach to. 256 excluded that recording and
        // gave its trace and its detail counters of their own; this one was
        // missed and stayed at 1 while the other three went to 0. A screen
        // where one number is known-noise is a screen nobody reads.
        var weatherSeen = 0
        var weatherImported = 0
        var weatherUpdated = 0
        var weatherUnmatched = 0
        /// A reading belonging to a recording `DataCorrections` excludes —
        /// patch 257. Split out of `weatherUnmatched`, which had carried it
        /// since 226 and reported it as a missing activity the whole time.
        /// Never counted as seen: the import declines it before it tries.
        var weatherIgnored = 0

        // Patch 228 — the profile. `profileSeen` is 0 or 1 and exists so the
        // screen can tell "no profile was offered" from "a profile was offered
        // and refused"; without it both read as a blank row.
        var profileSeen = 0
        var profileImported = 0
        var profileUpdated = 0
        /// An observed maximum whose activity could not be identified — §12.10.
        /// NOT a refusal: the profile imports either way, and the column is
        /// provenance rather than the figure itself.
        var profileProvenanceUnresolved = 0
        var zonesSeen = 0
        var zonesImported = 0
        var restingSeen = 0
        var restingImported = 0
        var restingUpdated = 0

        // Patch 237 — the bundled plan. `planUnchanged` is the normal answer
        // on every run after the first: the content hash matched, so nothing
        // was rewritten. It is counted rather than folded into "imported"
        // because "we already had this exact plan" and "we wrote a new
        // version" are different events and only one of them should ever
        // follow an app update.
        var planSeen = 0
        var planImported = 0
        var planUnchanged = 0
        var planWeeks = 0
        var planWeekStats = 0
        var planSessions = 0
        var planDetails = 0
        var planBlocks = 0
        var planExercises = 0
        var planFuel = 0
        var planFuelRows = 0
        var planWarmup = 0
        var planWarmupRows = 0

        // Patch 243 — the traces and the details. `recordingsUnmatched` and
        // `detailsUnmatched` are NOT refusals: a trace on disk for an activity
        // the app has excluded is the exclusion working, exactly as with
        // weather in §12.9.
        /// Traces and details belonging to a recording `DataCorrections`
        /// excludes — patch 256. Counted rather than dropped silently, because
        /// this project's rule is that a number the app declines to import is
        /// visible. Distinct from `unmatched`, which means the activity is not
        /// there and nobody knows why.
        var recordingsIgnored = 0
        var detailsIgnored = 0
        var recordingsSeen = 0
        var recordingsImported = 0
        var recordingsUpdated = 0
        var recordingsUnchanged = 0
        var recordingsUnmatched = 0
        /// Fewer than eight samples — below what the app will chart, stored
        /// anyway. A charting threshold is not a truth threshold.
        var recordingsShort = 0
        var samplesImported = 0

        var detailsSeen = 0
        var detailsImported = 0
        var detailsUpdated = 0
        var detailsUnchanged = 0
        var detailsUnmatched = 0
        var splitsImported = 0
        var lapsImported = 0
        var effortsImported = 0

        /// WHICH ids did not resolve, and how many activities named each —
        /// patch 221.
        ///
        /// The first real run left 404 activities unresolved and the report
        /// could only say "404". Whether that is one untracked bike or forty
        /// missing shoes are completely different problems, and a number cannot
        /// tell them apart. Naming them is cheap and stops the next answer
        /// being a guess.
        // Patch 280 — D5 slice 4. Which rides are commutes. `removed` is
        // this importer pruning its own FIELD, and it holds back entirely
        // while any decision is unaccounted for — see the guard.
        var correctionsSeen = 0
        var correctionsImported = 0
        var correctionsUpdated = 0
        var correctionsUnresolved = 0
        var correctionsIgnored = 0
        var correctionsRemoved = 0

        // Patch 278 — D5 slice 3. What a rule threw away. NEVER pruned:
        // nothing in the app removes a receipt short of Delete local data,
        // which removes the database in the same breath.
        var rejectionsSeen = 0
        var rejectionsImported = 0
        var rejectionsUpdated = 0

        // Patch 276 — D5 slice 2. What the app has stopped asking for.
        // `removed` is this importer pruning its own kinds, which is NOT what
        // §12.21's reconciliation does: it owns `detail` and `stream`
        // entirely and gets the complete set every run.
        var workItemsSeen = 0
        var workItemsImported = 0
        var workItemsUpdated = 0
        var workItemsRemoved = 0

        // Patch 275 — D5 slice 1. Where the sync has got to. `seen` is 0 or
        // 1 and exists for §12.10's reason: without it, "no position was
        // offered" and "a position was offered and refused" both render as a
        // blank row.
        var syncStateSeen = 0
        var syncStateImported = 0
        var syncStateUpdated = 0

        // PATCH 274 — the reconciliation pass. Everything above this line
        // counts things that arrived; these count things that LEFT, which the
        // importer had no way to express until now.
        //
        // `reconciled` carries the reason rather than a Bool so that "a store
        // could not be read" and "the caller did not ask" are different words
        // on the health screen. A single false would have made a forgotten
        // argument look exactly like the gate doing its job.
        var reconciled: Reconciliation = .skipped("not attempted")
        var notesRemoved = 0
        var matchDecisionsRemoved = 0
        /// One row, and four more go with it: `review_evidence` and `proposal`
        /// cascade from `review`, `proposal_change` and `proposal_watch` from
        /// `proposal`. Counted as reviews because that is the thing the
        /// athlete deleted.
        var reviewsRemoved = 0

        var removedTotal: Int {
            notesRemoved + matchDecisionsRemoved + reviewsRemoved
        }

        var unresolvedGear: [String: Int] = [:]
        var refusals: [Refusal] = []
        var seconds: Double = 0

        var isClean: Bool { refusals.isEmpty }

        /// WHAT THE IMPORT DID, FOR THE PASTE — patch 341, renamed at 341a.
        ///
        /// `redactedLines`, NOT `diagnosticLines`, AND THE NAME IS THE POINT.
        /// This type already has a `diagnosticLines` that lists every refusal
        /// by `externalID` — a Strava activity id — which is why it has never
        /// been called from `diagnosticsText` and never should be. §12.7
        /// promises that file carries no identifiers from the athlete's
        /// history.
        ///
        /// `SnapshotManifest` made the same split at 248 and the paste already
        /// calls its `redactedLines`. Two functions, two audiences, one
        /// convention. 341 tried to add a second `diagnosticLines` instead and
        /// the compiler refused it — which is the cheapest way this could have
        /// been found.
        ///
        /// This report was drawn on the Database screen from the day it was
        /// written and reached the diagnostics file NEVER. It lived in a
        /// `@State` property, so the only way to send somebody "Notes: 1 new"
        /// was a screenshot — which is what happened twice on 10 August, and
        /// is how the gap was found. §12.57, fifth instance, and the last
        /// block on that screen still trapped behind it.
        ///
        /// COUNTS ONLY, AND THAT IS NOT A STYLE CHOICE. `refusals` carries a
        /// `Refusal.externalID` — a Strava activity id — and §12.7 promises
        /// this paste carries none, so the refusals arrive here as a number
        /// and their detail stays on the screen. Same rule the verifier's
        /// `detail` follows.
        ///
        /// BUILT WITH `append`, NOT AS ONE ARRAY LITERAL. A list of forty
        /// interpolated strings is an expression, and 327a lost a build to
        /// exactly that — "unable to type-check in reasonable time" in a plain
        /// `[String]`. §12.71.9.
        var redactedLines: [String] {
            var l: [String] = []
            l.append("  activities: \(activitiesSeen) seen, "
                     + "\(activitiesInserted) new, \(activitiesUpdated) refreshed")
            l.append("  gear: \(gearInserted) new, \(gearAlreadyPresent) known, "
                     + "\(gearRefreshed) refreshed, \(gearUnresolved) unresolved")
            l.append("  notes: \(notesSeen) seen, \(notesImported) new, "
                     + "\(notesUpdated) refreshed, \(notesRemoved) removed")
            l.append("  reviews: \(reviewsSeen) seen, \(reviewsImported) new, "
                     + "\(reviewsUpdated) refreshed, \(reviewsRemoved) removed")
            l.append("  match decisions: \(matchDecisionsSeen) seen, "
                     + "\(matchDecisionsImported) new, "
                     + "\(matchDecisionsUpdated) refreshed, "
                     + "\(matchDecisionsRemoved) removed")
            l.append("    ignored: \(matchDecisionsIgnored), "
                     + "unresolved: \(matchDecisionsUnresolved)")
            l.append("  commute decisions: \(correctionsSeen) seen, "
                     + "\(correctionsImported) new, \(correctionsUpdated) refreshed, "
                     + "\(correctionsRemoved) removed")
            l.append("    ignored: \(correctionsIgnored), "
                     + "unresolved: \(correctionsUnresolved)")
            l.append("  weather: \(weatherSeen) seen, \(weatherImported) new, "
                     + "\(weatherUpdated) refreshed")
            l.append("    unmatched: \(weatherUnmatched), ignored: \(weatherIgnored)")
            l.append("  traces: \(recordingsSeen) seen, \(recordingsImported) new, "
                     + "\(recordingsUpdated) replaced, "
                     + "\(recordingsUnchanged) unchanged")
            l.append("    unmatched: \(recordingsUnmatched), "
                     + "too short: \(recordingsShort), ignored: \(recordingsIgnored)")
            l.append("  trace samples written: \(samplesImported)")
            l.append("  details: \(detailsSeen) seen, \(detailsImported) new, "
                     + "\(detailsUpdated) replaced, \(detailsUnchanged) unchanged")
            l.append("    unmatched: \(detailsUnmatched), ignored: \(detailsIgnored)")
            l.append("  splits, laps, efforts written: \(splitsImported), "
                     + "\(lapsImported), \(effortsImported)")
            l.append("  refused recordings: \(rejectionsSeen) seen, "
                     + "\(rejectionsImported) new, \(rejectionsUpdated) refreshed")
            l.append("  stopped asking: \(workItemsSeen) seen, "
                     + "\(workItemsImported) new, \(workItemsUpdated) refreshed, "
                     + "\(workItemsRemoved) removed")
            l.append("  athlete: profile \(profileImported) new / "
                     + "\(profileUpdated) refreshed, zones \(zonesImported), "
                     + "resting months \(restingImported) new / "
                     + "\(restingUpdated) refreshed")
            l.append("  sync position: \(syncStateImported) new, "
                     + "\(syncStateUpdated) refreshed")
            l.append("  plan: \(planUnchanged > 0 ? "unchanged" : "written") — "
                     + "\(planWeeks) weeks, \(planSessions) sessions, "
                     + "\(planBlocks) blocks")
            l.append("  reconciled: \(reconciled.isRunning ? "yes" : "no")")
            l.append("  rows removed in total: \(removedTotal)")
            // A NUMBER, NOT A LIST. Each refusal names an activity.
            l.append("  refused: \(refusals.count)")
            l.append(String(format: "  took: %.3f s", seconds))
            return l
        }

        /// What the ledger stores about this run — patch 255.
        ///
        /// COUNTS ONLY. The ledger is read back into the redacted diagnostic
        /// paste, which promises no session names and no dates from the
        /// athlete's history, so this may never carry either. Refusals are a
        /// number here; which ones they were is on the import screen.
        var ledgerNote: String {
            var parts = ["\(activitiesSeen) activities",
                         "\(recordingsSeen) traces",
                         "\(detailsSeen) details"]
            if refusals.isEmpty == false { parts.append("\(refusals.count) refused") }
            parts.append(String(format: "%.1fs", seconds))
            return parts.joined(separator: ", ")
        }

        /// Most-named first, so the answer is in the first line rather than
        /// somewhere in a list of forty.
        var unresolvedGearRanked: [(external: String, count: Int)] {
            unresolvedGear
                .map { (external: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.external) > ($1.count, $0.external) }
        }

        var summary: String {
            var s = "\(activitiesInserted) imported"
            if activitiesUpdated > 0 { s += ", \(activitiesUpdated) refreshed" }
            if !refusals.isEmpty { s += ", \(refusals.count) refused" }
            return s
        }

        var diagnosticLines: [String] {
            var l = [String(format: "Import: %.2f s", seconds),
                     "Activities seen: \(activitiesSeen)",
                     "  inserted: \(activitiesInserted), refreshed: \(activitiesUpdated)",
                     "Notes seen: \(notesSeen) — imported \(notesImported), refreshed \(notesUpdated)",
                     "Reviews seen: \(reviewsSeen) — imported \(reviewsImported), refreshed \(reviewsUpdated)",
                     "Weather seen: \(weatherSeen) — imported \(weatherImported), refreshed \(weatherUpdated), no activity \(weatherUnmatched), excluded \(weatherIgnored)",
                     "Profile seen: \(profileSeen) — imported \(profileImported), refreshed \(profileUpdated), provenance unresolved \(profileProvenanceUnresolved)",
                     "Zones seen: \(zonesSeen) — imported \(zonesImported)",
                     "Resting months seen: \(restingSeen) — imported \(restingImported), refreshed \(restingUpdated)",
                     "Plan seen: \(planSeen) — imported \(planImported), unchanged \(planUnchanged)",
                     "  weeks: \(planWeeks), stats: \(planWeekStats), sessions: \(planSessions)",
                     "  breakdowns: \(planDetails), blocks: \(planBlocks), exercises: \(planExercises)",
                     "  fuel: \(planFuel) with \(planFuelRows) rows, warm-up: \(planWarmup) with \(planWarmupRows) rows",
                     "Traces seen: \(recordingsSeen) — imported \(recordingsImported), replaced \(recordingsUpdated), unchanged \(recordingsUnchanged)",
                     "  samples: \(samplesImported), short: \(recordingsShort), no activity: \(recordingsUnmatched)",
                     "Details seen: \(detailsSeen) — imported \(detailsImported), replaced \(detailsUpdated), unchanged \(detailsUnchanged)",
                     "  splits: \(splitsImported), laps: \(lapsImported), efforts: \(effortsImported), no activity: \(detailsUnmatched)",
                     "Gear inserted: \(gearInserted), already present: \(gearAlreadyPresent), refreshed: \(gearRefreshed)",
                     "Activities naming unknown gear: \(gearUnresolved)"]
            for (external, count) in unresolvedGearRanked {
                l.append("  \(external): \(count) activities")
            }
            l.append("Refused: \(refusals.count)")
            for r in refusals { l.append("  \(r.externalID): \(r.reason)") }
            return l
        }
    }

    // MARK: Fixed identities

    /// One account, minted here. §9.6: the column exists for Phase 4A, not
    /// because this app has users. A literal rather than a UUID so that a
    /// second import run finds the same account instead of making another.
    static let accountID = "local"
    static let accountLabel = "This phone"

    /// Everything imported in 3.3.2 arrived from Strava. When Apple Health
    /// becomes a source at 4A it gets its own value, and the same activity can
    /// then carry two source records.
    static let sourceID = "strava"

    // MARK: Running

    static func run(into db: Sub4Database,
                    activities: [Activity],
                    shoes: [AthleteStore.Shoe],
                    notes: [NotesStore.Note] = [],
                    proposals: [ProposalStore.Record] = [],
                    matchDecisions: [MatchDecision] = [],
                    syncState: SyncState? = nil,
                    workItems: [WorkItem] = [],
                    rejections: [RejectionReceipt] = [],
                    commutes: [CommuteDecision] = [],
                    // PATCH 274. DEFAULTS TO NOT RECONCILING, and that is the
                    // safe direction: a forgotten argument leaves rows behind,
                    // which is the status quo and is visible on the health
                    // screen. A default that deleted would delete in the one
                    // call site nobody thought about.
                    //
                    // The gate is computed by the CALLER — `Sub4Import` is
                    // `nonisolated` end to end and `StoreReadJournal` is on
                    // the main actor. That is the right shape anyway: the
                    // decision to delete belongs to the screen that knows
                    // what was read.
                    reconcile: Reconciliation = .skipped("the caller did not ask"),
                    weather: [ActivityWeather] = [],
                    constants: AthleteConstants? = nil,
                    ftpWatts: Int? = nil,
                    zones: [AthleteStore.HRZone] = [],
                    plan: Plan? = nil,
                    planSourceLabel: String = "bundled",
                    streams: [ActivityStreams] = [],
                    details: [ActivityDetail] = [],
                    appVersion: String = "unknown",
                    snapshotID: String? = nil,
                    // WHO CAUSED THIS RUN — patch 311, groundwork §5.4.
                    //
                    // Defaulted to nil HERE and required on the `AppStores`
                    // overload every production caller goes through. That is
                    // the split on purpose: the two call sites that can answer
                    // must, and the several dozen test call sites that have no
                    // answer are left alone.
                    //
                    // A nil is stored as NULL and reads back as "not recorded",
                    // which is what the 45 rows written before this patch
                    // honestly are.
                    trigger: MigrationRunTrigger? = nil) throws -> Report {

        let clock = ContinuousClock()
        var report = Report()
        report.reconciled = reconcile
        let now = iso8601(Date())

        // THE LEDGER OPENS BEFORE THE WRITE AND CLOSES AFTER IT — patch 255,
        // migration contract item 11. Three transactions rather than one, and
        // the reason is the acceptance criterion: a `failed` row written inside
        // the import's own `write` would be rolled back by the very throw it
        // was recording, leaving the run reading `running` for ever.
        let runID = try MigrationLedger.open(db, appVersion: appVersion,
                                             snapshotID: snapshotID,
                                             trigger: trigger, now: now)
        report.runID = runID

        do {
        let elapsed = try clock.measure {
            try db.queue.write { d in
                try ensureAccount(d, now: now)

                // GEAR FIRST — §12.3. `activity.gearID` references the
                // canonical gear id, so an activity written before its shoes
                // has nowhere to point and loses the attribution silently.
                let gearByExternal = try importGear(d, shoes: shoes, now: now, into: &report)

                for a in activities {
                    report.activitiesSeen += 1
                    try importOne(d, a, gearByExternal: gearByExternal,
                                  now: now, into: &report)
                }

                // AFTER the activities, and it does not currently matter — a
                // note references its plan session, not an activity, and
                // `activityID` is left NULL for the matcher to fill. Ordered
                // this way so that when the matcher does run, the rows it needs
                // are already there.
                try importNotes(d, notes: notes, now: now, into: &report)
                try importProposals(d, records: proposals, now: now, into: &report)

                // AFTER THE ACTIVITIES, and here the order is load-bearing
                // rather than tidy — the same dependency weather has. A
                // decision names a STRAVA activity id and `match_decision`
                // references the canonical one, so it resolves through
                // `activity_alias`, which the activity loop above writes.
                try importMatchDecisions(d, decisions: matchDecisions,
                                         now: now, into: &report)

                // AFTER the activities, and here the order is load-bearing
                // rather than tidy: every reading is resolved through
                // `activity_alias`, which the activity loop above writes.
                try importWeather(d, readings: weather, now: now, into: &report)

                // LAST, and after the activities for the same reason weather
                // is: `hrMaxObservedActivityID` is resolved through
                // `activity_alias`, which the activity loop writes. A profile
                // imported first would lose its provenance every run and give
                // no sign of it — the column would simply be NULL.
                if let constants {
                    try importAthleteProfile(d, constants: constants,
                                             ftpWatts: ftpWatts,
                                             activities: activities,
                                             now: now, into: &report)
                    try importRestingMonths(d, byMonth: constants.restByMonth,
                                            now: now, into: &report)
                }
                try importHRZones(d, zones: zones, now: now, into: &report)

                // The plan last. It references nothing the other importers
                // write — a plan version is its own object — so the position
                // is about the report reading in the order the work happened
                // rather than about correctness.
                if let plan {
                    try importPlan(d, plan: plan, sourceLabel: planSourceLabel,
                                   now: now, into: &report)
                }

                // AFTER the activities, like weather: both resolve a Strava id
                // through `activity_alias`, which the activity loop writes.
                try importRecordings(d, streams: streams, now: now, into: &report)
                try importDetails(d, details: details, now: now, into: &report)

                // BOOKKEEPING, NOT HISTORY — §8's group 9 header. Position in
                // the run is free: `sync_state` references `account` and
                // `source`, both of which exist before the activity loop.
                try importSyncState(d, state: syncState, now: now, into: &report)

                // Group 9 as well, and it references nothing — `work_queue`
                // has no foreign keys at all, because the subject of a piece
                // of work may be an id the database has never held.
                try importWorkQueue(d, items: workItems, now: now, into: &report)

                // `rejection.sourceID` is a RESTRICTED foreign key and
                // `accountID` cascades, so both must exist — they do, from the
                // seed and from `ensureAccount`. It references no ACTIVITY,
                // deliberately: the receipt outlives the recording.
                try importRejections(d, receipts: rejections, now: now, into: &report)

                // AFTER THE ACTIVITIES, like weather: the store is keyed by
                // Strava id and `correction.subjectID` holds the canonical one.
                // It takes `reconcile` because it prunes its own field, and
                // `commutes.json` is an authored store with a decode step —
                // §12.20's hazard is real on this path.
                try importCorrections(d, decisions: commutes,
                                      reconcile: reconcile, now: now,
                                      into: &report)

                // LAST, AND INSIDE THE SAME WRITE — patch 274.
                //
                // Last because everything above has already put the current
                // records in, so what is left over is genuinely left over.
                // Inside the write because a throw here must roll the whole
                // import back rather than leave a half-reconciled database.
                if reconcile.isRunning {
                    try reconcileAuthored(d, notes: notes, proposals: proposals,
                                          matchDecisions: matchDecisions,
                                          into: &report)
                }
            }
        }
        report.seconds = seconds(elapsed)

        // `pending`, NOT `verified`. The write committed and nothing has
        // checked it — see `MigrationLedger`'s header on what the word means
        // here. Marking a run verified from inside the importer that produced
        // it would be a control reporting work it did not do, which is the
        // defect this project has now found five times.
        try MigrationLedger.finish(db, id: runID, state: .pending,
                                   note: report.ledgerNote,
                                   now: iso8601(Date()))
        return report

        } catch {
            // Best effort, and deliberately swallowing its own failure: the
            // import's error is the one worth raising, and a ledger write that
            // also fails must not replace it with a less useful one.
            try? MigrationLedger.finish(db, id: runID, state: .failed,
                                        note: String(describing: error).prefix(500)
                                            .description,
                                        now: iso8601(Date()))
            throw error
        }
    }

    // MARK: The account

    private static func ensureAccount(_ d: Database, now: String) throws {
        let exists = try Bool.fetchOne(
            d, sql: "SELECT 1 FROM account WHERE id = ?", arguments: [accountID]) ?? false
        guard !exists else { return }
        try d.execute(sql: """
            INSERT INTO account (id, label, createdUTC) VALUES (?, ?, ?)
            """, arguments: [accountID, accountLabel, now])
    }

    // MARK: Gear

    /// Returns Strava's gear id → canonical gear id, for the activity loop.
    ///
    /// LAST KNOWN, NOT FIRST SEEN — patch 325, ADR-0003 §12.68.
    ///
    /// Until 325 this function did `continue` on an existing row: name and
    /// distance were written once, at first import, and never again. Patch
    /// 324's read-back found it — one shoe of six differing on `distanceM`
    /// after five days, and the count could only ever grow.
    ///
    /// **Why that matters more than a red row on a screen.** ADR-0002 retires
    /// Strava at Phase 4A. When the import is switched off, whatever is in
    /// `gear.distanceM` on that day is the mileage FOR EVER — there is no
    /// second copy to reconcile against afterwards. The schema's own comment on
    /// the table says gear "survives the source it came from — shoes keep their
    /// mileage after Strava is gone", and a first-seen figure is not that. This
    /// is the difference between freezing the right number and freezing an old
    /// one.
    ///
    /// `gearAlreadyPresent` keeps its meaning — the row was there — and
    /// `gearRefreshed` counts the subset that actually changed.
    private static func importGear(_ d: Database,
                                   shoes: [AthleteStore.Shoe],
                                   now: String,
                                   into report: inout Report) throws -> [String: String] {
        var map: [String: String] = [:]
        for shoe in shoes {
            if let row = try Row.fetchOne(d, sql: """
                SELECT id, name, distanceM FROM gear
                WHERE accountID = ? AND sourceID = ? AND externalID = ?
                """, arguments: [accountID, sourceID, shoe.id]),
               let existing = row["id"] as String? {
                map[shoe.id] = existing
                report.gearAlreadyPresent += 1

                // WRITTEN ONLY WHEN SOMETHING MOVED. An unconditional UPDATE
                // would work and would make `gearRefreshed` mean "rows we
                // touched" rather than "rows that changed" — and a counter
                // that cannot go quiet cannot report that the refresh stopped.
                let sameName = (row["name"] as String?) == shoe.name
                let sameDistance = (row["distanceM"] as Double?) == shoe.distanceM
                if !sameName || !sameDistance {
                    try d.execute(sql: """
                        UPDATE gear SET name = ?, distanceM = ? WHERE id = ?
                        """, arguments: [shoe.name, shoe.distanceM, existing])
                    report.gearRefreshed += 1
                }
                continue
            }
            let id = UUID().uuidString
            try d.execute(sql: """
                INSERT INTO gear (id, accountID, sourceID, externalID, name, distanceM)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, accountID, sourceID, shoe.id, shoe.name, shoe.distanceM])
            map[shoe.id] = id
            report.gearInserted += 1
        }
        return map
    }

    // MARK: One activity

    private static func importOne(_ d: Database,
                                  _ a: Activity,
                                  gearByExternal: [String: String],
                                  now: String,
                                  into report: inout Report) throws {

        // §12.1, AND THE CORRECTION MADE IN PATCH 220.
        //
        // Found means this activity already has a canonical id minted by an
        // earlier run. The first version RETURNED here, and that was wrong: an
        // import tool has to CONVERGE, not merely insert once.
        //
        // The case that proved it took four minutes to find on real data. The
        // first run happened before `AthleteStore` had refreshed, so its shoe
        // list was empty and 474 activities imported with a null `gearID`.
        // Skipping on the second run would have left every one of them
        // unattributed for good, and the report would have said "already there"
        // with quiet confidence.
        //
        // So a known activity is UPDATED from the source. Safe precisely
        // because nothing reads the database yet — and after 3.3.3 it stays
        // safe, because the JSON stores remain the upstream until they are
        // retired.
        let existing = try String.fetchOne(d, sql: """
            SELECT activityID FROM activity_source_record
            WHERE accountID = ? AND sourceID = ? AND externalID = ?
            """, arguments: [accountID, sourceID, a.id])

        // `startUTC` is NOT NULL in the schema and optional in the JSON —
        // early rows predate the app recording it. Refused rather than
        // invented: a made-up instant would order wrongly against every other
        // activity and nobody would ever know why.
        guard let startUTC = a.startUTC, !startUTC.isEmpty else {
            report.refusals.append(.init(externalID: a.id,
                                         reason: "no start instant (startUTC is missing)"))
            return
        }

        let canonical = existing ?? UUID().uuidString
        let gearID = a.gearId.flatMap { gearByExternal[$0] }

        do {
            // THE SAVEPOINT — §12.2. A CHECK violation rolls back this
            // activity alone. Without it the first refused row would take the
            // whole import with it.
            try d.inSavepoint {
                if existing != nil {
                    // Everything the source owns, refreshed. `id`, `accountID`
                    // and `createdUTC` are NOT touched: the canonical id is
                    // ours and outlives the source, and when a row first
                    // arrived is not something a later run gets to rewrite.
                    try d.execute(sql: """
                        UPDATE activity SET
                          startUTC = ?, startLocal = ?, dayKey = ?,
                          startOffsetSeconds = ?, timeZoneIdentifier = ?,
                          discipline = ?, sportLabel = ?, name = ?,
                          distanceM = ?, movingSeconds = ?, elapsedSeconds = ?,
                          elevationGainM = ?, averageHeartrate = ?, maxHeartrate = ?,
                          startLatitude = ?, startLongitude = ?,
                          gearID = ?, averageWatts = ?, hasPowerMeter = ?,
                          isIndoor = ?, maxSpeedMS = ?, updatedUTC = ?
                        WHERE id = ?
                        """, arguments: [
                            startUTC, a.startLocal, a.dayKey,
                            a.startOffsetSeconds, a.timeZoneIdentifier,
                            (a.discipline ?? .other).rawValue, a.sportType, a.name,
                            a.distance, a.movingTime, a.elapsedTime,
                            a.elevationGain, a.averageHeartrate, a.maxHeartrate,
                            a.startLat, a.startLon,
                            gearID, a.averageWatts, a.deviceWatts, a.isTrainer,
                            a.maxSpeed, now, canonical
                        ])
                    try d.execute(sql: """
                        UPDATE activity_source_record SET lastSeenUTC = ?
                        WHERE accountID = ? AND sourceID = ? AND externalID = ?
                        """, arguments: [now, accountID, sourceID, a.id])
                    try recordGearReference(d, activityID: canonical,
                                            named: a.gearId, now: now)
                    return .commit
                }

                try d.execute(sql: """
                    INSERT INTO activity
                      (id, accountID, startUTC, startLocal, dayKey,
                       startOffsetSeconds, timeZoneIdentifier,
                       discipline, sportLabel, name,
                       distanceM, movingSeconds, elapsedSeconds,
                       elevationGainM, averageHeartrate, maxHeartrate,
                       startLatitude, startLongitude,
                       gearID, averageWatts, hasPowerMeter, isIndoor, maxSpeedMS,
                       createdUTC, updatedUTC)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        canonical, accountID, startUTC, a.startLocal, a.dayKey,
                        a.startOffsetSeconds, a.timeZoneIdentifier,
                        (a.discipline ?? .other).rawValue, a.sportType, a.name,
                        a.distance, a.movingTime, a.elapsedTime,
                        a.elevationGain, a.averageHeartrate, a.maxHeartrate,
                        a.startLat, a.startLon,
                        gearID, a.averageWatts, a.deviceWatts, a.isTrainer,
                        a.maxSpeed, now, now
                    ])

                try d.execute(sql: """
                    INSERT INTO activity_source_record
                      (id, activityID, accountID, sourceID, externalID,
                       firstSeenUTC, lastSeenUTC)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, canonical, accountID,
                                     sourceID, a.id, now, now])

                // The alias is what makes a note written against a Strava id
                // still resolve after Strava is gone — §3.1. Written at import
                // rather than at retirement, because at retirement the mapping
                // no longer exists to be written.
                try d.execute(sql: """
                    INSERT INTO activity_alias
                      (id, activityID, sourceID, externalID, notedUTC)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, canonical,
                                     sourceID, a.id, now])

                try recordGearReference(d, activityID: canonical,
                                        named: a.gearId, now: now)
                return .commit
            }
            if existing != nil { report.activitiesUpdated += 1 }
            else { report.activitiesInserted += 1 }

            // COUNTED HERE, NOT BEFORE THE WRITE — patch 224.
            //
            // The first version incremented these next to the lookup, which
            // counted gear for an activity the CHECK constraints then refused:
            // the phone reported "404 naming unknown gear" against 473 rows in
            // `activity_gear_reference`, and reconciling that took longer than
            // the bug was worth. These numbers are the cutover's audit trail —
            // an off-by-one in them is a wasted hour six weeks from now.
            if let named = a.gearId, gearID == nil {
                report.gearUnresolved += 1
                report.unresolvedGear[named, default: 0] += 1
            }
        } catch {
            // The reason SQLite gave, not a paraphrase. "CHECK constraint
            // failed: distanceM" names the column; "could not import" does not.
            report.refusals.append(.init(externalID: a.id,
                                         reason: String(describing: error)))
        }
    }

    /// What the source called the gear, kept whether or not it resolves —
    /// §3.1 and §12.6. Deleted and rewritten rather than upserted: an activity
    /// whose gear was cleared at the source must lose the reference too, and a
    /// row left behind would outlive the fact it recorded.
    private static func recordGearReference(_ d: Database,
                                            activityID: String,
                                            named externalID: String?,
                                            now: String) throws {
        try d.execute(sql: """
            DELETE FROM activity_gear_reference
            WHERE activityID = ? AND sourceID = ?
            """, arguments: [activityID, sourceID])
        guard let externalID, !externalID.isEmpty else { return }
        try d.execute(sql: """
            INSERT INTO activity_gear_reference
              (id, activityID, sourceID, externalID, notedUTC)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, activityID, sourceID,
                             externalID, now])
    }

    // MARK: Small helpers

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
