//
//  HydrationTests.swift
//  Sub4CoreTests
//
//  D7 slice B1, second half — patch 344.
//
//  WHAT THIS SUITE IS FOR
//  ----------------------
//  Three stores learn to take their data from rows. Nothing calls them yet:
//  `sliceUnderTest` is still nil and 345 is the patch that wires the launch. So
//  every check here is on the machinery, which is exactly the half that can be
//  checked without a device.
//
//  THE ONE THAT MATTERS MOST is `hydratingRebuildsEveryDerivedIndex`. `PlanStore`
//  holds three things derived from `plan` — `byDate`, `weeksByUid` and
//  `focusCache` — and none of them knows it is derived. A hydration that moved
//  `plan` without rebuilding all three would leave a store whose index describes
//  a plan it no longer holds: internally consistent on both sides, describing
//  nothing, and invisible to any test that only checked `plan`.
//
//  A NOTE ON WHAT IS NOT ASSERTED, so nobody reads a gap as a guarantee:
//  `AthleteStore.hydrate` must leave shoes, bikes and retired gear alone until
//  B5. A fresh store holds none of those, so a test on this side of the file
//  boundary cannot tell "left alone" from "cleared" — both read as empty. What
//  IS asserted is the contract that reaches the paste: `servedFrom` is
//  `.partial` and names gear as still coming from files. A real check needs an
//  injectable file URL, and that is not this patch's work. §12.69 — a test that
//  cannot fail has not tested anything, and saying so beats writing one.
//

import Testing
import Foundation
@testable import Sub4

// MARK: - Fixtures

/// Small plans built by hand, so a hydration can be watched replacing a real
/// 261-session plan with something whose every day is known.
enum HydrationFixtures {

    // PATCH 394 — MOVED HERE FROM `HydrationDecisionTests`, WHERE THEY WERE
    // PRIVATE. `DetailHydrationTests` needs a whole plan and a whole athlete to
    // reach `.hydrate` at all, and a second copy of these three is a second
    // thing that must be kept agreeing with `PlanLoad`. §12.43 — do not
    // reimplement a rule; call it.
    static func loadedPlan() -> PlanLoad {
        .loaded(meta: Meta(plan: "stored", week1Monday: "2026-07-27",
                           raceDate: "2027-03-21", targetTime: "04:00:00",
                           targetPaceSecKm: 341),
                weeks: [HydrationFixtures.week("w1", startDate: "2026-07-27")],
                sessions: [HydrationFixtures.session("s0", week: "w1",
                                                     date: "2026-07-27")],
                version: PlanLoad.VersionNote(sourceLabel: "test",
                                              importedUTC: "2026-08-10T00:00:00Z",
                                              versionsPresent: 1),
                rows: PlanLoad.TableRows(), skipped: 0)
    }

    static func loadedExtras() -> PlanExtrasLoad {
        .loaded(fuel: nil, warmup: nil, exercises: [], skipped: 0)
    }

    static func loadedAthlete() -> AthleteLoad {
        .loaded(constants: AthleteConstants(hrMaxObserved: 181, version: 1),
                ftp: 270,
                zones: [.init(index: 1, min: 0, max: 115),
                        .init(index: 2, min: 116, max: nil)])
    }

    static func week(_ uid: String, startDate: String?) -> Week {
        Week(uid: uid, weekNo: 1, label: "1", dateRange: nil,
             startDate: startDate, tag: nil, badge: nil, kind: nil,
             logged: false, stats: [:])
    }

    static func session(_ uid: String, week weekUid: String,
                        date: String?, seq: Int = 0,
                        discipline: Discipline = .run,
                        title: String = "20 km easy") -> Session {
        Session(uid: uid, weekUid: weekUid, day: "Mon", date: date,
                discipline: discipline, intensity: nil, title: title,
                detail: nil, fuel: nil, prep: nil, seq: seq,
                swimDetail: nil, strengthDetail: nil)
    }

    /// A one-week, two-session plan on the days given.
    static func plan(weekUid: String, start: String,
                     days: [String]) -> Plan {
        Plan(meta: Meta(plan: "fixture", week1Monday: start,
                        raceDate: "2027-03-21", targetTime: "04:00:00",
                        targetPaceSecKm: 341),
             weeks: [week(weekUid, startDate: start)],
             sessions: days.enumerated().map { i, d in
                 session("s\(i)", week: weekUid, date: d, seq: i)
             },
             exercises: [], fuel: nil, warmup: nil)
    }
}

// MARK: - PlanStore

@MainActor
@Suite("The plan store takes a stored plan")
struct PlanHydrationTests {

    /// A store of its own, never `shared`.
    ///
    /// 1267 tests share one process and Swift Testing runs suites in parallel.
    /// Hydrating `PlanStore.shared` would change the plan under
    /// `PlanCoverageTests` and `PlanFocusTests` while they are reading it —
    /// which is why 344 made `init` internal and why nothing here touches the
    /// singleton.
    private func store() -> PlanStore { PlanStore() }

    @Test("A fresh store serves the bundle and says so")
    func aFreshStoreSaysWhereItsPlanCameFrom() {
        let s = store()
        #expect(s.servedFrom == .files)
        #expect(s.plan.sessions.count > 0, "the bundled plan is the starting point")
    }

    /// THE ONE THAT MATTERS. Four things move or the store is worse than either
    /// half — see the file header.
    @Test("Hydrating rebuilds every derived index")
    func hydratingRebuildsEveryDerivedIndex() {
        let s = store()

        // Populate the focus cache from the BUNDLED plan, so a hydration that
        // forgot to clear it would keep answering about a plan it no longer
        // holds.
        _ = s.focus
        #expect(s.focusCache != nil, "the cache is populated by reading it")

        let stored = HydrationFixtures.plan(weekUid: "w-stored",
                                            start: "2026-09-07",
                                            days: ["2026-09-07", "2026-09-09"])
        s.hydrate(from: stored)

        // `plan` itself
        #expect(s.plan.sessions.count == 2)
        #expect(s.plan.meta.plan == "fixture")
        #expect(s.servedFrom == .database)

        // `byDate`
        #expect(s.sessions(on: "2026-09-07").count == 1)
        #expect(s.sessions(on: "2026-09-09").count == 1)

        // `weeksByUid`
        #expect(s.weeksByUid["w-stored"] != nil)
        #expect(s.weeksByUid.count == 1, "the bundled plan's 37 weeks are gone")
        #expect(s.week(containing: "2026-09-07")?.uid == "w-stored")

        // `focusCache` — cleared, then rebuilt from the plan the store now
        // holds. Checked as the cache rather than through `PlanFocus`'s own
        // fields: what can go wrong here is a STALE answer surviving, and a
        // cache that was not cleared is exactly that.
        #expect(s.focusCache == nil, "the bundled plan's focus is gone")
        _ = s.focus
        #expect(s.focusCache != nil, "and it derives again on demand")
    }

    /// THE HAZARD A MERGE WOULD HIDE. Hydration can REMOVE a day. An index
    /// that was added to rather than rebuilt would keep answering for dates the
    /// stored plan does not have — and every one of those answers would look
    /// like real plan data.
    @Test("A day the stored plan does not have is gone")
    func hydratingRemovesDaysTheStoredPlanDoesNotHave() {
        let s = store()
        let firstDay = s.plan.sessions.compactMap(\.date).min()
        #expect(firstDay != nil, "the bundled plan has dated sessions")
        #expect(!s.sessions(on: firstDay!).isEmpty)

        s.hydrate(from: HydrationFixtures.plan(weekUid: "w-stored",
                                               start: "2026-09-07",
                                               days: ["2026-09-07"]))

        #expect(s.sessions(on: firstDay!).isEmpty,
                "a rebuilt index, not a merged one")
        #expect(s.weeksByUid.count == 1)
    }

    /// Hydrating twice leaves the store describing the SECOND plan only. The
    /// same rebuild, exercised from a hydrated state rather than from `init`.
    @Test("Hydrating twice keeps only the newest plan")
    func hydratingTwiceKeepsOnlyTheNewest() {
        let s = store()
        s.hydrate(from: HydrationFixtures.plan(weekUid: "a", start: "2026-09-07",
                                               days: ["2026-09-07"]))
        s.hydrate(from: HydrationFixtures.plan(weekUid: "b", start: "2026-09-14",
                                               days: ["2026-09-14"]))
        #expect(s.sessions(on: "2026-09-07").isEmpty)
        #expect(s.sessions(on: "2026-09-14").count == 1)
        #expect(s.weeksByUid["a"] == nil)
        #expect(s.weeksByUid["b"] != nil)
    }
}

// MARK: - ConstantsStore

@MainActor
@Suite("The constants store preserves what the database cannot hold")
struct ConstantsHydrationTests {

    /// THE TWO LISTS ARE ONE LIST.
    ///
    /// `approved` says which differences the read-back may see and not call a
    /// bug. `preservedOnHydrate` says which fields hydration must not
    /// overwrite. They are the same fact — a field the database cannot
    /// reproduce — and this is what stops the second from being forgotten when
    /// somebody adds to the first. §12.43.
    @Test("The approved list and the hydration-exclusion list agree")
    func theApprovedListIsTheExclusionList() {
        let approved = Set(AthleteRoundTrip.approved.map(\.field))
        #expect(approved == AthleteRoundTrip.preservedOnHydrate,
                "add an approved difference and you must decide what hydration does with it")
        #expect(approved.contains("version"))
    }

    /// THE ROLLBACK THIS EXISTS TO PREVENT. `constants.json` holds version 2;
    /// the schema has no column; `AthleteConstants()` defaults to 1; and
    /// `LoadStore.currentSignature` interpolates the counter.
    @Test("Hydration does not roll the version counter back")
    func hydrationPreservesTheVersion() {
        let s = ConstantsStore()
        let before = s.version

        // What the database would hand over: everything read, `version` absent
        // and therefore at the struct's default.
        let stored = AthleteConstants(hrMaxObserved: 181,
                                      hrMaxObservedOn: "2025-08-24",
                                      restByMonth: ["2026-08": 60])
        #expect(stored.version == 1, "the default the database read would carry")

        s.hydrate(from: stored)

        #expect(s.version == before, "the counter is the app's, not the database's")
        #expect(s.hrMaxObserved == 181, "everything else IS taken")
        #expect(s.c.restByMonth["2026-08"] == 60)
        #expect(s.servedFrom == .database)
    }

    /// NOT ONLY THE DEFAULT. A stored value that is not 1 is refused just the
    /// same — the rule is "the counter is the app's", not "ignore 1".
    ///
    /// Nothing here calls a setter: every mutator on this store saves, and
    /// `constants.json` in the test host's container is shared by the whole
    /// run. A test that wrote it would be changing another suite's input.
    @Test("A stored counter is refused whatever it holds")
    func aStoredCounterIsRefusedWhateverItHolds() {
        let s = ConstantsStore()
        let before = s.version
        s.hydrate(from: AthleteConstants(hrMaxObserved: 175, version: 99))
        #expect(s.version == before,
                "neither the default nor the stored 99 — the app's own")
    }
}

// MARK: - AthleteStore

@MainActor
@Suite("The athlete store takes zones and FTP, and says gear is still a file")
struct AthleteHydrationTests {

    private func zones() -> [AthleteStore.HRZone] {
        [.init(index: 1, min: 0, max: 115),
         .init(index: 2, min: 116, max: 139),
         .init(index: 3, min: 140, max: 149),
         .init(index: 4, min: 150, max: 160),
         .init(index: 5, min: 161, max: nil)]
    }

    @Test("Zones and FTP arrive")
    func zonesAndFTPArrive() {
        let s = AthleteStore()
        s.hydrate(zones: zones(), ftp: 270)
        #expect(s.hrZones.count == 5)
        #expect(s.ftp == 270)
        #expect(s.topZoneFloor == 161)
    }

    /// THE PROPERTY THE READ-BACK DEPENDS ON.
    ///
    /// `hydrate` applies `separate`, exactly as the file path does — the store
    /// normalises what it holds whatever the source. That is only safe if
    /// applying it to already-separated zones changes nothing; otherwise
    /// hydration would move the athlete read-back's answer off its current
    /// "5 zones, 0 differ" and the change would look like a data problem.
    @Test("Separating already-separated zones changes nothing")
    func separateIsIdempotent() {
        let once = AthleteStore.separate(zones())
        let twice = AthleteStore.separate(once)
        #expect(once == twice)
        #expect(once == zones(), "these zones are already in the stored form")
    }

    /// The half-hydrated state is NAMED, both sides of it. See the file header
    /// for why this is the assertion and not one about gear itself.
    @Test("The store says gear still comes from a file")
    func theSplitIsReadable() {
        let s = AthleteStore()
        #expect(s.servedFrom == .files)
        s.hydrate(zones: zones(), ftp: 270)

        guard case .partial(let fromDatabase, let fromFiles) = s.servedFrom else {
            Issue.record("B1 hydrates part of this store, so the source is partial")
            return
        }
        #expect(fromDatabase.contains("zones"))
        #expect(fromFiles.contains("gear"))
        #expect(s.servedFrom.line.contains("gear"),
                "and it reaches the paste, unconditionally")
    }
}

// MARK: - StoreSource

@Suite("Where a store's data came from")
struct StoreSourceTests {

    @Test("Every case says something different")
    func everyCaseReads() {
        #expect(StoreSource.files.line == "the app's own files")
        #expect(StoreSource.database.line == "the database")
        let split = StoreSource.partial(fromDatabase: "zones and FTP",
                                        fromFiles: "gear, until slice B5")
        #expect(split.line.contains("zones and FTP"))
        #expect(split.line.contains("gear"))
        #expect(split != .database, "a half-hydrated store is not a hydrated one")
        #expect(split != .files)
    }
}
