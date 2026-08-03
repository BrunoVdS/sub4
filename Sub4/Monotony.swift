//
//  Monotony.swift
//  Sub4
//
//  Foster's monotony and strain — how EVENLY the week's load was spread, and
//  what that evenness costs.
//
//  WHAT THE PMC CANNOT SEE
//  -----------------------
//  CTL, ATL and TSB are averages, and averages are blind to shape. A week of
//  350 TRIMP done as 50 every day and the same 350 done as one 200 day, two 75s
//  and four rest days produce identical fitness, identical fatigue, identical
//  freshness. They are not identical weeks. The second has a hard session and
//  real recovery; the first has neither, and Foster's finding was that the
//  first is the one that precedes illness and injury.
//
//      monotony = mean(daily load) / SD(daily load)     over 7 days
//      strain   = weekly total load × monotony
//
//  Monotony rises when every day looks like every other day. It is DELIBERATELY
//  sensitive to rest days: a zero is what creates the spread, so a week with no
//  zeros scores high even at a modest total. That is the mechanism, not a
//  defect — "you never take a day off" is exactly what it is built to say.
//
//  THE THRESHOLD, AND THE ONE WE REFUSE TO INVENT
//  ---------------------------------------------
//  Foster associated monotony at or above 2.0 with a rise in illness. That
//  figure travels with the literature and is used here as a flag.
//
//  Strain has no such number. It scales with the athlete's own volume, so a
//  strain of 900 means something different for a 20-hour week than a 4-hour
//  one, and every published "high strain" threshold is a population figure
//  applied to an individual. So strain is reported and compared against THIS
//  athlete's own trailing history, never against a constant. The review can say
//  "the highest in eight weeks"; it will not say "too high".
//
//  POPULATION SD, NOT SAMPLE SD
//  ----------------------------
//  Divided by 7, not by 6. These seven days are not a sample drawn from some
//  larger week — they are the whole week, and the whole week is the thing being
//  described. The choice matters: n−1 inflates the SD by about 8% at n=7 and
//  deflates every monotony figure by the same amount, which would put readings
//  either side of Foster's 2.0 on the wrong side of it.
//
//  IMPUTED DAYS POISON THIS MORE THAN THEY POISON THE PMC
//  -----------------------------------------------------
//  A gap day is filled from the trailing week's mean. That is a reasonable
//  stand-in for an average, which is what CTL is — but it is the WORST possible
//  stand-in for a spread, because a value at the mean reduces the SD and
//  therefore raises monotony. An imputed day makes a week look more monotonous
//  than it was. Every window carries its imputed count, and a window with any
//  imputed day is not trustworthy on this metric even though the same day is
//  perfectly acceptable for the PMC.
//

import Foundation

struct MonotonyPoint: Identifiable {
    let dayKey: String
    /// nil when the week has no spread to measure — no training at all, or
    /// seven identical days, where the ratio is undefined rather than infinite.
    let monotony: Double?
    let strain: Double?
    /// Sum of the seven days.
    let weeklyLoad: Double
    /// How many of the seven were imputed. Any at all and the figure reads high.
    let imputedInWindow: Int
    /// How many were rest days. The thing monotony is really counting.
    let restInWindow: Int

    var id: String { dayKey }
    var isTrustworthy: Bool { imputedInWindow == 0 }
}

enum Monotony {

    static let window = 7

    /// Foster's flag. At or above this, the week was too even.
    static let highMonotony = 2.0

    /// Below this the week is varied enough that the figure is not worth
    /// mentioning — used to keep the review quiet rather than chatty.
    static let lowMonotony = 1.5

    /// One point per day, each describing the seven days ENDING on that day.
    ///
    /// Trailing rather than centred: the question is always "what have the last
    /// seven days been", asked today. A centred window would need tomorrow.
    static func series(_ points: [PMCPoint]) -> [MonotonyPoint] {
        guard points.count >= window else { return [] }
        return (window - 1 ..< points.count).map { end in
            let slice = points[(end - window + 1)...end]
            let loads = slice.map(\.load)
            let total = loads.reduce(0, +)
            let mean = total / Double(window)

            // Population SD — see the note at the top of the file.
            let variance = loads.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                         / Double(window)
            let sd = variance.squareRoot()

            let m: Double? = sd > 0.001 ? mean / sd : nil
            return MonotonyPoint(
                dayKey: points[end].dayKey,
                monotony: m,
                strain: m.map { total * $0 },
                weeklyLoad: total,
                imputedInWindow: slice.filter(\.imputed).count,
                restInWindow: slice.filter { $0.load <= 0 }.count)
        }
    }

    /// Descriptive, never prescriptive — the same rule the freshness label
    /// follows. It says what the number is; it does not say what to do.
    static func label(_ m: Double) -> String {
        switch m {
        case ..<lowMonotony:  return "Varied"
        case ..<highMonotony: return "Even"
        default:              return "Very even"
        }
    }

    /// Strain against the athlete's own trailing history, because there is no
    /// population figure worth quoting. nil until there is enough history to
    /// compare against.
    ///
    /// The rank of the latest strain among the trailing window — 1 meaning the
    /// highest.
    ///
    /// `of` is the number of days that HAD a strain figure, which is not the
    /// same as the number of days looked at: a week with no spread produces no
    /// monotony and therefore no strain, and those days drop out. Reporting
    /// `of` as "days" conflated the two and made "24th of 43" read as though 43
    /// days had been examined when 56 were.
    static func strainRank(_ series: [MonotonyPoint], of value: Double,
                           weeks: Int = 8) -> (rank: Int, of: Int, span: Int)? {
        let days = weeks * 7
        let window = series.suffix(days)
        let recent = window.compactMap(\.strain)
        guard recent.count >= 14 else { return nil }
        let higher = recent.filter { $0 > value }.count
        return (higher + 1, recent.count, window.count)
    }

    /// The most recent window with no imputed day in it.
    ///
    /// The card draws only trustworthy windows, so its headline has to come
    /// from the same place. The first version printed `series.last` beside a
    /// chart that had deliberately declined to plot it — stating the one figure
    /// the drawing was refusing, one line below the refusal.
    static func latestTrustworthy(_ series: [MonotonyPoint]) -> MonotonyPoint? {
        series.last { $0.isTrustworthy && $0.monotony != nil }
    }

    // MARK: Self-test

    /// Worked examples, checked in the app rather than in a test target this
    /// project does not have.
    static func selfTest() -> [LoadEngine.Check] {
        func point(_ load: Double, _ i: Int) -> PMCPoint {
            PMCPoint(dayKey: String(format: "2026-01-%02d", i + 1), load: load,
                     ctl: 0, atl: 0, tsb: nil, state: .measured,
                     imputed: false, isWarmup: false)
        }
        func build(_ loads: [Double]) -> MonotonyPoint? {
            series(loads.enumerated().map { point($1, $0) }).last
        }
        func check(_ name: String, _ expected: Double, _ got: Double?) -> LoadEngine.Check {
            let g = got ?? -1
            return LoadEngine.Check(name: name,
                                    expected: String(format: "%.2f", expected),
                                    got: got == nil ? "nil" : String(format: "%.2f", g),
                                    pass: abs(expected - g) <= 0.01)
        }

        var out: [LoadEngine.Check] = []

        // Six equal days and one rest day. mean 51.43, population SD 20.99,
        // so monotony 2.45 — above Foster's flag on a week that never once
        // went hard. This is the case the metric exists for.
        out.append(check("Monotony · 6×60 + rest", 2.45,
                         build([60, 60, 60, 60, 60, 60, 0])?.monotony))

        // The same weekly total spread unevenly scores far lower.
        // 4×100 and 3×0: mean 57.14, SD 49.49, monotony 1.15.
        out.append(check("Monotony · 4×100 + 3 rest", 1.15,
                         build([100, 0, 100, 0, 100, 0, 100])?.monotony))

        // Strain is the weekly total times monotony: 360 × 2.45 = 882.
        out.append(check("Strain · 6×60 + rest", 882.0,
                         build([60, 60, 60, 60, 60, 60, 0])?.strain))

        // Seven identical days have no spread at all. Undefined, not infinite.
        let flat = build([50, 50, 50, 50, 50, 50, 50])
        out.append(LoadEngine.Check(name: "Monotony · seven identical days",
                                    expected: "nil", got: flat?.monotony == nil ? "nil" : "value",
                                    pass: flat?.monotony == nil))

        // A week of nothing is not a monotonous week.
        let empty = build([0, 0, 0, 0, 0, 0, 0])
        out.append(LoadEngine.Check(name: "Monotony · empty week",
                                    expected: "nil", got: empty?.monotony == nil ? "nil" : "value",
                                    pass: empty?.monotony == nil))

        return out
    }
}
