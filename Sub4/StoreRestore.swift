//
//  StoreRestore.swift
//  Sub4
//
//  The restore contract, extracted so there is one of it — patch 400,
//  ADR-0003 §12.144.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  §5.5 has called it the largest open risk in this project for many patches:
//  **five stores of the athlete's own writing have no way back.** `notes.json`,
//  the match decisions, `moves.json`, `commutes.json` and `proposals.json`.
//  Patch 372 stopped the lifecycle mechanism destroying them; nothing built the
//  recovery. Weather got one at 374 and the authored data — the category
//  ADR-0002 promises survives the Strava retirement and everything after it —
//  did not.
//
//  THE CONTRACT IS SUBTLE AND IT IS ALREADY WRITTEN
//  ------------------------------------------------
//  `WeatherStore.restore` got it right at 374 and the reasoning is worth more
//  than the code:
//
//    · **STRICTLY ADDITIVE.** A record written since the last import exists in
//      the file and NOT in the database. Replacing wholesale would delete
//      exactly those — the defect the restore repairs, with an extra step.
//    · **IT SATISFIES `save()`'s GUARD RATHER THAN BYPASSING IT.** The guard
//      exists to stop bytes nobody could read being overwritten. So the bytes
//      are MOVED somewhere they survive, `lastLoad` becomes `.absent`, and the
//      ordinary write runs on the ordinary path. A second write path would
//      have been shorter and would have made the guard advisory.
//    · **MEMORY GOES BACK IF THE WRITE DOES NOT LAND.** The screens read the
//      store; leaving 5 notes in memory that are not on the disk is §12.17.
//    · **NO WRITE-THROUGH.** The records came out of the database. Announcing
//      them back to it is a loop, and `noteAuthoredChange` is for what the
//      athlete wrote.
//    · **COUNTS, NOT A BOOL.** "Ran and added nothing" and "never ran" are
//      different facts — §12.15 — and on the screen the difference is whether
//      the database had anything to give.
//
//  Copying that five times is five chances to drift, and §12.43's worst
//  instance was five copies of one rule disagreeing for 230 patches. So the two
//  subtle steps live here, once, and each store's `restore` is the ten lines
//  that are genuinely its own.
//
//  WHY THE MERGE KEYS ON `id`
//  --------------------------
//  All five stores hold `[String: T]` and every one of them keys that
//  dictionary by the record's own identity — `Note.id` and `MatchDecision.id`
//  and `PlanMove.id` are `sessionUid`, `CommuteDecision.id` is `activityId`,
//  `ActivityWeather.id` is the activity. Taking a key CLOSURE would have let one
//  call site key its merge differently from the dictionary it is merging into,
//  silently, and that is a defect no test would find because both sides would
//  be internally consistent. `Identifiable` makes the key and the identity the
//  same thing by construction.
//

import Foundation

/// The two steps of a restore that are the same for every store.
nonisolated enum StoreRestore {

    /// What a restore did, for one store.
    ///
    /// UNCONDITIONAL AND COUNTED — §12.15, §12.54.2. `added: 0, alreadyHeld: 0`
    /// is reachable only from an empty database and says so; a `Bool` would
    /// have collapsed it into the same answer as a restore that repaired
    /// everything.
    struct Receipt: Equatable, Sendable {
        let store: String
        let added: Int
        let alreadyHeld: Int
        /// Where an unreadable file was moved to. Nil is the ordinary case and
        /// NOT a failure — it means the file read cleanly and nothing had to be
        /// preserved.
        let setAside: URL?

        /// Nothing in the database for this store. Named, because the caller
        /// must not have to build a zero receipt itself and get the store name
        /// wrong.
        static func nothingStored(_ store: String) -> Receipt {
            Receipt(store: store, added: 0, alreadyHeld: 0, setAside: nil)
        }

        /// One line, always sayable. **THE FILE NAME IS IN IT** — a receipt
        /// that said "added 3" without saying to what is a number nobody can
        /// act on, and this control restores several stores at once.
        var line: String {
            var s = "\(store): added \(added), already held \(alreadyHeld)"
            if setAside != nil { s += ", unreadable file set aside" }
            return s
        }
    }

    /// **WHAT A RESTORE DID, AS LINES — patch 402, §12.146.**
    ///
    /// UNCONDITIONAL, and "not run" is the answer that makes the others
    /// readable. Two exports of the authored read-back taken on 17 August, one
    /// of them after pressing Restore, were BYTE-IDENTICAL: the receipt lived
    /// in `@State` and rendered as a row, so the paste could not tell a restore
    /// that ran from a button nobody pressed. §12.54.2, exactly.
    ///
    /// **AND THE WEATHER RESTORE HAD IT SINCE 374.** 391 was written to close
    /// screen-only figures (§12.135) and swept the three read-backs and the
    /// write-through; nobody looked at the restore receipts, and no
    /// `diagnosticLines` in the app mentioned one until this patch.
    ///
    /// Store names, counts and an aside FILENAME only — §12.7. Nothing here can
    /// carry a note's text or an activity's identity.
    /// **PATCH 404 — FAILURES ARE PER STORE, NOT ONE ERROR FOR THE RUN.** Three
    /// independent files: a notes problem has nothing to do with `moves.json`,
    /// and a runner that stopped at the first throw would leave the others
    /// untried AND unreported, so a reader could not tell "moves was fine" from
    /// "moves was never attempted". That is §12.15 in a repair tool.
    static func lines(_ receipts: [Receipt], failures: [Failure],
                      subject: String) -> [String] {
        guard !receipts.isEmpty || !failures.isEmpty else {
            return ["\(subject) restore: not run since this launch."]
        }
        return ["\(subject) restore:"]
            + receipts.map { "  " + $0.line }
            + failures.map { "  " + $0.line }
    }

    /// One store's restore that did not happen, and why.
    ///
    /// SEPARATE FROM `Receipt` because they are different facts. A receipt with
    /// `added: 0` means the store was looked at and needed nothing; a failure
    /// means it was not looked at, or could not be written. Collapsing them
    /// would let "nothing to do" and "could not be done" print the same.
    struct Failure: Equatable, Sendable {
        let store: String
        let why: String

        var line: String { "\(store): NOT RESTORED — \(why)" }
    }

    /// **THE ADDITIVE MERGE.** Records the store already holds win.
    ///
    /// That direction is the whole safety of a restore: the store's copy may
    /// have been edited since the import that wrote the row, and the row cannot
    /// know. A restore that preferred the database would silently revert the
    /// athlete's most recent writing — which is a data loss wearing the name of
    /// a repair.
    static func merge<T: Identifiable>(_ stored: [T], into current: [String: T])
    -> (merged: [String: T], added: Int, alreadyHeld: Int) where T.ID == String {
        var merged = current
        var added = 0
        var alreadyHeld = 0
        for record in stored {
            if merged[record.id] == nil {
                merged[record.id] = record
                added += 1
            } else {
                alreadyHeld += 1
            }
        }
        return (merged, added, alreadyHeld)
    }

    /// Moves an unreadable file out of the way so the ordinary write can run.
    ///
    /// Returns nil when there was nothing to move — either the file read
    /// cleanly, or there is no file. **The caller must set `lastLoad` to
    /// `.absent` when this returns non-nil**, or `save()`'s guard stays shut
    /// for the rest of the session and the one action offered for fixing the
    /// store fixes nothing until the next launch (§12.371's finding, in
    /// `WeatherStore.resetCache`).
    ///
    /// NOT `try?`. A move that silently did not happen would leave the bytes
    /// exactly where the write is about to land, which is the defect with an
    /// extra step. §12.20.
    static func setAsideIfUnreadable(at file: URL, trustworthy: Bool,
                                     now: Date) throws -> URL? {
        guard !trustworthy, FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        let destination = asideURL(for: file, now: now)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// `notes.json.unreadable-20260817-084500`, and a suffix if that exists.
    ///
    /// The collision is not hypothetical: two restores in the same second are
    /// two taps, and one control now restores several stores at once.
    static func asideURL(for file: URL, now: Date) -> URL {
        let stamp = asideStamp.string(from: now)
        var candidate = file.appendingPathExtension("unreadable-\(stamp)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = file.appendingPathExtension("unreadable-\(stamp)-\(n)")
            n += 1
        }
        return candidate
    }

    private static let asideStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Why a restore did not happen — the authored stores' version of
/// `WeatherRestoreFault`, patch 400.
nonisolated enum AuthoredRestoreFault: Error, Equatable {
    /// The read did not produce records. Carries the load's own sentence,
    /// because "the database could not be read" and "the database is not open"
    /// send a reader to different places. §12.15.
    case databaseUnreadable(String)

    var line: String {
        switch self {
        case .databaseUnreadable(let why):
            "The stored records could not be read, so nothing was restored — \(why)"
        }
    }
}
