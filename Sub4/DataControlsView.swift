//
//  DataControlsView.swift
//  Sub4
//
//  Export and delete, in front of the person they belong to — patch 183,
//  plan steps 2.1.3 and 2.1.4.
//
//  ONE PRESENTATION MODIFIER PER VIEW — patch 185, and it is a scar.
//  ------------------------------------------------------------------
//  183 put a `.confirmationDialog` and a `.sheet` on this Section. 184 added a
//  second `.sheet` for the share item beside them, and the confirmation stopped
//  appearing: SwiftUI presents one thing at a time from a given node, and the
//  dialog silently lost. The delete then ran on the FIRST tap, with no prompt,
//  and removed 660 activities.
//
//  Nothing failed, nothing logged, and the tests could not have caught it —
//  presentation is not reachable from a unit test. The only defence is
//  structural: the destructive confirmation hangs off the destructive button
//  and nothing else, and every sheet in this file goes through a single
//  enum-driven `.sheet(item:)`. Adding a third presentation here means changing
//  that enum, which is a visible decision rather than an accident.
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

    /// Everything this view can put on screen, as one value.
    ///
    /// Two `@State` booleans and an optional, each with their own modifier, is
    /// what broke in 184. One optional and one modifier cannot race.
    private enum Presented: Identifiable {
        case share(URL)

        var id: String {
            switch self {
            case .share(let u): u.absoluteString
            }
        }
    }

    @State private var confirming = false
    @State private var presented: Presented?
    @State private var lastExport: (size: Int64, at: Date)?
    @State private var exportError: String?
    @State private var building = false

    /// Off by default. Sensor traces are the bulk of an export — roughly 200 KB
    /// per session once an activity has been opened, against a few kilobytes
    /// for its summary — and the least readable part of it. Opting in is a
    /// deliberate choice to wait for a large file.
    @State private var includeTraces = false
    @State private var clearedWeather = false

    var body: some View {
        Section {
            exportRow
            weatherRow
            deleteRow

            // From the log, not from @State. The delete tears this view's
            // state down as a side effect of removing the @AppStorage keys —
            // see LifecycleLog.
            if let r = LifecycleLog.shared.last {
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
        // THE ONLY presentation modifier on this Section. The confirmation
        // lives on the delete button itself — see the header.
        .sheet(item: $presented) { what in
            switch what {
            case .share(let url): ShareSheet(items: [url])
            }
        }
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
                presented = .share(url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// The one concrete item left in plan step 2.1.6. `WeatherStore` has had a
    /// `resetCache()` with no caller since it was written, so the inventory said
    /// the cache could not be cleared from inside the app — a gap closed by
    /// giving the function a button rather than by building a retention sweep
    /// with nothing to sweep. Every other category's retention is indefinite,
    /// and the one that should not be — Strava's seven days — cannot be enforced
    /// before Phase 4A without emptying the app.
    ///
    /// Its own property rather than a second view inside `deleteRow`, which is
    /// not a `@ViewBuilder` and would not have compiled.
    ///
    /// **AND 374 MADE THAT MISTAKE HERE, THREE LINES BELOW THIS SENTENCE.**
    /// A caption was appended beside the button, which is two statements in a
    /// body that had one and no builder to combine them. The attribute is what
    /// the note above was pointing at; `importSection` and
    /// `weatherGearReadBackSection` have carried it all along. §12.118.7.
    @ViewBuilder
    private var weatherRow: some View {
        Button {
            WeatherStore.shared.resetCache()
            clearedWeather = true
        } label: {
            HStack {
                Label(clearedWeather ? "Weather cache cleared" : "Clear cached weather",
                      systemImage: "cloud.sun")
                    .font(.subheadline)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(clearedWeather)

        // PATCH 374. This button DELETES weather.json, and since 374 the
        // database can put it back — so the two facts are one sentence apart
        // rather than two screens apart. Somebody clearing the cache to fix a
        // problem should not have to already know the repair exists.
        Text("Cleared weather is re-fetched as you browse. Readings already "
             + "copied to the database can be put back at once, under "
             + "Weather and gear on Database health.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        // Attached HERE, to the button that triggers it, and not to the
        // Section. On the Section it competed with two sheets and lost.
        //
        // `.alert` rather than `.confirmationDialog` — patch 186. iOS rendered
        // the dialog as an anchored popover, and in that presentation the
        // `.cancel` role button is DROPPED: the only button on screen was the
        // destructive one, and the way out was tapping the dimmed area, which
        // nothing tells you. An alert shows both buttons in every size class.
        .alert("Delete everything Sub4 stored?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { performDelete() }
        } message: {
            Text(survivesMessage)
        }
    }

    /// Separated from the dialog so there is exactly one call site for the
    /// destructive operation in this file, and it is greppable.
    private func performDelete() {
        let r = DataLifecycleCoordinator.deleteEverything()
        // NEXT RUN LOOP, deliberately. Removing the display preferences
        // invalidates every `@AppStorage` binding in Settings at once, and a
        // sheet presented in the same turn is dismissed by the rebuild that
        // follows. Letting the rebuild happen first, then presenting, is the
        // difference between a receipt you can read and one that flashes.
        //
        // And if it is torn down anyway, nothing is lost: the summary row above
        // reads from `LifecycleLog`, so the receipt is one tap away for as long
        // as the app is running.
        // Nothing to present here. `deleteEverything` records into
        // `LifecycleLog`, and the root presents it — see ContentView.
        _ = r
    }

    private func receiptSummary(_ r: LifecycleReceipt) -> some View {
        Button { LifecycleLog.shared.showLast() } label: {
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
                        // WORDED BY OPERATION — patch 189. The summary line was
                        // fixed for disconnects in 187 and this header was not,
                        // so a disconnect receipt filed your own session notes
                        // under "not this app's to delete". Wrong twice: they
                        // are not held by anyone else, and the app could delete
                        // them perfectly well — it chose not to, which is the
                        // entire difference between a disconnect and a delete.
                        Text(receipt.operation == .disconnectStrava
                             ? "Kept — still here after disconnecting"
                             : "Still exists — not this app's to delete")
                    } footer: {
                        Text(receipt.operation == .disconnectStrava
                             ? "These did not come from Strava, or are yours regardless "
                             + "of where they came from. Delete local data removes them."
                             : "These are held by the system or shipped inside the "
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
