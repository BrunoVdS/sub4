//
//  StoreReadJournal.swift
//  Sub4
//
//  Which stores could not be read — patch 273, ADR-0003 §12.20.
//
//  THE READ COUNTERPART OF `StoreWriteJournal`, AND IT IS NOT ITS MIRROR
//  ---------------------------------------------------------------------
//  The write journal answers "is anything not saved". Everything it lists is
//  re-fetchable, so it is a warning rather than a loss, and a successful write
//  clears the entry.
//
//  This one answers a different question: "did the app read everything it
//  thinks it read". An entry here means a file exists that the app could not
//  turn into records — so the athlete is being shown LESS than he has, which
//  is the failure the write journal cannot express. Nothing clears it during a
//  session, because every store reads once at launch: the entry stands until
//  the next launch reads the file again.
//
//  WHAT IT IS FOR, BEYOND THE ROW IN SETTINGS
//  ------------------------------------------
//  `canReconcile` is the gate on 274's reconciliation pass. A store that never
//  recorded an outcome is NOT trustworthy — the default is refusal, so a store
//  wired into the pass and forgotten here fails closed rather than deleting
//  rows on the strength of a read nobody checked.
//

import Foundation

nonisolated struct UnreadStore: Equatable, Identifiable {
    /// `notes.json`, `proposals.json` — the file, as the athlete would
    /// recognise it. `match.decisions` for the one that is a preference.
    let store: String
    let reason: String
    let noticedUTC: String

    var id: String { store }

    var line: String { reason }
}

@MainActor
@Observable
final class StoreReadJournal {

    static let shared = StoreReadJournal()

    /// Every store that has reported, including the ones that read fine. This
    /// is what `canReconcile` consults; `unreadable` is what Settings shows.
    private(set) var outcomes: [String: StoreLoad] = [:]

    private(set) var unreadable: [String: UnreadStore] = [:]

    private init() {}

    /// Called from each store's SINGLETON init only.
    ///
    /// The `init(directory:)` and `init(defaults:)` seams deliberately do not
    /// record: a test store writing into the shared journal would leak into
    /// whatever ran next, and this journal's whole job is to be believed.
    func record(_ store: String, _ outcome: StoreLoad,
                now: String = StoreWriteJournal.stamp()) {
        outcomes[store] = outcome
        if case .unreadable(let reason) = outcome {
            unreadable[store] = UnreadStore(store: store, reason: reason,
                                            noticedUTC: now)
        } else {
            unreadable.removeValue(forKey: store)
        }
    }

    // MARK: Reading

    var hasUnreadable: Bool { !unreadable.isEmpty }
    var count: Int { unreadable.count }

    /// Sorted, so the list does not reshuffle between renders.
    var all: [UnreadStore] { unreadable.values.sorted { $0.store < $1.store } }

    /// THE GATE. Every named store must have reported something believable.
    ///
    /// FAILS CLOSED on a store that never reported — see the header. The
    /// alternative, treating silence as success, would make forgetting to wire
    /// a store in look exactly like wiring it in correctly.
    func canReconcile(_ stores: [String]) -> Bool {
        for store in stores {
            guard let outcome = outcomes[store], outcome.isTrustworthy else {
                return false
            }
        }
        return true
    }

    /// For the redacted paste. STORE NAMES ONLY — the reason can name a file
    /// system path, the same judgement `StoreWriteJournal.diagnosticLines`
    /// made about its errors.
    var diagnosticLines: [String] {
        guard hasUnreadable else { return ["Unreadable stores: none"] }
        var out = ["Unreadable stores: \(count)"]
        for u in all { out.append("  \(u.store)") }
        return out
    }

    /// Test seam. Not `reset()`, for `StoreWriteJournal`'s reason: nothing in
    /// the app clears this, and a method that looked general would eventually
    /// be called from somewhere that should not.
    func forgetEverythingForTesting() {
        outcomes = [:]
        unreadable = [:]
    }
}
