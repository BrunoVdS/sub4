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
//  COPY, NEVER MOVE. The live legacy stores keep working during and after a
//  snapshot, and contract item 12 keeps them for at least one proven release
//  window. Retention may remove an older verified COPY after preserving its
//  complete manifest receipt; it never removes or renames a live input.
//
//  A MISSING FILE IS RECORDED AS MISSING. Not skipped. `notes.json` absent
//  from a fresh install and `notes.json` absent because something deleted it
//  are the same bytes on disk and different facts, and only the manifest can
//  hold the difference. A file that simply vanishes from a list reads as a
//  file that was never expected — which is precisely how `details.json`
//  survived four versions of this app unlisted.
//
//  NO LEGACY FILE IS DECODED. The snapshot runs before any store is asked what
//  it holds, because item 3 says "before decoding" and because a decoder is the
//  one thing that can turn a damaged file into an empty one. UserDefaults is a
//  separate API-backed store: its declared keys are losslessly serialised into
//  `preferences.plist` because copying the physical preferences file is neither
//  scoped nor safe while the process owns it.
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
nonisolated struct SnapshotEntry: Codable, Hashable, Sendable {
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
nonisolated struct SnapshotManifest: Codable, Hashable, Sendable {
    /// The folder name, which is the timestamp: `2026-08-05-141233`.
    let id: String
    let createdUTC: String
    /// Which build took it. A snapshot from a build that predates a schema
    /// change is a different artefact and has to be recognisable as one.
    let appVersion: String
    let entries: [SnapshotEntry]

    /// `createdUTC` parsed, or nil for a manifest written before patch 338 —
    /// where the field holds `id` rather than a timestamp.
    ///
    /// NIL RATHER THAN A FALLBACK TO `id`'s TIME. The id encodes the same
    /// instant and it would parse, but a reader asking this question is asking
    /// what the manifest RECORDED, and the honest answer for an old one is that
    /// it recorded nothing. §12.15.
    var createdDate: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: createdUTC)
    }

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

/// A generated migration input that is not an Application Support file. The
/// current instance is `preferences.plist`: a filtered, lossless copy of the
/// UserDefaults keys declared by `DataLifecycle`, never the whole preferences
/// domain and never Keychain data.
nonisolated struct SnapshotSupplement: Hashable, Sendable {
    let declared: String
    let relativePath: String
    let data: Data
}

/// Small audit record retained after an old full snapshot is pruned. This is
/// not a backup: it preserves the exact manifest and its digest, but not the
/// payload bytes needed for a restore.
nonisolated struct SnapshotReceipt: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let id: String
    let capturedUTC: String
    let appVersion: String
    let copiedCount: Int
    let presentCount: Int
    let missingCount: Int
    let failureCount: Int
    let totalBytes: Int
    let manifestSHA256: String
    /// The complete per-path inventory. Keeping only its hash would prove that
    /// some bytes once existed without retaining the details Bruno asked to
    /// inspect later.
    let manifest: SnapshotManifest
    let prunedUTC: String
    let prunedByAppVersion: String
}

nonisolated struct SnapshotRetentionReport: Equatable, Sendable {
    let fullSnapshots: Int
    let receipts: Int
    let pruned: [SnapshotReceipt]
    let warnings: [String]
}

nonisolated struct SnapshotCaptureResult: Sendable {
    let manifest: SnapshotManifest
    let retention: SnapshotRetentionReport
}

// MARK: - Taking one

/// `nonisolated` for the same reason `AppSupportItem` is: it is thrown out of
/// nonisolated code and has to cross back to the main actor to be shown.
nonisolated enum SnapshotError: LocalizedError {
    case applicationSupportUnreachable
    case alreadyExists(String)
    case couldNotCreate(String)
    case couldNotWriteManifest(String)
    case invalidStamp(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnreachable:
            "Application Support is not reachable, so nothing could be copied."
        case .alreadyExists(let id):
            "A snapshot called \(id) already exists. Snapshots are never "
            + "overwritten — that is the point of them."
        case .couldNotCreate(let why):  "The snapshot folder could not be created: \(why)"
        case .couldNotWriteManifest(let why): "The manifest could not be written: \(why)"
        case .invalidStamp(let value): "\(value) is not a snapshot timestamp."
        case .unsafePath(let value): "\(value) is not a safe snapshot-relative path."
        }
    }
}

private nonisolated enum SnapshotRetentionError: LocalizedError {
    case receiptDidNotVerify(String)
    case receiptAlreadyExists(String)
    case newSnapshotDidNotReverify(String)

    var errorDescription: String? {
        switch self {
        case .receiptDidNotVerify(let id):
            "The retention receipt for \(id) did not read back exactly."
        case .receiptAlreadyExists(let id):
            "An audit receipt already reserves snapshot id \(id)."
        case .newSnapshotDidNotReverify(let id):
            "The new snapshot \(id) did not pass the independent retention re-check."
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
            // NOT A CANONICAL INPUT — patch 439, and the same argument one step
            // along. `hidden-for-test/` holds copies of the very files above,
            // so capturing it would put two versions of `athlete.json` in one
            // manifest with nothing saying which the app reads. Its own
            // path/hash/bytes inventory is what records it, in
            // `LegacyFileTest`. §12.194.
            case .internalTestArtifact: continue
            // AND THIS ONE WOULD RECURSE TWICE OVER — patch 444. A package
            // CONTAINS a snapshot, so a capture that walked into `evidence/`
            // would copy its own output, and the next capture would copy that.
            // §12.200.
            case .evidencePackage: continue
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

    /// Production entry point. One instant derives both the folder identifier
    /// and the manifest timestamp, so the two cannot drift.
    @discardableResult
    nonisolated static func capture(at capturedAt: Date,
                                    appVersion: String,
                                    base: URL? = AppSupportItem.container,
                                    items: [AppSupportItem],
                                    supplements: [SnapshotSupplement] = [],
                                    fm: FileManager = .default) throws -> SnapshotCaptureResult {
        try capture(stamp: stamp(for: capturedAt),
                    createdUTC: iso8601(capturedAt),
                    appVersion: appVersion, base: base, items: items,
                    supplements: supplements, fm: fm)
    }

    /// Compatibility helper for the existing fixed-folder tests. The timestamp
    /// is parsed from the supplied id rather than read from a second clock.
    @discardableResult
    nonisolated static func capture(stamp: String,
                                    appVersion: String,
                                    base: URL? = AppSupportItem.container,
                                    items: [AppSupportItem],
                                    fm: FileManager = .default) throws -> SnapshotManifest {
        guard let date = date(fromStamp: stamp) else {
            throw SnapshotError.invalidStamp(stamp)
        }
        return try capture(at: date, appVersion: appVersion, base: base,
                           items: items, fm: fm).manifest
    }

    /// Copy everything the inventory declares into `snapshots/<stamp>/`, verify
    /// each copy by hash, write the manifest, then apply retention.
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
    private nonisolated static func capture(stamp: String,
                                            createdUTC: String,
                                            appVersion: String,
                                            base: URL?,
                                            items: [AppSupportItem],
                                            supplements: [SnapshotSupplement],
                                            fm: FileManager) throws -> SnapshotCaptureResult {
        guard let base else { throw SnapshotError.applicationSupportUnreachable }
        let snapshots = base.appendingPathComponent(directoryName, isDirectory: true)
        let folder = snapshots.appendingPathComponent(stamp, isDirectory: true)

        if fm.fileExists(atPath: folder.path)
            || fm.fileExists(atPath: receiptURL(id: stamp, base: base).path) {
            throw SnapshotError.alreadyExists(stamp)
        }

        // Resolve and validate every destination before creating the folder.
        // The production inventory is fixed code, but supplements are an API
        // boundary and no future caller should be able to escape the dated
        // folder or overwrite its manifest.
        var planned = plan(base: base, items: items, fm: fm)
        var supplementalByPath: [String: SnapshotSupplement] = [:]
        for entry in planned {
            guard payloadPathIsSafe(entry.relativePath) else {
                throw SnapshotError.unsafePath(entry.relativePath)
            }
        }
        for supplement in supplements.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard payloadPathIsSafe(supplement.relativePath) else {
                throw SnapshotError.unsafePath(supplement.relativePath)
            }
            guard supplementalByPath[supplement.relativePath] == nil,
                  !planned.contains(where: { $0.relativePath == supplement.relativePath })
            else {
                throw SnapshotError.couldNotCreate(
                    "two inputs use \(supplement.relativePath)")
            }
            supplementalByPath[supplement.relativePath] = supplement
            planned.append(.init(declared: supplement.declared,
                                 relativePath: supplement.relativePath,
                                 exists: true, bytes: supplement.data.count,
                                 modifiedUTC: createdUTC,
                                 sha256: hex(supplement.data), copied: false,
                                 error: nil))
        }
        guard Set(planned.map(\.relativePath)).count == planned.count else {
            throw SnapshotError.couldNotCreate("the source inventory contains duplicate paths")
        }
        planned.sort { $0.relativePath < $1.relativePath }

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SnapshotError.couldNotCreate(error.localizedDescription)
        }
        // Set on the parent as well as the folder: files created inside inherit
        // the class, and the parent is what a later capture will be created in.
        FileProtection.protect(directory: snapshots, using: fm)
        FileProtection.protect(directory: folder, using: fm)

        var written: [SnapshotEntry] = []
        written.reserveCapacity(planned.count)

        for entry in planned {
            guard entry.exists else {
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

                if let supplement = supplementalByPath[entry.relativePath] {
                    try supplement.data.write(to: destination,
                                              options: FileProtection.options)
                } else {
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: source.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        // A declared empty directory is a real input. The old
                        // path left it `copied == false`, making an otherwise
                        // healthy snapshot permanently incomplete.
                        try fm.createDirectory(at: destination,
                                               withIntermediateDirectories: true)
                        FileProtection.protect(directory: destination, using: fm)
                        written.append(with(entry, copied: true, error: nil))
                        continue
                    }
                    guard entry.sha256 != nil else {
                        written.append(entry)
                        continue
                    }
                    try fm.copyItem(at: source, to: destination)
                }

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

        // PATCH 338 — `createdUTC` NOW HOLDS A UTC TIMESTAMP.
        //
        // It held `stamp` from the day it was written, so `id` and `createdUTC`
        // were the same string — `"2026-08-09-143235"` — in every manifest on
        // disk. The field name promised ISO-8601 and delivered a folder name,
        // which is §12.48's "a timestamp that is a name is not a time" arriving
        // from the other direction.
        //
        // THE KEY IS NOT RENAMED. Four manifests already on disk carry it, one
        // of them the only copy of stores this project has already lost once,
        // and `SnapshotManifest` is `Codable` with a non-optional field: a
        // rename makes every existing manifest undecodable. Old manifests keep
        // decoding, their value is simply the id — which `createdDate` reads
        // back as nil rather than as a wrong date.
        let manifest = SnapshotManifest(id: stamp,
                                        createdUTC: createdUTC,
                                        appVersion: appVersion,
                                        entries: written)
        // THE PRUNE RIDES ALONG — patch 338, and for `MigrationLedger`'s reason
        // (§12.59.6): a step that can be skipped without symptom will be. A
        // caller that forgot to prune would produce a phone that fills up and
        // a screen that says nothing is wrong.
        //
        // GUARDED ON `isComplete`, which is `failureCount == 0 && copiedCount
        // == presentCount` — every file that existed was copied AND its copy
        // re-hashed to the same value. Pruning on anything weaker would remove
        // a good snapshot on the strength of a bad one.
        //
        // AFTER the manifest is written, so a crash between the two leaves the
        // old copies intact rather than leaving no readable snapshot at all.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: folder.appendingPathComponent("manifest.json"),
                           options: FileProtection.options)
        } catch {
            throw SnapshotError.couldNotWriteManifest(error.localizedDescription)
        }
        let retention = manifest.isComplete
            ? enforceRetention(protectedID: manifest.id,
                               appVersion: appVersion, base: base, fm: fm)
            : retentionReport(base: base, fm: fm)
        return SnapshotCaptureResult(manifest: manifest, retention: retention)
    }

    // MARK: Retention — patch 338

    /// How many complete snapshots keep their payload files. Older verified
    /// copies become compact audit receipts; incomplete/unreadable folders are
    /// preserved rather than counted as safe fallbacks.
    ///
    /// TWO, NOT ONE, AND THE REASON IS THE SEQUENCE RATHER THAN THE SIZE. The
    /// obvious policy — delete the previous snapshot as the new one is written
    /// — destroys the only good copy at the exact moment the new one is
    /// unproven. A phone that runs out of disk halfway through 958 files would
    /// be left with a half-written snapshot and nothing behind it, and this
    /// project has already lost every store once.
    ///
    /// So: prune AFTER `isComplete`, and keep the one before it. On 9 August
    /// four snapshots held 40.6 MB against a 27 MB database and 14 MB of live
    /// stores — two of them byte-identical, taken fifty-eight seconds apart —
    /// and nothing in this file removed anything. §12.86.
    nonisolated static let keepSnapshots = 2
    /// Full manifests are roughly 300 KB for the current 958-file package.
    /// Keeping them all would merely replace one unbounded store with a slower
    /// one, so audit history has its own explicit ceiling.
    nonisolated static let keepReceipts = 20
    nonisolated static let receiptSchemaVersion = 2

    private nonisolated static let receiptPrefix = "receipt-"

    nonisolated static func hasReceipt(_ id: String,
                                       base: URL? = AppSupportItem.container,
                                       fm: FileManager = .default) -> Bool {
        guard let base else { return false }
        return fm.fileExists(atPath: receiptURL(id: id, base: base).path)
    }

    /// Retain two VERIFIED full snapshots: the capture that triggered cleanup
    /// and the newest other verified copy. Incomplete and undecodable folders
    /// are not candidates and are never deleted. Before a
    /// full folder is removed, a small receipt is atomically written and read
    /// back byte-for-byte. Any problem leaves the full folder in place and is
    /// returned as a non-fatal warning beside the successful new capture.
    @discardableResult
    nonisolated static func enforceRetention(
        keeping: Int = keepSnapshots,
        protectedID: String? = nil,
        appVersion: String,
        base: URL? = AppSupportItem.container,
        fm: FileManager = .default
    ) -> SnapshotRetentionReport {
        guard let base else {
            return .init(fullSnapshots: 0, receipts: 0, pruned: [],
                         warnings: ["Application Support was unavailable for retention."])
        }
        let verified = verifiedFullSnapshots(base: base, fm: fm)
        var pruned: [SnapshotReceipt] = []
        var warnings: [String] = []

        // PATCH 339. Folders 338b emptied are adopted into receipts before the
        // candidates are chosen; they are invisible to `verifiedFullSnapshots`
        // by construction and would otherwise never be reachable again.
        warnings += adoptFoldersPrunedBeforeReceipts(appVersion: appVersion,
                                                     base: base, fm: fm)

        // A capture may have an id older than folders already on disk if the
        // device clock was corrected or a future-dated backup was restored.
        // The snapshot that triggered retention is always one of the retained
        // copies, independent of lexical ordering. If it cannot be reverified,
        // delete nothing.
        if let protectedID,
           !verified.contains(where: { $0.id == protectedID }) {
            warnings.append(
                SnapshotRetentionError.newSnapshotDidNotReverify(protectedID)
                    .localizedDescription)
            return retentionReport(base: base, fm: fm, warnings: warnings)
        }

        var retained = Set<String>()
        if let protectedID { retained.insert(protectedID) }
        let otherSlots = max(0, max(0, keeping) - retained.count)
        for candidate in verified where candidate.id != protectedID {
            if retained.count >= otherSlots + (protectedID == nil ? 0 : 1) { break }
            retained.insert(candidate.id)
        }

        for candidate in verified where !retained.contains(candidate.id) {
            let capturedUTC = candidate.manifest.createdDate.map(iso8601)
                ?? date(fromStamp: candidate.id).map(iso8601)
                ?? candidate.manifest.createdUTC
            let receipt = SnapshotReceipt(
                schemaVersion: receiptSchemaVersion,
                id: candidate.id,
                capturedUTC: capturedUTC,
                appVersion: candidate.manifest.appVersion,
                copiedCount: candidate.manifest.copiedCount,
                presentCount: candidate.manifest.presentCount,
                missingCount: candidate.manifest.missingCount,
                failureCount: candidate.manifest.failureCount,
                totalBytes: candidate.manifest.totalBytes,
                manifestSHA256: hex(candidate.manifestData),
                manifest: candidate.manifest,
                prunedUTC: iso8601(Date()),
                prunedByAppVersion: appVersion)
            let receiptURL = receiptURL(id: candidate.id, base: base)

            do {
                guard !fm.fileExists(atPath: receiptURL.path) else {
                    throw SnapshotRetentionError.receiptAlreadyExists(candidate.id)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let receiptData = try encoder.encode(receipt)
                try receiptData.write(to: receiptURL, options: FileProtection.options)
                let readBack = try Data(contentsOf: receiptURL)
                let decoded = try JSONDecoder().decode(SnapshotReceipt.self,
                                                       from: readBack)
                guard readBack == receiptData, decoded == receipt else {
                    throw SnapshotRetentionError.receiptDidNotVerify(candidate.id)
                }
                do {
                    try fm.removeItem(at: candidate.folder)
                } catch {
                    try? fm.removeItem(at: receiptURL)
                    throw error
                }
                pruned.append(receipt)
            } catch {
                warnings.append("\(candidate.id) was kept in full: "
                                + error.localizedDescription)
            }
        }

        warnings += pruneOldReceipts(keeping: keepReceipts,
                                     base: base, fm: fm)

        return retentionReport(base: base, fm: fm,
                               pruned: pruned, warnings: warnings)
    }

    /// Delete only receipts that decode, identify their own file name, retain
    /// a manifest whose digest still agrees, and no longer have a full folder.
    /// Corrupt/unknown receipts are left for inspection and never authorise a
    /// deletion merely because their name sorts old.
    private nonisolated static func pruneOldReceipts(
        keeping: Int,
        base: URL,
        fm: FileManager
    ) -> [String] {
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        let fullIDs = Set(ids(base: base, fm: fm))
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(receiptPrefix) && $0.hasSuffix(".json") }
            .sorted(by: >)
        var verified: [(name: String, url: URL)] = []
        for name in names {
            let start = name.index(name.startIndex, offsetBy: receiptPrefix.count)
            let end = name.index(name.endIndex, offsetBy: -".json".count)
            let id = String(name[start..<end])
            let url = root.appendingPathComponent(name)
            guard !fullIDs.contains(id),
                  let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(SnapshotReceipt.self,
                                                          from: data),
                  receipt.schemaVersion == receiptSchemaVersion,
                  receipt.id == id, receipt.manifest.id == id,
                  receipt.manifestSHA256 == encodedManifestHash(receipt.manifest)
            else { continue }
            verified.append((name, url))
        }

        var warnings: [String] = []
        for receipt in verified.dropFirst(max(0, keeping)) {
            do {
                try fm.removeItem(at: receipt.url)
            } catch {
                warnings.append("Old audit receipt \(receipt.name) was kept: "
                                + error.localizedDescription)
            }
        }
        return warnings
    }

    private nonisolated static func encodedManifestHash(
        _ manifest: SnapshotManifest
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return nil }
        return hex(data)
    }

    private nonisolated struct VerifiedSnapshot {
        let id: String
        let folder: URL
        let manifest: SnapshotManifest
        let manifestData: Data
    }

    /// A manifest saying "complete" is historical evidence. Before it can
    /// justify deletion of another copy, the payload it names is re-hashed.
    /// Folders emptied by patch 338b's retention, which removed the copies and
    /// left the manifest in place with a `pruned.json` beside it.
    ///
    /// THE RECEIPT SCHEME THAT REPLACED IT CANNOT SEE THEM. `verifiedFullSnapshots`
    /// requires the payload to match the manifest, so a folder with no payload
    /// never becomes a candidate and can never be receipted. Three folders on
    /// the device sat outside both designs: counted as full, holding nothing,
    /// and unreachable by retention for ever.
    ///
    /// ABSENT IS NOT CORRUPT, AND THAT DISTINCTION IS THE SAFETY OF THIS.
    /// A folder whose copies are WRONG is evidence of corruption, and deleting
    /// it would destroy the evidence. A folder whose copies are ABSENT is a
    /// prune that completed under an older scheme and is missing only its
    /// paperwork. Only the second is adopted. The first is left in place and
    /// reported, which is the same choice `enforceRetention` makes when a
    /// receipt will not verify.
    ///
    /// The manifest is the whole record — every declared path, its size and its
    /// SHA-256 — so a receipt built from it says exactly what a receipt written
    /// at prune time would have said. Only `prunedByAppVersion` differs, and it
    /// names 338b rather than claiming this build removed copies that were
    /// already gone.
    private nonisolated static func adoptFoldersPrunedBeforeReceipts(
        appVersion: String,
        base: URL,
        fm: FileManager
    ) -> [String] {
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        var warnings: [String] = []

        for id in ids(base: base, fm: fm) {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SnapshotManifest.self,
                                                           from: data),
                  manifest.id == id
            else { continue }

            let copies = manifest.entries.filter { $0.exists && $0.copied }
            guard !copies.isEmpty else { continue }
            let present = copies.filter {
                fm.fileExists(atPath: folder
                    .appendingPathComponent($0.relativePath).path)
            }
            // Every copy still there: a live snapshot, and none of this
            // function's business.
            if present.count == copies.count { continue }
            // Some there and some not: not a completed prune. Left alone.
            if !present.isEmpty {
                warnings.append("\(id) holds \(present.count) of "
                                + "\(copies.count) copies and was left in full.")
                continue
            }

            let capturedUTC = manifest.createdDate.map(iso8601)
                ?? date(fromStamp: id).map(iso8601)
                ?? manifest.createdUTC
            let receipt = SnapshotReceipt(
                schemaVersion: receiptSchemaVersion,
                id: id,
                capturedUTC: capturedUTC,
                appVersion: manifest.appVersion,
                copiedCount: manifest.copiedCount,
                presentCount: manifest.presentCount,
                missingCount: manifest.missingCount,
                failureCount: manifest.failureCount,
                totalBytes: manifest.totalBytes,
                manifestSHA256: hex(data),
                manifest: manifest,
                prunedUTC: iso8601(Date()),
                prunedByAppVersion: "338b, adopted at \(appVersion)")
            let url = receiptURL(id: id, base: base)

            do {
                guard !fm.fileExists(atPath: url.path) else {
                    throw SnapshotRetentionError.receiptAlreadyExists(id)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let bytes = try encoder.encode(receipt)
                try bytes.write(to: url, options: FileProtection.options)
                let readBack = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(SnapshotReceipt.self,
                                                       from: readBack)
                guard readBack == bytes, decoded == receipt else {
                    throw SnapshotRetentionError.receiptDidNotVerify(id)
                }
                // The folder goes only after the receipt has been read back
                // byte for byte, and the receipt goes if the folder will not.
                do { try fm.removeItem(at: folder) }
                catch { try? fm.removeItem(at: url); throw error }
            } catch {
                warnings.append("\(id) was kept in full: "
                                + error.localizedDescription)
            }
        }
        return warnings
    }

    private nonisolated static func verifiedFullSnapshots(
        base: URL,
        fm: FileManager
    ) -> [VerifiedSnapshot] {
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        return ids(base: base, fm: fm).compactMap { id in
            let folder = root.appendingPathComponent(id, isDirectory: true)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SnapshotManifest.self,
                                                           from: data),
                  manifest.id == id, manifest.isComplete,
                  manifest.entries.contains(where: { $0.exists && $0.copied }),
                  manifestPathsAreSafeAndUnique(manifest),
                  payloadMatches(manifest, in: folder, fm: fm)
            else { return nil }
            return VerifiedSnapshot(id: id, folder: folder,
                                    manifest: manifest, manifestData: data)
        }
    }

    private nonisolated static func manifestPathsAreSafeAndUnique(
        _ manifest: SnapshotManifest
    ) -> Bool {
        let paths = manifest.entries.map(\.relativePath)
        guard Set(paths).count == paths.count else { return false }
        return paths.allSatisfy(payloadPathIsSafe)
    }

    private nonisolated static func payloadPathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path != "manifest.json" else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private nonisolated static func payloadMatches(_ manifest: SnapshotManifest,
                                                    in folder: URL,
                                                    fm: FileManager) -> Bool {
        for entry in manifest.entries where entry.exists {
            let url = folder.appendingPathComponent(entry.relativePath)
            if let expected = entry.sha256 {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      hex(data) == expected else { return false }
            } else {
                var isDirectory: ObjCBool = false
                guard entry.copied, entry.bytes == 0,
                      fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return false }
            }
        }
        return true
    }

    private nonisolated static func receiptURL(id: String, base: URL) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(receiptPrefix)\(id).json")
    }

    private nonisolated static func receiptCount(base: URL,
                                                 fm: FileManager) -> Int {
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(receiptPrefix) && $0.hasSuffix(".json") }
            .count
    }

    private nonisolated static func retentionReport(
        base: URL?,
        fm: FileManager,
        pruned: [SnapshotReceipt] = [],
        warnings: [String] = []
    ) -> SnapshotRetentionReport {
        guard let base else {
            return .init(fullSnapshots: 0, receipts: 0, pruned: pruned,
                         warnings: warnings)
        }
        return .init(fullSnapshots: ids(base: base, fm: fm).count,
                     receipts: receiptCount(base: base, fm: fm),
                     pruned: pruned, warnings: warnings)
    }

    /// What the snapshots folder costs, and how it is divided. Unconditional,
    /// including at zero — the paste is where somebody reads this and a line
    /// that vanishes when nothing is pruned cannot be told from one nobody
    /// wired in. §12.54.2.
    nonisolated static func retentionLines(base: URL? = AppSupportItem.container,
                                           fm: FileManager = .default) -> [String] {
        let all = ids(base: base, fm: fm)
        let receipts = base.map { receiptCount(base: $0, fm: fm) } ?? 0
        var bytes = 0
        if let base {
            let root = base.appendingPathComponent(directoryName, isDirectory: true)
            let w = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            while let url = w?.nextObject() as? URL {
                bytes += ((try? fm.attributesOfItem(atPath: url.path))?[.size]
                          as? Int) ?? 0
            }
        }
        return ["Full snapshot folders: \(all.count), retention target \(keepSnapshots)",
                "  audit receipts for pruned copies: \(receipts), target \(keepReceipts)",
                "  total size: "
                + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)]
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
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent(name).path,
                                 isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted(by: >)
    }

    nonisolated static func latest(base: URL? = AppSupportItem.container,
                                   fm: FileManager = .default) -> SnapshotManifest? {
        manifests(base: base, fm: fm).first
    }

    // MARK: Small shared things

    /// Losslessly serialises only the preference keys declared by the data
    /// inventory. The physical preferences plist may contain framework state
    /// and is not copied; Keychain is deliberately outside this boundary.
    @MainActor
    static func preferenceSupplement(keys: [String],
                                     values: [String: Any]) throws -> SnapshotSupplement {
        let declared = keys.sorted()
        var selected: [String: Any] = [:]
        for key in declared {
            if let value = values[key] { selected[key] = value }
        }
        let archive: [String: Any] = [
            "schemaVersion": 1,
            "declaredKeys": declared,
            "values": selected
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive,
                                                      format: .binary,
                                                      options: 0)
        return SnapshotSupplement(declared: "UserDefaults",
                                  relativePath: "preferences.plist",
                                  data: data)
    }

    /// `2026-08-05-141233` — sorts chronologically as a string, which is what
    /// `ids()` relies on, and contains nothing that needs escaping in a path.
    nonisolated static func stamp(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    nonisolated static func date(fromStamp stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.isLenient = false
        return f.date(from: stamp)
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
