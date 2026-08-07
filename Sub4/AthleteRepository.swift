//
//  AthleteRepository.swift
//  Sub4
//
//  The athlete, read back out — D6c slice 6a, patch 317, ADR-0003 §12.61.
//
//  THE ONE TABLE GROUP D6a NEVER READ BACK
//  ---------------------------------------
//  289 through 294 built readers for activities, details and recordings and
//  compared every field of each. `athlete_profile`, `resting_month` and
//  `hr_zone` got a row count from `SemanticVerifier` and nothing else — so the
//  constants that scale **every training load this app has ever computed** were
//  the least checked thing in the database.
//
//  `sexCoefficient` is an exponent. `hrMax` and the month's resting rate are
//  the two ends of the fraction it is applied to. A single wrong figure there
//  does not corrupt one row; it rescales thirteen months of history, quietly,
//  in a direction nobody would question.
//
//  WHAT IT IS FOR, BEYOND ITSELF
//  ----------------------------
//  §12.59 holds constants, zones, FTP, sRPE and Apple Health from the app on
//  both sides of the load comparison, and says so on screen. Three of those
//  five are now **verified** rather than assumed — the read-back proves the
//  database's copy is the same one, so slice 3's twin can keep taking them from
//  the app and a difference in the fitness rows still has exactly one cause.
//
//  That is why this is a READ-BACK and not a second input to the twin. Swapping
//  the twin's constants would make a fitness difference mean *either* the trace
//  *or* the constants, and the screen could not say which. Verifying them
//  separately keeps the single cause and closes the same gap.
//
//  TWO FIELDS DO NOT ROUND-TRIP, AND THEY FAIL DIFFERENTLY
//  ------------------------------------------------------
//  **`version`** has no column, and should not have one. It is a local
//  cache-invalidation counter — bumped when HR max changes, read by
//  `LoadStore`'s input fingerprint — so it describes the app's STATE rather
//  than the athlete. It is the first and only entry in §5's approved list, and
//  the reader sets it to the value the store holds so it can never masquerade
//  as a difference.
//
//  **`hrMaxObservedName`** has no column either and is RECOVERED. The importer
//  resolves the observing activity to a canonical id and stores that as a
//  foreign key, so `LEFT JOIN activity` gives the name back. When the importer
//  could not resolve it uniquely — the report counts that as
//  `profileProvenanceUnresolved` — the key is null and the name is genuinely
//  gone, which is a real difference and is reported as one.
//
//  A JOIN RATHER THAN AN APPROVED ENTRY, deliberately. *"The name is
//  reconstructed and checked"* is a stronger sentence than *"the name is
//  expected to differ"*, and a list that starts at one entry grows less easily
//  than one that starts at two.
//
//  IT DISTINGUISHES "NO PROFILE" FROM "COULD NOT LOOK"
//  --------------------------------------------------
//  A fresh database has no `athlete_profile` row, and that is a legitimate
//  answer rather than a failure — §12.15, for the ninth time. `.missing` says
//  so; `.failed` says the read threw.
//
//  IT COST TWO `nonisolated` KEYWORDS ELSEWHERE, AND BOTH ARE REAL
//  --------------------------------------------------------------
//  This reader runs inside a database transaction, off the main actor, and the
//  two types it works with are main-actor isolated by the module default:
//
//    · `AthleteConstants.hrMax` — a COMPUTED property, so SE-0434's rule that
//      Sendable STORED properties of an isolated value type are implicitly
//      nonisolated does not reach it. Marked `nonisolated` rather than
//      inlining `hrMaxOverride ?? hrMaxObserved` here, which would be §12.43's
//      defect: one rule, two implementations, nothing keeping them in step.
//    · `AthleteStore.HRZone` — nested in the store's `@Observable final class`,
//      so it inherits the main actor from it, and this reader CONSTRUCTS one
//      per row. Marked `nonisolated` rather than mirrored the way
//      `AthleteFile.Cache` was at 259: a mirror is right for the shape of a
//      file with a single writer, and wrong for a three-field value both sides
//      of a comparison have to hold.
//
//  Fourth and fifth times this project has paid this particular tax — 207,
//  219, 228 — and the first two were warnings nobody had to act on yet.
//

import Foundation
import GRDB

/// What a read of the athlete tables produced.
///
/// NOT `Equatable`, for 289a's reason: `AthleteConstants`' synthesised
/// conformance is MainActor-isolated in this target, so a `nonisolated` type
/// carrying one cannot use it. Nothing needs to compare two loads.
nonisolated enum AthleteLoad: Sendable {
    case loaded(constants: AthleteConstants, ftp: Int?, zones: [AthleteStore.HRZone])
    /// No profile row. A fresh database, not a fault.
    case missing
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        switch self {
        case .loaded, .missing: true
        case .unavailable, .failed: false
        }
    }

    var constants: AthleteConstants? {
        if case .loaded(let c, _, _) = self { return c }
        return nil
    }

    var ftp: Int? {
        if case .loaded(_, let f, _) = self { return f }
        return nil
    }

    /// Deliberately nil rather than `[]` when nothing was read, so a caller
    /// cannot reach for the happy path without deciding what an untrustworthy
    /// read means.
    var zones: [AthleteStore.HRZone]? {
        if case .loaded(_, _, let z) = self { return z }
        return nil
    }

    var line: String {
        switch self {
        case .loaded(let c, let ftp, let z):
            "HR max \(c.hrMax.map(String.init) ?? "—"), "
            + "\(c.restByMonth.count) resting months, \(z.count) zones, "
            + "FTP \(ftp.map(String.init) ?? "—")"
        case .missing:     "No athlete profile in the database yet."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

// MARK: - The comparison

/// The store against the database, field by field — the pattern
/// `ActivityRoundTrip` established at 290.
///
/// IT NAMES FIELDS, NOT A COUNT. "3 differences" sends somebody through a
/// profile; "3 differences, all in restByMonth" is a one-line answer. §12.39.
nonisolated enum AthleteRoundTrip {

    /// GROUNDWORK §5's LIST, AND THIS IS THE FIRST SLICE WITH AN ENTRY IN IT.
    ///
    /// A DECISION RECORD, NOT A SUPPRESSION LIST. Every entry carries the
    /// reason and the patch that made it. An entry nobody can justify is a bug
    /// that has been given a hiding place, and the moment this list grows
    /// without a reason attached is the moment it stops being a gate.
    struct ApprovedDifference: Sendable {
        let field: String
        let reason: String
        let patch: String
    }

    static let approved: [ApprovedDifference] = [
        ApprovedDifference(
            field: "version",
            reason: "a local cache-invalidation counter with no column. Bumped "
                  + "when HR max changes and read by LoadStore's input "
                  + "fingerprint, so it describes the app's state rather than "
                  + "the athlete. There is no sensible column for it.",
            patch: "317")
    ]

    struct Report: Sendable {

        // Denominators. Without them "no differences" and "nothing was
        // examined" read identically — groundwork §2.1 case 2.

        /// Scalar fields on the profile.
        var fieldsCompared = 0
        /// Months present on either side.
        var monthsCompared = 0
        /// Zones present on either side.
        var zonesCompared = 0

        var differences: [String] = []
        /// Months the two sides disagree about, named.
        var monthsDiffering: [String] = []
        var zonesDiffering: [Int] = []

        /// What the app holds and what the database gave back, for the two
        /// figures that scale everything.
        var appHRMax: Int?
        var databaseHRMax: Int?
        var appFTP: Int?
        var databaseFTP: Int?

        var totalCompared: Int { fieldsCompared + monthsCompared + zonesCompared }

        var unexplained: Int {
            differences.count + monthsDiffering.count + zonesDiffering.count
        }

        /// Zero fields compared to zero fields agrees perfectly.
        var lookedAtSomething: Bool { totalCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        /// BOTH SIDES, NOT A VERDICT. These two figures are the ones a reader
        /// can hold against the Settings screen without pressing anything
        /// else, and "191 vs 191" is evidence in a way that "agrees" is not.
        /// An em dash rather than a zero for a figure nobody has set — §12.15's
        /// rule one field down.
        var hrMaxLine: String {
            "\(appHRMax.map(String.init) ?? "—") vs "
            + "\(databaseHRMax.map(String.init) ?? "—")"
        }

        var ftpLine: String {
            "\(appFTP.map(String.init) ?? "—") vs "
            + "\(databaseFTP.map(String.init) ?? "—")"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE. Field names, month keys and counts. The only figures
        /// are the heart-rate maximum and the FTP, which describe a body's
        /// capacity rather than anything the athlete did or where.
        var diagnosticLines: [String] {
            var lines = [
                "Athlete read-back: \(totalCompared) compared",
                "  profile fields: \(fieldsCompared)",
                "  resting months: \(monthsCompared)",
                "  zones: \(zonesCompared)",
                "  fields that differ: \(differences.count)",
                "  months that differ: \(monthsDiffering.count)",
                "  zones that differ: \(zonesDiffering.count)",
                "  approved differences: \(approved.count) "
                + "(\(approved.map(\.field).joined(separator: ", ")))",
                "  HR max: \(hrMaxLine)",
                "  FTP: \(ftpLine)",
                "  unexplained differences: \(unexplained)"]
            for d in differences { lines.append("    \(d)") }
            for m in monthsDiffering.prefix(6) { lines.append("    restByMonth[\(m)]") }
            if monthsDiffering.count > 6 {
                lines.append("    + \(monthsDiffering.count - 6) more months")
            }
            for z in zonesDiffering { lines.append("    zone \(z)") }
            return lines
        }
    }

    /// EVERY STORED FIELD, NAMED. Adding one to `AthleteConstants` and not to
    /// this list makes the comparison quietly weaker, which is why the names
    /// are spelled out rather than derived — there is no reflection here that
    /// would not also silently skip something.
    ///
    /// `version` is not in it, and that is the approved list's single entry
    /// rather than an omission. See `approved`.
    static func compare(store: AthleteConstants,
                        storeFTP: Int?,
                        storeZones: [AthleteStore.HRZone],
                        database: AthleteLoad) -> Report {

        var r = Report()
        r.appHRMax = store.hrMax
        r.appFTP = storeFTP

        guard case .loaded(let d, let ftp, let zones) = database else {
            // Nothing to compare against. The denominators stay zero and
            // `lookedAtSomething` refuses to call that a pass.
            return r
        }
        r.databaseHRMax = d.hrMax
        r.databaseFTP = ftp

        func check(_ name: String, _ same: Bool) {
            r.fieldsCompared += 1
            if !same { r.differences.append(name) }
        }

        check("hrMaxOverride", store.hrMaxOverride == d.hrMaxOverride)
        check("hrMaxObserved", store.hrMaxObserved == d.hrMaxObserved)
        check("hrMaxObservedOn", store.hrMaxObservedOn == d.hrMaxObservedOn)
        // RECONSTRUCTED BY JOIN, not approved away. A mismatch here means the
        // importer could not resolve which activity produced the maximum —
        // `Report.profileProvenanceUnresolved` counts that at import time.
        check("hrMaxObservedName", store.hrMaxObservedName == d.hrMaxObservedName)
        check("restOverride", store.restOverride == d.restOverride)
        // AN EXPONENT, not a preference. The wrong one rescales every training
        // load the app has ever computed, so it is compared exactly.
        check("sexCoefficient", store.sexCoefficient == d.sexCoefficient)
        check("ftpWatts", storeFTP == ftp)

        // THE RESTING SERIES, month by month over the UNION. A month present
        // on one side only is the difference most worth reporting, and
        // comparing only shared months would be the version that cannot see it.
        let months = Set(store.restByMonth.keys).union(d.restByMonth.keys).sorted()
        r.monthsCompared = months.count
        for m in months where store.restByMonth[m] != d.restByMonth[m] {
            r.monthsDiffering.append(m)
        }

        // THE ZONES, by ordinal over the union. A zone set with a hole is not a
        // smaller problem than no zone set — `zone(forHR:)` would answer
        // confidently from it.
        let byIndex = Dictionary(storeZones.map { ($0.index, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(zones.map { ($0.index, $0) },
                                uniquingKeysWith: { first, _ in first })
        let indices = Set(byIndex.keys).union(theirs.keys).sorted()
        r.zonesCompared = indices.count
        for i in indices where byIndex[i]?.min != theirs[i]?.min
                              || byIndex[i]?.max != theirs[i]?.max {
            r.zonesDiffering.append(i)
        }
        return r
    }
}

// MARK: - The reader

nonisolated enum AthleteRepository {

    static func load(_ db: Sub4Database,
                     accountID: String = Sub4Import.accountID) -> AthleteLoad {
        do {
            return try db.queue.read { d -> AthleteLoad in
                guard let row = try Row.fetchOne(d, sql: profileSQL,
                                                 arguments: [accountID])
                else { return .missing }

                var rest: [String: Int] = [:]
                for r in try Row.fetchAll(d, sql: restingSQL, arguments: [accountID]) {
                    guard let month = r["month"] as String?,
                          let bpm = r["bpm"] as Int? else { continue }
                    rest[month] = bpm
                }

                var zones: [AthleteStore.HRZone] = []
                for r in try Row.fetchAll(d, sql: zoneSQL, arguments: [accountID]) {
                    guard let ordinal = r["ordinal"] as Int?,
                          let min = r["minBpm"] as Int? else { continue }
                    // `max` stays nil for the open-ended top zone. Mapping it
                    // to 0 or to `min` would undo patch 236 silently.
                    zones.append(AthleteStore.HRZone(index: ordinal, min: min,
                                                     max: r["maxBpm"] as Int?))
                }

                // THE MEMBERWISE INITIALISER, NOT SEVEN ASSIGNMENTS. Naming
                // every field is the point: a property added to
                // `AthleteConstants` breaks this line, where seven `c.x = …`
                // statements would compile unchanged and quietly return a
                // default for the new field. Same argument as
                // `differingFields` — no reflection that would not also
                // silently skip something.
                //
                // `version` is the one omission and takes the struct's
                // default. It has no column by design — see the header — and
                // the approved list is what says so out loud rather than this
                // line being where it disappears.
                return .loaded(
                    constants: AthleteConstants(
                        hrMaxOverride: row["hrMaxOverride"] as Int?,
                        hrMaxObserved: row["hrMaxObserved"] as Int?,
                        hrMaxObservedOn: row["hrMaxObservedOnDayKey"] as String?,
                        // From the LEFT JOIN. Null when the importer could not
                        // resolve which activity produced the maximum — a real
                        // loss, and reported as a difference rather than
                        // swallowed here.
                        hrMaxObservedName: row["observedName"] as String?,
                        restByMonth: rest,
                        restOverride: row["restOverride"] as Int?,
                        sexCoefficient: (row["sexCoefficient"] as Double?) ?? 1.92),
                    ftp: row["ftpWatts"] as Int?,
                    zones: zones)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// `LEFT JOIN`, because most profiles resolve their provenance and the ones
    /// that do not must still come back. An inner join would turn an
    /// unresolved maximum into a missing profile.
    private static let profileSQL = """
        SELECT p.hrMaxOverride          AS hrMaxOverride,
               p.hrMaxObserved          AS hrMaxObserved,
               p.hrMaxObservedOnDayKey  AS hrMaxObservedOnDayKey,
               p.restOverride           AS restOverride,
               p.sexCoefficient         AS sexCoefficient,
               p.ftpWatts               AS ftpWatts,
               a.name                   AS observedName
          FROM athlete_profile p
          LEFT JOIN activity a ON a.id = p.hrMaxObservedActivityID
         WHERE p.accountID = ?
        """

    private static let restingSQL = """
        SELECT month, bpm FROM resting_month
         WHERE accountID = ? ORDER BY month
        """

    private static let zoneSQL = """
        SELECT ordinal, minBpm, maxBpm FROM hr_zone
         WHERE accountID = ? ORDER BY ordinal
        """
}
