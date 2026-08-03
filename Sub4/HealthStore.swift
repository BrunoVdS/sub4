//
//  HealthStore.swift
//  Sub4
//
//  Daily step count from Apple Health. Read-only — never writes.
//
//  HARDENED: HealthKit is never queried unless authorisation has actually been
//  granted, and every query is bounded by a timeout. Without both, a missing
//  entitlement or an unserviceable query leaves the continuation unresumed and
//  the startup task hangs forever — which looks exactly like the app freezing.
//
//  SETUP (both required, or steps silently stay empty):
//   1. Target → Signing & Capabilities → + Capability → HealthKit
//   2. Target → Info → `Privacy - Health Share Usage Description`
//

import Foundation
import Observation
import HealthKit

@Observable
final class HealthStore {

    static let shared = HealthStore()

    private(set) var stepsByDay: [String: Int] = [:]
    private(set) var walkRunKmByDay: [String: Double] = [:]

    /// Daily resting heart rate, bpm. Feeds `ConstantsStore`, which turns it
    /// into a per-month figure — the denominator of every TRIMP the app will
    /// ever compute. Read-only, like everything else here.
    private(set) var restingHRByDay: [String: Double] = [:]
    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var lastError: String?

    /// Workouts as read from Health, cached in memory only.
    ///
    /// Not persisted, on purpose: it is derived data with an authoritative
    /// source one query away, and a stale copy surviving a relaunch would be
    /// indistinguishable on screen from a live one. Empty until something asks
    /// — `refresh()` deliberately does NOT populate it, because the launch path
    /// should not pay for a query most sessions never use.
    private(set) var cachedWorkouts: [HealthWorkout] = []
    private(set) var workoutsLoadedAt: Date?

    /// Set once the cache has been filled, so a caller can tell "no swims in
    /// Health" from "Health was never asked".
    var hasWorkoutCache: Bool { workoutsLoadedAt != nil }

    /// How many Health records the last read returned BEFORE deduplication.
    /// Kept so the diagnostic can show the collapse rather than hide it.
    private(set) var lastRawWorkoutCount = 0

    /// `private(set)` is file-scoped, and the queries live in
    /// HealthWorkouts.swift — so the writes go through here rather than the
    /// properties being opened up to the whole module.
    func storeWorkoutCache(_ workouts: [HealthWorkout]) {
        cachedWorkouts = workouts
        workoutsLoadedAt = Date()
    }

    func noteRawWorkoutCount(_ n: Int) { lastRawWorkoutCount = n }

    /// Persisted: HealthKit won't tell us on relaunch whether we were granted,
    /// so we remember that we successfully completed the request once.
    private(set) var isAuthorized: Bool {
        didSet { UserDefaults.standard.set(isAuthorized, forKey: Self.grantedKey) }
    }
    private static let grantedKey = "health.authorized"

    private let store = HKHealthStore()
    private var stepType: HKQuantityType { HKQuantityType(.stepCount) }
    private var walkRunType: HKQuantityType { HKQuantityType(.distanceWalkingRunning) }
    private var restingType: HKQuantityType { HKQuantityType(.restingHeartRate) }

    /// Workouts, and the swim distance samples inside them.
    ///
    /// `distanceSwimming` is requested SEPARATELY from the workout type.
    /// Permission to read a workout does not extend to the samples underneath
    /// it, and the swim fix lives entirely in those samples — a workout on its
    /// own carries one duration field, which is the number that cannot be
    /// trusted.
    private var workoutType: HKSampleType { HKObjectType.workoutType() }
    private var swimDistanceType: HKQuantityType { HKQuantityType(.distanceSwimming) }

    /// Heart rate INSIDE a workout, which is a different grant from resting
    /// heart rate. Needed because Strava does not always receive one: a
    /// strength session logged through Hevy arrives with reps, sets and
    /// calories and no HR at all, which turns a real training day into a gap.
    private var heartRateType: HKQuantityType { HKQuantityType(.heartRate) }

    /// The workout queries live in HealthWorkouts.swift and need the store and
    /// a way to report a failure. Internal, not public — same module.
    var healthStore: HKHealthStore { store }
    func noteError(_ message: String) { lastError = message }

    /// Bumped when the set of types we read changes. iOS only prompts for
    /// types it has not asked about before, so re-requesting is cheap — but it
    /// must actually be re-requested, or the new type silently returns nothing
    /// and looks like a device that has no data.
    ///
    /// 3 adds workouts and swim distance. 4 adds heart rate.
    private static let authVersion = 4
    private static let authVersionKey = "health.authVersion"

    /// True while resting heart rate is not arriving — never asked for, asked
    /// and denied, or granted with no data in the window. HealthKit cannot tell
    /// the three apart. Steps keep working meanwhile; this only gates the
    /// prompt.
    var needsRestingHRGrant: Bool {
        isAuthorized
            && UserDefaults.standard.integer(forKey: Self.authVersionKey) < Self.authVersion
    }

    /// Any single query taking longer than this is treated as failed.
    private let queryTimeout: Duration = .seconds(8)

    private init() {
        isAuthorized = UserDefaults.standard.bool(forKey: Self.grantedKey)
    }

    // MARK: Authorisation

    /// Info.plist key iOS demands before ANY HealthKit read call.
    private static let usageKey = "NSHealthShareUsageDescription"

    /// True only if the privacy string is actually present in the built bundle.
    ///
    /// This check is not optional politeness. If the key is missing, iOS raises
    /// an Objective-C `NSException` — which Swift's `do/catch` CANNOT intercept,
    /// so the process terminates. Pre-flighting is the only way to fail safely.
    var hasUsageDescription: Bool {
        let s = Bundle.main.object(forInfoDictionaryKey: Self.usageKey) as? String
        return !(s ?? "").isEmpty
    }

    @MainActor
    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "Health data isn't available on this device."
            return
        }
        guard hasUsageDescription else {
            lastError = """
                Missing “Privacy - Health Share Usage Description” in the target's \
                Info tab. iOS terminates the app if HealthKit is called without it, \
                so the request was not attempted.
                """
            return
        }
        do {
            try await store.requestAuthorization(
                toShare: [],
                read: [stepType, walkRunType, restingType,
                       workoutType, swimDistanceType, heartRateType])
            isAuthorized = true
            lastError = nil
            await refresh()
            // HealthKit never reports a DENIED read — the request succeeds
            // either way. So the only evidence that resting heart rate is
            // actually readable is resting heart rate arriving. Recording the
            // grant before checking would hide the prompt forever on a denial,
            // with no route back.
            if !restingHRByDay.isEmpty {
                UserDefaults.standard.set(Self.authVersion, forKey: Self.authVersionKey)
            }
        } catch {
            isAuthorized = false
            lastError = error.localizedDescription
        }
    }

    /// Called on launch. Does NOTHING unless we've been granted before — this is
    /// the guard that stops a missing entitlement hanging the startup task.
    @MainActor
    func refreshIfPossible() async {
        guard isAvailable, isAuthorized, hasUsageDescription else { return }
        await refresh()
    }

    // MARK: Queries

    /// `restingDaysBack` is deliberately much longer than the step window: the
    /// activity history now starts in January, and a January session has to be
    /// scored against January's resting rate, not this month's.
    @MainActor
    func refresh(daysBack: Int = 120,
                 restingDaysBack: Int = 420,
                 daysForward: Int = 1) async {
        guard isAvailable, isAuthorized, hasUsageDescription else { return }

        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: daysForward,
                           to: cal.startOfDay(for: Date())) ?? Date()
        let start = cal.date(byAdding: .day, value: -daysBack,
                             to: cal.startOfDay(for: Date())) ?? Date()
        let restStart = cal.date(byAdding: .day, value: -restingDaysBack,
                                 to: cal.startOfDay(for: Date())) ?? Date()

        async let steps = collect(stepType, unit: .count(), from: start, to: end)
        async let dist  = collect(walkRunType, unit: .meterUnit(with: .kilo),
                                  from: start, to: end)
        // Resting HR is a DISCRETE measurement — one reading per day. Summing
        // it, as the other two are summed, would produce a number in the
        // hundreds and it would look almost plausible.
        async let rest  = collect(restingType,
                                  unit: HKUnit.count().unitDivided(by: .minute()),
                                  from: restStart, to: end, statistic: .average)
        let (s, d, r) = await (steps, dist, rest)

        stepsByDay = s.mapValues { Int($0.rounded()) }
        walkRunKmByDay = d
        restingHRByDay = r

        ConstantsStore.shared.refreshFromSources(
            activities: ActivityStore.shared.activities,
            restingByDay: restingHRByDay)
    }

    // MARK: The button

    /// True while `recomputeEverything` is running, so the button can say so.
    private(set) var isRefreshing = false

    /// What the last run actually found. Without this the button is silent: it
    /// re-queries Health, recomputes the constants, and if the derived figures
    /// are unchanged — which is the normal case — absolutely nothing on screen
    /// moves and it looks broken.
    private(set) var lastRefreshSummary: String?

    /// Everything the "Recompute from Strava and Health" button should do.
    ///
    /// Three things the old inline version did not:
    ///
    ///  1. It never loaded the WORKOUT cache, so the swim pace and the
    ///     reconciliation screen were untouched by the one button whose label
    ///     says "and Health".
    ///  2. It never recorded the authorisation version, so the amber re-grant
    ///     block stayed on screen after a successful read — only
    ///     `requestAuthorization` cleared it.
    ///  3. It reported nothing at all.
    @MainActor
    func recomputeEverything() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard isAvailable, hasUsageDescription else {
            lastRefreshSummary = isAvailable
                ? "Not run — the privacy string is missing from the build."
                : "Not run — Health is not available on this device."
            return
        }
        guard isAuthorized else {
            // No grant means no query. Fall back to the Strava-only path so the
            // constants are still rebuilt, and say which one ran.
            ConstantsStore.shared.refreshFromSources(
                activities: ActivityStore.shared.activities,
                restingByDay: restingHRByDay)
            lastRefreshSummary = "Recomputed from Strava only — Health access "
                               + "has not been granted."
            return
        }

        await refresh()
        // maxAge 0 forces it: this button is the explicit "go and look now".
        await loadWorkoutCacheIfStale(since: MatchRules.cutoffDayKey, maxAge: 0)

        // HealthKit never reports a denied read, so the only evidence of a
        // grant is data arriving. Any of the three is enough — a device with no
        // workouts is not a denial.
        if !restingHRByDay.isEmpty || !cachedWorkouts.isEmpty || !stepsByDay.isEmpty {
            UserDefaults.standard.set(Self.authVersion, forKey: Self.authVersionKey)
        }

        let swims = cachedWorkouts.filter { $0.sport == .swim }
        let timed = swims.filter { $0.activeSeconds != nil }.count
        lastRefreshSummary =
            "\(stepsByDay.count) days of steps · "
            + "\(restingHRByDay.count) resting readings · "
            + "\(cachedWorkouts.count) workouts"
            + (swims.isEmpty ? "" : " · \(timed) of \(swims.count) swims have length samples")
    }

    func steps(on dayKey: String) -> Int? { stepsByDay[dayKey] }

    // `restingHRByDay` and `walkRunKmByDay` are still collected: the resting
    // series feeds the monthly percentile the load engine calibrates against,
    // and both would cost a second HealthKit backfill to re-gather if a reader
    // ever gets built. What was deleted in patch 170 is only the per-day
    // accessors nothing called.

    // MARK: Core

    enum Statistic { case sum, average }

    /// Bounded query. Returns [:] on error OR timeout — never hangs.
    private func collect(_ type: HKQuantityType,
                         unit: HKUnit,
                         from start: Date,
                         to end: Date,
                         statistic: Statistic = .sum) async -> [String: Double] {

        await withTaskGroup(of: [String: Double]?.self) { group in

            group.addTask { [weak self] in
                guard let self else { return [:] }
                return await self.runQuery(type, unit: unit, from: start, to: end,
                                           statistic: statistic)
            }

            group.addTask { [queryTimeout] in
                try? await Task.sleep(for: queryTimeout)
                return nil                      // nil == timed out
            }

            let first = await group.next() ?? [:]
            group.cancelAll()

            if first == nil {
                await MainActor.run {
                    self.lastError = "Health query timed out — check the HealthKit "
                                   + "capability and privacy string."
                }
                return [:]
            }
            return first ?? [:]
        }
    }

    private func runQuery(_ type: HKQuantityType,
                          unit: HKUnit,
                          from start: Date,
                          to end: Date,
                          statistic: Statistic) async -> [String: Double] {

        await withCheckedContinuation { cont in
            var resumed = false
            let finish: ([String: Double]) -> Void = { result in
                guard !resumed else { return }   // belt and braces
                resumed = true
                cont.resume(returning: result)
            }

            var interval = DateComponents()
            interval.day = 1

            // Resolved on this side of the boundary: HealthKit invokes the
            // handler below on its own queue, and comparing the enum there
            // would drag a main-actor conformance across with it.
            let wantsSum = statistic == .sum

            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(
                    withStart: start, end: end, options: .strictStartDate),
                options: wantsSum ? .cumulativeSum : .discreteAverage,
                anchorDate: Calendar.current.startOfDay(for: start),
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    Task { @MainActor in self.lastError = error.localizedDescription }
                    finish([:])
                    return
                }
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { s, _ in
                    let q = wantsSum ? s.sumQuantity() : s.averageQuantity()
                    if let q {
                        out[DayKey.key(s.startDate)] = q.doubleValue(for: unit)
                    }
                }
                finish(out)
            }

            store.execute(query)
        }
    }
}
