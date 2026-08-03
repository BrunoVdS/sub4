//
//  ProposalView.swift
//  Sub4
//
//  Reading a monthly proposal.
//
//  NOTHING ON THIS SCREEN CHANGES THE PLAN. There is no Apply button, by
//  decision — the plan ships read-only in the bundle and applying changes needs
//  an override layer that does not exist yet. Until it does, a proposal is
//  something you read and then act on yourself, and the screen says so rather
//  than leaving you looking for a button.
//
//  ORDER: verdict, then confidence, then reasoning, then changes. The verdict
//  is first because most months it will be "no change" and that should take one
//  glance. Confidence sits next to it because a `harder` verdict at 2/5 is a
//  different thing from the same verdict at 5/5, and separating them across the
//  screen would let the second be read as the first.
//
//  Guardrail rejections are shown, not hidden. A filter you cannot see is
//  indistinguishable from a model that never proposed anything — and knowing it
//  tried to rewrite the taper is exactly the kind of thing you want to know.
//

import SwiftUI

struct ProposalView: View {

    let record: ProposalStore.Record

    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?

    private var proposal: ReviewProposal { record.proposal }
    private var accepted: [ReviewProposal.Change] {
        proposal.acceptedChanges(plan: PlanStore.shared)
    }
    private var rejected: [ReviewProposal.Rejection] {
        proposal.rejections(plan: PlanStore.shared)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    verdictCard
                    reasoningCard
                    if accepted.isEmpty { noChangesCard } else { changesCard }
                    if !rejected.isEmpty { rejectedCard }
                    if !proposal.watchFor.isEmpty { watchCard }
                    provenanceCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            .navigationTitle(record.windowLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        }
        .tint(.accent4)
    }

    // MARK: Verdict

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title3)
                Text(proposal.verdictLabel)
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(tint)

            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= proposal.confidence ? tint : Color.line)
                        .frame(width: 7, height: 7)
                }
                Text("confidence \(proposal.confidence)/5")
                    .font(.caption2).foregroundStyle(Color.dim)
                Spacer()
            }

            Text(proposal.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var tint: Color {
        switch proposal.verdict {
        case .noChange:             Discipline.run.tint
        case .insufficientEvidence: Color.dim
        case .easier:               Discipline.swim.tint
        case .harder:               Color.accent4
        case .mixed:                Color.accent4
        }
    }

    private var symbol: String {
        switch proposal.verdict {
        case .noChange:             "checkmark.seal.fill"
        case .insufficientEvidence: "questionmark.circle.fill"
        case .easier:               "arrow.down.right.circle.fill"
        case .harder:               "arrow.up.right.circle.fill"
        case .mixed:                "arrow.up.arrow.down.circle.fill"
        }
    }

    // MARK: Reasoning

    private var reasoningCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Reasoning").font(.subheadline.weight(.semibold))
            Text(proposal.reasoning)
                .font(.subheadline).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Changes

    private var noChangesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No changes proposed", systemImage: "equal.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dim)
            Text("Which is a result, not an absence of one. A block that needs "
                 + "adjusting every month was not periodised in the first place.")
                .font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var changesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Proposed changes").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(accepted.count)")
                    .font(.caption.weight(.bold)).foregroundStyle(Color.accent4)
            }

            ForEach(accepted) { c in changeRow(c) }

            Text("Nothing here has been applied. The app does not modify the "
                 + "plan — these are for you to weigh and act on yourself.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func changeRow(_ c: ReviewProposal.Change) -> some View {
        let session = PlanStore.shared.plan.sessions.first { $0.uid == c.sessionUid }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let s = session {
                    Image(systemName: s.discipline.symbol).font(.caption2)
                        .foregroundStyle(s.tint)
                    Text(s.date ?? "").font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.dim)
                }
                Spacer()
                if c.skip {
                    Text("SKIP").font(.caption2.weight(.bold))
                        .foregroundStyle(Color.dangerColor)
                }
            }

            if let s = session, let was = s.detail {
                Text(was)
                    .font(.caption).foregroundStyle(Color.dim)
                    .strikethrough(true, color: Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !c.skip {
                Text(c.newDetail)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(c.reason).font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "quote.opening").font(.system(size: 8))
                Text(c.evidence).font(.caption2).italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.dim.opacity(0.85))
        }
        .padding(.vertical, 4)
    }

    // MARK: Rejections

    private var rejectedCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Discarded by the guardrails", systemImage: "shield.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accent4)
            // `ForEach(rejected)` — Rejection is Identifiable. A key path into
            // a tuple element (`\.change.id`) does not compile in Swift.
            ForEach(rejected) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.change.sessionUid)
                        .font(.caption2.monospaced()).foregroundStyle(Color.dim)
                    Text(r.why).font(.caption).foregroundStyle(Color.dim)
                }
            }
            Text("Shown rather than hidden: a filter you cannot see is "
                 + "indistinguishable from a reviewer that proposed nothing.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Watch for

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Watch for next month").font(.subheadline.weight(.semibold))
            ForEach(proposal.watchFor, id: \.self) { w in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(Color.accent4)
                    Text(w).font(.caption).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Provenance

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = ProposalStore.shared.writeMarkdown(record) {
                    share = ShareItem(url: url)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up").font(.caption)
                    Text("Export proposal and evidence")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(Color.accent4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(record.model) · \(record.appVersion)")
                .font(.caption2).foregroundStyle(Color.dim)
            Text("The evidence pack is stored with the verdict. Thresholds and "
                 + "estimators change over 34 weeks, so the same window would "
                 + "not produce the same numbers twice.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
