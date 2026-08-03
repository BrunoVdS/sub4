//
//  PMCCard.swift
//  Sub4
//
//  The fitness curve, on Progress.
//
//  THREE QUANTITIES, TWO MARKS
//  ---------------------------
//  Fitness, fatigue and freshness — but freshness is not a third series. It is
//  literally CTL minus ATL, so it is drawn as the GAP between the two lines,
//  shaded. When the green line sits above the amber one you are fresh, and the
//  size of the gap is the number. Nothing is encoded twice, nothing needs a
//  second axis, and the one relationship that matters is geometric rather than
//  something you have to hold in your head across two charts.
//
//  ONE AXIS. All three are in the same units — they are averages of the same
//  daily series — so there is no excuse for a second scale here, and no need.
//
//  WHY 120 DAYS
//  ------------
//  Far enough back to show the Ironman block draining away, which is the honest
//  answer to "am I starting this plan from fitness or from zero". Short enough
//  that a week is still a visible distance. The series itself runs from January
//  and will run to March; drawing all of it would compress the part you can act
//  on into nothing.
//
//  WHAT IT REFUSES TO DRAW
//  -----------------------
//  A curve it does not believe. Inside the 42-day warm-up, or with more than a
//  fifth of the recent window filled in for days that could not be scored, the
//  caveat replaces the headline instead of sitting under it. A fitness curve is
//  the single most authoritative-looking object this app can put on screen, and
//  authority is exactly what it should not have when it is guessing.
//

import SwiftUI
import Charts

struct PMCCard: View {

    private let store = LoadStore.shared

    struct Point: Identifiable {
        let date: Date
        let ctl: Double
        let atl: Double
        let imputed: Bool
        var id: Date { date }
    }

    /// Days of history drawn. See the note above.
    private let windowDays = 120

    /// The points, rebuilt only when the series behind them changes.
    ///
    /// Deliberately NOT a snapshot of the summary. An earlier version cached
    /// that too and read `summary ?? store.pmc` — which short-circuits once the
    /// cache is warm, so no LoadStore property was read during a body pass, the
    /// observation registration was dropped, and the card froze on its first
    /// value while every other card on the page updated. The summary is read
    /// live every pass; it is two multiply-adds per day and cheap enough.
    @State private var cache: [Point] = []

    // Fitness forward, fatigue in the warning colour. Validated against the
    // card surface #181b22: ΔE 10.8 for protanopia and 20.7 for normal vision,
    // both clear of the floors. Both series are named in the legend and in the
    // header, so identity never rests on colour alone.
    private let ctlTint = Color.ctlTint
    private let atlTint = Color.atlTint

    var body: some View {
        let s = store.pmc
        // Expandable ONLY when the curve is worth reading. Otherwise the card
        // refuses to draw a curve and a tap opens a full-screen one anyway,
        // which is the trust gate leaking out through the back door.
        if s.caveat == nil {
            // Opens on Fitness, switches to Load pattern in place. The group is
            // named in ExpandableCard so this card and the Today strip cannot
            // disagree about what is reachable.
            ExpandableCard(panels: PanelGroup.load, opensOn: "fitness") {
                card(s)
            }
        } else {
            card(s)
        }
    }

    private func card(_ s: PMCSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The caveat REPLACES the headline rather than sitting under it. A
            // bold fitness number above the words "the curve is describing the
            // fill, not the training" is the number winning the argument.
            if let c = s.caveat {
                Text("Fitness").font(.subheadline.weight(.semibold))
                Text(c).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                header(s)
                chart(cache.isEmpty ? points(s) : cache)
                legend
                footnote(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        // Progress does not build the series itself, so landing straight on
        // this tab would otherwise show "No load series yet" and stay there.
        .task { store.recomputeIfNeeded() }
        .onChange(of: store.computedAt, initial: true) { _, _ in
            cache = points(store.pmc)
        }
    }

    // MARK: Header

    private func header(_ s: PMCSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text("Fitness").font(.subheadline.weight(.semibold))
                    // In the header row, not top-right — top-right is where the
                    // headline number lives on every card on this page.
                    InfoButton(topic: .fitness)
                }
                Text(rampLine(s)).font(.caption).foregroundStyle(Color.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.ctl.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ctlTint)
                if let t = s.tsb {
                    Text(String(format: "%@ · %+.0f", PMC.freshnessLabel(t), t))
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        }
    }

    /// The ramp is the number a build is actually steered by, so it goes in the
    /// subtitle rather than being left for the reader to eyeball off a slope.
    private func rampLine(_ s: PMCSummary) -> String {
        guard let r = s.ramp else { return "not enough history" }
        let direction = r > 0.5 ? "building" : (r < -0.5 ? "falling" : "holding")
        return String(format: "%@ · %+.1f CTL/week", direction, r)
    }

    // MARK: Chart

    private func points(_ s: PMCSummary) -> [Point] {
        s.points.suffix(windowDays).compactMap { p in
            guard let d = DayKey.date(p.dayKey) else { return nil }
            return Point(date: d, ctl: p.ctl, atl: p.atl, imputed: p.imputed)
        }
    }

    private func chart(_ pts: [Point]) -> some View {
        Chart {
            // Freshness, as the distance between the two. Drawn first so the
            // lines sit on top of it.
            ForEach(pts) { p in
                AreaMark(x: .value("Day", p.date),
                         yStart: .value("CTL", p.ctl),
                         yEnd: .value("ATL", p.atl))
                    .foregroundStyle(Color.ink.opacity(0.06))
                    .interpolationMethod(.monotone)
            }

            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date),
                         y: .value("Load", p.ctl),
                         series: .value("s", "ctl"))
                    .foregroundStyle(ctlTint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }

            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date),
                         y: .value("Load", p.atl),
                         series: .value("s", "atl"))
                    .foregroundStyle(atlTint)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }

            if let start = DayKey.date(MatchRules.planStartDayKey),
               let first = pts.first?.date, start >= first {
                RuleMark(x: .value("Day", start))
                    .foregroundStyle(Color.accent4.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("plan").font(.system(size: 8))
                            .foregroundStyle(Color.accent4.opacity(0.7))
                    }
            }
        }
        // The domain, not left to Swift Charts. Its ladder is 1/2/5 × 10ⁿ, so a
        // peak of 110 gets an axis to 200 and the top half of the card is empty.
        .chartYScale(domain: ChartScale.domain(pts.flatMap { [$0.ctl, $0.atl] }))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.3))
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(height: 140)
    }

    private var legend: some View {
        HStack(spacing: 13) {
            LegendItem(.swatch(.line(ctlTint)), "Fitness")
            LegendItem(.swatch(.line(atlTint)), "Fatigue")
            HStack(spacing: 4) {
                Rectangle().fill(Color.ink.opacity(0.12))
                    .frame(width: 9, height: 7)
                Text("the gap is freshness")
                    .font(.caption2).foregroundStyle(Color.dim)
            }
            Spacer()
        }
    }

    // MARK: Footnote

    /// DATA ONLY, AND ONLY WHEN THERE IS ANY
    /// --------------------------------------
    /// This used to open with "42-day and 7-day averages of daily training
    /// load" on every render. That is a definition, it is already the first two
    /// entries in the ⓘ sheet word for word, and it was the permanent third
    /// line of a card whose other two lines carry figures.
    ///
    /// What remains are counts you cannot get anywhere else on this card, and
    /// they appear only when they are non-zero — so the line shows up when
    /// something is wrong with the data and is absent when nothing is. That is
    /// the right way round: a caption that is always there is furniture, and a
    /// caption that appears is a signal.
    ///
    /// "filled in where nothing could be scored" went to ⓘ *Filled in*, which
    /// already said it.
    @ViewBuilder
    private func footnote(_ s: PMCSummary) -> some View {
        if let line = footnoteLine(s) {
            Text(line)
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footnoteLine(_ s: PMCSummary) -> String? {
        var bits: [String] = []
        if s.imputedCount > 0 {
            bits.append("\(s.imputedCount) day\(s.imputedCount == 1 ? "" : "s") filled in")
        }
        if s.partialCount > 0 {
            bits.append("\(s.partialCount) partial")
        }
        guard !bits.isEmpty else { return nil }
        return bits.joined(separator: " · ")
    }
}

// MARK: - The whole series, full screen
//
// The card draws 120 days because that is what fits. Here there is room for all
// of it — January onwards, the Ironman block and the marathon block in one
// picture — plus a cursor, because at this width a single day is finally wide
// enough to point at.

struct PMCExpanded: View {

    private let store = LoadStore.shared
    @State private var selected: Date?
    /// Held OUTSIDE this view, so switching to Load pattern and back does not
    /// silently turn every series on again. Still reset on each open — see
    /// SeriesToggle for why that is deliberate rather than lazy, and
    /// PanelToggles for why it had to leave.
    private let toggles = PanelToggles.shared
    private var hidden: Set<String> { toggles.hidden["fitness"] ?? [] }

    private let ctlTint = Color.ctlTint
    private let atlTint = Color.atlTint

    private var options: [SeriesOption] {
        [SeriesOption("ctl", "Fitness", .line(Color.ctlTint)),
         SeriesOption("atl", "Fatigue", .line(Color.atlTint)),
         SeriesOption("tsb", "Freshness", .area),
         // NOT "Even weeks" — the first label, and it read as "weeks 2, 4, 6"
         // rather than "weeks with no variation in them". A control whose name
         // has two readings is a control you have to be told about.
         SeriesOption("even", "High monotony", .rule(Color.bandTint))]
    }

    private var showCTL: Bool { !hidden.contains("ctl") }
    private var showATL: Bool { !hidden.contains("atl") }
    /// The band needs both its edges. See the note in SeriesToggle.
    private var showTSB: Bool { !hidden.contains("tsb") && showCTL && showATL }
    private var showEven: Bool { !hidden.contains("even") }

    /// Contiguous runs of days whose seven-day monotony reached Foster's
    /// figure, as date ranges to shade.
    ///
    /// This is the pattern dimension arriving on the chart where fitness is
    /// read, without a second y-axis: a background band carries no scale, so
    /// it can say "these weeks had no shape" beside curves measured in
    /// something else entirely.
    private var evenRuns: [(start: Date, end: Date)] {
        var out: [(Date, Date)] = []
        var open: Date?
        var last: Date?
        for m in store.monotony {
            guard let d = DayKey.date(m.dayKey) else { continue }
            let high = m.isTrustworthy && (m.monotony ?? 0) >= Monotony.highMonotony
            if high {
                if open == nil { open = d }
                last = d
            } else if let o = open, let l = last {
                out.append((o, l)); open = nil; last = nil
            }
        }
        if let o = open, let l = last { out.append((o, l)) }
        return out
    }

    private struct Point: Identifiable {
        let date: Date
        let ctl: Double
        let atl: Double
        let tsb: Double?
        var id: Date { date }
    }

    private var points: [Point] {
        store.pmc.points.compactMap { p in
            guard let d = DayKey.date(p.dayKey) else { return nil }
            return Point(date: d, ctl: p.ctl, atl: p.atl, tsb: p.tsb)
        }
    }

    /// The point nearest the cursor, or the last one when nothing is selected.
    private func current(_ pts: [Point]) -> Point? {
        guard let selected else { return pts.last }
        return pts.min {
            abs($0.date.timeIntervalSince(selected))
                < abs($1.date.timeIntervalSince(selected))
        }
    }

    var body: some View {
        let pts = points
        VStack(alignment: .leading, spacing: 8) {
            readout(current(pts))
            SeriesToggleBar(options: options, hidden: toggles.binding("fitness"))
            Chart {
                // First, so every curve is drawn over it.
                if showEven {
                    ForEach(evenRuns, id: \.start) { r in
                        RectangleMark(xStart: .value("From", r.start),
                                      xEnd: .value("To", r.end))
                            // Not 10%. It is competing with the freshness fill
                            // already tinting the same region at 6% white, and
                            // at a tenth it was visible only where nothing else
                            // was drawn. 16% while the fill was warm; 20% since
                            // patch 142 made it slate, which separates less from
                            // a cool card at the same alpha.
                            .foregroundStyle(Color.bandTint.opacity(Color.bandFill))
                    }
                }
                if showTSB {
                    ForEach(pts) { p in
                        AreaMark(x: .value("Day", p.date),
                                 yStart: .value("CTL", p.ctl),
                                 yEnd: .value("ATL", p.atl))
                            .foregroundStyle(Color.ink.opacity(0.06))
                            .interpolationMethod(.monotone)
                    }
                }
                if showCTL {
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date),
                                 y: .value("Load", p.ctl),
                                 series: .value("s", "ctl"))
                            .foregroundStyle(ctlTint)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
                if showATL {
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date),
                                 y: .value("Load", p.atl),
                                 series: .value("s", "atl"))
                            .foregroundStyle(atlTint)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                            .interpolationMethod(.monotone)
                    }
                }
                if let start = DayKey.date(MatchRules.planStartDayKey) {
                    RuleMark(x: .value("Day", start))
                        .foregroundStyle(Color.accent4.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("plan").font(.system(size: 9))
                                .foregroundStyle(Color.accent4.opacity(0.7))
                        }
                }
                if let c = current(pts), selected != nil {
                    RuleMark(x: .value("Day", c.date))
                        .foregroundStyle(Color.line)
                        .zIndex(-1)
                }
            }
            .chartXSelection(value: $selected)
            // The domain follows what is DRAWN. Keeping fatigue's peaks in the
            // scale after hiding fatigue would leave the fitness curve in the
            // bottom third of a chart with nothing above it.
            .chartYScale(domain: ChartScale.domain(
                pts.flatMap { p in
                    (showCTL ? [p.ctl] : []) + (showATL ? [p.atl] : [])
                }))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                    AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                    AxisGridLine().foregroundStyle(Color.line.opacity(0.3))
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        }
    }

    private func readout(_ p: Point?) -> some View {
        HStack(spacing: 18) {
            if let p {
                stat(DayKey.pretty(p.date), "", Color.dim)
                stat("Fitness", String(format: "%.0f", p.ctl), ctlTint,
                     swatch: .line(Color.ctlTint))
                stat("Fatigue", String(format: "%.0f", p.atl), atlTint,
                     swatch: .line(Color.atlTint))
                if let t = p.tsb {
                    stat(PMC.freshnessLabel(t), String(format: "%+.0f", t), Color.dim,
                         swatch: .area)
                }
            }
            Spacer()
            if selected != nil {
                Button("Clear") { selected = nil }
                    .font(.caption2).buttonStyle(.plain)
                    .foregroundStyle(Color.dim)
            }
        }
    }

    /// A dot carries the identity, the numeral stays in ink.
    ///
    /// Colouring the number itself was the obvious alternative and it fails
    /// twice: freshness is an AREA with no line colour to borrow, and on the
    /// Today strip the load figure is already using colour to say whether the
    /// day was measured — a second meaning on the same channel.
    private func stat(_ label: String, _ value: String, _ colour: Color,
                      swatch: SeriesSwatch? = nil) -> some View {
        HStack(spacing: 5) {
            if let swatch { swatch }
            Text(label).font(.caption2).foregroundStyle(Color.dim)
            if !value.isEmpty {
                Text(value).font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(swatch == nil ? colour : Color.ink)
            }
        }
    }
}
