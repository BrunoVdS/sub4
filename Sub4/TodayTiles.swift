//
//  TodayTiles.swift
//  Sub4
//
//  Two squares under the load strip: what the curve has been doing for a
//  fortnight, and what the weekly load has been doing beside it.
//
//  WHY A FORTNIGHT, AND WHY PICTURES
//  ---------------------------------
//  The strip above these prints four numbers and three day-on-day changes. That
//  answers "where am I" exactly and answers "where am I going" not at all: a
//  change of −0.7 could be the seventh in a row or the first after six of +0.9,
//  and those are opposite situations wearing the same figure.
//
//  Fourteen days is the shortest window in which that direction is legible and
//  the longest that fits in a square. Anything wider belongs on Progress, where
//  it already is.
//
//  THE STRIP SAYS WHAT; THESE SAY WHAT SHAPE
//  -----------------------------------------
//  Deliberately no figures on either tile. The card directly above already
//  prints 31 CTL and 19 ATL, and this app has removed the same number stated
//  twice on one screen four separate times — the Strava status, the done/total
//  bar, the peak-zone sentence, the weather header. Adding a fifth to save a
//  glance upward would be the same mistake with a nicer chart on it.
//
//  THE TRUNCATED AXIS, WHICH IS THE ONLY REAL RISK HERE
//  ----------------------------------------------------
//  Fitness runs on a 42-day time constant, so across a fortnight it moves a
//  point or two. Scaled to its own range that becomes a mountain, and a
//  truncated axis is the oldest way to lie with a chart.
//
//  So the two curves SHARE one scale, spanning whichever of them reaches
//  furthest. Fitness then reads as nearly flat, because it is; fatigue does the
//  moving, because it does; and the gap between them is freshness, which is the
//  one thing on that tile meant to be read as a quantity.
//
//  The load tile is zero-based for the opposite reason: it is a magnitude rather
//  than a position, and "did my week halve" is a question its baseline has to be
//  able to answer.
//

import SwiftUI
import Charts

struct TodayTiles: View {

    let summary: PMCSummary
    /// The day being viewed, which since patch 158 is not always today.
    let dayKey: String

    /// Days on screen.
    private static let window = 14
    /// Days of run-up the rolling total needs before the first visible point.
    ///
    /// Without them the first six points of the line are sums of fewer than
    /// seven days and the tile opens with a ramp that never happened. The tile
    /// is absent rather than wrong when the series cannot supply them.
    private static let runUp = 6

    private var points: [PMCPoint] {
        summary.points.filter { $0.dayKey <= dayKey }
    }

    private var visible: [PMCPoint] { Array(points.suffix(Self.window)) }

    var body: some View {
        if !visible.isEmpty {
            HStack(spacing: 10) {
                if summary.isTrustworthy, visible.count >= 4 { fitnessTile }
                if rolling.count >= 4 { loadTile }
            }
        }
    }

    // MARK: Fitness

    /// Gated on the same test as the strip's figures. A curve the app has just
    /// said it does not believe is not more believable drawn small.
    private var fitnessTile: some View {
        ExpandableCard(panels: PanelGroup.loadFromStrip, opensOn: "fitness") {
            tile("FITNESS", chart: {
                Chart {
                    // Freshness first, so both curves are drawn over it. Same
                    // band and same colour as the Progress chart; at this size
                    // it is the only thing carrying a quantity.
                    ForEach(visible) { p in
                        AreaMark(x: .value("Day", date(p)),
                                 yStart: .value("Fitness", p.ctl),
                                 yEnd: .value("Fatigue", p.atl))
                            .foregroundStyle(Color.tsbFill)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(visible) { p in
                        LineMark(x: .value("Day", date(p)),
                                 y: .value("Fatigue", p.atl),
                                 series: .value("s", "atl"))
                            .foregroundStyle(Color.atlTint)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(visible) { p in
                        LineMark(x: .value("Day", date(p)),
                                 y: .value("Fitness", p.ctl),
                                 series: .value("s", "ctl"))
                            .foregroundStyle(Color.ctlTint)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    // Where you are. A fortnight of line with no mark on it
                    // leaves the reader working out which end is now.
                    if let last = visible.last {
                        PointMark(x: .value("Day", date(last)),
                                  y: .value("Fitness", last.ctl))
                            .foregroundStyle(Color.ctlTint)
                            .symbolSize(38)
                    }
                }
                .chartYScale(domain: fitnessDomain)
            }, key: {
                HStack(spacing: 9) {
                    LegendItem(.swatch(.line(Color.ctlTint)), "Fitness", font: .system(size: 9))
                    LegendItem(.swatch(.line(Color.atlTint)), "Fatigue", font: .system(size: 9))
                    LegendItem(.swatch(.area), "Fresh", font: .system(size: 9))
                }
            })
        }
    }

    /// ONE domain for both series — see the file header. Padded by a tenth of
    /// the span so neither line is drawn on the frame.
    private var fitnessDomain: ClosedRange<Double> {
        let vs = visible.flatMap { [$0.ctl, $0.atl] }
        let lo = vs.min() ?? 0, hi = vs.max() ?? 1
        let pad = max((hi - lo) * 0.12, 1)
        return (lo - pad)...(hi + pad)
    }

    // MARK: Load

    /// The rolling seven-day total, which is the series Progress calls Weekly
    /// load — the same figure the strip prints for the week, drawn every day
    /// instead of once.
    private struct RollPoint: Identifiable {
        let id: String
        let date: Date
        let total: Double
    }

    private var rolling: [RollPoint] {
        let all = points
        guard all.count >= Self.window + Self.runUp else { return [] }
        let start = all.count - Self.window
        return (start..<all.count).compactMap { i in
            guard let d = DayKey.date(all[i].dayKey) else { return nil }
            let sum = all[(i - Self.runUp)...i].reduce(0.0) { $0 + $1.load }
            return RollPoint(id: all[i].dayKey, date: d, total: sum)
        }
    }

    private var loadTile: some View {
        ExpandableCard(panels: PanelGroup.load, opensOn: "pattern") {
            tile("LOAD", chart: {
                Chart {
                    ForEach(rolling) { r in
                        AreaMark(x: .value("Day", r.date),
                                 y: .value("Weekly load", r.total))
                            .foregroundStyle(Color.ink.opacity(0.10))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(rolling) { r in
                        LineMark(x: .value("Day", r.date),
                                 y: .value("Weekly load", r.total))
                            .foregroundStyle(Self.neutral)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    if let last = rolling.last {
                        PointMark(x: .value("Day", last.date),
                                  y: .value("Weekly load", last.total))
                            .foregroundStyle(Self.neutral)
                            .symbolSize(38)
                    }
                }
                // ZERO-BASED, unlike the tile beside it. This is a magnitude,
                // and a weekly total that halves has to look halved.
                .chartYScale(domain: 0...((rolling.map(\.total).max() ?? 1) * 1.12))
            }, key: {
                HStack(spacing: 9) {
                    LegendItem(.swatch(.line(Self.neutral)), "7-day total", font: .system(size: 9))
                }
            })
        }
    }

    /// NEUTRAL, AND NOT THE ACCENT.
    ///
    /// One series carries no identity — the title names it — so the colour is
    /// free, and free is worth spending here. An amber or orange line would sit
    /// a few ΔE from the Fatigue curve in the tile immediately beside it, which
    /// is the warm-band collision patch 142 spent an afternoon unpicking.
    ///
    /// It also does real work: the tiles read as MEASURED beside MODELLED, which
    /// is exactly what they are.
    private static let neutral = Color.ink.opacity(0.72)

    // MARK: Chrome

    /// Title, plot, key. Square-ish rather than square: a true square with a
    /// header and a key on it leaves the plot squat, and the plot is the point.
    private func tile<C: View, K: View>(_ title: String,
                                        @ViewBuilder chart: () -> C,
                                        @ViewBuilder key: () -> K) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10, weight: .bold)).tracking(0.5)
                Spacer(minLength: 4)
                Text("14 days").font(.system(size: 9.5))
            }
            .foregroundStyle(Color.dim)

            chart()
                // NO AXES, AND THAT IS THE HONEST CHOICE AT THIS SIZE. There is
                // room for two y labels, and two labels on a truncated axis are
                // worse than none — they invite reading a value off a scale that
                // does not start where the eye assumes. The strip has the
                // figures; this has the shape.
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 92)

            key()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func date(_ p: PMCPoint) -> Date {
        DayKey.date(p.dayKey) ?? Date()
    }
}
