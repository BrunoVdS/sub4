//
//  HealthCoverageView.swift
//  Sub4
//
//  4A M0 on a screen — patch 282, ADR-0003 §12.28.
//
//  ONE QUERY PER MONTH, NOT ONE FOR THE WINDOW
//  -------------------------------------------
//  `HealthStore.workoutTimeout` is twelve seconds and the window here is
//  thirteen months. A single query for the lot is one timeout away from
//  returning `[]` — which this diagnostic would then have to report as "Health
//  answered, and it has nothing", the exact false negative the whole design is
//  built to avoid. A month at a time is bounded, and the months are the buckets
//  the report wants anyway.
//
//  The trade is stated rather than hidden: dedupe runs per call, so a session
//  that starts on the last night of a month and ends in the next is deduped
//  within its own month only. Sessions do not span months in practice, and the
//  bucket is chosen by start date, so this cannot double-count.
//
//  SWIM ENRICHMENT IS OFF
//  ----------------------
//  `workouts(from:to:)` runs one extra sample query per swim to recover active
//  seconds, capped at eighty. This report never reads `activeSeconds` — it
//  counts sessions and days — so thirteen calls would buy several hundred
//  round trips for a field nobody here looks at. `enrichSwims: false` is patch
//  282's one change to that function, and every existing caller keeps the
//  default.
//

import SwiftUI

struct HealthCoverageView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var health = HealthStore.shared

    @State private var report: HealthCoverage.Report?
    @State private var monthsDone = 0
    @State private var monthsTotal = 0
    @State private var running = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if let r = report {
                    resultSections(r)
                } else {
                    Section {
                        if running {
                            LabeledContent("Reading Health",
                                           value: "\(monthsDone) of \(monthsTotal) months")
                            ProgressView(value: Double(monthsDone),
                                         total: Double(max(monthsTotal, 1)))
                        } else {
                            Text("Nothing measured yet.")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("One query per month from \(MatchRules.cutoffDayKey). "
                             + "Nothing is written and nothing leaves the phone.")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("Health coverage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await measure() }
        }
    }

    // MARK: The result

    @ViewBuilder
    private func resultSections(_ r: HealthCoverage.Report) -> some View {
        Section("What this is") {
            // THE READING FIRST, ALWAYS. Four of its five cases produce zeros
            // that mean nothing at all, and a reader who scrolls straight to
            // the table would take them for an answer.
            Text(r.reading.line)
                .font(.callout.weight(r.reading.isTrustworthy ? .regular : .semibold))
                .foregroundStyle(r.reading.isTrustworthy ? Color.ink : Color.red)
            if r.reading.isTrustworthy {
                Text(r.headline).font(.callout)
            }
        }

        if r.reading.isTrustworthy {
            let t = r.total

            Section("Totals") {
                LabeledContent("Health sessions", value: "\(t.sessions)")
                LabeledContent("  run / ride / swim / strength / other",
                               value: "\(t.runs) / \(t.rides) / \(t.swims) / "
                                    + "\(t.strength) / \(t.other)")
                LabeledContent("With a distance", value: "\(t.withDistance)")
                LabeledContent("With a heart rate", value: "\(t.withHeartRate)")
                LabeledContent("The app holds", value: "\(t.storedSessions)")
                LabeledContent("  run / ride / swim / strength / other",
                               value: "\(t.storedRuns) / \(t.storedRides) / "
                                    + "\(t.storedSwims) / \(t.storedStrength) / "
                                    + "\(t.storedOther)")
            }

            Section {
                LabeledContent("Days in both", value: "\(t.daysBoth)")
                LabeledContent("Days only in Health", value: "\(t.daysHealthOnly)")
                LabeledContent("Days only in the app", value: "\(t.daysStoredOnly)")
                    .foregroundStyle(t.daysStoredOnly > 0 ? Color.red : Color.ink)
                // NAMED, NOT COUNTED — 283. The number is what you read; the
                // dates are what you act on. Capped on screen because a list
                // is not a view, and the remainder is SAID rather than
                // silently dropped — the paste has all of them.
                ForEach(Array(t.datesStoredOnly.prefix(20)), id: \.self) { d in
                    Text(d).font(.caption).foregroundStyle(Color.dim)
                }
                if t.datesStoredOnly.count > 20 {
                    Text("+ \(t.datesStoredOnly.count - 20) more — copy the report")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            } header: {
                Text("Training days")
            } footer: {
                Text("Days, not sessions. A day on both sides counts as covered "
                     + "even if the two sessions on it are different sessions — "
                     + "Compare with Strava is the screen that checks that. "
                     + "Every day in the last row is one a disconnect would "
                     + "destroy with nothing to put in its place.")
                    .font(.caption2)
            }

            Section {
                LabeledContent("Strava was one of the writers", value: "\(t.stravaWrote)")
                LabeledContent("Strava was the only writer", value: "\(t.stravaAlone)")
                    .foregroundStyle(t.stravaAlone > 0 ? Color.accent4 : Color.ink)
            } header: {
                Text("Who wrote it")
            } footer: {
                Text("A session Strava alone wrote is a summary it pushed back "
                     + "into Health. It does not disappear when you disconnect — "
                     + "an HKWorkout is Apple's once written — but it usually "
                     + "carries no route and no heart-rate samples. Present is "
                     + "not the same as complete.")
                    .font(.caption2)
            }

            Section("By month") {
                ForEach(r.months) { m in
                    LabeledContent(m.month) {
                        Text("\(m.sessions) H · \(m.storedSessions) app"
                             + (m.daysStoredOnly > 0 ? " · \(m.daysStoredOnly) missing" : ""))
                            .font(.caption)
                            .foregroundStyle(m.daysStoredOnly > 0 ? Color.red : Color.secondary)
                    }
                }
            }
        }

        Section {
            Button {
                UIPasteboard.general.string = HealthCoverage.text(r)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy the report", systemImage: "doc.on.doc")
            }
        } footer: {
            Text("Fixed-width, so the table survives being pasted into the plan. "
                 + "Routes are not measured — see HealthCoverage.swift for why.")
                .font(.caption2)
        }
    }

    // MARK: Reading Health

    private func measure() async {
        guard report == nil, !running else { return }
        running = true
        defer { running = false }

        let keys = HealthCoverage.monthKeys(from: MatchRules.cutoffDayKey, now: Date())
        monthsTotal = keys.count
        monthsDone = 0

        // THE PREFLIGHT, AND IT DECIDES THE WHOLE ANSWER. Every one of these
        // makes `workouts(from:to:)` return `[]` without ever asking Health.
        let reading: HealthCoverage.Reading
        if !health.isAvailable { reading = .unavailable }
        else if !health.hasUsageDescription { reading = .noUsageDescription }
        else if !health.hasRequestedAuthorization { reading = .neverAsked }
        else { reading = .read }

        guard reading.isTrustworthy else {
            report = HealthCoverage.build(health: [], activities: [], months: keys,
                                          reading: reading, generated: AppVersion.stamp)
            return
        }

        // REMEMBERED, NOT CLEARED. Writing an empty string into `lastError` to
        // get a clean slate would leave the Apple Health section in Settings
        // rendering an empty red row, and would throw away a message somebody
        // may still need. Comparing is enough: only a message that appeared
        // DURING this run belongs to this run.
        let errorBefore = health.lastError
        var found: [HealthWorkout] = []
        for key in keys {
            if let (from, to) = Self.bounds(of: key) {
                found += await health.workouts(from: from, to: to, enrichSwims: false)
            }
            monthsDone += 1
        }

        let outcome: HealthCoverage.Reading
        if let now = health.lastError, now != errorBefore { outcome = .failed(now) }
        else { outcome = .read }

        report = HealthCoverage.build(health: found,
                                      activities: ActivityStore.shared.activities,
                                      months: keys,
                                      reading: outcome,
                                      generated: AppVersion.stamp)
    }

    /// First instant of the month, and the first instant of the next one.
    private static func bounds(of key: String) -> (Date, Date)? {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        guard key.count == 7,
              let year = Int(key.prefix(4)), let month = Int(key.suffix(2)),
              let start = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = cal.date(byAdding: .month, value: 1, to: start)
        else { return nil }
        return (start, end)
    }
}
