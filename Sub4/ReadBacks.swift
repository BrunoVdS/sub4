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

    // MARK: The independent side — patch 356, D7 slice B2, ADR-0003 §12.101

    /// The three authored sources, read WITHOUT asking the app's stores.
    ///
    /// WHY THIS EXISTS. `ReadBacks.authored` compared the database against
    /// `NotesStore.shared`, `CommuteStore.shared` and `Matcher.shared`. B2
    /// hydrates all three FROM the database, and at that moment the comparison
    /// is the database against itself — three counts that cannot disagree, on
    /// a read-back inside D7's entry gate. §12.69, and §12.91.2 settled what to
    /// do about it: the store serves the database, the read-back keeps its own
    /// legacy read.
    ///
    /// NOT A SECOND DECODER. Each store's own `init` is used, so this cannot
    /// drift from what the store would have decoded — §12.43, call the rule
    /// rather than reimplement it. The three initialisers were written for
    /// tests; their docs now say they have a production caller.
    struct AuthoredSources {
        let notes: [NotesStore.Note]
        let commutes: [CommuteDecision]
        let decisions: [MatchDecision]
        /// PATCH 364. Read from `moves.json` through `PlanMoveStore`'s own
        /// `init(directory:)`, for the reason above: not a second decoder.
        let moves: [PlanMove]

        /// What each read actually did. `.absent` is a clean read of nothing —
        /// a fresh install has no `notes.json` — and `.unreadable` is not.
        let notesLoad: StoreLoad
        let commutesLoad: StoreLoad
        let decisionsLoad: StoreLoad
        let movesLoad: StoreLoad

        /// Nil when Application Support is unreachable. Distinct from three
        /// `.absent` loads: one says the files are not there, the other says
        /// the app cannot look. §12.15.
        let directoryFound: Bool

        var isTrustworthy: Bool {
            directoryFound && notesLoad.isTrustworthy
                && commutesLoad.isTrustworthy && decisionsLoad.isTrustworthy
                && movesLoad.isTrustworthy
        }

        /// Printed unconditionally. A read-back that does not say where its own
        /// side came from is a read-back nobody can check.
        var line: String {
            guard directoryFound else {
                return "Application Support is unreachable, so the app side "
                     + "was not read at all"
            }
            return "notes.json, commutes.json, moves.json and the stored "
                 + "match decisions, read directly"
        }
    }

    /// One of each store, rooted at the real container.
    ///
    /// `AppSupportItem.container` and not a tenth copy of the
    /// `applicationSupportDirectory` incantation — there are already nine.
    ///
    /// ON `AppSupportItem` AND NOT ON `DataLifecycle`, which is what 356 wrote
    /// and 356a corrected. The declaration sits at the top of
    /// `DataLifecycle.swift`, inside a `nonisolated enum` that opens three
    /// hundred lines before `enum DataLifecycle` does. A file name is not a
    /// scope.
    ///
    /// It is the right thing to call for a second reason its own doc gives:
    /// *"Nil is a real answer — every caller must handle it rather than
    /// force-unwrapping and crashing a delete flow."* `directoryFound` is this
    /// read-back handling it.
    static func authoredSources() -> AuthoredSources {
        guard let dir = AppSupportItem.container else {
            return AuthoredSources(notes: [], commutes: [], decisions: [],
                                   moves: [],
                                   notesLoad: .absent, commutesLoad: .absent,
                                   decisionsLoad: .absent, movesLoad: .absent,
                                   directoryFound: false)
        }
        let notes = NotesStore(directory: dir)
        let commutes = CommuteStore(directory: dir)
        // `UserDefaults.standard` and not a file — `Matcher`'s header says why
        // the decisions stayed there, and D7 is what moves them.
        let decisions = Matcher(defaults: .standard)
        // PATCH 364. `init(directory:)` and NOT `PlanMoveStore.shared` — the
        // shared store will be hydrated from the database eventually, and a
        // read-back that asked it would compare the database against itself.
        // §12.91.2, fourth store. It also does not touch `StoreReadJournal`,
        // which is that seam's own rule.
        let moves = PlanMoveStore(directory: dir)
        return AuthoredSources(
            notes: Array(notes.all.values),
            commutes: Array(commutes.decisions.values),
            decisions: Array(decisions.decisions.values),
            moves: moves.all,
            notesLoad: notes.lastLoad,
            commutesLoad: commutes.lastLoad,
            decisionsLoad: decisions.lastLoad,
            movesLoad: moves.lastLoad,
            directoryFound: true)
    }

    // MARK: The six that cost one read

    /// Patch 317 — D6c slice 6a. `athlete_profile`, `resting_month`, `hr_zone`.
    ///
    /// **ITS APP SIDE IS THREE HYDRATED STORES AND HAS BEEN SINCE 346 — patch
    /// 389, §12.133.** `ConstantsStore.shared.c`, `AthleteStore.shared.ftp` and
    /// `.hrZones` are all handed over by `HydrationPlanner.Instruction.hydrate`,
    /// so this row has compared the database against itself for forty-two
    /// patches while drawing the same as a row that could disagree. 343 wrote
    /// the rule for the plan in this very file; B1 applied it to the plan and
    /// not to the athlete beside it.
    ///
    /// **`.zones` IS THE WHOLE ANSWER AND THAT IS CHECKED, NOT ASSUMED** —
    /// §12.60.1. `AthleteStore.zonesServedFrom` is the half `StoreSource
    /// .partial(fromDatabase: "zones and FTP", …)` names, so it covers the FTP
    /// by construction. The constants have no `ExpectationField` because no
    /// verifier comparison reads them — and they cannot be fed while the zones
    /// are not, because both are NON-OPTIONAL associated values of the single
    /// `.hydrate` case and are applied by two unconditional statements in
    /// `Sub4Launch.apply`. One determines the other; there is no build that
    /// separates them.
    ///
    /// That the constants and `resting_month` are compared by NOTHING ELSE is a
    /// real gap and it is recorded in CLAUDE.md §5.5 rather than papered over
    /// here. This row is their only check, and it is this row.
    static func athlete(_ db: Sub4Database)
    async -> (load: AthleteLoad, report: AthleteRoundTrip.Report,
              source: ReadBackSource) {
        let load = await Task.detached(priority: .utility) {
            AthleteRepository.load(db)
        }.value
        return (load, AthleteRoundTrip.compare(store: ConstantsStore.shared.c,
                                               storeFTP: AthleteStore.shared.ftp,
                                               storeZones: AthleteStore.shared.hrZones,
                                               database: load),
                .liveStores([.from(.zones,
                                   "the zones, the FTP and the constants beside them")]))
    }

    /// Patch 322 — D6c slice 5b. `user_note` and `correction`.
    ///
    /// PATCH 355 ADDS `match_decision`, and it is a THIRD VALUE out of ONE
    /// read-back rather than a tenth entry in the roll-up. The roll-up's nine
    /// rows are load-bearing in D7's entry gate and "9 of 9" is written down in
    /// several places; a tenth would change what that sentence means in all of
    /// them. Match decisions are authored data, on the same screen, refreshed
    /// by the same write-through — one family, one row.
    ///
    /// **THE ROW A FIELD-ONLY DERIVATION WOULD GET WRONG — patch 389.** It
    /// reads `.notes`, `.commutes`, `.matchDecisions` and `.moves`, every one
    /// of which the database feeds, and it is real evidence anyway because 356
    /// gave it `authoredSources()`. `ReadBackSource.ownRead` is what says so,
    /// and `sources.line` is the same sentence the section already prints.
    static func authored(_ db: Sub4Database)
    async -> (load: AuthoredLoad, report: AuthoredRoundTrip.Report,
              decisions: MatchDecisionLoad, moves: PlanMoveLoad,
              source: ReadBackSource) {
        let load = await Task.detached(priority: .utility) {
            AuthoredRepository.load(db)
        }.value
        // BOTH READS OFF THE ACTOR, one after the other, for the reason at
        // the top of this file: a database read is not this screen's to block
        // on. The comparison stays on it — `Matcher` is a main-actor
        // singleton, like every other store compared here. §12.9c.
        let decisionLoad = await Task.detached(priority: .utility) {
            MatchDecisionRepository.load(db)
        }.value
        // PATCH 364, off the actor like the two above it and for the same
        // reason: a database read is not this screen's to block on.
        let moveLoad = await Task.detached(priority: .utility) {
            PlanMoveRepository.load(db)
        }.value

        // PATCH 356 — THE FILES, NOT THE STORES, AND THIS IS THE WHOLE PATCH.
        //
        // This read the three singletons. From B2 they are hydrated FROM the
        // database, so comparing the database against them would be the
        // database against itself: three counts, guaranteed to agree, on the
        // read-back that passed D7's entry gate. §12.69, §12.91.2.
        //
        // TODAY THIS CHANGES NO NUMBER. The stores ARE these sources until B2
        // hydrates them, so every count below must come back unchanged — which
        // is exactly what makes this half checkable on its own. 343's argument,
        // applied to two files and a `UserDefaults` blob.
        let sources = authoredSources()

        var report = AuthoredRoundTrip.compare(
            storeNotes: sources.notes,
            storeCommutes: sources.commutes,
            database: load)
        AuthoredRoundTrip.compareDecisions(
            store: sources.decisions,
            database: decisionLoad,
            into: &report)
        AuthoredRoundTrip.compareMoves(
            store: sources.moves,
            database: moveLoad,
            into: &report)
        report.appSideCameFrom = sources.line
        report.appSideWasReadCleanly = sources.isTrustworthy
        // PATCH 413. The authority for the table the two families share, taken
        // here because this is the one place that holds the database AND both
        // readers' results — §12.130.1, ask the thing that owns the answer.
        report.correctionRowsInDatabase = CorrectionCensus.rows(in: db)
        // THE PROVENANCE IS THE REPORT'S OWN SENTENCE, not a second one written
        // beside it. Two strings describing one read is how they come to say
        // different things — §12.127.5.
        return (load, report, decisionLoad, moveLoad, .ownRead(sources.line))
    }

    /// Patch 323 and 326 — D6c slices 6b and 6c, read together because the
    /// screen shows them together and both describe one plan version.
    ///
    /// TWO READS RATHER THAN ONE THAT RETURNS EVERYTHING: the trimmings are a
    /// separate claim and a separate report, so a red row says which half
    /// broke.
    ///
    /// **THE ROW THAT GOT THIS RIGHT FIRST — 343, and patch 389 is where its
    /// answer becomes machine-readable.** Both halves take the bundle, so both
    /// are `.ownRead` however much of the plan the database feeds.
    static func plan(_ db: Sub4Database)
    async -> (load: PlanLoad, report: PlanRoundTrip.Report,
              extrasLoad: PlanExtrasLoad, extrasReport: PlanExtrasRoundTrip.Report,
              source: ReadBackSource) {
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
        return (load, report, extras, extrasReport,
                .ownRead("the bundled plan.json, decoded fresh"))
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
    ///
    /// **STILL EVIDENCE, AND `knownActivityIDs` IS THE PART THAT IS NOT** —
    /// §12.126.3. The weather readings come from `WeatherStore` and the gear
    /// from the half of `AthleteStore` B1 did not take, so both VALUES are
    /// file-backed until B5; only the id FILTER is database-derived, and a
    /// filter that shrinks makes a check fail rather than pass. The declaration
    /// names the two fields whose values it reads, which is what decides the
    /// classification.
    static func weatherGear(_ db: Sub4Database)
    async -> (load: WeatherGearLoad, report: WeatherGearRoundTrip.Report,
              source: ReadBackSource) {
        let load = await Task.detached(priority: .utility) {
            WeatherGearRepository.load(db)
        }.value
        return (load, WeatherGearRoundTrip.compare(
            storeWeather: Array(WeatherStore.shared.byActivity.values),
            storeGear: AthleteStore.shared.allGear,
            knownActivityIDs: Set(ActivityStore.shared.activities.map(\.id)),
            database: load),
                .liveStores([.from(.weather, "the readings the store holds"),
                             .from(.gear, "AthleteStore's file half")]))
    }

    /// Patch 327 — D6c slice 7. Six review tables.
    ///
    /// **INDEPENDENT BECAUSE NOTHING FEEDS IT YET, WHICH IS NOT THE SAME AS
    /// INDEPENDENT BY ITS OWN READ** — patch 389, and the distinction is the
    /// point of `ReadBackSource`'s third mark. `ProposalStore` is a live store;
    /// the day B7 hydrates it, this row becomes self-referential and the paste
    /// will say so on that run rather than six patches later.
    static func review(_ db: Sub4Database)
    async -> (load: ReviewTrailLoad, report: ReviewRoundTrip.Report,
              source: ReadBackSource) {
        let load = await Task.detached(priority: .utility) {
            ReviewRepository.load(db)
        }.value
        return (load, ReviewRoundTrip.compare(
            storeRecords: ProposalStore.shared.records,
            database: load),
                .liveStores([.from(.reviews)]))
    }

    // MARK: The three that cost a great deal more

    /// Patch 289. 674 activities, nineteen named fields each.
    ///
    /// **SELF-REFERENTIAL FROM 382 TO 390, AND B3's OVERDUE DEBT.** 381 gave
    /// `ShadowParity` its own read of `activities.json` through
    /// `ActivitySource.read()` and did not touch this function, so this row
    /// compared the hydrated store against the rows it was hydrated from for
    /// eight patches — 694 activities × nineteen fields, drawn exactly like a
    /// row that could disagree. 389 printed the fact; this fixes it.
    ///
    /// **THE SOURCE FOLLOWS WHAT WAS ACTUALLY READ, INCLUDING ON THE
    /// FALLBACK.** If `activities.json` cannot be read the store is compared,
    /// and the row says `self-referential` rather than `own read` — so the
    /// fifth count goes back up and the fallback is impossible to miss. That is
    /// 389's machinery doing the shouting instead of a new field.
    static func activities(_ db: Sub4Database)
    async -> (load: ActivityLoad, report: ActivityRoundTrip.Report?,
              source: ReadBackSource) {
        let own = ActivitySource.read()
        let store = own.isTrustworthy ? own.activities
                                      : ActivityStore.shared.activities
        let load = ActivityRepository.all(db)
        return (load, load.activities.map {
            ActivityRoundTrip.compare(store: store, database: $0)
        }, own.isTrustworthy
            ? .ownRead(own.line)
            : .fellBackToStores(why: own.line,
                                [.from(.activities, "nineteen fields each")]))
    }

    /// Patch 291. 674 details, and every split, lap and best effort inside
    /// them.
    ///
    /// **ITS OWN READ SINCE 390**, under the rule 381 made general and §12.126.3
    /// restated: a read-back gets its own read in the slice that hydrates its
    /// own store. B4 hydrates the details, so B4 does this.
    ///
    /// TODAY IT CHANGES NO NUMBER — `DetailStore` still serves these files, so
    /// the store and the files hold the same 694 — which is exactly what makes
    /// this half checkable on its own. 381's sentence, one store over.
    static func details(_ db: Sub4Database)
    async -> (load: DetailLoad, report: DetailRoundTrip.Report?,
              source: ReadBackSource) {
        let own = DetailSource.read()
        // PATCH 394 — its own half. See `DetailSource.Read.detailsAreTrustworthy`.
        let store = own.detailsAreTrustworthy ? Array(own.details.values)
                                              : Array(DetailStore.shared.details.values)
        let load = ActivityDetailRepository.all(db)
        return (load, load.details.map {
            DetailRoundTrip.compare(store: store, database: $0)
        }, own.detailsAreTrustworthy
            ? .ownRead(own.line)
            : .fellBackToStores(why: own.line,
                                [.from(.details,
                                       "every split, lap and best effort")]))
    }

    /// Patch 294. THE ONLY ONE THAT WALKS SAMPLES — roughly 1.5 million
    /// comparisons across 668 recordings, which is why it is the one read-back
    /// whose comparison runs off the main actor as well as its read.
    ///
    /// **THE 1.5 MILLION IS COMPARISONS, NOT ROWS, AND THE TWO HAVE BEEN READ
    /// AS ONE** — patch 389. `recording_sample` held **199,848 rows** on the
    /// device at 388, and 392's export put the comparison count at
    /// **1,453,877** — the streams every recording actually carries, not eight
    /// times the rows. §5.6 and B4's groundwork both carried the row count as
    /// 1.5 M, which is an order of magnitude wrong in the direction that makes
    /// B4's launch-cost question look worse than it is.
    ///
    /// **ITS OWN READ SINCE 390**, for `details` above's reason and with more at
    /// stake: this is the comparison that walks every sample, so after 392 it
    /// would be 199,848 rows of the database agreeing with itself.
    ///
    /// The read is the SAME one `details` makes — `DetailSource.read()` returns
    /// both dictionaries out of one `DetailStore(directory:)`, because they come
    /// out of one store and reading the container twice would be two answers to
    /// one question. Each read-back calls it for its own half; the roll-up runs
    /// them in sequence, so that is two constructions per roll-up and 19 MB of
    /// JSON decoded twice. **Named rather than optimised away**: caching it
    /// would mean a value that outlives the press, and §12.57 is what that
    /// costs. If it becomes slow enough to matter, the fix is one read passed to
    /// both, not a cache.
    ///
    /// No separate load type: the report carries the read's own outcome,
    /// because the id read failing means everything under it is unknown rather
    /// than zero. §12.15.
    static func recordings(_ db: Sub4Database)
    async -> (report: RecordingRoundTrip.Report, source: ReadBackSource) {
        let own = DetailSource.read()
        // PATCH 394 — its own half. A detail file that will not decode is not
        // this comparison's problem; 390 made it one.
        let store = own.tracesAreTrustworthy ? Array(own.streams.values)
                                             : Array(DetailStore.shared.streams.values)
        return (await RecordingRoundTrip.compareOffMain(db, store: store),
                own.tracesAreTrustworthy
                    ? .ownRead(own.line)
                    : .fellBackToStores(why: own.line,
                                        [.from(.traces,
                                               "every sample in every series")]))
    }
}
