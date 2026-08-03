//
//  ReviewPreflightView.swift
//  Sub4
//
//  What would leave the phone, before it does — patch 192, plan step 2.3.
//
//  WHY A SCREEN AND NOT A SENTENCE
//  -------------------------------
//  Every consent flow this app could have written would be a paragraph saying
//  "this sends your training data to Anthropic", and every one of them would be
//  a summary nobody can check. The payload is already a list of sections that
//  know their own size and provenance, so the screen can simply show it: what
//  goes, what does not, why not, and how big each part is.
//
//  It is also the answer to a question the gate cannot give. `aiReview` has been
//  shut since patch 178 with the reason "the review sends figures derived from
//  Strava data" — true, and useless if you want to know WHICH figures. This
//  screen names them.
//
//  THE OPT-IN IS A REAL SWITCH, NOT A DISCLOSURE
//  ---------------------------------------------
//  Notes default to off (PRIV-03). The toggle changes what `render()` returns,
//  and the byte count above it moves when you flip it — so the effect of the
//  choice is visible in the same glance as the choice.
//

import SwiftUI

struct ReviewPreflightView: View {

    let payload: ReviewPayload
    /// Called with the payload as configured, or never if the reader backs out.
    var onSend: (ReviewPayload) -> Void = { _ in }

    @State private var optedIn: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var configured: ReviewPayload {
        var p = payload
        p.optedIn = optedIn
        return p
    }

    var body: some View {
        NavigationStack {
            List {
                verdictSection
                if !configured.sending.isEmpty { sendingSection }
                if !configured.optional.isEmpty { optionalSection }
                if !configured.blocked.isEmpty { blockedSection }
            }
            .navigationTitle("Before it sends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(configured)
                        dismiss()
                    }
                    // Disabled rather than hidden: a missing button is a
                    // mystery, a greyed one with a reason above it is an answer.
                    .disabled(!configured.isUsable)
                }
            }
        }
    }

    // MARK: Sections

    private var verdictSection: some View {
        Section {
            Text(configured.verdict)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if configured.isUsable {
                Text("Sending \(bytes(configured.bytesSending)) to Anthropic.")
                    .font(.caption).foregroundStyle(Color.dim)
            }
        } footer: {
            Text("Anthropic receives this text and returns a written verdict and "
                 + "proposed changes. Nothing is sent until you tap Send, and "
                 + "nothing about this window is sent again afterwards.")
                .font(.caption2)
        }
    }

    private var sendingSection: some View {
        Section("Would be sent") {
            ForEach(configured.sending) { s in row(s, state: .sending) }
        }
    }

    private var optionalSection: some View {
        Section {
            ForEach(configured.optional) { s in
                Toggle(isOn: binding(for: s.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.subheadline)
                        Text(s.what).font(.caption2).foregroundStyle(Color.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(s.sourceLabel) · \(bytes(s.byteCount))")
                            .font(.caption2).foregroundStyle(Color.dim.opacity(0.8))
                    }
                }
            }
        } header: {
            Text("Your choice")
        } footer: {
            Text("Off by default. The analysis works without these; they are "
                 + "included only if you decide they should be.")
                .font(.caption2)
        }
    }

    private var blockedSection: some View {
        Section {
            ForEach(configured.blocked) { s in row(s, state: .blocked) }
        } header: {
            Text("Cannot be sent")
        } footer: {
            Text("These are computed from Strava activities. Sub4 is not "
                 + "permitted to pass them to an AI provider, and will not send "
                 + "the rest without them — a verdict built on what is left "
                 + "would be a guess wearing the same words.")
                .font(.caption2)
        }
    }

    // MARK: A row

    private enum RowState { case sending, blocked }

    private func row(_ s: PayloadSection, state: RowState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.title).font(.subheadline)
                    .foregroundStyle(state == .blocked ? Color.dim : Color.ink)
                Spacer()
                Text(bytes(s.byteCount)).font(.caption2)
                    .foregroundStyle(Color.dim.opacity(0.8))
            }
            Text(s.what).font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text(s.sourceLabel).font(.caption2)
                .foregroundStyle(Color.dim.opacity(0.8))
            if case .blocked(let why) = s.inclusion {
                Text(why).font(.caption2).foregroundStyle(Color.accent4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { optedIn.contains(id) },
                set: { on in
                    if on { optedIn.insert(id) } else { optedIn.remove(id) }
                })
    }

    private func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
