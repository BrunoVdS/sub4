//
//  ActivityIndependenceTests.swift
//  Sub4CoreTests
//
//  The activity parity keeps its own read — patch 381, D7 slice B3,
//  ADR-0003 §12.125. §12.101 one slice later.
//
//  WHY THIS PATCH EXISTS BEFORE THE FLIP
//  -------------------------------------
//  `ShadowParity.run` read `ActivityStore.shared.activities` for the app side
//  of slices 1 and 2. 382 hydrates that store from the database, and on that
//  day both sides of `ActivityParity` and `VolumeParity` would be the same
//  rows — agreeing perfectly, proving nothing, and saying so nowhere.
//
//  356 met this exactly one slice ago and answered it: the authored read-back
//  stopped asking the stores and read `notes.json`, `commutes.json` and
//  `moves.json` directly. 343 did the same for the plan by decoding the
//  bundle. `activities.json` is still written, still complete, and still the
//  legacy side's only copy — so the same answer is available here, and it has
//  to land BEFORE the flip or there is a build in which the comparison is
//  vacuous.
//
//  WHAT IS TESTED HERE AND WHAT IS GUARDED INSTEAD
//  -----------------------------------------------
//  The defect this patch removes is a NEGATIVE — `ShadowParity` must not ask
//  `ActivityStore.shared` for its app side — and no assertion can see it
//  today, because the store and the file hold the same activities. That is
//  what `apply-381.py` is for. 356 recorded the identical split for the
//  identical reason.
//
//  What CAN be tested is everything this patch adds that has a failure mode:
//  the three states of the independent read, the provenance the report now
//  carries, an unclean app side refusing to read as healthy, and the write
//  the seam should never make.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The activity parity reads for itself")
@MainActor
struct ActivityIndependenceTests {

    // MARK: Fixtures

    private func ride(_ id: String, at startLocal: String,
                      movingTime: Int = 3_600, distance: Double = 24_300,
                      maxSpeed: Double? = 12.4) -> Activity {
        Activity(id: id, name: "Ride", sportType: "Ride",
                 startLocal: startLocal, distance: distance,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: 130, isTrainer: false,
                 maxHeartrate: 160, gearId: nil, maxSpeed: maxSpeed,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: startLocal + "Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-381-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// The store's own encoder, so what is written is what `load` expects —
    /// a bare `JSONEncoder`, not `JSONEncoder.sub4`. §12.122.4.
    private func write(_ activities: [Activity], to dir: URL) throws {
        let data = try JSONEncoder().encode(activities)
        try data.write(to: dir.appendingPathComponent("activities.json"))
    }

    // MARK: The independent read

    /// A SMOKE TEST, AND HONEST ABOUT BEING ONE — `AuthoredIndependenceTests`'
    /// first test, for its reason. It reads whatever the test host's container
    /// holds, so it cannot assert a count. What it asserts is that the read
    /// HAPPENS and names itself: a container this build cannot reach fails
    /// here rather than on a device.
    @Test("The source reads and says where it came from")
    func theSourceReads() {
        let s = ActivitySource.read()
        #expect(s.directoryFound, "Application Support was not reachable")
        #expect(s.isTrustworthy)
        #expect(s.line.contains("activities.json"))
        #expect(!s.line.contains("store"),
                "the whole point is that it did not ask the store")
    }

    /// **THE ONE WITH A REAL FAILURE MODE.** A container the app cannot reach
    /// and a device with no activities produce the same empty array. §12.15:
    /// one says the athlete has recorded nothing, the other says the app could
    /// not look, and a comparison must never report the second as the first.
    @Test("An unreachable container is not an empty history")
    func unreachableIsNotEmpty() {
        let lost = ActivitySource.Read(activities: [], roster: nil,
                                       load: .absent, directoryFound: false)
        #expect(!lost.isTrustworthy, "the read was not performed at all")
        #expect(lost.line.contains("unreachable"))

        let fresh = ActivitySource.Read(activities: [], roster: nil,
                                        load: .absent, directoryFound: true)
        #expect(fresh.isTrustworthy,
                "a fresh install has no activities.json and that is a clean read")
        #expect(fresh.line != lost.line)
    }

    /// `.absent` is trustworthy and `.unreadable` is not — `StoreLoad`'s rule,
    /// and this checks the struct applies it rather than reporting a clean
    /// read because the directory was there.
    @Test("An unreadable file is not a clean read")
    func unreadableIsNotClean() {
        let bad = ActivitySource.Read(activities: [], roster: nil,
                                      load: .unreadable("the data could not be read"),
                                      directoryFound: true)
        #expect(!bad.isTrustworthy)
        #expect(bad.line.contains("could not be read"))
        #expect(bad.line.contains("store"),
                "and it names what was compared instead")
    }

    /// The read goes through the store's own `init(directory:)` — 364's rule,
    /// *not a second decoder*. So it settles by the same rules, and what comes
    /// back is what the app would show.
    @Test("The read settles what it finds, through the store's own door")
    func theReadSettles() throws {
        let dir = try directory()
        try write([ride("a", at: "2026-04-21T09:00:00"),
                   ride("b", at: "2026-04-22T09:00:00"),
                   ride("old", at: "2020-01-01T09:00:00")], to: dir)

        let store = ActivityStore(directory: dir)
        #expect(store.activities.map(\.id) == ["b", "a"],
                "settled, ordered, and the pre-cutoff row dropped")
        #expect(store.loadRoster?.offered == 3)
        #expect(store.lastLoad.isTrustworthy)
    }

    // MARK: The write the seam must not make

    /// **FOUND WHILE GIVING THE PARITY ITS OWN READ, AND IT IS A REAL ONE.**
    ///
    /// `load()` calls `recordRejections`, which appends to `receipts` and
    /// writes `strava.rejections` — a shared `UserDefaults` key. A seam-rooted
    /// store starts with `receipts` EMPTY, because `loadRejections` runs in
    /// `private init()` only. So one self-contradictory row in the file it
    /// reads would have written a blob holding that one alone, losing the
    /// three receipts this device has kept since 278 — recordings that are in
    /// no file and that the cursor moved past years ago. §12.8.1: nothing
    /// could re-fetch them.
    ///
    /// Unreachable in practice — a rejected activity is never written to
    /// `activities.json` — which is the shape this project keeps paying for: a
    /// write nobody can trigger until the day somebody can.
    @Test("A store rooted elsewhere records no rejection")
    func theSeamRecordsNoRejection() throws {
        let dir = try directory()
        // 60 km in an hour against a 5 m/s maximum: 16.7 m/s average, and the
        // rule refuses anything above 1.5x the maximum.
        let impossible = ride("bad", at: "2026-04-21T09:00:00",
                              movingTime: 3_600, distance: 60_000, maxSpeed: 5)
        #expect(impossible.selfContradictoryDistance,
                "the fixture has to be refusable or this test proves nothing")
        try write([impossible, ride("a", at: "2026-04-22T09:00:00")], to: dir)

        let store = ActivityStore(directory: dir)

        #expect(store.receipts.isEmpty,
                "a seam store's receipts start empty; writing them replaces the device's")
        #expect(store.activities.map(\.id) == ["a"],
                "the rule still refuses it — what changes is what is RECORDED")
    }

    // MARK: The provenance the report carries

    /// THE DEFAULT NAMES THE SINGLETON, DELIBERATELY — 356's argument. A
    /// caller nobody updated announces itself in the paste instead of hiding,
    /// and after 382 this sentence on that line IS the defect.
    @Test("A report nobody told says it came from the store")
    func theDefaultAnnouncesItself() {
        let r = ActivityParity.compare(store: [], databaseRows: [],
                                       databaseSkipped: 0)
        #expect(r.appSideCameFrom == "ActivityStore.shared")
        #expect(r.appSideWasReadCleanly)
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("the app side came from: ActivityStore.shared")
        }))
    }

    /// UNCONDITIONAL, and it is the line every count under it means. A parity
    /// report that does not say where its own side came from cannot be checked
    /// by anybody who was not holding the phone. §12.54.2.
    @Test("The provenance is two lines and both are always there")
    func theProvenanceIsPrinted() {
        var r = ActivityParity.compare(store: [ride("a", at: "2026-04-21T09:00:00")],
                                       databaseRows: [ride("a", at: "2026-04-21T09:00:00")],
                                       databaseSkipped: 0)
        r.appSideCameFrom = "activities.json, read directly"
        r.appSideWasReadCleanly = true

        let lines = r.diagnosticLines
        #expect(lines.contains(where: {
            $0 == "  the app side came from: activities.json, read directly"
        }))
        #expect(lines.contains(where: {
            $0 == "  the app side was read cleanly: yes"
        }))

        r.appSideWasReadCleanly = false
        #expect(r.diagnosticLines.contains(where: {
            $0 == "  the app side was read cleanly: NO"
        }), "and the bad state shouts, because it is the one that matters")
    }

    /// **THE ONE WITH TEETH.** Zero differences over an app side that could
    /// not be read is not a pass. Without this, a device whose
    /// `activities.json` had gone unreadable would fall back to the store,
    /// compare the database against itself, and print `no differences` in the
    /// one place this stage reads as evidence. §12.69.
    @Test("An unclean app side is not healthy however few differences there are")
    func anUncleanAppSideIsNotHealthy() {
        let a = ride("a", at: "2026-04-21T09:00:00")
        var r = ActivityParity.compare(store: [a], databaseRows: [a],
                                       databaseSkipped: 0)
        #expect(r.unexplained == 0, "the two sides agree completely")
        #expect(r.isHealthy, "and with a clean read that is a pass")

        r.appSideWasReadCleanly = false
        #expect(r.unexplained == 0, "nothing about the comparison changed")
        #expect(!r.isHealthy,
                "but it compared the database against whatever was to hand")
    }

    /// **THE CONTROL THIS PATCH EMPTIED, AND 381a PUT BACK.**
    ///
    /// `storeIsSettled` is computed from the list handed to `compare`, and
    /// since 381 that list comes out of `load`, which settles. True by
    /// construction, and §12.69 is that a check which cannot fail has not been
    /// tested. `liveStoreIsSettled` asks the store the same question through
    /// the same rule, and answers in three states.
    @Test("The settled control is asked of the live store, and nil is not yes")
    func theSettledControlIsAskedOfTheStore() {
        let long = ride("long", at: "2026-04-21T09:00:00",
                        movingTime: 7_500, distance: 61_700)
        let short = ride("short", at: "2026-04-21T09:05:00",
                         movingTime: 7_200, distance: 60_400)

        #expect(!ActivityParity.isSettled([long, short]),
                "that pair would collapse, so the list is not settled")
        #expect(ActivityParity.isSettled([long]))

        var r = ActivityParity.compare(store: [long], databaseRows: [long],
                                       databaseSkipped: 0)
        #expect(r.liveStoreIsSettled == nil, "nobody has asked yet")
        #expect(r.unexplained == 0, "and not asking is not a difference")
        #expect(r.diagnosticLines.contains(
            "  the live store's list is settled: not asked"))

        r.liveStoreIsSettled = false
        #expect(r.unexplained == 1, "an unsettled live store is a difference")
        #expect(!r.isHealthy)
        #expect(r.diagnosticLines.contains(
            "  the live store's list is settled: no"))
    }
}
