//
//  EvidencePackageSection.swift
//  Sub4
//
//  Taking a package, and warning before it leaves — patch 446, §12.202.
//
//  **ITS OWN `View` TYPE FROM THE FIRST LINE, AND 441 IS WHY.** That patch
//  added rows to `DatabaseHealthView` as a `@ViewBuilder` function, the phone
//  crashed opening the screen (§12.76), and the fix for that then broke the row
//  above it (§12.197). CLAUDE.md §2 says adding to that screen is a structural
//  change rather than an edit. This is the structure, up front.
//
//  THE ORDER OF THE THREE PRESSES IS THE DESIGN
//  --------------------------------------------
//  1. **Take an evidence package…** — opens the warning. Takes nothing yet.
//  2. **Take it** — only after the warning has been on screen. The capture runs
//     off the main actor with the barrier held.
//  3. **Send it…** — packs and opens the share sheet, and is only offered once
//     a package exists.
//
//  A single button that captured and shared would put the most sensitive file
//  this app can produce one tap from AirDrop.
//

import SwiftUI

struct EvidencePackageSection: View {

    /// **PRESENTED BY THE SCREEN, NOT BY THIS SECTION — patch 448b, §12.206.**
    ///
    /// `DatabaseHealthView` carries a comment from patch 332 saying exactly
    /// this: *presentation modifiers live at the container, because a sheet
    /// presented from inside a `List` row is presented from a view the list is
    /// free to recycle.* 446 attached `.sheet` to this Section anyway, and on
    /// the device pressing Send closed the whole Database screen — the row went
    /// away and took the presentation with it. The item is handed up instead.
    @Binding var shared: ShareItem?

    enum Stage: Equatable {
        case idle
        case warning
        case working(String)
        /// **BUSY, BUT NOT STOPPABLE — patch 449.**
        ///
        /// Packing a 60 MB package into a zip and removing one are both
        /// seconds of file work, and both ran on the main actor: the screen
        /// simply froze, which reads as a crash rather than as work. A capture
        /// gets `working` and a Stop; these get a spinner and no button,
        /// because `NSFileCoordinator` has no honest mid-way stop and a button
        /// that cannot do what it says is worse than none (§12.205).
        case busy(String)
        case done(String)
        /// **ITS OWN CASE, BECAUSE THE COLOUR WAS ARGUING WITH THE WORDS.**
        /// A cancellation went to `.failed` and rendered in red under the
        /// sentence "Nothing was left behind." Somebody who changed their mind
        /// has not had a failure, and 448 exists to say so — §12.15 in a
        /// colour. Patch 448b.
        case stopped(String)
        case failed(String)
    }

    @State private var stage: Stage = .idle
    @State private var packages: [String] = EvidencePackage.ids(base: AppSupportItem.container)
    @State private var work: Task<Void, Never>?
    /// **NOT `Task.isCancelled` — see `CaptureStop`.** The work runs in a
    /// detached task, which does not inherit cancellation, so the flag has to
    /// be something both ends hold.
    @State private var stop = CaptureStop()
    @State private var expanded: Set<String> = []

    var body: some View {
        Section {
            // UNCONDITIONAL. A package is a copy of everything this app holds,
            // so how many are on the phone is a fact its owner is entitled to
            // see without pressing anything.
            LabeledContent("Evidence packages",
                           value: EvidencePackage.line(base: AppSupportItem.container))
                .font(.caption2)
                .foregroundStyle(packages.isEmpty ? Color.dim : Color.accent4)

            if ReleaseGates.isInternalBuild {
                controls
                existing
            }
        } header: {
            Text("Starting evidence")
        } footer: {
            Text("A package is one folder holding a verified copy of every file "
               + "the app has written, a copy of the database taken at a single "
               + "instant, and a record binding the two. It is made only when "
               + "you ask, and it is checked off this phone by "
               + "scripts/validate-evidence-package.py in the project.")
                .font(.caption2)
        }
    }

    // MARK: The three presses

    @ViewBuilder
    private var controls: some View {
        switch stage {
        case .idle:
            Button("Take an evidence package…") { stage = .warning }
                .font(.caption)

        case .warning:
            // **BEFORE, NOT IN A FOOTNOTE AFTERWARDS.** The protection this app
            // applies ends the moment the file leaves it, and the only honest
            // place to say so is above the button that starts it.
            Text(EvidencePackageShare.warningTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accent4)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(EvidencePackageShare.warningLines.enumerated()), id: \.offset) { _, line in
                Text("  " + line)
                    .font(.caption2).foregroundStyle(Color.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Take it") { take() }
                .font(.caption.weight(.semibold))
            Button("Not now") { stage = .idle }
                .font(.caption)

        case .busy(let what):
            HStack {
                ProgressView()
                Text(what).font(.caption)
            }

        case .working(let what):
            HStack { ProgressView(); Text(what).font(.caption) }
            // **IT SAYS IT REGISTERED — patch 448, and the device is why.**
            //
            // `cancel()` changes nothing visible, and the next checkpoint can
            // be seconds away, so the section looked identical whether the tap
            // had landed or not. On 22 August that read as a dead button and
            // three captures ran to completion. §12.15 in a control rather
            // than a diagnostic: a press that cannot be seen to have worked
            // will be pressed again, or given up on.
            Button("Stop", role: .destructive) {
                stage = .working("Stopping at the next safe point…")
                stop.stop()
                work?.cancel()
            }
            .font(.caption)
            .disabled(what.hasPrefix("Stopping"))

        case .done(let line), .stopped(let line), .failed(let line):
            Text("  " + line)
                .font(.caption2)
                .foregroundStyle({ if case .failed = stage { Color.red } else { Color.dim } }())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Done") { stage = .idle }
                .font(.caption)
        }
    }

    @ViewBuilder
    private var existing: some View {
        ForEach(packages, id: \.self) { id in
            Button(expanded.contains(id) ? "\(id) — delete it?" : id) {
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            }
            .font(.caption)
            if expanded.contains(id) {
                Button("Send \(id)…") { send(id) }
                    .font(.caption.weight(.semibold))
                // A package is a copy of everything, so deleting one loses
                // nothing — the live data it was taken from is untouched.
                Button("Delete \(id)", role: .destructive) { delete(id) }
                    .font(.caption)
            }
        }
    }

    // MARK: Doing it

    private func take() {
        guard let container = AppSupportItem.container,
              let database = Sub4Launch.shared.database else {
            stage = .failed("Application Support or the database is unreachable.")
            return
        }
        guard let hold = EvidenceBarrier.beginHold() else {
            stage = .failed(EvidenceBarrier.Refusal
                .alreadyHeld(since: EvidenceBarrier.iso8601(Date())).line)
            return
        }
        // READ ON THE MAIN ACTOR, where the inventory and the defaults live.
        // Inside the detached task below they would not be reachable — the
        // mistake `LegacySnapshot.capture`'s `items` parameter exists to stop.
        let items = DataLifecycle.appSupportItems
        let keys = DataLifecycle.preferenceKeys
        let version = AppVersion.patchLabel
        let short = AppVersion.short
        let configuration = AppVersion.configuration
        // READ HERE TOO. `AppVersion.patch` and `.revision` are main-actor
        // properties, and a `@Sendable` closure cannot reach them — SE-0434's
        // rule, arriving as a warning rather than as a crash for once.
        let patch = AppVersion.patch
        let revision = AppVersion.revision
        let provenance = ReleaseGates.distributionLabel
        let artifacts = LegacyFileTest.inventory(in: container)
        let record = EvidencePackage.BarrierRecord(
            writersAskedToWait: EvidenceBarrier.Writer.asked.map(\.rawValue),
            writersDetectedOnly: EvidenceBarrier.Writer.detectedOnly.map(\.rawValue),
            turnedAwayDuringCapture: Dictionary(
                uniqueKeysWithValues: EvidenceBarrier.refusals.map { ($0.key.rawValue, $0.value) }),
            notWatched: EvidencePackage.notWatchedWhy.keys.sorted(),
            notWatchedWhy: EvidencePackage.notWatchedWhy)
        let supplement = try? LegacySnapshot.preferenceSupplement(
            keys: keys,
            values: Bundle.main.bundleIdentifier
                .flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
                ?? UserDefaults.standard.dictionaryRepresentation())
        let now = Date()

        stage = .working("Taking a package…")
        let stop = CaptureStop()
        self.stop = stop
        work = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                EvidencePackage.write(
                    hold: hold, database: database, base: container,
                    allItems: items, preferenceKeys: keys,
                    defaults: .standard,
                    identity: { id in
                        EvidencePackage.Identity(
                            captureID: id,
                            capturedUTC: EvidenceBarrier.iso8601(now),
                            app: short, patch: patch, revision: revision,
                            configuration: configuration, provenance: provenance)
                    },
                    now: now, barrierWriters: record,
                    // **PREFERENCE-INCLUSIVE, WHICH IS THE WHOLE POINT OF THE
                    // SUPPLEMENT.** `capture(at:)` derives its stamp from the
                    // same instant `EvidencePackage.write` derives the capture
                    // id from, so the two agree by construction rather than by
                    // being passed around.
                    takeSnapshot: { _ in
                        try LegacySnapshot.capture(
                            at: now, appVersion: version, base: container,
                            items: items,
                            supplements: supplement.map { [$0] } ?? []).manifest
                    },
                    // THE TASK'S OWN CANCELLATION, checked between stages by
                    // `EvidencePackage.write`. Stopping mid-file would leave a
                    // partial one; stopping between stages leaves a folder the
                    // writer then removes whole.
                    // **THE SHARED FLAG, NOT THIS TASK'S OWN.** A detached
                    // task does not inherit cancellation, so `Task.isCancelled`
                    // here is always false — 448's checkpoint read it and could
                    // never fire. §12.205, RULE 18.
                    shouldCancel: { stop.isStopped },
                    artifacts: artifacts,
                    snapshotsRoot: container.appendingPathComponent(
                        LegacySnapshot.directoryName, isDirectory: true))
            }.value

            // **ON EVERY PATH.** A barrier left up stops the sync, the backfill
            // and the background refresh for the rest of the launch.
            EvidenceBarrier.endHold()
            switch outcome {
            case .success(let manifest):
                stage = .done("\(manifest.identity.captureID) — "
                            + "\(manifest.snapshotCopy.count) files and a database "
                            + "copy of \(manifest.database.bytes) bytes, "
                            + "\(manifest.database.tables.count) tables. "
                            + "Send it from the list below.")
            case .failure(.cancelled(let after)):
                // NOT `.failed`. See `Stage.stopped`.
                stage = .stopped(EvidencePackage.Failure.cancelled(after: after).line)
            case .failure(let why):
                stage = .failed(why.line)
            }
            packages = EvidencePackage.ids(base: AppSupportItem.container)
            work = nil
        }
    }

    /// **OFF THE MAIN ACTOR, AND IT SAYS SO — patch 449.**
    ///
    /// Zipping sixty megabytes took seconds on the main actor, so the screen
    /// froze with no indication that anything was happening. A frozen screen
    /// reads as a crash: the athlete presses again, or gives up. Same shape as
    /// 448's invisible Stop — **work that cannot be seen has not been
    /// communicated**, whatever it is doing underneath.
    private func send(_ id: String) {
        guard let container = AppSupportItem.container else { return }
        let package = container
            .appendingPathComponent(EvidencePackage.directoryName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
        stage = .busy("Packing \(id) to send…")
        work = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                EvidencePackageShare.zip(packageAt: package, captureID: id,
                                         into: temporary)
            }.value
            switch outcome {
            case .success(let url):
                shared = ShareItem(url: url)
                stage = .idle
            case .failure(let why):
                stage = .failed(why.line)
            }
            work = nil
        }
    }

    /// Removing 1,381 files is the same story, one order of magnitude down.
    private func delete(_ id: String) {
        guard let container = AppSupportItem.container else { return }
        let package = container
            .appendingPathComponent(EvidencePackage.directoryName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        expanded.remove(id)
        stage = .busy("Removing \(id)…")
        work = Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try FileManager.default.removeItem(at: package); return nil }
                catch { return error.localizedDescription }
            }.value
            stage = failure.map { .failed("FAILED — \(id) could not be removed: \($0)") }
                 ?? .done("\(id) removed. The data it copied is untouched.")
            packages = EvidencePackage.ids(base: AppSupportItem.container)
            work = nil
        }
    }
}
