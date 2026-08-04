//
//  Sub4Import+Weather.swift
//  Sub4
//
//  Weather, and the re-keying it performs on the way — patch 226,
//  ADR-0003 §12.9.
//
//  THE FIRST 3.2b TABLE THAT NEEDED NOTHING
//  ----------------------------------------
//  `proposal_change` was missing five fields and `activity` was missing five
//  columns, both because the table was designed from §8's prose rather than
//  from the type it holds. `weather` was checked the same way before this file
//  was written and came out complete: every stored property of
//  `ActivityWeather` has a column, `WeatherSource`'s raw values are exactly the
//  frozen `domainWeatherProviders`, and the CHECK bounds match what
//  `WeatherStore` already refuses. Recorded because "we checked and it was
//  fine" is worth as much as the two findings — it is what makes the checking
//  a habit rather than a reaction.
//
//  THIS IMPORT CLOSES A GAP RATHER THAN CARRYING IT
//  ------------------------------------------------
//  `weather.json` is a dictionary keyed by STRAVA ACTIVITY ID. §8 records that
//  as a known gap — "the key itself carries Strava lineage (ADR-0002 — re-key
//  at 4A M4)". The schema's `weather.activityID` references the canonical
//  activity instead, so the import has to resolve every key through
//  `activity_alias`, and the row that lands carries no Strava identity at all.
//
//  That is 4A M4 done early, as a side effect of the cutover rather than as a
//  migration of its own. It is also why `activity_alias` was written at import
//  time in patch 218 rather than at retirement: this is the first thing that
//  needs it, three patches later.
//
//  WEATHER FOR AN ACTIVITY THAT IS NOT HERE
//  ----------------------------------------
//  `weather.activityID` is NOT NULL with a foreign key, so a reading whose
//  activity never made it into the database cannot be stored. That is not a
//  defect to work around: weather is ABOUT an activity, and a reading attached
//  to nothing is not a fact anybody can use.
//
//  It is counted rather than refused, and the distinction matters. A refusal
//  means the schema rejected something that should have fitted; this is the
//  schema correctly declining to hold an orphan. The expected count is one —
//  the August 2025 artifact — and anything larger means activities are missing
//  that should not be.
//

import Foundation
import GRDB

extension Sub4Import {

    nonisolated static func importWeather(
        _ d: Database,
        readings: [ActivityWeather],
        now: String,
        into report: inout Report
    ) throws {
        for w in readings {
            report.weatherSeen += 1

            // THROUGH THE ALIAS, NOT THE SOURCE RECORD. Both would work today.
            // The alias is the one that survives Strava's retirement — §3.1
            // calls it "the mechanism by which thirteen months of notes,
            // corrections and rejections survive Phase 4A" — and weather is
            // exactly such a thing.
            let canonical = try String.fetchOne(d, sql: """
                SELECT activityID FROM activity_alias
                WHERE sourceID = ? AND externalID = ?
                """, arguments: [sourceID, w.activityId])

            guard let activityID = canonical else {
                report.weatherUnmatched += 1
                continue
            }

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM weather WHERE activityID = ?
                """, arguments: [activityID])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE weather SET
                              provider = ?, tempC = ?, feelsLikeC = ?, humidity = ?,
                              windKmh = ?, windFromDegrees = ?, precipitationMm = ?,
                              symbolName = ?, conditionLabel = ?, samples = ?,
                              fetchedUTC = ?
                            WHERE id = ?
                            """, arguments: [w.provider.rawValue, w.tempC, w.feelsLikeC,
                                             w.humidity, w.windKmh, w.windFromDegrees,
                                             w.precipitationMm, w.symbolName,
                                             w.conditionLabel, w.samples,
                                             iso8601(w.fetched), id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO weather
                              (id, activityID, provider, tempC, feelsLikeC, humidity,
                               windKmh, windFromDegrees, precipitationMm,
                               symbolName, conditionLabel, samples, fetchedUTC)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, activityID,
                                             w.provider.rawValue, w.tempC, w.feelsLikeC,
                                             w.humidity, w.windKmh, w.windFromDegrees,
                                             w.precipitationMm, w.symbolName,
                                             w.conditionLabel, w.samples,
                                             iso8601(w.fetched)])
                    }
                    return .commit
                }
                if existing != nil { report.weatherUpdated += 1 }
                else { report.weatherImported += 1 }
            } catch {
                // Named by the Strava id, because that is the only handle the
                // reading has — the canonical id it would have taken is the
                // thing that did not get written.
                report.refusals.append(.init(externalID: "weather \(w.activityId)",
                                             reason: String(describing: error)))
            }
        }
    }
}
