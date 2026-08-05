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

    private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("commutes.json")
        load()
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

    func set(_ isCommute: Bool, for activityId: String, now: Date = Date()) {
        decisions[activityId] = CommuteDecision(activityId: activityId,
                                                isCommute: isCommute,
                                                decided: now)
        save()
    }

    /// Removes the decision, returning the ride to the distance rule. Distinct
    /// from setting `false`: "I have no opinion" and "this is not a commute"
    /// are different answers and the second one survives a change to the
    /// threshold.
    func clear(_ activityId: String) {
        guard decisions.removeValue(forKey: activityId) != nil else { return }
        save()
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        decisions = (try? JSONDecoder.sub4.decode([String: CommuteDecision].self,
                                                  from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder.sub4.encode(decisions) else { return }
        try? data.write(to: fileURL, options: FileProtection.options)
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
