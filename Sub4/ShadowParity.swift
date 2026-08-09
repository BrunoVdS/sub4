//
//  ShadowParity.swift
//  Sub4
//
//  D6c — one run, every slice. Patch 313, groundwork §7, ADR-0003 §12.57.
//
//  WHY THIS EXISTS, AND IT IS A CORRECTION TO 312
//  ----------------------------------------------
//  312 put the running and the holding inside `ActivityParity`, because there
//  was one slice and one place to put them. Slice 2 made two things wrong with
//  that, and both are worth naming rather than quietly fixing.
//
//  **A second button would read the database twice.** Both slices need the same
//  672-row read and the same `ActivityRoster.settle`. Running them separately
//  would do that work twice for no reason — and worse, somebody who pressed one
//  and not the other would get an answer that looked complete and was half.
//  Groundwork §7 said the roll-up arrives when there is more than one slice.
//  There is.
//
//  **The result evaporated on Done.** `@State` on a sheet is discarded when the
//  sheet is dismissed, so the diagnostics paste — the thing that gets read later
//  by somebody who was not there — said *"Not compared since this launch"* a
//  minute after the comparison passed. The line was true of that `@State` and
//  false about the world, which is §12.15's shape wearing a fresh coat.
//
//  So the result lives on a singleton, like `DatabaseWriteThrough` since 302,
//  and survives dismissal within a launch. Not persisted: the question it
//  answers is "does the database agree with the app right now", and a stored
//  answer from three launches ago would be a second answer to a question the
//  current data already settles — §12.29's problem.
//
//  ONLY PARITY MOVES. The three read-backs and the survey keep their `@State`
//  and their current behaviour. Changing five things to fix one is how a slice
//  patch stops being checkable.
//
//  FIVE SLICES AT 321, AND TWO OF THEM CAN BE NIL
//  ----------------------------------------------
//  `LoadParity` needs the app's own load series and the inputs the last rebuild
//  used. Both exist on `LoadStore` after one recompute, and this asks for one
//  before comparing — but `lastInputs` is nil on a device that has never built
//  a series, so the slice is optional.
//
//  `DetailParity` needs a detail read that worked. `ActivityDetailRepository`
//  can come back `.failed`, and a comparison against nothing is not a
//  comparison.
//
//  SLICE 5 IS NOT ONE OF THEM. Matching needs the plan, the decisions and two
//  activity lists, and all four exist on any launch — there is no state in
//  which it cannot run, so making it optional would have invented a case to
//  handle rather than described one.
//
//  A NIL SLICE COUNTS AS ONE DIFFERENCE, not as zero. A comparison that could
//  not run is no answer, and every version of this screen that has treated
//  those two as the same has had to be corrected.
//
//  EVERY SLICE IS A PURE COMPARISON
//  --------------------------------
//  Each takes its two sides and returns a `Report`. None reads a database, a
//  store or a clock. That is what lets a test build their two sides from
//  genuinely different places, and it is the property each new slice inherits
//  for free.
//
//  ONE READ PER TABLE GROUP, STILL. Slice 4 adds a detail read to the same
//  pass rather than a second button, for the reason at the top of this file:
//  a screen where somebody can run half the comparison is a screen that reports
//  half an answer as a whole one.
//

import Foundation

@MainActor
@Observable
final class ShadowParity {

    static let shared = ShadowParity()

    private init() {}

    /// What the last run produced.
    ///
    /// `.never` is not agreement and not a failure — the eighth instance of
    /// §12.15's shape in this project, and the reason this is an enum rather
    /// than an optional report.
    enum Outcome: Equatable {
        case never
        case ran(activities: ActivityParity.Report,
                 volume: VolumeParity.Report,
                 load: LoadParity.Report?,
                 details: DetailParity.Report?,
                 matches: MatchParity.Report,
                 /// Slice 8 — patch 330. Nil when the plan could not be read
                 /// from the database, which is the one input this slice needs
                 /// and no other slice does.
                 summaries: SummaryParity.Report?)
        /// The launch gate never opened one. Not the same as a read failing.
        case noDatabase
        case readFailed(String)

        var line: String {
            switch self {
            case .never:
                "Not compared since this launch."
            case .ran(let a, let v, let l, let d, let m, let s):
                Self.total(a, v, l, d, m, s) == 0
                    ? "\(a.common) activities · \(v.daysCompared) days · no differences"
                    : "\(Self.total(a, v, l, d, m, s)) differences"
            case .noDatabase:
                "The database is not open, so nothing was derived."
            case .readFailed(let why):
                "The database could not be read — \(why)"
            }
        }

        /// `.never` is healthy. Not having looked is not a fault; looking and
        /// disagreeing is, and so is looking at nothing.
        var isHealthy: Bool {
            switch self {
            case .never:                true
            // A SLICE THAT COULD NOT RUN IS NOT A PASS. `load` is nil when the
            // app's own series has not been built yet and `details` is nil when
            // the detail read failed; treating a missing comparison as a clean
            // one is the whole family of defect this screen keeps correcting.
            case .ran(let a, let v, let l, let d, let m, let s):
                a.isHealthy && v.isHealthy
                && (l?.isHealthy ?? false) && (d?.isHealthy ?? false)
                && m.isHealthy && (s?.isHealthy ?? false)
            case .noDatabase, .readFailed: false
            }
        }

        /// The six slices' differences, or zero when there is nothing to
        /// count. A slice that could not run contributes ONE — it is not zero
        /// differences, it is no answer.
        static func total(_ a: ActivityParity.Report,
                          _ v: VolumeParity.Report,
                          _ l: LoadParity.Report?,
                          _ d: DetailParity.Report?,
                          _ m: MatchParity.Report,
                          _ s: SummaryParity.Report?) -> Int {
            a.unexplained + v.unexplained
            + (l?.unexplained ?? 1) + (d?.unexplained ?? 1)
            + m.unexplained + (s?.unexplained ?? 1)
        }

        var activities: ActivityParity.Report? {
            if case .ran(let a, _, _, _, _, _) = self { return a }
            return nil
        }

        var volume: VolumeParity.Report? {
            if case .ran(_, let v, _, _, _, _) = self { return v }
            return nil
        }

        /// Nil when the app's own load series had not been built when the
        /// comparison ran. `ShadowParity.run` asks for it first, so this should
        /// only ever be nil on a device with no training in it at all.
        var load: LoadParity.Report? {
            if case .ran(_, _, let l, _, _, _) = self { return l }
            return nil
        }

        /// Nil when the detail read itself failed — patch 320. Not the same as
        /// a device with no details, which compares zero of zero and is caught
        /// by `lookedAtSomething` instead.
        var details: DetailParity.Report? {
            if case .ran(_, _, _, let d, _, _) = self { return d }
            return nil
        }

        /// Slice 5 — patch 321. Never nil: matching needs the plan, the
        /// decisions and two activity lists, and all four exist on any launch.
        /// Slice 8 — patch 330. Nil when `PlanRepository.load` did not return
        /// a plan: this is the only slice that reads one, so it is the only
        /// one that can be nil for that reason.
        var summaries: SummaryParity.Report? {
            if case .ran(_, _, _, _, _, let s) = self { return s }
            return nil
        }

        var matches: MatchParity.Report? {
            if case .ran(_, _, _, _, let m, _) = self { return m }
            return nil
        }

        /// Every slice's lines, or the reason there are none. Unconditional —
        /// 266c's rule, and the paste is where this patch's own defect showed.
        var diagnosticLines: [String] {
            switch self {
            case .ran(let a, let v, let l, let d, let m, let s):
                a.diagnosticLines + [""] + v.diagnosticLines + [""]
                + (l?.diagnosticLines
                   ?? ["Load parity: the app's own load series was not built"])
                + [""]
                + (d?.diagnosticLines
                   ?? ["Detail parity: the details could not be read"])
                + [""] + m.diagnosticLines + [""]
                + (s?.diagnosticLines
                   ?? ["Summary parity: the plan could not be read from the database"])
            case .never, .noDatabase, .readFailed:
                ["Shadow parity: \(line)"]
            }
        }
    }

    private(set) var last: Outcome = .never
    private(set) var isRunning = false
    /// Runs since this launch, like `DatabaseWriteThrough.runs` and for the
    /// same reason: it answers "is this firing at all", which is about now.
    private(set) var runs = 0

    /// ONE READ, ONE SETTLE, EVERY SLICE.
    ///
    /// OFF THE MAIN ACTOR FOR THE READ, ON IT FOR THE RULES. `ActivityLoad` is
    /// `Sendable` precisely so that hand-off is legal, and `ActivityRoster` is
    /// `@MainActor` because `isKept` reads `MatchRules` and `DataCorrections`.
    ///
    /// The suspension is load-bearing for a second reason: 312 did the read
    /// synchronously inside a `Task`, so `isRunning` went true and false in the
    /// same main-actor hop and the spinner never drew. Nobody noticed, because
    /// the run is fast — which is exactly the kind of thing that stops being
    /// true when a slice is added.
    ///
    /// ONE `settle`, TWO COMPARISONS. Slice 1 is handed the raw rows because it
    /// reports what the rules dropped; slice 2 is handed the settled list
    /// because it compares what the app would show.
    func run(_ db: Sub4Database) async {
        isRunning = true
        defer { isRunning = false }

        let load = await Task.detached(priority: .userInitiated) {
            ActivityRepository.all(db)
        }.value

        switch load {
        case .unavailable:
            last = .noDatabase
        case .failed(let why):
            last = .readFailed(why)
        case .loaded(let rows, let skipped):
            let twin = ActivityRoster.settle(rows)
            let mine = ActivityStore.shared.activities

            // SLICE 3 — patch 315. The database's traces, read in the same
            // pass, and the app's own series brought up to date so the left
            // hand side is literally what Today and Progress are showing.
            let traces = await Task.detached(priority: .userInitiated) {
                RecordingRepository.all(db).recordings
            }.value
            LoadStore.shared.recomputeIfNeeded()

            // SLICE 4 — patch 320. Read in the same pass for the same reason
            // the traces are: a second button is a way to see half an answer.
            let storedDetails = await Task.detached(priority: .userInitiated) {
                ActivityDetailRepository.all(db).details
            }.value

            last = .ran(activities: ActivityParity.compare(store: mine,
                                                           databaseRows: rows,
                                                           databaseSkipped: skipped),
                        volume: VolumeParity.compare(store: mine,
                                                     database: twin.activities),
                        load: loadReport(twin: twin.activities, traces: traces),
                        details: detailReport(storedDetails),
                        matches: matchReport(twin: twin.activities),
                        // SLICE 8 — patch 330. Reads the plan from the
                        // database, which no other slice does. Same pass as
                        // the rest for §12.57's reason: a second button is a
                        // way to see half an answer.
                        summaries: await summaryReport(twin: twin.activities,
                                                       db: db))
            runs += 1
        }
    }

    /// The twin load series, and the comparison against the app's own.
    ///
    /// THE INPUTS ARE THE APP'S, TAKEN NOT RE-GATHERED. `LoadStore` remembers
    /// what its last rebuild used, and this changes exactly one field of it —
    /// the traces. Re-reading the stores here would be a second implementation
    /// of that gathering, and the two would eventually disagree about an sRPE
    /// or a power factor with nothing able to say which was right.
    ///
    /// A COST THAT COMES WITH THAT, stated rather than left to be found: sRPE
    /// and Apple Health are keyed by activity id and were gathered over the
    /// APP's list. An activity the database has and the app does not would
    /// therefore score without either. Slice 1 reports that case directly as
    /// `In the database only`, so it is visible — but it is visible there and
    /// not here.
    private func loadReport(twin: [Activity],
                            traces: [ActivityStreams]?) -> LoadParity.Report? {
        guard var inputs = LoadStore.shared.lastInputs else { return nil }
        inputs.streams = Dictionary((traces ?? []).map { ($0.activityId, $0) },
                                    uniquingKeysWith: { first, _ in first })

        let theirs = LoadSeries.build(from: MatchRules.cutoffDayKey,
                                      to: DayKey.key(),
                                      byDay: ActivityRoster.byDay(twin),
                                      inputs: inputs)
        // THE ZONES ARE HELD FROM THE APP, like the constants — patch 316.
        // `hr_zone` is in the database and has no reader yet, and bucketing
        // both sides with the same boundaries is what makes a difference in
        // the zone rows mean the trace rather than the boundaries.
        return LoadParity.compare(app: LoadStore.shared.days, database: theirs,
                                  zones: AthleteStore.shared.hrZones)
    }

    /// Slice 5 — patch 321.
    ///
    /// ONE RESOLVER, TWO ACTIVITY LISTS. Every day carrying a planned session
    /// or an activity on either side is resolved twice through
    /// `MatchResolver.day` — the app's own function, extracted and unchanged.
    ///
    /// THE PLAN DAYS ARE IN THE SET, not just the activity days. A session on a
    /// day with no activity still resolves, still counts towards adherence, and
    /// would be invisible to a walk over activity days alone. Slice 1's 324 days
    /// are the activities; the plan adds its own.
    ///
    /// The decisions come from `Matcher` on BOTH sides. `match_decision` is in
    /// the database with no reader, and reading it would make a difference here
    /// mean either the activities or the overrides — the same argument §12.61.1
    /// made for the athlete constants.
    private func matchReport(twin: [Activity]) -> MatchParity.Report {
        let mine = ActivityRoster.byDay(ActivityStore.shared.activities)
        let theirs = ActivityRoster.byDay(twin)
        let decisions = Matcher.shared.decisions
        let days = Set(mine.keys).union(theirs.keys)
            .union(PlanStore.shared.byDate.keys)

        var app: [String: MatchResolver.Day] = [:]
        var database: [String: MatchResolver.Day] = [:]
        for day in days {
            let sessions = PlanStore.shared.sessions(on: day)
            app[day] = MatchResolver.day(sessions: sessions,
                                         activities: mine[day] ?? [],
                                         decisions: decisions, dayKey: day)
            database[day] = MatchResolver.day(sessions: sessions,
                                              activities: theirs[day] ?? [],
                                              decisions: decisions, dayKey: day)
        }
        return MatchParity.compare(app: app, database: database)
    }

    /// Slice 8 — patch 330, the last of D6c.
    ///
    /// THE ONLY SLICE THAT READS THE PLAN. Every other one calls
    /// `PlanStore.shared` for both sides — see `matchReport` directly above —
    /// so the plan is HELD and `PlanRoundTrip` verifies it separately. This
    /// one asks the database, which makes the planned figures a comparison
    /// rather than the same input twice, and makes this the closest thing on
    /// the screen to what D7 will do.
    ///
    /// `todayKey` IS READ ONCE. Both sides are handed the same string. Reading
    /// it per side is a race that only shows up across midnight, which is
    /// exactly when nobody is looking — the slice-8 addendum §3.
    ///
    /// THE CLOSURES COUNT WHAT THEY WERE ASKED. A closure that returns an
    /// empty day for a key the database has nothing for is indistinguishable
    /// from a day that holds nothing, and every other figure here is per WEEK
    /// so a missing DAY would barely move one. Addendum §2.
    private func summaryReport(twin: [Activity],
                               db: Sub4Database) async -> SummaryParity.Report? {
        let plan = await Task.detached(priority: .userInitiated) {
            PlanRepository.load(db)
        }.value
        guard let dbWeeks = plan.weeks, let dbSessions = plan.sessions else {
            return nil
        }

        let todayKey = DayKey.key()
        let decisions = Matcher.shared.decisions
        let mineByDay = ActivityRoster.byDay(ActivityStore.shared.activities)
        let theirsByDay = ActivityRoster.byDay(twin)
        let dbByDate = Dictionary(grouping: dbSessions.filter { $0.date != nil },
                                  by: { $0.date! })

        var askedApp = 0, hadApp = 0
        var askedDatabase = 0, hadDatabase = 0

        let appPoints = TabSummary.weekPoints(
            weeks: PlanStore.shared.planWeeks,
            sessions: PlanStore.shared.plan.sessions,
            todayKey: todayKey,
            day: { key in
                askedApp += 1
                let sessions = PlanStore.shared.sessions(on: key)
                let acts = mineByDay[key] ?? []
                if !sessions.isEmpty || !acts.isEmpty { hadApp += 1 }
                return MatchResolver.day(sessions: sessions, activities: acts,
                                         decisions: decisions, dayKey: key)
            })

        let databasePoints = TabSummary.weekPoints(
            weeks: dbWeeks,
            sessions: dbSessions,
            todayKey: todayKey,
            day: { key in
                askedDatabase += 1
                let sessions = dbByDate[key] ?? []
                let acts = theirsByDay[key] ?? []
                if !sessions.isEmpty || !acts.isEmpty { hadDatabase += 1 }
                return MatchResolver.day(sessions: sessions, activities: acts,
                                         decisions: decisions, dayKey: key)
            })

        // ASKED FOR THE SAME DAYS OR THE COMPARISON IS NOT ONE. Both walks
        // cover their own weeks' seven days, so the counts diverge only if the
        // two sides disagree about which weeks have begun — which the week
        // figures would also show, but this says it in days.
        let asked = max(askedApp, askedDatabase)

        return SummaryParity.compare(
            app: appPoints,
            database: databasePoints,
            appActual: TabSummary.actualVolume(ActivityStore.shared.activities),
            databaseActual: TabSummary.actualVolume(twin),
            appPlanned: PlanStore.plannedVolume(
                sessions: PlanStore.shared.plan.sessions,
                weeksByUid: PlanStore.shared.weeksByUid),
            databasePlanned: PlanStore.plannedVolume(
                sessions: dbSessions,
                weeksByUid: Dictionary(dbWeeks.map { ($0.uid, $0) },
                                       uniquingKeysWith: { a, _ in a })),
            planSessionsInApp: PlanStore.shared.plan.sessions.count,
            planSessionsInDatabase: dbSessions.count,
            daysAskedFor: asked,
            daysWithContentInApp: hadApp,
            daysWithContentInDatabase: hadDatabase)
    }

    /// Slice 4 — patch 320.
    ///
    /// NIL ONLY WHEN THE READ ITSELF FAILED. A device that holds no details at
    /// all still gets a report, and `lookedAtSomething` is what refuses to call
    /// that a pass — the two states are different and the screen says which.
    ///
    /// Nothing is swapped, unlike the load slice: both sides are whole details,
    /// and the only thing that differs between them is where they came from.
    private func detailReport(_ database: [ActivityDetail]?) -> DetailParity.Report? {
        guard let database else { return nil }
        return DetailParity.compare(app: Array(DetailStore.shared.details.values),
                                    database: database)
    }
}
