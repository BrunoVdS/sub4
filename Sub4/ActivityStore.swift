//
//  ActivityStore.swift
//  Sub4
//
//  Pulls activities from Strava, dedups them, and keeps them on disk.
//  Runs on every app launch.
//
//  SYNC READS EVERYTHING — patch 249, and the reason is a defect that lost data
//  ---------------------------------------------------------------------------
//  It used to read incrementally: `after` was set to the highest activity START
//  time already seen, so each check cost one request and fetched only what was
//  new. That is wrong, and the way it is wrong is permanent rather than
//  temporary.
//
//  Strava's `after` filters by START DATE. Activities do not arrive in start
//  order. A bike computer that uploads when it next finds WiFi, a Garmin batch,
//  a FIT file dragged in by hand — all of these appear on Strava hours or days
//  after the ride they describe.
//
//  What that produced, found on 5 August 2026 and reproducible from the ids:
//
//    4 Aug 22:06  Squat day     id 19603201792   uploaded that evening, ingested
//    4 Aug 07:26  Morning Ride  id 19608576674   uploaded the NEXT morning
//    4 Aug 08:40  Morning Ride  id 19608576609   uploaded the NEXT morning
//    4 Aug 17:31  Afternoon Rd  id 19608576461   uploaded the NEXT morning
//
//  Strava ids increase with upload time, so the three rides were uploaded after
//  the squat had already advanced the cursor past 22:06. Every subsequent
//  request asked for activities after 4 Aug 22:06. The rides start twelve hours
//  before that. They would never have arrived — not late, not ever.
//
//  There is no `uploaded_after` parameter on this endpoint, so the only lever is
//  how far back each sync reads. An overlap window was considered and rejected:
//  it converts "always lost" into "lost if delayed more than N days", which is a
//  smaller hole and still a hole, and the day it swallows something the athlete
//  will not know either.
//
//  THE COST, STATED RATHER THAN GLOSSED. Reading from the cutoff is seven pages
//  of a hundred for 661 activities, roughly a megabyte, against one page before.
//  With a two-hourly background refresh that is on the order of ten megabytes a
//  day on cellular. That was the athlete's call, made with the figure in front
//  of him, and it buys a sync that cannot silently miss anything.
//
//  `cursor` survives this change, doing the opposite job: it is now how a late
//  arrival is DETECTED rather than how one is missed. See `lateArrivals`.
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
        didSet {
            // MOVED TO `ActivityRoster` AT 312, and it is one line, and that is
            // the point. D6c's twin needs the same buckets built from the
            // database — **one line copied twice is still two implementations**
            // (§12.43), and this one carries a promise a copy would not:
            // `Dictionary(grouping:)` preserves encounter order, which patch
            // 168's comment below says callers depend on.
            byDay = ActivityRoster.byDay(activities)
            // `DayZones.from` was already a shared pure function, so the twin
            // calls this one. Nothing to move.
            dayZones = DayZones.from(activities: activities)
        }
    }

    /// Which clock each training day was lived on — patch 201, ADR-0003 §4.5.
    ///
    /// HERE RATHER THAN IN `HealthStore`, WHICH IS WHERE IT STARTED.
    ///
    /// Patch 198 built this inside the Health refresh, because Health was the
    /// only consumer. That made it depend on a Health refresh having run — so
    /// on a device where Health is unavailable or unauthorised, `refresh()`
    /// returns early and the zones stay empty for ever. The zones are derived
    /// from ACTIVITIES and have nothing to do with Health; the dependency was
    /// backwards.
    ///
    /// Attached to the `didSet` above for the reason stated there: derived
    /// state maintained beside the thing it derives from cannot go stale. It is
    /// also what makes it cheap enough for a view — `DayZones.from` walks all
    /// 661 activities, and a `DayRow` computing it per body pass would do that
    /// seven times a frame.
    private(set) var dayZones = DayZones(changes: [],
                                         trailingOffsetSeconds: TimeZone.current.secondsFromGMT())

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

    /// Highest activity start seen, as epoch seconds.
    ///
    /// NO LONGER THE QUERY BOUND — patch 249. It was, and that was a defect
    /// that lost data permanently. See `SYNC READS EVERYTHING` in the header.
    /// It is kept because it is exactly the right instrument for detecting the
    /// problem it used to cause: an activity that arrives starting BEFORE this
    /// mark was uploaded late, and under the old scheme would never have been
    /// seen at all.
    ///
    /// The four backfill blocks below still rewind it to the cutoff. They are
    /// now inert — re-reading is unconditional, so there is nothing to rewind
    /// for — and all four have already fired once on this device. Left in
    /// place: they are the record of why each backfill happened, and deleting
    /// history to tidy a variable is how the reason for a decision is lost.
    private var cursor: TimeInterval = 0

    /// What `sync_state` should say about this source — patch 275, D5.
    ///
    /// A COMPUTED VIEW RATHER THAN AN EXPOSED CURSOR. `cursor` stays private:
    /// the importer needs to READ where the sync has got to and nothing
    /// outside this file has any business setting it.
    ///
    /// `Sub4Import.sourceID` rather than the literal "strava", because
    /// `sync_state.sourceID` is a RESTRICTED foreign key — an id the schema
    /// has not seeded is refused, and two places spelling it separately is how
    /// that refusal arrives one day with no explanation.
    ///
    /// `lastResult` is `lastError` alone. `lastGateNotice` is deliberately
    /// excluded: §179 separated a deliberate refusal from an outage, and a
    /// closed gate means the sync did NOT run — which `lastSyncUTC` already
    /// says by not moving.
    var syncState: SyncState {
        SyncState(sourceID: Sub4Import.sourceID,
                  // Verbatim, via Swift's shortest round-tripping description.
                  // §8 types the column as opaque text on purpose; formatting
                  // an epoch into ISO-8601 here would be this app inventing a
                  // representation for a value it does not own.
                  cursor: "\(cursor)",
                  lastSync: lastSync,
                  lastResult: lastError)
    }

    /// **WHAT THE LAST READ OF `activities.json` FOUND — patch 378, §12.122.**
    ///
    /// The seventh store to get this, and the one that needed it most. Until
    /// this patch `load` read
    ///
    ///     let decoded = (try? JSONDecoder().decode(…)) ?? []
    ///
    /// so a file that existed and did not decode produced an athlete with no
    /// activities — and `ingest` seeds `byID` from `activities`, so the next
    /// sync wrote its window over the lot. §12.115 on the largest store here.
    ///
    /// `.absent` is the correct start: a fresh install has no file, and a
    /// fresh install must be able to write one.
    private(set) var lastLoad: StoreLoad = .absent

    // A DOC FOR A DIFFERENT PROPERTY USED TO SIT HERE — patch 378.
    //
    // Seven lines describing `lateArrivals`, left above `loadRoster` by 376
    // and never attached to a declaration. `lateArrivals` has its own full
    // doc at its own declaration below, so this was a stale duplicate sitting
    // on top of an unrelated property. Removed rather than moved.

    /// WHAT THE LOAD PATH DID, AND WHAT IT COST — patch 310, §12.54.
    ///
    /// Nil until `load` has read a file. Nil is not zero: a device with no
    /// `activities.json` yet and a device whose file held nothing are different
    /// answers, and the summary below says which.
    ///
    /// In memory, cleared on relaunch, and that is right — it describes THIS
    /// launch's file, and the current file already answers the question.
    private(set) var loadRoster: ActivityRoster.Result?

    /// One row's worth, always sayable. See §12.54.2: 309 showed these numbers
    /// only when non-zero, which made a working counter and an unwired one look
    /// identical — the exact thing 266c and 273 wrote down about the paste.
    var loadSummary: String {
        // THREE ANSWERS, NOT TWO — patch 378. `loadRoster` is nil both when
        // there is no file and when there is one this app could not read, and
        // §12.15 is that those are opposite facts wearing one sentence. The
        // reason is included HERE and not in the paste below: this is the
        // athlete's own screen, and `StoreRead`'s doc reserves the reason for
        // it because a file-system error can carry a path.
        if case .unreadable(let why) = lastLoad {
            return "the cached file could not be read — \(why)"
        }
        return loadRoster?.summary ?? "no cached file read"
    }

    /// For the redacted paste, unconditional.
    var loadDiagnosticLines: [String] {
        // THE SAME THREE ANSWERS, WITHOUT THE REASON — patch 378. See
        // `loadSummary`: the paste says THAT the file could not be read and
        // not why, because this text is copied into a chat window.
        var lines = loadRoster?.diagnosticLines
            ?? [lastLoad.isTrustworthy
                ? "Activity roster: no cached file read"
                : "Activity roster: the cached file could not be read"]
        // PATCH 376. NOT indented under the roster: the roster describes what
        // the LOAD kept, and this describes what the last SYNC brought. Two
        // facts about the same activities, arrived at differently, and an
        // indent would claim they came from one place.
        lines.append(Self.lateArrivalLine(lateArrivals))
        // PATCH 380. THE THIRD FACT ABOUT THE SAME ACTIVITIES, and the one
        // §12.123.7 asked for: after a hydration the roster above describes a
        // file the store is no longer serving. Unconditional, so "no" is a
        // sentence somebody can read rather than a line that is missing —
        // §12.54.2, which is the rule this store has now applied three times
        // on this one block.
        lines.append(Self.hydrationLine(hydrationRoster))
        return lines
    }

    /// **HOW MANY ARRIVED BEHIND THE CURSOR — patch 376, §12.120.**
    ///
    /// New to the store, dated before the high-water mark, and kept by the
    /// roster's rules. That combination is the one case a cursor-based sync can
    /// miss: the source served something whose date this app had already
    /// walked past.
    ///
    /// The header of this file has pointed at this field since it was written —
    /// *"arrival is DETECTED rather than how one is missed"* — and until 376
    /// nothing read it. A count computed and never told is a fact the app has
    /// and the reader does not.
    ///
    /// **OPTIONAL, AND THAT IS THE PATCH AS MUCH AS THE ROW IS.** It was `= 0`,
    /// so a launch with no sync yet reported "none arrived late" when it meant
    /// "nobody has looked". §12.15.
    private(set) var lateArrivals: Int?

    /// Pure, for `PersistenceMode.derive`'s reason: the two states this
    /// sentence tells apart are exactly the ones a device cannot be made to
    /// produce on demand.
    nonisolated static func lateArrivalLine(_ late: Int?) -> String {
        guard let late else {
            return "Activities arriving late: no sync this launch"
        }
        return "Activities arriving late: \(late) in the most recent sync"
    }

    // MARK: Hydration — D7 slice B3, patch 380

    /// Where the activities this store is serving came from — patch 380.
    ///
    /// `.files`, AND 381 IS WHAT MOVES IT. `PlanMoveStore.servedFrom` sat here
    /// exactly this way at 368 and for the same reason: a store with no line
    /// in the paste cannot be told from a store nobody wired in (§12.54.2),
    /// and the line has to exist BEFORE the thing it reports on, or the paste
    /// that would show B3 working is the one nobody added.
    private(set) var servedFrom: StoreSource = .files

    /// What the hydration kept, and what it cost. Nil until one has happened.
    ///
    /// **SEPARATE FROM `loadRoster`, WHICH GOES ON DESCRIBING THE FILE.**
    /// §12.123.7 named this before it could happen: once a hydration replaces
    /// the store's contents, `Activity roster: 694 kept of 694 offered`
    /// describes `activities.json` while the store holds rows, and nothing on
    /// the screen says so. Two rosters with two subjects, both printed — not
    /// one number whose subject quietly moved. §12.15.
    private(set) var hydrationRoster: ActivityRoster.Result?

    /// Replaces the activities with the stored ones — D7 slice B3.
    ///
    /// **IT SETTLES, AND THAT IS NOT A NEW DECISION.** `load` settles and
    /// `ingest` settles; `ActivityParity` has settled the database side since
    /// 312. §12.43 says the third door calls the rule rather than trusting the
    /// rows to arrive settled. Two consequences worth stating rather than
    /// discovering: the list is re-ordered newest-first by LOCAL start, which
    /// `ActivityRepository.all` does not produce — it orders by `startUTC`,
    /// which §4.1 makes authoritative for ORDER while `startLocal` is
    /// authoritative for BELONGING — and a row the app's own rules now reject
    /// is dropped, because `DataCorrections.ignoredActivities` can gain an
    /// entry after a row was written. That second one is patch 310's whole
    /// argument, one door later.
    ///
    /// **IF SETTLING DROPS ANYTHING, THE VERIFIER'S `activities` COMPARISON
    /// DISAGREES FROM 381 — AND THE DISAGREEMENT WOULD BE TRUE.** It would
    /// mean the table holds rows the app's own rules reject, which is a
    /// finding to read rather than a difference to patch away.
    /// `hydrationRoster.dropped` is the number that says so, and the device
    /// paste of 16 August says 694 offered and 694 kept, so today it is zero.
    /// §12.123.7.
    ///
    /// **IT DOES NOT WRITE**, for `NotesStore.hydrate`'s reason and
    /// `PersistenceMode`'s rule: `activities.json` stays complete while the
    /// slice is under test, which is what makes taking `.activities` back out
    /// of `hydratedFamilies` a rollback rather than a data loss. `save()` is
    /// reached from `ingest` and from `resetCache`, and from nothing here.
    func hydrate(from stored: [Activity]) {
        let settled = ActivityRoster.settle(stored)
        hydrationRoster = settled
        activities = settled.activities
        servedFrom = .database
    }

    /// One line, always sayable, in both states — `lateArrivalLine`'s shape
    /// and its reason. Pure, so the two states can be driven from a test
    /// rather than from a device that has to be in one of them.
    nonisolated static func hydrationLine(_ r: ActivityRoster.Result?) -> String {
        guard let r else {
            return "Activities hydrated: no — the roster above is what the "
                + "store is serving"
        }
        return "Activities hydrated: \(r.activities.count) kept of "
            + "\(r.offered) offered from the database — the roster above "
            + "describes activities.json"
    }

    private let fileURL: URL
    private let cursorKey = "strava.cursor"
    private let lastSyncKey = "strava.lastSync"
    private let cutoffKey = "strava.cutoffUsed"
    private static let powerBackfillKey = "strava.powerBackfill"
    private static let speedBackfillKey = "strava.speedBackfill"
    private static let geoBackfillKey = "strava.geoBackfill"
    /// Patch 196. Its own key rather than a reused one — the note on the geo
    /// backfill below said that was the rule from now on.
    static let zoneBackfillKey = "strava.zoneBackfill"
    /// The retired shape — `[activity id: rendered line]`. Read once by the
    /// migration in `loadRejections` and then removed. Still named in the
    /// inventory beside the new key, because a device that has not launched
    /// this build still holds it.
    nonisolated static let rejectedKey = "strava.rejectedByRule"

    /// The receipts, as records — patch 278. A `Data` blob, for the reason
    /// `match.decisions` is one: UserDefaults cannot hold a `Codable` any
    /// other way, and two parallel keys that must agree is a split brain by
    /// construction.
    nonisolated static let rejectionsKey = "strava.rejections"

    /// Asked of the type that WRITES them — the lesson
    /// `loadThresholdKeysAreCoveredAtTheirSource` exists for, applied at the
    /// moment a key changes rather than after a delete has missed one.
    nonisolated static let rejectionKeys = [rejectionsKey, rejectedKey]

    /// **A STORE ROOTED SOMEWHERE ELSE — patch 378, and §12.69 is why.**
    ///
    /// The seam `CommuteStore`, `PlanMoveStore` and `Weather` already have.
    /// Nothing can drive a corrupt `activities.json` through the singleton —
    /// it reads Application Support on a device — so without this the guard
    /// below could not be shown to fail, and a guard that cannot be shown to
    /// fail has not been tested.
    ///
    /// IT DOES NOT RECORD TO THE READ JOURNAL, for `Weather`'s reason: a test
    /// store writing into the shared journal leaks into whatever runs next,
    /// and `canReconcile` reads that journal to decide whether rows may be
    /// deleted.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("activities.json")
        load()
    }

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
        // PATCH 378. A store the "Unreadable stores" list cannot name is a
        // store the list cannot warn about — 371's sentence, and until now
        // `activities.json` was exactly that. Recorded here rather than in
        // `load` so the seam above stays out of the shared journal.
        StoreReadJournal.shared.record("activities.json", lastLoad)

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

        // Patch 196 added `timeZoneIdentifier` and `startOffsetSeconds`, and
        // this rewind is the one with an expiry date on it.
        //
        // The other three above could be run at any time — the fields they fill
        // will still be there next year. These two will not. ADR-0002 retires
        // Strava at Phase 4A, Apple Health carries neither field, and no other
        // source in this app knows what clock a past activity was recorded on.
        // Every activity that is not backfilled before the Strava connection
        // ends has lost its zone permanently: not degraded, not recoverable
        // from a coordinate, gone.
        //
        // That is why this ships now rather than with Phase 3's import, and why
        // it deserves its own key — a rewind that has already been consumed by
        // another field's flag would fail silently and look done.
        if UserDefaults.standard.integer(forKey: Self.zoneBackfillKey) < 1 {
            cursor = Self.cutoffEpoch
            UserDefaults.standard.set(cursor, forKey: cursorKey)
            UserDefaults.standard.set(1, forKey: Self.zoneBackfillKey)
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
    /// UNCHANGED FOR EVERY READER — patch 278 made this computed rather than
    /// stored, and `SettingsView` cannot tell. The lines are the same lines;
    /// what changed is that the app now knows what is inside them.
    var rejected: [String] { receipts.map(\.label) }

    /// The receipts themselves, as records — patch 278, §12.24.
    ///
    /// The rendered line held everything `rejection`'s columns want and none
    /// of it as a field. Parsing it back would be inventing structure out of
    /// prose, so the store learned the shape instead.
    private(set) var receipts: [RejectionReceipt] = []

    private func loadRejections() {
        if let data = UserDefaults.standard.data(forKey: Self.rejectionsKey) {
            // A blob that will not decode is LEFT WHERE IT IS rather than
            // overwritten — §12.8.1's rule, and these cannot be re-fetched:
            // the recording they describe is not in `activities.json` and the
            // cursor moved past it years ago.
            receipts = (try? JSONDecoder.sub4.decode([RejectionReceipt].self,
                                                     from: data)) ?? []
            return
        }

        guard UserDefaults.standard.object(forKey: Self.rejectedKey) != nil else { return }
        let legacy = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        receipts = RejectionReceipt.migrate(legacy)
        // ONLY IF THE NEW COPY LANDED — patch 278c, the same rule as
        // `Matcher`. These receipts describe recordings that are not in
        // `activities.json` and that the cursor moved past years ago: if both
        // keys go, there is nothing anywhere that remembers them.
        guard persistRejections() else { return }
        UserDefaults.standard.removeObject(forKey: Self.rejectedKey)
    }

    private func recordRejections(_ candidates: [Activity]) {
        var known = Set(receipts.map(\.activityId))
        var added = false
        for a in candidates where a.selfContradictoryDistance {
            guard !known.contains(a.id) else { continue }
            // A RECEIPT MADE NOW KNOWS EVERYTHING. The activity is in hand
            // here — it is the only moment it ever will be, because the next
            // save writes it out of `activities.json` for good.
            receipts.append(RejectionReceipt(a, rule: .selfContradictoryDistance))
            known.insert(a.id)
            added = true
        }
        guard added else { return }
        receipts.sort { $0.activityId < $1.activityId }
        persistRejections()
    }

    /// Returns whether the blob was written — patch 278c.
    ///
    /// No failure to REPORT: `UserDefaults.set` has no API for one, and that
    /// is unchanged. What the `Bool` buys is the one decision that depends on
    /// it — the migration must not delete the retired key unless the new one
    /// is on disk.
    @discardableResult
    private func persistRejections() -> Bool {
        guard let data = try? JSONEncoder.sub4.encode(receipts) else { return false }
        UserDefaults.standard.set(data, forKey: Self.rejectionsKey)
        return true
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
                fetched = try await StravaClient.activities(after: Self.cutoffEpoch, token: token)
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
                fetched = try await StravaClient.activities(after: Self.cutoffEpoch, token: token)
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

        // Read BEFORE the loop moves it. Anything new that starts earlier than
        // this was uploaded after something later had already been seen — the
        // exact shape the old incremental cursor could never fetch.
        let highWater = cursor
        var late = 0

        recordRejections(incoming)
        for a in incoming {
            if byID[a.id] == nil, epoch(of: a) < highWater,
               ActivityRoster.isKept(a) { late += 1 }
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
            guard ActivityRoster.isKept(a) else {
                byID.removeValue(forKey: a.id); continue
            }
            byID[a.id] = a
        }

        // The same call `load` makes. Its counts are ignored here: a
        // dictionary's values have no order to be out of. §12.54.4.
        activities = ActivityRoster.settle(Array(byID.values)).activities
        lateArrivals = late
        UserDefaults.standard.set(cursor, forKey: cursorKey)
        save()
    }

    /// Moved to `ActivityRoster` at 310, along with `dedup` and the sort. Both
    /// of this store's entrances call `ActivityRoster.settle` now, so the rules
    /// cannot drift apart again — and D6c's database side calls the same one
    /// rather than reimplementing it. §12.54.


    /// Same sport, starting within a few minutes, similar distance → one session
    /// recorded by two devices. Keep the longer recording.
    /// `dedup` and `isDuplicate` moved to `ActivityRoster` at 310. They were
    /// `private` until 309 and static-but-here at 309; they belong with
    /// `isKept`, because the three of them together are what decides what the
    /// activity list is.


    private func epoch(of a: Activity) -> TimeInterval {
        (DayKey.date(a.dayKey) ?? Date()).timeIntervalSince1970
            + Double(a.startMinuteOfDay * 60)
    }

    // MARK: Persistence

    private func load() {
        // **BARE `JSONDecoder()`, AND IT IS NOT A STYLE CHOICE — §12.122.**
        //
        // `save()` below writes with a bare `JSONEncoder()`, so the dates in
        // `activities.json` are in the default numeric encoding.
        // `StoreRead.decode` DEFAULTS to `JSONDecoder.sub4`, which is
        // ISO-8601. Taking that default would make every existing file
        // undecodable — turning a patch about not destroying data into the
        // thing that destroys it, on every device at once. `Weather.load`
        // carries the same sentence, put there by 371 for the same reason.
        let (value, outcome) = StoreRead.decode([Activity].self, at: fileURL,
                                                decoder: JSONDecoder())
        lastLoad = outcome

        // THE ASSIGNMENT IS CONDITIONAL. A failed read leaves memory as it
        // was, which is what every other store here does. The old line was
        // `?? []`, and that is the whole of §12.115: it said "the athlete has
        // no activities" when it meant "I could not tell".
        guard let decoded = value else { return }
        recordRejections(decoded)

        // ONE CALL, AND THE OTHER DOOR MAKES THE SAME ONE — patch 310.
        //
        // 309 made both doors apply the same rules by writing them out twice.
        // This makes it structural rather than remembered, which matters
        // because D6c needs the database side to produce the same list from the
        // same rules, and two implementations of one rule is the mistake §12.43
        // cost three patches to learn.
        //
        // `loadRoster` stays nil unless a file was actually decoded — the
        // guard above returns first. That is the difference between "no cached
        // file" and "a cached file holding nothing", and it is the sixth
        // instance of §12.15's shape on this screen.
        //
        // AND SINCE 378 THE GUARD RETURNS FOR TWO DIFFERENT REASONS: no file,
        // and a file this app could not read. `loadRoster` is nil for both and
        // cannot tell them apart. `lastLoad` is what does, which is why
        // `loadSummary` asks it rather than reading nil as an answer.
        let settled = ActivityRoster.settle(decoded)
        loadRoster = settled
        activities = settled.activities
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
        activities = []
        // `receipts` since patch 278 — `rejected` is computed from it now.
        // This line is why 278 did not build: the sweep looked for
        // `.rejected`, and an assignment has no dot in front of it.
        receipts = []
        cursor = Self.cutoffEpoch
        lastSync = nil
        lastError = nil
        lastGateNotice = nil
        isSyncing = false
    }

    /// THE MEMORY IS NOT ROLLED BACK — patch 266, and unlike `NotesStore` that
    /// is deliberate.
    ///
    /// These activities came off the network a moment ago. Discarding them
    /// because a write failed would throw away a completed sync and show the
    /// athlete less than the app actually has, to buy a consistency nobody
    /// asked for. The disagreement is recorded instead: Settings says so, the
    /// tab badge lights, and the next successful sync clears it.
    ///
    /// **THE GUARD, SEVEN PATCHES LATE — 378, §12.122.**
    ///
    /// §12.20 on a file rather than a row: nothing is overwritten on the
    /// strength of a read nobody could make. `ingest` seeds `byID` from
    /// `activities`, so after a failed load that dictionary is empty and this
    /// write puts one sync window where the whole history was.
    ///
    /// **`rebuildingFromScratch` IS NOT `force`, AND THE NAME IS THE POINT.**
    /// `resetCache()` must be able to write — it is how an athlete with a
    /// corrupt file recovers, and a guard that blocked it would be this patch
    /// causing the harm it exists to prevent. What makes that write safe is
    /// not that somebody asked for it: it is that `resetCache` puts `cursor`
    /// back to the cutoff FIRST, so the file being written is a complete
    /// replacement and the next sync re-pulls everything. A caller that has
    /// not done that has no business passing `true`.
    ///
    /// THE COST IS DISCLOSED, NOT HIDDEN. While the file is unreadable a sync
    /// still runs and its activities still appear on screen; they are not
    /// persisted, and come back next launch. That is the cheap failure. The
    /// expensive one is the file. "Unreadable stores" names `activities.json`
    /// as of this patch, which is how anybody finds out.
    ///
    /// RETURNS WHETHER IT WROTE — 374's change to `Weather.save`, for the same
    /// reason: a refusal that cannot be observed cannot be tested. §12.69.
    @discardableResult
    func save(rebuildingFromScratch: Bool = false) -> Bool {
        guard rebuildingFromScratch || lastLoad.isTrustworthy else { return false }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return StoreWriteJournal.shared.attempt("activities.json") {
            try StoreWrite.encode(activities, to: fileURL,
                                  store: "activities.json", encoder: enc)
        }
    }

    /// Wipe local cache and re-pull from the cutoff.
    func resetCache() {
        activities = []
        cursor = Self.cutoffEpoch
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: cursorKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        // `rebuildingFromScratch` — `cursor` went back to the cutoff four
        // lines up, so this write is a complete replacement and the next sync
        // re-pulls everything. That is what authorises it over an unreadable
        // file, and it is the athlete's recovery path. §12.122.
        save(rebuildingFromScratch: true)
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
