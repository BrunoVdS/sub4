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

import Foundation

struct Match: Hashable {
    let session: Session
    let activity: Activity?
    let auto: Bool          // false = manual override

    var isDone: Bool { activity != nil }
}

@Observable
final class Matcher {

    static let shared = Matcher()

    /// Manual corrections: session uid → activity id ("" = explicitly none).
    private(set) var overrides: [String: String] = [:]
    private let key = "match.overrides"

    private init() {
        overrides = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
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
        overrides[session.uid] = activity?.id ?? ""
        UserDefaults.standard.set(overrides, forKey: key)
    }

    func clearOverride(session: Session) {
        overrides.removeValue(forKey: session.uid)
        UserDefaults.standard.set(overrides, forKey: key)
    }

    // MARK: Core

    private func resolve(sessions: [Session],
                         activities: [Activity],
                         dayKey: String) -> ([Match], [Activity]) {

        var pool = activities
        var matches: [Match] = []

        // 1. Manual overrides win outright.
        var remaining: [Session] = []
        for s in sessions {
            if let forced = overrides[s.uid] {
                if forced.isEmpty {
                    matches.append(Match(session: s, activity: nil, auto: false))
                } else if let i = pool.firstIndex(where: { $0.id == forced }) {
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
