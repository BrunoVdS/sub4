//
//  ProgressTabView.swift
//  Sub4
//
//  Trends across the block. Named ProgressTabView because `ProgressView` is
//  SwiftUI's own type.
//
//  Chart conventions used throughout:
//   • one y-axis per chart, never two — different measures get separate charts
//   • actual data in the accent hue; the plan is a recessive grey reference,
//     because it's a benchmark rather than a competing series
//   • labels only where they carry information, never on every mark
//   • zone colours always accompanied by their "Z2" label, never colour alone
//   • charts hide themselves until there's enough data to read
//

import SwiftUI
import Charts

struct ProgressTabView: View {

    private let store = PlanStore.shared
    @State private var matcher = Matcher.shared
    @State private var activities = ActivityStore.shared
    @State private var athlete = AthleteStore.shared
    @State private var notes = NotesStore.shared
    @State private var proposals = ProposalStore.shared
    @State private var showReview = false
    @State private var review: Review?
    /// Time in zone reads the scored series, not the activity list — the
    /// distribution lives on `WorkoutLoad`.
    @State private var load = LoadStore.shared
    @AppStorage(ZoneWindowKey.selected) private var zoneWindowRaw = ZoneWindow.days90.rawValue

    private var todayKey: String { DayKey.key() }

    // MARK: Week aggregation

    struct WeekPoint: Identifiable {
        let weekNo: Int
        let start: Date
        let plannedKm: Double        // RUNNING only — see PlanStore.plannedRunKm
        let plannedExact: Bool
        let actualKm: Double         // RUNNING only, so the two are comparable
        let longestRunKm: Double
        let done: Int
        let total: Int
        var id: Int { weekNo }
    }

    /// Only weeks that have begun — a future week has nothing to say.
    private var points: [WeekPoint] {
        store.planWeeks.compactMap { w -> WeekPoint? in
            guard let n = w.weekNo,
                  let startKey = w.startDate,
                  startKey <= todayKey,
                  let start = DayKey.date(startKey) else { return nil }

            var actual = 0.0, longest = 0.0, done = 0, total = 0
            for offset in 0..<7 {
                guard let d = Calendar(identifier: .iso8601)
                        .date(byAdding: .day, value: offset, to: start) else { continue }
                let key = DayKey.key(d)
                let r = matcher.day(key)

                // OPTIONAL SESSIONS EXCLUDED, as they are everywhere else.
                // This filter was missing until patch 98: the tally counted the
                // plan's 28 optional Zwift rides while every distance figure on
                // the same card excluded them, and the info sheet said they were
                // not counted. Week 1 has no optional sessions, which is why it
                // never showed.
                for m in r.matches
                where !m.session.isRest && !PlanStore.isOptional(m.session) {
                    total += 1
                    if m.isDone { done += 1 }
                }
                // RUNS only. The planned figure this is charted against is
                // running kilometres, so anything else here would be comparing
                // two different quantities on one axis.
                for a in (r.matches.compactMap(\.activity) + r.extras)
                where a.discipline == .run {
                    actual += a.km
                    longest = max(longest, a.km)
                }
            }

            let planned = store.plannedRunKm(week: w)
            return WeekPoint(weekNo: n, start: start,
                             plannedKm: planned.km,
                             plannedExact: planned.exact,
                             actualKm: actual, longestRunKm: longest,
                             done: done, total: total)
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // ORDER IS DELIBERATE, top to bottom:
                    //
                    //   where the block is and how much of it is done, in one
                    //   card — then the four charts that describe the training
                    //   itself, fitness first because it is the summary of the
                    //   other three — then the two pieces of equipment-and-
                    //   habit context, which are reference rather than trend —
                    //   then the review, which is the only thing here you act
                    //   on rather than read, and belongs at the end of the read.
                    overviewCard

                    PMCCard()                                 // Fitness
                    LoadPatternCard()                         // monotony · strain
                    VolumeCard()                              // Weekly volume · run/bike/swim
                    if points.count >= 2 { longRunCard }      // hidden until week 2
                    PaceCard()                                // Pace · run/bike/swim
                    if athlete.hasZones { zoneCard }          // Time in zone

                    shoesCard
                    CommuteCard()

                    reviewCard

                    if points.isEmpty { emptyState }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.bg)
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await activities.sync() }
        }
        .tint(.accent4)
    }

    // MARK: Monthly review
    //
    // Lives in Progress rather than Settings because it is something you read,
    // which is the same rule that moved zones and shoes here. It shows the
    // headline flag count rather than a bare link, so a blocking flag is
    // visible without opening it.

    @ViewBuilder
    private var reviewCard: some View {
        // Shown only when there is something to show: a review that has
        // actually been run, or one that is due. The old version was permanent
        // and spent the first six weeks of the block saying "Available once the
        // first plan week has ended" — a tappable row that does nothing, in the
        // one place on this tab you are supposed to act rather than read.
        //
        // The gate deliberately does NOT include `review != nil`. `review` is
        // built by the `.task` inside the button, so gating on it would be
        // circular: card hidden, task never runs, review stays nil, card stays
        // hidden. It is also the wrong test — a review buildable over one
        // finished week is not a verdict, it is a fortnight of noise that
        // ReviewBuilder would flag as thin anyway.
        let state = ReviewDue.state()
        if state.isDue || !proposals.records.isEmpty {
            reviewButton(state)
        }
    }

    private func reviewButton(_ state: ReviewDue.State) -> some View {
        Button { showReview = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "text.magnifyingglass")
                    .font(.title3).foregroundStyle(Color.accent4).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("Monthly review").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                        if state.isDue {
                            Text("DUE").font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accent4.opacity(0.18)))
                                .foregroundStyle(Color.accent4)
                        }
                    }
                    Text(reviewSubtitle(review, state))
                        .font(.caption).foregroundStyle(Color.dim)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Color.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
        .sheet(isPresented: $showReview) { ReviewView() }
        // Rebuilt only when the inputs change, never per re-render — the
        // builder runs the matcher over four weeks of days.
        .task(id: "\(notes.count)·\(activities.count)·\(matcher.decisions.count)") {
            review = ReviewBuilder.build()
        }
    }

    /// The verdict when there is one, the due-state when there is not.
    ///
    /// The old version returned a placeholder for `nil`, which is what made the
    /// card permanent. `nil` now means the card is not drawn at all — except
    /// when a review IS due, where the due reason is the honest subtitle.
    private func reviewSubtitle(_ r: Review?, _ state: ReviewDue.State) -> String {
        guard let r else { return ReviewDue.subtitle(state) }
        let blocking = r.flags.filter { $0.level == .blocking }.count
        if blocking > 0 {
            return "\(r.window.label) · \(blocking) reason"
                + (blocking == 1 ? "" : "s") + " the data can't support a conclusion"
        }
        let warnings = r.flags.filter { $0.level == .warning }.count
        if warnings > 0 {
            return "\(r.window.label) · \(warnings) flag" + (warnings == 1 ? "" : "s")
        }
        return "\(r.window.label) · nothing flagged"
    }

    // MARK: Where we are in the plan
    //
    // Each sport in the unit the plan writes it in — km for running, HOURS for
    // the bike (the plan never gives a cycling distance), km for swimming,
    // sessions for strength. Converting hours to kilometres would need an
    // invented average speed.

    private struct VolumeRow: Identifiable {
        let id: String
        let symbol: String
        let name: String
        let done: Double
        let dueSoFar: Double
        let total: Double
        let unit: String
        let decimals: Int
        let colour: Color
        let approximate: Bool
    }

    /// Where the block is, and how much of it has been done.
    ///
    /// Two cards merged into one. They were always answering the same question
    /// at two resolutions — "week 1 of 34, 4 of 180 km run" above and "3 of 5
    /// sessions done" below — and keeping them apart meant the top of the page
    /// was two boxes of progress bars with a gap between them and no reason for
    /// the gap.
    ///
    /// The caption sits at the bottom of the merged card because it now
    /// qualifies both halves: optional sessions are excluded from the session
    /// count as well as from the kilometres.
    /// THREE TIERS, LABELLED. Patch 98.
    ///
    /// The card answered two questions and looked like it answered one. Under
    /// the per-sport bars sat "Sessions 3/4 · Adherence 75%" with no heading,
    /// and the code comment beside it claimed it described the current week. It
    /// did not: it summed every plan week that had begun, so it was block-to-
    /// date wearing a week's clothes. With one week elapsed the two are the same
    /// number, which is exactly why it survived — it would have started lying
    /// silently next Monday.
    ///
    /// Split into what they actually are:
    ///
    ///   PER SPORT     distance or hours against the block total. Unchanged.
    ///   THE BLOCK     sessions done against every session the plan asks for,
    ///                 all 34 weeks. The long view.
    ///   THIS WEEK     the same count over the current week, with the dates on
    ///                 it so it cannot be mistaken for the row above.
    ///
    /// Both session figures exclude optional sessions, as the distances do.
    private var overviewCard: some View {
        let blockDone = points.reduce(0) { $0 + $1.done }
        let blockTotal = store.requiredSessionCount
        let blockPct = blockTotal > 0 ? Double(blockDone) / Double(blockTotal) * 100 : 0

        let week = points.last
        let weekDone = week?.done ?? 0
        let weekTotal = week?.total ?? 0
        let weekPct = weekTotal > 0 ? Double(weekDone) / Double(weekTotal) * 100 : 0

        return VStack(alignment: .leading, spacing: 12) {
            planHeader
            ForEach(volumeRows) { volumeRow($0) }

            Rectangle().fill(Color.line).frame(height: 1)

            sessionBlock(title: "THE BLOCK", trailing: blockRange,
                         leftLabel: "Sessions",
                         leftValue: "\(blockDone)/\(blockTotal)",
                         rightLabel: "Complete",
                         rightValue: String(format: "%.0f", blockPct),
                         rightUnit: "%",
                         // Never green: 1% of a 34-week block is not a
                         // shortfall, and a colour here would read as one.
                         rightTint: Color.dim,
                         done: blockDone, total: blockTotal)

            Rectangle().fill(Color.line).frame(height: 1)

            sessionBlock(title: "THIS WEEK", trailing: currentWeekRange,
                         leftLabel: "Sessions",
                         leftValue: "\(weekDone)/\(weekTotal)",
                         rightLabel: "Adherence",
                         rightValue: String(format: "%.0f", weekPct),
                         rightUnit: "%",
                         rightTint: weekPct >= 85 ? Color.accent4 : Color.dim,
                         done: weekDone, total: weekTotal)
        }
        .cardStyle()
    }

    /// One shape, twice. A heading, two stats and a bar — so the block row and
    /// the week row are visibly the same kind of thing at two scales, which is
    /// the whole point of splitting them.
    private func sessionBlock(title: String, trailing: String,
                              leftLabel: String, leftValue: String,
                              rightLabel: String, rightValue: String,
                              rightUnit: String, rightTint: Color,
                              done: Int, total: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.caption2.weight(.bold)).tracking(0.5)
                Spacer()
                Text(trailing).font(.caption2)
            }
            .foregroundStyle(Color.dim)

            HStack(spacing: 0) {
                stat(leftLabel, leftValue, "", Color.dim)
                divider
                stat(rightLabel, rightValue, rightUnit, rightTint)
            }
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(.accent4)
            }
        }
    }

    /// "34 weeks · to 21 Mar" — the span the block figure is measured over.
    private var blockRange: String {
        let weeks: String = "\(store.totalPlanWeeks) weeks"
        guard let race = store.raceDate else { return weeks }
        return weeks + " · to " + DayKey.short(race)
    }

    /// "27 Jul – 2 Aug". Dates rather than a week number, because the number is
    /// already in the header and the dates are what stop this being read as the
    /// block row above it.
    private var currentWeekRange: String {
        guard let start = points.last?.start,
              let end = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: 6, to: start) else { return "" }
        return DayKey.short(start) + " – " + DayKey.short(end)
    }

    private var planHeader: some View {
        let weekNo = store.week(containing: todayKey)?.weekNo
        let total = store.totalPlanWeeks
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(weekNo.map { "Week \($0) of \(total)" } ?? "Before week 1")
                    .font(.subheadline.weight(.bold))
                InfoButton(topic: .blockProgress)
                Spacer()
                if let d = store.daysToRace() {
                    Text("\(d) days to race")
                        .font(.caption).foregroundStyle(Color.dim)
                }
            }
            ProgressView(value: Double(weekNo ?? 0), total: Double(max(total, 1)))
                .tint(.accent4)
        }
    }

    /// Recorded volume since the plan began. Bike counts training rides only —
    /// commutes have their own tab, and the plan's bike sessions are rides.
    private var actualVolume: PlanStore.PlanVolume {
        var v = PlanStore.PlanVolume()
        for a in activities.activities where a.dayKey >= MatchRules.planStartDayKey {
            switch a.discipline {
            case .run:      v.runKm += a.km
            case .swim:     v.swimKm += a.km
            case .bike:     if a.isPlanEligible { v.bikeHours += Double(a.movingTime) / 3600 }
            case .strength: if a.isPlanEligible { v.strengthSessions += 1 }
            default:        break
            }
        }
        return v
    }

    private var volumeRows: [VolumeRow] {
        let done = actualVolume
        let due = store.plannedVolume(throughDay: todayKey)
        let all = store.plannedVolume()

        return [
            VolumeRow(id: "run", symbol: Discipline.run.symbol, name: "Run",
                      done: done.runKm, dueSoFar: due.runKm, total: all.runKm,
                      unit: "km", decimals: 0, colour: Discipline.run.tint,
                      approximate: !all.runExact),
            VolumeRow(id: "bike", symbol: Discipline.bike.symbol, name: "Bike",
                      done: done.bikeHours, dueSoFar: due.bikeHours, total: all.bikeHours,
                      unit: "h", decimals: 1, colour: Discipline.bike.tint,
                      approximate: false),
            VolumeRow(id: "swim", symbol: Discipline.swim.symbol, name: "Swim",
                      done: done.swimKm, dueSoFar: due.swimKm, total: all.swimKm,
                      unit: "km", decimals: 1, colour: Discipline.swim.tint,
                      approximate: false),
            VolumeRow(id: "strength", symbol: Discipline.strength.symbol, name: "Strength",
                      done: Double(done.strengthSessions),
                      dueSoFar: Double(due.strengthSessions),
                      total: Double(all.strengthSessions),
                      unit: "sessions", decimals: 0, colour: Discipline.strength.tint,
                      approximate: false)
        ]
    }

    private func volumeRow(_ r: VolumeRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: r.symbol)
                    .font(.caption).foregroundStyle(r.colour).frame(width: 18)
                Text(r.name).font(.caption.weight(.semibold)).foregroundStyle(Color.ink)
                Spacer(minLength: 4)
                Text(num(r.done, r.decimals))
                    .font(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(r.colour)
                Text("/ \(r.approximate ? "≈" : "")\(num(r.total, r.decimals)) \(r.unit)")
                    .font(.caption2).foregroundStyle(Color.dim)
            }
            ProgressView(value: min(r.done, r.total), total: max(r.total, 0.001))
                .tint(r.colour)
            Text(pacing(r)).font(.caption2).foregroundStyle(Color.dim)
        }
    }

    /// The actionable line: not "how much of the block", but "are you where the
    /// plan expects you to be today".
    private func pacing(_ r: VolumeRow) -> String {
        guard r.dueSoFar > 0.05 else {
            return "nothing due yet — the block total is \(num(r.total, r.decimals)) \(r.unit)"
        }
        let delta = r.done - r.dueSoFar
        let pct = r.total > 0 ? r.done / r.total * 100 : 0
        let share = String(format: "%.0f%% of the block", pct)
        if abs(delta) < max(r.dueSoFar * 0.05, r.decimals == 0 ? 0.5 : 0.1) {
            return "on plan · \(share)"
        }
        let word = delta > 0 ? "ahead of" : "behind"
        return "\(num(abs(delta), r.decimals)) \(r.unit) \(word) plan to date · \(share)"
    }

    private func num(_ v: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }

    // MARK: Volume
    //
    // Lives in VolumeCard.swift, on calendar weeks rather than plan weeks —
    // the reasoning is at the top of that file.

    // MARK: Long run — the marathon metric that matters most

    private var longRunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            chartTitle("LONGEST RUN", "km per week")

            Chart(points) { p in
                LineMark(x: .value("Week", p.weekNo),
                         y: .value("Longest", p.longestRunKm))
                    .foregroundStyle(Color.accent4)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Week", p.weekNo),
                          y: .value("Longest", p.longestRunKm))
                    .foregroundStyle(Color.accent4)
                    .symbolSize(40)
            }
            .chartYAxis { recessiveY() }
            .chartXAxis { recessiveX() }
            .frame(height: 130)

            if let peak = points.map(\.longestRunKm).max(), peak > 0 {
                // Read from the plan, not hard-coded. It builds to 34 km, not
                // the 32 this line used to claim.
                Text(String(format: "Peak so far %.1f km · plan builds to %.0f km",
                            peak, store.peakLongRunKm))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .cardStyle()
    }

    // MARK: Pace
    //
    // Lives in PaceCard.swift — the scale rule, the brick handling and the
    // expanded variant are documented at the top of that file.

    // MARK: Shoes
    //
    // Moved out of Settings. Wear is a training metric — the plan has over a
    // thousand kilometres of running in it and most road shoes are done
    // somewhere between 600 and 800. Buried in a settings screen you would
    // never notice the crossing.

    @ViewBuilder
    private var shoesCard: some View {
        let shoes = athlete.activeShoes
        if !shoes.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 2) {
                    Text("SHOES").font(.caption2.weight(.bold)).tracking(0.5)
                    InfoButton(topic: .shoes)
                    Spacer()
                    Text("lifetime distance").font(.caption2)
                }
                .foregroundStyle(Color.dim)

                ForEach(shoes) { shoe in
                    shoeRow(shoe)
                }
                // A LEGEND, not advice. "Replacing before the long runs get long
                // is cheaper than the alternative" was a recommendation printed
                // under a chart; it is now the ⓘ entry that explains the range.
                // What stays is the key to two colours that would otherwise be
                // colour alone on the bars.
                if shoes.contains(where: \.needsAttention) {
                    Text(shoeLegend)
                        .font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cardStyle()
        }
    }

    /// Assembled outside the view builder — the rule from VolumeCard.
    private var shoeLegend: String {
        let a: String = "\(Int(AthleteStore.Shoe.attentionKm))"
        let b: String = "\(Int(AthleteStore.Shoe.spentKm))"
        return "Amber past " + a + " km · red past " + b + " km."
    }

    private static func shoeTint(_ w: AthleteStore.Shoe.Wear) -> Color {
        switch w {
        case .fine:  Color.dim
        case .worn:  Color.slowerColor
        case .spent: Color.spentColor
        }
    }

    /// "worn" at 600, "replace" at 800. The word carries the state as well as
    /// the colour does — the rule this project follows everywhere a hue means
    /// something.
    private static func shoeWord(_ w: AthleteStore.Shoe.Wear) -> String? {
        switch w {
        case .fine:  nil
        case .worn:  "worn"
        case .spent: "replace"
        }
    }

    private func shoeRow(_ shoe: AthleteStore.Shoe) -> some View {
        let tint = Self.shoeTint(shoe.wear)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(shoe.name).font(.caption).foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let word = Self.shoeWord(shoe.wear) {
                    Text(word).font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 4)
                Text("\(Int(shoe.km)) km")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(tint)
            }
            // TrackBar, not ProgressView — wear is a magnitude against a
            // budget, not a completion count, and the tint IS the state here,
            // which is exactly the job TrackBar was extracted for.
            TrackBar(fraction: shoe.wearFraction, tint: tint)
        }
    }

    // MARK: Zones

    private var zoneWindow: ZoneWindow {
        ZoneWindow(rawValue: zoneWindowRaw) ?? .days90
    }

    /// Two words in a capsule, the same control the volume card's h/km toggle
    /// uses. Not a `Picker`: a segmented picker at this size is taller than the
    /// header row it has to live in.
    private var zoneWindowToggle: some View {
        HStack(spacing: 0) {
            ForEach(ZoneWindow.allCases) { w in
                let on = w == zoneWindow
                Button { zoneWindowRaw = w.rawValue } label: {
                    Text(w.short)
                        .font(.system(size: 10, weight: on ? .bold : .regular))
                        .foregroundStyle(on ? Color.ink : Color.dim)
                        .frame(width: 32, height: 17)
                        .background(Capsule().fill(Color.ink.opacity(on ? 0.13 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1.5)
        .overlay(Capsule().stroke(Color.line, lineWidth: 1))
    }

    private var zoneCard: some View {
        // Computed ONCE and captured. The sum walks every scored session in the
        // window, and reading it from inside the chart's mark closure would run
        // it again per bar — six full passes to draw five rectangles.
        let zones = athlete.hrZones
        let totals = ZoneTotals.build(days: load.days, zones: zones, window: zoneWindow)
        let shares = totals.shareLabels(zones)
        let ceiling = totals.axisCeiling
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                Text("TIME IN ZONE").font(.caption2.weight(.bold)).tracking(0.5)
                InfoButton(topic: .zones)
                Spacer()
                zoneWindowToggle
            }
            .foregroundStyle(Color.dim)

            if totals.isEmpty {
                Text(zoneEmptyLine(totals))
                    .font(.caption).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // NAME ON THE AXIS, RANGE IN THE FOOTER
                // -------------------------------------
                // The bpm range used to sit on the axis label so the zones did
                // not need a reference list elsewhere. That was right until the
                // name went there too: "Z4  Threshold  150–160" is long enough
                // to eat a third of the card, and because the labels differ in
                // width the plot area shrinks to whatever the longest one
                // leaves — so the bars get a shorter track than they need and a
                // different one than the eye expects.
                //
                // The name is what you read the chart with; the range is a
                // reference you consult once. So the name goes on the axis, the
                // five ranges go on one line underneath, and every bar gets the
                // same, longer track.
                // ONE FIGURE PER ROW
                // ------------------
                // The label carries the share and nothing else does. The bar
                // used to end with the raw figure, which put the same quantity
                // on the row twice in two units — and the bar itself already
                // shows it, as its length.
                Chart(zones) { z in
                    BarMark(x: .value("Hours", totals.hours(z.index)),
                            y: .value("Zone", shares[z.index] ?? z.titled))
                        .foregroundStyle(z.color)
                        .cornerRadius(4)
                }
                // No trailing label to make room for any more, so the longest
                // bar can now run the full width.
                .chartXScale(domain: 0...ceiling)
                // NO X AXIS. Every bar now carries its own figure, so an axis
                // would be a second copy of the same five numbers — and the
                // gridlines would be crossing labels to say it.
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
                    }
                }
                .frame(height: CGFloat(zones.count) * 26 + 20)

                // Data, not explanation: what is in the bars, then what is out
                // of them and which disciplines it was. Why a discipline cannot
                // be traced is in the info sheet; WHICH ones were not is a
                // reading, and belongs here — an untraced run is a fault, an
                // untraced ride without heart rate is a known limit.
                //
                // Two lines, one block. They are halves of the same statement —
                // what is in, what is out — and at the stack's spacing of 10
                // they read as two unrelated footnotes.
                VStack(alignment: .leading, spacing: 2) {
                    Text(totals.footnote)
                    if let missing = totals.untracedLine {
                        Text(missing)
                    }
                }
                .font(.system(size: 9.5)).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)

                // The bpm bounds used to be a third line here. They are a
                // reference you consult once and then never again — the bars
                // carry the zone NAMES, which is what you read the chart with —
                // so they moved into the info sheet as bands. See `.zones`.
            }
        }
        .cardStyle()
        // This card reads the scored series rather than the activity list, so
        // the series has to exist. Cheap — a string comparison when it is
        // already current.
        .task { load.recomputeIfNeeded() }
    }

    /// Shown when the window holds no measured seconds. It has to distinguish
    /// "nothing recorded" from "nothing traced" — those look identical on an
    /// empty card and mean entirely different things.
    private func zoneEmptyLine(_ t: ZoneTotals) -> String {
        if t.untraced > 0 {
            let n: String = "\(t.untraced) session" + (t.untraced == 1 ? "" : "s")
            return "No traced sessions in the " + zoneWindow.label + " — "
                 + n + " were scored from an average only."
        }
        return "No sessions with heart-rate data in the " + zoneWindow.label + "."
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title).foregroundStyle(Color.dim)
            Text("Nothing to plot yet").font(.headline)
            Text("Charts appear as the weeks accumulate — volume from week one, "
                 + "trends from week two.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .cardStyle()
    }

    // MARK: Chart furniture

    private func chartTitle(_ title: String, _ sub: String) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).tracking(0.5)
            Spacer()
            Text(sub).font(.caption2)
        }
        .foregroundStyle(Color.dim)
    }

    // Functions returning `some AxisContent`, not properties typed as the bare
    // protocol — AxisContent has associated types and can't be used as an
    // existential here.
    private func recessiveY() -> some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
            AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
        }
    }

    private func recessiveX() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
            AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(width: 1, height: 26)
    }

    private func stat(_ label: String, _ value: String,
                      _ unit: String, _ colour: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.bold)).foregroundStyle(colour)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(Color.dim) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
