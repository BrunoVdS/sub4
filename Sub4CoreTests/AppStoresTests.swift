//
//  AppStoresTests.swift
//  Sub4CoreTests
//
//  D6b step 1 — patch 301, ADR-0003 §12.45.
//
//  `theFieldCountIsPinned` is the one with teeth, and it is a test about a
//  number rather than about behaviour. `Sub4Import.run` has eighteen defaulted
//  parameters; a field added to `AppStores` and not forwarded compiles, runs,
//  and silently stops importing a table. Nothing on any screen would say so —
//  the read-back would report the rows as missing from the database, which
//  reads as a data problem rather than as a forgotten line.
//
//  Pinning the count does not prove the forwarding. It makes adding a field
//  something somebody has to acknowledge, which is the half that is cheap to
//  check. The forwarding itself is proved for three fields below and, on the
//  device, by the three read-backs being unmoved.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct AppStoresTests {

    private func ride(_ id: String = "19580875358") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-28T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func detail(_ id: String = "19580875358") -> ActivityDetail {
        ActivityDetail(activityId: id, calories: 812,
                       splits: [], bestEfforts: [],
                       laps: [.init(index: 1, distanceM: 5000,
                                    movingTime: 1200, averageHR: 138)],
                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    private func stream(_ id: String = "19580875358") -> ActivityStreams {
        ActivityStreams(activityId: id, distanceM: [0, 500, 1000],
                        heartRate: [120, 131, 145],
                        speed: nil, altitude: nil, grade: nil,
                        power: nil, latitude: nil, longitude: nil,
                        fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    // MARK: The shape

    /// THE ONE WITH TEETH. If this fails, a field was added — forward it in
    /// `Sub4Import.run(into:stores:)` and, if the verifier gained a check for
    /// it, in `SemanticVerifier.attempt(_:stores:)` too. Then bump the number.
    @Test("Every field of AppStores is accounted for")
    func theFieldCountIsPinned() {
        let fields = Mirror(reflecting: AppStores()).children.count
        #expect(fields == AppStores.fieldCount,
                "a field was added — forward it before bumping this")
    }

    /// EMPTY IMPORTS LESS; IT DOES NOT DELETE MORE. A half-built value must
    /// fail in the direction that leaves rows alone, because the other
    /// direction is `reconcile` removing them.
    @Test("A default AppStores refuses to reconcile")
    func theDefaultIsSafe() {
        let s = AppStores()
        // PATCH 414 — no family, not "not running". `.run([])` and
        // `.skipped` are different facts and neither deletes anything.
        #expect(ReconcileFamily.allCases.allSatisfy { !s.reconcile.permits($0) })
        #expect(s.activities.isEmpty)
        #expect(s.details.isEmpty)
        #expect(s.streams.isEmpty)
        #expect(s.syncState == nil)
        #expect(s.plan == nil)
    }

    // MARK: The forwarding

    /// Three of seventeen, and said plainly rather than dressed up: this proves
    /// the overload reaches the granular one and that these three fields land.
    /// The count above is what refuses silent growth; the read-backs on the
    /// device are what prove the rest.
    @Test("Activities, details and traces reach the database through the overload")
    func theOverloadImports() throws {
        let db = try Sub4Database.inMemory()
        var s = AppStores()
        s.activities = [ride()]
        s.details = [detail()]
        s.streams = [stream()]

        let r = try Sub4Import.run(into: db, stores: s, appVersion: "301-test",
                                   trigger: .manual, cause: "a test")
        #expect(r.activitiesSeen == 1)
        #expect(r.activitiesInserted == 1)
        #expect(r.refusals.isEmpty)

        // Read them back with D6a's own readers, which is the check that
        // matters: the rows are there and reconstitute.
        #expect(ActivityRepository.all(db).activities?.count == 1)
        #expect(ActivityDetailRepository.all(db).details?.count == 1)
        #expect(RecordingRepository.all(db).recordings?.count == 1)
    }

    /// `reconcile` gets its own test because it is the field that DELETES.
    /// A forwarding that dropped it would default to skipping, which is safe;
    /// a forwarding that inverted it would not, and only one of those is
    /// visible without looking.
    @Test("The reconcile permission is forwarded, not defaulted")
    func reconcileIsForwarded() throws {
        let db = try Sub4Database.inMemory()

        var asked = AppStores()
        asked.activities = [ride()]
        asked.reconcile = .run(Set(ReconcileFamily.allCases))
        #expect(try Sub4Import.run(into: db, stores: asked, trigger: .manual, cause: "a test")
                    .reconciled == .run(Set(ReconcileFamily.allCases)))

        let other = try Sub4Database.inMemory()
        var declined = AppStores()
        declined.activities = [ride()]
        declined.reconcile = .skipped("a store could not be read")
        #expect(try Sub4Import.run(into: other, stores: declined, trigger: .manual, cause: "a test")
                    .reconciled == .skipped("a store could not be read"))
    }

    /// The verifier reads a subset on purpose — it has no checks for the plan,
    /// the constants or the FTP. Pinned so that adding one of those checks
    /// without widening the overload is a failure rather than a silent gap.
    @Test("The verifier overload reaches the verifier")
    func theVerifierOverloadWorks() throws {
        let db = try Sub4Database.inMemory()
        var s = AppStores()
        s.activities = [ride()]
        _ = try Sub4Import.run(into: db, stores: s, trigger: .manual, cause: "a test")

        let report = SemanticVerifier.attempt(db, stores: s)
        #expect(!report.checks.isEmpty, "it looked at something")
    }

    /// PATCH 311. The overload is the ONE door every production import comes
    /// through, and `trigger` is required there for that reason — the two call
    /// sites that know who caused the run cannot forget to say. This pins that
    /// it lands, so a required parameter that went nowhere would be visible.
    @Test("The trigger handed to the overload reaches the ledger row")
    func theTriggerIsForwarded() throws {
        let db = try Sub4Database.inMemory()
        var s = AppStores()
        s.activities = [ride()]
        _ = try Sub4Import.run(into: db, stores: s, appVersion: "311-test",
                               trigger: .backgroundRefresh, cause: "a test")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.triggeredBy == .backgroundRefresh)
    }

    // MARK: The gate's own list

    /// The stores whose read must be trustworthy before anything is deleted on
    /// their behalf. `canReconcile` fails CLOSED, so a name MISSING from this
    /// list makes reconciliation more likely to run — a delete hazard, not a
    /// skip hazard, which is why the list is pinned.
    ///
    /// `moves.json` JOINED AT 363, in the same patch as `pruneMoves`. That
    /// pairing is the rule: a store gains a prune and the gate gains its name
    /// together, or there is a window in which rows are deleted on the strength
    /// of a read nobody checked.
    ///
    /// **PER FAMILY SINCE 414.** The list was five names and one verdict, so a
    /// missing name made reconciliation more likely to run AND a present one
    /// made four unrelated families refuse whenever the fifth store was
    /// unreadable. `ReconcileFamily.source` pairs each family with the one read
    /// that speaks for it, and this pins every pair.
    @Test("Every family names the one store that speaks for it")
    func theGateListIsPinned() {
        #expect(ReconcileFamily.notes.source == "notes.json")
        #expect(ReconcileFamily.reviews.source == "proposals.json")
        #expect(ReconcileFamily.commutes.source == "commutes.json")
        #expect(ReconcileFamily.moves.source == "moves.json")
        #expect(ReconcileFamily.matchDecisions.source == Matcher.decisionsKey)
        // A FAMILY ADDED LATER CANNOT INHERIT SOMEBODY ELSE'S SOURCE BY BEING
        // FORGOTTEN. Five distinct names for five families — if a sixth arrives
        // sharing one, this says so.
        #expect(Set(ReconcileFamily.allCases.map(\.source)).count
                == ReconcileFamily.allCases.count)
    }
}
