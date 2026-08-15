//
//  ImporterSeedTests.swift
//  Sub4CoreTests
//
//  D7 slice B1, the write direction — patch 347, ADR-0003 §12.93.
//
//  THE LOOP 346 CLOSED, AND WHY IT LOOKED HARMLESS
//  -----------------------------------------------
//  `AppStores.current()` reads the singletons. That was the whole point of it:
//  one place that gathers what the app holds so nothing has to be threaded
//  through twenty parameters (§12.45). Every field it reads was, until 346, a
//  store fed from a file.
//
//  346 fed four of them from the database. So the importer began taking four
//  of its seventeen inputs out of the thing it writes into, and for the plan
//  that has a consequence nothing on any screen would show:
//
//    · a revised `plan.json` can no longer reach the database, because the
//      store never reads the bundle again and the importer reads the store
//    · the plan the importer hashes has been through SQL, which returns weeks
//      and sessions `ORDER BY uid` rather than in the plan's own order — so it
//      hashed differently and a second `plan_version` was written on the first
//      import after the flip
//    · `planSourceLabel` still said "bundled", of a plan that came from rows
//
//  All three are one fix: the importer takes the plan from the BUNDLE, which
//  is the bundle's documented role. §12.91.3 forbids reaching for the bundle
//  when a database READ fails; it has never forbidden seeding a write from it,
//  and `PlanStore.decodeBundle`'s own comment calls it the seed.
//
//  WHAT THESE TESTS CAN AND CANNOT DO, SAID PLAINLY
//  ------------------------------------------------
//  After the fix, `AppStores.current().plan` and `PlanStore.decodeBundle()` are
//  the same call, so comparing them pins a CALL SITE rather than proving a
//  behaviour — the same category as `AppStores.fieldCount`, and worth about as
//  much. It fails today, before the fix, which is the only sense in which a
//  pinning test earns its place.
//
//  The enforcement that has teeth is in the apply script: `AppStores.swift` may
//  not name `PlanStore.shared`, and `decodeBundle()` may be called from exactly
//  three places. A fourth is a decision somebody has to make on purpose.
//

import Testing
import Foundation
@testable import Sub4

@Suite("What the importer is handed")
struct ImporterSeedTests {

    /// THE HASH IS THE THING THAT DECIDES, so the hash is what this compares.
    ///
    /// `importPlan` writes a new `plan_version` when no stored version carries
    /// the hash of the plan it is given. Handing it the served plan instead of
    /// the seed is therefore not a cosmetic difference: it is the difference
    /// between finding version 1 and writing version 2.
    @MainActor
    @Test("The importer is handed the bundled plan")
    func theImporterIsHandedTheBundle() throws {
        let stores = AppStores.current()
        let handed = try #require(stores.plan, "the importer must be given a plan")

        #expect(Sub4Import.contentHash(of: handed)
                == Sub4Import.contentHash(of: PlanStore.decodeBundle().plan),
                "the seed, not whatever the app is currently serving")
    }

    /// AND THE LABEL IS TRUE AGAIN.
    ///
    /// `Sub4Import.run` stamps every version it writes `sourceLabel: "bundled"`
    /// by default. Between 346 and this patch that was false of every version
    /// written — the plan came out of SQL and was recorded as having come from
    /// the app bundle. A provenance field that lies is worse than one that is
    /// missing, because it is the field somebody checks when two versions
    /// appear and they want to know where the second came from.
    @MainActor
    @Test("A version written from this plan is honestly labelled")
    func theSourceLabelIsTrue() throws {
        let stores = AppStores.current()
        let handed = try #require(stores.plan)
        let bundle = PlanStore.decodeBundle()

        #expect(bundle.error == nil, "the bundled plan must decode")
        #expect(handed.sessions.count == bundle.plan.sessions.count)
        #expect(handed.weeks.count == bundle.plan.weeks.count)
    }

    /// THE ONE THAT IS NOT A TAUTOLOGY, and it only says something when the
    /// test host's database differs from the bundle.
    ///
    /// In the test host `PlanStore.shared` IS hydrated — that is what 346a
    /// discovered, on a stored plan holding 260 sessions where the bundle holds
    /// 261. When that is the case this compares two genuinely different plans
    /// and would have caught the defect directly. When the two coincide it
    /// says nothing, and that is stated rather than dressed up. §12.69.
    @MainActor
    @Test("A hydrated singleton does not reach the importer")
    func aHydratedSingletonDoesNotReachTheImporter() async throws {
        await Sub4Launch.shared.begin()

        guard PlanStore.shared.servedFrom == .database else {
            // Nothing is being served from rows in this host, so the two
            // plans are the same object and there is nothing to distinguish.
            return
        }
        let served = Sub4Import.contentHash(of: PlanStore.shared.plan)
        let bundled = Sub4Import.contentHash(of: PlanStore.decodeBundle().plan)
        guard served != bundled else {
            // Hydrated, and identical to the bundle — the steady state after
            // this patch, and a state in which this test cannot discriminate.
            return
        }

        let handed = try #require(AppStores.current().plan)
        #expect(Sub4Import.contentHash(of: handed) == bundled,
                "the store is serving a different plan and the importer must not take it")
    }

    /// The write direction's inventory. Eighteen fields since 363, when the
    /// moved sessions joined it; the plan is still one of them, and what 347
    /// moved is where that one field is read FROM rather than whether it is
    /// forwarded.
    @Test("The field count is what the forwarding covers")
    func theFieldCountDidNotMove() {
        #expect(AppStores.fieldCount == 18)
    }
}
