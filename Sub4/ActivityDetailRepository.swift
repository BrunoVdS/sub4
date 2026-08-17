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

    // MARK: The bootstrap's two verdicts — patch 394, §12.92

    /// Did the read succeed. **TRUE FOR A CLEAN READ OF AN EMPTY TABLE**, which
    /// is the whole reason this is not `holdsContent` — a device between its
    /// first launch and its first backfill reads perfectly and holds nothing.
    ///
    /// §12.92 removed a single `isTrustworthy` from `DatabaseBootstrap` for
    /// exactly this: the sibling loads do not agree about what one word means,
    /// and `&&`-ing them produced a boolean that meant neither thing.
    var wasReadCleanly: Bool { isTrustworthy }

    /// Does this family hold anything to hydrate a store from.
    ///
    /// FALSE IS NOT A FAULT. `skipped` deliberately does not enter: a row the
    /// reader could not turn into an `ActivityDetail` is a fault
    /// `wasReadCleanly` already reports, and counting it here would make the
    /// same defect say two different things.
    var holdsContent: Bool {
        if case .loaded(let d, _) = self { return !d.isEmpty }
        return false
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
        /// In the store and not in the database, and nobody meant that.
        var missing: [String] = []
        /// In the store and not in the database ON PURPOSE — patch 298.
        /// `DataCorrections` refuses two sessions and the importer declines
        /// their details at the door, while `DetailStore` keeps them because it
        /// keys by Strava id and never sees an `Activity`. A permanent, correct
        /// red row is a row that stops being read.
        var excluded: [String] = []
        var differences: [Difference] = []


        var agreed: Int { compared - differences.count }

        /// TWO NUMBERS PER ROW — patch 295, and the second one is new.
        ///
        /// `details` is how many DETAILS carry this field at all; `elements` is
        /// how many splits, laps or efforts inside them do. Thirteen details
        /// each with one bad lap and thirteen details with forty bad laps
        /// between them are the same first number and nothing alike in the
        /// second — the same wide-versus-deep split §12.39.2 built into the
        /// recording report.
        ///
        /// Grouped by `tallyKey`, so one cause is one row. See its comment for
        /// what that run actually looked like without it.
        var fieldTally: [(field: String, details: Int, elements: Int)] {
            var details: [String: Int] = [:]
            var elements: [String: Int] = [:]
            for d in differences {
                var seen: Set<String> = []
                for f in d.fields {
                    let key = DetailRoundTrip.tallyKey(f)
                    elements[key, default: 0] += 1
                    if seen.insert(key).inserted { details[key, default: 0] += 1 }
                }
            }
            return details.map { (field: $0.key,
                                  details: $0.value,
                                  elements: elements[$0.key] ?? 0) }
                .sorted { a, b in
                    if a.details != b.details { return a.details > b.details }
                    if a.elements != b.elements { return a.elements > b.elements }
                    return a.field < b.field
                }
        }

        /// **THE PASTE HAS NEVER CARRIED THIS — patch 391, §12.135.** See
        /// `ActivityRoundTrip.Report.diagnosticLines` for the argument; this is
        /// the same gap over 694 details and every split, lap and best effort
        /// inside them.
        ///
        /// **BOTH TALLY NUMBERS, because patch 295 bought the distinction.**
        /// Thirteen details each with one bad lap and thirteen details with
        /// forty bad laps between them share the first number and are nothing
        /// alike in the second.
        ///
        /// `excluded` is printed and is NOT a difference — §12.42.2, two
        /// sessions `DataCorrections` refuses. A permanently correct red row is
        /// a row that stops being read, so it is counted apart rather than
        /// folded into `missing`.
        ///
        /// Counts and field names only; the ids stay on the screen. §12.7.
        var diagnosticLines: [String] {
            var out = ["Detail read-back: \(compared) compared",
                       "  agreed: \(agreed)",
                       "  in the app and not in the database: \(missing.count)",
                       "  excluded on purpose: \(excluded.count)",
                       "  details with a differing field: \(differences.count)"]
            out.append("  fields that differ: "
                       + (fieldTally.isEmpty ? "none"
                          : fieldTally
                              .map { "\($0.field) \($0.details) details / "
                                   + "\($0.elements) elements" }
                              .joined(separator: ", ")))
            return out
        }
    }

    /// THE TALLY KEY — patch 295, ADR-0003 §12.40.
    ///
    /// `differingFields` names an element precisely on purpose:
    /// `laps[index: 12].averageHR` is a lap somebody can open, and §12.37.2
    /// chose identity over position exactly so it would be. That precision is
    /// right on the difference and wrong on the tally.
    ///
    /// The first real run showed why. Thirteen details differed, one cause —
    /// the importer's `positiveOrNil` on a zero heart rate — and the tally had
    /// twenty-five keys, because every lap index is its own key. The screen
    /// truncated at twelve and printed "+ 13 more fields", so a single known
    /// normalisation arrived looking like twenty-five unrelated problems with
    /// an unknown number hidden behind a cut-off.
    ///
    /// This is the same defect §12.39.2 designed the recording report AROUND,
    /// found in the report written four patches earlier. The fix is to collapse
    /// the element identity **for grouping only**: `laps[*].averageHR`, one
    /// row, count thirteen. The precise name stays on `Difference.fields`,
    /// where it still leads to a lap.
    ///
    /// Rules, matching exactly what `differingFields` emits:
    ///
    ///     laps[index: 12].averageHR   →  laps[*].averageHR
    ///     bestEfforts[1k].seconds     →  bestEfforts[*].seconds
    ///     splits missing 12           →  splits missing
    ///     bestEfforts surplus 1500m   →  bestEfforts surplus
    ///     calories                    →  calories
    static func tallyKey(_ field: String) -> String {
        if let open = field.firstIndex(of: "["),
           let close = field.firstIndex(of: "]"),
           open < close {
            return String(field[..<open]) + "[*]"
                + String(field[field.index(after: close)...])
        }
        for word in [" missing ", " surplus "] {
            if let r = field.range(of: word) {
                return String(field[..<r.lowerBound]) + String(word.dropLast())
            }
        }
        return field
    }

    static func compare(store: [ActivityDetail], database: [ActivityDetail]) -> Report {
        var byID: [String: ActivityDetail] = [:]
        for d in database { byID[d.activityId] = d }

        var report = Report()
        for s in store {
            guard let d = byID[s.activityId] else {
                // Absent on purpose is not absent — patch 298, §12.42.2.
                if DataCorrections.isIgnored(id: s.activityId) {
                    report.excluded.append(s.activityId)
                } else {
                    report.missing.append(s.activityId)
                }
                continue
            }

            report.compared += 1
            let fields = differingFields(s, d)
            if !fields.isEmpty {
                report.differences.append(Difference(id: s.activityId, fields: fields))
            }
        }
        report.missing.sort()
        report.excluded.sort()
        return report
    }

    /// THE WRITER'S OWN FUNCTION, not a model of it — 299, and this is the
    /// third version of four lines of code. The history is the point.
    ///
    /// **291: `.rounded()`.** The read-back reported `fetched` differing on
    /// **320 of 668** details. 47.9%, which is how many timestamps carry a
    /// fractional second of 0.5 or more — the proportion was the diagnosis.
    /// `ISO8601DateFormatter` with `.withInternetDateTime` drops the fraction
    /// rather than rounding it, so a store value of x.6 was written as x and
    /// compared as x+1, and disagreed with itself.
    ///
    /// **291a: `floor()`.** 320 became **1**, and the note written at the time
    /// said *"a comparison has to model what the writer did, not what would be
    /// tidy."* Correct, and it stopped one word short. Flooring is still a
    /// MODEL of the writer.
    ///
    /// **298 made the last one legible** by printing both values, and the
    /// screen said:
    ///
    ///     17463863070 — fetched: store 2026-08-04T17:58:58Z,
    ///                   database 2026-08-04T17:58:58Z
    ///
    /// The two dates render identically and the comparison called them
    /// different. That is proof — whatever the mechanism — that `floor` on a
    /// `TimeInterval` and Foundation's calendar arithmetic do not agree on
    /// every instant, and one of them is the one that actually wrote the row.
    ///
    /// **299: call the writer.** `Sub4Import.iso8601` is the function that
    /// produced `fetchedUTC`. Comparing its output cannot drift from it,
    /// because it is not an approximation of the writer — it IS the writer.
    /// It is also exactly what `Sub4Import+Recording` does when it decides a
    /// trace is unchanged, which is why the importer said `0 replaced` about
    /// the same row this reported as a difference. The importer was right.
    ///
    /// The name still holds: the database is second-precision by construction,
    /// and this asks whether two instants land on the same stored second.
    ///
    /// **The general form, and it has cost three patches to learn:** when a
    /// comparison and a writer must agree, do not reimplement the writer.
    /// Call it.
    static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        Sub4Import.iso8601(a) == Sub4Import.iso8601(b)
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
