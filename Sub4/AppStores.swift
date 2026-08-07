//
//  AppStores.swift
//  Sub4
//
//  Everything the app holds, as one value — D6b step 1, patch 301.
//  ADR-0003 §12.45.
//
//  WHY THIS EXISTS, AND IT IS NOT TIDINESS
//  ---------------------------------------
//  `Sub4Import.run` takes twenty parameters and eighteen of them are defaulted.
//  `SemanticVerifier.attempt` takes fourteen, thirteen defaulted, and thirteen
//  of the expressions are the same ones. Both argument lists were assembled by
//  hand inside `DatabaseHealthView`, forty lines apart.
//
//  A defaulted parameter that is forgotten is not a compile error. It is a
//  table that quietly stops being imported, and nothing on any screen says so
//  — the read-back would report it as data missing from the database, which is
//  the shape §12.35.4 keeps naming.
//
//  D6b's whole job is to fire that import from somewhere that is not a screen.
//  That would have been the THIRD hand-written copy of the same list, in code
//  that runs unattended. So the list becomes a value first, and the forwarding
//  is written once where a test can hold it.
//
//  WHY NOT "SNAPSHOT"
//  ------------------
//  `LegacySnapshot` and `SnapshotManifest` already mean *a protected copy of
//  the input files, taken before anything decodes them* — contract item 3. A
//  third meaning for the word in the same subsystem would cost a reader more
//  than the name is worth.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  --------------------------------
//  It does not change `Sub4Import.run` or `SemanticVerifier.attempt`. Both keep
//  their granular signatures, so every existing test still calls them the way
//  it did. This is an overload and an assembly point, nothing else — a
//  mechanical change whose proof is that the three read-backs are unmoved.
//

import Foundation

/// Everything the database import and the verifier read from, gathered once.
///
/// EVERY FIELD DEFAULTS TO EMPTY, and the reconcile permission defaults to
/// refusing. A partially-built `AppStores` therefore imports less rather than
/// deleting more, which is the safe direction — the same argument
/// `Sub4Import.run`'s own `reconcile` default makes.
nonisolated struct AppStores: Sendable {

    var activities: [Activity] = []
    /// ALL gear, not just shoes — patch 267. The `gear` table holds anything an
    /// activity can name, and a bike that is not in it is 287 activities
    /// naming gear the database does not hold.
    var gear: [AthleteStore.Shoe] = []
    var notes: [NotesStore.Note] = []
    var proposals: [ProposalStore.Record] = []
    var matchDecisions: [MatchDecision] = []
    var syncState: SyncState?
    var workItems: [WorkItem] = []
    var rejections: [RejectionReceipt] = []
    var commutes: [CommuteDecision] = []
    var weather: [ActivityWeather] = []
    var constants: AthleteConstants?
    var ftpWatts: Int?
    var zones: [AthleteStore.HRZone] = []
    var plan: Plan?
    var streams: [ActivityStreams] = []
    var details: [ActivityDetail] = []

    /// PATCH 274'S GATE, CARRIED WITH THE THING IT IS ABOUT.
    ///
    /// It was computed in the view from a hand-written list of store names, and
    /// `canReconcile` fails CLOSED on any store that never reported — which
    /// means a name MISSING from that list makes reconciliation more likely to
    /// run, and reconciliation deletes rows. A forgotten name there is a delete
    /// hazard rather than a skip hazard, so the list now sits beside the fields
    /// it is about.
    ///
    /// Moved verbatim. Making the list DERIVE from the fields is a real
    /// improvement and a separate patch — mixing a permissions change into a
    /// mechanical extraction would make both harder to check.
    var reconcile: Reconciliation = .skipped("the caller did not ask")

    /// The stores whose read must be trustworthy before anything may be
    /// deleted on their behalf. See `reconcile`.
    static let reconcileRequires = ["notes.json", "proposals.json",
                                    "commutes.json", Matcher.decisionsKey]

    /// Read every store, now. `@MainActor` because every one of them is.
    @MainActor
    static func current() -> AppStores {
        var s = AppStores()
        s.activities = ActivityStore.shared.activities
        s.gear = AthleteStore.shared.allGear
        s.notes = Array(NotesStore.shared.notes.values)
        s.proposals = ProposalStore.shared.records
        s.matchDecisions = Array(Matcher.shared.decisions.values)
        s.syncState = ActivityStore.shared.syncState
        s.workItems = DetailStore.shared.workItems
        s.rejections = ActivityStore.shared.receipts
        s.commutes = Array(CommuteStore.shared.decisions.values)
        s.weather = Array(WeatherStore.shared.byActivity.values)
        s.constants = ConstantsStore.shared.c
        s.ftpWatts = AthleteStore.shared.ftp
        s.zones = AthleteStore.shared.hrZones
        s.plan = PlanStore.shared.plan
        s.streams = Array(DetailStore.shared.streams.values)
        s.details = Array(DetailStore.shared.details.values)
        s.reconcile = StoreReadJournal.shared.canReconcile(reconcileRequires)
            ? .run
            : .skipped("a store could not be read")
        return s
    }

    /// THE NUMBER A TEST HOLDS — see `AppStoresTests`.
    ///
    /// A field added here and not forwarded in `Sub4Import.run(into:stores:)`
    /// is a table that stops being imported, silently. Nothing else in the app
    /// would notice until a read-back reported the rows as missing data, and by
    /// then it reads as a database problem rather than as a forgotten line.
    ///
    /// Pinning the COUNT does not prove the forwarding. It makes adding a field
    /// a thing somebody has to acknowledge, which is the half that can be
    /// checked cheaply — the same trick §12.34 uses on a hand-written list.
    static let fieldCount = 17
}

// MARK: - The forwarding, written once

extension Sub4Import {

    /// The import, from a gathered `AppStores`.
    ///
    /// EVERY FIELD FORWARDED EXPLICITLY. This is the one place the mapping
    /// exists, and it is the place to look when a table stops being written.
    ///
    /// `trigger` IS REQUIRED, AND IT IS THE ONLY REQUIRED ONE — patch 311.
    ///
    /// Every production import in this app comes through this overload, and the
    /// granular signature below it defaults `trigger` to nil for the fifty test
    /// call sites that have no answer. Required here means the two call sites
    /// that DO have one cannot forget it — which is the same argument this
    /// file's header makes about defaulted parameters, applied to the parameter
    /// that says who caused the run.
    nonisolated static func run(into db: Sub4Database,
                                stores s: AppStores,
                                appVersion: String = "unknown",
                                snapshotID: String? = nil,
                                trigger: MigrationRunTrigger) throws -> Report {
        try run(into: db,
                activities: s.activities,
                shoes: s.gear,
                notes: s.notes,
                proposals: s.proposals,
                matchDecisions: s.matchDecisions,
                syncState: s.syncState,
                workItems: s.workItems,
                rejections: s.rejections,
                commutes: s.commutes,
                reconcile: s.reconcile,
                weather: s.weather,
                constants: s.constants,
                ftpWatts: s.ftpWatts,
                zones: s.zones,
                plan: s.plan,
                streams: s.streams,
                details: s.details,
                appVersion: appVersion,
                snapshotID: snapshotID,
                trigger: trigger)
    }
}

extension SemanticVerifier {

    /// The verifier reads a SUBSET, and that is not an oversight to fix here.
    ///
    /// It has no checks for the plan, the constants or the FTP, so passing them
    /// would be passing arguments nothing reads. Recorded rather than quietly
    /// dropped: if a check for one of those is added later, this is the line
    /// that has to grow with it.
    static func attempt(_ db: Sub4Database, stores s: AppStores) -> VerificationReport {
        attempt(db,
                activities: s.activities,
                shoes: s.gear,
                notes: s.notes,
                proposals: s.proposals,
                syncState: s.syncState,
                workItems: s.workItems,
                rejections: s.rejections,
                commutes: s.commutes,
                matchDecisions: s.matchDecisions,
                weather: s.weather,
                zones: s.zones,
                streams: s.streams,
                details: s.details)
    }
}
