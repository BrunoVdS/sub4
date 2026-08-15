//
//  AuthoredExport.swift
//  Sub4
//
//  The files that cannot be re-fetched, in one document that can leave the
//  phone — patch 341, Stage A1 item 5, ADR-0003 §12.89.
//
//  THE SENTENCE THIS FILE EXISTS FOR
//  ---------------------------------
//  *"A snapshot inside the app container is recovery input, not an off-device
//  backup."*
//
//  On 9 August 2026 the app was deleted by hand during a crash loop. It took
//  `notes.json` — thirteen months of what the athlete thought after each
//  session — and `commutes.json`, which is the only source the `correction`
//  table has. Both were also inside the protected snapshot, and the snapshot
//  was inside the container the delete removed. The protection worked exactly
//  as designed and protected nothing, because everything it protected lived in
//  the same place as the thing it was protecting against.
//
//  Strava sent the activities back. It cannot send these.
//
//  WHAT IT EXPORTS, AND WHY NOT EVERYTHING
//  ---------------------------------------
//  Five files, all small, all authored or configured rather than fetched:
//
//    · `notes.json`      — the sessions and what they felt like
//    · `commutes.json`   — the athlete's own answer about each ride
//    · `proposals.json`  — every review that has been run, with its evidence
//    · `athlete.json`    — gear, zones, FTP
//    · `constants.json`  — the physiological constants
//
//  `activities.json`, `weather.json`, `details/` and `streams/` are absent on
//  purpose: they are 19 MB of things a source can send again, and including
//  them would make this an export nobody presses. The complete artefact is the
//  database, and the way to take that off the phone is a container download —
//  which is a different operation with a different cost, written down in the
//  A1 campaign rather than hidden behind this button.
//
//  ONE JSON DOCUMENT, NOT AN ARCHIVE
//  ---------------------------------
//  There is no zip in the platform SDK worth writing three hundred lines
//  against for five files totalling twelve kilobytes. A single document also
//  carries what an archive could not: the app version that wrote it, the
//  moment, and a SHA-256 per file, so a copy that has rotted can be told from
//  one that has not — the same argument `SnapshotManifest` makes.
//
//  THE CONTENTS ARE EMBEDDED AS TEXT, NOT RE-ENCODED. Each store's bytes go in
//  verbatim as a UTF-8 string. Decoding and re-encoding them would put this
//  file's opinion of the shape between the athlete and his own data, and the
//  hash beside each one would then describe the copy rather than the original.
//

import Foundation
import CryptoKit

/// One store, as it was on disk.
nonisolated struct AuthoredExportEntry: Codable, Hashable, Sendable {
    let name: String
    /// Present and readable, or the reason it is not. §12.15: an absent file
    /// and an unreadable one are different facts and this says which.
    let bytes: Int?
    let sha256: String?
    /// The file's own contents, verbatim. Nil when it could not be read.
    let contents: String?
    let error: String?
}

nonisolated struct AuthoredExportDocument: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let createdUTC: String
    let appVersion: String
    let entries: [AuthoredExportEntry]

    var presentCount: Int { entries.filter { $0.contents != nil }.count }
    var absentCount: Int { entries.filter { $0.contents == nil }.count }
    var totalBytes: Int { entries.compactMap(\.bytes).reduce(0, +) }

    /// One line for the screen and the paste. Counts only — a note's text is
    /// the athlete writing about his own training and never appears in either.
    var summary: String {
        "\(presentCount) of \(entries.count) stores, \(totalBytes) bytes"
    }
}

nonisolated enum AuthoredExport {

    /// THE LIST, AND IT IS DELIBERATELY NOT `LegacyStore.allCases`.
    ///
    /// `allCases` would fail towards including 19 MB of re-fetchable data the
    /// day somebody adds a case, which is the direction that makes the button
    /// useless rather than the direction that loses something. The same
    /// argument `MigrationLedger.prunableTriggers` makes, pointing the other
    /// way: there, a forgotten case leaks; here, a forgotten case bloats. Both
    /// fail towards the harmless side.
    // `.moves` ADDED AT 362. It belongs on the small side of the argument
    // above without needing the argument: a file of session uids and day keys
    // is bytes, not megabytes, and it is authored — nothing can re-fetch a
    // decision the athlete made about his own week.
    static let stores: [LegacyStore] = [.notes, .commutes, .moves, .proposals,
                                        .athlete, .constants]

    static let schemaVersion = 1

    /// Builds the document. Reads files, so it never runs on the main actor's
    /// time if the caller can help it.
    static func build(appVersion: String,
                      now: Date = Date(),
                      base: URL? = AppSupportItem.container,
                      fm: FileManager = .default) -> AuthoredExportDocument {
        var entries: [AuthoredExportEntry] = []
        for store in stores {
            guard case .file(let name) = store.item else { continue }
            guard let base else {
                entries.append(.init(name: name, bytes: nil, sha256: nil,
                                     contents: nil,
                                     error: "Application Support is unreachable"))
                continue
            }
            let url = base.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                // ABSENT IS NOT AN ERROR. A device with no commute decisions
                // has no `commutes.json`, and calling that a failure would
                // make the export look broken on a healthy phone. §12.15.
                entries.append(.init(name: name, bytes: nil, sha256: nil,
                                     contents: nil, error: nil))
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                entries.append(.init(name: name,
                                     bytes: data.count,
                                     sha256: hex(data),
                                     contents: String(data: data, encoding: .utf8),
                                     error: nil))
            } catch {
                entries.append(.init(name: name, bytes: nil, sha256: nil,
                                     contents: nil,
                                     error: String(describing: error)))
            }
        }
        return AuthoredExportDocument(schemaVersion: schemaVersion,
                                      createdUTC: Sub4Import.iso8601(now),
                                      appVersion: appVersion,
                                      entries: entries)
    }

    /// Writes the document to a temporary file and returns it, ready for the
    /// share sheet.
    ///
    /// THE NAME CARRIES THE DAY AND THE PATCH, like the diagnostics file that
    /// patch 332 added — a file called `export.json` in a Downloads folder is
    /// a file nobody can date six months later.
    static func write(_ document: AuthoredExportDocument,
                      day: String,
                      into directory: URL = FileManager.default.temporaryDirectory)
    throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let url = directory.appendingPathComponent(
            "sub4-authored-\(day)-p\(document.appVersion).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
