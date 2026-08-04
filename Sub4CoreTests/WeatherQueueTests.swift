//
//  WeatherQueueTests.swift
//  Sub4CoreTests
//
//  What the backfill button is actually offering — patch 227.
//
//  THE DEFECT THIS FILE EXISTS FOR
//  -------------------------------
//  Three filters described the same idea and disagreed. `pending` counted
//  outdoor activities with no reading; `backfill` queued the same set; but
//  `canFetch`, the only one that decided anything, ALSO excluded the ids that
//  had failed this session. With two activities both providers had refused,
//  the phone showed "Fetch weather for 2 activities", queued them, declined
//  them one at a time, and ran a progress counter from 0 of 2 to 2 of 2 while
//  storing nothing. Every number on the screen was identical afterwards.
//
//  That is the failure mode worth a test: not a crash, not a wrong figure — a
//  control that reports completed work it never attempted, which leaves
//  nothing for anybody to notice.
//
//  So there is now one definition, `WeatherStore.fetchable`, and the assertion
//  that matters is `theOfferMatchesWhatWouldBeAttempted`.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct WeatherQueueTests {

    /// Outdoor by default: `Activity.isOutdoor` requires a coordinate, not just
    /// `isTrainer != true`, so a helper without lat/lon would silently make
    /// every case in this file vacuous.
    private func activity(_ id: String,
                          startLocal: String = "2026-07-28T07:24:06",
                          trainer: Bool? = false,
                          lat: Double? = 51.2194,
                          lon: Double? = 4.4025) -> Activity {
        Activity(id: id, name: "Session \(id)", sportType: "Run",
                 startLocal: startLocal, distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: trainer,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T05:24:06Z", startLat: lat, startLon: lon,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// THE ONE THAT MATTERS. An activity both providers already refused this
    /// session is not offered again until `retryAll` clears it — because
    /// `canFetch` will decline it, and offering work that will be declined is
    /// the whole bug.
    @Test("An activity that failed this session is not offered")
    func failedActivitiesAreNotOffered() {
        let acts = [activity("a"), activity("b")]
        let queue = WeatherStore.fetchable(acts, have: [], unavailable: ["b"])
        let ids = queue.map(\.id)
        #expect(ids == ["a"])
    }

    /// The counterpart: `retryAll` empties the failure set, and the same
    /// activity comes back. A session-scoped refusal that behaved like a
    /// permanent one would make the retry button decorative.
    @Test("Clearing the failure set puts the activity back in the queue")
    func clearingFailuresRestoresTheActivity() {
        let acts = [activity("a"), activity("b")]
        let queue = WeatherStore.fetchable(acts, have: [], unavailable: [])
        #expect(queue.count == 2)
    }

    /// The drift test, and the reason this is a static function rather than
    /// three inline filters. It asserts the count Settings prints is the count
    /// of the queue the backfill would build — whatever the shared store
    /// happens to be holding on this runner.
    @Test("The offer matches what would actually be attempted")
    func theOfferMatchesWhatWouldBeAttempted() {
        let acts = [activity("a"), activity("b"), activity("c", trainer: true)]
        let store = WeatherStore.shared
        let queue = WeatherStore.fetchable(acts,
                                           have: Set(store.byActivity.keys),
                                           unavailable: store.unavailable)
        #expect(store.pending(acts) == queue.count)
    }

    @Test("An indoor session is never offered")
    func indoorIsNotOffered() {
        let queue = WeatherStore.fetchable([activity("t", trainer: true)],
                                           have: [], unavailable: [])
        #expect(queue.isEmpty)
    }

    /// `isOutdoor` already requires a coordinate. Asserted anyway: without it
    /// an activity with no position would sit in the queue for ever —
    /// `fetchIfNeeded` returns at the `lat`/`lon` guard WITHOUT marking the id
    /// unavailable, so it would be re-offered after every backfill, and the
    /// pending count would never reach zero.
    @Test("An activity with no start coordinate is never offered")
    func noCoordinateIsNotOffered() {
        let queue = WeatherStore.fetchable([activity("n", lat: nil, lon: nil)],
                                           have: [], unavailable: [])
        #expect(queue.isEmpty)
    }

    @Test("An activity that already has a reading is not offered")
    func storedActivitiesAreNotOffered() {
        let queue = WeatherStore.fetchable([activity("a"), activity("b")],
                                           have: ["a"], unavailable: [])
        let ids = queue.map(\.id)
        #expect(ids == ["b"])
    }

    /// Oldest first, so a backfill interrupted halfway leaves the recent
    /// history complete rather than a hole in the middle.
    @Test("The queue runs oldest first")
    func theQueueIsOldestFirst() {
        let acts = [activity("new", startLocal: "2026-07-28T07:24:06"),
                    activity("old", startLocal: "2025-01-04T09:00:00"),
                    activity("mid", startLocal: "2026-01-01T18:30:00")]
        let ids = WeatherStore.fetchable(acts, have: [], unavailable: []).map(\.id)
        #expect(ids == ["old", "mid", "new"])
    }

    /// The failure list Settings prints, newest first — the opposite order from
    /// the queue, and deliberately: a queue is worked from the far end of the
    /// history, a failure list is read from today backwards.
    @Test("The failure list names the right activities, newest first")
    func theFailureListIsNewestFirst() {
        let acts = [activity("a", startLocal: "2025-01-04T09:00:00"),
                    activity("b", startLocal: "2026-07-28T07:24:06"),
                    activity("c", startLocal: "2026-01-01T18:30:00")]
        let listed = WeatherStore.failedList(acts, unavailable: ["a", "b"]).map(\.id)
        #expect(listed == ["b", "a"], "the failure list is not newest first")
    }

    /// `failed` is the instance form of `failedList`, and the pair has the same
    /// drift risk `pending` and `backfill` had. Asserted against the shared
    /// store's own failure set, whatever this runner left in it.
    @Test("The instance failure list agrees with the pure one")
    func theFailureListDoesNotDrift() {
        let acts = [activity("a"), activity("b")]
        let store = WeatherStore.shared
        let direct = WeatherStore.failedList(acts, unavailable: store.unavailable)
        #expect(store.failed(acts).map(\.id) == direct.map(\.id))
    }
}
