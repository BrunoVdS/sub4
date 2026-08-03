//
//  PlanView.swift
//  Sub4
//
//  The whole block, top to bottom. Tap any week for its seven days.
//
//  Completion is only computed for weeks that have started. A future week
//  showing "0/8" would read as failure rather than as "hasn't happened yet",
//  and it would also make the list do pointless work while scrolling.
//

import SwiftUI

struct PlanView: View {

    private let store = PlanStore.shared
    @State private var matcher = Matcher.shared
    @State private var activities = ActivityStore.shared

    private var todayKey: String { DayKey.key() }

    private var currentWeekNo: Int? {
        store.week(containing: todayKey)?.weekNo
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    overview
                    // The shape of the block, above the 34 rows that make it
                    // up — the question "is the load going where it should?"
                    // is not answerable from a list.
                    PlanVolumeChart()
                    fuelLink
                    ForEach(store.planWeeks) { week in
                        NavigationLink {
                            PlanWeekDetail(week: week)
                        } label: {
                            WeekRow(week: week,
                                    isCurrent: week.weekNo == currentWeekNo,
                                    started: hasStarted(week))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.bg)
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(.accent4)
    }

    // MARK: Fuelling
    //
    // On Plan rather than Settings: fuelling is part of the plan, not a
    // preference. Sections 09 and 10 of the source document are as much the
    // plan as the 34 weeks below them.

    // A NavigationLink, not a sheet. The gear used to attach a
    // `.sheet` to this view, and stacking a second one is the exact pattern
    // that stopped Today's sheets presenting. Plan is inside a NavigationStack
    // and every week row is already a link, so this is also the more consistent
    // gesture.
    private var fuelLink: some View {
        NavigationLink { FuelView(embedded: true) } label: {
            HStack(spacing: 11) {
                Image(systemName: "bolt.fill")
                    .font(.title3).foregroundStyle(Color.accent4).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fuelling & race day")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text("Products, per-session targets, the long-run ladder "
                         + "and the race-day schema")
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
    }

    private func hasStarted(_ w: Week) -> Bool {
        guard let start = w.startDate else { return false }
        return start <= todayKey
    }

    // MARK: Overview

    private var overview: some View {
        let done = store.planWeeks.filter { hasStarted($0) }.count
        let total = store.totalPlanWeeks
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.plan.meta.plan).font(.headline)
                    Text("\(store.plan.meta.targetTime) · \(store.targetPace)")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                Spacer()
                if let d = store.daysToRace() {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(d)").font(.title3.weight(.bold))
                            .foregroundStyle(Color.accent4)
                        Text("days").font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }

            VStack(spacing: 5) {
                HStack {
                    Text("Week \(min(done, total)) of \(total)")
                        .font(.caption).foregroundStyle(Color.dim)
                    Spacer()
                    Text(String(format: "%.0f%%",
                                total > 0 ? Double(done) / Double(total) * 100 : 0))
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Color.dim)
                }
                ProgressView(value: Double(min(done, total)), total: Double(total))
                    .tint(.accent4)
            }
        }
        .cardStyle()
    }
}

// MARK: - Row

struct WeekRow: View {
    let week: Week
    let isCurrent: Bool
    let started: Bool

    @State private var matcher = Matcher.shared
    private let store = PlanStore.shared

    private var dayKeys: [String] {
        guard let start = week.startDate, let d = DayKey.date(start) else { return [] }
        return (0..<7).compactMap {
            Calendar(identifier: .iso8601).date(byAdding: .day, value: $0, to: d)
                .map(DayKey.key)
        }
    }

    /// Only walked for weeks that have started — see the note at the top.
    private var progress: (done: Int, total: Int)? {
        guard started else { return nil }
        var done = 0, total = 0
        for key in dayKeys {
            for m in matcher.day(key).matches where !m.session.isRest {
                total += 1
                if m.isDone { done += 1 }
            }
        }
        return total > 0 ? (done, total) : nil
    }

    private var kind: WeekKind? { week.weekKind }

    var body: some View {
        HStack(spacing: 12) {
            // A coloured bar on the hard weeks only. Four of thirty-four, so it
            // reads as an exception rather than decoration.
            RoundedRectangle(cornerRadius: 2)
                .fill(kind?.isHard == true ? (kind?.tint ?? .clear) : .clear)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            number
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(week.dateRange ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    badgeChip
                    Spacer(minLength: 0)
                }
                if let tag = week.tag, !tag.isEmpty {
                    Text(tag).font(.caption).foregroundStyle(Color.dim)
                        .lineLimit(1)
                }
                footprint
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(Color.dim.opacity(0.5))
        }
        .fixedSize(horizontal: false, vertical: true)
        // Recovery weeks recede rather than the hard weeks merely brightening.
        // Sixteen of the 34 are cutbacks; at full weight the list still reads
        // as uniform. The current week is never dimmed — you need to find it.
        .opacity(isCurrent ? 1 : (kind?.rowOpacity ?? 1))
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderTint, lineWidth: isCurrent ? 1.5 : 1)
        )
    }

    /// The current week still wins — it is the one you are looking for. A hard
    /// week gets a faint edge so it is findable while scrolling.
    private var borderTint: Color {
        if isCurrent { return Color.accent4.opacity(0.55) }
        if kind?.isHard == true { return (kind?.tint ?? .clear).opacity(0.35) }
        return .clear
    }

    /// The plan's own badge text, in the plan's own weighting: filled for the
    /// hard weeks, outlined for recovery and the logged prologue.
    @ViewBuilder
    private var badgeChip: some View {
        if let k = kind, let text = week.badge, !text.isEmpty {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(k.isFilled ? k.tint : Color.clear)
                .foregroundStyle(k.onTint)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(k.isFilled ? .clear : Color.line, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .fixedSize()
        }
    }

    private var number: some View {
        VStack(spacing: 1) {
            Text(week.label)
                .font(.headline.weight(.bold)).monospacedDigit()
                .foregroundStyle(isCurrent ? Color.accent4 : Color.dim)
            Text("wk").font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
        }
        .frame(width: 34)
    }

    @ViewBuilder
    private var footprint: some View {
        HStack(spacing: 8) {
            // Running kilometres, summed from the sessions. The week's own
            // "~275 km" is total multisport including the commute — putting a
            // running icon next to it was simply mislabelling it.
            let run = store.plannedRunKm(week: week)
            if run.km > 0 {
                Text(String(format: "%@%.0f km run", run.exact ? "" : "≈", run.km))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.dim)
            }
            if let h = week.stats["h"], h > 0 {
                Text("\(Int(h)) h").font(.caption2).foregroundStyle(Color.dim)
            }
            if let p = progress {
                Text("· \(p.done)/\(p.total)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(p.done == p.total ? Color.accent4 : Color.dim)
            }
        }
    }
}

// MARK: - Week detail

struct PlanWeekDetail: View {
    let week: Week

    @State private var detail: Session?

    private var dayKeys: [String] {
        guard let start = week.startDate, let d = DayKey.date(start) else { return [] }
        return (0..<7).compactMap {
            Calendar(identifier: .iso8601).date(byAdding: .day, value: $0, to: d)
                .map(DayKey.key)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                ForEach(dayKeys, id: \.self) { DayRow(dayKey: $0, onOpen: { detail = $0 }) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.bg)
        .navigationTitle(week.display)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { SessionDetailView(session: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(week.dateRange ?? "").font(.headline)
            if let tag = week.tag, !tag.isEmpty {
                Text(tag).font(.subheadline).foregroundStyle(Color.dim)
            }
            if !orderedStats.isEmpty {
                HStack(spacing: 10) {
                    ForEach(orderedStats, id: \.0) { k, v in
                        Text("\(fmt(v)) \(label(for: k))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.dim)
                    }
                }
                .padding(.top, 2)

                // The plan's own headline volume counts riding, swimming and the
                // daily commute. Spelling that out here stops "275 km" being
                // read as running.
                let run = PlanStore.shared.plannedRunKm(week: week)
                if run.km > 0 {
                    Text(String(format: "of which %@%.0f km is running",
                                run.exact ? "" : "about ", run.km))
                        .font(.caption).foregroundStyle(Color.accent4)
                        .padding(.top, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// km and h lead; everything else follows alphabetically. The plan's own
    /// keys aren't consistent — some weeks say "ride", others "rides", and race
    /// week says "shakeouts" — so nothing is hard-coded or it gets dropped.
    private var orderedStats: [(String, Double)] {
        let lead = ["km", "h"]
        let first = lead.compactMap { k -> (String, Double)? in
            guard let v = week.stats[k], v > 0 else { return nil }
            return (k, v)
        }
        let rest = week.stats
            .filter { !lead.contains($0.key) && $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
        return first + rest
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func label(for key: String) -> String {
        key == "km" ? "km all sports" : key
    }
}
