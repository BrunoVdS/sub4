//
//  DataLifecycleView.swift
//  Sub4
//
//  The inventory from DataLifecycle, shown to the person it is about —
//  patch 180, plan step 2.1.4.
//
//  ONE SOURCE, TWO READERS. The pane renders `DataLifecycle.entries` directly
//  rather than restating it in prose. A privacy screen written by hand beside a
//  privacy model is two documents that will disagree, and PRIV-01 is the
//  finding that this app's disclosures already disagree with its behaviour.
//  Rendering the model means the screen cannot drift from what the tests assert.
//
//  THE GAPS ARE SHOWN ON INTERNAL BUILDS ONLY, and that is a real decision
//  rather than a hedge. `gaps` exists so the inventory can be honest about
//  where the app falls short — no file protection, retention beyond what the
//  policy allows, a cache with no delete path. That belongs in front of whoever
//  is fixing it. In a shipped build the same list would be a catalogue of
//  weaknesses printed for anyone who opens Settings, which is a different
//  document with a different audience. The data always carries them; the UI
//  shows them where they are actionable.
//

import SwiftUI

struct DataLifecycleView: View {

    @State private var expanded: Set<String> = []

    var body: some View {
        Section {
            ForEach(DataLifecycle.entries, id: \.category.id) { entry in
                row(entry)
            }
        } header: {
            Text("What Sub4 holds")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(DataLifecycle.summary)
                #if DEBUG
                if !DataLifecycle.allGaps.isEmpty {
                    Text("\(DataLifecycle.allGaps.count) known gaps between this "
                         + "description and current behaviour, listed in the rows "
                         + "above. Internal builds only.")
                        .foregroundStyle(Color.accent4.opacity(0.9))
                }
                #endif
                Text("Full detail: docs/STRAVA-DATA-FLOW-INVENTORY.md in the project.")
                    .foregroundStyle(Color.dim.opacity(0.8))
            }
            .font(.caption2)
        }
    }

    // MARK: A row

    /// Collapsed to a line and a sentence; the rest on tap. Thirteen categories
    /// each stating source, purpose, storage, retention, recipients and a
    /// deletion rule is a wall of text nobody reads, and an unread disclosure
    /// is not a disclosure.
    private func row(_ e: DataCategoryEntry) -> some View {
        let isOpen = expanded.contains(e.category.rawValue)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(e.category.rawValue) }
                    else { expanded.insert(e.category.rawValue) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                        Text(sourceLine(e)).font(.caption2)
                            .foregroundStyle(Color.dim)
                    }
                    Spacer(minLength: 8)
                    if !e.sharedWith.isEmpty {
                        // The one fact worth surfacing before a tap: whether
                        // this category has ever left the phone.
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2).foregroundStyle(Color.accent4)
                    }
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(Color.dim.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { detail(e) }
        }
        .padding(.vertical, 2)
    }

    private func sourceLine(_ e: DataCategoryEntry) -> String {
        let sources = DataSource.allCases
            .filter { e.lineage.contains($0) }
            .map(\.label)
            .joined(separator: " + ")
        return sources + " · " + e.retention.label
    }

    @ViewBuilder
    private func detail(_ e: DataCategoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(e.whatItIs).font(.caption).foregroundStyle(Color.ink.opacity(0.85))

            field("Why", e.purpose)
            field("Where", e.storage.map(\.label).joined(separator: "\n"))

            if e.sharedWith.isEmpty {
                field("Shared with", "Nobody. This has never left your phone.")
            } else {
                field("Shared with", e.sharedWith.joined(separator: "\n"))
            }

            field("Deleting it", e.deletionRule)

            #if DEBUG
            if !e.gaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Known gaps", systemImage: "exclamationmark.triangle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accent4)
                    ForEach(e.gaps, id: \.self) { g in
                        Text("• " + g)
                            .font(.caption2)
                            .foregroundStyle(Color.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
            #endif
        }
        .padding(.leading, 2)
        .padding(.bottom, 4)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                .foregroundStyle(Color.dim.opacity(0.8))
            Text(value)
                .font(.caption2)
                .foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
