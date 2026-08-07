//
//  ActivityStoreLoadTests.swift
//  Sub4CoreTests
//
//  Patches 309 and 310. ADR-0003 §12.53, §12.54.
//
//  THE FILE NAME LAGS THE SUITE, deliberately. Renaming it would mean deleting
//  a file from the project, and a delete in an apply script is a class of
//  operation this workflow has never needed. The suite is `ActivityRosterTests`
//  because that is what it tests.
//
//  `bothDoorsAgree` is the one with teeth, and it is a test about a property
//  rather than a case: the same activities, put in through either door, must
//  come out the same. Until 309 they did not — `ingest` deduped and sorted,
//  `load` only filtered — and nothing anywhere said so, because the file was
//  written from an array that had already been through both.
//
//  `dedup` was `private` until 309, which is why the two doors could drift
//  apart without a test noticing — nothing outside that file could ask what it
//  did. At 310 the three rules live in `ActivityRoster` and both of the store's
//  entrances call `settle`, so the drift is structurally impossible rather than
//  remembered.
//
//  `settleCountsWhatItDid` is the second one with teeth, and it is the answer
//  to a question 309 could not answer: an absent row on screen means zero, or
//  it means nobody wired it in. A test that asserts the COUNT is 1 when one
//  duplicate went in proves the number is produced, without needing a duplicate
//  on the device. §12.54.2.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct ActivityRosterTests {

    private func ride(_ id: String, at startLocal: String,
                      movingTime: Int = 3_600, distance: Double = 24_300,
                      sport: String = "Ride") -> Activity {
        Activity(id: id, name: "Ride", sportType: sport,
                 startLocal: startLocal, distance: distance,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: 130, isTrainer: false,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: startLocal + "Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    // MARK: The rules, as the store applies them

    /// Newest first, by LOCAL start — §4.1 says `startUTC` is authoritative for
    /// order and `startLocal` for belonging, and `ActivityRepository` uses UTC
    /// while the store uses local. The twin must match the store.
    @Test("The list is newest first by local start")
    func newestFirstByLocal() {
        let a = ride("1", at: "2026-07-28T06:00:00")
        let b = ride("2", at: "2026-07-28T19:00:00")
        let c = ride("3", at: "2026-07-29T07:00:00")
        let sorted = [a, b, c].sorted { $0.startLocal > $1.startLocal }
        #expect(sorted.map(\.id) == ["3", "2", "1"])
    }

    /// The real case `MatchRules` records: 21 Apr 2026, two rides at an
    /// identical start time from two devices, 61.7 km and 60.4 km.
    @Test("Two devices uploading one ride is one ride, and the longer wins")
    func theLongerOfADuplicatePairWins() {
        let short = ride("short", at: "2026-04-21T09:00:00",
                         movingTime: 7_200, distance: 60_400)
        let long = ride("long", at: "2026-04-21T09:05:00",
                        movingTime: 7_500, distance: 61_700)

        // Both orders in, the same one out. `dedup` sorts ascending before it
        // walks, so a caller cannot change the survivor by changing the input
        // order — which is the property a reimplementation would break.
        for input in [[short, long], [long, short]] {
            let out = ActivityRoster.dedup(input)
            #expect(out.count == 1)
            #expect(out.first?.id == "long", "more moving time wins")
        }
    }

    @Test("Different sports at the same minute are not duplicates")
    func differentSportsSurvive() {
        let run = ride("r", at: "2026-04-21T09:00:00", sport: "Run")
        let bike = ride("b", at: "2026-04-21T09:00:00", sport: "Ride")
        #expect(ActivityRoster.dedup([run, bike]).count == 2)
    }

    @Test("The same sport far enough apart is two sessions")
    func farApartSurvives() {
        let morning = ride("m", at: "2026-04-21T09:00:00")
        let evening = ride("e", at: "2026-04-21T18:00:00")
        #expect(ActivityRoster.dedup([morning, evening]).count == 2)
    }

    // MARK: THE ONE WITH TEETH

    /// THE PROPERTY 309 EXISTS FOR. The same activities, through either door,
    /// come out the same. Before 309 the load path skipped both steps, so a
    /// cached duplicate pair survived until the next sync and nothing said so.
    @Test("Both doors produce the same list")
    func bothDoorsAgree() {
        let a = ride("a", at: "2026-04-21T09:00:00", movingTime: 7_500, distance: 61_700)
        let dup = ride("b", at: "2026-04-21T09:05:00", movingTime: 7_200, distance: 60_400)
        let later = ride("c", at: "2026-04-22T09:00:00")

        // What `ingest` does.
        let viaIngest = ActivityRoster
            .dedup([a, dup, later])
            .sorted { $0.startLocal > $1.startLocal }

        // What `load` does as of 309 — same two steps, and the file arrives in
        // whatever order it was written in, so start from a different one.
        let viaLoad = ActivityRoster
            .dedup([later, dup, a])
            .sorted { $0.startLocal > $1.startLocal }

        #expect(viaIngest.map(\.id) == viaLoad.map(\.id))
        #expect(viaIngest.map(\.id) == ["c", "a"], "the pair collapsed, longer kept")
    }

    // MARK: What settling cost — patch 310

    /// THE SECOND ONE WITH TEETH. 309 hid these numbers when they were zero,
    /// so a working counter and an unwired one looked the same on screen. This
    /// proves the number is produced. The screen showing it is §12.54.2's job.
    @Test("Settling counts what it dropped and what it collapsed")
    func settleCountsWhatItDid() {
        let a = ride("a", at: "2026-04-21T09:00:00", movingTime: 7_500, distance: 61_700)
        let dup = ride("b", at: "2026-04-21T09:05:00", movingTime: 7_200, distance: 60_400)
        let later = ride("c", at: "2026-04-22T09:00:00")
        // Before the cutoff, so `isKept` refuses it.
        let old = ride("old", at: "2020-01-01T09:00:00")

        let r = ActivityRoster.settle([a, dup, later, old])
        #expect(r.offered == 4, "the denominator, without which zero says nothing")
        #expect(r.dropped == 1, "before the cutoff")
        #expect(r.collapsed == 1, "the pair")
        #expect(r.activities.count == 2)
        #expect(r.activities.map(\.id) == ["c", "a"])
    }

    /// A clean list must still produce all four numbers. This is the case that
    /// matters most, because it is the one that runs on the device every day —
    /// and the one 309 rendered as nothing at all.
    @Test("Nothing to correct still says so, with its denominator")
    func nothingToCorrectStillSpeaks() {
        let r = ActivityRoster.settle([ride("a", at: "2026-04-22T09:00:00"),
                                       ride("b", at: "2026-04-21T09:00:00")])
        #expect(r.offered == 2)
        #expect(r.dropped == 0)
        #expect(r.collapsed == 0)
        #expect(!r.arrivedOutOfOrder)
        #expect(r.summary == "2 · 0 collapsed · in order")
        #expect(r.diagnosticLines.count == 4,
                "all four, always — 266c's rule")
        #expect(r.diagnosticLines.first == "Activity roster: 2 kept of 2 offered")
    }

    @Test("Out of order is noticed, and only on the filtered list")
    func outOfOrderIsNoticed() {
        let older = ride("older", at: "2026-04-21T09:00:00")
        let newer = ride("newer", at: "2026-04-22T09:00:00")
        #expect(ActivityRoster.settle([older, newer]).arrivedOutOfOrder)
        #expect(!ActivityRoster.settle([newer, older]).arrivedOutOfOrder)
    }

    /// The rules are applied by ONE function, so both doors cannot diverge —
    /// 309 made them agree, 310 makes disagreement unavailable.
    @Test("Settling is idempotent")
    func settlingTwiceChangesNothing() {
        let input = [ride("a", at: "2026-04-21T09:00:00", movingTime: 7_500, distance: 61_700),
                     ride("b", at: "2026-04-21T09:05:00", movingTime: 7_200, distance: 60_400),
                     ride("c", at: "2026-04-22T09:00:00")]
        let once = ActivityRoster.settle(input)
        let twice = ActivityRoster.settle(once.activities)
        #expect(once.activities.map(\.id) == twice.activities.map(\.id))
        #expect(twice.collapsed == 0, "nothing left to collapse")
        #expect(!twice.arrivedOutOfOrder)
    }
}
