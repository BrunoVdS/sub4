//
//  WeatherGearRepository.swift
//  Sub4
//
//  Weather and gear, read back out — D6c slice 6, patch 324, ADR-0003 §12.67.
//
//  WHAT THIS IS FOR
//  ----------------
//  Seventh repository, and the one that closes slice 6. `AthleteRoundTrip` did
//  the zones at 317 and the slice has read "317 ✔ / rest open" ever since.
//  `weather` is the largest table in the database with no reader — 583 rows
//  drawn on every activity screen — and `gear` is eleven rows that turn out to
//  be the more interesting half.
//
//  TWO TABLES, ONE SECTION, for the reason §12.65.7 gave: both are caches of
//  fetched source data making the same shape of claim, and the Database screen
//  already carries six read-backs.
//
//  THE CANONICAL-ID TRAP, FIFTH INSTANCE — AND GEAR IS THE EXCEPTION
//  ----------------------------------------------------------------
//  `weather.activityID` is the CANONICAL activity id. `ActivityWeather.activityId`
//  is Strava's. `Sub4Import+Weather` resolves through `activity_alias` on the
//  way in — its own comment says the alias "is the one that survives Strava's
//  retirement" — so this reverses the alias on the way out. Fifth instance:
//  289, 317, 322, 323, this.
//
//  `gear` is the one place the trap does NOT apply, and that is worth stating
//  rather than leaving as a silence. `gear.externalID` IS Strava's id and
//  `AthleteStore.Shoe.id` is Strava's id, so the two key against each other
//  directly. A reader that "helpfully" joined the alias here would find nothing
//  — the alias maps activities, not gear.
//
//  WHY THIS RETURNS `StoredGear` RATHER THAN `Shoe`
//  ------------------------------------------------
//  Every repository before this one hands back the app's own type, because both
//  sides of a comparison should hold the same value. That argument fails here:
//  `Shoe` carries `primary`, which has no column, and `gear` carries
//  `retiredUTC`, which has no field. Constructing a `Shoe` would mean inventing
//  a `primary` — and a fabricated value that then compares equal is the exact
//  silent-data-change shape §12.63.8 was written about.
//
//  So the reader hands back the columns it actually read, and the comparison
//  maps the store's `Shoe` onto them. The two absences are on the approved
//  list, named, with the reason at the line that causes each.
//
//  `source` IS NOT COMPARED, AND `provider` IS — §12.63.8 AGAIN
//  -----------------------------------------------------------
//  `ActivityWeather.source` is `WeatherSource?`; `weather.provider` is NOT
//  NULL, and the importer writes `w.provider`, which is `source ?? .openMeteo`.
//  A nil source therefore normalises to `openMeteo` on write and CANNOT round
//  trip as nil.
//
//  The fix is not an approved-difference entry. 320a made this exact call about
//  a zero heart rate: an approved entry would enshrine a wrong comparison as a
//  data decision. What both sides genuinely hold — and what every screen
//  actually draws — is `provider`, the defaulted value. So `provider` is
//  compared, `source` is not, and the count of readings whose stored `source`
//  was nil is printed as context so the normalisation is visible rather than
//  hidden by the thing that makes it harmless.
//
//  NO TOLERANCE ON THE DOUBLES, DELIBERATELY
//  -----------------------------------------
//  Every weather figure is a `Double` written to a REAL column and read back.
//  That is lossless — there is no formatting step in between, unlike the paces
//  at 320 or the TRIMP at 314. A tolerance here would forgive a difference that
//  can only mean the value changed.
//

import Foundation
import GRDB

// MARK: - What the read produced

nonisolated enum WeatherGearLoad: Sendable {

    case loaded(weather: [ActivityWeather], gear: [StoredGear], skipped: Int)
    case unavailable
    case failed(String)

    /// The `gear` row as it actually is, rather than as `Shoe` wishes it were.
    /// See the header — inventing a `primary` to satisfy a shared type is how a
    /// fabricated value comes to compare equal.
    struct StoredGear: Sendable, Hashable {
        /// Strava's id, which is what `Shoe.id` is. No alias in between.
        let externalID: String
        let name: String
        let distanceM: Double
        /// A column the importer has never written. Read anyway, so the
        /// diagnostic can say it is empty rather than say nothing.
        let retiredUTC: String?
    }

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    var weather: [ActivityWeather]? {
        if case .loaded(let w, _, _) = self { return w }
        return nil
    }

    var gear: [StoredGear]? {
        if case .loaded(_, let g, _) = self { return g }
        return nil
    }

    var skipped: Int {
        if case .loaded(_, _, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let w, let g, let skipped):
            let base = "\(w.count) readings, \(g.count) gear."
            return skipped == 0 ? base
                : base + " \(skipped) rows could not be read."
        case .unavailable: return "The database is not open."
        case .failed(let why): return "The database could not be read — \(why)"
        }
    }
}

// MARK: - The comparison

nonisolated enum WeatherGearRoundTrip {

    /// GROUNDWORK §5's LIST — fourth and fifth entries, after `version` at 317
    /// and the two `user_note` columns at 322.
    ///
    /// A DECISION RECORD, NOT A SUPPRESSION LIST. Both are structural: one
    /// field with no column, one column with no field. Neither is a value that
    /// differs.
    struct ApprovedDifference: Sendable {
        let field: String
        let reason: String
        let patch: String
    }

    static let approved: [ApprovedDifference] = [
        ApprovedDifference(
            field: "Shoe.primary",
            reason: "no column. It is Strava's answer to \"which pair is the "
                  + "default\", a preference held on their side and refetched "
                  + "with the athlete, not a fact about the shoe. The database "
                  + "keeps what survives Strava's retirement — the name and the "
                  + "distance — and this is not that.",
            patch: "324"),
        ApprovedDifference(
            field: "gear.retiredUTC",
            reason: "a column the importer has never written, and there is no "
                  + "field to compare it against. NOT a decision like "
                  + "user_note.activityID: retirement is known at decode time "
                  + "and thrown away twice, once by AthleteStore collapsing it "
                  + "into primary: false and once by an INSERT that names six "
                  + "columns and omits this one. §12.67.4.",
            patch: "324")
    ]

    struct Report: Sendable {

        // MARK: Denominators

        var readingsInApp = 0
        var readingsInDatabase = 0
        var readingsCompared = 0
        /// Eleven per reading.
        var readingFieldsCompared = 0

        var gearInApp = 0
        var gearInDatabase = 0
        var gearCompared = 0
        /// Two per item — the name and the distance. The other two fields are
        /// on the approved list and there is nothing to walk.
        var gearFieldsCompared = 0

        var rowsSkipped = 0

        // MARK: Differences, named

        /// Strava activity ids. A weather reading says nothing about the
        /// athlete beyond which day they were out in it.
        var readingsOnlyInApp: [String] = []
        var readingsOnlyInDatabase: [String] = []
        /// "19580875358 · windKmh"
        var readingDifferences: [String] = []

        var gearOnlyInApp: [String] = []
        var gearOnlyInDatabase: [String] = []
        var gearDifferences: [String] = []

        // MARK: The explained absence

        /// Readings the app holds for an activity its own roster does not.
        /// `weather.activityID` is a foreign key, so the importer CANNOT store
        /// these — its own counter calls them `weatherUnmatched`. Counted here
        /// rather than reported as a difference, because a reading with no
        /// activity to hang on is the database being right.
        ///
        /// Subtracted from `readingsOnlyInApp` before that count is judged, so
        /// the two numbers on screen do not double-count the same rows.
        var readingsForUnknownActivities = 0

        // MARK: Context, printed rather than asserted

        /// Readings whose stored `source` is nil and therefore normalise to
        /// Open-Meteo on write. Printed so the normalisation is visible; see
        /// the header for why it is not a difference.
        var readingsWithNoStoredSource = 0

        var appReadingsFromAppleWeather = 0
        var databaseReadingsFromAppleWeather = 0

        /// Gear rows carrying a retirement timestamp. Expected to be zero until
        /// something writes the column, and printed unconditionally so the day
        /// it stops being zero is visible — §12.54.2.
        var gearCarryingRetirement = 0

        var totalCompared: Int { readingsCompared + gearCompared }

        var unexplained: Int {
            readingsOnlyInApp.count + readingsOnlyInDatabase.count
            + readingDifferences.count
            + gearOnlyInApp.count + gearOnlyInDatabase.count
            + gearDifferences.count
            + rowsSkipped
        }

        /// Gear alone is allowed to be empty — an athlete with no shoes on
        /// Strava is a real state. Weather is not: 583 readings exist and a
        /// device that has opened an activity has some.
        var lookedAtSomething: Bool { readingsCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        var appleLine: String {
            "\(appReadingsFromAppleWeather) vs \(databaseReadingsFromAppleWeather)"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE. Strava activity ids, gear ids, field names and counts.
        /// A weather reading is a fact about a place and an hour.
        var diagnosticLines: [String] {
            var lines = [
                "Weather and gear read-back: \(totalCompared) compared",
                "  readings in the app: \(readingsInApp)",
                "  readings in the database: \(readingsInDatabase)",
                "  readings compared: \(readingsCompared)",
                "  reading fields compared: \(readingFieldsCompared)",
                "  readings only in the app: \(readingsOnlyInApp.count)",
                "  readings only in the database: \(readingsOnlyInDatabase.count)",
                "  readings for an activity the app does not hold: "
                + "\(readingsForUnknownActivities)",
                "  reading fields that differ: \(readingDifferences.count)",
                "  readings with no stored source: \(readingsWithNoStoredSource)",
                "  readings from Apple Weather: \(appleLine)",
                "  gear in the app: \(gearInApp)",
                "  gear in the database: \(gearInDatabase)",
                "  gear compared: \(gearCompared)",
                "  gear fields compared: \(gearFieldsCompared)",
                "  gear only in the app: \(gearOnlyInApp.count)",
                "  gear only in the database: \(gearOnlyInDatabase.count)",
                "  gear fields that differ: \(gearDifferences.count)",
                "  gear carrying a retirement date: \(gearCarryingRetirement)",
                "  rows the reader could not read: \(rowsSkipped)",
                "  approved differences: \(approved.count) "
                + "(\(approved.map(\.field).joined(separator: ", ")))",
                "  unexplained differences: \(unexplained)"]
            for d in readingDifferences.prefix(8) { lines.append("    \(d)") }
            if readingDifferences.count > 8 {
                lines.append("    + \(readingDifferences.count - 8) more readings")
            }
            for d in gearDifferences.prefix(6) { lines.append("    \(d)") }
            return lines
        }
    }

    /// EVERY STORED FIELD, NAMED — the same argument every round trip before
    /// this one makes. There is no reflection here that would not also silently
    /// skip something.
    ///
    /// `knownActivityIDs` is the app's own roster, passed in so a reading for an
    /// activity the app does not hold can be counted as explained rather than
    /// reported as missing. Without it the only honest answer would be "some of
    /// these are fine and this screen cannot tell you which".
    static func compare(storeWeather: [ActivityWeather],
                        storeGear: [AthleteStore.Shoe],
                        knownActivityIDs: Set<String>,
                        database: WeatherGearLoad) -> Report {

        var r = Report()
        r.readingsInApp = storeWeather.count
        r.gearInApp = storeGear.count
        r.readingsWithNoStoredSource = storeWeather.filter { $0.source == nil }.count
        r.appReadingsFromAppleWeather =
            storeWeather.filter { $0.provider == .appleWeather }.count

        guard case .loaded(let dbWeather, let dbGear, let skipped) = database else {
            return r
        }
        r.readingsInDatabase = dbWeather.count
        r.gearInDatabase = dbGear.count
        r.rowsSkipped = skipped
        r.databaseReadingsFromAppleWeather =
            dbWeather.filter { $0.provider == .appleWeather }.count
        r.gearCarryingRetirement = dbGear.filter { $0.retiredUTC != nil }.count

        // MARK: Weather, by Strava's activity id

        let mine = Dictionary(storeWeather.map { ($0.activityId, $0) },
                              uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(dbWeather.map { ($0.activityId, $0) },
                                uniquingKeysWith: { first, _ in first })
        let myKeys = Set(mine.keys)
        let theirKeys = Set(theirs.keys)

        // THE EXPLAINED ABSENCE, SPLIT OUT BEFORE THE COUNT IS JUDGED.
        // `weather.activityID` is a foreign key: a reading whose activity the
        // roster dropped cannot be stored, and the importer counts those as
        // `weatherUnmatched`. Reporting them as missing data would make the
        // screen red for the database doing the right thing.
        let orphans = myKeys.subtracting(theirKeys)
            .filter { !knownActivityIDs.contains($0) }
        r.readingsForUnknownActivities = orphans.count
        r.readingsOnlyInApp = myKeys.subtracting(theirKeys)
            .subtracting(orphans).sorted()
        r.readingsOnlyInDatabase = theirKeys.subtracting(myKeys).sorted()

        for id in myKeys.intersection(theirKeys).sorted() {
            guard let a = mine[id], let b = theirs[id] else { continue }
            r.readingsCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.readingFieldsCompared += 1
                if !same { r.readingDifferences.append("\(id) · \(name)") }
            }
            // EXACT, no tolerance — see the header. A Double through a REAL
            // column and back is lossless, so a difference means the value
            // changed.
            check("tempC", a.tempC == b.tempC)
            check("feelsLikeC", a.feelsLikeC == b.feelsLikeC)
            check("humidity", a.humidity == b.humidity)
            check("windKmh", a.windKmh == b.windKmh)
            check("windFromDegrees", a.windFromDegrees == b.windFromDegrees)
            check("precipitationMm", a.precipitationMm == b.precipitationMm)
            check("symbolName", a.symbolName == b.symbolName)
            check("conditionLabel", a.conditionLabel == b.conditionLabel)
            check("samples", a.samples == b.samples)
            // THE WRITER'S OWN FORMATTER, on both sides — 322's rule. A
            // sub-second difference the column cannot hold is not a divergence.
            check("fetched", Sub4Import.iso8601(a.fetched)
                             == Sub4Import.iso8601(b.fetched))
            // `provider`, NOT `source` — §12.63.8 and the header. What both
            // sides hold and every screen draws.
            check("provider", a.provider == b.provider)
        }

        // MARK: Gear, by Strava's own id — no alias in between

        let myGear = Dictionary(storeGear.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let theirGear = Dictionary(dbGear.map { ($0.externalID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let myGearKeys = Set(myGear.keys)
        let theirGearKeys = Set(theirGear.keys)
        r.gearOnlyInApp = myGearKeys.subtracting(theirGearKeys).sorted()
        r.gearOnlyInDatabase = theirGearKeys.subtracting(myGearKeys).sorted()

        for id in myGearKeys.intersection(theirGearKeys).sorted() {
            guard let a = myGear[id], let b = theirGear[id] else { continue }
            r.gearCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.gearFieldsCompared += 1
                if !same { r.gearDifferences.append("\(id) · \(name)") }
            }
            check("name", a.name == b.name)
            check("distanceM", a.distanceM == b.distanceM)
            // `primary` and `retiredUTC` are on the approved list. Not walked,
            // because there is nothing on the other side to walk against —
            // counting them would inflate the denominator with comparisons
            // that never happened.
        }

        return r
    }
}

// MARK: - The reader

nonisolated enum WeatherGearRepository {

    static func load(_ db: Sub4Database,
                     accountID: String = Sub4Import.accountID,
                     sourceID: String = Sub4Import.sourceID) -> WeatherGearLoad {
        do {
            return try db.queue.read { d -> WeatherGearLoad in
                var readings: [ActivityWeather] = []
                var skipped = 0

                for row in try Row.fetchAll(d, sql: weatherSQL, arguments: [sourceID]) {
                    guard let storeID = row["storeID"] as String?,
                          let rawProvider = row["provider"] as String?,
                          let tempC = row["tempC"] as Double?,
                          let feelsLikeC = row["feelsLikeC"] as Double?,
                          let humidity = row["humidity"] as Double?,
                          let windKmh = row["windKmh"] as Double?,
                          let windFromDegrees = row["windFromDegrees"] as Double?,
                          let precipitationMm = row["precipitationMm"] as Double?,
                          let symbolName = row["symbolName"] as String?,
                          let conditionLabel = row["conditionLabel"] as String?,
                          let samples = row["samples"] as Int?,
                          let fetched = row["fetchedUTC"] as String? else {
                        skipped += 1; continue
                    }
                    // A frozen vocabulary with a CHECK constraint, like
                    // `user_note.feel` and `plan_session.discipline`. An
                    // unrecognised provider is a row this reader cannot
                    // reconstitute, not a nil source — mapping it to nil would
                    // silently resolve it to Open-Meteo through `provider`.
                    guard let provider = WeatherSource(rawValue: rawProvider) else {
                        skipped += 1; continue
                    }
                    readings.append(ActivityWeather(
                        activityId: storeID,
                        tempC: tempC,
                        feelsLikeC: feelsLikeC,
                        humidity: humidity,
                        windKmh: windKmh,
                        windFromDegrees: windFromDegrees,
                        precipitationMm: precipitationMm,
                        symbolName: symbolName,
                        conditionLabel: conditionLabel,
                        samples: samples,
                        fetched: date(fetched),
                        source: provider))
                }

                var gear: [WeatherGearLoad.StoredGear] = []
                for row in try Row.fetchAll(d, sql: gearSQL, arguments: [accountID]) {
                    guard let externalID = row["externalID"] as String?,
                          let name = row["name"] as String?,
                          let distanceM = row["distanceM"] as Double? else {
                        skipped += 1; continue
                    }
                    gear.append(WeatherGearLoad.StoredGear(
                        externalID: externalID,
                        name: name,
                        distanceM: distanceM,
                        retiredUTC: row["retiredUTC"] as String?))
                }

                return .loaded(weather: readings, gear: gear, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// THE WRITER'S FORMATTER, READ BACKWARDS — 322's rule. A string that will
    /// not parse becomes 1970 rather than nil, so it shows as a `fetched`
    /// difference instead of as a row that vanished.
    private static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    /// THROUGH `activity_alias`, reversing what `Sub4Import+Weather` did on the
    /// way in — its own comment says the alias is the mapping that survives
    /// Strava's retirement. `weather.activityID` is the canonical id and
    /// `ActivityWeather.activityId` is Strava's. Fifth instance of the trap.
    private static let weatherSQL = """
        SELECT al.externalID     AS storeID,
               w.provider, w.tempC, w.feelsLikeC, w.humidity, w.windKmh,
               w.windFromDegrees, w.precipitationMm, w.symbolName,
               w.conditionLabel, w.samples, w.fetchedUTC
          FROM weather w
          JOIN activity_alias al ON al.activityID = w.activityID
                                AND al.sourceID = ?
         ORDER BY al.externalID
        """

    /// NO ALIAS. `gear.externalID` is Strava's gear id and `Shoe.id` is
    /// Strava's gear id — the alias table maps activities and would match
    /// nothing here. Rows with a NULL `externalID` are gear that outlived its
    /// source; the app cannot be holding them either, so they are read and let
    /// fall out as "only in the database" rather than filtered away in SQL
    /// where nothing would count them.
    private static let gearSQL = """
        SELECT externalID, name, distanceM, retiredUTC
          FROM gear
         WHERE accountID = ?
         ORDER BY externalID
        """
}
