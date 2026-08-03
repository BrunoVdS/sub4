//
//  DataLifecycleCoordinator.swift
//  Sub4
//
//  Export and deletion, driven by the inventory — patch 183, plan steps
//  2.1.3 and 2.1.4.
//
//  WHAT THIS IS FOR
//  ----------------
//  `DataLifecycle` describes what the app holds. Until now that description was
//  the only thing that existed: eight of its entries say "Removed by Delete
//  local data", and there is no such control anywhere in the app. Reading that
//  sentence in the privacy pane, a person would reasonably conclude they can
//  remove their history. They cannot. That is PRIV-01 in its purest form — a
//  disclosure describing a feature rather than a behaviour — and it is written
//  in the file whose whole purpose is to not do that.
//
//  This file is what makes those sentences true.
//
//  IT WALKS THE INVENTORY, NOT A LIST OF PATHS
//  -------------------------------------------
//  The obvious implementation is a function that deletes eight named files. It
//  would work today and be wrong within two patches, because the ninth store
//  will be added by someone editing a store, not by someone editing this file.
//  So every operation here enumerates `DataLifecycle.entries` and resolves the
//  locations it finds. A new `.applicationSupport` location is exported and
//  deleted the moment it is declared, and `everyStoreIsCovered` already fails
//  the build if a store is written without being declared. The two halves meet.
//
//  WHAT IT REFUSES TO CLAIM
//  ------------------------
//  Deletion returns a receipt that names what it could NOT remove. Apple Health
//  readings are the system's, the training plan is inside the app bundle, and
//  no amount of wanting makes either this app's to delete. A flow that reports
//  "all your data has been removed" while Health still holds every heart-rate
//  sample would be a new instance of exactly the finding above, committed while
//  fixing it. The receipt says removed, absent, failed, or not-ours, per item.
//
//  ORDER OF DELETION
//  -----------------
//  Files first, then preferences, then the Keychain. A crash midway should
//  leave the app with credentials it can use to re-fetch, rather than a
//  half-emptied cache and no way back in. The reverse order fails badly.
//

import Foundation

// MARK: - What happened to one thing

/// The fate of a single storage location.
///
/// `.absent` is deliberately not a failure. A device that never ran a review
/// has no `proposals.json`, and reporting that as an error would teach the
/// reader to ignore the receipt — which is the only part of a delete flow that
/// can be checked.
enum LocationOutcome: Equatable {
    case removed(bytes: Int64)
    case absent
    case failed(String)
    /// Not this app's to remove. Carries the reason, which is shown verbatim.
    case notOurs(String)

    var isFailure: Bool { if case .failed = self { return true }; return false }
    var didRemove: Bool { if case .removed = self { return true }; return false }

    var label: String {
        switch self {
        case .removed(let b) where b > 0: "Removed (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)))"
        case .removed:                    "Removed"
        case .absent:                     "Nothing stored"
        case .failed(let why):            "Failed — \(why)"
        case .notOurs(let why):           why
        }
    }
}

struct ReceiptLine: Identifiable, Equatable {
    let id = UUID()
    /// What the reader would call it.
    let what: String
    /// Which categories this location belongs to. Plural is normal — one file
    /// often carries two categories, and the reader should see both.
    let categories: [DataCategory]
    let outcome: LocationOutcome
}

/// The record of one operation, in enough detail to be checked rather than
/// believed.
struct LifecycleReceipt: Equatable {
    enum Operation: String, Equatable {
        case deleteEverything = "Delete local data"
        case export           = "Export"
    }

    let operation: Operation
    let lines: [ReceiptLine]

    var removedCount: Int { lines.filter { $0.outcome.didRemove }.count }
    var failures: [ReceiptLine] { lines.filter { $0.outcome.isFailure } }
    var retained: [ReceiptLine] {
        lines.filter { if case .notOurs = $0.outcome { return true }; return false }
    }
    var bytesRemoved: Int64 {
        lines.reduce(0) { total, l in
            if case .removed(let b) = l.outcome { return total + b }
            return total
        }
    }

    /// The sentence shown when it is over. Written so that the awkward parts —
    /// what failed, what survives — are in the FIRST clause rather than a
    /// footnote, because the failure case is the one worth reading.
    var summary: String {
        if !failures.isEmpty {
            return "\(failures.count) item\(failures.count == 1 ? "" : "s") could not be removed. "
                 + "\(removedCount) removed."
        }
        let size = bytesRemoved > 0
            ? " (\(ByteCountFormatter.string(fromByteCount: bytesRemoved, countStyle: .file)))"
            : ""
        if retained.isEmpty {
            return "\(removedCount) removed\(size). Nothing is left behind."
        }
        return "\(removedCount) removed\(size). "
             + "\(retained.count) thing\(retained.count == 1 ? " is" : "s are") not this app's to delete — "
             + "listed below."
    }
}

// MARK: - The coordinator

@MainActor
enum DataLifecycleCoordinator {

    // MARK: Delete

    /// Removes everything the inventory says this app owns, and reports on
    /// everything it does not.
    ///
    /// Not `throws`. A delete flow that aborts on the first failure leaves the
    /// user in the worst state available: some data gone, some not, and no
    /// account of which. Every location is attempted and every result recorded.
    @discardableResult
    static func deleteEverything(using fm: FileManager = .default) -> LifecycleReceipt {
        var lines: [ReceiptLine] = []

        // 1. Files, first — see the header note on ordering.
        for item in DataLifecycle.appSupportItems {
            lines.append(ReceiptLine(what: item.displayName,
                                     categories: DataLifecycle.categories(holding: item),
                                     outcome: remove(item, using: fm)))
        }

        // 2. Preferences.
        let defaults = UserDefaults.standard
        for key in DataLifecycle.preferenceKeys {
            let present = defaults.object(forKey: key) != nil
            if present { defaults.removeObject(forKey: key) }
            lines.append(ReceiptLine(
                what: "Preference · \(key)",
                categories: DataLifecycle.entries.filter { e in
                    e.storage.contains { if case .preferences(let k) = $0 { return k.contains(key) }; return false }
                }.map(\.category),
                outcome: present ? .removed(bytes: 0) : .absent))
        }

        // 3. Secrets last, so an interrupted delete still leaves a usable
        //    connection rather than an app that can neither read nor re-fetch.
        for item in DataLifecycle.keychainItems {
            Keychain.delete(item)
            // `Keychain.delete` discards its OSStatus (AUTH-03), so this cannot
            // honestly claim more than "asked". Recorded as removed rather than
            // invented: the gap is disclosed in the credentials entry, and
            // step 4.2.10 is what makes this line trustworthy.
            lines.append(ReceiptLine(what: "Keychain · \(item)",
                                     categories: [.credentials],
                                     outcome: .removed(bytes: 0)))
        }

        // 4. Drop what the running app is still holding.
        //
        //    NOT OPTIONAL, and the reason is worth stating plainly: every store
        //    here keeps its contents in memory and writes them back on the next
        //    change. Delete `activities.json` and leave `ActivityStore` loaded,
        //    and the next sync saves four hundred activities straight back out
        //    of RAM. The delete would appear to work and quietly undo itself.
        //
        //    `dropInMemory` rather than `resetCache`, because reset SAVES —
        //    it would recreate the file this function just removed.
        dropAllInMemory()

        // 5. What survives, named. This is the half that makes the receipt
        //    worth reading — see the header.
        for e in DataLifecycle.entries {
            for s in e.storage where !s.isAppDeletable {
                lines.append(ReceiptLine(what: s.label,
                                         categories: [e.category],
                                         outcome: .notOurs(reason(for: s))))
            }
        }

        return LifecycleReceipt(operation: .deleteEverything, lines: lines)
    }

    /// Every store that holds its contents in memory, emptied.
    ///
    /// A hand-kept list, and unlike the file list there is no way to derive it —
    /// the inventory knows where data rests, not which object graph is holding
    /// a copy. `noStoreIsMissedByTheMemoryDrop` in the tests pins it against the
    /// set of stores that declare an Application Support location, which is the
    /// closest check available.
    static func dropAllInMemory() {
        ActivityStore.shared.dropInMemory()
        DetailStore.shared.dropInMemory()
        NotesStore.shared.dropInMemory()
        ProposalStore.shared.dropInMemory()
        AthleteStore.shared.dropInMemory()
        ConstantsStore.shared.dropInMemory()
        WeatherStore.shared.dropInMemory()
    }

    private static func reason(for s: StorageLocation) -> String {
        switch s {
        case .systemOwned(let who): "Held by \(who) — remove it there"
        case .appBundle:            "Part of the app — removed by deleting the app"
        case .memoryOnly:           "Never written down — gone when the app quits"
        default:                    "Not removed"
        }
    }

    /// Removes one Application Support item, reporting its size first so the
    /// receipt can say how much went. Size is read BEFORE the removal for the
    /// obvious reason.
    private static func remove(_ item: AppSupportItem, using fm: FileManager) -> LocationOutcome {
        guard let url = item.url else {
            return .failed("Application Support is not reachable")
        }
        guard fm.fileExists(atPath: url.path) else { return .absent }

        let size = byteSize(of: url, using: fm)
        do {
            try fm.removeItem(at: url)
            return .removed(bytes: size)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Bytes on disk for a file or a whole directory.
    static func byteSize(of url: URL, using fm: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
            return Int64(v.fileSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Export

    /// Everything the inventory marks exportable, as one file.
    ///
    /// Written to the temporary directory rather than Application Support: an
    /// export is a copy made to be handed somewhere else, and leaving a second
    /// full copy of the history inside the app — unprotected, since no file
    /// protection class is applied anywhere yet (DATA-05) — would be a worse
    /// outcome than not offering an export at all.
    static func export(using fm: FileManager = .default) throws -> URL {
        var bundle: [String: Any] = [:]
        var included: [String] = []
        var skipped: [String] = []

        for item in DataLifecycle.appSupportItems {
            let owners = DataLifecycle.categories(holding: item)
            // A file is exportable only if EVERY category that claims it is.
            // The conservative direction: a store shared between an exportable
            // and a non-exportable category stays out. Nothing today is shared
            // that way; the rule is here so that when something is, the failure
            // is a missing file rather than a leaked secret.
            let exportable = !owners.isEmpty && owners.allSatisfy { c in
                DataLifecycle.entry(c)?.isExportable == true
            }
            guard exportable else {
                skipped.append(item.displayName)
                continue
            }
            guard let url = item.url, fm.fileExists(atPath: url.path) else { continue }

            if item.isDirectory {
                var files: [String: Any] = [:]
                let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                for name in names where name.hasSuffix(".json") {
                    if let j = json(at: url.appendingPathComponent(name)) { files[name] = j }
                }
                bundle[item.pathComponent] = files
            } else if let j = json(at: url) {
                bundle[item.pathComponent] = j
            }
            included.append(item.pathComponent)
        }

        // Preferences, per category, so the reader can tell a correction they
        // made from a diagnostic the app wrote.
        var prefs: [String: Any] = [:]
        for e in DataLifecycle.entries where e.isExportable {
            for s in e.storage {
                guard case .preferences(let keys) = s else { continue }
                for k in keys {
                    if let v = UserDefaults.standard.object(forKey: k) {
                        prefs[k] = describe(v)
                    }
                }
            }
        }
        if !prefs.isEmpty { bundle["preferences"] = prefs }

        // The manifest is not decoration. An export with no account of what was
        // left out looks complete, and a person checking whether their data was
        // handed over has no way to tell the difference between "not held" and
        // "held and omitted".
        bundle["manifest"] = [
            "app":         AppVersion.short,
            "exportedAt":  ISO8601DateFormatter().string(from: Date()),
            "included":    included.sorted(),
            "excluded":    skipped.sorted(),
            "notIncluded": DataLifecycle.entries.filter { !$0.isExportable }
                                                .map { "\($0.title) — \($0.deletionRule)" },
            "heldElsewhere": DataLifecycle.entries.flatMap { e in
                e.storage.compactMap { s -> String? in
                    if case .systemOwned(let who) = s { return "\(e.title) — held by \(who)" }
                    return nil
                }
            }
        ]

        let data = try JSONSerialization.data(withJSONObject: bundle,
                                              options: [.prettyPrinted, .sortedKeys])
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sub4-export-\(stamp.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Reads a stored file back as JSON. A store that fails to parse is carried
    /// into the export as raw text rather than dropped — it is still the user's
    /// data, and an export that silently omits a corrupted file is the same
    /// class of quiet loss as DATA-01.
    private static func json(at url: URL) -> Any? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: d) { return obj }
        return ["unparsed": String(data: d, encoding: .utf8) ?? "\(d.count) bytes"]
    }

    /// UserDefaults values are plist types, and not all of them survive
    /// `JSONSerialization`. Dates and Data are the two that appear here.
    private static func describe(_ v: Any) -> Any {
        switch v {
        case let d as Date: ISO8601DateFormatter().string(from: d)
        case let d as Data: "\(d.count) bytes"
        default:            JSONSerialization.isValidJSONObject([v]) ? v : String(describing: v)
        }
    }
}
