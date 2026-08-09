//
//  Review.swift
//  Sub4
//
//  The monthly review — computation only, no UI, no network.
//
//  WHAT THIS IS FOR
//  ----------------
//  The plan is a hypothesis written by an AI with no knowledge of how any of it
//  would feel. Once a month the question is: is the block landing where it
//  should, or does it need to get easier or harder?
//
//  ARITHMETIC IS NOT A JUDGEMENT CALL
//  ----------------------------------
//  Everything in this file is computed. Adherence, volume, mean RPE, pace
//  deviation — none of it is inferred, estimated or asked of a model. That
//  matters because a wrong number here is invisible: it looks exactly like a
//  right number, and it would be believed. If a language model is ever wired in
//  (see the export below), it receives THESE FACTS and reasons about them. It
//  never gets the raw data and a calculator.
//
//  THE THRESHOLDS ARE MINE, NOT THE PLAN'S
//  ---------------------------------------
//  The flags at the bottom fire on fixed numbers — easy runs averaging RPE 6,
//  adherence under 70%, and so on. The plan states none of these. They are
//  training-literature conventions, and they are wrong for somebody. So every
//  threshold is a named constant in `Thresholds`, printed in the report next to
//  the flag it fired, and adjustable in one place. A hidden threshold is a
//  guess wearing a fact's clothing.
//
//  COVERAGE COMES FIRST
//  --------------------
//  A review over four weeks where half the sessions have no note and a third
//  never matched an activity says nothing about the plan — it says something
//  about the logging. `coverage` is computed first and reported first for
//  exactly that reason, and there is a flag that says "conclude nothing" when
//  it is too thin.
//

import Foundation

struct Review {

    // MARK: Thresholds — every number the flags below fire on

    enum Thresholds {
        /// Easy running should sit at conversational effort. A mean above this
        /// over a month is the single clearest sign the easy pace bands are
        /// wrong, or that fatigue is not clearing between sessions.
        static let easyRunRPECeiling = 5.5

        /// Below this and the block is not being followed, so nothing can be
        /// concluded about whether it is correctly calibrated.
        static let adherenceFloor = 0.70

        /// Recorded running volume this far under plan is a real gap rather
        /// than rounding.
        static let volumeShortfall = 0.15

        /// Proportion of sessions marked "harder than the target" above which
        /// the prescription, not the day, is the likely explanation.
        static let harderShare = 0.40

        /// The mirror: consistently easier than asked, at full adherence.
        static let easierShare = 0.50
        static let tooEasyRPECeiling = 3.5

        /// Minimum share of non-rest sessions carrying a note before the RPE
        /// figures mean anything.
        static let noteCoverageFloor = 0.50

        /// Minimum non-rest sessions in the window. Fewer than this and the
        /// window is too short to review at all.
        static let minSessions = 8
    }

    // MARK: Window

    struct Window {
        var weeks: [Week]
        var startDay: String
        var endDay: String
        var label: String
    }

    // MARK: Pieces

    struct Coverage {
        var sessions: Int          // non-rest, in window
        var matched: Int           // have a Strava activity
        var noted: Int             // have a note
        var notedRuns: Int
        var runSessions: Int

        var matchShare: Double { sessions == 0 ? 0 : Double(matched) / Double(sessions) }
        var noteShare: Double { sessions == 0 ? 0 : Double(noted) / Double(sessions) }
    }

    struct DisciplineRow: Identifiable {
        var discipline: Discipline
        var planned: Int
        var done: Int
        var id: String { discipline.rawValue }
        var share: Double { planned == 0 ? 0 : Double(done) / Double(planned) }
    }

    struct WeekRow: Identifiable {
        var label: String
        var plannedKm: Double
        var doneKm: Double
        var plannedExact: Bool
        var done: Int
        var total: Int
        var id: String { label }
    }

    /// RPE and feel grouped by what the session was FOR. This grouping is the
    /// whole point: RPE 8 on a threshold session is the plan working, RPE 8 on
    /// an easy run is the plan failing, and an ungrouped average hides both.
    struct EffortRow: Identifiable {
        var key: String            // "Run · easy", "Bike", …
        var sessions: Int
        var noted: Int
        var meanRPE: Double?
        var easier: Int
        var expected: Int
        var harder: Int
        var id: String { key }

        var harderShare: Double { noted == 0 ? 0 : Double(harder) / Double(noted) }
        var easierShare: Double { noted == 0 ? 0 : Double(easier) / Double(noted) }
    }

    /// One session where the plan stated a pace and the run can be checked
    /// against it. Sessions the plan leaves open, and minute-based intervals
    /// that kilometre splits cannot isolate, are excluded rather than guessed.
    struct PaceRow: Identifiable {
        /// The session uid, not date+title. Two runs on one day with the same
        /// title would collide on a composed key and SwiftUI would silently
        /// drop a row; uid is the uniqueness guarantee the rest of the app
        /// already relies on.
        var uid: String
        var date: String
        var title: String
        var scope: String
        var target: String
        var measured: Int
        var deviation: Int         // seconds/km, + is slower than the slow bound
        var id: String { uid }
    }

    struct Flag: Identifiable {
        enum Level: String { case blocking, warning, note }
        var level: Level
        var title: String
        var detail: String
        var id: String { title }
    }

    // MARK: The report

    var window: Window
    var coverage: Coverage
    var disciplines: [DisciplineRow]
    var weeks: [WeekRow]
    var efforts: [EffortRow]
    var paces: [PaceRow]
    var flags: [Flag]
    var notes: [(day: String, title: String, note: NotesStore.Note)]

    var plannedKm: Double { weeks.reduce(0) { $0 + $1.plannedKm } }
    var doneKm: Double { weeks.reduce(0) { $0 + $1.doneKm } }
    var sessionsDone: Int { weeks.reduce(0) { $0 + $1.done } }
    var sessionsTotal: Int { weeks.reduce(0) { $0 + $1.total } }
    var adherence: Double {
        sessionsTotal == 0 ? 0 : Double(sessionsDone) / Double(sessionsTotal)
    }
}

// MARK: - Lineage

/// WHICH DATA SOURCES A REVIEW PACK IS DERIVED FROM — patch 335, §12.83.
///
/// ADR-0002 requires that every stored piece of review evidence with Strava
/// lineage can be found and removed while the verdict stands. That is a query,
/// so lineage has to be queryable, and `review_evidence_source` is where it
/// goes. Nothing had ever written it: zero rows on every device since
/// `2026-08-03-initial`, an obligation unmet by construction rather than by
/// accident. §12.71.3 found it; this closes it.
///
/// A PROPERTY OF THE BUILDER, NOT OF THE PACK — and that is the decision worth
/// recording, because the obvious alternative is wrong.
///
/// The obvious version derives the set per review: mark `authored` only if
/// that month actually had notes, `strava` only if an activity matched. It
/// reads as more precise and it under-reports the exact case a purge exists
/// for. **A pack that consulted Strava and found nothing is still derived from
/// Strava** — "you recorded no runs in this window" is a claim built out of
/// Strava's data, and deleting that data invalidates it just as surely as it
/// invalidates a distance. Lineage is about what was CONSULTED, not what was
/// found.
///
/// It is also what keeps this out of `ProposalStore.Record`. A per-instance
/// set would have to survive `proposals.json`, which means changing a
/// persisted `Codable` shape whose synthesised `init(from:)` does not use
/// Swift default values — a decode failure on every existing record, for
/// precision the purge does not want.
///
/// KEEPING IT HONEST. The list below is the stores `ReviewBuilder.build` binds
/// at its top, one line each, and it sits immediately above them so the two
/// cannot be read apart. When `build` gains a store, this gains a case in the
/// same edit or the Database screen's lineage row starts printing a number
/// that is quietly too small — which is visible, unlike the alternative.
nonisolated enum ReviewLineage {

    /// `PlanStore`      → `bundled`  — the plan ships inside the app
    /// `Matcher`        → `strava`   — every matched activity
    /// `DetailStore`    → `strava`   — splits, laps and traces
    /// `NotesStore`     → `authored` — what the athlete typed
    ///
    /// Not `appleHealth`: `build` reads no Health data today, and claiming a
    /// source that was never consulted would make the purge delete evidence it
    /// has no business touching. Not `weatherProvider` or `device` for the
    /// same reason. This list grows when the builder does, and only then.
    ///
    /// LITERALS RATHER THAN `DataSource` CASES, and that is `Sub4Migrations`'
    /// precedent rather than laziness. Its header makes the argument for
    /// frozen vocabularies: *"deriving them from the enums looked like the
    /// drift-proof choice and is the opposite"*, with the agreement asserted
    /// by test instead. Here there is a second reason on top of that one —
    /// `DataSource` takes the module's MainActor default, and this is read by
    /// `Sub4Import`, which is nonisolated end to end. A `rawValue` reached
    /// across that boundary is the isolation trap CLAUDE.md has recorded five
    /// times.
    ///
    /// Sorted, so the row order in `review_evidence_source` is stable and the
    /// read-back compares sequences rather than sets.
    /// `ReviewLineageVocabularyTests` asserts every id is a real `DataSource`.
    static let sourceIDs: [String] = ["authored", "bundled", "strava"]
}

// MARK: - Builder

enum ReviewBuilder {

    /// Builds a review over the last `weeksBack` plan weeks that have finished.
    ///
    /// Finished, not elapsed: a week still in progress would count its
    /// unstarted sessions as missed and read as a collapse in adherence every
    /// time you opened it mid-week.
    static func build(weeksBack: Int = 4, today: String = DayKey.key()) -> Review? {

        let plan = PlanStore.shared
        let matcher = Matcher.shared
        let notesStore = NotesStore.shared
        let details = DetailStore.shared

        // Weeks whose last session day is strictly before today.
        let finished = plan.planWeeks.filter { w in
            let days = plan.sessions(inWeek: w).compactMap(\.date)
            guard let last = days.max() else { return false }
            return last < today
        }
        guard !finished.isEmpty else { return nil }

        let window = Array(finished.suffix(weeksBack))
        let sessions = window.flatMap { plan.sessions(inWeek: $0) }
        let dated = sessions.filter { $0.date != nil && !$0.isRest }
        guard let start = dated.compactMap(\.date).min(),
              let end = dated.compactMap(\.date).max() else { return nil }

        // MARK: Matching, once
        //
        // Matcher.day() re-runs the whole day's matching on every call, so the
        // results are taken once and reused. Calling it per metric would run
        // the matcher four times over the same month.
        var matchByUid: [String: Activity] = [:]
        for dayKey in Set(dated.compactMap(\.date)) {
            for m in matcher.day(dayKey).matches {
                if let a = m.activity { matchByUid[m.session.uid] = a }
            }
        }

        // MARK: Coverage

        let runSessions = dated.filter { $0.discipline == .run }
        let coverage = Review.Coverage(
            sessions: dated.count,
            matched: dated.filter { matchByUid[$0.uid] != nil }.count,
            noted: dated.filter { notesStore.note(uid: $0.uid) != nil }.count,
            notedRuns: runSessions.filter { notesStore.note(uid: $0.uid) != nil }.count,
            runSessions: runSessions.count)

        // MARK: Adherence by discipline

        var perDiscipline: [Discipline: (Int, Int)] = [:]
        for s in dated {
            var t = perDiscipline[s.discipline] ?? (0, 0)
            t.0 += 1
            if matchByUid[s.uid] != nil { t.1 += 1 }
            perDiscipline[s.discipline] = t
        }
        let disciplines = perDiscipline
            .map { Review.DisciplineRow(discipline: $0.key, planned: $0.value.0, done: $0.value.1) }
            .sorted { $0.planned > $1.planned }

        // MARK: Weekly running volume
        //
        // Planned uses the session-derived estimator, NOT week.stats["km"] —
        // that headline is total multisport volume including the commute, and
        // comparing recorded running against it would show a permanent deficit
        // of over a hundred kilometres a week.

        var weekRows: [Review.WeekRow] = []
        for w in window {
            let ws = plan.sessions(inWeek: w)
            let planned = plan.plannedRunKm(week: w)
            let runs = ws.filter { $0.discipline == .run && !$0.isRest }
            let doneKm = runs.compactMap { matchByUid[$0.uid]?.km }.reduce(0, +)
            // Counted from matchByUid rather than Matcher.adherence(for:).
            // That helper calls isComplete per session, and isComplete re-runs
            // Matcher.day() in full — so it would re-match every day of the
            // window a second time for a number already computed above.
            // PATCH 328a — `SessionTally.counts`, and this is the copy that
            // mattered most. This figure is what the MODEL is told each month.
            // Left as it was, the review would have reported "6 of 8" for a
            // week the athlete's own screens call "6 of 7", and a proposal
            // would have been reasoned out over a plan the athlete does not
            // see. `date != nil` stays: an undated prologue session has no
            // week to belong to, which is a different exclusion. §12.72.7.
            let countable = ws.filter { SessionTally.counts($0) && $0.date != nil }
            let done = countable.filter { matchByUid[$0.uid] != nil }.count
            weekRows.append(.init(label: w.label,
                                  plannedKm: planned.km,
                                  doneKm: doneKm,
                                  plannedExact: planned.exact,
                                  done: done, total: countable.count))
        }

        // MARK: Effort, grouped by what the session was for

        var buckets: [String: [Session]] = [:]
        for s in dated { buckets[groupKey(s), default: []].append(s) }

        var efforts: [Review.EffortRow] = []
        for (key, group) in buckets {
            let ns = group.compactMap { notesStore.note(uid: $0.uid) }
            let rpes = ns.compactMap(\.rpe)
            efforts.append(.init(
                key: key,
                sessions: group.count,
                noted: ns.count,
                meanRPE: rpes.isEmpty ? nil
                    : Double(rpes.reduce(0, +)) / Double(rpes.count),
                easier: ns.filter { $0.feel == .easier }.count,
                expected: ns.filter { $0.feel == .expected }.count,
                harder: ns.filter { $0.feel == .harder }.count))
        }
        efforts.sort { $0.sessions > $1.sessions }

        // MARK: Pace against the plan's own numbers

        var paces: [Review.PaceRow] = []
        for s in runSessions {
            guard let a = matchByUid[s.uid],
                  let target = PaceTarget.parse(s), target.isMeasurable,
                  let d = details.detail(for: a.id),
                  let measured = target.measured(in: d, fallback: a.paceSecPerKm)
            else { continue }
            // Deviation from the nearest edge of the band — inside the band is
            // zero, not "off by the distance to the midpoint".
            let dev: Int
            if measured < target.low { dev = measured - target.low }
            else if measured > target.high { dev = measured - target.high }
            else { dev = 0 }
            paces.append(.init(uid: s.uid,
                               date: s.date ?? "",
                               title: s.title ?? s.kindLabel,
                               scope: target.scopeLabel,
                               target: target.rangeLabel,
                               measured: measured,
                               deviation: dev))
        }
        paces.sort { $0.date < $1.date }

        // MARK: Notes, in order, for the narrative

        var noteRows: [(day: String, title: String, note: NotesStore.Note)] = []
        for s in dated.sorted(by: { ($0.date ?? "") < ($1.date ?? "") }) {
            if let n = notesStore.note(uid: s.uid) {
                noteRows.append((s.date ?? "", s.title ?? s.kindLabel, n))
            }
        }

        var review = Review(
            window: .init(weeks: window, startDay: start, endDay: end,
                          label: windowLabel(window)),
            coverage: coverage,
            disciplines: disciplines,
            weeks: weekRows,
            efforts: efforts,
            paces: paces,
            flags: [],
            notes: noteRows)

        review.flags = flags(for: review)
        return review
    }

    /// "Run · easy" for runs, plain discipline for everything else. Run
    /// intensity is the axis that matters; a bike session has no equivalent.
    private static func groupKey(_ s: Session) -> String {
        s.discipline == .run ? s.kindLabel : s.discipline.label
    }

    private static func windowLabel(_ weeks: [Week]) -> String {
        guard let first = weeks.first, let last = weeks.last else { return "" }
        return first.uid == last.uid
            ? "Week \(first.label)"
            : "Weeks \(first.label)–\(last.label)"
    }

    // MARK: Flags
    //
    // Deterministic rules over the computed facts. Each states the threshold it
    // fired on, because a flag whose rule is hidden cannot be argued with.

    private static func flags(for r: Review) -> [Review.Flag] {
        var out: [Review.Flag] = []
        typealias T = Review.Thresholds     // a type, so typealias — `let` here
                                            // is a compile error, not a shortcut

        // The load engine's contribution: ramp rate, sustained deep freshness
        // and Foster monotony. Appended FIRST so that a "not assessed" note
        // sits near the top rather than after the effort findings — the reader
        // should know what could not be looked at before reading what could.
        out += ReviewLoad.flags(ReviewLoad.assess(startDay: r.window.startDay,
                                                  endDay: r.window.endDay))

        // Blocking: the data cannot support a conclusion.
        if r.coverage.sessions < T.minSessions {
            out.append(.init(level: .blocking, title: "Window too short",
                             detail: "\(r.coverage.sessions) non-rest sessions in "
                             + "\(r.window.label). Below \(T.minSessions) there is "
                             + "nothing to review. Wait for more weeks."))
        }
        if r.coverage.noteShare < T.noteCoverageFloor {
            out.append(.init(level: .blocking, title: "Not enough notes",
                             detail: pct(r.coverage.noteShare)
                             + " of sessions carry a note (floor "
                             + pct(T.noteCoverageFloor) + "). The effort figures "
                             + "below are computed from whatever exists, but they "
                             + "describe the sessions you chose to write about, "
                             + "not the block."))
        }
        if r.adherence < T.adherenceFloor {
            out.append(.init(level: .blocking, title: "Adherence below the floor",
                             detail: pct(r.adherence) + " of sessions completed "
                             + "(floor " + pct(T.adherenceFloor) + "). A plan that "
                             + "is not being followed cannot be judged too hard or "
                             + "too easy — the first question is why sessions are "
                             + "being missed."))
        }

        // Warnings: real signals about calibration.
        for e in r.efforts where e.key.hasPrefix("Run · easy") {
            if let m = e.meanRPE, m > T.easyRunRPECeiling, e.noted >= 3 {
                out.append(.init(level: .warning, title: "Easy runs are not easy",
                                 detail: String(format: "Mean RPE %.1f", m)
                                 + " across \(e.noted) noted easy runs, against a "
                                 + String(format: "ceiling of %.1f", T.easyRunRPECeiling)
                                 + ". Either the easy pace bands are too quick, or "
                                 + "fatigue is not clearing between sessions."))
            }
        }
        for e in r.efforts where e.noted >= 3 && e.harderShare > T.harderShare {
            out.append(.init(level: .warning, title: "\(e.key): harder than asked",
                             detail: "\(e.harder) of \(e.noted) noted sessions marked "
                             + "harder than the target (threshold "
                             + pct(T.harderShare) + "). One session is a bad day; "
                             + "this proportion is the prescription."))
        }
        if r.plannedKm > 0 {
            let short = (r.plannedKm - r.doneKm) / r.plannedKm
            if short > T.volumeShortfall {
                out.append(.init(level: .warning, title: "Running volume short",
                                 detail: String(format: "%.0f km run against %.0f planned — ",
                                                r.doneKm, r.plannedKm)
                                 + pct(short) + " under (threshold "
                                 + pct(T.volumeShortfall) + ")."))
            }
        }

        // The mirror case, deliberately harder to trigger than the overload
        // one: calling a block too easy on thin evidence invites adding load
        // that was not earned.
        let easyish = r.efforts.filter { $0.noted >= 3 }
        if r.adherence >= 0.95, !easyish.isEmpty,
           easyish.allSatisfy({ ($0.meanRPE ?? 99) <= T.tooEasyRPECeiling }),
           easyish.allSatisfy({ $0.easierShare >= T.easierShare }) {
            out.append(.init(level: .note, title: "Possibly under-loaded",
                             detail: "Full adherence, every noted group averaging "
                             + String(format: "RPE %.1f or below", T.tooEasyRPECeiling)
                             + " and mostly marked easier than the target. Worth "
                             + "asking whether the block is asking enough — but one "
                             + "month of easy weeks early in a 34-week plan is what "
                             + "a base phase is supposed to feel like."))
        }

        let slow = r.paces.filter { $0.deviation > 10 }.count
        if r.paces.count >= 3, Double(slow) / Double(r.paces.count) > 0.5 {
            out.append(.init(level: .note, title: "Paced sessions running slow",
                             detail: "\(slow) of \(r.paces.count) sessions with a "
                             + "stated pace finished more than 10 s/km outside the "
                             + "band. Check whether the bands themselves are right "
                             + "before treating this as fitness."))
        }

        if out.isEmpty {
            out.append(.init(level: .note, title: "Nothing flagged",
                             detail: "Adherence, volume and effort are all inside "
                             + "their thresholds for \(r.window.label). No change "
                             + "indicated — which is a result, not an absence of one."))
        }
        return out
    }

    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}

// MARK: - Markdown export
//
// This is deliberately the evidence pack, not a pretty summary. If a Claude
// call is ever added, THIS STRING is what gets sent — so it carries the
// computed facts, the thresholds those facts were judged against, and the raw
// notes, and it states its own coverage honestly at the top. Nothing here is
// rounded away to look tidier than the data is.

extension Review {

    /// The whole review, as sections that know where they came from.
    ///
    /// Every string this app might transmit is built here. `markdown()` renders
    /// all of it for the athlete's own export; `ReviewPayload.render()` renders
    /// only what may leave the phone. Two callers, one source of text.
    func payload() -> ReviewPayload {
        typealias P = ReviewPayload
        var s: [PayloadSection] = []

        s.append(PayloadSection(
            id: "header", title: "Which window, which build",
            what: "The dates this review covers and the app version that computed it.",
            lineage: [.bundled, .device],
            inclusion: P.inclusion(for: [.bundled, .device]),
            body: headerSection()))

        // Matched-to-Strava counts. The share is the whole point of the
        // section and it is a Strava-derived figure.
        s.append(PayloadSection(
            id: "coverage", title: "Coverage",
            what: "How many planned sessions have a recording and a note behind them.",
            lineage: [.strava, .bundled],
            inclusion: P.inclusion(for: [.strava, .bundled]),
            body: coverageSection()))

        // Flags fire on adherence, volume and pace as well as on notes, so the
        // lineage of the flag list is the union of everything it reads.
        s.append(PayloadSection(
            id: "flags", title: "Flags",
            what: "What the app thinks went wrong or right in this window.",
            lineage: [.strava, .authored, .bundled],
            inclusion: P.inclusion(for: [.strava, .authored, .bundled]),
            body: flagsSection()))

        s.append(PayloadSection(
            id: "adherence", title: "Adherence",
            what: "Sessions completed against sessions planned, by discipline.",
            lineage: [.strava, .bundled],
            inclusion: P.inclusion(for: [.strava, .bundled]),
            body: adherenceSection()))

        s.append(PayloadSection(
            id: "volume", title: "Running volume by week",
            what: "Kilometres planned and kilometres run, week by week.",
            lineage: [.strava, .bundled],
            inclusion: P.inclusion(for: [.strava, .bundled]),
            body: volumeSection()))

        // RPE and feel come from what the athlete typed; the session counts
        // come from the bundled plan. No Strava figure reaches this table.
        s.append(PayloadSection(
            id: "effort", title: "Effort by session type",
            what: "Your own RPE and how each session felt against what was asked.",
            lineage: [.authored, .bundled],
            inclusion: P.inclusion(for: [.authored, .bundled]),
            body: effortSection()))

        s.append(PayloadSection(
            id: "paces", title: "Pace against the plan",
            what: "Measured pace against the band the plan asked for.",
            lineage: [.strava, .bundled],
            inclusion: P.inclusion(for: [.strava, .bundled]),
            body: pacesSection()))

        // OPT-IN — PRIV-03. These were in the payload by default, which is
        // consent by omission. They are the most personal thing in the review
        // and the only section whose absence does not break the analysis.
        s.append(PayloadSection(
            id: "notes", title: "Your session notes",
            what: "The words you wrote after a session, verbatim.",
            lineage: [.authored],
            inclusion: P.inclusion(for: [.authored], optIn: true),
            body: notesSection()))

        s.append(PayloadSection(
            id: "thresholds", title: "Thresholds",
            what: "The fixed numbers the flags above fired on. No personal data.",
            lineage: [.bundled],
            inclusion: P.inclusion(for: [.bundled]),
            body: thresholdsSection()))

        return ReviewPayload(sections: s)
    }

    /// The athlete's own copy — everything, no restriction. Byte-identical to
    /// what this function returned before patch 192 split it into sections.
    func markdown() -> String { payload().renderForTheAthlete() }

    // MARK: The sections
    //
    // Split out of one `markdown()` in patch 192 so each can carry its lineage.
    // The text is unchanged; only the seams are new.

    fileprivate func headerSection() -> String {
        var m = "# Sub4 — monthly review\n\n"
        m += "**\(window.label)** · \(window.startDay) → \(window.endDay)\n\n"
        // Which build produced these numbers. An exported analysis that cannot
        // be traced back to a version is unfalsifiable a month later — if a
        // threshold or an estimator changed in between, you want to know.
        m += "_\(AppVersion.stamp)_\n\n"
        return m
    }

    fileprivate func coverageSection() -> String {
        var m = "## Coverage — read this first\n\n"
        m += "| | |\n|---|---|\n"
        m += "| Non-rest sessions | \(coverage.sessions) |\n"
        m += "| Matched to a Strava activity | \(coverage.matched)"
        m += " (\(pct(coverage.matchShare))) |\n"
        m += "| Carrying a note | \(coverage.noted) (\(pct(coverage.noteShare))) |\n"
        m += "| Run sessions noted | \(coverage.notedRuns) of \(coverage.runSessions) |\n\n"
        m += "Everything below is computed from these sessions only. "
        m += "Effort figures describe noted sessions, which may not be a fair "
        m += "sample of all of them.\n\n"
        return m
    }

    fileprivate func flagsSection() -> String {
        var m = "## Flags\n\n"
        for f in flags {
            m += "- **[\(f.level.rawValue)] \(f.title)** — \(f.detail)\n"
        }
        m += "\n"
        return m
    }

    fileprivate func adherenceSection() -> String {
        var m = "## Adherence\n\n"
        m += "Overall **\(sessionsDone)/\(sessionsTotal)** (\(pct(adherence)))\n\n"
        m += "| Discipline | Planned | Done | Share |\n|---|---|---|---|\n"
        for d in disciplines {
            m += "| \(d.discipline.label) | \(d.planned) | \(d.done) | \(pct(d.share)) |\n"
        }
        m += "\n"
        return m
    }

    fileprivate func volumeSection() -> String {
        var m = "## Running volume by week\n\n"
        m += "Planned figures are derived from the sessions themselves, not the "
        m += "plan's weekly headline — that headline is total multisport volume "
        m += "including the bike commute.\n\n"
        m += "| Week | Planned km | Run km | Sessions |\n|---|---|---|---|\n"
        for w in weeks {
            let p = String(format: "%@%.0f", w.plannedExact ? "" : "≈", w.plannedKm)
            m += "| \(w.label) | \(p) | \(String(format: "%.1f", w.doneKm)) "
            m += "| \(w.done)/\(w.total) |\n"
        }
        m += String(format: "| **Total** | **%.0f** | **%.1f** | **%d/%d** |\n\n",
                    plannedKm, doneKm, sessionsDone, sessionsTotal)
        return m
    }

    fileprivate func effortSection() -> String {
        var m = "## Effort by session type\n\n"
        m += "RPE is Borg CR10, self-reported. Feel is relative to what the plan "
        m += "asked for, not absolute difficulty.\n\n"
        m += "| Type | Sessions | Noted | Mean RPE | Easier | As asked | Harder |\n"
        m += "|---|---|---|---|---|---|---|\n"
        for e in efforts {
            let r = e.meanRPE.map { String(format: "%.1f", $0) } ?? "—"
            m += "| \(e.key) | \(e.sessions) | \(e.noted) | \(r) "
            m += "| \(e.easier) | \(e.expected) | \(e.harder) |\n"
        }
        m += "\n"
        return m
    }

    /// Empty when there is nothing to say, exactly as the guard did before.
    fileprivate func pacesSection() -> String {
        guard !paces.isEmpty else { return "" }
        var m = "## Pace against the plan's stated bands\n\n"
        m += "Only sessions where the plan gives a number and kilometre "
        m += "splits can check it. Deviation is from the nearest edge of the "
        m += "band; inside the band is 0.\n\n"
        m += "| Date | Session | Scope | Target | Measured | Deviation |\n"
        m += "|---|---|---|---|---|---|\n"
        for p in paces {
            m += "| \(p.date) | \(p.title) | \(p.scope) | \(p.target) "
            m += "| \(Self.pace(p.measured)) | \(p.deviation >= 0 ? "+" : "")"
            m += "\(p.deviation) s/km |\n"
        }
        m += "\n"
        return m
    }

    fileprivate func notesSection() -> String {
        guard !notes.isEmpty else { return "" }
        var m = "## The notes\n\n"
        for n in notes {
            let rpe = n.note.rpe.map { "RPE \($0)" } ?? "no RPE"
            let feel = n.note.feel?.longLabel ?? "no comparison"
            m += "**\(n.day) · \(n.title)** — \(rpe), \(feel)\n"
            if !n.note.text.isEmpty { m += "\n> \(n.note.text)\n" }
            m += "\n"
        }
        return m
    }

    fileprivate func thresholdsSection() -> String {
        var m = "## Thresholds these flags fired on\n\n"
        m += "These are conventions, not part of the plan, and they are wrong "
        m += "for somebody. They live in `Review.Thresholds`.\n\n"
        m += "| Threshold | Value |\n|---|---|\n"
        m += String(format: "| Easy-run mean RPE ceiling | %.1f |\n",
                    Thresholds.easyRunRPECeiling)
        m += "| Adherence floor | \(pct(Thresholds.adherenceFloor)) |\n"
        m += "| Volume shortfall | \(pct(Thresholds.volumeShortfall)) |\n"
        m += "| \"Harder than asked\" share | \(pct(Thresholds.harderShare)) |\n"
        m += "| Note-coverage floor | \(pct(Thresholds.noteCoverageFloor)) |\n"
        m += "| Minimum sessions | \(Thresholds.minSessions) |\n"
        return m
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    fileprivate static func pace(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Writes the review to a temporary file for the share sheet.
    func writeMarkdown() -> URL? {
        let name = "sub4-review-\(window.startDay)-to-\(window.endDay).md"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        guard let data = markdown().data(using: .utf8) else { return nil }
        do {
            // Temporary, but it holds the same words as the store it came
            // from, so it gets the same protection class — patch 190.
            try data.write(to: url, options: FileProtection.options)
            return url
        } catch {
            return nil
        }
    }
}
