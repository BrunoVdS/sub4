//
//  ActivityDetailVerdict.swift
//  Sub4
//
//  The pace verdict and the plan's ask — runs with a stated target only.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI

extension ActivityDetailView {

    // MARK: Verdict — runs only, and only when the plan states a number

    /// Inlined into `runCard` since patch 107 — hence no `.cardStyle()` on any
    /// branch. The content is otherwise the shipped verdict, unchanged.
    @ViewBuilder
    func verdictBody(_ ctx: SplitContext) -> some View {
        if activity.discipline == .run,
           let s = session,
           let target = PaceTarget.parse(s),
           !target.isMeasurable {

            // The reps themselves, when they can be read out of the run — a
            // verdict on the work only, never on the warm-up around it.
            let iv = bestIntervals(ctx)
            if let iv, iv.matchesPlan, let mean = iv.meanPace {
                timedVerdict(target, iv, mean)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "target")
                        Text("Target \(target.rangeLabel) /km")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                    }
                    .foregroundStyle(tint)
                    // The refusal only speaks for a session that HAS an
                    // interval structure. On one that hasn't — a lone "25min
                    // @4:55–5:10", or THE TEST, which the parser refuses on
                    // purpose — it would replace a true explanation with
                    // "no interval structure in the plan", which is both wrong
                    // and less useful.
                    Text((iv?.plan != nil ? iv?.refusal : nil)
                         ?? ("The plan sets this by time, not distance. Kilometre "
                             + "splits can't separate the reps from the warm-up, "
                             + "so no verdict is claimed — read the splits below."))
                        .font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } else if activity.discipline == .run,
           let s = session,
           let target = PaceTarget.parse(s),
           let d = detail,
           let measured = target.measured(in: d, fallback: paceSecPerKm) {

            let state = target.state(for: measured)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: state.symbol)
                    Text(state.headline).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(target.scopeLabel).font(.caption2)
                        .foregroundStyle(Color.dim)
                }
                .foregroundStyle(state.colour)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.pace(measured)).font(.title2.weight(.bold))
                        .foregroundStyle(state.colour).monospacedDigit()
                    Text("min/km").font(.caption).foregroundStyle(Color.dim)
                    Text("· target \(target.rangeLabel)")
                        .font(.caption).foregroundStyle(Color.dim)
                }

                Text(gapSentence(measured, target))
                    .font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)

                // "Plan asked N km · recorded N km" is gone: the hero states
                // what was recorded and the asked row states what was asked,
                // both within this card and neither of them twice.
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Measured against the BOUND, not the midpoint.
    ///
    /// The verdict is decided by whether you left the band, so the sentence
    /// underneath has to be measured the same way. Saying "10 s/km faster than
    /// the middle of the range" about a run 3 s/km outside the fast bound
    /// describes a different, larger miss than the one that was actually
    /// flagged — two frames on one card, and the bigger number wins the
    /// reader's attention.
    func gapSentence(_ measured: Int, _ target: PaceTarget) -> String {
        if measured < target.low {
            let d = target.low - measured
            return "\(d) s/km faster than the \(Fmt.pace(target.low)) bound "
                 + "— inside the band would be \(target.rangeLabel)."
        }
        if measured > target.high {
            let d = measured - target.high
            return "\(d) s/km slower than the \(Fmt.pace(target.high)) bound "
                 + "— inside the band would be \(target.rangeLabel)."
        }
        let fromFast = measured - target.low
        let fromSlow = target.high - measured
        return "Inside the band — \(fromFast) s/km off the fast end, "
             + "\(fromSlow) s/km off the slow end."
    }

    var plannedKm: Double? {
        guard let text = session.map({ [$0.title, $0.detail].compactMap { $0 }.joined(separator: " ") }),
              let r = text.range(of: #"(\d+(?:[.,]\d+)?)\s*km"#, options: .regularExpression)
        else { return nil }
        return Double(text[r].replacingOccurrences(of: "km", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces))
    }

    // MARK: What the plan asked for

    // `planCard` and the standalone match row were folded into `runCard` in
    // patch 107. "Change match" now sits in `titleRow`; the plan content is
    // `askedSection`, which draws the shared card in its compact form.

    /// Swim sets and strength circuits carry a real structure from the plan and
    /// render as their own rows — the same treatment they get on the session
    /// page, because it is the same content.
    @ViewBuilder
    var breakdownCards: some View {
        if let s = session, let blocks = s.breakdown?.blocks {
            ForEach(blocks) { BlockRow(block: $0, tint: s.tint) }
        }
    }

    /// Only with a session, because a note is stored against the plan's uid —
    /// an unmatched ride has nothing to attach one to. This is now the ONLY
    /// place in the app a note can be written.
    @ViewBuilder
    var noteCard: some View {
        if let s = session {
            SessionNoteCard(session: s) { route = .note(s) }
        }
    }

}
