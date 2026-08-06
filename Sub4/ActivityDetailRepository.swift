//
//  ActivityDetailRepository.swift
//  Sub4
//
//  D6a's second reader — patch 291, ADR-0003 §12.37.
//  Design: docs/D6A-DETAIL-GROUNDWORK.md and D6A-DETAIL-DECISIONS.md.
//
//  FOUR TABLES, THREE NESTED ARRAYS
//  --------------------------------
//    ActivityDetail        activity_detail          668
//    .splits               activity_split         7,990
//    .laps                 activity_lap           2,344
//    .bestEfforts          activity_best_effort     755
//
//  THE ORDINAL MEANS DIFFERENT THINGS IN DIFFERENT TABLES
//  ------------------------------------------------------
//  All three children carry `ordinal`, NOT NULL, >= 0, unique per parent. It
//  is not the same quantity in all three — read from the importer:
//
//    activity_split         ordinal = split.index   a DOMAIN value, 1-based
//    activity_lap           ordinal = lap.index     a DOMAIN value
//    activity_best_effort   ordinal = i             the ARRAY POSITION, 0-based
//
//  So `Split` and `Lap` take their `index` FROM the ordinal. `BestEffort` has
//  no index property at all — its identity is `name` — and its ordinal exists
//  only to preserve array order, so it is ordered by and then discarded.
//
//  Getting this backwards gives splits numbered from zero, or best efforts in
//  whatever order SQLite chose. Neither fails a count comparison, which is
//  §12.16's warning exactly.
//
//  THE DATE
//  --------
//  `fetched` is the one type change in the mapping: `Date` in the store,
//  ISO-8601 text in the column. The writer's formatter is
//  `Sub4Import.iso8601` — `.withInternetDateTime`, no fractional seconds — so
//  `parseUTC` below is written to match it and is kept in this file for that
//  reason. The database is second-precision by construction.
//
//  WHAT IT LOSES, AND WHY THAT IS NOT FIXED HERE
//  ---------------------------------------------
//  The importer writes `positiveOrNil(...)` for BOTH `split.averageHR` and
//  `lap.averageHR`, so a zero heart rate becomes NULL and comes back `nil`.
//  That is the importer's deliberate normalisation. This reader reports it
//  rather than inventing a zero to make a comparison pass — see §12.37.4.
//

import Foundation
import GRDB

/// What a read of the detail tables produced. Same shape as `ActivityLoad`.
nonisolated enum DetailLoad: Sendable {
    /// `skipped` counts `activity_detail` rows that could not be turned into
    /// an `ActivityDetail` — today, one whose activity has no source record
    /// for this source, orphaned by a source change. Expected to be zero.
    case loaded(details: [ActivityDetail], skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Optional, never `[]` — a caller must decide what an untrustworthy read
    /// means before it can reach the happy path.
    var details: [ActivityDetail]? {
        if case .loaded(let d, _) = self { return d }
        return nil
    }

    var skipped: Int {
        if case .loaded(_, let n) = self { return n }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let d, let skipped):
            skipped == 0
                ? "\(d.count) details."
                : "\(d.count) details; \(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

nonisolated enum ActivityDetailRepository {

    static func all(_ db: Sub4Database,
                    accountID: String = Sub4Import.accountID,
                    sourceID: String = Sub4Import.sourceID) -> DetailLoad {
        do {
            return try db.queue.read { d -> DetailLoad in
                let rows = try Row.fetchAll(d, sql: parentSQL,
                                            arguments: [sourceID, sourceID, accountID])
                var out: [ActivityDetail] = []
                var skipped = 0
                for row in rows {
                    guard let storeID: String = row["storeID"],
                          let rowID: String = row["detailID"] else { skipped += 1; continue }
                    out.append(try detail(d, rowID: rowID, storeID: storeID, row: row))
                }
                return .loaded(details: out, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func detail(_ db: Sub4Database, storeID: String,
                       accountID: String = Sub4Import.accountID,
                       sourceID: String = Sub4Import.sourceID) -> DetailLoad {
        do {
            return try db.queue.read { d -> DetailLoad in
                let row = try Row.fetchOne(d, sql: parentSQL + "\n  AND r.externalID = ?",
                                           arguments: [sourceID, sourceID,
                                                       accountID, storeID])
                guard let row, let rowID: String = row["detailID"] else {
                    return .loaded(details: [], skipped: 0)
                }
                let one = try detail(d, rowID: rowID, storeID: storeID, row: row)
                return .loaded(details: [one], skipped: 0)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Building one

    private static func detail(_ d: Database, rowID: String,
                               storeID: String, row: Row) throws -> ActivityDetail {
        ActivityDetail(
            activityId: storeID,
            calories: row["calories"],
            descriptionText: row["descriptionText"],
            averageCadence: row["averageCadence"],
            averageWatts: row["averageWatts"],
            maxWatts: row["maxWatts"],
            deviceName: row["deviceName"],
            polyline: row["polyline"],
            splits: try splits(d, rowID),
            bestEfforts: try bestEfforts(d, rowID),
            laps: try laps(d, rowID),
            fetched: parseUTC(row["fetchedUTC"]) ?? .distantPast)
    }

    /// `index` FROM `ordinal` — the importer put `split.index` there.
    private static func splits(_ d: Database, _ id: String) throws -> [ActivityDetail.Split] {
        try Row.fetchAll(d, sql: """
            SELECT ordinal, distanceM, movingSeconds, elapsedSeconds,
                   elevationDiffM, averageHeartrate
            FROM activity_split WHERE activityDetailID = ? ORDER BY ordinal
            """, arguments: [id]).map {
            ActivityDetail.Split(index: $0["ordinal"],
                                 distanceM: $0["distanceM"],
                                 movingTime: $0["movingSeconds"],
                                 elapsedTime: $0["elapsedSeconds"],
                                 elevationDiff: $0["elevationDiffM"],
                                 averageHR: $0["averageHeartrate"])
        }
    }

    /// Likewise. `Lap` has no `elapsedTime`, and the table has no column for
    /// one — the two agree about that.
    private static func laps(_ d: Database, _ id: String) throws -> [ActivityDetail.Lap] {
        try Row.fetchAll(d, sql: """
            SELECT ordinal, distanceM, movingSeconds, averageHeartrate
            FROM activity_lap WHERE activityDetailID = ? ORDER BY ordinal
            """, arguments: [id]).map {
            ActivityDetail.Lap(index: $0["ordinal"],
                               distanceM: $0["distanceM"],
                               movingTime: $0["movingSeconds"],
                               averageHR: $0["averageHeartrate"])
        }
    }

    /// ORDERED BY `ordinal` AND THEN IT IS DISCARDED. `BestEffort` has no
    /// index; the ordinal is array position and belongs nowhere in the struct.
    private static func bestEfforts(_ d: Database,
                                    _ id: String) throws -> [ActivityDetail.BestEffort] {
        try Row.fetchAll(d, sql: """
            SELECT name, seconds FROM activity_best_effort
            WHERE activityDetailID = ? ORDER BY ordinal
            """, arguments: [id]).map {
            ActivityDetail.BestEffort(name: $0["name"], seconds: $0["seconds"])
        }
    }

    // MARK: The parent query

    private static let parentSQL = """
        SELECT ad.id                 AS detailID,
               r.externalID          AS storeID,
               ad.calories           AS calories,
               ad.descriptionText    AS descriptionText,
               ad.averageCadence     AS averageCadence,
               ad.averageWatts       AS averageWatts,
               ad.maxWatts           AS maxWatts,
               ad.deviceName         AS deviceName,
               ad.polyline           AS polyline,
               ad.fetchedUTC         AS fetchedUTC
        FROM activity_detail ad
        JOIN activity a ON a.id = ad.activityID
        JOIN activity_source_record r
          ON r.activityID = ad.activityID AND r.sourceID = ?
        WHERE ad.sourceID = ? AND a.accountID = ?
        """

    /// The reader's half of the date pair. Deliberately beside nothing else:
    /// it exists to match `Sub4Import.iso8601`, and the two drift apart the
    /// moment either is changed without the other.
    static func parseUTC(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

/// The store against the database, one detail at a time — patch 291.
///
/// MATCHED BY IDENTITY, NEVER BY POSITION — `D6A-DETAIL-DECISIONS.md` §2.
/// Splits and laps match on `index`, best efforts on `name`. That removes the
/// ordering question entirely: it makes no difference what order either side
/// is in, and a failure names a kilometre you can open rather than an array
/// slot you cannot.
///
/// It also separates three things a count would blur: an element the store has
/// and the database does not is MISSING, the reverse is SURPLUS, and neither
/// is a DIFFERENCE.
nonisolated enum DetailRoundTrip {

    struct Difference: Sendable, Identifiable {
        /// The store's activity id — Strava's.
        let id: String
        /// e.g. "calories", "splits[index: 7].movingTime", "splits missing 12",
        /// "bestEfforts surplus 1500m".
        let fields: [String]
    }

    struct Report: Sendable {
        var compared = 0
        /// In the store and not in the database at all.
        var missing: [String] = []
        var differences: [Difference] = []

        var agreed: Int { compared - differences.count }

        var fieldTally: [(field: String, count: Int)] {
            var counts: [String: Int] = [:]
            for d in differences { for f in d.fields { counts[f, default: 0] += 1 } }
            return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { (field: $0.key, count: $0.value) }
        }
    }

    static func compare(store: [ActivityDetail], database: [ActivityDetail]) -> Report {
        var byID: [String: ActivityDetail] = [:]
        for d in database { byID[d.activityId] = d }

        var report = Report()
        for s in store {
            guard let d = byID[s.activityId] else {
                report.missing.append(s.activityId); continue
            }
            report.compared += 1
            let fields = differingFields(s, d)
            if !fields.isEmpty {
                report.differences.append(Difference(id: s.activityId, fields: fields))
            }
        }
        report.missing.sort()
        return report
    }

    /// SECOND PRECISION, TRUNCATED — 291a, and the correction is the finding.
    ///
    /// This used `.rounded()`, and the read-back reported `fetched` differing
    /// on 320 of 668 details. 47.9% — which is how many timestamps carry a
    /// fractional second of 0.5 or more.
    ///
    /// `ISO8601DateFormatter` with `.withInternetDateTime` DROPS the fraction;
    /// it does not round it. So a store timestamp of x.6 was written as x and
    /// compared as x+1, and disagreed with itself. The reader was right, the
    /// database was right, and the comparison manufactured 320 differences
    /// that were not differences.
    ///
    /// **A comparison has to model what the writer did, not what would be
    /// tidy.** Truncation is not an approximation of rounding.
    static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        floor(a.timeIntervalSince1970) == floor(b.timeIntervalSince1970)
    }

    static func differingFields(_ s: ActivityDetail, _ d: ActivityDetail) -> [String] {
        var out: [String] = []
        func check(_ name: String, _ same: Bool) { if !same { out.append(name) } }

        check("calories", s.calories == d.calories)
        check("descriptionText", s.descriptionText == d.descriptionText)
        check("averageCadence", s.averageCadence == d.averageCadence)
        check("averageWatts", s.averageWatts == d.averageWatts)
        check("maxWatts", s.maxWatts == d.maxWatts)
        check("deviceName", s.deviceName == d.deviceName)
        check("polyline", s.polyline == d.polyline)
        check("fetched", sameSecond(s.fetched, d.fetched))

        out += compareSplits(s.splits, d.splits)
        out += compareLaps(s.laps, d.laps)
        out += compareEfforts(s.bestEfforts, d.bestEfforts)
        return out
    }

    private static func compareSplits(_ s: [ActivityDetail.Split],
                                      _ d: [ActivityDetail.Split]) -> [String] {
        var byIndex: [Int: ActivityDetail.Split] = [:]
        for x in d { byIndex[x.index] = x }
        var out: [String] = []
        for a in s {
            guard let b = byIndex.removeValue(forKey: a.index) else {
                out.append("splits missing \(a.index)"); continue
            }
            if a.distanceM != b.distanceM { out.append("splits[index: \(a.index)].distanceM") }
            if a.movingTime != b.movingTime { out.append("splits[index: \(a.index)].movingTime") }
            if a.elapsedTime != b.elapsedTime { out.append("splits[index: \(a.index)].elapsedTime") }
            if a.elevationDiff != b.elevationDiff { out.append("splits[index: \(a.index)].elevationDiff") }
            // Expected to appear where the store holds a zero: the importer
            // writes `positiveOrNil`. Reported, not papered over — §12.37.4.
            if a.averageHR != b.averageHR { out.append("splits[index: \(a.index)].averageHR") }
        }
        for left in byIndex.keys.sorted() { out.append("splits surplus \(left)") }
        return out
    }

    private static func compareLaps(_ s: [ActivityDetail.Lap],
                                    _ d: [ActivityDetail.Lap]) -> [String] {
        var byIndex: [Int: ActivityDetail.Lap] = [:]
        for x in d { byIndex[x.index] = x }
        var out: [String] = []
        for a in s {
            guard let b = byIndex.removeValue(forKey: a.index) else {
                out.append("laps missing \(a.index)"); continue
            }
            if a.distanceM != b.distanceM { out.append("laps[index: \(a.index)].distanceM") }
            if a.movingTime != b.movingTime { out.append("laps[index: \(a.index)].movingTime") }
            if a.averageHR != b.averageHR { out.append("laps[index: \(a.index)].averageHR") }
        }
        for left in byIndex.keys.sorted() { out.append("laps surplus \(left)") }
        return out
    }

    /// Matched on `name`, which is `BestEffort.id`. The ordinal never enters
    /// the struct, so it cannot be compared and does not need to be.
    private static func compareEfforts(_ s: [ActivityDetail.BestEffort],
                                       _ d: [ActivityDetail.BestEffort]) -> [String] {
        var byName: [String: ActivityDetail.BestEffort] = [:]
        for x in d { byName[x.name] = x }
        var out: [String] = []
        for a in s {
            guard let b = byName.removeValue(forKey: a.name) else {
                out.append("bestEfforts missing \(a.name)"); continue
            }
            if a.seconds != b.seconds { out.append("bestEfforts[\(a.name)].seconds") }
        }
        for left in byName.keys.sorted() { out.append("bestEfforts surplus \(left)") }
        return out
    }
}
