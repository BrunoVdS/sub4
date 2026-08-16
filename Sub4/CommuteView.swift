//
//  CommuteView.swift
//  Sub4
//
//  Commute tracking, kept inside the app rather than using Strava's own commute
//  flag — flagged rides drop off the heatmap, which isn't a trade worth making.
//
//  A commute here is any ride below the training threshold (MatchRules.minRideKm).
//  That's the same test that keeps commutes from being mistaken for planned
//  sessions, so the two views can never disagree.
//
//  This used to be its own tab. It lives on Progress now: commuting is a trend
//  you review, not a thing you act on daily, which is the same question the rest
//  of that tab answers. The card carries the totals and the trend; the recent
//  rides are one tap deeper so Progress stays scannable.
//

import SwiftUI
import Charts

// MARK: - Shared maths
//
// One source for the card and the detail, so the two can't drift apart.

struct CommuteSummary {

    struct WeekBucket: Identifiable {
        let start: Date
        var km: Double
        /// SECONDS since 375, for `TabSummary.WeekActuals`'s reason — this
        /// held minutes and was fed `a.minutes`. §12.119.
        var movingSeconds: Int
        var count: Int
        var id: Date { start }

        var minutes: Int { movingSeconds / 60 }
    }

    let commutes: [Activity]
    let weekly: [WeekBucket]

    init(_ all: [Activity], weeks: Int = 12) {
        commutes = all
            .filter { $0.discipline == .bike && !$0.isPlanEligible }
            .sorted { $0.startLocal > $1.startLocal }

        // Last 12 weeks, oldest first, empty weeks included so gaps are visible.
        let cal = Calendar(identifier: .iso8601)
        let thisMonday = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        var buckets: [Date: WeekBucket] = [:]
        for offset in stride(from: -(weeks - 1), through: 0, by: 1) {
            if let d = cal.date(byAdding: .weekOfYear, value: offset, to: thisMonday) {
                buckets[d] = WeekBucket(start: d, km: 0,
                                        movingSeconds: 0, count: 0)
            }
        }
        for a in commutes {
            guard let d = DayKey.date(a.dayKey),
                  let monday = cal.dateInterval(of: .weekOfYear, for: d)?.start,
                  buckets[monday] != nil else { continue }
            buckets[monday]?.km += a.km
            buckets[monday]?.movingSeconds += a.movingTime
            buckets[monday]?.count += 1
        }
        weekly = buckets.values.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { commutes.isEmpty }
    var thisWeek: WeekBucket? { weekly.last }

    var thisMonth: (km: Double, count: Int) {
        let prefix = String(DayKey.key().prefix(7))          // "2026-07"
        let m = commutes.filter { $0.dayKey.hasPrefix(prefix) }
        return (m.reduce(0) { $0 + $1.km }, m.count)
    }

    /// **SECONDS IN THE TUPLE — patch 375, §12.119.**
    ///
    /// It carried minutes, summed from truncated minutes, and the card then
    /// divided that by 60 again for hours. Two truncations over hundreds of
    /// rides: the displayed hour count could be a full hour low.
    ///
    /// The label changed rather than staying `minutes`, because the one reader
    /// wants HOURS and should divide the seconds itself rather than divide a
    /// figure that has already been rounded once.
    var allTime: (km: Double, count: Int, movingSeconds: Int) {
        (commutes.reduce(0) { $0 + $1.km },
         commutes.count,
         commutes.movingSeconds)
    }
}

// MARK: - The card on Progress

struct CommuteCard: View {

    @State private var activities = ActivityStore.shared
    @State private var selectedWeek: Date?

    private var s: CommuteSummary { CommuteSummary(activities.activities) }

    var body: some View {
        let summary = s
        VStack(alignment: .leading, spacing: 10) {
            header
            if summary.isEmpty {
                Text("Rides under \(Int(MatchRules.minRideKm)) km count as commutes.")
                    .font(.caption).foregroundStyle(Color.dim)
            } else {
                totals(summary)
                // The chart expands; the header navigates. Previously the whole
                // card was one NavigationLink, which swallowed every tap the
                // chart might have wanted.
                ExpandableCard(title: "Commute") {
                    CommuteChart(weekly: summary.weekly, selected: $selectedWeek,
                                 interactive: false)
                        .frame(height: 96)
                } expanded: {
                    CommuteExpanded()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// The row is the link to the full view. The words already said so.
    private var header: some View {
        NavigationLink { CommuteView() } label: {
            HStack {
                Label("COMMUTE", systemImage: "bicycle")
                    .font(.caption2.weight(.bold)).tracking(0.5)
                Spacer()
                Text("last 12 weeks").font(.caption2)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(Color.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func totals(_ s: CommuteSummary) -> some View {
        HStack(spacing: 0) {
            stat("This week", String(format: "%.0f", s.thisWeek?.km ?? 0), "km", .accent4)
            divider
            stat("This month", String(format: "%.0f", s.thisMonth.km), "km", .dim)
            divider
            stat("Total", String(format: "%.0f", s.allTime.km), "km", .dim)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(width: 1, height: 24)
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

// MARK: - The chart, shared by both

struct CommuteChart: View {
    let weekly: [CommuteSummary.WeekBucket]
    @Binding var selected: Date?

    /// Whether this copy handles taps.
    ///
    /// On the Progress card it does NOT: `chartXSelection` installs a gesture on
    /// the plot area, and an inner gesture beats an outer one — so the card's
    /// "tap to expand" only worked on the few points of padding around the
    /// bars. The card shows no selection anywhere, so it was spending the
    /// gesture on nothing.
    var interactive = true

    /// The cursor resolved to a bar.
    ///
    /// `chartXSelection` hands back the RAW date under the finger, not one
    /// snapped to the bin. Comparing that to a bucket's midnight-on-Monday
    /// start matches with probability zero — which meant that the moment
    /// anything was selected, every bar dimmed to 0.35 and none was
    /// highlighted, and the rule mark was never drawn at all.
    private var selectedStart: Date? {
        guard let selected else { return nil }
        return weekly.first {
            Calendar(identifier: .iso8601)
                .isDate($0.start, equalTo: selected, toGranularity: .weekOfYear)
        }?.start
    }

    var body: some View {
        if interactive {
            base.chartXSelection(value: $selected)
        } else {
            base
        }
    }

    private var base: some View {
        Chart(weekly) { w in
            BarMark(x: .value("Week", w.start, unit: .weekOfYear),
                    y: .value("Distance", w.km),
                    width: .fixed(12))
                .foregroundStyle(Color.accent4.opacity(
                    selectedStart == nil || selectedStart == w.start ? 1 : 0.35))
                .cornerRadius(4)                       // rounded data-end only

            if let selectedStart, selectedStart == w.start {
                RuleMark(x: .value("Week", w.start, unit: .weekOfYear))
                    .foregroundStyle(Color.line)
                    .zIndex(-1)
            }
        }
        // Floored at 10 km: an all-zero window would otherwise get a 0…1 domain
        // and three axis labels reading 0, 0, 1.
        .chartYScale(domain: ChartScale.domain(weekly.map(\.km), minimum: 10))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
    }
}

// MARK: - The detail, pushed from Progress
//
// No NavigationStack of its own — it's pushed into the one Progress owns.

struct CommuteView: View {

    @State private var activities = ActivityStore.shared
    @State private var selectedWeek: Date?

    private var s: CommuteSummary { CommuteSummary(activities.activities) }

    var body: some View {
        let summary = s
        ScrollView {
            VStack(spacing: 10) {
                if summary.isEmpty { empty } else {
                    totals(summary)
                    chartCard(summary)
                    recentCard(summary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.bg)
        .navigationTitle("Commute")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await activities.sync() }
    }

    // MARK: Totals

    private func totals(_ s: CommuteSummary) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                stat("This week", String(format: "%.0f", s.thisWeek?.km ?? 0), "km", .accent4)
                divider
                stat("This month", String(format: "%.0f", s.thisMonth.km), "km", .dim)
                divider
                stat("Total", String(format: "%.0f", s.allTime.km), "km", .dim)
            }
            HStack(spacing: 0) {
                stat("Rides", "\(s.allTime.count)", "", .dim)
                divider
                // ONE DIVISION FROM SECONDS — patch 375. This read
                // `allTime.minutes / 60`, which is a truncated sum truncated
                // again.
                stat("Time", "\(s.allTime.movingSeconds / 3600)", "h", .dim)
                divider
                stat("Average",
                     String(format: "%.1f", s.allTime.count > 0
                            ? s.allTime.km / Double(s.allTime.count) : 0), "km", .dim)
            }
        }
        .cardStyle()
    }

    // MARK: Chart

    private func chartCard(_ s: CommuteSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WEEKLY DISTANCE")
                    .font(.caption2.weight(.bold)).tracking(0.5)
                Spacer()
                Text(selectionLabel(s)).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.dim)

            CommuteChart(weekly: s.weekly, selected: $selectedWeek)
                .frame(height: 140)
        }
        .cardStyle()
    }

    /// Only the selected bar gets a number — never a label on every mark.
    private func selectionLabel(_ s: CommuteSummary) -> String {
        guard let sel = selectedWeek,
              let w = s.weekly.first(where: {
                  Calendar(identifier: .iso8601).isDate($0.start, equalTo: sel,
                                                        toGranularity: .weekOfYear)
              })
        else { return "last 12 weeks" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return String(format: "%@ · %.1f km · %d rides",
                      f.string(from: w.start), w.km, w.count)
    }

    // MARK: Recent

    private func recentCard(_ s: CommuteSummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("RECENT")
                .font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(Color.dim)

            ForEach(s.commutes.prefix(12)) { a in
                HStack(spacing: 9) {
                    Image(systemName: "bicycle")
                        .font(.caption).foregroundStyle(Color.dim).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.subheadline).lineLimit(1)
                        Text(prettyDay(a.dayKey))
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.1f km", a.km))
                            .font(.caption.weight(.semibold))
                        Text("\(a.minutes) min").font(.caption2)
                    }
                    .foregroundStyle(Color.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func prettyDay(_ key: String) -> String {
        guard let d = DayKey.date(key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bicycle").font(.title).foregroundStyle(Color.dim)
            Text("No commutes yet").font(.headline)
            Text("Rides under \(Int(MatchRules.minRideKm)) km count as commutes.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .cardStyle()
    }

    // MARK: Bits

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

// MARK: - A year of commuting, full screen
//
// The card shows a quarter because that is what fits in 96 points of height.
// With the screen turned there is room for the seasonal shape — the winter dip,
// the spring return — which is the only thing a commute chart has to say that a
// single number does not.

struct CommuteExpanded: View {

    @State private var activities = ActivityStore.shared
    @State private var selected: Date?

    private var summary: CommuteSummary {
        CommuteSummary(activities.activities, weeks: 52)
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                stat("This week", String(format: "%.0f km", s.thisWeek?.km ?? 0))
                stat("This month", String(format: "%.0f km", s.thisMonth.km))
                stat("All time", String(format: "%.0f km", s.allTime.km))
                if let w = selected,
                   let b = s.weekly.first(where: {
                       Calendar(identifier: .iso8601)
                           .isDate($0.start, equalTo: w, toGranularity: .weekOfYear)
                   }) {
                    stat(DayKey.pretty(b.start),
                         String(format: "%.0f km · %d rides", b.km, b.count))
                }
                Spacer()
            }
            CommuteChart(weekly: s.weekly, selected: $selected)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(Color.dim)
            Text(value).font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.accent4)
        }
    }
}
