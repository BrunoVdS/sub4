//
//  HealthWorkouts.swift
//  Sub4
//
//  Reading workouts from Apple Health, and comparing them with Strava.
//
//  WHY THIS EXISTS BEFORE ANY FIX
//  ------------------------------
//  Strava's `moving_time` is a DERIVED field — its own auto-pause algorithm
//  applied after the fact — and on swims it is wrong in both directions. Pool
//  swims count rest as swimming (25 May, 3 200 m, reads 2:18 /100 m). Open
//  water loses the athlete under the surface and calls it stopped (14 June, the
//  Ironman leg, reads 1:10 /100 m — faster than the 1500 m world record).
//  Elapsed time fixes the first and not the second, so it is not a shortcut.
//
//  Health holds what the watch measured. But Health cannot replace Strava:
//  there is no concept of a shoe in HealthKit, so the gear join dies with it;
//  activity titles and the commute and trainer flags are Strava's; and a ride
//  recorded on a bike head unit reaches Strava having never touched the watch.
//
//  Which of those actually apply to THIS athlete is a question about his data,
//  not about the APIs — so this file answers it with the data rather than
//  guessing. It is the same day-and-start-time join the swim fix needs, built
//  first as a diagnostic so the scope of everything after it is decided by
//  evidence.
//
//  ACTIVE TIME COMES FROM THE DISTANCE SAMPLES, NOT FROM A DURATION FIELD
//  ---------------------------------------------------------------------
//  `HKWorkout.duration` is one number and inherits whatever the recorder
//  decided about pausing. The watch also writes a `distanceSwimming` sample per
//  length, each with its own start and end, and resting at the wall produces no
//  sample at all. Summing those intervals cannot count rest and cannot drop
//  swimming that happened, which is exactly the pair of failures above.
//
//  Both figures are kept and both are shown. If they disagree the disagreement
//  is the finding.
//
//  AND `HKWorkout.duration` IS NEITHER MOVING NOR ELAPSED TIME
//  ----------------------------------------------------------
//  An earlier version of this file asserted it equalled Strava's elapsed time.
//  It does on rides; it equals MOVING time on runs, because the watch
//  auto-pauses on those. It is recorded time minus whatever the recorder
//  paused, and no single Strava field corresponds to it. The measurements and
//  the consequence are in `ReconcileRow.durationOutsideBand`.
//
//  READ-ONLY, LIKE EVERYTHING ELSE HERE. This file never writes to Health.
//

import Foundation
import HealthKit

// MARK: - Model

struct HealthWorkout: Identifiable, Hashable {
    let id: String                 // HKWorkout UUID
    let start: Date
    let end: Date
    let dayKey: String
    /// nil for anything with no plan equivalent — walks, kayaking, yoga.
    let sport: Discipline?
    /// What HealthKit called it, kept for the rows that map to nothing.
    let rawType: String
    /// `HKWorkout.duration` — active time as the RECORDER understood it.
    let durationSeconds: Int
    /// Summed `distanceSwimming` sample intervals. Swims only, and nil when the
    /// samples are not there — an older watch, or a workout written by an app
    /// that only stored a total.
    var activeSeconds: Int?
    let distanceM: Double?
    /// Mean heart rate over the workout, from Health's own samples.
    ///
    /// The reason this exists: Strava does not always receive one. A strength
    /// session logged through Hevy reaches Strava with reps, sets and calories
    /// and no heart rate, so the load engine cannot score it and the day
    /// becomes a gap — imputed in the fitness curve and poisoning monotony for
    /// a week afterwards. The watch recorded the heart rate the whole time.
    let averageHeartRate: Double?
    /// Every app that wrote this session into Health. More than one is the
    /// NORMAL case here, not an anomaly — see `dedupe`.
    let sources: [String]

    /// Local minutes past midnight, for the join against
    /// `Activity.startMinuteOfDay`.
    let startMinuteOfDay: Int

    var km: Double { (distanceM ?? 0) / 1000 }

    var sourceLabel: String { sources.joined(separator: " + ") }
    /// How many Health records were collapsed into this one.
    var mergedCount: Int { Swift.max(sources.count, 1) }

    /// Seconds per 100 m from the samples where they exist, from the duration
    /// otherwise. nil when there is no distance to divide by.
    var swimPaceSec100m: Double? {
        guard sport == .swim, let d = distanceM, d > 50 else { return nil }
        let seconds = Double(activeSeconds ?? durationSeconds)
        guard seconds > 0 else { return nil }
        return seconds / (d / 100)
    }
}

// MARK: - Reading

extension HealthStore {

    /// Everything HealthKit calls a workout in the window, newest first.
    ///
    /// Returns [] rather than throwing on any failure — a diagnostic that
    /// crashes is worse than a diagnostic that says "nothing came back", and
    /// the caller cannot tell a denial from an empty store anyway.
    @MainActor
    func workouts(from start: Date, to end: Date) async -> [HealthWorkout] {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return [] }

        let raw = await withTaskGroup(of: [HealthWorkout]?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return [] }
                return await self.runWorkoutQuery(from: start, to: end)
            }
            group.addTask { [workoutTimeout] in
                try? await Task.sleep(for: workoutTimeout)
                return nil
            }
            let first = await group.next() ?? []
            group.cancelAll()
            if first == nil {
                await MainActor.run {
                    self.noteError("Health workout query timed out.")
                }
                return [HealthWorkout]()
            }
            return first ?? []
        }

        // DEDUPE BEFORE ENRICHING, both for correctness and for cost.
        //
        // This athlete's Health store holds the same session three times: the
        // watch records it, the Strava app writes a copy back, and Garmin
        // Connect writes a third. Enriching first would run three sample
        // queries per swim and then still have to collapse them.
        noteRawWorkoutCount(raw.count)
        var out = HealthWorkout.dedupe(raw)

        // Only swims need the second pass. Capped because this is one query per
        // swim and the window is seven months.
        var enriched = 0
        for i in out.indices where out[i].sport == .swim && enriched < Self.maxSwimEnrich {
            out[i].activeSeconds = await swimActiveSeconds(from: out[i].start,
                                                           to: out[i].end)
            enriched += 1
        }
        return out
    }

    /// Above this many swims the enrichment stops — the totals stay correct,
    /// the later rows simply fall back to the duration field and say so.
    static var maxSwimEnrich: Int { 80 }

    /// Fill `cachedWorkouts`, at most once an hour.
    ///
    /// Called from the views that want to prefer Health over Strava. The
    /// throttle matters because this is one query plus one per swim, and a
    /// SwiftUI `.task` fires on every appearance of the view.
    @MainActor
    func loadWorkoutCacheIfStale(since cutoff: String, maxAge: TimeInterval = 3600) async {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return }
        if let at = workoutsLoadedAt, Date().timeIntervalSince(at) < maxAge { return }
        guard let start = DayKey.date(cutoff) else { return }
        let found = await workouts(from: start, to: Date())
        // A failed or timed-out query returns []. Recording the timestamp
        // anyway is deliberate: without it a device that cannot answer is
        // re-queried on every appearance of every view that asks.
        storeWorkoutCache(found)
    }

    /// The Health workout matching one Strava activity, by the same rule the
    /// reconciliation screen uses. nil when Health has nothing for it.
    /// The Health session matching one Strava activity.
    ///
    /// Among candidates, one carrying length samples wins over one that does
    /// not, and only then is proximity used. Before the dedupe pass this
    /// mattered a great deal — three records for the same swim, and picking the
    /// nearest start could land on the copy with no samples and silently fall
    /// back to Strava's timing, which is the number the whole exercise exists
    /// to avoid. It is kept as a belt-and-braces ordering.
    func healthMatch(for a: Activity) -> HealthWorkout? {
        guard let sport = a.discipline else { return nil }
        let candidates = cachedWorkouts.filter {
            $0.dayKey == a.dayKey && $0.sport == sport
                && abs($0.startMinuteOfDay - a.startMinuteOfDay)
                    <= HealthReconcile.toleranceMinutes
        }
        return candidates.min { x, y in
            let xs = x.activeSeconds != nil, ys = y.activeSeconds != nil
            if xs != ys { return xs }
            return abs(x.startMinuteOfDay - a.startMinuteOfDay)
                 < abs(y.startMinuteOfDay - a.startMinuteOfDay)
        }
    }

    private var workoutTimeout: Duration { .seconds(12) }

    private func runWorkoutQuery(from start: Date, to end: Date) async -> [HealthWorkout] {
        await withCheckedContinuation { cont in
            var resumed = false
            let finish: ([HealthWorkout]) -> Void = { r in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: r)
            }

            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                        ascending: false)

            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout]) ?? []
                finish(workouts.map(HealthWorkout.make))
            }

            healthStore.execute(query)
        }
    }

    /// Sum of the `distanceSwimming` sample intervals inside one workout.
    ///
    /// Deliberately queried by DATE RANGE rather than by
    /// `HKQuery.predicateForObjects(from:)`. The association predicate returns
    /// nothing when the samples were written by a different source than the
    /// workout — which is exactly the case when Strava, not the watch, owns the
    /// workout record. The date range costs an occasional neighbouring sample
    /// and works in both cases.
    private func swimActiveSeconds(from start: Date, to end: Date) async -> Int? {
        await withCheckedContinuation { cont in
            var resumed = false
            let finish: (Int?) -> Void = { v in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: v)
            }

            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: [])
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.distanceSwimming),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                guard let samples, !samples.isEmpty else { finish(nil); return }
                // Union of the intervals, not the sum: overlapping samples from
                // two sources would otherwise double-count the same length.
                let spans = samples
                    .map { ($0.startDate, $0.endDate) }
                    .sorted { $0.0 < $1.0 }
                var total: TimeInterval = 0
                var cursor: Date?
                var openStart: Date?
                for (s, e) in spans {
                    if openStart == nil { openStart = s; cursor = e; continue }
                    if let c = cursor, s <= c {
                        cursor = Swift.max(c, e)
                    } else {
                        if let o = openStart, let c = cursor { total += c.timeIntervalSince(o) }
                        openStart = s; cursor = e
                    }
                }
                if let o = openStart, let c = cursor { total += c.timeIntervalSince(o) }
                finish(total > 0 ? Int(total.rounded()) : nil)
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - Deduplication

extension HealthWorkout {

    /// Collapse the same real session, written by several apps, into one.
    ///
    /// THIS IS THE NORMAL CASE, NOT AN EDGE CASE. On 6 May 2026 one ride sits
    /// in Health three times:
    ///
    ///     Bruno's Apple Watch   2:58:51     the watch's own recording
    ///     Strava               2:55:28     equals Strava's elapsed_time
    ///     Connect              2:47:55     equals Strava's moving_time
    ///
    /// The watch records it, the Strava app writes a copy back into Health, and
    /// Garmin Connect writes a third from the head unit. Without this pass the
    /// reconciliation matched one arbitrarily and reported the other two as
    /// "sessions Strava never received" — 25 rows of them, every one a
    /// duplicate of something Strava had. It also inflated the workout count
    /// threefold and made "23 of 23 swims have length samples" a claim about
    /// roughly eight real swims.
    ///
    /// WHAT IS KEPT
    /// -----------
    /// The longest duration, because that is the most complete view of the
    /// session and the shorter copies are other apps' opinions about pausing.
    /// The largest distance. Any `activeSeconds` that exists, since a copy
    /// without samples carries no information the one with samples lacks. And
    /// every source name, so the merge is visible rather than silent.
    static func dedupe(_ all: [HealthWorkout]) -> [HealthWorkout] {
        var out: [HealthWorkout] = []
        for w in all.sorted(by: { $0.start < $1.start }) {
            if let i = out.lastIndex(where: { isSameSession($0, w) }) {
                out[i] = merged(out[i], w)
            } else {
                out.append(w)
            }
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Same sport, overlapping in time, and not contradicting each other on
    /// distance.
    ///
    /// Overlap rather than equal start times: the three copies above begin
    /// within a couple of minutes of each other but not on the same second, and
    /// each has its own idea of where the session ended. The distance test is
    /// what stops two genuinely separate sessions on one afternoon — the two
    /// runs on 14 June, 64 minutes apart — from being merged; they do not
    /// overlap, but a 5% band means even a near-miss on time cannot join a
    /// 7.4 km run to a 5.0 km one.
    static func isSameSession(_ a: HealthWorkout, _ b: HealthWorkout) -> Bool {
        guard a.sport == b.sport else { return false }
        guard a.start < b.end, b.start < a.end else { return false }
        if let x = a.distanceM, let y = b.distanceM, x > 0, y > 0 {
            return abs(x - y) / Swift.max(x, y) <= 0.05
        }
        return true
    }

    static func merged(_ a: HealthWorkout, _ b: HealthWorkout) -> HealthWorkout {
        let keepLonger = b.durationSeconds > a.durationSeconds
        let base = keepLonger ? b : a
        var names = a.sources
        for n in b.sources where !names.contains(n) { names.append(n) }
        return HealthWorkout(
            id: base.id,
            start: Swift.min(a.start, b.start),
            end: Swift.max(a.end, b.end),
            dayKey: base.dayKey,
            sport: base.sport,
            rawType: base.rawType,
            durationSeconds: Swift.max(a.durationSeconds, b.durationSeconds),
            activeSeconds: a.activeSeconds ?? b.activeSeconds,
            distanceM: [a.distanceM, b.distanceM].compactMap { $0 }.max(),
            // Either copy will do — they describe the same session — but a
            // copy written by an app that only stored a total has none.
            averageHeartRate: a.averageHeartRate ?? b.averageHeartRate,
            sources: names,
            startMinuteOfDay: a.start <= b.start ? a.startMinuteOfDay : b.startMinuteOfDay)
    }
}

// MARK: - Mapping

extension HealthWorkout {

    nonisolated static func make(_ w: HKWorkout) -> HealthWorkout {
        let sport = discipline(for: w.workoutActivityType)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: w.startDate)

        return HealthWorkout(
            id: w.uuid.uuidString,
            start: w.startDate,
            end: w.endDate,
            dayKey: DayKey.key(w.startDate),
            sport: sport,
            rawType: name(for: w.workoutActivityType),
            durationSeconds: Int(w.duration.rounded()),
            activeSeconds: nil,
            distanceM: distance(w, sport: sport),
            averageHeartRate: w.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?
                .doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            sources: [w.sourceRevision.source.name],
            startMinuteOfDay: (comps.hour ?? 0) * 60 + (comps.minute ?? 0))
    }

    /// `statistics(for:)` rather than `totalDistance`, which is deprecated and
    /// which returns whatever single type the recorder happened to file it as.
    private nonisolated static func distance(_ w: HKWorkout,
                                             sport: Discipline?) -> Double? {
        let type: HKQuantityType?
        switch sport {
        case .run:  type = HKQuantityType(.distanceWalkingRunning)
        case .bike: type = HKQuantityType(.distanceCycling)
        case .swim: type = HKQuantityType(.distanceSwimming)
        default:    type = nil
        }
        guard let type,
              let q = w.statistics(for: type)?.sumQuantity() else { return nil }
        return q.doubleValue(for: .meter())
    }

    private nonisolated static func discipline(
        for t: HKWorkoutActivityType) -> Discipline? {
        switch t {
        case .running, .trackAndField:
            return .run
        case .cycling, .handCycling:
            return .bike
        case .swimming:
            return .swim
        case .traditionalStrengthTraining, .functionalStrengthTraining,
             .coreTraining, .highIntensityIntervalTraining, .crossTraining:
            return .strength
        default:
            return nil
        }
    }

    private nonisolated static func name(for t: HKWorkoutActivityType) -> String {
        switch t {
        case .running:                     "Running"
        case .cycling:                     "Cycling"
        case .swimming:                    "Swimming"
        case .walking:                     "Walking"
        case .hiking:                      "Hiking"
        case .rowing:                      "Rowing"
        case .paddleSports:                "Paddling"
        case .traditionalStrengthTraining: "Strength"
        case .functionalStrengthTraining:  "Functional strength"
        case .coreTraining:                "Core"
        case .highIntensityIntervalTraining: "HIIT"
        case .crossTraining:               "Cross training"
        case .swimBikeRun:                 "Multisport"
        case .yoga:                        "Yoga"
        default:                           "Other (\(t.rawValue))"
        }
    }
}

// MARK: - The join

/// One line of the comparison: a Health workout, a Strava activity, or both.
struct ReconcileRow: Identifiable {
    let id: String
    let dayKey: String
    let sport: Discipline?
    let health: HealthWorkout?
    let strava: Activity?

    var inBoth: Bool { health != nil && strava != nil }
    var healthOnly: Bool { health != nil && strava == nil }
    var stravaOnly: Bool { health == nil && strava != nil }

    var date: Date { health?.start ?? DayKey.date(dayKey) ?? .distantPast }

    /// How far Health's duration falls OUTSIDE the band Strava reports.
    ///
    /// Zero means inside the band, which is agreement. Negative means shorter
    /// than Strava's moving time; positive means longer than its elapsed time.
    ///
    /// WHY A BAND AND NOT A NUMBER
    /// ---------------------------
    /// `HKWorkout.duration` is recorded time minus whatever the RECORDER
    /// paused, and that lands in a different place depending on who recorded
    /// it. Measured on this athlete:
    ///
    ///     1 May run    moving 1:05:00  elapsed 1:14:07  Health 1:05:00
    ///     15 May run   moving   45:45  elapsed   47:55  Health   45:46
    ///     7 May ride   moving 7:13:32  elapsed 8:09:22  Health 8:09:22
    ///     3 May ride   moving 4:45:14  elapsed 5:50:09  Health 5:50:09
    ///
    /// The watch auto-pauses on runs, so duration tracks MOVING time. On rides
    /// where the Strava-written copy is longest and wins the merge, it tracks
    /// ELAPSED. There is no single Strava field it corresponds to.
    ///
    /// Two earlier versions each picked one and were wrong in opposite
    /// directions: against moving time this reported 59 disagreements out of
    /// 116, against elapsed it reported 44. Both were measuring the choice
    /// rather than the data. A duration anywhere between the two is the
    /// recorder and Strava agreeing as closely as two pause algorithms can.
    var durationOutsideBand: Int? {
        guard let h = health, let s = strava else { return nil }
        let lo = Swift.min(s.movingTime, s.elapsedTime)
        let hi = Swift.max(s.movingTime, s.elapsedTime)
        if h.durationSeconds < lo { return h.durationSeconds - lo }
        if h.durationSeconds > hi { return h.durationSeconds - hi }
        return 0
    }

    /// The band itself, for display. One figure when Strava's two agree.
    var stravaBand: String? {
        guard let s = strava else { return nil }
        let lo = Swift.min(s.movingTime, s.elapsedTime)
        let hi = Swift.max(s.movingTime, s.elapsedTime)
        return lo == hi ? Fmt.duration(lo)
                        : "\(Fmt.duration(lo))\u{2013}\(Fmt.duration(hi))"
    }

    /// Sample-derived active time against Strava's moving time. Swims only,
    /// because only swims carry length samples — and this IS the comparison the
    /// screen exists for: both sides claim to be time spent moving, so a
    /// difference here is a real defect rather than a unit mismatch.
    var activeDelta: Int? {
        guard let h = health, let s = strava, let active = h.activeSeconds
        else { return nil }
        return s.movingTime - active
    }
}

enum HealthReconcile {

    /// Same day, same sport, started within this many minutes of each other.
    ///
    /// Ten rather than two, because Strava stamps the local start of the
    /// upload's own clock and a watch that began recording before the GPS lock
    /// can differ by several minutes on the same session. Two runs on one day
    /// (14 June) are 64 minutes apart, so ten is nowhere near ambiguous here.
    static let toleranceMinutes = 10

    /// Only sessions the app actually reasons about. The commute would
    /// otherwise contribute eighteen rows a month of pure noise, and it is
    /// already excluded everywhere else.
    static func isRelevant(_ a: Activity) -> Bool {
        switch a.discipline {
        case .run, .swim: return true
        case .bike, .strength: return a.isPlanEligible
        default: return false
        }
    }

    /// The SAME rule, applied to the Health side.
    ///
    /// The first version filtered only the Strava side, and the asymmetry
    /// produced a badly wrong headline: every commute ride recorded on the
    /// watch had no Strava candidate to match — because commutes had been
    /// filtered out of the pool — so each one was reported as "Health only",
    /// meaning a session the app cannot see. On this athlete's data that put
    /// 156 rows in a bucket whose whole purpose is to say "Strava never
    /// received this", when Strava had received all of them.
    ///
    /// A workout with no distance is KEPT. Not knowing how far it went is not
    /// evidence that it was short, and silently dropping it would repeat the
    /// same mistake in the other direction.
    /// A workout with no distance has to last long enough to be a session.
    ///
    /// The original rule kept every distance-less record on the grounds that
    /// not knowing how far it went is not evidence that it was short. Correct
    /// in principle, and on this athlete's data it produced five Health-only
    /// rows and all five were noise: cycling records of 1:35, 1:45, 2:59, 3:16
    /// and 11:27 with no distance at all — the watch's "looks like you are
    /// cycling" prompt accepted and then abandoned. They never reached Strava
    /// because there was nothing to send.
    ///
    /// Fifteen minutes is above every one of them and below any session worth
    /// the name.
    static let minDistancelessSeconds = 900

    static func isRelevant(_ w: HealthWorkout) -> Bool {
        switch w.sport {
        case .run, .swim:
            guard w.distanceM == nil else { return true }
            return w.durationSeconds >= minDistancelessSeconds
        case .bike:
            guard let m = w.distanceM else {
                return w.durationSeconds >= minDistancelessSeconds
            }
            return m / 1000 >= MatchRules.minRideKm
        case .strength:
            // Never carries a distance, so duration is the only test there is.
            return w.durationSeconds >= minDistancelessSeconds
        default: return false
        }
    }

    static func build(health: [HealthWorkout],
                      activities: [Activity],
                      since cutoff: String) -> [ReconcileRow] {

        let pool = activities.filter { $0.dayKey >= cutoff && isRelevant($0) }
        var byDay: [String: [Activity]] = [:]
        for a in pool { byDay[a.dayKey, default: []].append(a) }

        var used: Set<String> = []
        var rows: [ReconcileRow] = []

        for w in health where w.dayKey >= cutoff {
            // A workout with no plan equivalent — a walk, a kayak — is not a
            // gap in Strava. It is simply not this app's business. Nor is a
            // commute: see `isRelevant(_ w:)`.
            guard let sport = w.sport, isRelevant(w) else { continue }

            let candidate = (byDay[w.dayKey] ?? [])
                .filter { $0.discipline == sport && !used.contains($0.id) }
                .min { a, b in
                    abs(a.startMinuteOfDay - w.startMinuteOfDay)
                        < abs(b.startMinuteOfDay - w.startMinuteOfDay)
                }
            let match = candidate.flatMap {
                abs($0.startMinuteOfDay - w.startMinuteOfDay) <= toleranceMinutes ? $0 : nil
            }
            if let match { used.insert(match.id) }
            rows.append(ReconcileRow(id: w.id, dayKey: w.dayKey, sport: sport,
                                     health: w, strava: match))
        }

        for a in pool where !used.contains(a.id) {
            rows.append(ReconcileRow(id: a.id, dayKey: a.dayKey,
                                     sport: a.discipline, health: nil, strava: a))
        }

        return rows.sorted { $0.date > $1.date }
    }

    struct Totals {
        var both = 0, healthOnly = 0, stravaOnly = 0
        /// Matched pairs whose Health duration falls outside Strava's
        /// moving–elapsed band by more than a minute.
        var disputed = 0
        /// Sessions that had more than one Health record, and the extra
        /// records absorbed. Reported over the RECONCILED set rather than the
        /// whole store — "330 raw → 310 deduped" invited the reading that
        /// dedup had barely worked, when the raw figure is dominated by walks
        /// and commutes that only ever had one writer.
        var sessionsMerged = 0
        var recordsAbsorbed = 0
        /// Matched swims where the length samples and Strava's moving time
        /// disagree by more than a minute. This one SHOULD be large: it is the
        /// defect the screen was built to measure.
        var swimsDisputed = 0
        /// Matched swims where the samples give a different answer from the
        /// duration field — the specific defect this was built to measure.
        var swimsWithSamples = 0

        var total: Int { both + healthOnly + stravaOnly }
    }

    static func totals(_ rows: [ReconcileRow]) -> Totals {
        var t = Totals()
        for r in rows {
            if r.inBoth { t.both += 1 } else if r.healthOnly { t.healthOnly += 1 }
            else { t.stravaOnly += 1 }
            if let d = r.durationOutsideBand, abs(d) > 60 { t.disputed += 1 }
            if let h = r.health, h.mergedCount > 1 {
                t.sessionsMerged += 1
                t.recordsAbsorbed += h.mergedCount - 1
            }
            if let d = r.activeDelta, abs(d) > 60 { t.swimsDisputed += 1 }
            if r.sport == .swim, r.health?.activeSeconds != nil { t.swimsWithSamples += 1 }
        }
        return t
    }
}
