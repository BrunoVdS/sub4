//
//  Matcher.swift
//  Sub4
//
//  Decides which Strava activity satisfies which planned session.
//
//  Bias: a missed match is easy to spot and harmless; a wrong match is silent
//  and corrupts your adherence numbers. So when it isn't confident, it leaves
//  the activity unmatched and shows it separately rather than guessing.
//
//  A DECISION CARRIES ITS DATE — patch 272, D4's database half
//  ----------------------------------------------------------
//  Until this patch the overrides were `[session uid: activity id]` in
//  UserDefaults, where `""` stood for "explicitly nothing". That shape says
//  what the athlete decided and nothing about when, and `match_decision` in
//  ADR-0003 §8 has `decidedUTC NOT NULL` — because a decision with no
//  timestamp cannot be reconciled against a later one. `CommuteStore` reached
//  the same conclusion in patch 251 and its header says so in as many words;
//  this is the same store one patch behind.
//
//  So the value is now a record, and `""` is a real absence.
//
//  WHY IT STAYS IN UserDefaults RATHER THAN BECOMING A FILE
//  --------------------------------------------------------
//  `commutes.json` went to Application Support in 251 and the obvious move is
//  to follow it. It is the wrong move HERE, and the reason is the ladder: D5
//  takes what is left in UserDefaults into typed rows, D7 makes the database
//  authoritative, and D8 removes the JSON writers. A new JSON store two rungs
//  before the JSON stores are retired is building something already scheduled
//  for demolition — and it would cost the whole legacy-fixture sweep
//  (`LegacyStore`, `LegacyInput`, the classifier, the reader, the snapshot
//  inventory) to carry a file for three patches.
//
//  The honest cost of staying: a `UserDefaults.set` has no failure to report,
//  so this is the one authored store with no failable-save path — not an
//  omission, an absence of API. §12.17's rule is that a write with somebody
//  watching must not report success it did not have; there is no way to ask
//  UserDefaults whether it succeeded, so the rule cannot be applied here and
//  is not pretended at. It becomes applicable at D5, in a transaction.
//
//  THE MIGRATION SYNTHESISES A DATE, AND SAYS SO
//  ---------------------------------------------
//  Decisions already on the phone have no timestamp anywhere — the old shape
//  never stored one and nothing else in the app remembers. Rather than invent
//  a plausible one (the session's date would be a different fact wearing this
//  one's clothes), the migration stamps them with the instant it ran and sets
//  `dateIsKnown` to false. `match_decision` has no column for that
//  distinction, so it survives in the store and in the import's counters
//  rather than in the table — which is the right place for it: the table
//  records what was decided, and this is a fact about our knowledge of it.
//

import Foundation

struct Match: Hashable {
    let session: Session
    let activity: Activity?
    let auto: Bool          // false = manual override

    var isDone: Bool { activity != nil }
}

/// One planned session, and what the athlete said satisfied it.
///
/// NONISOLATED, and deliberately so. `Sub4Import` reads this from inside a
/// database write that is `nonisolated` end to end, and
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise put every
/// member of it on the main actor. The rule the project learned three times in
/// patch 258 and 264: anything that is DATA rather than STATE says
/// `nonisolated` when it is written, not after a build says so.
nonisolated struct MatchDecision: Codable, Hashable, Identifiable, Sendable {

    /// Which planned session. The key this store has always used, and the same
    /// one `NotesStore` uses — verified against it by test since patch 225.
    var sessionUid: String

    /// The activity the athlete named, or nil for "explicitly nothing".
    ///
    /// NIL RATHER THAN THE EMPTY STRING. The old shape used `""` because a
    /// `[String: String]` in UserDefaults had nowhere to put an absence.
    /// `match_decision.activityID` is a nullable column, so the database can
    /// say it properly and this can too.
    var activityId: String?

    var decided: Date

    /// Whether `decided` is when the athlete decided, or when this record was
    /// made out of one that had no date. See the header.
    ///
    /// NOT OPTIONAL, and that is safe only because this type is new in this
    /// patch: nothing on disk predates it, so every record ever written
    /// carries the key. A synthesised `init(from:)` does not use Swift default
    /// values — the rule that has cost this project two patches — so any field
    /// ADDED here later must be Optional.
    var dateIsKnown: Bool

    var id: String { sessionUid }
}

@Observable
final class Matcher {

    static let shared = Matcher()

    /// What the athlete decided, by session uid.
    private(set) var decisions: [String: MatchDecision] = [:]

    /// Patch 272. The record shape; a `Data` blob rather than a dictionary,
    /// because UserDefaults cannot hold a `Codable` any other way and two
    /// parallel keys that must agree is a split brain by construction.
    ///
    /// NONISOLATED, like the two below it — a string literal is data, and
    /// `preferenceKeys` cannot be built out of main-actor-isolated members.
    nonisolated static let decisionsKey = "match.decisions"

    /// The retired shape, read once and removed. Still named in
    /// `DataLifecycle` alongside the new key: a device that has not launched
    /// this build still holds it, and a key nobody names is a key "Delete
    /// local data" cannot remove.
    nonisolated static let legacyKey = "match.overrides"

    /// Asked of the type that WRITES them, so the inventory cannot drift.
    ///
    /// `loadThresholdKeysAreCoveredAtTheirSource` is the test that exists
    /// because the hand-written list in `everyPreferenceKeyIsCovered` and the
    /// inventory it checks were written the same day by the same person and
    /// both forgot the same five keys. This patch CHANGES a key, which is the
    /// exact moment that failure repeats — so this store answers for itself
    /// now rather than after a delete has missed something.
    nonisolated static let preferenceKeys = [decisionsKey, legacyKey]

    private let defaults: UserDefaults

    private init() {
        defaults = .standard
        load()
        // SINGLETON ONLY — patch 273, the same rule as the three file stores.
        StoreReadJournal.shared.record(Self.decisionsKey, lastLoad)
    }

    /// A matcher rooted in its own defaults — patch 272, for the tests, in the
    /// same spirit as `NotesStore(directory:)` and `CommuteStore(directory:)`.
    /// The migration below is the one piece of this file that runs exactly
    /// once per device, which makes it the one piece that cannot be tested at
    /// all without this.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    // MARK: Persistence

    /// What the last read of the blob found — patch 273, §12.20.
    ///
    /// AND A CORRECTION TO THE COMMENT THIS REPLACES, which said there was
    /// nowhere to report an undecodable blob from. That was true for one
    /// patch. This store still has no WRITE journal, for the reason in the
    /// header — `UserDefaults.set` has no failure to report — but a read that
    /// found something it could not use is a fact with somewhere to go.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        if let data = defaults.data(forKey: Self.decisionsKey) {
            // A blob that will not decode is LEFT WHERE IT IS rather than
            // overwritten: destroying authored data to tidy up a read is the
            // trade §12.8.1 says never to make. What changed in 273 is that
            // the fact is recorded rather than swallowed.
            guard let list = try? JSONDecoder.sub4.decode([MatchDecision].self,
                                                          from: data) else {
                lastLoad = .unreadable("the stored decisions did not decode")
                return
            }
            decisions = Dictionary(list.map { ($0.sessionUid, $0) },
                                   uniquingKeysWith: { _, later in later })
            lastLoad = .loaded
            return
        }

        guard defaults.object(forKey: Self.legacyKey) != nil else {
            lastLoad = .absent
            return
        }
        decisions = Self.migrate(defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:])
        // ONLY IF THE NEW COPY LANDED — patch 278c. Removing the old key after
        // a write that silently did nothing would leave the decisions in
        // memory for this launch and gone at the next, with nothing else
        // holding them. A migration may lose the OLD SHAPE; it may not lose
        // the data.
        guard persist() else { return }
        defaults.removeObject(forKey: Self.legacyKey)
        lastLoad = .loaded
    }

    /// The retired `[uid: activity id]` shape, dated by the instant this ran.
    /// `dateIsKnown` is false on every row it produces — see the header.
    private static func migrate(_ old: [String: String], now: Date = Date()) -> [String: MatchDecision] {
        var out: [String: MatchDecision] = [:]
        for (uid, activityId) in old {
            out[uid] = MatchDecision(sessionUid: uid,
                                     activityId: activityId.isEmpty ? nil : activityId,
                                     decided: now,
                                     dateIsKnown: false)
        }
        return out
    }

    /// Returns whether the blob was written — patch 278c.
    ///
    /// SORTED, so the blob is stable between launches and a diff of a backup
    /// shows a decision changing rather than a dictionary reshuffling.
    ///
    /// The `Bool` has exactly one caller that reads it: the migration, which
    /// must not delete the old key on the strength of a write that did
    /// nothing. Every other caller discards it, because there is still nowhere
    /// to report a `UserDefaults` failure to — see the header.
    @discardableResult
    private func persist() -> Bool {
        let list = decisions.values.sorted { $0.sessionUid < $1.sessionUid }
        guard let data = try? JSONEncoder.sub4.encode(list) else { return false }
        defaults.set(data, forKey: Self.decisionsKey)
        return true
    }

    // MARK: Public

    /// Matches for one day, plus everything that wasn't part of the plan.
    ///
    /// `extras` deliberately includes commutes, walks, kayaking and any
    /// plan-eligible activity that found no session — it's the full movement
    /// picture, not a discard pile.
    func day(_ dayKey: String) -> (matches: [Match], extras: [Activity]) {
        let sessions = PlanStore.shared.sessions(on: dayKey)
        let all = ActivityStore.shared.activities(on: dayKey)

        let eligible = all.filter(\.isPlanEligible)
        let ineligible = all.filter { !$0.isPlanEligible }

        let (matches, leftover) = resolve(sessions: sessions,
                                          activities: eligible,
                                          dayKey: dayKey)

        let extras = (leftover + ineligible).sorted { $0.startLocal < $1.startLocal }
        return (matches, extras)
    }

    func isComplete(_ session: Session, on dayKey: String) -> Bool {
        day(dayKey).matches.first { $0.session.uid == session.uid }?.isDone ?? false
    }

    func setOverride(session: Session, activity: Activity?) {
        setOverride(sessionUid: session.uid, activityId: activity?.id)
    }

    /// The primitive the view's call above goes through — patch 272.
    ///
    /// By uid and id rather than by `Session` and `Activity`, because that is
    /// what the store holds and what a test can supply. Constructing a whole
    /// `Session` to record one decision about it is how a store ends up
    /// untestable.
    func setOverride(sessionUid: String, activityId: String?, now: Date = Date()) {
        decisions[sessionUid] = MatchDecision(sessionUid: sessionUid,
                                              activityId: activityId,
                                              decided: now,
                                              dateIsKnown: true)
        persist()
    }

    func clearOverride(session: Session) {
        clearOverride(sessionUid: session.uid)
    }

    func clearOverride(sessionUid: String) {
        decisions.removeValue(forKey: sessionUid)
        persist()
    }

    // MARK: Core

    private func resolve(sessions: [Session],
                         activities: [Activity],
                         dayKey: String) -> ([Match], [Activity]) {

        var pool = activities
        var matches: [Match] = []

        // 1. Manual overrides win outright.
        //
        //    THREE OUTCOMES, TWO OF THEM THE SAME MATCH. "Explicitly nothing"
        //    and "the activity named is not here" both produce an unmatched
        //    session, which is the behaviour the `""` shape had and is kept
        //    deliberately: the athlete overrode the matcher, so the matcher
        //    does not get another guess. The importer treats the two
        //    differently, because the database can tell them apart and this
        //    screen cannot.
        var remaining: [Session] = []
        for s in sessions {
            if let decision = decisions[s.uid] {
                if let forced = decision.activityId,
                   let i = pool.firstIndex(where: { $0.id == forced }) {
                    matches.append(Match(session: s, activity: pool.remove(at: i), auto: false))
                } else {
                    matches.append(Match(session: s, activity: nil, auto: false))
                }
            } else {
                remaining.append(s)
            }
        }

        // 2. Rest days in the past complete themselves — a rest day is done by
        //    doing nothing, so there is never an activity to find.
        var needsActivity: [Session] = []
        for s in remaining {
            if s.isRest {
                let past = dayKey < DayKey.key()
                matches.append(Match(session: s,
                                     activity: nil,
                                     auto: true))
                _ = past
            } else {
                needsActivity.append(s)
            }
        }

        // 3. Automatic matching, best-fit first. Sessions with a stated distance
        //    are resolved before vague ones so they claim the right activity.
        for s in needsActivity.sorted(by: { plannedKm($0) ?? 0 > plannedKm($1) ?? 0 }) {
            let candidates = pool.enumerated().filter { $0.element.discipline == s.discipline }

            guard !candidates.isEmpty else {
                matches.append(Match(session: s, activity: nil, auto: true))
                continue
            }

            let pick: Int
            if let target = plannedKm(s), candidates.count > 1 {
                pick = candidates.min {
                    abs($0.element.km - target) < abs($1.element.km - target)
                }!.offset
            } else {
                pick = candidates.first!.offset
            }
            matches.append(Match(session: s, activity: pool.remove(at: pick), auto: true))
        }

        let order = sessions.map(\.uid)
        matches.sort {
            (order.firstIndex(of: $0.session.uid) ?? 0)
                < (order.firstIndex(of: $1.session.uid) ?? 0)
        }
        return (matches, pool)
    }

    /// Best guess at the planned distance, pulled from the session text
    /// ("26 km", "1200 m", "6×100").
    private func plannedKm(_ s: Session) -> Double? {
        let text = [s.title, s.detail, s.breakdown?.total]
            .compactMap { $0 }.joined(separator: " ")

        if let m = text.range(of: #"(\d+(?:[.,]\d+)?)\s*km"#, options: .regularExpression) {
            let n = text[m].replacingOccurrences(of: "km", with: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            return Double(n)
        }
        if let m = text.range(of: #"(\d{3,5})\s*m\b"#, options: .regularExpression) {
            let n = text[m].replacingOccurrences(of: "m", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(n).map { $0 / 1000.0 }
        }
        return nil
    }
}

// MARK: - Week roll-up

extension Matcher {
    /// Completion for a set of sessions — rest days excluded from the count.
    func adherence(for sessions: [Session]) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for s in sessions where !s.isRest {
            total += 1
            if let d = s.date, isComplete(s, on: d) { done += 1 }
        }
        return (done, total)
    }
}
