//
//  ChartScale.swift
//  Sub4
//
//  Where the top of a chart goes.
//
//  Swift Charts picks its own domain, and its "nice number" ladder is
//  1 / 2 / 5 × 10ⁿ. A fitness curve peaking at 110 therefore gets an axis to
//  200, because the rung above 100 is 200 and there is nothing in between. The
//  data then occupies just over half the height and the top of the card is
//  empty — which was the first thing anyone noticed about the fitness chart.
//
//  This is a finer ladder. Same idea, more rungs: 0.2, 0.25, 0.5 and 1 of the
//  leading magnitude, so 110 rounds to 120 rather than to 200 and the same
//  chart uses 92% of its height instead of 55%.
//
//  It rounds UP and never adds headroom on top of that. The ceiling is always
//  at or above the peak, so nothing is ever clipped; when a peak lands exactly
//  on a rung the line touches the top gridline, which is tidy rather than a
//  problem.
//

import Foundation

enum ChartScale {

    /// The next round number at or above `value`.
    ///
    ///     110  → 120        53 → 60        38 → 40
    ///     7.2  → 8         1.05 → 1.2     100 → 100
    static func ceiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }

        let magnitude = pow(10, (log10(value)).rounded(.down))
        let n = value / magnitude          // 1.0 ..< 10.0

        // Step within the magnitude. Fine near the bottom of the decade, where
        // the 1/2/5 ladder does its worst damage, coarser higher up where the
        // relative waste is smaller anyway.
        let step: Double
        switch n {
        case ..<1.2: step = 0.2
        case ..<2:   step = 0.25
        case ..<5:   step = 0.5
        default:     step = 1
        }

        return (n / step).rounded(.up) * step * magnitude
    }

    /// A closed domain from zero to the next round number above the data.
    ///
    /// Zero-based on purpose: these are magnitudes — kilometres, load, watts —
    /// and a chart of magnitudes that does not start at zero exaggerates every
    /// difference on it.
    /// `minimum` is the smallest ceiling worth drawing. Without one, a window
    /// where everything is zero gets a 0…1 axis and three labels reading
    /// 0, 0, 1 — three ticks describing nothing.
    static func domain(_ values: [Double], minimum: Double = 1) -> ClosedRange<Double> {
        let peak = values.filter { $0.isFinite }.max() ?? 0
        return 0...Swift.max(ceiling(peak), minimum)
    }
}
