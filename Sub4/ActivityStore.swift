//
//  ActivityStore.swift
//  Sub4
//
//  Pulls activities from Strava, dedups them, and keeps them on disk.
//  Runs on every app launch — incrementally, using Strava's `after` parameter,
//  so each check costs one request and only fetches what's new.
//

import Foundation
import Observation

@Observable
final class ActivityStore {

    static let shared = ActivityStore()

    /// Every mutation rebuilds the day index in `didSet`, and that placement is
    /// the point: an index maintained beside each of the three writes would be
    /// three chances to forget one. Attached to the property, it cannot go
    /// stale, because it is not separately maintained.
    private(set) var activities: [Activity] = [] {
        didSet { byDay = Dictionary(grouping: activities, by: \.dayKey) }
    }

    /// THE DAY INDEX — patch 168.
    ///
    /// `activities(on:)` used to be a linear filter over the whole history, and
    /// it sat at the bottom of everything: `Matcher.day()` calls it, WeekView's
    /// totals call the matcher seven times per body pass, every DayRow calls it
    /// again, and `LoadStore` reads it once per day across four hundred days on
    /// every recompute. A Week-tab body pass cost roughly fifteen full-history
    /// scans; a load rebuild cost four hundred.
    ///
    /// The array mutates about twice per launch (disk load, sync); the lookups
    /// run on every body pass. That is the textbook shape for paying O(n) once
    /// at the write instead of at each of thousands of reads.
    ///
    /// `Dictionary(grouping:)` preserves encounter order, so each day's bucket
    /// keeps the newest-first order the array is sorted into at ingest — no
    /// caller sees a different sequence than the old filter produced.
    private var byDay: [String: [Activity]] = [:]

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    /// A DELIBERATE REFUSAL, HELD APART FROM `lastError` — patch 179.
    ///
    /// This is a fix for a bug patch 178 introduced and its own code comments
    /// warned about. `ReleaseGates` says in as many words that a closed gate is
    /// not an outage, and `GateError` even carries an `isDeliberate` flag —
    /// which 178 then never read. Writing the refusal into `lastError` lit the
    /// red badge on the Settings tab, and that badge means one specific thing:
    /// the Strava connection is broken and completion data is therefore
    /// untrustworthy. It sent the reader to reconnect an account that was
    /// working perfectly, to fix a state somebody chose on purpose.
    ///
    /// Two properties rather than one enum with two cases, because every
    /// existing reader of `lastError` — the tab badge, `needsAttention`, the
    /// Settings row — should treat a closed gate as nothing at all, and the
    /// cheapest way to guarantee that is for it to be nothing at all to them.
    private(set) var lastGateNotice: String?

    /// Highest activity start seen, as epoch seconds — the incremental cursor.
    private var cursor: TimeInterval = 0

    private let fileURL: URL
    private let cursorKey = "strava.cursor"
    private let lastSyncKey = "strava.lastSync"
    private let cutoffKey = "strava.cutoffUsed"
    private static let powerBackfillKey = "strava.powerBackfill"
    private static let speedBackfillKey = "strava.speedBackfill"
    private static let geoBackfillKey = "strava.geoBackfill"
    private static let rejectedKey = "strava.rejectedByRule"

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("activities.json")
        cursor  = UserDefaults.standard.double(forKey: cursorKey)
        if cursor == 0 { cursor = Self.cutoffEpoch }
        lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        load()

        // If the cutoff has been moved (e.g. back to cover the post-Ironman
        // block), the persisted cursor is now too late to ever fetch the
        // earlier history. Detect that and rebuild rather than silently
        // showing an incomplete picture.
        let used = UserDefaults.standard.string(forKey: cutoffKey)
        if used != MatchRules.cutoffDayKey {
            resetCache()
            UserDefaults.standard.set(MatchRules.cutoffDayKey, forKey: cutoffKey)
        }

        // Patch 27 added device_watts to Activity. Cached rows predate it and
        // decode as nil, and the incremental cursor means they are never read
        // again — so every trace fetched after the schema bump would have been
        // asked for without power and stored without it. Three list pages,
        // merged by id, no details touched.
        if UserDefaults.standard.integer(forKey: Self.powerBackfillKey) < 1 {
            cursor = Self.cutoffEpoch
            UserDefaults.standard.set(cursor, forKey: cursorKey)
            UserDefaults.standard.set(1, forKey: Self.powerBackfillKey)
        }

        // Patch 123 added `maxSpeed`, and the self-contradiction rule cannot
        // fire without it. Cached rows decode it as nil, and the incremental
        // cursor means they would never be read again — so the three known bad
        // rides would sit in the cache for ever, immune to the rule written to
        // catch them. Same shape as the power backfill above: rewind the cursor
        // once, let ingest merge by id.
        // VERSION 2, not a bool. Version 1 ran under patch 123, whose ingest
        // could not evict a stale row — so it fetched the corrected data, threw
        // it away, and left the bad rows in place with the flag set. Anyone who
        // ran that build needs the rewind a second time, and a plain "have we
        // done this" flag has no way to say so.
        if UserDefaults.standard.integer(forKey: Self.speedBackfillKey) < 2 {
            cursor = Self.cutoffEpoch
            UserDefaults.standard.set(cursor, forKey: cursorKey)
            UserDefaults.standard.set(2, forKey: Self.speedBackfillKey)
        }

        // Patch 128 added `startUTC`, `startLat` and `startLon`. Cached rows
        // decode them as nil and the cursor would never look at those rows
        // again, so every activity older than this build would be permanently
        // ineligible for weather. Third rewind of the session, and the last one
        // this shape of change should need — the pattern is now established
        // enough that any future field should ship with its own key rather than
        // reusing one.
        if UserDefaults.standard.integer(forKey: Self.geoBackfillKey) < 1 {
            cursor = Self.cutoffEpoch
            UserDefaults.standard.set(cursor, forKey: cursorKey)
            UserDefaults.standard.set(1, forKey: Self.geoBackfillKey)
        }

        loadRejections()
    }

    // MARK: What the rule threw away

    /// Human-readable lines for the activities the self-contradiction rule
    /// rejected, oldest first.
    ///
    /// PERSISTED, AND THAT IS THE POINT. A rejected activity is not written to
    /// activities.json and the cursor moves past it, so after one launch there
    /// is nothing left in the app that remembers it existed. A rule that
    /// silently deletes data is worse than the data it deleted — this is the
    /// receipt, and Settings prints it.
    private(set) var rejected: [String] = []

    private func loadRejections() {
        let map = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        rejected = map.keys.sorted().compactMap { map[$0] }
    }

    private func recordRejections(_ candidates: [Activity]) {
        var map = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        var changed = false
        for a in candidates where a.selfContradictoryDistance {
            if map[a.id] == nil { map[a.id] = Self.rejectionLabel(a); changed = true }
        }
        guard changed else { return }
        UserDefaults.standard.set(map, forKey: Self.rejectedKey)
        rejected = map.keys.sorted().compactMap { map[$0] }
    }

    /// Everything needed to look the recording up in Strava and see for
    /// yourself: when, what it was called, and the two figures that disagree.
    private static func rejectionLabel(_ a: Activity) -> String {
        let kmh = (a.distance / Double(max(a.movingTime, 1))) * 3.6
        let maxKmh = (a.maxSpeed ?? 0) * 3.6
        let mins = a.movingTime / 60, secs = a.movingTime % 60
        return String(format: "%@ %@ — %.1f km in %d:%02d = %.0f km/h avg, max %.0f",
                      String(a.startLocal.prefix(10)), a.name,
                      a.km, mins, secs, kmh, maxKmh)
    }

    /// Plan start — nothing earlier is ever ingested.
    private static var cutoffEpoch: TimeInterval {
        (DayKey.date(MatchRules.cutoffDayKey) ?? Date()).timeIntervalSince1970
    }

    // MARK: Queries

    func activities(on dayKey: String) -> [Activity] {
        byDay[dayKey] ?? []
    }

    var count: Int { activities.count }

    // MARK: Sync

    /// Called on every launch and on pull-to-refresh.
    /// `minInterval` throttles repeat launches — set 0 to force.
    @MainActor
    func syncIfNeeded(minInterval: TimeInterval = 15 * 60) async {
        if let last = lastSync, Date().timeIntervalSince(last) < minInterval { return }
        await sync()
    }

    @MainActor
    func sync() async {
        guard !isSyncing else { return }

        let auth = StravaAuth.shared
        guard var token = await auth.validAccessToken() else {
            lastError = auth.lastError ?? "Not connected to Strava."
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            var fetched: [Activity]
            do {
                fetched = try await StravaClient.activities(after: cursor, token: token)
            } catch let e as StravaClient.APIError where e.status == 401 {
                // The token was refused despite looking valid — clock skew, a
                // revoked token, or a refresh that silently failed earlier.
                // Force a refresh and retry exactly once before giving up.
                guard let fresh = await auth.validAccessToken(forceRefresh: true) else {
                    lastError = auth.lastError
                        ?? "Strava rejected the sign-in. Reconnect in Settings."
                    return
                }
                token = fresh
                fetched = try await StravaClient.activities(after: cursor, token: token)
            }

            ingest(fetched)
            // HR_max is derived from the activity list, so it is re-derived
            // whenever that list changes — including the one-time January
            // backfill, which is where the real maximum most likely lives.
            ConstantsStore.shared.refreshFromSources(
                activities: activities,
                restingByDay: HealthStore.shared.restingHRByDay)
            // Cheap and fingerprint-guarded: it rebuilds only when something
            // that can change a load figure has actually changed.
            LoadStore.shared.recomputeIfNeeded()
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: lastSyncKey)
            lastError = nil
            // A sync that got through is proof the gate is open, so the notice
            // goes with it. Cleared here rather than when the switch moves,
            // because the switch is not the only thing that can change the
            // answer — an external build ignores the stored value entirely.
            lastGateNotice = nil

            // Per-activity extras — splits, route, calories — are pulled here
            // rather than when a sheet opens, so the detail view is instant and
            // works offline. Fires and forgets: the queue drains in the
            // background and picks up where it left off next launch.
            DetailStore.shared.enqueueAndDrain()
        } catch {
            // A cancelled sync is not a failed sync. `.refreshable` and `.task`
            // are cancelled whenever the view goes away — which happens on every
            // tab switch — and URLSession then throws URLError.cancelled, whose
            // localizedDescription is the bare word "cancelled". That is what
            // produced the "Strava · cancelled" banner: a request that simply
            // did not finish and will run again on the next trigger.
            //
            // The previous lastError is deliberately left alone rather than
            // cleared. If a real failure was on screen, a cancellation is no
            // evidence that it has been resolved.
            guard !error.isCancellation else { return }
            // A CLOSED GATE IS NOT AN OUTAGE — 178 said so and then wrote it
            // into `lastError` anyway, which is the one field that means "the
            // connection is broken". Corrected in 179: the refusal goes to
            // `lastGateNotice`, and `lastError` is cleared, because a gate
            // closing does not make a previous genuine failure current.
            if let g = error as? GateError {
                lastGateNotice = g.errorDescription
                lastError = nil
                return
            }
            lastError = error.localizedDescription
        }
    }

    /// Merge, filter and dedup. Idempotent — re-running changes nothing.
    private func ingest(_ incoming: [Activity]) {
        var byID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })

        recordRejections(incoming)
        for a in incoming {
            // Advance for everything we have SEEN, kept or not. A rejected
            // activity is still processed; leaving the cursor behind it would
            // re-fetch it on every sync for ever.
            cursor = max(cursor, epoch(of: a) + 1)

            // REJECTION MUST REMOVE, NOT MERELY DECLINE TO ADD.
            //
            // Patch 123 wrote `continue` here and the rule looked like it had
            // failed. It had not: Settings correctly reported three rejections
            // while the chart kept drawing all three rides. `byID` is seeded
            // from the rows already held, those rows predate `maxSpeed` and so
            // decode it as nil, and a nil max cannot contradict anything — they
            // passed `isKept` on load and stayed. Skipping the incoming copy
            // then left the stale one sitting there untouched.
            //
            // The freshly fetched version is the authority on whether a row
            // belongs at all, so a rejection deletes whatever is under that id.
            guard Self.isKept(a) else { byID.removeValue(forKey: a.id); continue }
            byID[a.id] = a
        }

        activities = dedup(Array(byID.values)).sorted { $0.startLocal > $1.startLocal }
        UserDefaults.standard.set(cursor, forKey: cursorKey)
        save()
    }

    /// THE ONE GATE, APPLIED WHEREVER AN ACTIVITY ARRIVES
    /// ---------------------------------------------------
    /// Two doors lead into `activities`: the network, through `ingest`, and
    /// activities.json, through `load`. The filter used to live in `ingest`
    /// only, which was fine while it was made of constants that never changed
    /// after a row was written — but `DataCorrections.ignoredActivities` does
    /// change, and a row already on disk would have walked straight past a rule
    /// added after it was cached. Applying the same predicate on load means a
    /// new entry takes effect on the next launch instead of needing a re-sync.
    ///
    /// Everything after the cutoff is kept — walks, commutes, the kayak. Only
    /// *matching* is filtered (`Activity.isPlanEligible`), so total movement
    /// volume stays honest.
    private static func isKept(_ a: Activity) -> Bool {
        guard a.dayKey >= MatchRules.cutoffDayKey else { return false }
        guard a.movingTime >= MatchRules.minAnyActivitySeconds else { return false }
        // Named, with the reason, in DataCorrections — and reported in
        // Settings, because a recording the app throws away without saying so
        // is indistinguishable from one it failed to fetch.
        guard !DataCorrections.isIgnored(a) else { return false }
        // The rule, not a list. See `Activity.selfContradictoryDistance` for the
        // three rides that produced it and why the threshold is 1.5×.
        guard !a.selfContradictoryDistance else { return false }
        return true
    }

    /// Same sport, starting within a few minutes, similar distance → one session
    /// recorded by two devices. Keep the longer recording.
    private func dedup(_ input: [Activity]) -> [Activity] {
        var kept: [Activity] = []
        for a in input.sorted(by: { $0.startLocal < $1.startLocal }) {
            if let i = kept.firstIndex(where: { isDuplicate($0, a) }) {
                if a.movingTime > kept[i].movingTime { kept[i] = a }
            } else {
                kept.append(a)
            }
        }
        return kept
    }

    private func isDuplicate(_ a: Activity, _ b: Activity) -> Bool {
        guard a.sportType == b.sportType, a.dayKey == b.dayKey else { return false }
        guard abs(a.startMinuteOfDay - b.startMinuteOfDay)
                <= MatchRules.duplicateWindowMinutes else { return false }
        let bigger = max(a.distance, b.distance)
        guard bigger > 0 else { return true }
        return abs(a.distance - b.distance) / bigger <= MatchRules.duplicateDistanceTolerance
    }

    private func epoch(of a: Activity) -> TimeInterval {
        (DayKey.date(a.dayKey) ?? Date()).timeIntervalSince1970
            + Double(a.startMinuteOfDay * 60)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = (try? JSONDecoder().decode([Activity].self, from: data)) ?? []
        recordRejections(decoded)
        // `{ Self.isKept($0) }` and not `Self.isKept`. The predicate reads
        // MatchRules and DataCorrections, which are MainActor-isolated like
        // everything else in this target, and handing it to `filter` as a
        // function VALUE strips that isolation — "call to main actor-isolated
        // static method in a synchronous nonisolated context". A closure
        // literal written here inherits the isolation of the method it sits in,
        // so the same call is fine spelled out.
        activities = decoded.filter { Self.isKept($0) }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(activities).write(to: fileURL, options: .atomic)
    }

    /// Wipe local cache and re-pull from the cutoff.
    func resetCache() {
        activities = []
        cursor = Self.cutoffEpoch
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: cursorKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        save()
        // Details are keyed by activity id, so a stale details.json would
        // otherwise survive a rebuild and quietly reference activities that no
        // longer exist.
        DetailStore.shared.resetCache()
    }
}

// MARK: - API

enum StravaClient {

    struct APIError: LocalizedError {
        let message: String
        var status: Int = 0
        var errorDescription: String? { message }
    }

    static func activities(after: TimeInterval, token: String) async throws -> [Activity] {
        // GATED AT THE WIRE, NOT AT THE BUTTON — patch 178, plan step 0.3.
        //
        // Six call sites reach this function: launch, pull-to-refresh on Today,
        // pull-to-refresh on Progress, Settings "Check now", the cache rebuild,
        // and the two-hourly background task. Gating any of them individually
        // leaves the other five, and leaves every one added later. See the note
        // at the top of ReleaseGates.
        try ReleaseGates.require(.stravaSync)

        var all: [Activity] = []
        var page = 1

        // 10 pages × 100 = 1000 activities. The backfill from 1 January — an
        // Ironman build, a February marathon and a winter of Zwift — measured
        // about 250 against the API, so this is headroom, not a limit.
        while page <= 10 {
            var c = URLComponents(string: "https://www.strava.com/api/v3/athlete/activities")!
            c.queryItems = [
                .init(name: "after",    value: String(Int(after))),
                .init(name: "per_page", value: "100"),
                .init(name: "page",     value: String(page))
            ]
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(message: "No response from Strava.")
            }
            if http.statusCode == 429 {
                throw APIError(message: "Strava rate limit reached — try again shortly.",
                               status: 429)
            }
            guard http.statusCode == 200 else {
                throw APIError(message: "Strava returned \(http.statusCode).",
                               status: http.statusCode)
            }

            let batch = try JSONDecoder().decode([StravaActivityDTO].self, from: data)
            all.append(contentsOf: batch.map { $0.toActivity() })
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }
}
