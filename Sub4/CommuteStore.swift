//
//  CommuteStore.swift
//  Sub4
//
//  Which rides are commutes, decided by the athlete — patch 251.
//
//  WHY THIS EXISTS RATHER THAN A STRAVA FIELD
//  ------------------------------------------
//  Patch 250 read Strava's own `commute` boolean and was right for one day.
//  ADR-0002 retires Strava; Phase 4A makes Apple Health canonical. A
//  classification whose source of truth is a field in a service this app is
//  leaving would have to be rebuilt at the moment the service goes away, and
//  the decisions already made would have nowhere to live in the meantime. So
//  the flag is read no longer, and the answer is held here.
//
//  ONE SOURCE OF TRUTH, AND IT IS THIS FILE. Nothing consults Strava about a
//  commute any more. `StravaActivityDTO` no longer decodes the field and
//  `Activity` no longer carries it.
//
//  WHY NOT A COLUMN ON `Activity`
//  ------------------------------
//  Because it would be destroyed every two hours. Since patch 249 the sync
//  re-reads all 661 activities from the cutoff on every run and `ingest`
//  replaces each row wholesale — `byID[a.id] = a`. Anything the athlete wrote
//  onto an `Activity` would survive until the next launch. Authored data has to
//  live beside the fetched data, never inside it, and that is true of every
//  store in this app: notes, corrections, match overrides.
//
//  THREE STATES, AND ALL THREE ARE USED
//  ------------------------------------
//  `true`  — you said this is a commute, whatever its distance.
//  `false` — you said this is not, whatever its distance.
//  absent  — you have not said, so `Activity.commuteByDistance` decides.
//
//  The default is what the app has always used: a bike ride under
//  `MatchRules.minRideKm` is a commute. On thirteen months of real history that
//  rule is right almost every time — but "almost" is doing work it should not,
//  and on 16 July 2026 a 9,985.9 m ride was a commute by fourteen metres. The
//  toggle is how that gets settled by the person who was on the bike.
//
//  A DECISION CARRIES ITS DATE. Not decoration: the `correction` table in
//  ADR-0003 §8 wants provenance for exactly this kind of row, and a decision
//  with no timestamp cannot be reconciled against a later one. ISO-8601, like
//  notes and proposals — authored data uses `JSONEncoder.sub4` throughout, and
//  `LegacyInput.commutes` in the fixture corpus states it.
//

import Foundation
import Observation

/// One ride, and what the athlete said about it.
struct CommuteDecision: Codable, Hashable, Identifiable {
    /// The activity's id — a Strava id today, remapped through `activity_alias`
    /// when the database becomes authoritative. The same remapping problem the
    /// match overrides already have, and recorded as such in the inventory.
    var activityId: String
    var isCommute: Bool
    var decided: Date

    var id: String { activityId }
}

@Observable
final class CommuteStore {

    static let shared = CommuteStore()

    private(set) var decisions: [String: CommuteDecision] = [:]

    /// Where the decisions this store is serving came from — patch 357.
    private(set) var servedFrom: StoreSource = .files

    private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("commutes.json")
        load()
        StoreReadJournal.shared.record("commutes.json", lastLoad)
    }

    /// A store rooted somewhere else — patch 265, exactly as
    /// `NotesStore(directory:)`, and NOT ONLY FOR THE TESTS since 356.
    ///
    /// A failable save nobody has watched fail is `try?` with more words around
    /// it — that is why it was written. `ReadBacks.authoredSources` is why it
    /// is now also production: B2 hydrates `shared` from the database, and the
    /// read-back needs `commutes.json` itself. §12.91.2.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("commutes.json")
        load()
    }

    // MARK: Hydration — D7 slice B2, patch 357

    /// Replaces the decisions with the stored ones. Does not write, for
    /// `NotesStore.hydrate`'s reason.
    func hydrate(from stored: [CommuteDecision]) {
        decisions = Dictionary(stored.map { ($0.activityId, $0) },
                               uniquingKeysWith: { first, _ in first })
        servedFrom = .database
    }

    // MARK: Reading

    /// What the athlete said, or nil if he has not said.
    ///
    /// Nil is not "no". A ride nobody has ruled on falls through to the
    /// distance rule, and collapsing that into `false` would silently promote
    /// every unreviewed commute into a training ride.
    func decision(for activityId: String) -> Bool? {
        decisions[activityId]?.isCommute
    }

    var count: Int { decisions.count }

    /// The decisions that disagree with what the distance rule would have said.
    /// The interesting ones — and the only evidence that the toggle earns its
    /// place rather than restating the default.
    func overrides(in activities: [Activity]) -> [CommuteDecision] {
        activities.compactMap { a in
            guard let d = decisions[a.id], d.isCommute != a.commuteByDistance else { return nil }
            return d
        }
        .sorted { $0.decided > $1.decided }
    }

    // MARK: Writing

    /// THROWS SINCE PATCH 265, and the memory is rolled back when it does.
    ///
    /// The rollback is also the visual revert, and that is not a coincidence
    /// worth relying on twice: `Activity.isCommuteRide` reads this store, so
    /// putting the old answer back IS the toggle snapping back. Nothing in the
    /// view has to undo anything, and there is no second opinion about what
    /// happened that could drift from this one.
    func set(_ isCommute: Bool, for activityId: String, now: Date = Date()) throws {
        let previous = decisions[activityId]
        decisions[activityId] = CommuteDecision(activityId: activityId,
                                                isCommute: isCommute,
                                                decided: now)
        do {
            try save()
        } catch {
            if let previous { decisions[activityId] = previous }
            else { decisions.removeValue(forKey: activityId) }
            throw error
        }
    }

    /// Removes the decision, returning the ride to the distance rule. Distinct
    /// from setting `false`: "I have no opinion" and "this is not a commute"
    /// are different answers and the second one survives a change to the
    /// threshold.
    func clear(_ activityId: String) throws {
        guard let previous = decisions.removeValue(forKey: activityId) else { return }
        do {
            try save()
        } catch {
            // Putting it back matters more here than it looks. Forgetting an
            // answer returns the ride to the distance rule, so a clear that
            // silently did not happen would leave the athlete believing the
            // threshold governs a ride it does not.
            decisions[activityId] = previous
            throw error
        }
    }

    // MARK: Disk

    /// What the last read of `commutes.json` found — patch 273, §12.20.
    ///
    /// An unreadable file here reads as "you have not ruled on any ride", so
    /// every decision silently falls back to `commuteByDistance` — the very
    /// rule patch 251 exists to override.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: CommuteDecision].self,
                                                at: fileURL)
        if let value { decisions = value }
        lastLoad = outcome
    }

    private func save() throws {
        try StoreWrite.encode(decisions, to: fileURL, store: "commutes.json")
        DatabaseWriteThrough.shared.noteAuthoredChange("a commute decision was saved")
    }

    /// Drops everything held in memory WITHOUT writing to disk — the
    /// counterpart to `DataLifecycleCoordinator.deleteEverything`. Same reason
    /// as `NotesStore.dropInMemory`: resetting would write an empty file and
    /// recreate the store that was just deleted, and leaving the memory copy
    /// alive would let the next save resurrect it.
    func dropInMemory() {
        decisions = [:]
    }
}
