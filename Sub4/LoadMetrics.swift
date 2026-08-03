//
//  LoadMetrics.swift
//  Sub4
//
//  The Load / Fitness / Fatigue / Freshness strip, and the change under it.
//
//  WHY THIS IS A FILE AND NOT A COPY
//  ---------------------------------
//  Today has carried this strip since patch 60. Week asked for "the same thing
//  for the week" in patch 139, and the obvious way to deliver that is to copy
//  thirty lines of layout into WeekView — after which there are two strips that
//  look identical today and will not in six months, because the next change to
//  a font size or a colour rule will land in one of them.
//
//  The two strips genuinely differ, but only in what they MEASURE. Today shows
//  one day's load and the curve at that day; Week shows the week's total and how
//  far the curve moved across it. The cell, the divider, the baseline, the
//  colour convention and the "level" threshold are the same thing said twice, so
//  they live here once.
//
//  WHAT THE COLOUR ASSERTS, AND WHERE IT IS WRONG
//  ----------------------------------------------
//  Green for the direction usually wanted, amber for the other: fitness up,
//  fatigue DOWN, freshness up. Right through a build block and wrong through a
//  taper, where losing fitness and gaining freshness is precisely the plan
//  working. Neither strip knows which week of 34 it is looking at, so neither
//  can know. The colour is a convention; the sign is the fact.
//

import SwiftUI

/// A signed change, already formatted and coloured.
struct MetricDelta {

    let text: String
    let colour: Color

    /// Below this the two figures are the same number to the precision shown,
    /// and an arrow would be claiming a movement the display cannot render.
    static let levelThreshold = 0.05

    /// One decimal, where the figures above show none.
    ///
    /// A CTL of 30.4 is a CTL of 30, but a day's change is a tenth to a point
    /// and a half — rounded the same way it would print +0 on a day that built
    /// and +0 on a day that did not. A week's change is larger and keeps the
    /// decimal anyway, so the two strips read alike.
    init?(_ change: Double?, upIsGood: Bool) {
        guard let change else { return nil }
        guard abs(change) >= Self.levelThreshold else {
            text = "level"
            colour = Color.dim
            return
        }
        let good = upIsGood ? change > 0 : change < 0
        text = String(format: "%+.1f", change)
        colour = good ? Color.ctlTint : Color.slowerColor
    }
}

/// One column of the strip: name, figure, unit, and the change beneath.
///
/// `swatch` links the figure to its line on the fitness chart. See SeriesSwatch
/// for why the mark carries the identity rather than the numeral. A figure with
/// no line on that chart — Load — passes nil and keeps using `colour` to say
/// whether the day was measured.
struct MetricCell: View {

    let label: String
    let value: String
    let unit: String
    let colour: Color
    var swatch: SeriesSwatch? = nil
    var delta: MetricDelta? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if let swatch { swatch }
                Text(label).font(.caption2).foregroundStyle(Color.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.bold))
                    .foregroundStyle(swatch == nil ? colour : Color.ink)
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(Color.dim)
                }
            }
            // Reserved whether or not there is a delta, so the columns keep one
            // baseline. Without the placeholder, a column with no change sits
            // two points higher than its neighbours on every render.
            Text(delta?.text ?? " ")
                .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                .foregroundStyle(delta?.colour ?? Color.clear)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MetricDivider: View {
    /// 26 matches the metric strips; the activity hero row passes 30 because
    /// its figures are a size up. One divider with a height beats the second
    /// divider the detail page kept for exactly that reason — patch 173.
    var height: CGFloat = 26

    var body: some View {
        Rectangle().fill(Color.line).frame(width: 1, height: height)
    }
}

// MARK: - A week's worth of the curve

/// What the fitness curve did across one week, and what went into it.
///
/// WHY THE VALUES ARE END-OF-WEEK AND THE CHANGES ARE ACROSS IT
/// ------------------------------------------------------------
/// A week has no single CTL. The figure worth printing is where the curve ended
/// up — which for the week in progress is where it stands now — and the figure
/// worth printing under it is how far it travelled to get there. That second
/// number is the RAMP, which the fitness ⓘ already calls the figure a build is
/// actually steered by, and it has never been on screen anywhere.
///
/// The change is measured against the day BEFORE the week opened, not against
/// the week's first day. A week's movement includes what its own Monday did.
struct WeekLoadSummary {

    /// Sum of the daily loads the curve consumed, imputed days included.
    let totalLoad: Double
    /// Days inside the week whose load was filled in rather than measured.
    let imputedDays: Int
    /// True while the week still has days to come.
    let isPartial: Bool

    let ctl: Double?
    let atl: Double?
    let tsb: Double?

    let ctlChange: Double?
    let atlChange: Double?
    let tsbChange: Double?

    /// nil when the week holds no points at all — a future week, or one before
    /// the ingest window. The strip is absent rather than empty — a dash is a
    /// claim that a number should be there, and here none should.
    static func build(_ summary: PMCSummary, dayKeys: [String],
                      today: String = DayKey.key()) -> WeekLoadSummary? {
        guard let first = dayKeys.first, let last = dayKeys.last else { return nil }
        let inside = summary.points.filter { $0.dayKey >= first && $0.dayKey <= last }
        guard let end = inside.last else { return nil }

        // The last point BEFORE the week. Looked up by key rather than by index
        // so it cannot quietly stop meaning "the day before" if the series ever
        // stops being contiguous.
        let before = summary.points.last { $0.dayKey < first }

        return WeekLoadSummary(
            totalLoad: inside.reduce(0.0) { $0 + $1.load },
            imputedDays: inside.filter(\.imputed).count,
            isPartial: last > today,
            ctl: end.ctl,
            atl: end.atl,
            tsb: end.tsb,
            ctlChange: before.map { end.ctl - $0.ctl },
            atlChange: before.map { end.atl - $0.atl },
            // Freshness is the only one of the three that can be nil on its own
            // — it is undefined on the first day of the series, where there is
            // no yesterday to take the gap from.
            tsbChange: {
                guard let t = end.tsb, let b = before?.tsb else { return nil }
                return t - b
            }())
    }
}
