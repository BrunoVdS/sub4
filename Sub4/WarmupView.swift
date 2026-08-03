//
//  WarmupView.swift
//  Sub4
//
//  The race-day warm-up, on screen.
//
//  Laid out as a timeline counting down to the gun, because that is how it will
//  actually be used: standing in a corral, checking what happens next. The
//  conditional steps — the jog, the accelerations — are marked rather than
//  hidden, because deciding whether to do them IS the protocol. A warm-up
//  screen that quietly dropped them would be answering a question the morning
//  has to answer.
//
//  The gun row is tinted differently. It is the only line that is not
//  preparation, and it carries the single highest-value instruction on the
//  screen: let people go past you.
//

import SwiftUI

struct WarmupView: View {

    var embedded = false

    @Environment(\.dismiss) private var dismiss

    private var warmup: Warmup? { PlanStore.shared.warmup }

    var body: some View {
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
        .tint(.accent4)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if let w = warmup {
                VStack(alignment: .leading, spacing: 10) {
                    if let i = w.intro { introCard(i) }
                    timelineCard(w)
                    circuitCard(w)
                    conditionsCard(w.conditions)
                    rehearsalCard
                    if let c = w.caution { cautionCard(c) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            } else {
                missing
            }
        }
        .background(Color.bg)
        .navigationTitle("Warm-up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.cooldown")
                .font(.largeTitle).foregroundStyle(Color.dim)
            Text("No warm-up in plan.json").font(.headline)
            Text("Section 10b was added to the plan after this build. Re-run "
                 + "extract_plan.py and rebuild.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .padding(30).frame(maxWidth: .infinity)
    }

    // MARK: Intro

    private func introCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    // MARK: Timeline

    private func timelineCard(_ w: Warmup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COUNTDOWN TO THE GUN").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(w.timeline) { s in
                stepRow(s, gun: w.isGun(s), conditional: w.isConditional(s))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func stepRow(_ s: Warmup.Step, gun: Bool, conditional: Bool) -> some View {
        let tint: Color = gun ? Discipline.run.tint
                              : (conditional ? Color.dim : Color.accent4)
        return HStack(alignment: .top, spacing: 10) {
            Text(s.time ?? "")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.action ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(gun ? tint : Color.ink)
                    if conditional {
                        Text("OPTIONAL")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.line)
                            .foregroundStyle(Color.dim)
                            .clipShape(Capsule())
                    }
                }
                Text(s.detail ?? "")
                    .font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Circuit

    private func circuitCard(_ w: Warmup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THE MOBILITY CIRCUIT").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(w.circuit) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.movement ?? "")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(m.dose ?? "")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.accent4)
                }
            }
            if let n = w.circuitNote {
                Text(n).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Conditions

    private func conditionsCard(_ conditions: [Warmup.Condition]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("BY CONDITIONS").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(conditions) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.condition ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accent4)
                    Text(c.what ?? "")
                        .font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Rehearsal
    //
    // Read from the sessions rather than restated here, so this list cannot
    // drift from the plan. If a rehearsal marker moves in the HTML, this moves.

    private var rehearsalCard: some View {
        let sessions = PlanStore.shared.plan.sessions
            .filter { $0.rehearsesWarmup }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }
        return VStack(alignment: .leading, spacing: 9) {
            Text("REHEARSE IT HERE").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(sessions) { s in
                HStack(alignment: .top, spacing: 9) {
                    Text(s.date ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.accent4)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title ?? "").font(.caption.weight(.semibold))
                        Text(s.prep ?? "").font(.caption2)
                            .foregroundStyle(Color.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let race = PlanStore.shared.plan.sessions
                .first(where: { $0.prepIsRaceDay }) {
                Divider().overlay(Color.line)
                HStack(alignment: .top, spacing: 9) {
                    Text(race.date ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.accent4)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Then the real thing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accent4)
                        Text(race.prep ?? "").font(.caption2)
                            .foregroundStyle(Color.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("The plan's own rule: nothing new on the day. A warm-up you "
                 + "have never done is exactly what that forbids.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Caution

    private func cautionCard(_ c: Fuel.Caution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").font(.caption)
                Text(c.tag ?? "Caution").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.dangerColor)
            Text(c.text ?? "").font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.dangerColor)
                .frame(width: 3).padding(.vertical, 10).padding(.leading, 1)
        }
    }
}
