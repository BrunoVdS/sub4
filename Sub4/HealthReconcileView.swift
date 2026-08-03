//
//  HealthReconcileView.swift
//  Sub4
//
//  What Apple Health has, what Strava has, and where they disagree.
//
//  WHAT THIS IS FOR
//  ----------------
//  Everything in this app is currently read from Strava, and Strava's timing
//  fields are derived rather than measured. Before moving anything onto Health
//  there is a question that no amount of API reading answers: does Health
//  actually HAVE the sessions? A ride recorded on a bike head unit reaches
//  Strava having never touched the watch, and if that is most of the long
//  rides then Health is an enrichment layer and not a replacement.
//
//  So this screen is deliberately a diagnostic and not a feature. It answers
//  three counts — in both, Health only, Strava only — and then shows the
//  per-session disagreement in time, which is where the swim defect lives.
//
//  IT CHANGES NOTHING
//  ------------------
//  No figure on any other screen moves because of this view. It reads, joins,
//  and reports. What it finds decides what gets built next; that is the whole
//  contract.
//
//  READING IT
//  ----------
//  · "In both" with a small time delta — the join works and the sources agree.
//  · "Strava only" on long rides — a head unit. Health cannot replace Strava.
//  · "Health only" — sessions Strava never received; the app is currently blind
//    to them.
//  · A swim with "samples" — the length-by-length data exists and the correct
//    active time is computable. A swim without it falls back to the duration
//    field, which is the number Strava also gets wrong.
//

import SwiftUI

struct HealthReconcileView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var health = HealthStore.shared
    @State private var activities = ActivityStore.shared

    @State private var rows: [ReconcileRow] = []
    @State private var totals = HealthReconcile.Totals()
    @State private var loading = false
    @State private var ran = false
    @State private var onlyAnomalies = false

    /// The list is a diagnostic, not a log. Every row is counted; only the most
    /// recent are drawn, because the ingest window is now thirteen months and
    /// several hundred rows, and scrolling past them proves nothing the counts
    /// have not already said.
    private let listLimit = 80

    private var cutoff: String { MatchRules.cutoffDayKey }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if ran { countsSection }
                if ran && !rows.isEmpty { swimSection; rowsSection }
            }
            .navigationTitle("Health vs Strava")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await run() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent("Health access",
                           value: health.isAuthorized ? "granted" : "not granted")
            LabeledContent("Window", value: "\(cutoff) → today")
            if loading {
                HStack { ProgressView(); Text("Reading Health…").foregroundStyle(.secondary) }
            } else {
                Button("Run again") { Task { await run(force: true) } }
                    .disabled(!health.isAuthorized)
            }
            if let e = health.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Read-only. Nothing on any other screen changes because of this "
                 + "screen — it exists to decide what is worth building next.")
        }
    }

    @ViewBuilder
    private var countsSection: some View {
        Section("Counts") {
            countRow("In both", totals.both, .green,
                     "Joined on the same day, same sport, within "
                     + "\(HealthReconcile.toleranceMinutes) minutes.")
            countRow("Strava only", totals.stravaOnly, .orange,
                     totals.stravaOnly == 0
                     ? "Everything Strava has, Health has too."
                     : "Recorded somewhere that is not the watch — a bike head "
                       + "unit, or a manual entry. Health cannot replace Strava "
                       + "for these.")
            countRow("Health only", totals.healthOnly, .orange,
                     totals.healthOnly == 0
                     ? "Nothing the app is currently blind to."
                     : "Sessions Strava never received. The app does not see "
                       + "these at all today.")
            countRow("Duration outside band", totals.disputed, .orange,
                     "Matched pairs where Health's duration falls outside "
                     + "Strava's moving–elapsed range by more than a minute. "
                     + "Health's figure is recorded time minus whatever the "
                     + "recorder paused, so it lands on moving time for runs "
                     + "and elapsed for rides — anywhere between the two is "
                     + "agreement, not a fault.")
            countRow("Swim time disagrees", totals.swimsDisputed, .orange,
                     "Matched swims where the length samples and Strava's "
                     + "moving time differ by more than a minute. This one "
                     + "SHOULD be large: it is the defect being measured.")
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent("Sessions with duplicates") {
                    Text("\(totals.sessionsMerged) · \(totals.recordsAbsorbed) records absorbed")
                        .monospacedDigit()
                }
                Text("Your watch records a session, the Strava app writes a copy "
                     + "back into Health, and Connect writes a third. Counted "
                     + "over the sessions on this screen, not the whole Health "
                     + "store — the store is mostly walks and commutes, which "
                     + "only ever have one writer, so a store-wide ratio made "
                     + "the merge look like it had barely run.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if health.lastRawWorkoutCount > 0 {
                    Text("Whole store: \(health.lastRawWorkoutCount) records → "
                         + "\(health.cachedWorkouts.count) sessions.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func countRow(_ title: String, _ n: Int,
                          _ tint: Color, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                Text("\(n)").font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(n > 0 ? tint : Color.secondary)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The reason this screen was built. Everything above is context.
    @ViewBuilder
    private var swimSection: some View {
        let swims = rows.filter { $0.sport == .swim && $0.health != nil }
        if !swims.isEmpty {
            Section {
                ForEach(swims) { r in swimRow(r) }
            } header: {
                Text("Swims · \(totals.swimsWithSamples) of \(swims.count) have "
                     + "length samples")
            } footer: {
                Text("\"Samples\" is the sum of the distanceSwimming intervals — "
                     + "resting at the wall produces no sample, so it cannot "
                     + "count rest and cannot drop swimming that happened. "
                     + "Where it differs from Strava, Strava is the one that is "
                     + "wrong.")
            }
        }
    }

    private func swimRow(_ r: ReconcileRow) -> some View {
        let h = r.health
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(DayKey.short(r.date)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f m", h?.distanceM ?? 0))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 14) {
                pace("samples", h?.activeSeconds, h?.distanceM)
                pace("duration", h?.durationSeconds, h?.distanceM)
                pace("Strava", r.strava?.movingTime, (r.strava?.km ?? 0) * 1000)
            }
            if h?.activeSeconds == nil {
                Text("no length samples — falling back to the duration field")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func pace(_ label: String, _ seconds: Int?, _ metres: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(paceLabel(seconds, metres))
                .font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    private func paceLabel(_ seconds: Int?, _ metres: Double?) -> String {
        guard let seconds, let metres, metres > 50, seconds > 0 else { return "—" }
        let per100 = Double(seconds) / (metres / 100)
        return String(format: "%d:%02d", Int(per100) / 60, Int(per100) % 60)
    }

    /// ANOMALIES ARE NEVER TRIMMED.
    ///
    /// The first version capped the list at 80 newest rows and applied that cap
    /// to everything. With 128 rows and 5 of them Health-only, four of the five
    /// fell below the cut — the counts said 5, the list showed 1, and there was
    /// no way to reach the rest. The trim existed to stop a seven-month list of
    /// matched sessions being scrolled past pointlessly, and it ended up hiding
    /// the only rows anyone opens this screen to read.
    ///
    /// So every row that is NOT "both" is always drawn, and the cap applies to
    /// the matched ones only.
    private var listedRows: [ReconcileRow] {
        let shown = onlyAnomalies ? [] : rows.filter(\.inBoth)
        let anomalies = rows.filter { !$0.inBoth }
        let room = Swift.max(0, listLimit - anomalies.count)
        return (anomalies + shown.prefix(room)).sorted { $0.date > $1.date }
    }

    private var trimmedCount: Int {
        onlyAnomalies ? 0 : Swift.max(0, rows.count - listedRows.count)
    }

    private var rowsSection: some View {
        Section {
            Toggle("Only Health-only and Strava-only", isOn: $onlyAnomalies)
                .font(.subheadline)
            ForEach(listedRows) { r in row(r) }
        } header: {
            Text("Sessions · \(listedRows.count) of \(rows.count)")
        } footer: {
            if trimmedCount > 0 {
                Text("\(trimmedCount) matched sessions are not listed — the cap "
                     + "applies to those only. Every Health-only and Strava-only "
                     + "row is always shown, however far back it is.")
            }
        }
    }

    private func row(_ r: ReconcileRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.sport?.symbol ?? "questionmark")
                .font(.caption).frame(width: 18)
                .foregroundStyle(r.sport?.tint ?? Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(r)).font(.subheadline).lineLimit(1)
                Text(detail(r)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(badge(r)).font(.caption2.weight(.semibold))
                .foregroundStyle(r.inBoth ? Color.secondary : Color.orange)
        }
    }

    private func title(_ r: ReconcileRow) -> String {
        r.strava?.name ?? r.health?.rawType ?? "—"
    }

    private func detail(_ r: ReconcileRow) -> String {
        var parts = [DayKey.short(r.date)]
        if let h = r.health {
            parts.append("Health \(Fmt.duration(h.durationSeconds))")
            if let a = h.activeSeconds {
                parts.append("active \(Fmt.duration(a))")
            }
            if h.km > 0 { parts.append(String(format: "%.1f km", h.km)) }
            parts.append(h.mergedCount > 1
                         ? "\(h.sourceLabel) (\(h.mergedCount))"
                         : h.sourceLabel)
        }
        if let band = r.stravaBand {
            // The BAND, not one figure. Health's duration corresponds to
            // neither of Strava's numbers reliably — see
            // ReconcileRow.durationOutsideBand — so showing one invited a
            // comparison that was wrong twice in two different directions.
            parts.append("Strava \(band)")
        }
        if let d = r.durationOutsideBand, abs(d) > 60 {
            parts.append("outside by \(d > 0 ? "+" : "\u{2212}")\(Fmt.duration(abs(d)))")
        }
        return parts.joined(separator: " · ")
    }

    private func badge(_ r: ReconcileRow) -> String {
        if r.inBoth { return "both" }
        return r.healthOnly ? "Health only" : "Strava only"
    }

    // MARK: Work

    private func run(force: Bool = false) async {
        guard !loading, force || !ran else { return }
        guard health.isAuthorized else { ran = true; return }
        loading = true
        defer { loading = false; ran = true }

        let start = DayKey.date(cutoff) ?? Date()
        let workouts = await health.workouts(from: start, to: Date())
        let built = HealthReconcile.build(health: workouts,
                                          activities: activities.activities,
                                          since: cutoff)
        rows = built
        totals = HealthReconcile.totals(built)
    }
}
