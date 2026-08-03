//
//  ZoneTime.swift
//  Sub4
//
//  Time in zone, actually measured.
//
//  WHAT THIS REPLACES, AND WHY IT HAD TO
//  -------------------------------------
//  Until patch 91 the Time in zone card counted SESSIONS and bucketed each one
//  by its average heart rate. Under a heading reading "TIME IN ZONE" the bars
//  were read as time, and they were not: a session of 40 minutes easy and 20
//  minutes hard averages into Z3 and landed there entirely, having spent no
//  time in Z3 at all. The caveat existed only in a code comment.
//
//  Everything needed to do it properly was already on disk. `LoadEngine` walks
//  each cached trace once per rebuild to integrate TRIMP; patch 91 has that
//  same walk also record seconds per bpm (`WorkoutLoad.hrSeconds`). This file
//  is the summing and the bucketing on top of it.
//
//  THREE DECISIONS, MADE DELIBERATELY
//  ----------------------------------
//  1. WINDOW is chosen by the reader — 30 days, 90 days, or the whole history.
//     Time in zone over eighteen months describes a training block you have
//     already left; over 30 days a single big week dominates. Neither is right
//     for every question, so the card asks rather than guesses.
//
//  2. SESSIONS WITHOUT A TRACE ARE EXCLUDED, and counted out loud. A session
//     scored from its average has a number but no shape. Spreading its whole
//     duration into the average's zone is what the old card effectively did,
//     and it is a guess wearing the shape of a measurement. The count goes on
//     the card so the exclusion is visible rather than quiet.
//
//  3. PLAN DISCIPLINES ONLY. `isLoadEligible` — what the fitness curve uses —
//     also admits anything over 10 km, so a long walk earns load. This card
//     answers "how did my training intensity distribute", and a walk to work is
//     not training. Note the consequence: this card and the fitness curve
//     deliberately count different sets, and the info sheet says so.
//
//  WHY THE TOTAL IS BELOW YOUR MOVING TIME
//  ---------------------------------------
//  Bins under 0.3 m/s are dropped by the integral — stopped time is not time in
//  a zone. A session with long stops contributes less here than its moving time
//  suggests, and that is the correct answer, not a shortfall.
//

import Foundation

// MARK: - Window

enum ZoneWindow: String, CaseIterable, Identifiable {
    case days30, days90, all

    var id: String { rawValue }

    /// nil = the whole series.
    var days: Int? {
        switch self {
        case .days30: 30
        case .days90: 90
        case .all:    nil
        }
    }

    var short: String {
        switch self {
        case .days30: "30 d"
        case .days90: "90 d"
        case .all:    "All"
        }
    }

    var label: String {
        switch self {
        case .days30: "last 30 days"
        case .days90: "last 90 days"
        case .all:    "all recorded"
        }
    }
}

enum ZoneWindowKey {
    static let selected = "zones.window"
}

// MARK: - The totals

struct ZoneTotals {

    /// Zone index → seconds. Only zones the athlete actually has.
    let seconds: [Int: Double]
    /// Sessions that carried a usable trace and are therefore IN the figures.
    let traced: Int
    /// Sessions that could not contribute a distribution.
    let untraced: Int
    /// Their duration, so the card can say how much is missing rather than only
    /// how many sessions are.
    let untracedSeconds: Double
    /// …and WHICH, because the cause differs by discipline and only one of them
    /// is a fault.
    ///
    /// Strength covers no distance, so it can never carry a distribution — its
    /// absence here is structural and permanent. A pool swim usually fails the
    /// moving-time drift check for the same reason its pace is untrustworthy.
    /// An untraced RUN, on the other hand, means a trace that should have been
    /// there was missing or failed the coverage floor, and that is worth
    /// chasing. A bare count cannot tell those apart; this can.
    let untracedByDiscipline: [Discipline: Int]

    var totalSeconds: Double { seconds.values.reduce(0, +) }
    var isEmpty: Bool { totalSeconds <= 0 }

    var hours: Double { totalSeconds / 3600 }
    var untracedHours: Double { untracedSeconds / 3600 }

    func hours(_ zoneIndex: Int) -> Double { (seconds[zoneIndex] ?? 0) / 3600 }

    // MARK: Building

    /// Sums every traced session's bpm histogram in the window and buckets it by
    /// the athlete's current zones.
    ///
    /// Bucketing happens HERE rather than in the load engine, which is what lets
    /// a zone edit in Settings redraw the card without recomputing the series —
    /// see the note on `WorkoutLoad.hrSeconds`.
    static func build(days: [DailyLoad],
                      zones: [AthleteStore.HRZone],
                      window: ZoneWindow,
                      today: String = DayKey.key()) -> ZoneTotals {

        guard !zones.isEmpty else {
            return ZoneTotals(seconds: [:], traced: 0, untraced: 0,
                              untracedSeconds: 0, untracedByDiscipline: [:])
        }

        let cutoff: String? = window.days.flatMap { n in
            guard let d = DayKey.date(today),
                  let start = Calendar(identifier: .iso8601)
                      .date(byAdding: .day, value: -(n - 1), to: d) else { return nil }
            return DayKey.key(start)
        }

        // Resolved once for the whole sum. `zone(forHR:)` walks the list per
        // call, and this is called once per bpm bucket per session — a few
        // hundred thousand times over a year of history if left unmemoised.
        var lookup: [Int: Int] = [:]
        func zoneIndex(_ bpm: Int) -> Int? {
            if let hit = lookup[bpm] { return hit }
            let found = zones.first { $0.contains(bpm) }?.index ?? zones.last?.index
            if let found { lookup[bpm] = found }
            return found
        }

        var seconds: [Int: Double] = [:]
        var traced = 0
        var untraced = 0
        var untracedSeconds = 0.0
        var untracedByDiscipline: [Discipline: Int] = [:]

        for day in days {
            if let cutoff, day.dayKey < cutoff { continue }
            for w in day.workouts where w.isPlanEligible {
                guard w.hasZoneDistribution else {
                    untraced += 1
                    untracedSeconds += Double(w.scoredSeconds)
                    untracedByDiscipline[w.discipline, default: 0] += 1
                    continue
                }
                traced += 1
                for (bpm, s) in w.hrSeconds {
                    guard let z = zoneIndex(bpm) else { continue }
                    seconds[z, default: 0] += s
                }
            }
        }

        return ZoneTotals(seconds: seconds, traced: traced,
                          untraced: untraced, untracedSeconds: untracedSeconds,
                          untracedByDiscipline: untracedByDiscipline)
    }

    // MARK: Labels

    /// "Z2 Endurance  61%" per zone index.
    ///
    /// PERCENTAGES THAT SUM TO 100, by largest remainder rather than by rounding
    /// each independently. Five independently rounded shares land on 99 or 101
    /// often enough that the first thing anyone does is add them up and ask.
    /// Carried over unchanged from the session-count card it replaces.
    func shareLabels(_ zones: [AthleteStore.HRZone]) -> [Int: String] {
        var raw: [Double] = []
        for z in zones { raw.append(seconds[z.index] ?? 0) }
        let percents: [Int] = Self.largestRemainder(raw)
        var out: [Int: String] = [:]
        for (i, z) in zones.enumerated() {
            out[z.index] = z.titled + "  \(percents[i])%"
        }
        return out
    }

    static func largestRemainder(_ values: [Double]) -> [Int] {
        let total: Double = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in 0 } }
        var exact: [Double] = []
        for v in values { exact.append(v / total * 100) }
        var out: [Int] = exact.map { Int($0) }
        var left: Int = 100 - out.reduce(0, +)
        var order: [Int] = Array(exact.indices)
        order.sort { (exact[$0] - Double(Int(exact[$0])))
                   > (exact[$1] - Double(Int(exact[$1]))) }
        var i = 0
        while left > 0, i < order.count {
            out[order[i]] += 1
            left -= 1
            i += 1
        }
        return out
    }

    /// The x domain, with a touch of slack so the longest bar does not run into
    /// the card edge.
    var axisCeiling: Double {
        var peak = 0.0
        for v in seconds.values where v > peak { peak = v }
        let h = peak / 3600
        return h <= 0 ? 1 : h * 1.05
    }

    /// "120.2 h counted · 97 sessions" — what is IN the bars.
    var footnote: String {
        var s: String = String(format: "%.1f h counted", hours)
        s += " · \(traced) session" + (traced == 1 ? "" : "s")
        return s
    }

    /// "26 not traced (67.0 h) — 19 strength, 5 swim, 2 rides" — what is OUT,
    /// and why.
    ///
    /// A bare count is a number without a cause. Named by discipline it does
    /// real work: strength and swim are structurally absent and always will be,
    /// so seeing a RUN in this list is the signal that something is actually
    /// wrong with a recording.
    ///
    /// Assembled as a String outside any view builder, per the rule in
    /// VolumeCard.
    var untracedLine: String? {
        guard untraced > 0 else { return nil }
        let h: String = String(format: "%.1f", untracedHours)
        var s: String = "\(untraced) not traced (" + h + " h)"
        let named: String = Self.disciplineList(untracedByDiscipline)
        if !named.isEmpty { s += " — " + named }
        return s
    }

    /// Biggest first, so the structural bulk leads and an odd one out is the
    /// tail — which is where the eye lands on a short list.
    static func disciplineList(_ counts: [Discipline: Int]) -> String {
        let order: [Discipline] = [.strength, .swim, .bike, .run, .other, .rest]
        var pairs: [(Discipline, Int)] = []
        for d in order {
            if let n = counts[d], n > 0 { pairs.append((d, n)) }
        }
        pairs.sort { $0.1 > $1.1 }
        var parts: [String] = []
        for (d, n) in pairs {
            parts.append("\(n) " + Self.plural(d, n))
        }
        return parts.joined(separator: ", ")
    }

    /// "5 swims", "2 rides", "19 strength" — strength has no plural that reads
    /// as a count of sessions, so it stays as it is.
    private static func plural(_ d: Discipline, _ n: Int) -> String {
        let one: Bool = n == 1
        switch d {
        case .run:      return one ? "run" : "runs"
        case .bike:     return one ? "ride" : "rides"
        case .swim:     return one ? "swim" : "swims"
        case .strength: return "strength"
        default:        return one ? "other" : "other"
        }
    }
}

// MARK: - One session

extension ZoneTotals {

    /// The distribution for a SINGLE workout — patch 159.
    ///
    /// WHY THIS SHARES THE WINDOWED BUILDER'S GUTS RATHER THAN COPYING THEM
    /// -------------------------------------------------------------------
    /// The activity page and the Progress card must agree. If they bucket by
    /// different code, an edge case — a bpm exactly on a boundary, a reading
    /// above the top zone's floor — resolves one way on one screen and the other
    /// way on the other, and the two disagree by a minute with no way to tell
    /// which is right. The lookup below is the same rule stated once.
    ///
    /// `traced` is 1 or 0 rather than a count, so the caller can use the same
    /// "is there anything here" test as the windowed form.
    static func build(_ w: WorkoutLoad,
                      zones: [AthleteStore.HRZone]) -> ZoneTotals {
        guard !zones.isEmpty, w.hasZoneDistribution else {
            return ZoneTotals(seconds: [:], traced: 0, untraced: 1,
                              untracedSeconds: Double(w.scoredSeconds),
                              untracedByDiscipline: [w.discipline: 1])
        }
        var lookup: [Int: Int] = [:]
        var seconds: [Int: Double] = [:]
        for (bpm, s) in w.hrSeconds {
            let z: Int?
            if let hit = lookup[bpm] { z = hit } else {
                z = zones.first { $0.contains(bpm) }?.index ?? zones.last?.index
                if let z { lookup[bpm] = z }
            }
            guard let z else { continue }
            seconds[z, default: 0] += s
        }
        return ZoneTotals(seconds: seconds, traced: 1, untraced: 0,
                          untracedSeconds: 0, untracedByDiscipline: [:])
    }
}
