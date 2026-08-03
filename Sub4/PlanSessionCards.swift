//
//  PlanSessionCards.swift
//  Sub4
//
//  The two cards that describe a PLANNED session, shared by both detail views.
//
//  WHY THEY LEFT SessionDetailView
//  -------------------------------
//  Patch 104 gave every card in the app one destination. A session with a
//  matched activity now opens ActivityDetailView and nothing else — but that
//  view had no idea what the plan asked for beyond a title and one line, and it
//  had no note at all. The content it needed was two hundred lines sitting
//  inside SessionDetailView as private members.
//
//  Copying them across would have produced two definitions of "what the plan
//  asked for", drifting apart on the first change to either. They are values
//  with a session in and a view out, which is what a component is for.
//
//  THE PARSE IS DONE ONCE, IN `init`
//  --------------------------------
//  `WorkoutParser.parse` walks the plan's text. As a computed property it ran on
//  every redraw of a view that redraws on every scroll frame — the same reason
//  SessionDetailView stores it rather than computing it.
//

import SwiftUI

// MARK: - What the plan asked for

/// "THE SESSION" — the headline work, its pace band, the derived duration and
/// gap to marathon pace, the collapsed legs, and the plan's own raw text.
///
/// Draws nothing when the plan states no structure: non-runs with a real
/// breakdown render as `BlockRow`s instead, and a card containing only its own
/// title is furniture.
struct PlanSessionCard: View {

    let session: Session
    /// COMPACT drops the card chrome, the "THE SESSION" heading, the big
    /// headline and the pace row — everything the activity page's verdict block
    /// has already said four lines above, at 26 points. What is left is what the
    /// verdict does NOT say: the distance asked, the intensity, the derived
    /// duration, the gap to marathon pace and the plan's own raw line.
    ///
    /// The full form is unchanged and is what the session page still draws.
    var compact = false
    private let parsed: (workout: PlanWorkout?, reason: String?)

    init(session: Session, compact: Bool = false) {
        self.session = session
        self.compact = compact
        self.parsed = WorkoutParser.parse(session)
    }

    var body: some View {
        if compact {
            compactBody
        } else if session.breakdown?.blocks == nil,
                  session.detail != nil || parsed.workout != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("THE SESSION").font(.system(size: 10, weight: .bold)).tracking(0.55)
                    Spacer()
                    if let i = session.intensity {
                        // "marathon_pace" is a storage key, not a word.
                        Text(i.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10.5))
                    }
                }
                .foregroundStyle(Color.dim)

                headline
                // An HStack, not `Text + Text`. Concatenation only survives
                // modifiers that return `Text`, and which of them do has moved
                // between SDK versions — not worth betting a build on.
                if let p = headlinePace {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(p.label).font(.system(size: 15, weight: .semibold))
                            .monospacedDigit().foregroundStyle(session.tint)
                        Text("min/km").font(.system(size: 11)).foregroundStyle(Color.dim)
                    }
                    .padding(.top, 2)
                }
                if !derivedLines.isEmpty {
                    Text(derivedLines.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Color.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }

                if legRows.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(legRows) { legRow($0) }
                    }
                    .padding(.top, 9)
                }

                if let raw = session.detail {
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.line).frame(height: 1)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// The plan's ask, stripped of everything the verdict states. No chrome —
    /// it is embedded in the run card's own box.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(askedLabel).font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.ink)
                if let i = session.intensity {
                    Text("· " + i.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(Color.dim)
                }
                Spacer(minLength: 0)
            }
            if !derivedLines.isEmpty {
                Text(derivedLines.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if legRows.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(legRows) { legRow($0) }
                }
                .padding(.top, 5)
            }
            if let raw = session.detail {
                Text(raw)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.dim.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The distance or the work, WITHOUT its pace band — the band is in the
    /// verdict. Falls back to the title when the plan states neither.
    private var askedLabel: String {
        if let b = parsed.workout?.steps.first(where: { $0.kind == .block }) {
            return b.iterations > 1 ? "\(b.iterations) × \(b.goalLabel)" : b.goalLabel
        }
        if let km = parsed.workout?.totalKm { return PlanStep.label(.distance(km)) }
        return session.title ?? "—"
    }

    /// The headline is the WORK, not the warm-up. Reading "2 km" at the top of
    /// an interval day would describe the jog that precedes it.
    private var headline: some View {
        let w = parsed.workout
        let effort = w?.steps.first { $0.kind == .block }
        let value: String
        let unit: String
        if let b = effort {
            value = b.iterations > 1 ? "\(b.iterations) × \(b.goalLabel)" : b.goalLabel
            unit = "work"
        } else if let km = w?.totalKm {
            value = PlanStep.label(.distance(km))
            unit = ""
        } else {
            value = session.title ?? "—"
            unit = ""
        }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.ink)
            if !unit.isEmpty {
                Text(unit).font(.system(size: 12)).foregroundStyle(Color.dim)
            }
        }
        .padding(.top, 5)
    }

    /// The band the headline is run at: the work block's, or the steady run's.
    private var headlinePace: PlanStep.Pace? {
        guard let w = parsed.workout else { return nil }
        if let b = w.steps.first(where: { $0.kind == .block && $0.pace != nil }) {
            return b.pace
        }
        return w.steps.compactMap(\.pace).first
    }

    /// Duration, and the gap to marathon pace. Both arithmetic, both withheld
    /// when the plan has not supplied enough to compute them honestly.
    private var derivedLines: [String] {
        var out: [String] = []
        guard let w = parsed.workout else { return out }

        // An open cool-down makes the total unknowable, and a total that
        // quietly omits it is worse than none. Same refusal the volume card
        // makes about planned figures it cannot state.
        let hasOpen = w.steps.contains { if case .open = $0.goal { return true }; return false }
        if let km = w.totalKm, let p = headlinePace, !hasOpen, !w.hasTimedParts {
            let fast = Int((km * Double(p.fast)).rounded())
            let slow = Int((km * Double(p.slow)).rounded())
            out.append("≈ " + Self.minutes(fast, slow))
        } else if hasOpen {
            out.append("total not stated — the cool-down is open")
        }

        let target = PlanStore.shared.plan.meta.targetPaceSecKm
        if let p = headlinePace, target > 0, let d = p.offset(from: target) {
            let word = d.fast > 0 ? "slower than" : "faster than"
            let lo = Swift.min(abs(d.fast), abs(d.slow))
            let hi = Swift.max(abs(d.fast), abs(d.slow))
            let span = lo == hi ? "\(lo)" : "\(lo)–\(hi)"
            out.append("\(span) s/km \(word) marathon pace")
        }
        return out
    }

    private static func minutes(_ fast: Int, _ slow: Int) -> String {
        let a = (fast + 30) / 60, b = (slow + 30) / 60
        return a == b ? "\(a) min" : "\(a)–\(b) min"
    }

    /// Collapsed legs — repeated reps shown once with their count, because a
    /// list of eight identical rows is a worse description than "×8".
    private struct LegRow: Identifiable {
        let id: Int
        let kind: String
        let goal: String
        let pace: PlanStep.Pace?
    }

    private var legRows: [LegRow] {
        guard let w = parsed.workout else { return [] }
        var out: [LegRow] = []
        for s in w.steps {
            if s.kind == .block {
                let n = Swift.max(s.iterations, 1)
                out.append(LegRow(id: out.count,
                                  kind: n > 1 ? "Work ×\(n)" : "Work",
                                  goal: s.goalLabel, pace: s.pace))
                if let r = s.recoveryGoal, n > 1 {
                    out.append(LegRow(id: out.count, kind: "Float",
                                      goal: PlanStep.label(r), pace: s.recoveryPace))
                }
            } else {
                out.append(LegRow(id: out.count,
                                  kind: s.kind == .warmup ? "Warm-up"
                                      : s.kind == .cooldown ? "Cool-down" : "Run",
                                  goal: s.goalLabel, pace: s.pace))
            }
        }
        return out
    }

    private func legRow(_ l: LegRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(l.kind.uppercased())
                .font(.system(size: 9.5)).tracking(0.4).foregroundStyle(Color.dim)
                .frame(width: 64, alignment: .leading)
            Text(l.goal).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            // "easy" rather than blank. The plan states no pace for a float, and
            // an empty cell reads as missing data instead of as deliberate.
            if let p = l.pace {
                Text(p.labelled).font(.system(size: 11, weight: .semibold))
                    .monospacedDigit().foregroundStyle(session.tint)
            } else {
                Text("easy").font(.system(size: 11)).foregroundStyle(Color.dim)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.line.opacity(0.7)).frame(height: 1)
        }
    }
}

// MARK: - The note

/// RPE, how it felt, and the words — with the whole card as the way in to the
/// editor.
///
/// ONE PLACE TO WRITE ONE, as of patch 104. It used to be reachable from Today,
/// from Week and from the session page, which meant three different routes to
/// the same editor and a note you could add to a run you had not done. A note is
/// a record of how a session WENT, so it belongs where the result is: the
/// activity page, and only once there is an activity.
struct SessionNoteCard: View {

    let session: Session
    let onTap: () -> Void
    @State private var notes = NotesStore.shared

    var body: some View {
        if let n = notes.note(for: session) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "text.quote").font(.caption)
                        Text("Note").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(Color.accent4)

                    HStack(spacing: 7) {
                        if let r = n.rpe {
                            Text("RPE \(r)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(session.tint.opacity(0.2))
                                .foregroundStyle(session.tint)
                                .clipShape(Capsule())
                        }
                        if let f = n.feel {
                            HStack(spacing: 4) {
                                Image(systemName: f.symbol).font(.caption2)
                                Text(f.label).font(.caption)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.line.opacity(0.6))
                            .foregroundStyle(Color.dim)
                            .clipShape(Capsule())
                        }
                        Spacer()
                    }

                    if !n.text.isEmpty {
                        Text(n.text)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()
        } else {
            Button(action: onTap) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil").font(.caption)
                    Text("Add a note").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("effort · how it felt")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                .foregroundStyle(Color.accent4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()
        }
    }
}
