//
//  LoadStore.swift
//  Sub4
//
//  Every day from the history cutoff to today, with a load on it.
//
//  WHY EVERY DAY, INCLUDING THE EMPTY ONES
//  ---------------------------------------
//  The fitness curve is an exponential moving average over a daily series, and
//  an average is only defined if the series has no holes. A rest day is a real
//  zero and has to be present as one; the single most common way a home-rolled
//  fitness curve goes wrong is treating "no row" as "no load" and quietly
//  shortening the window.
//
//  But a zero and a gap are not the same thing, and this is where the honesty
//  lives. Four states:
//
//    measured  every eligible activity on the day produced a number
//    partial   something happened that could not be scored — the day is a floor
//    rest      nothing eligible happened. A true zero, and it belongs in the curve
//    gap       things happened and none of them scored. NOT a zero
//
//  A curve drawn across a gap is wrong for six weeks afterwards, so gaps are
//  counted, shown, and will block the verdict rather than being smoothed over.
//
//  NOTHING IS PERSISTED
//  --------------------
//  There is no load.json, deliberately. Every input — activities, streams,
//  constants — is already on disk and already complete, and the whole series
//  recomputes in a few milliseconds. A cache would add exactly one thing:
//  the possibility of being stale in a way nobody notices. Instead the inputs
//  are fingerprinted, and the series is rebuilt whenever the fingerprint moves.
//
//  This is a deliberate departure from the source spec's schema, which assumes
//  a server and a remote source of truth. Ours is local.
//
//  THE WALK ITSELF LIVES IN `LoadSeries` — patch 314
//  -------------------------------------------------
//  This class still decides WHAT to feed the series: it reads the stores,
//  measures the power factor, maps sRPE through the plan and the matcher, and
//  asks Apple Health for the heart rates Strava does not have. `LoadSeries`
//  takes all of that as arguments and walks the days.
//
//  The split is not tidiness. D6c slice 3 builds the same series from the
//  database's activities and traces with every other input held identical, and
//  that is only possible if the walk has no hidden inputs. §12.58.
//

import Foundation
import Observation

@Observable
final class LoadStore {

    static let shared = LoadStore()

    private(set) var days: [DailyLoad] = []
    private(set) var computedAt: Date?

    /// The measured TRIMP-per-TSS conversion, or nil while there are too few
    /// rides carrying both to measure one.
    private(set) var powerFactor: PowerFactor?

    /// Why there is no factor, when there is none. Rebuilt alongside it.
    private(set) var powerDiagnosis: PowerDiagnosis?


    /// What the series was last built from. Recompute is a string comparison.
    private var signature = ""

    private init() {}

    // MARK: Building

    /// Cheap fingerprint of everything that can change a load figure.
    ///
    /// The stream count matters as much as the activity count: a day scored
    /// from a session average is upgraded to the full trace the moment the
    /// detail queue reaches it, and the series has to notice.
    @MainActor
    private func currentSignature() -> String {
        let a = ActivityStore.shared
        let d = DetailStore.shared
        let c = ConstantsStore.shared
        return [
            "e\(LoadEngine.version)",
            "a\(a.count)",
            "s\(d.streamCount)",
            "v\(c.version)",
            "r\(c.restFingerprint)",
            "n\(NotesStore.shared.count)",
            "f\(AthleteStore.shared.ftp ?? 0)",
            // The Health workout cache is loaded on demand and arrives AFTER
            // the first materialisation. Without it in the fingerprint, a
            // strength session whose heart rate only exists in Health would
            // stay a gap until something else happened to change the signature.
            "h\(HealthStore.shared.cachedWorkouts.count)"
        ].joined(separator: "-")
    }

    @MainActor
    func recomputeIfNeeded() {
        let s = currentSignature()
        guard s != signature else { return }
        recompute()
    }

    @MainActor
    func recompute() {
        signature = currentSignature()
        computedAt = Date()

        let constants = ConstantsStore.shared
        let w = constants.sexCoefficient
        let store = ActivityStore.shared
        let details = DetailStore.shared
        let ftp = AthleteStore.shared.ftp

        // Measured once per rebuild, from every ride carrying both a heart rate
        // and a meter. Nil until there are five of them, and power-only rides
        // stay unscored until then rather than being converted by a guess.
        powerFactor = PowerLoad.calibrate(activities: store.activities,
                                          ftp: ftp,
                                          hrMax: constants.hrMax,
                                          hrRest: { constants.hrRest(on: $0) },
                                          w: w)
        powerDiagnosis = PowerLoad.diagnose(activities: store.activities,
                                            ftp: ftp,
                                            hrMax: constants.hrMax,
                                            hrRest: { constants.hrRest(on: $0) })

        // sRPE is carried, never summed — see the note at the top of
        // TrainingLoad.swift. Built once here rather than per day.
        var srpeByActivity: [String: Double] = [:]
        let notes = NotesStore.shared.all
        if !notes.isEmpty {
            // uniquingKeysWith rather than uniqueKeysWithValues: a duplicate uid
            // in plan.json would trap the app on launch, and a plan file is not
            // a thing this code should be able to crash on.
            let sessionsByUid = Dictionary(
                PlanStore.shared.plan.sessions.map { ($0.uid, $0) },
                uniquingKeysWith: { first, _ in first })
            for (uid, note) in notes {
                guard let rpe = note.rpe,
                      let session = sessionsByUid[uid],
                      let dayKey = session.date else { continue }
                for m in Matcher.shared.day(dayKey).matches where m.session.uid == uid {
                    guard let a = m.activity else { continue }
                    // Through the correction, like every other duration in
                    // the app — an sRPE scored on a clock the fitness curve has
                    // already overruled would disagree with it by construction.
                    srpeByActivity[a.id] = Double(rpe)
                        * Double(DataCorrections.scoringSeconds(a)) / 60
                }
            }
        }

        // APPLE HEALTH'S HEART RATES, GATHERED UP FRONT — patch 314.
        //
        // `healthMatch` used to be called inside the day walk. It is called
        // over the same set — load-eligible activities only — and the result
        // is handed in, because `LoadSeries` must have no hidden inputs for a
        // twin to be possible at all.
        //
        // THE ONE INPUT NO DATABASE WILL EVER HOLD. It is a cache of Apple
        // Health, not of anything this app writes, which is why slice 3 holds
        // it identical on both sides rather than pretending it could vary.
        var health: [String: Double] = [:]
        for a in store.activities where a.isLoadEligible {
            if let hr = HealthStore.shared.healthMatch(for: a)?.averageHeartRate {
                health[a.id] = hr
            }
        }

        // THE WALK MOVED OUT — patch 314, ADR-0003 §12.58.
        //
        // Four hundred days over a four-rung scoring engine, reading eight
        // singletons as it went. D6c slice 3 needs the same series built from
        // the database's activities and traces, and a second implementation of
        // this is the mistake §12.43 cost three patches to learn.
        //
        // `ActivityRoster.byDay` rather than `store.activities(on:)`, and they
        // are the same thing: the store's own index is built by that function
        // (§12.56.2). Building it again here costs one grouping of ~670 rows
        // per rebuild and buys a `build` with nothing hidden in it.
        let out = LoadSeries.build(
            from: MatchRules.cutoffDayKey,
            to: DayKey.key(),
            byDay: ActivityRoster.byDay(store.activities),
            inputs: LoadSeries.Inputs(hrMax: constants.hrMax,
                                      hrRest: { constants.hrRest(on: $0) },
                                      w: w,
                                      ftp: ftp,
                                      powerFactor: powerFactor,
                                      srpe: srpeByActivity,
                                      healthAverageHR: health,
                                      streams: details.streams))
        days = out
        // One assignment site for all three, so the two derived series cannot
        // describe a different day list from the one they were built from.
        pmc = PMCSummary(points: PMC.build(out))
        monotony = Monotony.series(pmc.points)
    }

    // MARK: Reading

    func day(_ key: String) -> DailyLoad? { days.first { $0.dayKey == key } }

    /// The fitness curve over the whole series.
    ///
    /// STORED, not computed on read. It used to be computed, on the reasoning
    /// that two multiply-adds per day is cheap and a cache is a second thing
    /// able to go stale. Both true — but SwiftUI re-evaluates a body on every
    /// stepper tap and every sync, and TodayView was written to build the curve
    /// only inside a branch to avoid paying for it on rest days. That
    /// constraint shaped the screen: the load strip could not be shown
    /// unconditionally because showing it meant building the curve
    /// unconditionally.
    ///
    /// It cannot go stale because it is assigned in exactly one place, at the
    /// end of the only function that assigns `days`.
    private(set) var pmc = PMCSummary(points: [])

    /// Foster monotony and strain, one point per day over the trailing week.
    /// Stored for the same reason, and derived from `pmc` so there is one
    /// definition of a daily load in the app rather than two.
    private(set) var monotony: [MonotonyPoint] = []
    var latestMonotony: MonotonyPoint? { monotony.last }

    /// Most recent first — the order a diagnostic list wants.
    var recent: [DailyLoad] { days.reversed() }

    func count(_ state: DayState) -> Int { days.filter { $0.state == state }.count }

    var gapCount: Int { count(.gap) }
    var partialCount: Int { count(.partial) }

    /// The share of days that can be used in a curve. Gaps are the only thing
    /// that cannot, so this is the honest headline for the whole engine.
    var coverage: Double {
        guard !days.isEmpty else { return 0 }
        return Double(days.filter { $0.state.isUsable }.count) / Double(days.count)
    }

    /// A window's total, carrying its own honesty with it.
    ///
    /// The gap count travels WITH the number rather than being available
    /// somewhere else on the screen. A bare total reads identically whether the
    /// week held three rest days or three sessions nothing could score, and the
    /// caller has no way to tell — which is how the distinction this file is
    /// built around gets lost at the last step.
    struct Window {
        let trimp: Double
        let gaps: Int
        let partials: Int

        var isClean: Bool { gaps == 0 && partials == 0 }
        var label: String {
            let n = String(format: "%.0f", trimp)
            if gaps > 0 { return "\(n) · \(gaps) gap\(gaps == 1 ? "" : "s")" }
            if partials > 0 { return "\(n) · \(partials) partial" }
            return n
        }
    }

    func total(from: String, to: String) -> Window {
        let w = days.filter { $0.dayKey >= from && $0.dayKey <= to }
        return Window(trimp: w.reduce(0) { $0 + $1.load },
                      gaps: w.filter { $0.state == .gap }.count,
                      partials: w.filter { $0.state == .partial }.count)
    }

    func total(lastDays n: Int, ending: String = DayKey.key()) -> Window {
        guard let end = DayKey.date(ending),
              let start = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: -(n - 1), to: end)
        else { return Window(trimp: 0, gaps: 0, partials: 0) }
        return total(from: DayKey.key(start), to: ending)
    }

    /// Every activity that could not be scored, most recent first. This is the
    /// working list — each row is either a fixable ingest problem or a real
    /// limit worth knowing about.
    var unscored: [WorkoutLoad] {
        recent.flatMap(\.unscored)
    }

    var scoredCount: Int { days.reduce(0) { $0 + $1.scored.count } }

    var sourceCounts: [LoadSource: Int] {
        var out: [LoadSource: Int] = [:]
        for d in days { for w in d.workouts { out[w.source, default: 0] += 1 } }
        return out
    }
}
