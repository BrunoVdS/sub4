//
//  AthleteRepositoryTests.swift
//  Sub4CoreTests
//
//  The athlete, read back out — D6c slice 6a, patch 317, ADR-0003 §12.61.
//
//  WHAT THESE ASSERT, AND WHY IT IS NOT "IT ROUND-TRIPS"
//  ----------------------------------------------------
//  Three scalars, a month-keyed series and five zone boundaries. It is also the
//  denominator of every training-load figure the app has ever produced, and it
//  is the one table group D6a never read back — `SemanticVerifier` counts
//  `hr_zone` rows and nothing else.
//
//  So the round trip is one test and the other fifteen are about the ways the
//  comparison could pass while being blind:
//
//    `noFieldIsSilentlySkipped`      — a field added to AthleteConstants and
//                                      not to `compare`
//    `aMonthOnlyOnOneSideIsCaught`   — comparing shared months only
//    `nothingComparedIsNotAPass`     — zero fields agreeing with zero fields
//    `versionIsApprovedNotIgnored`   — the approved list carrying an entry
//                                      nobody can justify
//
//  A comparison with no way to fail is a comparison that says nothing, and
//  every negative control below exists to give one of these a way to fail.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct AthleteRepositoryTests {

    // MARK: Fixtures

    private func activity(_ id: String,
                          name: String = "Hill repeats",
                          startLocal: String = "2026-07-28T07:24:06",
                          maxHR: Double? = nil) -> Activity {
        Activity(id: id, name: name, sportType: "Run",
                 startLocal: startLocal, distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: maxHR, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T05:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// Strava's five, with the top one open-ended and the bottom one starting
    /// at zero — both of which have already cost this project a patch.
    private var zones: [AthleteStore.HRZone] {
        [.init(index: 1, min: 0, max: 115),
         .init(index: 2, min: 116, max: 139),
         .init(index: 3, min: 140, max: 155),
         .init(index: 4, min: 156, max: 172),
         .init(index: 5, min: 173, max: nil)]
    }

    /// A fully populated athlete: every stored field non-default, so a reader
    /// that drops one cannot pass by accident.
    private func constants() -> AthleteConstants {
        var c = AthleteConstants()
        c.hrMaxOverride = 191
        c.hrMaxObserved = 189
        c.hrMaxObservedOn = "2026-07-28"
        c.hrMaxObservedName = "Hill repeats"
        c.restOverride = 44
        c.sexCoefficient = 1.67
        c.restByMonth = ["2025-08": 47, "2026-06": 44, "2026-07": 45]
        // Not stored, and that is the approved list's single entry. Set to
        // something conspicuous so a reader that invented a column would show.
        c.version = 7
        return c
    }

    private func seeded(_ db: Sub4Database) throws {
        _ = try Sub4Import.run(into: db,
                               activities: [activity("19580875358", maxHR: 189.4)],
                               shoes: [],
                               constants: constants(),
                               ftpWatts: 244,
                               zones: zones)
    }

    // MARK: Nothing there is not the same as could not look

    /// §12.15, for the ninth time in this project. A fresh install has no
    /// profile row and that is an ANSWER. A reader that returned an empty
    /// `AthleteConstants()` would hand the load engine a default HR max of nil
    /// and a `sexCoefficient` of 1.92 with no way to know they were invented.
    @Test("An empty database is missing, not failed and not a blank athlete")
    func emptyIsMissingNotAnEmptyAthlete() throws {
        let db = try Sub4Database.inMemory()
        let load = AthleteRepository.load(db)

        #expect(load.isTrustworthy, "a fresh database is a legitimate answer")
        #expect(load.constants == nil,
                "a caller must not be able to reach a default AthleteConstants")
        #expect(load.zones == nil, "nor an empty zone set")
        #expect(load.ftp == nil)
        #expect(load.line == "No athlete profile in the database yet.")
    }

    @Test("An untrustworthy read hands back nothing, not defaults")
    func anUntrustworthyReadIsNotEmpty() {
        for load: AthleteLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.constants == nil)
            #expect(load.zones == nil,
                    "a caller must not reach [] without deciding what this means")
        }
    }

    // MARK: The round trip

    /// THE ONE THAT MATTERS. Field by field rather than one `==`, so a failure
    /// names the field.
    @Test("The profile survives the round trip, field by field")
    func theProfileRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)

        let load = AthleteRepository.load(db)
        let back = try #require(load.constants)

        #expect(back.hrMaxOverride == 191)
        #expect(back.hrMaxObserved == 189)
        #expect(back.hrMaxObservedOn == "2026-07-28",
                "hrMaxObservedOn is stored as hrMaxObservedOnDayKey")
        #expect(back.restOverride == 44)
        #expect(back.sexCoefficient == 1.67,
                "the exponent that rescales thirteen months came back wrong")
        #expect(load.ftp == 244, "ftpWatts comes from AthleteStore, not constants")
        #expect(back.hrMax == 191, "the override still beats the observed figure")
    }

    @Test("The resting series comes back whole and keyed by month")
    func theRestingSeriesRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        let back = try #require(AthleteRepository.load(db).constants)

        #expect(back.restByMonth.count == 3)
        #expect(back.restByMonth["2025-08"] == 47)
        #expect(back.restByMonth["2026-06"] == 44)
        #expect(back.restByMonth["2026-07"] == 45)
    }

    /// Both ends of `hr_zone` have cost this project a patch: the NOT NULL that
    /// refused the open top zone (236) and the `minBpm > 0` that refused the
    /// bottom one. A reader that mapped a null ceiling to 0 or dropped Z1 would
    /// undo both silently.
    @Test("The zones come back with the open top and the zero floor intact")
    func theZonesRoundTrip() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        let back = try #require(AthleteRepository.load(db).zones)

        #expect(back.map(\.index) == [1, 2, 3, 4, 5], "ordinals are 1-based")
        #expect(back.first?.min == 0, "the bottom zone starts at zero")
        #expect(back.last?.max == nil, "the top zone was given a ceiling")
        #expect(back.last?.min == 173)
    }

    /// The store keeps a NAME and the database keeps a FOREIGN KEY. The name is
    /// reconstructed by joining back to `activity` rather than declared an
    /// approved difference — a list that starts at one entry grows less easily
    /// than one that starts at two.
    @Test("The observing session's name is recovered by the join")
    func theObservedNameIsRecoveredByJoin() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)

        // The column really does hold a key, not the name.
        let key = try db.queue.read { d in
            try String.fetchOne(d, sql: """
                SELECT hrMaxObservedActivityID FROM athlete_profile
                """)
        }
        #expect(key != nil, "the importer could not resolve the provenance")
        #expect(key != "Hill repeats")

        let back = try #require(AthleteRepository.load(db).constants)
        #expect(back.hrMaxObservedName == "Hill repeats",
                "the join did not give the name back")
    }

    /// When the importer could not resolve which activity produced the maximum
    /// the key is null and the name is genuinely gone. That is a REAL loss and
    /// it is reported as a difference rather than swallowed by the join.
    @Test("An unresolved provenance loses the name, and the comparison says so")
    func anUnresolvedProvenanceIsADifference() throws {
        let db = try Sub4Database.inMemory()
        var c = constants()
        c.hrMaxObservedName = "Intervals"
        // Two candidates on the same day with the same maximum and the same
        // name — the importer refuses to guess and counts it.
        let report = try Sub4Import.run(
            into: db,
            activities: [activity("1", name: "Intervals", maxHR: 189),
                         activity("2", name: "Intervals", maxHR: 189)],
            shoes: [], constants: c, ftpWatts: 244, zones: zones)
        #expect(report.profileProvenanceUnresolved == 1)

        let load = AthleteRepository.load(db)
        #expect(load.constants?.hrMaxObservedName == nil)

        let r = AthleteRoundTrip.compare(store: c, storeFTP: 244,
                                         storeZones: zones, database: load)
        #expect(r.differences == ["hrMaxObservedName"],
                "an unresolved provenance must not be reported as agreement")
        #expect(!r.isHealthy)
    }

    // MARK: The comparison, on the real round trip

    /// The whole point: the store this app is running on, against what the
    /// database gives back, through the real importer and the real reader.
    @Test("The store and the database agree on every compared field")
    func theRealRoundTripAgrees() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))

        #expect(r.fieldsCompared == 7, "compared \(r.fieldsCompared) scalar fields")
        #expect(r.monthsCompared == 3)
        #expect(r.zonesCompared == 5)
        #expect(r.totalCompared == 15)
        #expect(r.differences.isEmpty, "differed on \(r.differences)")
        #expect(r.monthsDiffering.isEmpty)
        #expect(r.zonesDiffering.isEmpty)
        #expect(r.lookedAtSomething)
        #expect(r.isHealthy)
        #expect(r.appHRMax == 191)
        #expect(r.databaseHRMax == 191)
        #expect(r.appFTP == 244)
        #expect(r.databaseFTP == 244)
    }

    /// Groundwork §2.1 case 2. Zero fields agreeing with zero fields is a
    /// perfect result that describes nothing, and `.missing` reaching this
    /// comparison is exactly how that would happen.
    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() {
        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones, database: .missing)
        #expect(r.totalCompared == 0)
        #expect(r.unexplained == 0, "there is genuinely nothing to disagree about")
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy, "zero of zero must not read as healthy")
        #expect(r.summary == "nothing compared")
    }

    // MARK: Negative controls — the ways this could be blind

    /// AN EXPONENT, NOT A PREFERENCE. 1.92 against 1.67 is a difference of one
    /// stored double and it rescales every TRIMP the app has ever computed, in
    /// a direction nobody would question.
    @Test("A changed sex coefficient is caught and named")
    func aChangedSexCoefficientIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE athlete_profile SET sexCoefficient = 1.92")
        }

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.differences == ["sexCoefficient"])
        #expect(r.fieldsCompared == 7, "the denominator must survive a difference")
        #expect(!r.isHealthy)
    }

    @Test("A changed resting month is caught and the month is named")
    func aChangedRestingMonthIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE resting_month SET bpm = 52 WHERE month = ?",
                          arguments: ["2026-06"])
        }

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.differences.isEmpty, "a month is not a profile field")
        #expect(r.monthsDiffering == ["2026-06"])
        #expect(r.monthsCompared == 3)
        #expect(r.unexplained == 1)
    }

    /// THE COMPARISON THAT WOULD HAVE BEEN BLIND. Walking the shared months
    /// only would agree perfectly about a month one side has never heard of —
    /// and a month missing from the database is every session in it scored
    /// against nothing.
    @Test("A month on one side only is compared, not skipped")
    func aMonthOnlyOnOneSideIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM resting_month WHERE month = ?",
                          arguments: ["2025-08"])
        }

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.monthsCompared == 3, "the union, not the intersection")
        #expect(r.monthsDiffering == ["2025-08"])
    }

    /// A zone set with a hole is not a smaller problem than no zone set —
    /// `zone(forHR:)` answers confidently from it. Matched by ordinal so a
    /// missing middle zone cannot shift the ones after it into agreement.
    @Test("A moved zone boundary is caught, by ordinal")
    func aChangedZoneBoundIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE hr_zone SET minBpm = 145 WHERE ordinal = 3")
        }

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.zonesDiffering == [3])
        #expect(r.zonesCompared == 5)
    }

    @Test("A zone the database no longer holds is still compared")
    func aMissingZoneIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM hr_zone WHERE ordinal = 5")
        }

        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.zonesCompared == 5, "the union, not the database's four")
        #expect(r.zonesDiffering == [5])
    }

    @Test("A different FTP is caught")
    func aChangedFTPIsCaught() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 260,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(r.differences == ["ftpWatts"])
        #expect(r.appFTP == 260)
        #expect(r.databaseFTP == 244)
    }

    // MARK: The approved list

    /// A DECISION RECORD, NOT A SUPPRESSION LIST. `version` is a local
    /// cache-invalidation counter with no column and no sensible one; the
    /// entry carries the reason and the patch, and this asserts both are there
    /// rather than just the field name. The moment an entry appears without a
    /// reason attached is the moment the list stops being a gate.
    @Test("version is approved, with a reason and a patch, and never differs")
    func versionIsApprovedNotIgnored() throws {
        let entry = try #require(AthleteRoundTrip.approved.first { $0.field == "version" })
        #expect(entry.patch == "317")
        #expect(entry.reason.count > 40, "an approved difference needs an argument")
        #expect(AthleteRoundTrip.approved.count == 1,
                "the approved list grew — every entry needs its own argument")

        let db = try Sub4Database.inMemory()
        try seeded(db)
        // The store's counter is 7 and the database has no column for it.
        let r = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                         storeZones: zones,
                                         database: AthleteRepository.load(db))
        #expect(!r.differences.contains("version"))
        #expect(r.isHealthy, "the approved difference was reported as a fault")
    }

    /// THE GUARD THAT KEEPS THE REST HONEST. Adding a property to
    /// `AthleteConstants` and not to `compare` makes every test above quietly
    /// weaker without failing any of them. This is the one that fails.
    @Test("Every stored field of AthleteConstants is compared or approved")
    func noFieldIsSilentlySkipped() {
        let fields = Set(Mirror(reflecting: AthleteConstants())
            .children.compactMap(\.label))
        // Six compared as scalars, `restByMonth` compared month by month, and
        // `version` in the approved list. Nothing else.
        #expect(fields == ["hrMaxOverride", "hrMaxObserved", "hrMaxObservedOn",
                           "hrMaxObservedName", "restByMonth", "restOverride",
                           "sexCoefficient", "version"],
                "AthleteConstants changed shape: \(fields.sorted())")
    }

    // MARK: Scope and the paste

    @Test("Another account's profile is not this account's")
    func accountScoped() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        let other = AthleteRepository.load(db, accountID: "someone-else")
        #expect(other.isTrustworthy)
        if case .missing = other { } else {
            Issue.record("another account's read returned a profile")
        }
    }

    /// UNCONDITIONAL, every line, including the zeros — 266c's rule, and
    /// §12.54.2's: a row that vanishes at zero cannot be told from a row nobody
    /// wired in.
    @Test("Every diagnostic line is present when nothing differs")
    func theDiagnosticLinesAreUnconditional() throws {
        let db = try Sub4Database.inMemory()
        try seeded(db)
        let lines = AthleteRoundTrip.compare(store: constants(), storeFTP: 244,
                                             storeZones: zones,
                                             database: AthleteRepository.load(db))
            .diagnosticLines
        let text = lines.joined(separator: "\n")

        for expected in ["Athlete read-back: 15 compared",
                         "profile fields: 7",
                         "resting months: 3",
                         "zones: 5",
                         "fields that differ: 0",
                         "months that differ: 0",
                         "zones that differ: 0",
                         "approved differences: 1 (version)",
                         "HR max: 191 vs 191",
                         "FTP: 244 vs 244",
                         "unexplained differences: 0"] {
            #expect(text.contains(expected), "the paste is missing: \(expected)")
        }
    }
}
