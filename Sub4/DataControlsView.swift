//
//  DataControlsView.swift
//  Sub4
//
//  Export and delete, in front of the person they belong to — patch 183,
//  plan steps 2.1.3 and 2.1.4.
//
//  THE CONFIRMATION STATES WHAT SURVIVES
//  -------------------------------------
//  A destructive confirmation usually asks "are you sure?" and lists nothing.
//  This one names what will still exist afterwards — Apple Health readings, the
//  bundled plan — because those are the two things a person clicking "delete my
//  data" would reasonably assume are included, and they are not. Finding that
//  out afterwards is worse than being told first, and the receipt says it again
//  after the fact so it cannot be missed.
//

import SwiftUI

struct DataControlsView: View {

    @State private var confirming = false
    @State private var receipt: LifecycleReceipt?
    @State private var shareItem: ShareItem?
    @State private var lastExport: (size: Int64, at: Date)?
    @State private var exportError: String?
    @State private var building = false
    @State private var showingReceipt = false

    /// Off by default. Sensor traces are the bulk of an export — roughly 200 KB
    /// per session once an activity has been opened, against a few kilobytes
    /// for its summary — and the least readable part of it. Opting in is a
    /// deliberate choice to wait for a large file.
    @State private var includeTraces = false

    var body: some View {
        Section {
            exportRow
            deleteRow

            if let r = receipt {
                receiptSummary(r)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("An export is a copy for you to keep. Deleting removes what this "
                 + "app stored on the phone; it does not touch anything held by "
                 + "Apple Health or by Strava's own servers.")
                .font(.caption2)
        }
        .confirmationDialog("Delete everything Sub4 stored?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete local data", role: .destructive) {
                let r = DataLifecycleCoordinator.deleteEverything()
                receipt = r
                showingReceipt = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(survivesMessage)
        }
        .sheet(isPresented: $showingReceipt) {
            if let r = receipt { ReceiptSheet(receipt: r) }
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }

    // MARK: Rows

    @ViewBuilder
    private var exportRow: some View {
        Toggle(isOn: $includeTraces) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Include sensor traces").font(.subheadline)
                Text("Heart rate, pace and elevation, sample by sample. Much "
                     + "larger and much slower to build.")
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }

        Button {
            build()
        } label: {
            HStack {
                Label("Export my data", systemImage: "arrow.down.doc")
                    .font(.subheadline)
                Spacer()
                if building { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(building)

        if let e = lastExport {
            // FEEDBACK, added in 184. The first version changed nothing visible
            // when the export succeeded a second time — same screen, same
            // labels — which is indistinguishable from a button that does not
            // work, and was reported as exactly that.
            Text("\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)) · built \(e.at.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(Color.dim)
        }

        if let e = exportError {
            Text(e).font(.caption2).foregroundStyle(Color.accent4)
        }
    }

    /// Builds, then presents the share sheet itself — one tap rather than two.
    ///
    /// `ShareSheet` rather than SwiftUI's `ShareLink`, and that is a correction:
    /// the ShareLink shipped in 183 rendered and did nothing at all when tapped.
    /// This wrapper is a `UIActivityViewController`, is what the notes CSV
    /// export has used since patch 84, and is known to work.
    private func build() {
        building = true
        exportError = nil
        Task {
            defer { building = false }
            do {
                let url = try await DataLifecycleCoordinator.export(
                    includingSensorTraces: includeTraces)
                let size = DataLifecycleCoordinator.byteSize(of: url)
                lastExport = (size, Date())
                shareItem = ShareItem(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var deleteRow: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            HStack {
                Label("Delete local data", systemImage: "trash")
                    .font(.subheadline)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func receiptSummary(_ r: LifecycleReceipt) -> some View {
        Button { showingReceipt = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.operation.rawValue).font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text(r.summary).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tap for the full receipt")
                    .font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Computed from the inventory, not written out — the list of things this
    /// app cannot delete is a property of the data, and a hand-written sentence
    /// here would be one more disclosure free to drift.
    private var survivesMessage: String {
        let elsewhere = DataLifecycle.entries.flatMap { e in
            e.storage.compactMap { s -> String? in
                if case .systemOwned(let who) = s { return "\(e.title) (held by \(who))" }
                return nil
            }
        }
        var lines = ["Everything Sub4 wrote on this phone is removed and cannot be recovered."]
        if !elsewhere.isEmpty {
            lines.append("This does NOT remove: " + elsewhere.joined(separator: ", ") + ".")
        }
        lines.append("Your Strava account and anything stored there is untouched.")
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - The receipt

/// What actually happened, line by line.
///
/// A summary alone would be the same kind of claim the app has been making all
/// along — "your data was deleted", believed because there is no way to check.
/// The lines are the way to check.
struct ReceiptSheet: View {
    let receipt: LifecycleReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(receipt.summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !receipt.failures.isEmpty {
                    Section("Could not be removed") {
                        ForEach(receipt.failures) { line in row(line) }
                    }
                }

                Section("Removed") {
                    let removed = receipt.lines.filter { $0.outcome.didRemove }
                    if removed.isEmpty {
                        Text("Nothing was stored.").font(.caption)
                            .foregroundStyle(Color.dim)
                    }
                    ForEach(removed) { line in row(line) }
                }

                let absent = receipt.lines.filter { $0.outcome == .absent }
                if !absent.isEmpty {
                    Section("Nothing was stored") {
                        ForEach(absent) { line in row(line) }
                    }
                }

                if !receipt.retained.isEmpty {
                    Section {
                        ForEach(receipt.retained) { line in row(line) }
                    } header: {
                        Text("Still exists — not this app's to delete")
                    } footer: {
                        Text("These are held by the system or shipped inside the "
                             + "app. Remove them where they live, or by deleting Sub4.")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle(receipt.operation.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ line: ReceiptLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.what).font(.caption.weight(.medium))
                .foregroundStyle(Color.ink)
            Text(line.outcome.label).font(.caption2)
                .foregroundStyle(line.outcome.isFailure ? Color.accent4 : Color.dim)
            if !line.categories.isEmpty {
                Text(line.categories.compactMap { DataLifecycle.entry($0)?.title }
                        .joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
