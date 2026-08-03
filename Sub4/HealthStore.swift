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
// For `UIApplication.openSettingsURLString` — the only way to send someone to
// the page where Health permissions are actually changed. See
// `systemSettingsURL`.
import UIKit

@Observable
final class HealthStore {

    static let shared = HealthStore()

    private(set) var stepsByDay: [String: Int] = [:]
    private(set) var walkRunKmByDay: [String: Double] = [:]

    /// Daily resting heart rate, bpm. Feeds `ConstantsStore`, which turns it
    /// into a per-month figure — the denominator of every TRIMP the app will
    /// ever compute. Read-only, like everything else here.
    private(set) var restingHRByDay: [String: Double] = [:]

    /// The clock each of the days above was counted on.
    ///
    /// MOVED TO `ActivityStore` IN PATCH 201. It lived here for one patch, and
    /// that was wrong in a way worth leaving a note about: it was populated
    /// inside `refresh()`, which returns early when Health is unavailable or
    /// unauthorised — so on those devices the zones would have stayed empty for
    /// ever, and the Week tab would have shown no marker for a trip it had all
    /// the evidence for. The zones come from activities. Health is a consumer,
    /// not the owner.
    var dayZones: DayZones { ActivityStore.shared.dayZones }

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
    private(set) var hasRequestedAuthorization: Bool {
        didSet { UserDefaults.standard.set(hasRequestedAuthorization, forKey: Self.grantedKey) }
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

    /// READ SINCE THE RIDE ENRICHMENT WAS WRITTEN, REQUESTED SINCE PATCH 181 —
    /// this is `HK-02`.
    ///
    /// `HealthWorkouts` asks for `distanceCycling` when enriching a ride, and
    /// this type appeared in no authorisation request. HealthKit does not report
    /// a denied read: an unrequested type returns an empty result exactly as a
    /// device with no cycling data would. So the failure was invisible — no
    /// error, no prompt, no missing-permission warning — just rides that never
    /// gained a distance and looked like rides nobody had recorded properly.
    ///
    /// Adding it to the request is the fix; bumping `authVersion` below is what
    /// makes the fix reach an install that has already been granted once.
    private var cyclingDistanceType: HKQuantityType { HKQuantityType(.distanceCycling) }

    /// Every type this app reads, in one place, so the authorisation request
    /// cannot drift from the queries again. Adding a read anywhere in the module
    /// means adding it here, and `HealthTypeTests` asserts the count.
    var typesRead: [HKObjectType] {
        [stepType, walkRunType, restingType,
         workoutType, swimDistanceType, heartRateType, cyclingDistanceType]
    }

    /// The same list in words, for the Settings row, the permission explanation
    /// and the data-lifecycle inventory. The purpose string iOS shows at the
    /// prompt must describe this set — it currently names step count alone,
    /// which is the other half of `PRIV-02` and lives in the target's build
    /// settings rather than in this file.
    static let typesReadDescribed = [
        "Steps", "Walking and running distance", "Resting heart rate",
        "Workouts", "Swimming distance", "Heart rate", "Cycling distance"
    ]

    /// The workout queries live in HealthWorkouts.swift and need the store and
    /// a way to report a failure. Internal, not public — same module.
    var healthStore: HKHealthStore { store }
    func noteError(_ message: String) { lastError = message }

    /// Bumped when the set of types we read changes. iOS only prompts for
    /// types it has not asked about before, so re-requesting is cheap — but it
    /// must actually be re-requested, or the new type silently returns nothing
    /// and looks like a device that has no data.
    ///
    /// 3 adds workouts and swim distance. 4 adds heart rate. 5 adds cycling
    /// distance, which had been read without ever being asked for (HK-02).
    private static let authVersion = 5
    private static let authVersionKey = "health.authVersion"

    /// True while resting heart rate is not arriving — never asked for, asked
    /// and denied, or granted with no data in the window. HealthKit cannot tell
    /// the three apart. Steps keep working meanwhile; this only gates the
    /// prompt.
    var needsRestingHRGrant: Bool {
        hasRequestedAuthorization
            && UserDefaults.standard.integer(forKey: Self.authVersionKey) < Self.authVersion
    }

    /// Any single query taking longer than this is treated as failed.
    private let queryTimeout: Duration = .seconds(8)

    private init() {
        hasRequestedAuthorization = UserDefaults.standard.bool(forKey: Self.grantedKey)
    }

    // MARK: Authorisation

    /// Info.plist key iOS demands before ANY HealthKit read call.
    nonisolated static let usageKey = "NSHealthShareUsageDescription"

    /// The bundle this class was compiled into.
    ///
    /// In the running app this is `Bundle.main` and nothing changes. In the test
    /// target it is the app bundle rather than the xctest runner, and that is
    /// the entire reason it exists: the purpose string is a build setting, so
    /// the only way to hold it to the type list is to read it back out of the
    /// product. `Bundle.main` would have returned the runner and found nothing.
    nonisolated static var hostBundle: Bundle { Bundle(for: HealthStore.self) }

    /// The text a person is shown at the permission prompt, read back from the
    /// built product. `nil` means the build setting is missing.
    nonisolated static var usageDescription: String? {
        hostBundle.object(forInfoDictionaryKey: usageKey) as? String
    }

    /// True only if the privacy string is actually present in the built bundle.
    ///
    /// This check is not optional politeness. If the key is missing, iOS raises
    /// an Objective-C `NSException` — which Swift's `do/catch` CANNOT intercept,
    /// so the process terminates. Pre-flighting is the only way to fail safely.
    var hasUsageDescription: Bool {
        !(Self.usageDescription ?? "").isEmpty
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
            // `typesRead`, not a second list written out here. The two versions
            // of this set diverged once already and cost a silently empty read
            // for every ride — see `cyclingDistanceType`.
            try await store.requestAuthorization(toShare: [], read: Set(typesRead))
            hasRequestedAuthorization = true
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
            hasRequestedAuthorization = false
            lastError = error.localizedDescription
        }
    }

    /// Called on launch. Does NOTHING unless we've been granted before — this is
    /// the guard that stops a missing entitlement hanging the startup task.
    @MainActor
    func refreshIfPossible() async {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return }
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
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return }

        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: daysForward,
                           to: cal.startOfDay(for: Date())) ?? Date()
        let start = cal.date(byAdding: .day, value: -daysBack,
                             to: cal.startOfDay(for: Date())) ?? Date()
        let restStart = cal.date(byAdding: .day, value: -restingDaysBack,
                                 to: cal.startOfDay(for: Date())) ?? Date()

        // Built once, from the activities, and passed down — ADR-0003 §4.5.
        //
        // READ HERE RATHER THAN INSIDE THE QUERY. `ActivityStore` is
        // main-actor state and the queries run on HealthKit's own queue; a
        // value type crossing that boundary once is the whole reason `DayZones`
        // is a struct of offsets rather than a reference to the store.
        //
        // On a device that has never left home this yields a single run and
        // every query below is exactly the one query it was before.
        let zones = ActivityStore.shared.dayZones

        async let steps = collect(stepType, unit: .count(), from: start, to: end,
                                  zones: zones)
        async let dist  = collect(walkRunType, unit: .meterUnit(with: .kilo),
                                  from: start, to: end, zones: zones)
        // Resting HR is a DISCRETE measurement — one reading per day. Summing
        // it, as the other two are summed, would produce a number in the
        // hundreds and it would look almost plausible.
        async let rest  = collect(restingType,
                                  unit: HKUnit.count().unitDivided(by: .minute()),
                                  from: restStart, to: end, statistic: .average,
                                  zones: zones)
        let (s, d, r) = await (steps, dist, rest)

        // LAST KNOWN GOOD SURVIVES A FAILURE — patch 181, `HK-02`.
        //
        // Each series is only replaced when its own query actually succeeded.
        // One failing read no longer takes the other two down with it, and a
        // transient failure no longer erases a hundred and twenty days of steps
        // and replaces them with a zero that looks like a measurement.
        if let v = s.values {
            stepsByDay = v.mapValues { Int($0.rounded()) }
        }
        if let v = d.values { walkRunKmByDay = v }
        if let v = r.values { restingHRByDay = v }

        stepsStatus = status(for: s, count: stepsByDay.count)
        walkRunStatus = status(for: d, count: walkRunKmByDay.count)
        restingHRStatus = status(for: r, count: restingHRByDay.count)
        lastRefreshAttempt = Date()

        // Fed the CURRENT series rather than whatever this pass returned — on a
        // failed read that is the previous good data, which is the point.
        ConstantsStore.shared.refreshFromSources(
            activities: ActivityStore.shared.activities,
            restingByDay: restingHRByDay)
    }

    // MARK: What each series actually knows
    //
    // Plan step 2.2.6. HealthKit refuses to say whether a read was denied — the
    // request succeeds either way — so "granted" is a claim this app cannot
    // make and used to make anyway. These five states are what it CAN
    // distinguish, and each one implies something different about whether to
    // retry, re-prompt, or leave the reader alone.

    enum SeriesStatus: Equatable {
        /// Never asked, or asked and nothing has come back yet.
        case notRequested
        /// The query ran and the window genuinely held nothing. On a new phone
        /// this is the honest answer and not a fault.
        case noData
        /// Readings arrived. The count is what makes this legible in Settings —
        /// "120 days" reads very differently from "1 day".
        case ok(count: Int)
        /// The query returned an error. Whatever was held before is still held.
        case failed(String)
        /// The query exceeded its bound. Distinct from `failed` because it is
        /// the state a missing capability or entitlement produces.
        case timedOut

        var label: String {
            switch self {
            case .notRequested:    "not requested"
            case .noData:          "no data in range"
            case .ok(let n):       "\(n) day\(n == 1 ? "" : "s")"
            case .failed:          "query failed"
            case .timedOut:        "timed out"
            }
        }

        /// True where the reader should be shown something is wrong. `noData` is
        /// deliberately not a problem: a device with no swims is not broken.
        var isProblem: Bool {
            switch self {
            case .failed, .timedOut: true
            case .notRequested, .noData, .ok: false
            }
        }
    }

    private(set) var stepsStatus: SeriesStatus = .notRequested
    private(set) var walkRunStatus: SeriesStatus = .notRequested
    private(set) var restingHRStatus: SeriesStatus = .notRequested
    private(set) var lastRefreshAttempt: Date?

    private func status(for outcome: QueryOutcome, count: Int) -> SeriesStatus {
        switch outcome {
        case .ok(let v):     v.isEmpty ? .noData : .ok(count: count)
        case .failed(let m): .failed(m)
        case .timedOut:      .timedOut
        }
    }

    /// Everything that went wrong on the last pass, for one Settings line.
    var failingSeries: [String] {
        var out: [String] = []
        if stepsStatus.isProblem { out.append("steps") }
        if walkRunStatus.isProblem { out.append("distance") }
        if restingHRStatus.isProblem { out.append("resting heart rate") }
        return out
    }

    /// Deep link to this app's page in Settings, where Health permissions are
    /// actually changed — plan step 2.2.9. The app cannot alter them itself and
    /// should not pretend to; it can only point.
    static var systemSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
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
        guard hasRequestedAuthorization else {
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

    /// WHY THIS IS NOT `[String: Double]` ANY MORE — patch 181, `HK-02`.
    ///
    /// `collect` used to return `[:]` for three different things: the query
    /// succeeded and the window held nothing, the query failed, and the query
    /// timed out. `refresh` then assigned that dictionary over the live one,
    /// so a single failed read replaced a hundred and twenty days of steps with
    /// nothing — and the screen showed zero, which is a measurement, rather
    /// than a gap, which is the truth.
    ///
    /// This is the same distinction the load engine makes everywhere else
    /// between a real zero and an absence, applied to the one place that was
    /// still collapsing them.
    enum QueryOutcome {
        case ok([String: Double])
        case failed(String)
        case timedOut

        var values: [String: Double]? {
            if case .ok(let v) = self { return v }
            return nil
        }
    }

    /// Bounded query, run once per stretch of days sharing one clock — patch
    /// 198, ADR-0003 §4.5.
    ///
    /// WHY THIS IS NOT ONE QUERY ANY MORE.
    ///
    /// `HKStatisticsCollectionQuery` takes a single `anchorDate` and a single
    /// interval, so every bucket it returns is cut on one clock. That is
    /// exactly the behaviour being fixed: whichever clock the phone is on when
    /// the query runs becomes the clock the whole history is counted on, and
    /// a month of Japanese days silently re-cuts itself on landing.
    ///
    /// A window that spans a trip is therefore split into runs — home, away,
    /// home — and each run is asked for separately with its own anchor and its
    /// own labelling. `DayZones.runs` guarantees the runs partition the window
    /// with no overlap, so nothing is counted twice at a boundary.
    ///
    /// The common case costs nothing: a device that has never left home yields
    /// a single run, which is the same one query as before.
    ///
    /// FAILURE IS ALL-OR-NOTHING, ON PURPOSE. If any run fails or times out,
    /// the whole collection reports that failure and the caller keeps its
    /// previous good series — patch 181's rule. Merging the runs that did
    /// succeed would produce a series with a silent hole in it, which is the
    /// shape of answer this store already refuses to give.
    private func collect(_ type: HKQuantityType,
                         unit: HKUnit,
                         from start: Date,
                         to end: Date,
                         statistic: Statistic = .sum,
                         zones: DayZones) async -> QueryOutcome {

        let runs = zones.runs(from: start, to: end)
        guard runs.count > 1 else {
            let zone = runs.first?.zone ?? TimeZone.current
            return await bounded(type, unit: unit, from: start, to: end,
                                 statistic: statistic, zone: zone)
        }

        var merged: [String: Double] = [:]
        for run in runs {
            let outcome = await bounded(type, unit: unit, from: run.start, to: run.end,
                                        statistic: statistic, zone: run.zone)
            switch outcome {
            case .ok(let values): merged.merge(values) { _, new in new }
            case .failed, .timedOut: return outcome
            }
        }
        return .ok(merged)
    }

    private func bounded(_ type: HKQuantityType,
                         unit: HKUnit,
                         from start: Date,
                         to end: Date,
                         statistic: Statistic,
                         zone: TimeZone) async -> QueryOutcome {

        await withTaskGroup(of: QueryOutcome?.self) { group in

            group.addTask { [weak self] in
                guard let self else { return .failed("The store went away.") }
                return await self.runQuery(type, unit: unit, from: start, to: end,
                                           statistic: statistic, zone: zone)
            }

            group.addTask { [queryTimeout] in
                try? await Task.sleep(for: queryTimeout)
                return nil                      // nil == the timeout won the race
            }

            let first = await group.next() ?? nil
            group.cancelAll()

            guard let outcome = first else {
                await MainActor.run {
                    self.lastError = "Health query timed out — check the HealthKit "
                                   + "capability and privacy string."
                }
                return .timedOut
            }
            return outcome
        }
    }

    private func runQuery(_ type: HKQuantityType,
                          unit: HKUnit,
                          from start: Date,
                          to end: Date,
                          statistic: Statistic,
                          zone: TimeZone) async -> QueryOutcome {

        await withCheckedContinuation { cont in
            var resumed = false
            let finish: (QueryOutcome) -> Void = { result in
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

            // The clock this run is cut on. Built once here rather than per
            // bucket — a `DateFormatter` per day over a 420-day resting-HR
            // window is the classic way to make a background query expensive
            // for no reason.
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = zone
            let labeller = DayKey.formatter(in: zone)

            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(
                    withStart: start, end: end, options: .strictStartDate),
                options: wantsSum ? .cumulativeSum : .discreteAverage,
                // The whole fix, in one argument. This was
                // `Calendar.current.startOfDay(for: start)` — the device's
                // clock at the moment of the query — which is what made a
                // Japanese day re-cut itself as a Belgian one on landing.
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    let message = error.localizedDescription
                    Task { @MainActor in self.lastError = message }
                    // `.failed`, NOT an empty dictionary. The caller keeps what
                    // it already had rather than adopting nothing as a reading.
                    finish(.failed(message))
                    return
                }
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { s, _ in
                    let q = wantsSum ? s.sumQuantity() : s.averageQuantity()
                    if let q {
                        // `labeller`, not `DayKey.key` — the label has to name
                        // the same clock the bucket was cut on, or the two
                        // disagree at every boundary the query crosses.
                        out[labeller.string(from: s.startDate)] = q.doubleValue(for: unit)
                    }
                }
                // An empty `out` here IS a real answer: the query ran and the
                // window held nothing. That is a different fact from the branch
                // above and the type now says so.
                finish(.ok(out))
            }

            store.execute(query)
        }
    }
}
