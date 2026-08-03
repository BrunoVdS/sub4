//
//  DetailStore.swift
//  Sub4
//
//  Per-activity extras, fetched during sync rather than when a sheet opens.
//
//  Two calls per activity:
//    /activities/{id}            → splits, best efforts, laps, route, calories
//    /activities/{id}/streams    → heart rate, speed, altitude, grade profiles
//
//  Why sync-time and not on-open: the sheet then opens instantly and works with
//  no signal. The cost is small — the whole history since 15 June is 60
//  activities, so the complete backfill is about 120 requests against a
//  1000/day limit.
//
//  It's still a QUEUE, not a burst, because the OTHER limit is 100 reads per 15
//  minutes: 30 activities per drain is at most 60 requests, and syncIfNeeded
//  won't run again for 15 minutes. It stops dead on a 429 and puts the id back.
//

import Foundation
import Observation

@Observable
final class DetailStore {

    static let shared = DetailStore()

    private(set) var details: [String: ActivityDetail] = [:]
    private(set) var streams: [String: ActivityStreams] = [:]
    private(set) var pending: [String] = []
    private(set) var isFetching = false
    private(set) var rateLimitedUntil: Date?

    /// Ids Strava refused (deleted, private, 404). Never retried automatically —
    /// otherwise a single dead id burns a queue slot on every launch, forever.
    private var failed: Set<String> = []

    /// Ids whose streams came back empty — a manually-entered activity with no
    /// recording. Distinct from `failed`: the detail is fine, the profile isn't
    /// coming.
    private var noStreams: Set<String> = []

    /// What has landed since the last write. `save()` persists exactly these
    /// and nothing else — the reason it can run in a defer without costing
    /// anything proportional to the history.
    private var dirtyDetails: Set<String> = []
    private var dirtyStreams: Set<String> = []

    /// One file per activity — patch 169. See the note on `save()`.
    private let detailsDir: URL
    private let streamsDir: URL
    /// The monoliths this store used before 169, kept only to migrate from.
    private let legacyDetailURL: URL
    private let legacyStreamsURL: URL
    private let failedKey = "detail.failed"
    private let noStreamsKey = "detail.noStreams"

    /// Bumped whenever the stored stream shape changes, so old caches are
    /// rebuilt instead of silently missing a series.
    ///   1 → distance, heart rate, speed, altitude, grade
    ///   2 → + latlng, for the scrub position on the map
    private let schemaKey = "streams.schema"
    /// 3: the power stream was added. Bumping clears the cached traces and
    /// refills the queue — done DURING the January backfill on purpose, because
    /// doing it afterwards would mean fetching all 250 traces a second time.
    private let schemaVersion = 3

    /// Activities per drain. Each costs up to two requests, so 30 → 60, leaving
    /// room for the activity-list call inside the 100-per-15-minutes window.
    private let batchSize = 30
    private let gap: Duration = .milliseconds(250)

    /// Below this there's no meaningful profile to plot — a five-minute strength
    /// session has no distance axis at all.
    private let minStreamDistance: Double = 500

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        detailsDir       = dir.appendingPathComponent("details", isDirectory: true)
        streamsDir       = dir.appendingPathComponent("streams", isDirectory: true)
        legacyDetailURL  = dir.appendingPathComponent("details.json")
        legacyStreamsURL = dir.appendingPathComponent("streams.json")
        try? FileManager.default.createDirectory(at: detailsDir,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: streamsDir,
                                                 withIntermediateDirectories: true)
        // Set on the DIRECTORY so the per-activity files created inside it
        // inherit the class — patch 190, DATA-05. Files here are written from a
        // background task, which is why the class is until-first-unlock rather
        // than complete; see FileProtection.
        FileProtection.protect(directory: detailsDir)
        FileProtection.protect(directory: streamsDir)
        failed     = Set(UserDefaults.standard.stringArray(forKey: failedKey) ?? [])
        noStreams  = Set(UserDefaults.standard.stringArray(forKey: noStreamsKey) ?? [])
        load()

        // Streams cached before latlng existed have no map position. Drop them
        // and let the queue refill — 60 activities, two drains. Details are
        // untouched, so splits, routes and best efforts stay put.
        if UserDefaults.standard.integer(forKey: schemaKey) != schemaVersion {
            streams = [:]
            dirtyStreams = []
            noStreams = []
            try? FileManager.default.removeItem(at: streamsDir)
            try? FileManager.default.createDirectory(at: streamsDir,
                                                     withIntermediateDirectories: true)
            FileProtection.protect(directory: streamsDir)
            UserDefaults.standard.removeObject(forKey: noStreamsKey)
            UserDefaults.standard.set(schemaVersion, forKey: schemaKey)
        }
    }

    // MARK: Queries

    func detail(for activityId: String) -> ActivityDetail? { details[activityId] }
    func streams(for activityId: String) -> ActivityStreams? { streams[activityId] }

    /// How many activities have a cached trace. Part of the load engine's
    /// input fingerprint: a day scored from a session average is upgraded to
    /// the full trace the moment the queue reaches it.
    var streamCount: Int { streams.count }

    func has(_ activityId: String) -> Bool { details[activityId] != nil }
    func isQueued(_ activityId: String) -> Bool { pending.contains(activityId) }

    /// True when the profile is never coming — so the sheet can stop promising it.
    func streamsUnavailable(_ activityId: String) -> Bool {
        noStreams.contains(activityId)
    }

    var backfillRemaining: Int { pending.count }

    // MARK: Queue

    private func needsDetail(_ a: Activity) -> Bool {
        details[a.id] == nil && !failed.contains(a.id)
    }

    private func needsStreams(_ a: Activity) -> Bool {
        a.distance >= minStreamDistance
            && streams[a.id] == nil
            && !noStreams.contains(a.id)
            && !failed.contains(a.id)
    }

    /// Recomputes the queue from what's stored. Cheap, idempotent, self-healing:
    /// anything deleted from the cache simply reappears in the queue.
    @MainActor
    func refreshQueue() {
        pending = ActivityStore.shared.activities            // newest first
            .filter { needsDetail($0) || needsStreams($0) }
            .map(\.id)
    }

    /// Called after every sync. Non-blocking — the UI never waits on the queue.
    @MainActor
    func enqueueAndDrain() {
        refreshQueue()
        guard !pending.isEmpty else { return }
        Task { await drain() }
    }

    /// `limit` and `pause` exist for the background path, which has roughly 30
    /// seconds before iOS kills it — the foreground defaults are minutes of
    /// work. Overrunning a background task doesn't just fail: iOS schedules the
    /// app less often afterwards.
    @MainActor
    func drain(limit: Int? = nil, pause: Duration? = nil) async {
        // Cheap early exit, so a closed gate costs no token refresh and no
        // wasted first request. The authoritative check is still the one inside
        // `StravaClient.detail`; this is politeness, not enforcement.
        guard ReleaseGates.isOpen(.stravaSync) else { return }
        guard !isFetching, !pending.isEmpty else { return }
        if let until = rateLimitedUntil, Date() < until { return }
        guard let token = await StravaAuth.shared.validAccessToken() else { return }

        isFetching = true
        // The whole point of keying the load series on `streamCount`: a day
        // scored from a session average upgrades to the full trace the moment
        // that trace lands. Without this the upgrade waits for the next sync.
        defer { isFetching = false; save(); LoadStore.shared.recomputeIfNeeded() }

        let cap = limit ?? batchSize
        let wait = pause ?? gap
        var done = 0
        while done < cap, !pending.isEmpty {
            // Expiring a background task cancels this Task. Stop cleanly — the
            // defer still writes whatever landed, and the queue resumes later.
            if Task.isCancelled { return }

            let id = pending.removeFirst()
            let activity = ActivityStore.shared.activities.first { $0.id == id }

            switch await fetchOne(id: id, activity: activity, token: token) {
            case .ok:
                break
            case .retryLater:
                pending.insert(id, at: 0)
                rateLimitedUntil = Date().addingTimeInterval(16 * 60)
                return                    // defer still saves what we got
            case .stop:
                pending.insert(id, at: 0)
                return
            case .transient:
                // Back of the queue, so one bad id can't wedge the drain.
                pending.append(id)
            }

            done += 1
            try? await Task.sleep(for: wait)
        }
    }

    private enum FetchOutcome { case ok, retryLater, stop, transient }

    // @MainActor is load-bearing, not decoration: this mutates `details` and
    // `streams`, which @Observable views read. A nonisolated async function
    // would perform those writes on a background executor.
    @MainActor
    private func fetchOne(id: String,
                          activity: Activity?,
                          token: String) async -> FetchOutcome {

        if details[id] == nil && !failed.contains(id) {
            do {
                details[id] = try await StravaClient.detail(id: id, token: token)
                dirtyDetails.insert(id)
            } catch let e as StravaClient.APIError where e.status == 429 {
                return .retryLater
            } catch let e as StravaClient.APIError where e.status == 401 {
                return .stop            // token died mid-drain; next launch refreshes
            } catch let e as StravaClient.APIError where e.status == 404 {
                failed.insert(id); saveSkips()
                return .ok
            } catch is GateError {
                // `.stop`, NOT `.transient` — patch 178. A transient result puts
                // the id at the back of the queue and moves on, so a closed gate
                // would spin the whole batch of thirty against a wall and
                // re-queue every one of them. The gate will not open in the next
                // three hundred milliseconds; stopping puts the id back and ends
                // the drain, which is what a permanent refusal deserves.
                return .stop
            } catch {
                return .transient
            }
        }

        guard let a = activity, needsStreams(a) else { return .ok }

        do {
            if let s = try await StravaClient.streams(
                id: id, token: token, hasDeviceWatts: a.hasRealPower) {
                streams[id] = s
                dirtyStreams.insert(id)
            } else {
                // 200 with nothing usable — a manual entry, or an indoor session
                // with no distance track. Record it so we never ask again.
                noStreams.insert(id); saveSkips()
            }
        } catch let e as StravaClient.APIError where e.status == 429 {
            return .retryLater
        } catch let e as StravaClient.APIError where e.status == 404 {
            noStreams.insert(id); saveSkips()
        } catch is GateError {
            // NOT `noStreams` — see above. Recording "this activity has no
            // trace" because a switch was off would be a permanent lie written
            // from a temporary state, and `noStreams` is never retried.
            return .stop
        } catch {
            // Detail landed, streams didn't — leave it out of `noStreams` so the
            // next drain picks it up again.
            return .transient
        }
        return .ok
    }

    /// Jump the queue for one activity — used when a sheet opens before the
    /// backfill has reached it.
    @MainActor
    func prioritise(_ activityId: String) async {
        guard ReleaseGates.isOpen(.stravaSync) else { return }
        guard !isFetching else { return }
        if let until = rateLimitedUntil, Date() < until { return }
        let activity = ActivityStore.shared.activities.first { $0.id == activityId }
        let wantsDetail = details[activityId] == nil && !failed.contains(activityId)
        let wantsStreams = activity.map { needsStreams($0) } ?? false
        guard wantsDetail || wantsStreams else { return }
        guard let token = await StravaAuth.shared.validAccessToken() else { return }

        isFetching = true
        // The whole point of keying the load series on `streamCount`: a day
        // scored from a session average upgrades to the full trace the moment
        // that trace lands. Without this the upgrade waits for the next sync.
        defer { isFetching = false; save(); LoadStore.shared.recomputeIfNeeded() }

        if case .retryLater = await fetchOne(id: activityId,
                                             activity: activity,
                                             token: token) {
            rateLimitedUntil = Date().addingTimeInterval(16 * 60)
            return
        }
        pending.removeAll { $0 == activityId }
    }

    // MARK: Persistence
    //
    // ONE FILE PER ACTIVITY — patch 169.
    //
    // This store used to persist two monolithic dictionaries, rewritten whole
    // in the defer of every drain and every prioritise. Opening one activity
    // you had not opened before therefore re-encoded EVERY cached trace in the
    // history — megabytes of other activities' data — on the MainActor, to
    // record the arrival of one. The write cost grew with the history and the
    // history only grows; a 34-week block ends with roughly 450 details and
    // 300 traces behind every single-activity fetch.
    //
    // Now each detail and each trace is its own file, `save()` writes exactly
    // the ids that landed since the last write, and only the ENCODE stays on
    // the MainActor — deliberately. Encoding one 300-sample trace is
    // milliseconds; it was the O(history) that hurt, not the codec. Moving the
    // encode off-main would mean the Codable conformances of MainActor-default
    // types crossing an isolation boundary, which is the trap this project has
    // already paid for twice. The file WRITE — plain Sendable Data — is what
    // goes to a background task.
    //
    // A decode failure on one file loses one activity, which `refreshQueue`
    // re-queues on the next pass — the cache was already self-healing by
    // design, and per-key files make the healing granular.

    private func load() {
        // The monoliths first, if this is the first launch since 169. Per-key
        // files load AFTER and win on collision, so a stale monolith can never
        // overwrite something newer — which is what makes it safe to leave the
        // legacy files in place until the migration writes have completed.
        var migrating = false
        if let d = try? Data(contentsOf: legacyDetailURL),
           let m = try? JSONDecoder().decode([String: ActivityDetail].self, from: d) {
            details = m
            dirtyDetails.formUnion(m.keys)
            migrating = true
        }
        if let d = try? Data(contentsOf: legacyStreamsURL),
           let m = try? JSONDecoder().decode([String: ActivityStreams].self, from: d) {
            streams = m
            dirtyStreams.formUnion(m.keys)
            migrating = true
        }

        for url in files(in: detailsDir) {
            guard let d = try? Data(contentsOf: url),
                  let v = try? JSONDecoder().decode(ActivityDetail.self, from: d)
            else { continue }
            details[id(of: url)] = v
        }
        for url in files(in: streamsDir) {
            guard let d = try? Data(contentsOf: url),
                  let v = try? JSONDecoder().decode(ActivityStreams.self, from: d)
            else { continue }
            streams[id(of: url)] = v
        }

        // Write-through, then retire the monoliths — INSIDE the write task, so
        // a kill between scheduling and completion leaves the legacy files for
        // the next launch rather than losing the history to a race.
        if migrating { save(retiring: [legacyDetailURL, legacyStreamsURL]) }
    }

    private func files(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: nil))
            ?? []
    }

    private func id(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }


    /// Drops everything held in memory WITHOUT writing to disk.
    ///
    /// The counterpart to `DataLifecycleCoordinator.deleteEverything`, and the
    /// reason it is not simply `resetCache`: reset saves an empty file, which
    /// after a delete recreates the very store that was just removed. Worse,
    /// leaving the in-memory copy alive means the next save resurrects the
    /// whole history from RAM — a delete that undoes itself the first time the
    /// app touches the store. Nothing here writes.
    func dropInMemory() {
        details = [:]
        streams = [:]
        pending = []
    }

    private func save(retiring legacy: [URL] = []) {
        guard !dirtyDetails.isEmpty || !dirtyStreams.isEmpty || !legacy.isEmpty
        else { return }

        var payload: [(URL, Data)] = []
        let enc = JSONEncoder()
        for id in dirtyDetails {
            guard let v = details[id], let d = try? enc.encode(v) else { continue }
            payload.append((detailsDir.appendingPathComponent(id + ".json"), d))
        }
        for id in dirtyStreams {
            guard let v = streams[id], let d = try? enc.encode(v) else { continue }
            payload.append((streamsDir.appendingPathComponent(id + ".json"), d))
        }
        dirtyDetails = []
        dirtyStreams = []

        Task.detached(priority: .utility) { [payload, legacy] in
            for (url, data) in payload {
                try? data.write(to: url, options: FileProtection.options)
            }
            for url in legacy {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func saveSkips() {
        UserDefaults.standard.set(Array(failed), forKey: failedKey)
        UserDefaults.standard.set(Array(noStreams), forKey: noStreamsKey)
    }

    func resetCache() {
        details = [:]
        streams = [:]
        pending = []
        failed = []
        noStreams = []
        UserDefaults.standard.removeObject(forKey: failedKey)
        UserDefaults.standard.removeObject(forKey: noStreamsKey)
        dirtyDetails = []
        dirtyStreams = []
        try? FileManager.default.removeItem(at: detailsDir)
        try? FileManager.default.removeItem(at: streamsDir)
        try? FileManager.default.createDirectory(at: detailsDir,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: streamsDir,
                                                 withIntermediateDirectories: true)
        FileProtection.protect(directory: detailsDir)
        FileProtection.protect(directory: streamsDir)
        try? FileManager.default.removeItem(at: legacyDetailURL)
        try? FileManager.default.removeItem(at: legacyStreamsURL)
    }
}

// MARK: - API

extension StravaClient {

    static func detail(id: String, token: String) async throws -> ActivityDetail {
        // Patch 178, plan step 0.3 — see the note in ReleaseGates. The drain
        // and `prioritise` both reach here, and `prioritise` is called from a
        // view's `.task`, which is exactly the kind of caller a UI-level gate
        // never covers.
        try ReleaseGates.require(.stravaSync)

        var c = URLComponents(string: "https://www.strava.com/api/v3/activities/\(id)")!
        c.queryItems = [.init(name: "include_all_efforts", value: "false")]
        let data = try await get(c, id: id, token: token)
        return try JSONDecoder().decode(StravaDetailDTO.self, from: data).toDetail()
    }

    /// Returns nil when Strava answers 200 with no usable distance track —
    /// a manually-entered activity, or one recorded without GPS.
    static func streams(id: String, token: String,
                       hasDeviceWatts: Bool = false) async throws -> ActivityStreams? {
        try ReleaseGates.require(.stravaSync)

        var c = URLComponents(
            string: "https://www.strava.com/api/v3/activities/\(id)/streams")!
        c.queryItems = [
            // Strava's own spelling — `heartrate`, one word. `latlng` is what
            // puts the scrub dot on the map at the right place.
            // `watts` added in patch 27. Several long rides in this history
            // carry power and no heart rate at all, so without it those days
            // cannot be scored by anything.
            .init(name: "keys", value: "distance,heartrate,altitude,"
                                     + "velocity_smooth,grade_smooth,watts,latlng"),
            .init(name: "key_by_type", value: "true")
        ]
        let data = try await get(c, id: id, token: token)
        let dto = try JSONDecoder().decode(StravaStreamsDTO.self, from: data)
        guard let s = dto.toStreams(activityId: id,
                                    hasDeviceWatts: hasDeviceWatts),
              s.isUsable else { return nil }
        return s
    }

    private static func get(_ components: URLComponents,
                            id: String,
                            token: String) async throws -> Data {
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "No response from Strava.")
        }
        guard http.statusCode == 200 else {
            throw APIError(message: "Strava returned \(http.statusCode) for activity \(id).",
                           status: http.statusCode)
        }
        return data
    }
}
