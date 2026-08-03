//
//  ChartChrome.swift
//  Sub4
//
//  The two pieces of chart furniture every card was building for itself.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The peer review found the same capsule track-bar hand-rolled four times and
//  the same swatch-plus-caption legend item seven times, each a few points
//  different from its siblings — spacing 4 here and 5 there, a 7×7 square on
//  one chart and a 9×9 on another. None of the differences were decisions;
//  they were drift, and every one was a font change away from getting worse.
//  This is the LoadMetrics argument again: two things that look identical
//  today and are maintained separately will not look identical in six months.
//
//  What was UNIFIED in the move, stated so nobody hunts for the pixel: legend
//  spacing settles on 5 pt, squares on 8 pt with a 1.5 pt radius (was 7×7 r1
//  and 9×9 r2), and every label is dim — a swatch beside a label is the
//  identity, and colouring the label as well says the same thing twice.
//

import SwiftUI

// MARK: - A fraction of a track

/// A filled share of a capsule track — shoe wear, a zone's share of a session,
/// a segment's share of a run.
///
/// NOT a replacement for `ProgressView`. The stock control keeps its jobs: it
/// means "completion of a count" (sessions done, weeks passed). This means "a
/// magnitude shown against a whole", carries meaning in its tint, and never
/// lets a non-zero sliver vanish — `slug` keeps "a little" from rendering as
/// "none", which a stock progress bar is happy to do at small fractions.
struct TrackBar: View {

    /// 0…1. Values outside are clamped rather than trusted.
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5
    /// Minimum drawn width for a non-zero fraction. Zero means "draw nothing",
    /// so a genuinely empty bar stays visibly empty.
    var slug: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let f = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.line)
                Capsule().fill(tint)
                    .frame(width: f <= 0 ? 0 : max(slug, geo.size.width * f))
            }
        }
        .frame(height: height)
    }
}

// MARK: - One legend entry

/// A mark and its caption. The mark carries the identity; the caption is
/// always dim.
///
/// An enum of marks rather than a generic, on the SeriesSwatch precedent: the
/// closed set is the point. A new kind of mark should be a deliberate addition
/// here, not an ad-hoc HStack at a call site — that is how the seven copies
/// happened.
struct LegendItem: View {

    enum Mark {
        /// A chart-series mark — line, area band, or dashed rule.
        case swatch(SeriesSwatch)
        /// A point-mark key: route endpoints, the scrub cursor.
        case dot(Color)
        /// A categorical block, for bar and band charts.
        case square(Color)
        /// An SF Symbol used as a mark on the chart itself.
        case symbol(String, Color)
        /// The escape hatch, for marks that are genuinely one of a kind —
        /// today, only the chequered finish flag.
        case view(AnyView)
    }

    let mark: Mark
    let label: String
    var font: Font = .caption2

    init(_ mark: Mark, _ label: String, font: Font = .caption2) {
        self.mark = mark
        self.label = label
        self.font = font
    }

    var body: some View {
        HStack(spacing: 5) {
            markView
            Text(label).font(font).foregroundStyle(Color.dim)
        }
        // Never let a two-word label break across lines — the lesson the split
        // table's legend learned the hard way, applied to all of them.
        .fixedSize()
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .swatch(let s):
            s
        case .dot(let c):
            Circle().fill(c).frame(width: 7, height: 7)
        case .square(let c):
            RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 8, height: 8)
        case .symbol(let name, let c):
            Image(systemName: name).font(.system(size: 7)).foregroundStyle(c)
        case .view(let v):
            v
        }
    }
}
