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
//  GEAR THE SOURCE NO LONGER LISTS IS NOT A DIFFERENCE — 325
//  ----------------------------------------------------------
//  324 reported five gear rows as "only in the database" in red. They are shoes
//  Strava's current gear list no longer returns, and the `gear` table's own
//  migration comment says the row is nullable on `sourceID` because "gear
//  survives the source it came from — shoes keep their mileage after Strava is
//  gone". Keeping them is the schema working, not failing.
//
//  So they are counted on their own line and excluded from `unexplained`.
//
//  **THE COST, STATED RATHER THAN LEFT TO BE NOTICED.** The app side of this
//  comparison IS Strava's current list, so every database row absent from it
//  falls into this category — which means **a spurious gear row is now
//  undetectable by this comparison.** Nothing distinguishes "retired" from
//  "should never have been written", because no column records when a row was
//  last seen. `gear.retiredUTC` would; it stays unwritten by decision, since
//  ADR-0002 retires Strava at Phase 4A and the signal disappears with it.
//
//  The other direction stays red: a shoe Strava lists that the database does
//  NOT hold is a row the importer failed to insert, and that is a real gap.
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
        /// **WRITTEN SINCE PATCH 426** — the newest activity naming this
        /// gear. Read since 324, when it was a column nothing filled and the
        /// diagnostic's job was to say it was empty rather than say nothing.
        let retiredUTC: String?
        /// PATCH 427. `nil` cannot occur — the column is `NOT NULL DEFAULT
        /// 'unknown'` — but an unrecognised value can, and mapping it into
        /// `GearKind` here rather than at the comparison means a row this
        /// reader cannot reconstitute is SKIPPED, exactly as an unrecognised
        /// weather provider is, instead of silently becoming `unknown`.
        let kind: GearKind
        /// PATCH 427. Stated by the importer, never derived — see §12.176.2.
        let isRetired: Bool
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
        // **REWRITTEN AT 427, AND THE OLD REASON WAS RIGHT WHEN IT WAS
        // WRITTEN.** 324 said retirement was thrown away twice; 426 stopped
        // that — `gear.isRetired` now carries the fact and IS compared. What
        // remains approved is only the DATE.
        ApprovedDifference(
            field: "gear.retiredUTC",
            reason: "written since 426 and derived from the database's own "
                  + "rows — the newest activity naming this gear, joined "
                  + "through activity_gear_reference. The store holds no "
                  + "retirement date to compare it against, and deriving one "
                  + "app-side would read ActivityStore, which the database has "
                  + "fed since 381: a comparison that could not disagree. "
                  + "Proved by test instead. The FACT of retirement is "
                  + "compared — see gear.isRetired. §12.177.",
            patch: "427")
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
        /// **FOUR per item since 427** — the name, the distance, the kind and
        /// the retirement. It was two until 425/426 gave both sides something
        /// to disagree about; `Shoe.primary` and `gear.retiredUTC` remain on
        /// the approved list, and there is nothing to walk them against.
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
        var gearDifferences: [String] = []

        /// Gear the database holds that the source no longer lists. NOT a
        /// difference — see the header. Named rather than merely counted,
        /// because eleven rows is a list a person can read and five of them
        /// being retired shoes is a fact worth being able to check.
        var gearKeptAfterTheSourceDropped: [String] = []

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
        /// **PATCH 427.** How many gear rows the DATABASE marks retired — the
        /// fact, as against `gearCarryingRetirement`'s date. The two differ
        /// exactly when a retirement could not be dated (§12.176.2), and
        /// printing both is what makes that state visible instead of arithmetic
        /// somebody has to do.
        var gearRetiredInDatabase = 0
        /// The database's kind census, so a screen can say `12 shoes, 3 bikes,
        /// 5 of unknown kind` rather than leave the reader to infer it from an
        /// absence. §12.54.2.
        var gearShoes = 0
        var gearBikes = 0
        var gearOfUnknownKind = 0
        /// **HOW MANY ACTIVITY IDS THE FILTER KNEW, AND WHERE THEY CAME FROM —
        /// patch 427.** `readingsForUnknownActivities` is meaningless without
        /// it: a filter that knew nothing calls every reading unknown, and a
        /// filter nobody wired in does the same. §12.15.
        var knownActivities = 0
        var rosterCameFrom = "not stated"

        var totalCompared: Int { readingsCompared + gearCompared }

        var unexplained: Int {
            readingsOnlyInApp.count + readingsOnlyInDatabase.count
            + readingDifferences.count
            + gearOnlyInApp.count + gearDifferences.count
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
                "  the roster that decided that: \(knownActivities) activities, "
                + "from \(rosterCameFrom)",
                "  reading fields that differ: \(readingDifferences.count)",
                "  readings with no stored source: \(readingsWithNoStoredSource)",
                "  readings from Apple Weather: \(appleLine)",
                "  gear in the app: \(gearInApp)",
                "  gear in the database: \(gearInDatabase)",
                "  gear compared: \(gearCompared)",
                "  gear fields compared: \(gearFieldsCompared)",
                "  gear only in the app: \(gearOnlyInApp.count)",
                "  gear kept after the source dropped it: "
                + "\(gearKeptAfterTheSourceDropped.count)",
                "  gear fields that differ: \(gearDifferences.count)",
                "  gear the database marks retired: \(gearRetiredInDatabase)",
                "  gear carrying a retirement date: \(gearCarryingRetirement)",
                "  gear by kind: \(gearShoes) shoes, \(gearBikes) bikes, "
                + "\(gearOfUnknownKind) of unknown kind",
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
    /// `rosterCameFrom` is a sentence, not a flag: it reaches the paste, and
    /// the device is the only place the wiring can be told apart. See
    /// §12.177.3 — no unit test discriminates it, and that is written down
    /// rather than left to be assumed.
    static func compare(storeWeather: [ActivityWeather],
                        storeGear: [AthleteStore.Shoe],
                        knownActivityIDs: Set<String>,
                        rosterCameFrom: String = "not stated",
                        database: WeatherGearLoad) -> Report {

        var r = Report()
        r.readingsInApp = storeWeather.count
        r.gearInApp = storeGear.count
        r.knownActivities = knownActivityIDs.count
        r.rosterCameFrom = rosterCameFrom
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
        r.gearRetiredInDatabase = dbGear.filter(\.isRetired).count
        r.gearShoes = dbGear.filter { $0.kind == .shoe }.count
        r.gearBikes = dbGear.filter { $0.kind == .bike }.count
        r.gearOfUnknownKind = dbGear.filter { $0.kind == .unknown }.count

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
        // RED: the source lists a shoe and the database does not hold it. That
        // is an insert the importer failed to make.
        r.gearOnlyInApp = myGearKeys.subtracting(theirGearKeys).sorted()
        // NOT RED: the database keeps what the source has stopped listing,
        // which is the whole reason `gear.sourceID` is nullable.
        r.gearKeptAfterTheSourceDropped =
            theirGearKeys.subtracting(myGearKeys).sorted()

        for id in myGearKeys.intersection(theirGearKeys).sorted() {
            guard let a = myGear[id], let b = theirGear[id] else { continue }
            r.gearCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.gearFieldsCompared += 1
                if !same { r.gearDifferences.append("\(id) · \(name)") }
            }
            check("name", a.name == b.name)
            check("distanceM", a.distanceM == b.distanceM)
            // **PATCH 427 — THE TWO FIELDS THAT COULD NOT DISAGREE UNTIL NOW.**
            // Before 425 neither side carried them, so there was nothing to
            // compare and no entry on the approved list either: a difference
            // that cannot be expressed appears on no list (§12.175.1).
            //
            // **`storedKind` AND `storedRetired`, NOT AN INLINE `??`.** The
            // importer and this comparison must resolve a missing kind the same
            // way or a pre-425 file reports a difference on every item — which
            // is what the first draft of 427 did, and what the existing
            // fixtures in `WeatherGearRepositoryTests` caught. §12.43.
            check("kind", a.storedKind == b.kind)
            check("retired", a.storedRetired == b.isRetired)
            // `primary` and `retiredUTC` stay on the approved list, and 427
            // rewrites the second one's reason: it is now WRITTEN, and it has
            // no counterpart in the store to walk against. Counting it would
            // inflate the denominator with a comparison that never happened.
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
                          let distanceM = row["distanceM"] as Double?,
                          let isRetired = row["isRetired"] as Bool? else {
                        skipped += 1; continue
                    }
                    // THE SAME RULE AS THE WEATHER PROVIDER ABOVE. A value the
                    // enum does not know is a row this reader cannot
                    // reconstitute; resolving it to `.unknown` would make a
                    // corrupt row compare equal to an honest one.
                    guard let rawKind = row["kind"] as String?,
                          let kind = GearKind(rawValue: rawKind) else {
                        skipped += 1; continue
                    }
                    gear.append(WeatherGearLoad.StoredGear(
                        externalID: externalID,
                        name: name,
                        distanceM: distanceM,
                        retiredUTC: row["retiredUTC"] as String?,
                        kind: kind,
                        isRetired: isRetired))
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
        SELECT externalID, name, distanceM, retiredUTC, kind, isRetired
          FROM gear
         WHERE accountID = ?
         ORDER BY externalID
        """
}
