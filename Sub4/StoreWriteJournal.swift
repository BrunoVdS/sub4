//
//  StoreWriteJournal.swift
//  Sub4
//
//  Which stores are behind their memory — D4 step 3, patch 266.
//
//  THE PROBLEM THIS SOLVES IS NOT THE ONE 264 SOLVED
//  -------------------------------------------------
//  `notes.json` and `commutes.json` are written while the athlete watches. A
//  failed write there gets an alert, and the store rolls its memory back so
//  the screen tells the truth — §12.17, §12.17.1.
//
//  The other six write during a sync. Nobody is watching, there is no sheet to
//  keep open and nothing to roll back TO: the data came off the network a
//  moment ago and rolling back would throw away a completed sync and show the
//  athlete less than the app actually has.
//
//  So the rule inverts, deliberately and for a stated reason: **memory keeps
//  what was fetched, and the disagreement with the disk is recorded.**
//
//  WHAT MAKES THAT SAFE RATHER THAN THE DEFECT 264 REMOVED
//  --------------------------------------------------------
//  264 existed because a note could appear on screen and be gone at the next
//  launch, with nothing anywhere saying so. The difference here is the last
//  clause. An unsaved store is a fact this journal holds, Settings shows, and
//  the diagnostic carries — so "the app is showing you more than it has saved"
//  is a sentence somebody can read, rather than a surprise at relaunch.
//
//  It is also recoverable in a way a note is not: every one of these six holds
//  something Strava or Open-Meteo will hand over again. The next sync rewrites
//  the file, and a successful write clears the entry.
//
//  ONE ENTRY PER STORE, NOT A LOG
//  ------------------------------
//  A sync that fails ten times leaves one entry saying it has failed ten
//  times, not ten entries. The athlete's question is "is anything not saved",
//  and a list that grows without bound turns that question into scrolling.
//

import Foundation

nonisolated struct UnsavedStore: Equatable, Identifiable {
    /// `activities.json`, `weather.json` — the file, as the athlete would
    /// recognise it.
    let store: String
    let error: StoreWriteError
    /// How many times running it has failed. One occurrence is a moment; a
    /// hundred is a condition.
    let attempts: Int
    let firstFailedUTC: String
    let lastFailedUTC: String

    var id: String { store }

    /// One line for Settings. No paths, no error domains.
    var line: String {
        attempts == 1
            ? error.errorDescription ?? "could not be saved"
            : "\(attempts) attempts since \(firstFailedUTC.prefix(10))"
    }
}

@MainActor
@Observable
final class StoreWriteJournal {

    static let shared = StoreWriteJournal()

    private(set) var unsaved: [String: UnsavedStore] = [:]

    private init() {}

    /// Every store's `save()` goes through here.
    ///
    /// NON-THROWING ON PURPOSE, which is the whole reason this patch touched
    /// six files and no callers. The six stores that use it write from inside
    /// syncs, backfills and detached tasks; making their `save()` throw would
    /// have pushed a decision out to forty call sites that all want the same
    /// answer, and forty places to get it wrong.
    ///
    /// The decision is made once, here: keep the memory, record the fact.
    /// `StoreWriteJournal.stamp()` and not `Self.stamp()`: `Self` in a default
    /// argument is covariant even on a `final` class, and the compiler refuses
    /// it. The explicit name is also the clearer read at the call site.
    @discardableResult
    func attempt(_ store: String, now: String = StoreWriteJournal.stamp(),
                 _ write: () throws -> Void) -> Bool {
        do {
            try write()
            // A successful write is the only thing that clears an entry.
            // Nothing times out and nothing is forgotten on relaunch by
            // accident — the journal is in memory, so a relaunch clears it,
            // and the first save after that will re-record if it is still bad.
            unsaved.removeValue(forKey: store)
            return true
        } catch {
            let failure = error as? StoreWriteError
                ?? StoreWriteError(store: store, stage: .writing,
                                   reason: String(describing: error))
            let at = now
            if let existing = unsaved[store] {
                unsaved[store] = UnsavedStore(store: store, error: failure,
                                              attempts: existing.attempts + 1,
                                              firstFailedUTC: existing.firstFailedUTC,
                                              lastFailedUTC: at)
            } else {
                unsaved[store] = UnsavedStore(store: store, error: failure,
                                              attempts: 1,
                                              firstFailedUTC: at, lastFailedUTC: at)
            }
            return false
        }
    }

    // MARK: Reading

    var hasUnsaved: Bool { !unsaved.isEmpty }
    var count: Int { unsaved.count }

    /// Sorted, so the list does not reshuffle between renders.
    var all: [UnsavedStore] { unsaved.values.sorted { $0.store < $1.store } }

    /// For the redacted paste. Store names, stages and counts — none of these
    /// is the athlete's data, and the underlying reason is left out because a
    /// file-system error can carry a path.
    var diagnosticLines: [String] {
        guard hasUnsaved else { return ["Unsaved stores: none"] }
        var out = ["Unsaved stores: \(count)"]
        for u in all {
            out.append("  \(u.store): \(u.error.stage.rawValue), \(u.attempts) attempt\(u.attempts == 1 ? "" : "s")")
        }
        return out
    }

    /// Test seam. Not `reset()` — nothing in the app clears this except a
    /// successful write, and a method that looked general would eventually be
    /// called from one.
    func forgetEverythingForTesting() { unsaved = [:] }

    nonisolated static func stamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}
