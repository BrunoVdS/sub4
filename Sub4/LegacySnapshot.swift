//
//  LegacySnapshot.swift
//  Sub4
//
//  The protected snapshot — step 3.3, patch 247, migration contract item 3,
//  ADR-0003 §12.14.
//
//  THE CONTRACT SENTENCE THIS FILE EXISTS FOR
//  ------------------------------------------
//  "Copy every legacy input unchanged into a dated protected snapshot. Record
//  path, byte count, and SHA-256 before decoding."
//
//  It has been outstanding since the migration began, and it is the single
//  most expensive omission in this project so far. Two reinstalls in one week
//  destroyed `notes.json`, `weather.json`, the UserDefaults gates and the
//  HealthKit authorisation. Four notes and 575 weather readings were recovered
//  only because the weather could be re-fetched; the notes could not, and were
//  re-typed. A snapshot taken before the first import would have made both a
//  copy operation instead of a loss.
//
//  WHAT IT REFUSES TO DO
//  ---------------------
//  COPY, NEVER MOVE. The legacy stores keep working during and after a
//  snapshot, and contract item 12 keeps them for at least one proven release
//  window. Nothing here removes or renames a byte the athlete owns.
//
//  A MISSING FILE IS RECORDED AS MISSING. Not skipped. `notes.json` absent
//  from a fresh install and `notes.json` absent because something deleted it
//  are the same bytes on disk and different facts, and only the manifest can
//  hold the difference. A file that simply vanishes from a list reads as a
//  file that was never expected — which is precisely how `details.json`
//  survived four versions of this app unlisted.
//
//  NOTHING IS DECODED. The snapshot runs before any store is asked what it
//  holds, because item 3 says "before decoding" and because a decoder is the
//  one thing that can turn a damaged file into an empty one.
//
//  THE SNAPSHOT IS NOT AN INPUT TO ITSELF
//  --------------------------------------
//  `snapshots/` is declared in the inventory as `AppSupportItem.snapshotDirectory`,
//  which `plan(base:items:fm:)` excludes by CASE and not by name. A name check
//  would work today and break the first time somebody renamed the folder; the
//  case cannot be got wrong, because a new snapshot location has to be spelled
//  as one to compile.
//
//  The database directory is excluded for the same reason and a different
//  argument: it is the migration's destination, not its input. Copying it into
//  a snapshot of its own inputs would double the disk cost of every capture to
//  preserve something that can be rebuilt from the very files beside it.
//
//  WHY THE HASH IS TAKEN TWICE
//  ---------------------------
//  Once on the source, before the copy, which is what the contract asks for.
//  Once on the copy, after. If they differ the entry records an error and the
//  snapshot says so, because a snapshot that silently holds a corrupted copy is
//  worse than no snapshot: it is a backup you would restore from.
//
//  WHY `nonisolated`
//  -----------------
//  This hashes and copies tens of megabytes — 800-odd files on a real device.
//  None of it may run on the main actor. Everything here is `nonisolated` and
//  takes its clock and its file manager as arguments, so a test can drive it
//  against a temporary directory with a fixed stamp and no ambient state.
//

import Foundation
import CryptoKit

// MARK: - What was found

/// One declared path, as it was at the moment of capture.
///
/// `exists == false` is a normal and expected row. Every other field is nil in
/// that case, and the absence of a hash is not a failure — it is the fact.
nonisolated struct SnapshotEntry: Codable, Hashable {
    /// The name `DataLifecycle` uses: `notes.json`, or `details` for a whole
    /// directory of per-activity files.
    let declared: String
    /// Path relative to Application Support: `details/11111111.json`.
    let relativePath: String
    let exists: Bool
    let bytes: Int?
    /// ISO-8601. The file's own modification date, which is the only thing that
    /// says WHEN this version of it was written.
    let modifiedUTC: String?
    let sha256: String?
    /// False when the file exists but the copy failed, so the manifest can
    /// distinguish "not there" from "there and not saved".
    let copied: Bool
    let error: String?

    static func missing(declared: String, relativePath: String) -> SnapshotEntry {
        .init(declared: declared, relativePath: relativePath, exists: false,
              bytes: nil, modifiedUTC: nil, sha256: nil, copied: false, error: nil)
    }
}

/// What one capture found and saved. Written to `manifest.json` beside the
/// copies, so the folder is self-describing without the app that made it.
nonisolated struct SnapshotManifest: Codable, Hashable {
    /// The folder name, which is the timestamp: `2026-08-05-141233`.
    let id: String
    let createdUTC: String
    /// Which build took it. A snapshot from a build that predates a schema
    /// change is a different artefact and has to be recognisable as one.
    let appVersion: String
    let entries: [SnapshotEntry]

    var presentCount: Int  { entries.filter(\.exists).count }
    var missingCount: Int  { entries.filter { !$0.exists }.count }
    var copiedCount: Int   { entries.filter(\.copied).count }
    var failureCount: Int  { entries.filter { $0.error != nil }.count }
    var totalBytes: Int    { entries.compactMap(\.bytes).reduce(0, +) }

    /// True only when everything that exists was copied and verified. Stated as
    /// a computed property rather than a stored flag so it cannot disagree with
    /// the rows it is derived from.
    var isComplete: Bool { failureCount == 0 && copiedCount == presentCount }

    // MARK: Which absences mean something — patch 336

    /// The declared names whose `AppSupportItem` is `.legacyFile`.
    ///
    /// DERIVED FROM THE VOCABULARY, NOT STORED ON THE ENTRY. `SnapshotEntry`
    /// is `Codable` and written to `manifest.json`, so a new field would be
    /// absent from every manifest already on disk — including the one taken on
    /// 9 August, which is the only copy this project has. The set is a pure
    /// function of `LegacyStore`, so reading it works on a manifest written
    /// before this patch existed. §12.43: do not store what the vocabulary
    /// already knows.
    static var retiredFormatNames: Set<String> {
        var names: Set<String> = []
        for store in LegacyStore.allCases {
            if case .legacyFile(let n) = store.item { names.insert(n) }
        }
        return names
    }

    /// `details.json` and `streams.json` — the pre-split monoliths, replaced by
    /// the `details/` and `streams/` directories.
    ///
    /// **THIS IS THE FLOOR OF `missingCount` AND IT CAN NEVER REACH ZERO.** An
    /// install that has never held the pre-split format cannot produce these
    /// files, so a snapshot on a perfectly healthy phone reports them absent
    /// for ever. Counting them beside three genuinely unwritten stores made
    /// "5 not present" read as five losses when it was three. §12.84.
    var retiredFormatsAbsent: Int {
        let retired = Self.retiredFormatNames
        return entries.filter { !$0.exists && retired.contains($0.declared) }.count
    }

    /// Declared, not retired, and not on disk. The number that can reach zero,
    /// and the only one worth reading as an absence.
    var storesNotWritten: Int { missingCount - retiredFormatsAbsent }

    /// The manifest, folded to one line per DECLARED path, for the redacted
    /// diagnostic paste — patch 248.
    ///
    /// WHY THIS EXISTS. Patch 247 put 1003 rows on the phone and gave the
    /// screen five numbers to show them with. "Declared but not present: 3"
    /// could not be turned into WHICH three without reading a file inside the
    /// app container, and "1003 files" could not be reconciled with 415 traces
    /// and 420 details in the database. Both questions had plausible answers
    /// and no way to check one — which is the shape of every wrong belief this
    /// project has held.
    ///
    /// WHY ONLY DECLARED NAMES. `relativePath` for a file inside `details/` is
    /// `details/18883849470.json`, and that number is a Strava activity — the
    /// athlete's history. The footer on that screen promises "no session names,
    /// no places, no dates from your history", and a list of nine hundred
    /// activity ids breaks that promise in the most literal way available.
    ///
    /// So a directory is reported as a count and a size, never as its contents.
    /// The eleven names that can appear here are fixed strings from
    /// `DataLifecycle` and describe nobody. `noPathsLeakIntoTheDiagnostic`
    /// asserts it rather than trusting this comment.
    var redactedLines: [String] {
        var lines = ["Snapshot \(id) · taken by patch \(appVersion)",
                     "  \(copiedCount) of \(presentCount) copied, "
                     + "\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)), "
                     + "\(missingCount) not present, \(failureCount) failed",
                     // PATCH 336. The split, because the total has a floor.
                     // UNCONDITIONAL, including at zero — §12.54.2. A line
                     // that appears only when a retired format is absent
                     // cannot be told from one nobody wired in, and the day
                     // this reads 0 is the day the vocabulary changed.
                     "  of those, retired formats: \(retiredFormatsAbsent) "
                     + "(cannot exist on this install)",
                     "  of those, stores not written: \(storesNotWritten)"]

        // Grouped by declared path, in the order the manifest holds them, so
        // two snapshots produce comparable pastes.
        var order: [String] = []
        var byDeclared: [String: [SnapshotEntry]] = [:]
        for e in entries {
            if byDeclared[e.declared] == nil { order.append(e.declared) }
            byDeclared[e.declared, default: []].append(e)
        }

        for name in order {
            let group = byDeclared[name] ?? []
            let present = group.filter(\.exists)
            let failed = group.filter { $0.error != nil }
            let bytes = present.compactMap(\.bytes).reduce(0, +)
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let padded = name.padding(toLength: max(18, name.count), withPad: " ", startingAt: 0)

            let state: String
            if present.isEmpty {
                state = "NOT PRESENT"
            } else if group.count == 1 {
                state = "present, \(size)"
            } else {
                // A directory. The count is the answer to "1003 files, but the
                // database imported 415 traces" — files with no matching
                // activity are the exclusion working, and this is where that
                // becomes checkable instead of arguable.
                state = "\(present.count) files, \(size)"
            }
            lines.append("  \(padded) \(state)"
                         + (failed.isEmpty ? "" : "  — \(failed.count) FAILED"))
        }
        return lines
    }

    var summary: String {
        var parts = ["\(copiedCount) file\(copiedCount == 1 ? "" : "s")",
                     ByteCountFormatter.string(fromByteCount: Int64(totalBytes),
                                               countStyle: .file)]
        if missingCount > 0 { parts.append("\(missingCount) missing") }
        if failureCount > 0 { parts.append("\(failureCount) FAILED") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Taking one

/// `nonisolated` for the same reason `AppSupportItem` is: it is thrown out of
/// nonisolated code and has to cross back to the main actor to be shown.
nonisolated enum SnapshotError: LocalizedError {
    case applicationSupportUnreachable
    case alreadyExists(String)
    case couldNotCreate(String)
    case couldNotWriteManifest(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnreachable:
            "Application Support is not reachable, so nothing could be copied."
        case .alreadyExists(let id):
            "A snapshot called \(id) already exists. Snapshots are never "
            + "overwritten — that is the point of them."
        case .couldNotCreate(let why):  "The snapshot folder could not be created: \(why)"
        case .couldNotWriteManifest(let why): "The manifest could not be written: \(why)"
        }
    }
}

enum LegacySnapshot {

    /// Under Application Support, declared in `DataLifecycle` so "Delete local
    /// data" removes it. A folder of copies of the athlete's own files that no
    /// delete flow knows about would be a privacy defect introduced by a
    /// privacy measure.
    nonisolated static let directoryName = "snapshots"

    nonisolated static var root: URL? {
        AppSupportItem.container?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: What will be captured

    /// Every file the inventory declares, expanded: a directory becomes its
    /// contents, a file becomes itself, and a declared path that is not there
    /// becomes one `exists: false` row.
    ///
    /// Sorted, so two captures of the same disk produce manifests in the same
    /// order and a diff between them is readable.
    nonisolated static func plan(base: URL,
                                 items: [AppSupportItem],
                                 fm: FileManager = .default) -> [SnapshotEntry] {
        var out: [SnapshotEntry] = []
        for item in items.sorted(by: { $0.pathComponent < $1.pathComponent }) {
            switch item {
            // The migration's destination, not its input — see the header.
            case .databaseDirectory: continue
            // Where the copies go. Excluded by case, deliberately, so this
            // cannot recurse into its own output.
            case .snapshotDirectory: continue
            case .file(let name), .legacyFile(let name):
                out.append(describe(declared: name, relative: name,
                                    url: base.appendingPathComponent(name), fm: fm))
            case .directory(let name):
                let dir = base.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    // The directory itself is the missing thing. One row, so it
                    // appears in the manifest rather than contributing nothing.
                    out.append(.missing(declared: name, relativePath: name))
                    continue
                }
                let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                if names.isEmpty {
                    // Present and empty is not the same as absent, and a
                    // directory that produced no rows would look like neither.
                    out.append(.init(declared: name, relativePath: name, exists: true,
                                     bytes: 0, modifiedUTC: nil, sha256: nil,
                                     copied: false, error: nil))
                    continue
                }
                for n in names {
                    out.append(describe(declared: name, relative: "\(name)/\(n)",
                                        url: dir.appendingPathComponent(n), fm: fm))
                }
            }
        }
        return out
    }

    /// One file, measured and hashed. Never throws: a file that cannot be read
    /// is a row with an error on it, because a capture that stops at the first
    /// unreadable file saves nothing at all.
    nonisolated static func describe(declared: String,
                                     relative: String,
                                     url: URL,
                                     fm: FileManager = .default) -> SnapshotEntry {
        guard fm.fileExists(atPath: url.path) else {
            return .missing(declared: declared, relativePath: relative)
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue
        let modified = (attrs?[.modificationDate] as? Date).map(iso8601)
        do {
            // `.mappedIfSafe` so a large file is not pulled into memory whole.
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return .init(declared: declared, relativePath: relative, exists: true,
                         bytes: bytes ?? data.count, modifiedUTC: modified,
                         sha256: hex(data), copied: false, error: nil)
        } catch {
            return .init(declared: declared, relativePath: relative, exists: true,
                         bytes: bytes, modifiedUTC: modified, sha256: nil,
                         copied: false, error: "could not read: \(error.localizedDescription)")
        }
    }

    // MARK: Taking it

    /// Copy everything the inventory declares into `snapshots/<stamp>/`, verify
    /// each copy by hash, and write the manifest beside them.
    ///
    /// `stamp` is a parameter rather than read from a clock, so a test can ask
    /// for a known folder name and so two captures in the same second cannot
    /// collide by accident — they collide by `alreadyExists`, loudly.
    ///
    /// `items` has NO default, deliberately. `DataLifecycle.appSupportItems`
    /// lives on the main actor, and a default argument is evaluated at the call
    /// site — which for this function is inside a detached task. Passing the
    /// list in forces the read to happen where it is legal and makes the
    /// dependency visible instead of hidden in a signature.
    @discardableResult
    nonisolated static func capture(stamp: String,
                                    appVersion: String,
                                    base: URL? = AppSupportItem.container,
                                    items: [AppSupportItem],
                                    fm: FileManager = .default) throws -> SnapshotManifest {
        guard let base else { throw SnapshotError.applicationSupportUnreachable }
        let snapshots = base.appendingPathComponent(directoryName, isDirectory: true)
        let folder = snapshots.appendingPathComponent(stamp, isDirectory: true)

        if fm.fileExists(atPath: folder.path) { throw SnapshotError.alreadyExists(stamp) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SnapshotError.couldNotCreate(error.localizedDescription)
        }
        // Set on the parent as well as the folder: files created inside inherit
        // the class, and the parent is what a later capture will be created in.
        FileProtection.protect(directory: snapshots, using: fm)
        FileProtection.protect(directory: folder, using: fm)

        let planned = plan(base: base, items: items, fm: fm)
        var written: [SnapshotEntry] = []
        written.reserveCapacity(planned.count)

        for entry in planned {
            guard entry.exists, entry.sha256 != nil else {
                // Missing, or unreadable and already carrying its error. Kept
                // in the manifest exactly as found.
                written.append(entry)
                continue
            }
            let source = base.appendingPathComponent(entry.relativePath)
            let destination = folder.appendingPathComponent(entry.relativePath)
            do {
                let parent = destination.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    FileProtection.protect(directory: parent, using: fm)
                }
                try fm.copyItem(at: source, to: destination)

                // The second hash. A copy that differs from its source is the
                // one failure a snapshot must never keep quiet about.
                let copiedData = try Data(contentsOf: destination, options: .mappedIfSafe)
                let copiedHash = hex(copiedData)
                if copiedHash == entry.sha256 {
                    written.append(with(entry, copied: true, error: nil))
                } else {
                    written.append(with(entry, copied: false,
                                        error: "copy hashes \(copiedHash), source hashed \(entry.sha256 ?? "—")"))
                }
            } catch {
                written.append(with(entry, copied: false,
                                    error: "copy failed: \(error.localizedDescription)"))
            }
        }

        let manifest = SnapshotManifest(id: stamp,
                                        createdUTC: stamp,
                                        appVersion: appVersion,
                                        entries: written)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: folder.appendingPathComponent("manifest.json"),
                           options: FileProtection.options)
        } catch {
            throw SnapshotError.couldNotWriteManifest(error.localizedDescription)
        }
        return manifest
    }

    // MARK: Reading them back

    /// Every snapshot on disk, newest first. A folder whose manifest will not
    /// decode is skipped rather than crashing the screen — but it still appears
    /// in `ids()`, so the difference is visible.
    nonisolated static func manifests(base: URL? = AppSupportItem.container,
                                      fm: FileManager = .default) -> [SnapshotManifest] {
        ids(base: base, fm: fm).compactMap { id in
            guard let base else { return nil }
            let url = base.appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SnapshotManifest.self, from: data)
        }
    }

    /// Folder names, newest first. The stamp sorts lexicographically into
    /// chronological order, which is the whole reason for its format.
    nonisolated static func ids(base: URL? = AppSupportItem.container,
                                fm: FileManager = .default) -> [String] {
        guard let base else { return [] }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >)
    }

    nonisolated static func latest(base: URL? = AppSupportItem.container,
                                   fm: FileManager = .default) -> SnapshotManifest? {
        manifests(base: base, fm: fm).first
    }

    // MARK: Small shared things

    /// `2026-08-05-141233` — sorts chronologically as a string, which is what
    /// `ids()` relies on, and contains nothing that needs escaping in a path.
    nonisolated static func stamp(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    nonisolated static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func with(_ e: SnapshotEntry,
                                         copied: Bool,
                                         error: String?) -> SnapshotEntry {
        .init(declared: e.declared, relativePath: e.relativePath, exists: e.exists,
              bytes: e.bytes, modifiedUTC: e.modifiedUTC, sha256: e.sha256,
              copied: copied, error: error)
    }

    private nonisolated static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
