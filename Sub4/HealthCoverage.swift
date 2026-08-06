//
//  HealthCoverage.swift
//  Sub4
//
//  Does Apple Health hold the history? — 4A M0, patch 282, ADR-0003 §12.28.
//
//  WHY THIS EXISTS BEFORE ANY OF THE CUTOVER WORK
//  ----------------------------------------------
//  ADR-0002 decided that Health becomes canonical and Strava is retired, and
//  its follow-up 3 says: "Measure Apple Health coverage back to 1 July 2025
//  BEFORE any purge." Its consequences say why — "the watch may not have been
//  worn, or workouts may have been written by Strava rather than to it" — and
//  name the bulk-export bridge as the contingency if the answer is thin.
//
//  Nothing has ever measured it. Every plan written since assumes the answer.
//
//  WHAT THE RISK ACTUALLY IS, WHICH IS NOT WHAT THE PLAN SAID
//  ---------------------------------------------------------
//  "Workouts written by Strava rather than to it" reads as though those
//  sessions would vanish on a disconnect. They will not: an `HKWorkout` is
//  Apple's the moment it is written, and revoking an API token does not reach
//  into the Health store.
//
//  The real risk is THINNESS. A session that exists in Health only because the
//  Strava app pushed a summary back carries a start, an end, a duration and
//  often nothing else — no route, no heart-rate samples, sometimes no distance.
//  It counts as present and is not a training record. So this report counts
//  what is there AND what state it is in, and reports the writers by name.
//
//  IT MUST BE ABLE TO SAY "I DO NOT KNOW"
//  --------------------------------------
//  `HealthStore.workouts(from:to:)` returns `[]` on a denial, a timeout and an
//  empty store alike — its own comment says "the caller cannot tell a denial
//  from an empty store anyway". For every other caller that is the right trade.
//  For THIS one it is fatal: a diagnostic that answers "Health has nothing"
//  when the truth is "the query never ran" would retire Strava on the strength
//  of a permissions bug.
//
//  So `Reading` is the first field of the report and everything else is read
//  through it. It is `StoreLoad` from patch 273 wearing different clothes, and
//  deliberately so — same failure, same shape of answer.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  -------------------------------
//  1. NO SESSION MATCHING. `HealthReconcile.build` already joins the two sides
//     and is filtered, on both sides, to the sessions the app reasons about —
//     for good reasons written up in its own comments. Coverage is a different
//     question and needs the commutes and the walks. Writing a second matcher
//     to answer it would put two joins in the codebase that disagree, which is
//     the hazard §12.16 refused for CTL.
//
//     So this compares DAYS, not sessions. A day carries a `dayKey` on both
//     sides, needs no tolerance rule, no candidate selection and no `used` set,
//     and cannot drift from `build` because it is not doing what `build` does.
//     Where a day disagrees, `HealthReconcileView` is the tool that inspects
//     it. Recorded as a limit rather than left to be discovered: a day present
//     on both sides is counted as present even if the two sessions on it are
//     different sessions.
//
//  2. NO ROUTES. `HKWorkoutRoute` is one query per workout, and over thirteen
//     months that is several hundred round trips for a diagnostic. Thinness is
//     measured here by distance and heart rate, which arrive with the workout
//     and cost nothing. A route census is worth doing before the purge and is
//     not this.
//

import Foundation

nonisolated enum HealthCoverage {

    /// Why the numbers below are what they are.
    ///
    /// THE FIRST FIELD OF THE REPORT, and the reason this type exists at all.
    /// Four of these five cases produce zeros that mean nothing, and only one
    /// produces zeros that mean "there is nothing there".
    enum Reading: Equatable, Sendable {
        /// The query ran and answered.
        case read
        /// No HealthKit on this device.
        case unavailable
        /// The prompt has never been shown, so nothing was ever permitted.
        case neverAsked
        /// The build cannot ask — `NSHealthShareUsageDescription` is missing.
        case noUsageDescription
        /// It answered with an error, or timed out.
        case failed(String)

        /// The one question every reader of this report has to ask first.
        var isTrustworthy: Bool { self == .read }

        var line: String {
            switch self {
            case .read:               "Health answered."
            case .unavailable:        "NOT MEASURED — HealthKit is not available on this device."
            case .neverAsked:         "NOT MEASURED — the Health prompt has never been shown."
            case .noUsageDescription: "NOT MEASURED — the build has no Health usage description."
            case .failed(let why):    "NOT MEASURED — \(why)"
            }
        }
    }

    /// One month, both sides.
    struct Month: Equatable, Sendable, Identifiable {
        let month: String                  // "2025-07"
        var id: String { month }

        // What Health holds
        var sessions = 0
        var days = 0
        var runs = 0
        var rides = 0
        var swims = 0
        var strength = 0
        var other = 0
        /// Sessions carrying a distance.
        var withDistance = 0
        /// Sessions carrying a mean heart rate.
        var withHeartRate = 0
        /// Sessions naming Strava among the apps that wrote them.
        var stravaWrote = 0
        /// Sessions whose ONLY writer is Strava. These are the summaries — see
        /// the header. Present, countable, and not a training record.
        var stravaAlone = 0

        // What the app holds.
        //
        // COUNTED THE SAME WAY AS HEALTH SINCE 283. The first report counted
        // Health by discipline and the app only in total, so the two sides
        // could not be compared — and on the real data that mattered: Health
        // held 710 sessions to the app's 668, of which 131 were walks and
        // other types the app does not track, which means the app held more of
        // the tracked disciplines. The report had no way to say so.
        var storedSessions = 0
        var storedDays = 0
        var storedRuns = 0
        var storedRides = 0
        var storedSwims = 0
        var storedStrength = 0
        var storedOther = 0

        // Day-level presence, which needs no matcher.
        //
        // THE DATES THEMSELVES SINCE 283, not the counts. "3 training days are
        // in the app and not in Health" is a finding somebody has to act on,
        // and acting on it means opening those three days in the app. A count
        // sends the reader looking; a date sends them to the session.
        var datesHealthOnly: [String] = []
        var datesStoredOnly: [String] = []

        var daysHealthOnly: Int { datesHealthOnly.count }
        var daysStoredOnly: Int { datesStoredOnly.count }

        /// Days on both sides. Not "sessions that agree" — see the header.
        var daysBoth: Int { days - daysHealthOnly }
    }

    struct Report: Equatable, Sendable {
        let reading: Reading
        let months: [Month]
        let generated: String

        /// Every field summed. Days are inside months, so summing them is
        /// sound — a day cannot appear in two buckets.
        var total: Month {
            var t = Month(month: "total")
            for m in months {
                t.sessions += m.sessions; t.days += m.days
                t.runs += m.runs; t.rides += m.rides; t.swims += m.swims
                t.strength += m.strength; t.other += m.other
                t.withDistance += m.withDistance
                t.withHeartRate += m.withHeartRate
                t.stravaWrote += m.stravaWrote
                t.stravaAlone += m.stravaAlone
                t.storedSessions += m.storedSessions
                t.storedDays += m.storedDays
                t.storedRuns += m.storedRuns; t.storedRides += m.storedRides
                t.storedSwims += m.storedSwims
                t.storedStrength += m.storedStrength
                t.storedOther += m.storedOther
                // CONCATENATED, not counted. `daysStoredOnly` is computed from
                // this now, so the total cannot drift from the months under it
                // — which is the failure the first version was one edit away
                // from, since it summed one field and set the other.
                t.datesHealthOnly += m.datesHealthOnly
                t.datesStoredOnly += m.datesStoredOnly
            }
            return t
        }

        /// Months where the app has training days Health does not. THE ANSWER
        /// TO M0 in one list: every one of these is a day the disconnect would
        /// destroy with nothing to put in its place.
        var monthsWithLoss: [Month] { months.filter { $0.daysStoredOnly > 0 } }

        /// NOT A VERDICT, on purpose. ADR-0002 requires the shortfall to be
        /// accepted in writing rather than discovered at the receipt, so this
        /// states the finding and stops. Whether it is acceptable is a
        /// decision, and decisions are not computed here.
        var headline: String {
            guard reading.isTrustworthy else { return reading.line }
            let t = total
            if t.daysStoredOnly == 0 {
                return "Health covers every training day the app holds "
                     + "(\(t.storedDays) days). \(t.stravaAlone) of "
                     + "\(t.sessions) sessions were written by Strava alone."
            }
            let days = t.daysStoredOnly == 1 ? "1 training day is"
                                            : "\(t.daysStoredOnly) training days are"
            let months = monthsWithLoss.count == 1 ? "1 month"
                                                   : "\(monthsWithLoss.count) months"
            return "\(days) in the app and not in Health, across \(months). "
                 + "\(t.stravaAlone) of \(t.sessions) sessions were written by "
                 + "Strava alone."
        }
    }

    // MARK: Building

    /// The month keys from `first` up to and including the month of `now`.
    ///
    /// Takes `now` rather than reading the clock, so the tests are not a
    /// function of the day they run on.
    static func monthKeys(from first: String, now: Date,
                          calendar: Calendar = .current) -> [String] {
        guard first.count >= 7 else { return [] }
        let last = String(DayKey.key(now).prefix(7))
        var out: [String] = []
        var cursor = String(first.prefix(7))
        // Bounded rather than `while true`: a malformed `first` that never
        // reaches `last` would otherwise spin forever inside a diagnostic.
        var guardCount = 0
        while cursor <= last, guardCount < 600 {
            out.append(cursor)
            guard let d = calendar.date(from: DateComponents(
                year: Int(cursor.prefix(4)), month: Int(cursor.suffix(2)), day: 1)),
                  let next = calendar.date(byAdding: .month, value: 1, to: d)
            else { break }
            let c = calendar.dateComponents([.year, .month], from: next)
            cursor = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            guardCount += 1
        }
        return out
    }

    /// Pure. Both sides are already-fetched values; nothing here queries.
    static func build(health: [HealthWorkout],
                      activities: [Activity],
                      months keys: [String],
                      reading: Reading,
                      generated: String) -> Report {

        var byMonth: [String: Month] = [:]
        for k in keys { byMonth[k] = Month(month: k) }

        var healthDays: [String: Set<String>] = [:]
        var storedDays: [String: Set<String>] = [:]

        for w in health {
            let key = String(w.dayKey.prefix(7))
            guard var m = byMonth[key] else { continue }
            m.sessions += 1
            switch w.sport {
            case .run:      m.runs += 1
            case .bike:     m.rides += 1
            case .swim:     m.swims += 1
            case .strength: m.strength += 1
            default:        m.other += 1
            }
            if w.distanceM != nil { m.withDistance += 1 }
            if w.averageHeartRate != nil { m.withHeartRate += 1 }
            // CASE-INSENSITIVE CONTAINS, not equality. The source name is the
            // app's display name as the writer set it, and it has been seen as
            // "Strava" and "Strava " on the same store.
            let wroteByStrava = w.sources.filter {
                $0.localizedCaseInsensitiveContains("strava")
            }
            if !wroteByStrava.isEmpty { m.stravaWrote += 1 }
            if !w.sources.isEmpty, wroteByStrava.count == w.sources.count {
                m.stravaAlone += 1
            }
            byMonth[key] = m
            healthDays[key, default: []].insert(w.dayKey)
        }

        for a in activities {
            let key = String(a.dayKey.prefix(7))
            guard var m = byMonth[key] else { continue }
            m.storedSessions += 1
            // THE SAME SWITCH AS THE HEALTH SIDE, deliberately written out
            // rather than shared. `Activity.discipline` and `HealthWorkout
            // .sport` are both `Discipline?` today; they are computed from
            // different things — a Strava `sportType` string and an
            // `HKWorkoutActivityType` — and a shared helper would quietly
            // couple two mappings that are allowed to disagree.
            switch a.discipline {
            case .run:      m.storedRuns += 1
            case .bike:     m.storedRides += 1
            case .swim:     m.storedSwims += 1
            case .strength: m.storedStrength += 1
            default:        m.storedOther += 1
            }
            byMonth[key] = m
            storedDays[key, default: []].insert(a.dayKey)
        }

        for k in keys {
            guard var m = byMonth[k] else { continue }
            let h = healthDays[k] ?? []
            let s = storedDays[k] ?? []
            m.days = h.count
            m.storedDays = s.count
            // SORTED, so two runs over unchanged data produce the same report
            // and a diff between them means the data moved.
            m.datesHealthOnly = h.subtracting(s).sorted()
            m.datesStoredOnly = s.subtracting(h).sorted()
            byMonth[k] = m
        }

        return Report(reading: reading,
                      months: keys.compactMap { byMonth[$0] },
                      generated: generated)
    }

    // MARK: The paste

    /// Fixed-width, because this goes into a plan document and a table that
    /// only lines up in the app is a table that has to be retyped.
    static func text(_ r: Report) -> String {
        var out = ["Sub4 — Apple Health coverage",
                   r.generated,
                   "",
                   r.reading.line,
                   ""]
        guard r.reading.isTrustworthy else { return out.joined(separator: "\n") }

        out.append(r.headline)
        out.append("")
        out.append("month    | sess  days | run ride swim strg oth | dist   hr | "
                 + "strava strava-only | app  days | H-only app-only")
        for m in r.months { out.append(row(m)) }
        out.append(row(r.total))

        // THE COMPARISON THE FIRST VERSION COULD NOT MAKE — 283.
        let t = r.total
        out.append("")
        out.append("discipline | health |    app")
        for (name, h, a) in [("run", t.runs, t.storedRuns),
                             ("ride", t.rides, t.storedRides),
                             ("swim", t.swims, t.storedSwims),
                             ("strength", t.strength, t.storedStrength),
                             ("other", t.other, t.storedOther)] {
            out.append("\(name)\(String(repeating: " ", count: max(0, 10 - name.count)))"
                     + " | \(pad(h, 6)) | \(pad(a, 6))")
        }

        // EVERY DATE, UNCAPPED. A report that says "3 days" and lists two of
        // them reads as complete. If this ever runs to hundreds of lines that
        // is the finding, not a formatting problem.
        if !t.datesStoredOnly.isEmpty {
            out.append("")
            out.append("Training days in the app and NOT in Health — "
                     + "\(t.datesStoredOnly.count). Each one is a day a "
                     + "disconnect would destroy with nothing to put in its place:")
            for d in t.datesStoredOnly { out.append("  " + d) }
        }
        if !t.datesHealthOnly.isEmpty {
            out.append("")
            out.append("Days in Health and not in the app — "
                     + "\(t.datesHealthOnly.count). Not a shortfall; Health "
                     + "knowing more is not a loss:")
            for d in t.datesHealthOnly { out.append("  " + d) }
        }

        out.append("")
        out.append("Days, not sessions: a day on both sides is counted as covered "
                 + "even if the two sessions on it differ. Routes are not measured "
                 + "— see HealthCoverage.swift.")
        return out.joined(separator: "\n")
    }

    /// Right-aligned in `w` columns. Lifted out of `row` in 283 so the
    /// discipline table can use it too.
    private static func pad(_ n: Int, _ w: Int) -> String {
        String(repeating: " ", count: max(0, w - "\(n)".count)) + "\(n)"
    }

    private static func row(_ m: Month) -> String {
        func p(_ n: Int, _ w: Int) -> String { pad(n, w) }
        let name = m.month + String(repeating: " ", count: max(0, 8 - m.month.count))
        return "\(name) | \(p(m.sessions, 4)) \(p(m.days, 5)) | \(p(m.runs, 3)) "
             + "\(p(m.rides, 4)) \(p(m.swims, 4)) \(p(m.strength, 4)) \(p(m.other, 3)) | "
             + "\(p(m.withDistance, 4)) \(p(m.withHeartRate, 4)) | \(p(m.stravaWrote, 6)) "
             + "\(p(m.stravaAlone, 11)) | \(p(m.storedSessions, 4)) \(p(m.storedDays, 5)) | "
             + "\(p(m.daysHealthOnly, 6)) \(p(m.daysStoredOnly, 8))"
    }
}
