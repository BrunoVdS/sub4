//
//  LoadDiagnosticView.swift
//  Sub4
//
//  The raw layer, before anything is drawn on top of it.
//
//  The rule this screen exists to serve: validate the data before building UI
//  on it. Every figure the load engine will eventually put on Today and
//  Progress is derived from this list, and each of those figures will look
//  equally plausible whether it is right or wrong. So the list comes first, it
//  ships, and it stays — not as a debug screen to be removed later, but as the
//  place to go when a number looks off.
//
//  What to look for in the first two weeks:
//
//   • GAPS. Days where something happened and nothing scored. Each one is
//     either a fixable ingest problem or a real limit worth knowing.
//   • The source mix. Sessions on "avg HR" are waiting for the detail queue;
//     that number should fall towards zero as the backfill drains.
//   • Anything flagged "above HR max" — the maximum is wrong or stale.
//   • The self-test. If the Banister vector stops matching the published
//     worked example, the formula has drifted and every figure is wrong.
//

import SwiftUI

struct LoadDiagnosticView: View {

    /// "3rd" — small enough not to warrant a formatter.
    fileprivate func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default:
            switch n % 10 {
            case 1: return "\(n)st"
            case 2: return "\(n)nd"
            case 3: return "\(n)rd"
            default: return "\(n)th"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var load = LoadStore.shared
    @State private var constants = ConstantsStore.shared
    @State private var showAllDays = false

    /// The engine's worked examples, Foster's, and the shoe thresholds. One
    /// list, because a formula that drifts should be caught by looking at one
    /// screen.
    ///
    /// The shoe checks are here rather than nowhere because two of the three
    /// wear states cannot occur on the current data — see `Shoe.selfTest`.
    private var checks: [LoadEngine.Check] {
        LoadEngine.selfTest() + Monotony.selfTest() + AthleteStore.Shoe.selfTest()
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                pmcSection
                if !load.unscored.isEmpty { unscoredSection }
                // ABOVE the day list, not below it. The self-test's own footer
                // says that if any of these stop matching, every load figure in
                // the app is wrong — and it was sitting under sixty rows of day
                // detail, which is far enough down to look absent. The summary
                // is what you came for; the check that the summary is arithmetic
                // rather than fiction belongs beside it, not after the evidence
                // it validates.
                selfTestSection
                daysSection
            }
            .navigationTitle("Load diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { load.recomputeIfNeeded() }
            .refreshable { load.recompute() }
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        Section {
            if !constants.isComplete {
                Label("Constants incomplete — nothing can be scored until "
                      + "max and resting heart rate are both known.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
            }
            // The maximum cannot be below the floor of your own top zone. When
            // it is, every figure below is inflated by the gap — so it is said
            // here, next to the numbers, rather than only in Settings.
            if constants.hrMaxContradictsZones {
                Label("Max HR \(constants.hrMax ?? 0) is at or below your Z5 "
                      + "floor. Every load here is provisional and reads high.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
            }
            LabeledContent("Days", value: "\(load.days.count)")
            LabeledContent("Usable") {
                Text(String(format: "%.0f%%", load.coverage * 100))
                    .foregroundStyle(load.coverage >= 0.9 ? Color.secondary : Color.orange)
            }
            Group {
                LabeledContent("Measured", value: "\(load.count(.measured))")
                LabeledContent("Partial",  value: "\(load.partialCount)")
                LabeledContent("Rest",     value: "\(load.count(.rest))")
                LabeledContent("Gaps") {
                    Text("\(load.gapCount)")
                        .foregroundStyle(load.gapCount == 0 ? Color.secondary : Color.orange)
                }
            }
            Group {
                LabeledContent("Sessions scored", value: "\(load.scoredCount)")
                LabeledContent("Trace / avg / power") {
                    let c = load.sourceCounts
                    Text("\(c[.stream] ?? 0) / \(c[.average] ?? 0) / \(c[.power] ?? 0)")
                }
                LabeledContent("Power factor") {
                    if let f = load.powerFactor, f.isUsable {
                        Text(f.label)
                            .foregroundStyle(f.isTight ? Color.secondary : Color.orange)
                    } else if let f = load.powerFactor {
                        Text("\(f.sampleCount) of \(PowerFactor.minSamples) rides")
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("not measurable").foregroundStyle(Color.orange)
                    }
                }
                // "not measurable" on its own covered four situations with four
                // different fixes, only two of which the athlete can act on.
                if let d = load.powerDiagnosis {
                    if let why = d.reason {
                        Text(why).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("FTP") {
                        Text(d.ftp.map { "\($0) W" } ?? "not set in Strava")
                            .foregroundStyle(d.ftp == nil ? Color.orange : Color.secondary)
                    }
                    LabeledContent("Rides · meter · both") {
                        Text("\(d.rides) / \(d.withPower) / \(d.withBoth)")
                    }
                }
            }
            // Foster: shape, not size. The PMC cannot see it — 350 TRIMP as
            // 50 every day and 350 as one hard day plus rest give identical
            // CTL, ATL and TSB, and are not the same week.
            if let m = load.latestMonotony {
                LabeledContent("Monotony, last 7 days") {
                    if let v = m.monotony {
                        Text(String(format: "%.2f · %@", v, Monotony.label(v)))
                            .foregroundStyle(v >= Monotony.highMonotony
                                             ? Color.orange : Color.secondary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Strain") {
                    Text(m.strain.map { String(format: "%.0f", $0) } ?? "—")
                }
                LabeledContent("Rest days in the window", value: "\(m.restInWindow) of 7")
                // The load monotony DIVIDED BY, spelled out. Without it the
                // strain above cannot be reconciled against "TRIMP, last 7
                // days" below, because that row counts a gap as nothing and
                // this one counts the PMC's imputed stand-in.
                LabeledContent("Weekly load used") {
                    Text(String(format: "%.0f", m.weeklyLoad)).monospacedDigit()
                }
                if m.imputedInWindow > 0 {
                    Text("\(m.imputedInWindow) of the seven days "
                         + (m.imputedInWindow == 1 ? "was" : "were")
                         + " imputed, which is why the weekly load above is "
                         + "higher than the measured TRIMP below. A filled-in "
                         + "day also sits at the mean, shrinking the spread and "
                         + "pushing monotony UP — the figure reads high for a "
                         + "reason that is not training.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let st = m.strain, let r = Monotony.strainRank(load.monotony, of: st) {
                    Text("Strain is the \(ordinal(r.rank)) highest of the "
                         + "\(r.of) days in the last \(r.span) that carried a "
                         + "strain figure at all. There is no published "
                         + "threshold worth quoting for strain — it scales with "
                         + "your own volume, so it is ranked against your own "
                         + "history instead.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("TRIMP, last 7 days", value: load.total(lastDays: 7).label)
            LabeledContent("TRIMP, last 28 days", value: load.total(lastDays: 28).label)
        } header: {
            Text("Series")
        } footer: {
            Text("A gap is a day where something was recorded and none of it "
                 + "could be scored. It is not a zero, and a fitness curve drawn "
                 + "across one is wrong for six weeks afterwards.")
        }
    }

    // MARK: The curve

    private var pmcSection: some View {
        let p = load.pmc
        return Section {
            if let c = p.caveat {
                Text(c).font(.caption).foregroundStyle(Color.orange)
            }
            LabeledContent("Fitness · CTL",
                           value: p.ctl.map { String(format: "%.1f", $0) } ?? "—")
            LabeledContent("Fatigue · ATL",
                           value: p.atl.map { String(format: "%.1f", $0) } ?? "—")
            LabeledContent("Freshness · TSB") {
                if let t = p.tsb {
                    Text(String(format: "%+.1f · %@", t, PMC.freshnessLabel(t)))
                } else {
                    Text("—")
                }
            }
            LabeledContent("Ramp · CTL/week",
                           value: p.ramp.map { String(format: "%+.1f", $0) } ?? "—")
            LabeledContent("Days filled in", value: "\(p.imputedCount)")
        } header: {
            Text("Fitness curve")
        } footer: {
            Text("Two exponential averages of the same daily series — 42 days "
                 + "and 7 — and their difference. TSB is yesterday's, because "
                 + "today's session is already in today's fatigue. 42 is a time "
                 + "constant, not a half-life: the half-life is 29 days.")
        }
    }

    // MARK: What could not be scored

    private var unscoredSection: some View {
        Section {
            ForEach(load.unscored.prefix(40)) { w in
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.callout).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(w.dayKey).monospacedDigit()
                        Text(w.sport)
                        ForEach(w.flags, id: \.self) { f in
                            Text(f.label)
                                .padding(.horizontal, 4)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Unscored — \(load.unscored.count)")
        } footer: {
            Text("Each of these contributed nothing. Strength sessions with no "
                 + "heart rate are the expected case; anything else is worth a look.")
        }
    }

    // MARK: The days themselves

    private var daysSection: some View {
        Section {
            ForEach(showAllDays ? load.recent : Array(load.recent.prefix(60))) { d in
                dayRow(d)
            }
            if !showAllDays, load.recent.count > 60 {
                Button("Show all \(load.recent.count) days") { showAllDays = true }
            }
        } header: {
            Text("By day")
        }
    }

    @ViewBuilder
    private func dayRow(_ d: DailyLoad) -> some View {
        if d.workouts.isEmpty {
            HStack {
                Text(d.dayKey).font(.callout.monospacedDigit())
                Spacer()
                Text("rest").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            DisclosureGroup {
                ForEach(d.workouts) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(w.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(w.isScored ? String(format: "%.0f", w.trimp) : "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(w.isScored ? Color.primary : Color.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(w.source.label)
                            if let c = w.hrCoverage {
                                Text(String(format: "HR %.0f%%", c * 100))
                            }
                            ForEach(w.flags, id: \.self) { f in Text(f.label) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        // Only where the two differ, which is the handful of
                        // rows in DataCorrections. A flag beside a number you
                        // cannot check is a claim rather than evidence.
                        if w.isDurationCorrected {
                            Text("scored over \(Fmt.duration(w.scoredSeconds)) · "
                                 + "Strava moving \(Fmt.duration(w.stravaMovingSeconds))")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(d.dayKey).font(.callout.monospacedDigit())
                    Text(d.state.label)
                        .font(.caption2)
                        .foregroundStyle(stateColour(d.state))
                    Spacer()
                    Text(String(format: "%.0f", d.load))
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
            }
        }
    }

    private func stateColour(_ s: DayState) -> Color {
        switch s {
        case .measured: return .secondary
        case .partial:  return .orange
        case .gap:      return .red
        case .rest:     return .secondary
        }
    }

    // MARK: Self-test

    private var selfTestSection: some View {
        Section {
            ForEach(checks) { c in
                HStack {
                    Image(systemName: c.pass ? "checkmark.circle" : "xmark.octagon.fill")
                        .foregroundStyle(c.pass ? Color.secondary : Color.red)
                    Text(c.name).font(.caption)
                    Spacer()
                    Text(c.pass ? c.got : "\(c.got) ≠ \(c.expected)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(c.pass ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Self-test")
        } footer: {
            Text("The published Banister worked example — 60 minutes at HR 150 "
                 + "with a resting rate of 50 and a maximum of 190 scores 108.1 — "
                 + "plus the clamps and the helpers around it. If any of these "
                 + "stop matching, every load figure in the app is wrong.")
        }
    }
}
