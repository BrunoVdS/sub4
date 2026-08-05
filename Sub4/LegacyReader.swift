//
//  LegacyReader.swift
//  Sub4
//
//  What is actually on this phone — step 3.4, patch 262.
//
//  260 built a classifier that takes bytes. 261 taught it about identity. Both
//  were exercised entirely against the fixture corpus, which is eleven strings
//  somebody wrote down. THIS is where they meet thirteen months of real files,
//  and the honest position before running it is that nobody knows what they
//  will say.
//
//  READING ONLY. NOTHING IS HELD BACK YET.
//  ---------------------------------------
//  A record that fails the identity check is reported and still imported,
//  because the `quarantine` table is patch 263. That ordering is deliberate:
//  a table designed before anybody had seen the data it holds is a table
//  designed from the fixtures, and the fixtures are a guess about what real
//  damage looks like.
//
//  It also means this patch cannot break an import. It reads files the app
//  already reads, decodes them with the same decoders, and writes nothing.
//
//  THE DIRECTORIES ARE WHERE `named:` FINALLY HAS AN ARGUMENT
//  ----------------------------------------------------------
//  `details/` and `streams/` are one file per activity, named by the Strava id
//  that is also inside the file. 261 built the check for it and had nothing to
//  feed it — every test passed `named: nil`, which SKIPS the check. Here the
//  file name is real, and if 667 details each state their id twice, this is
//  the first time anything has compared the two.
//
//  ONE ROW PER STORE, PLUS THE PER-FILE DETAIL UNDERNEATH
//  ------------------------------------------------------
//  A directory of 667 files cannot be one condition. It is 667 conditions,
//  and the useful summary is "660 readable, 7 held back" with the seven named
//  — not "details: mismatch", which tells nobody which activity to look at.
//

import Foundation

/// What one file turned out to be.
nonisolated struct LegacyFileReading: Equatable, Identifiable {
    /// `notes.json`, or `details/19608576674.json`.
    let path: String
    /// The id the file name carries, for the two directory stores. Nil for
    /// everything else — and nil is what makes `classify` skip the name check
    /// rather than pass it.
    let named: String?
    let bytes: Int
    let condition: LegacyCondition

    var id: String { path }
}

/// What one store turned out to be.
nonisolated struct LegacyReading: Equatable, Identifiable {
    let store: LegacyStore
    let files: [LegacyFileReading]

    var id: String { store.rawValue }

    /// The store's own condition, for stores that are one file. For the two
    /// directories this is the worst thing found, which is a summary and says
    /// so — `files` is where the answer actually lives.
    var condition: LegacyCondition {
        if files.count == 1, let only = files.first { return only.condition }
        if files.isEmpty { return .absent }
        return faults.first?.condition ?? .readable
    }

    var faults: [LegacyFileReading] { files.filter { $0.condition.isFault } }
    var readableCount: Int { files.count - faults.count }
    var bytes: Int { files.reduce(0) { $0 + $1.bytes } }

    /// Every identity fault in the store, flattened, so a screen can list them
    /// without walking two levels.
    var identityFaults: [IdentityFault] {
        files.flatMap { file -> [IdentityFault] in
            if case .identityMismatch(let f) = file.condition { return f }
            return []
        }
    }
}

@MainActor
enum LegacyReader {

    /// Every declared store, read and classified. Never throws.
    ///
    /// A read that stops at the first unreadable file reports nothing about
    /// the other ten, which is the same failure `LegacySnapshot.describe` was
    /// written to avoid: a survey that gives up is worth less than no survey,
    /// because it looks like one.
    static func readAll(base: URL? = AppSupportItem.container,
                        fm: FileManager = .default) -> [LegacyReading] {
        LegacyStore.allCases.map { read($0, base: base, fm: fm) }
    }

    static func read(_ store: LegacyStore,
                     base: URL? = AppSupportItem.container,
                     fm: FileManager = .default) -> LegacyReading {
        guard let base else {
            // Application Support unreachable. Not "the files are missing" —
            // nobody looked. Reported as absent because there is no honest
            // alternative, and the caller has bigger problems.
            return LegacyReading(store: store, files: [])
        }

        switch store.item {
        case .file(let name), .legacyFile(let name):
            return LegacyReading(store: store,
                                 files: [reading(at: base.appendingPathComponent(name),
                                                 path: name, named: nil,
                                                 store: store, fm: fm)])

        case .directory(let name):
            let dir = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                // The directory itself is what is missing. One row rather than
                // none, so "no details on this phone" is distinguishable from
                // "the survey did not cover details".
                return LegacyReading(store: store,
                                     files: [.init(path: name, named: nil, bytes: 0,
                                                   condition: .absent)])
            }
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
            guard !names.isEmpty else {
                return LegacyReading(store: store,
                                     files: [.init(path: name, named: nil, bytes: 0,
                                                   condition: .absent)])
            }
            return LegacyReading(store: store, files: names.map { n in
                // THE FILE NAME IS AN IDENTITY CLAIM. `19608576674.json` says
                // the file is about that activity, and the record inside says
                // so too. 261 built the comparison; this is the first caller
                // that knows both halves.
                let stem = (n as NSString).deletingPathExtension
                return reading(at: dir.appendingPathComponent(n),
                               path: "\(name)/\(n)", named: stem,
                               store: store, fm: fm)
            })

        case .databaseDirectory, .snapshotDirectory:
            // Not legacy inputs. `LegacyStore` cannot name one — the switch is
            // exhaustive over `AppSupportItem`, not over this enum's own cases
            // — and reaching here would mean `item` started returning
            // something it has no business returning.
            return LegacyReading(store: store, files: [])
        }
    }

    private static func reading(at url: URL,
                                path: String,
                                named: String?,
                                store: LegacyStore,
                                fm: FileManager) -> LegacyFileReading {
        let data = try? Data(contentsOf: url)
        return LegacyFileReading(path: path,
                                 named: named,
                                 bytes: data?.count ?? 0,
                                 condition: LegacyClassifier.classify(data, as: store,
                                                                      named: named))
    }

    // MARK: For the diagnostic

    /// The redacted survey. Counts, conditions and store names only.
    ///
    /// NO ACTIVITY IDS AND NO SESSION UIDS, which means the identity faults
    /// appear here as a NUMBER and not as a list. The two names in an
    /// `IdentityFault` are the athlete's own identifiers, and the diagnostic
    /// paste promises they do not leave the phone — §12.7. The screen shows
    /// them; this does not.
    static func diagnosticLines(_ readings: [LegacyReading]) -> [String] {
        var out = ["Legacy files:"]
        for r in readings {
            let label = r.store.rawValue
            if r.files.count > 1 {
                out.append("  \(label): \(r.files.count) files, "
                           + "\(r.readableCount) readable, \(r.faults.count) at fault")
            } else {
                out.append("  \(label): \(r.condition.diagnosticName)")
            }
            // One line per distinct fault kind, counted. Enough to tell
            // somebody what to ask about without naming anything of the
            // athlete's.
            let kinds = Dictionary(grouping: r.faults, by: { $0.condition.diagnosticName })
            for kind in kinds.keys.sorted() {
                guard let n = kinds[kind]?.count else { continue }
                out.append("    \(kind): \(n)")
            }
        }
        return out
    }
}

extension LegacyCondition {
    /// A stable short name for diagnostics and grouping. Distinct from
    /// `summary`, which is prose for the athlete and may be reworded; this one
    /// is compared and sorted, so it does not change.
    var diagnosticName: String {
        switch self {
        case .absent:            "absent"
        case .empty:             "empty"
        case .whitespace:        "whitespace"
        case .notJSON:           "not-json"
        case .truncated:         "truncated"
        case .corrupt:           "corrupt"
        case .wrongContainer:    "wrong-container"
        case .undecodable:       "undecodable"
        case .identityMismatch:  "identity-mismatch"
        case .duplicateIdentity: "duplicate-identity"
        case .readable:          "readable"
        }
    }
}
