//
//  ReadBacks.swift
//  Sub4
//
//  The nine read-backs, in one place — patch 333.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  Nothing here is new. Every function below was a `private func reload*` or
//  `private func run*ReadBack` on `DatabaseHealthView`, written the same way
//  nine times: read the repository off the main actor, compare on it, because
//  the stores being compared against are main-actor singletons.
//
//  They moved because they now have TWO callers. The write-through's
//  `onChange` refreshes one read-back at a time; patch 333's roll-up runs all
//  nine at once. Leaving them in the view would have meant writing each read
//  twice, which is §12.43's rule — *do not reimplement a rule, call it* —
//  and this project has paid for that rule three times.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  --------------------------------
//  It does not decide anything. No verdict, no health, no summary: each
//  function returns the load and the report exactly as the repository and the
//  round-trip produced them. `ReadBackRollUp` reads those. Splitting it this
//  way is what keeps the roll-up from becoming a second opinion about numbers
//  the sections already draw.
//
//  THE ACTOR SHAPE IS LOAD-BEARING, NOT DECORATION.
//  The database read is `Task.detached(priority: .utility)` because it is not
//  this screen's to block on. The comparison is NOT, because every store it
//  compares against — `ConstantsStore`, `NotesStore`, `PlanStore`,
//  `WeatherStore`, `AthleteStore`, `ProposalStore`, `ActivityStore`,
//  `DetailStore` — is a main-actor singleton. §12.9c.
//

import Foundation

@MainActor
enum ReadBacks {

    // MARK: The six that cost one read

    /// Patch 317 — D6c slice 6a. `athlete_profile`, `resting_month`, `hr_zone`.
    static func athlete(_ db: Sub4Database)
    async -> (load: AthleteLoad, report: AthleteRoundTrip.Report) {
        let load = await Task.detached(priority: .utility) {
            AthleteRepository.load(db)
        }.value
        return (load, AthleteRoundTrip.compare(store: ConstantsStore.shared.c,
                                               storeFTP: AthleteStore.shared.ftp,
                                               storeZones: AthleteStore.shared.hrZones,
                                               database: load))
    }

    /// Patch 322 — D6c slice 5b. `user_note` and `correction`.
    static func authored(_ db: Sub4Database)
    async -> (load: AuthoredLoad, report: AuthoredRoundTrip.Report) {
        let load = await Task.detached(priority: .utility) {
            AuthoredRepository.load(db)
        }.value
        return (load, AuthoredRoundTrip.compare(
            storeNotes: Array(NotesStore.shared.all.values),
            storeCommutes: Array(CommuteStore.shared.decisions.values),
            database: load))
    }

    /// Patch 323 and 326 — D6c slices 6b and 6c, read together because the
    /// screen shows them together and both describe one plan version.
    ///
    /// TWO READS RATHER THAN ONE THAT RETURNS EVERYTHING: the trimmings are a
    /// separate claim and a separate report, so a red row says which half
    /// broke.
    static func plan(_ db: Sub4Database)
    async -> (load: PlanLoad, report: PlanRoundTrip.Report,
              extrasLoad: PlanExtrasLoad, extrasReport: PlanExtrasRoundTrip.Report) {
        let load = await Task.detached(priority: .utility) {
            PlanRepository.load(db)
        }.value
        // PATCH 343 — THE BUNDLE, NOT THE STORE, AND THIS IS THE WHOLE PATCH.
        //
        // This read the plan store's own copy. From B1 that store is hydrated
        // from the database, so comparing the database against it would be
        // the database against itself: 298 comparisons, guaranteed zero
        // differences, proving nothing. A check that cannot fail has not been
        // tested — §12.69 — and this one is in the roll-up that passed D7's
        // entry gate.
        //
        // The bundle is the original source and stays an independent side.
        // Decoded on a utility task because it is a file read, and the
        // comparison itself stays on the actor for §12.9c's reason.
        //
        // TODAY THIS CHANGES NO NUMBER. The store IS the decoded bundle until
        // B1 hydrates it, so 298 and 71 must both come back unchanged — which
        // is exactly what makes this half checkable on its own.
        let bundled = await Task.detached(priority: .utility) {
            PlanStore.decodeBundle().plan
        }.value
        let report = PlanRoundTrip.compare(storeMeta: bundled.meta,
                                           storeWeeks: bundled.weeks,
                                           storeSessions: bundled.sessions,
                                           database: load)
        let extras = await Task.detached(priority: .utility) {
            PlanExtrasRepository.load(db)
        }.value
        let extrasReport = PlanExtrasRoundTrip.compare(
            storeFuel: bundled.fuel,
            storeWarmup: bundled.warmup,
            storeExercises: bundled.exercises,
            database: extras)
        return (load, report, extras, extrasReport)
    }

    /// PATCH 352 — the version census, ADR-0003 §12.97.
    ///
    /// SEPARATE FROM `plan(_:)` RATHER THAN FOLDED INTO ITS TUPLE, and it is a
    /// deliberate exclusion from the roll-up: every function above compares the
    /// database against a store and reports differences. This one compares
    /// versions against each other and there is no store to be right or wrong
    /// against. Putting it in the roll-up would give `ReadBackRollUp` a tenth
    /// row whose "unexplained differences" number could only ever be zero —
    /// §12.69, a check that cannot fail.
    ///
    /// `readerSessionCount` is `PlanRoundTrip.Report.sessionsInDatabase`. It is
    /// handed in so the census can be CHECKED against the reader rather than
    /// believed: two pieces of code read the same tables, and if they disagree
    /// about the active version the census is the one that is wrong.
    ///
    /// Detached, like every read on this screen. 1043 sessions and 2536 blocks
    /// hashed is not the main actor's work.
    static func planVersions(_ db: Sub4Database,
                             readerSessionCount: Int?) async -> PlanVersionCensus {
        await Task.detached(priority: .utility) {
            PlanVersionCensus.read(db, readerSessionCount: readerSessionCount)
        }.value
    }

    /// Patch 324 — D6c slice 6. `weather` and `gear`.
    ///
    /// `allGear`, NOT `shoes` — patch 325a. `AthleteStore` holds `shoes`,
    /// `bikes` and `retired` separately; 324 passed `shoes` and the comparison
    /// reported five bikes as "kept after the source dropped it". §12.68.6.
    static func weatherGear(_ db: Sub4Database)
    async -> (load: WeatherGearLoad, report: WeatherGearRoundTrip.Report) {
        let load = await Task.detached(priority: .utility) {
            WeatherGearRepository.load(db)
        }.value
        return (load, WeatherGearRoundTrip.compare(
            storeWeather: Array(WeatherStore.shared.byActivity.values),
            storeGear: AthleteStore.shared.allGear,
            knownActivityIDs: Set(ActivityStore.shared.activities.map(\.id)),
            database: load))
    }

    /// Patch 327 — D6c slice 7. Six review tables.
    static func review(_ db: Sub4Database)
    async -> (load: ReviewTrailLoad, report: ReviewRoundTrip.Report) {
        let load = await Task.detached(priority: .utility) {
            ReviewRepository.load(db)
        }.value
        return (load, ReviewRoundTrip.compare(
            storeRecords: ProposalStore.shared.records,
            database: load))
    }

    // MARK: The three that cost a great deal more

    /// Patch 289. 674 activities, nineteen named fields each.
    static func activities(_ db: Sub4Database)
    async -> (load: ActivityLoad, report: ActivityRoundTrip.Report?) {
        let store = ActivityStore.shared.activities
        let load = ActivityRepository.all(db)
        return (load, load.activities.map {
            ActivityRoundTrip.compare(store: store, database: $0)
        })
    }

    /// Patch 291. 674 details, and every split, lap and best effort inside
    /// them.
    static func details(_ db: Sub4Database)
    async -> (load: DetailLoad, report: DetailRoundTrip.Report?) {
        let store = Array(DetailStore.shared.details.values)
        let load = ActivityDetailRepository.all(db)
        return (load, load.details.map {
            DetailRoundTrip.compare(store: store, database: $0)
        })
    }

    /// Patch 294. THE ONLY ONE THAT WALKS SAMPLES — roughly 1.5 million
    /// comparisons across 649 recordings, which is why it is the one read-back
    /// whose comparison runs off the main actor as well as its read.
    ///
    /// No separate load type: the report carries the read's own outcome,
    /// because the id read failing means everything under it is unknown rather
    /// than zero. §12.15.
    static func recordings(_ db: Sub4Database) async -> RecordingRoundTrip.Report {
        let store = Array(DetailStore.shared.streams.values)
        return await RecordingRoundTrip.compareOffMain(db, store: store)
    }
}
