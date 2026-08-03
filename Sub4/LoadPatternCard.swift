//
//  LoadPatternCard.swift
//  Sub4
//
//  The shape of the week, which is the one thing the fitness curve cannot show.
//
//  WHY IT IS NOT ON THE FITNESS CHART
//  ----------------------------------
//  The obvious place for monotony is beside CTL and ATL, and it cannot go
//  there. Monotony lives in 0–4; strain during a build runs past 1000; CTL and
//  ATL sit in 0–150. Putting any of them on that axis means either a second
//  scale or squashing the fitness curve into the bottom tenth of the card, and
//  the convention at the top of ProgressTabView is explicit: one y-axis per
//  chart, never two.
//
//  So it gets its own card, immediately after Fitness, because it is the same
//  family of question asked about the same days.
//
//  MONOTONY IS THE LINE, STRAIN IS TEXT
//  ------------------------------------
//  Monotony is unitless and has a threshold worth drawing — Foster's 2.0 — so
//  a curve against a rule line says something at a glance.
//
//  Strain has neither. It scales with the athlete's own volume, so its absolute
//  height means nothing without a comparison, and a curve of an unbounded
//  number invites reading a peak as a problem. A rank against the athlete's own
//  trailing history — "the 3rd highest of the 41 days that carried a strain
//  figure" — says the same thing honestly and in one line.
//
//  THE LINE BREAKS RATHER THAN BRIDGING
//  ------------------------------------
//  A window containing an imputed day is excluded, and the line stops and
//  restarts around it. This is not tidiness: a filled-in day sits at the
//  trailing mean, which shrinks the spread and pushes monotony UP, so drawing
//  through those points would put a peak in the curve that describes the fill
//  rather than the training — and a peak is exactly what the eye goes to on
//  this chart. A gap is honest; an interpolation is a fabricated finding.
//
//  EXPANDED IS TWO PLOTS, NOT A BIGGER ONE
//  ---------------------------------------
//  Monotony alone is genuinely incomplete: 1.9 tells you the week was even, not
//  whether it was even at 40 a day or at 120. Weekly load supplies that, and it
//  cannot share the axis either — so the panel stacks two plots over one shared
//  x-axis. Aligned in time, never overlaid, each with its own scale. The card
//  keeps the single line, because the card is the glance.
//

import SwiftUI
import Charts

struct LoadPatternCard: View {

    @State private var load = LoadStore.shared

    /// Below this the curve is more gap than line and says nothing. Same rule
    /// every other chart on the tab follows: hide rather than draw noise.
    static let minCleanWindows = 8

    /// What the card shows. The panel shows everything.
    static let cardDays = 120

    /// Read here AND by PanelGroup, so the switcher never offers a panel this
    /// card has decided not to draw.
    static var hasEnoughWindows: Bool {
        LoadStore.shared.monotony
            .filter { $0.isTrustworthy && $0.monotony != nil }
            .count >= minCleanWindows
    }

    var body: some View {
        let all = load.monotony
        let clean = all.filter { $0.isTrustworthy && $0.monotony != nil }
        if clean.count >= Self.minCleanWindows {
            // Opens on Load pattern, switches to Fitness in place.
            ExpandableCard(panels: PanelGroup.load, opensOn: "pattern") {
                LoadPatternBody(points: Array(all.suffix(Self.cardDays)),
                                series: all,
                                height: 140, showLoadPlot: false)
            }
        }
    }
}

struct LoadPatternExpanded: View {
    @State private var load = LoadStore.shared
    /// Held outside the view so a switch to Fitness and back does not reset it.
    /// Still cleared on every open — see SeriesToggle and PanelToggles.
    private let toggles = PanelToggles.shared
    private var hidden: Set<String> { toggles.hidden["pattern"] ?? [] }

    private var options: [SeriesOption] {
        [SeriesOption("mono", "Monotony", .line(Color.ink.opacity(0.72))),
         SeriesOption("load", "Weekly load", .line(Color.accent4))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SeriesToggleBar(options: options, hidden: toggles.binding("pattern"))
            LoadPatternBody(points: load.monotony,
                            series: load.monotony,
                            height: nil,
                            showLoadPlot: !hidden.contains("load"),
                            showMonotonyPlot: !hidden.contains("mono"),
                            chrome: false)
        }
    }
}

// MARK: - The chart

struct LoadPatternBody: View {

    /// What is drawn.
    let points: [MonotonyPoint]
    /// The whole series, for ranking strain against a longer history than the
    /// window on screen.
    let series: [MonotonyPoint]
    /// nil means "take the height you are given" — the expanded panel.
    let height: CGFloat?
    /// The second, stacked plot. Panel only.
    let showLoadPlot: Bool
    /// The panel can hide the monotony plot to give the whole height to load.
    /// The card never can — it IS the monotony plot.
    var showMonotonyPlot = true
    var chrome = true

    /// Neutral on purpose. Monotony is not a discipline, and borrowing run
    /// green or bike cyan would break the rule that colour follows the entity.
    private let lineTint = Color.ink.opacity(0.72)

    /// The headline comes from the last window with NO imputed day in it —
    /// the same rule the line follows. Reading `points.last` printed a figure
    /// the chart had just declined to draw.
    private var latest: MonotonyPoint? { Monotony.latestTrustworthy(points) }

    /// True when the current window is not drawable, so the headline is
    /// describing an earlier day and has to say so.
    ///
    /// `latestTrustworthy` steps back for EITHER reason — a filled-in day or a
    /// week with no spread — so the caption states the date and leaves the two
    /// causes to the info sheet. It used to name imputation alone, which was
    /// wrong every time the real cause was a rest week.
    private var headlineIsStale: Bool {
        guard let l = latest, let last = points.last else { return false }
        return l.dayKey != last.dayKey
    }

    /// Trustworthy points grouped into unbroken runs. Each run is its own
    /// series, which is what makes the line stop at an imputed window instead
    /// of bridging it.
    private var segments: [(id: Int, points: [MonotonyPoint])] {
        var out: [(Int, [MonotonyPoint])] = []
        var current: [MonotonyPoint] = []
        var id = 0
        for p in points {
            if p.isTrustworthy, p.monotony != nil {
                current.append(p)
            } else if !current.isEmpty {
                out.append((id, current)); id += 1; current = []
            }
        }
        if !current.isEmpty { out.append((id, current)) }
        return out
    }

    private var dates: [Date] { points.compactMap { DayKey.date($0.dayKey) } }

    private var xDomain: ClosedRange<Date>? {
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else { return nil }
        return lo...hi
    }

    private var monotonyDomain: ClosedRange<Double> {
        let vs = points.compactMap(\.monotony)
        // Always includes the threshold: a chart of a rule you cannot see is
        // a chart of a number without its meaning.
        return ChartScale.domain(vs + [Monotony.highMonotony * 1.1], minimum: 2.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chrome {
                HStack(spacing: 2) {
                    Text("LOAD PATTERN").font(.caption2.weight(.bold)).tracking(0.5)
                    InfoButton(topic: .loadPattern)
                    Spacer()
                    // "higher is more even" moved to ⓘ *Monotony*, whose first
                    // sentence is that and more. The header keeps the subject.
                    Text("monotony").font(.caption2)
                }
                .foregroundStyle(Color.dim)
            }

            if height == nil {
                // Panel. Whatever is switched on shares the height between it;
                // one plot alone gets all of it rather than half and a gap.
                //
                // EACH READING UNDER ITS OWN PLOT — see the Readings section.
                // Nested at spacing 4 rather than the stack's 10, so a reading
                // reads as attached to the chart above it rather than as a
                // third item floating in the seam between two charts. Inside
                // the toggle branch, so switching a series off takes its
                // numbers with it.
                if showMonotonyPlot {
                    VStack(alignment: .leading, spacing: 4) {
                        monotonyChart.frame(maxHeight: .infinity)
                        monotonyCaption
                    }
                    .frame(maxHeight: .infinity)
                }
                if showLoadPlot {
                    VStack(alignment: .leading, spacing: 4) {
                        loadChart.frame(maxHeight: .infinity)
                        loadCaption
                    }
                    .frame(maxHeight: .infinity)
                }
                if !showMonotonyPlot && !showLoadPlot {
                    Text("Both series are switched off.")
                        .font(.caption).foregroundStyle(Color.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The foot of the panel, under both. Gated on the monotony plot
                // because it counts windows of that series — with monotony off
                // there is no drawing for it to be a footnote about.
                if showMonotonyPlot { undrawnFootnote }
            } else {
                // The card IS the monotony plot and nothing else, so its reading
                // and its footnote both stay at the foot, under the legend.
                monotonyChart.frame(height: height)
            }

            if chrome {
                legend
                monotonyCaption
                undrawnFootnote
            }
        }
        .modifier(PatternChrome(on: chrome))
    }

    private var monotonyChart: some View {
        Chart {
            ForEach(segments, id: \.id) { seg in
                ForEach(seg.points) { p in
                    if let d = DayKey.date(p.dayKey), let m = p.monotony {
                        LineMark(x: .value("Day", d), y: .value("Monotony", m),
                                 series: .value("Segment", seg.id))
                            .foregroundStyle(lineTint)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            // Last, so it is never under the line.
            RuleMark(y: .value("Foster", Monotony.highMonotony))
                .foregroundStyle(Color.bandTint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .chartYScale(domain: monotonyDomain)
        .modifier(SharedX(domain: xDomain))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: chrome ? 4 : 7)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
    }

    /// The second half of the answer: how even, at what volume.
    private var loadChart: some View {
        Chart {
            ForEach(points) { p in
                if let d = DayKey.date(p.dayKey) {
                    AreaMark(x: .value("Day", d),
                             y: .value("Weekly load", p.weeklyLoad))
                        .foregroundStyle(Color.accent4.opacity(0.22))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", d),
                             y: .value("Weekly load", p.weeklyLoad))
                        .foregroundStyle(Color.accent4)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: ChartScale.domain(points.map(\.weeklyLoad), minimum: 100))
        .modifier(SharedX(domain: xDomain))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            LegendItem(.swatch(.line(lineTint)), "Monotony")
            LegendItem(.swatch(.rule(Color.bandTint)),
                       String(format: "Foster %.1f", Monotony.highMonotony))
            if showLoadPlot {
                LegendItem(.swatch(.line(Color.accent4)), "Weekly load")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Why a window is not drawn
    //
    // TWO CAUSES, AND THE CAPTION USED TO NAME ONLY ONE
    // -------------------------------------------------
    // `broken` was computed as
    //
    //     points.count - points.filter { $0.isTrustworthy && $0.monotony != nil }.count
    //
    // which folds together two entirely different conditions, and the sentence
    // underneath asserted the first of them for both:
    //
    //   NOT TRUSTWORTHY  imputedInWindow > 0 — a filled-in day sits at the
    //                    trailing mean, which shrinks the spread and inflates
    //                    monotony. A data fault.
    //   NO SPREAD        monotony == nil, i.e. SD <= 0.001 — seven days at an
    //                    identical load. In practice, seven days of nothing.
    //                    Foster's ratio is undefined there, not infinite. NOT a
    //                    fault: it is a rest week, which is a fact about the
    //                    training.
    //
    // On a series with zero imputed days the card was still reporting "a
    // filled-in day sits at the mean" for every gap in the line — describing a
    // problem the data did not have, while the real reason (a recovery block)
    // went unnamed. The Fitness card two above says "0 days filled in" on the
    // same series, and the two cards contradicted each other in plain sight.
    //
    // Counted separately now. The card prints the counts; both reasons live in
    // the info sheet, where there is room to say which is which.

    /// Windows dropped because the week had no spread — a rest block.
    private var flatWindows: Int {
        points.filter { $0.isTrustworthy && $0.monotony == nil }.count
    }

    /// Windows dropped because a day in them was filled in.
    private var unfitWindows: Int {
        points.filter { !$0.isTrustworthy }.count
    }

    /// Counts only. Assembled as a `String` outside the view builder — the rule
    /// this project learned in patch 76.
    private var undrawnLabel: String? {
        let flat: Int = flatWindows
        let unfit: Int = unfitWindows
        guard flat + unfit > 0 else { return nil }
        var parts: [String] = []
        if flat > 0 { parts.append("\(flat) with no spread") }
        if unfit > 0 { parts.append("\(unfit) with a filled-in day") }
        let total: String = "\(flat + unfit) of \(points.count) windows not drawn"
        return total + " · " + parts.joined(separator: ", ")
    }

    // MARK: Readings
    //
    // ONE READING PER PLOT, EACH UNDER ITS OWN PLOT
    // ----------------------------------------------
    // Until patch 90 the panel stacked five lines in one block, and that block
    // sat under whichever chart happened to be last. Every figure in it —
    // monotony, its band, rest days, strain, the stale-week date — comes from
    // the monotony window, so under the weekly-load chart it read as that
    // chart's caption and described nothing on screen.
    //
    //   MONOTONY      one line: value · band · rest · strain. Strain stays here
    //                 rather than moving to the load plot even though it is
    //                 weekly load × monotony: it is undefined exactly when
    //                 monotony is, it steps back to the same earlier week, and
    //                 the amber date line below governs it. Split them and the
    //                 number loses its date.
    //   WEEKLY LOAD   its own reading, which it never had. A plain 7-day sum,
    //                 never undefined, so it can carry a figure on days the
    //                 monotony line cannot.
    //   FOOTNOTE      the undrawn-window counts. Not a reading of either series
    //                 — a statement about the drawing — so it goes to the foot,
    //                 under both, where a footnote goes.

    /// "0.63 · Varied". Kept separate from the rest of the line because it is
    /// the only part that changes colour above Foster's threshold.
    private func headlineValue(_ m: MonotonyPoint) -> String? {
        guard let v = m.monotony else { return nil }
        return String(format: "%.2f · %@", v, Monotony.label(v))
    }

    /// Everything after it, dim: rest days and strain, compressed onto the same
    /// line. The window the rank is drawn from is stated in the info sheet
    /// rather than spelled out here every time.
    private func headlineRest(_ m: MonotonyPoint) -> String {
        var parts: [String] = ["\(m.restInWindow) of 7 rest"]
        if let s = m.strain {
            let value: String = String(format: "Strain %.0f", s)
            if let r = Monotony.strainRank(series, of: s) {
                let suffix: String = ordinalSuffix(r.rank)
                parts.append(value + " (\(r.rank)\(suffix) of \(r.of))")
            } else {
                parts.append(value + " · unranked")
            }
        }
        return "· " + parts.joined(separator: " · ")
    }

    /// The weekly-load plot's own reading: the last point of the series it
    /// draws, which is a plain seven-day total and never goes undefined.
    private var loadReading: String? {
        guard let p = points.last, let d = DayKey.date(p.dayKey) else { return nil }
        let value: String = String(format: "%.0f", p.weeklyLoad)
        return "Weekly load " + value + " · 7 days to " + DayKey.short(d)
    }

    @ViewBuilder
    private var monotonyCaption: some View {
        if let m = latest {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let v = headlineValue(m), let mv = m.monotony {
                        Text(v)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(mv >= Monotony.highMonotony
                                             ? Color.slowerColor : Color.ink)
                    }
                    Text(headlineRest(m))
                        .font(.caption2).foregroundStyle(Color.dim)
                    Spacer(minLength: 0)
                }
                .lineLimit(1).minimumScaleFactor(0.7)

                if headlineIsStale, let d = DayKey.date(m.dayKey) {
                    Text("Figures are for the week ending \(DayKey.short(d)).")
                        .font(.caption2).foregroundStyle(Color.slowerColor)
                }
            }
        }
    }

    @ViewBuilder
    private var loadCaption: some View {
        if let line = loadReading {
            Text(line).font(.caption2).foregroundStyle(Color.dim)
        }
    }

    @ViewBuilder
    private var undrawnFootnote: some View {
        if let line = undrawnLabel {
            Text(line)
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ordinalSuffix(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "th"
        default:
            switch n % 10 {
            case 1: return "st"; case 2: return "nd"; case 3: return "rd"
            default: return "th"
            }
        }
    }
}

/// Both plots take the same x domain so the two are readable against each
/// other. Without it Swift Charts picks each domain from its own data and the
/// same date sits at two different offsets.
private struct SharedX: ViewModifier {
    let domain: ClosedRange<Date>?
    func body(content: Content) -> some View {
        Group {
            if let domain { content.chartXScale(domain: domain) } else { content }
        }
    }
}

private struct PatternChrome: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        Group {
            if on { content.cardStyle() } else { content }
        }
    }
}
