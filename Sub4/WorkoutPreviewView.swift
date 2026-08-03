//
//  WorkoutPreviewView.swift
//  Sub4
//
//  The safety gate. Nothing reaches the Watch until the parse has been read by
//  a human and looks right.
//
//  A mis-parsed workout is worse than no workout: standing outside at 07:00 you
//  will trust whatever the watch says, and a session that quietly turned "8 km
//  easy + 4×20s strides" into "four strides" would waste the morning. So the
//  structure is shown step by step, beside the plan's original wording, with
//  every assumption spelled out.
//

import SwiftUI

struct WorkoutPreviewView: View {

    let session: Session

    @Environment(\.dismiss) private var dismiss

    private var result: (workout: PlanWorkout?, reason: String?) {
        WorkoutParser.parse(session)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let r = result
                    sourceCard
                    if let w = r.workout {
                        summaryCard(w)
                        stepsCard(w)
                        if !w.notes.isEmpty { notesCard(w.notes) }
                        // ← DELETE THIS ONE LINE if WatchWorkout.swift won't build.
                        WatchWorkoutCard(workout: w)
                    } else {
                        refusedCard(r.reason ?? "unparsed")
                    }
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Structured workout")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.tint)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(.accent4)
    }

    // MARK: Source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("THE PLAN SAYS").font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(Color.dim)
            Text([session.title, session.detail].compactMap { $0 }.joined(separator: " — "))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Summary

    private func summaryCard(_ w: PlanWorkout) -> some View {
        HStack(spacing: 0) {
            metric("Steps", "\(w.legCount)", "")
            divider
            metric("Distance",
                   w.totalKm.map { String(format: "%g", ($0 * 10).rounded() / 10) } ?? "—",
                   w.hasTimedParts ? "km +" : "km")
            divider
            metric("Type", w.shape.rawValue, "")
        }
        .cardStyle()
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(width: 1, height: 26)
    }

    private func metric(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.bold))
                    .foregroundStyle(session.tint).monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(Color.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Steps

    /// Blocks are UNROLLED here on purpose.
    ///
    /// Showing "2× [4 km / 1 km float]" reads as work-float-work-float, which
    /// is a kilometre more than the session actually is. On a screen whose only
    /// job is to let you verify what you'll be asked to run, a compact notation
    /// you have to interpret is the wrong trade.
    private func stepsCard(_ w: PlanWorkout) -> some View {
        let legs = w.legs
        return VStack(alignment: .leading, spacing: 0) {
            Text("WHAT THE WATCH WOULD RUN")
                .font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(Color.dim)
                .padding(.bottom, 10)
            ForEach(legs) { leg in
                legRow(leg)
                if leg.id != legs.last?.id {
                    Rectangle().fill(Color.line).frame(height: 1)
                        .padding(.vertical, 7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func legRow(_ leg: PlanWorkout.Leg) -> some View {
        let colour = leg.isEffort ? session.tint : Color.dim
        return HStack(spacing: 10) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(leg.label).font(.caption).foregroundStyle(Color.dim)
                .frame(width: 78, alignment: .leading)
            Text(leg.goalLabel).font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            if let p = leg.pace {
                Text(p.labelled)
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(colour)
            } else {
                Text("no target").font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
            }
        }
    }

    // MARK: Notes / refusal

    private func notesCard(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Assumptions", systemImage: "info.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accent4)
            ForEach(notes, id: \.self) { n in
                Text("• " + n).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func refusedCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No structured workout", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.dim)
            Text(reason).font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Run it on feel. Guessing a structure here would give you a "
                 + "workout to obey that the plan never asked for.")
                .font(.caption2).foregroundStyle(Color.dim.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var footnote: some View {
        Text("Check the steps above before sending. Once a workout is on the "
             + "Watch you'll follow whatever it says.")
            .font(.caption2).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - Whole-block audit
//
// One session at a time is no way to check 103 of them. This lists every run
// session in the plan with its parse on one line, so the whole block can be
// skimmed for anything that looks wrong.

struct WorkoutAuditView: View {

    // Parsed once, not on every body evaluation — 103 regex-heavy parses per
    // render would make the list stutter while scrolling.
    @State private var coverage = WorkoutParser.Coverage()
    @State private var loaded = false

    var body: some View {
        let c = coverage
        List {
            Section {
                LabeledContent("Run sessions", value: "\(c.total)")
                LabeledContent("Structured", value: "\(c.parsed.count)")
                LabeledContent("Left to feel", value: "\(c.refused.count)")
            } footer: {
                Text("Refused sessions are the plan's own \"(pointer) — by feel\" "
                     + "runs and the field test. They state no structure on purpose.")
            }

            // Grouped by identical parse. 92 rows with the same easy run
            // repeated eleven times is not something anyone audits; 46 distinct
            // shapes with a count is.
            Section("Structured · \(grouped(c).count) distinct shapes") {
                ForEach(grouped(c), id: \.key) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            if row.count > 1 {
                                Text("×\(row.count)").font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(row.line).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Left to feel") {
                ForEach(c.refused) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Workout parsing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            coverage = WorkoutParser.coverage()
        }
    }

    private struct Row {
        let key: String
        let title: String
        let line: String
        let count: Int
    }

    private func grouped(_ c: WorkoutParser.Coverage) -> [Row] {
        var order: [String] = []
        var bucket: [String: (title: String, line: String, count: Int)] = [:]
        for w in c.parsed {
            let line = oneLine(w)
            let key = w.title + "|" + line
            if bucket[key] == nil { order.append(key); bucket[key] = (w.title, line, 0) }
            bucket[key]!.count += 1
        }
        return order.compactMap { k in
            bucket[k].map { Row(key: k, title: $0.title, line: $0.line, count: $0.count) }
        }
    }

    private func oneLine(_ w: PlanWorkout) -> String {
        w.steps.map { s -> String in
            let pace = s.pace.map { " @\($0.label)" } ?? ""
            if s.kind == .block {
                // "between" is load-bearing — n reps, n−1 floats.
                let rec = s.recoveryLabel.map { ", \($0) float between" } ?? ""
                return "\(s.iterations)× \(s.goalLabel)\(pace)\(rec)"
            }
            return "\(s.kind.rawValue) \(s.goalLabel)\(pace)"
        }
        .joined(separator: " | ")
    }
}
