//
//  Activity.swift
//  Sub4
//
//  A completed activity, from Strava. Strava is the sole source of truth for
//  what was done — nothing in this app creates one.
//

import Foundation

struct Activity: Codable, Identifiable, Hashable {

    let id: String                 // Strava activity id — the dedup key
    let name: String
    let sportType: String          // "Run", "Ride", "Swim", "WeightTraining", …
    let startLocal: String         // "2026-07-28T09:24:06"
    let distance: Double           // metres
    let movingTime: Int            // seconds
    let elapsedTime: Int
    let elevationGain: Double?
    let averageHeartrate: Double?
    let isTrainer: Bool?
    var maxHeartrate: Double?
    var gearId: String?          // joins to AthleteStore.shoes

    /// Fastest instant the recording observed, in metres per second.
    ///
    /// Stored for one reason: it is the only field that can contradict
    /// `distance`. Optional so rows cached before patch 123 still decode — they
    /// arrive as nil and `selfContradictoryDistance` stays false for them until
    /// the one-time re-fetch fills it in.
    var maxSpeed: Double?

    /// True only when the watts came from a meter. Strava also serves an
    /// ESTIMATE for rides without one, in the same field, and treating that as
    /// a measurement would put invented numbers into the load model. Optional
    /// so that activities cached before patch 27 still decode.
    var deviceWatts: Bool?
    var averageWatts: Double?

    // MARK: Where and when it actually happened
    //
    // APPENDED AT THE END OF THE PROPERTY LIST, DELIBERATELY.
    // A memberwise initialiser takes its arguments in declaration order, and
    // patch 123 spent a build failure learning that the diagnostic for getting
    // that wrong is "unable to type-check this expression in reasonable time".
    // New fields go last, where the call site cannot disagree with the
    // declaration. All three are optional so rows cached before patch 128 still
    // decode; they arrive nil and the weather row simply does not appear until
    // the one-time re-fetch fills them.

    /// The start instant in UTC, as Strava's ISO-8601 string.
    ///
    /// WHY `startLocal` COULD NOT DO THIS JOB
    /// -------------------------------------
    /// `startLocal` is wall-clock with no zone attached: "2026-06-14T06:30:00"
    /// is not a point in time, it is a point in time *somewhere*. Everything the
    /// app did with it until now was calendar arithmetic — which day is this,
    /// which week does it fall in — and for that the local reading is not merely
    /// adequate, it is the correct one. Asking an external service what the
    /// weather was requires the actual instant, and no amount of care with a
    /// local string produces one.
    var startUTC: String?

    /// Where it started. Nil for anything Strava recorded without GPS — a
    /// treadmill run, a Hevy circuit, a pool swim.
    var startLat: Double?
    var startLon: Double?

    /// The start instant, or nil for rows that predate the field.
    var startDateUTC: Date? {
        guard let startUTC else { return nil }
        return Self.iso8601.date(from: startUTC)
            ?? Self.iso8601NoFraction.date(from: startUTC)
    }

    /// Strava sends "2026-06-14T04:30:00Z". Two formatters because the seconds
    /// field has carried a fractional part in some responses and a single
    /// strict formatter returns nil for the other shape rather than coping.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// True when the weather where this happened is a fact about the session.
    ///
    /// A treadmill run and a Zwift ride happened in a room. Reporting the
    /// outdoor temperature against them would not be a small inaccuracy, it
    /// would be a category error — and it is exactly the kind that looks
    /// authoritative because it is rendered in the same card as the real ones.
    var isOutdoor: Bool {
        if isTrainer == true { return false }
        if sportType == "VirtualRide" || sportType == "VirtualRun" { return false }
        // A pool swim reports no coordinate at all, so this is belt and braces:
        // the guard below on `startLat` already excludes it.
        return startLat != nil && startLon != nil
    }

    /// Power worth using: present, and actually measured.
    var hasRealPower: Bool { deviceWatts == true }

    /// "yyyy-MM-dd" — the join key against plan sessions.
    var dayKey: String { String(startLocal.prefix(10)) }

    var km: Double { distance / 1000.0 }
    var minutes: Int { movingTime / 60 }

    var paceSecPerKm: Int? {
        guard km > 0.2 else { return nil }
        return Int((Double(movingTime) / km).rounded())
    }

    /// A recording that disagrees with itself about how far it went.
    ///
    /// WHY THIS IS A RULE AND NOT THREE MORE TABLE ENTRIES
    /// ---------------------------------------------------
    /// DataCorrections says a class of failure gets a rule and an individual bad
    /// recording gets a line. Three rides inside five days share one signature:
    ///
    ///   8 Nov 2025 09:36   52.8 km in 9:51    → 322 km/h avg, max 55.7
    ///   8 Nov 2025 11:24   56.7 km in 17:07   → 199 km/h avg, max 21.0
    ///  12 Nov 2025 16:56   91.5 km in 8:51    → 620 km/h avg, max 37.7
    ///
    /// All three are the ordinary 3–4 km commute: normal cadence, 73–117 kcal,
    /// a handful of metres of climb, a plausible maximum. A GPS fix jumped and
    /// wrote tens of phantom kilometres into the distance, which is also why
    /// each one collected seven to ten "personal records" on the way past.
    ///
    /// The test needs no plausibility constant and no judgement about cycling:
    /// a distance divided by the time it took CANNOT exceed the fastest instant
    /// the same file recorded. When it does, the file is arguing with itself,
    /// and the distance is the term that is wrong — the duration, the cadence
    /// and the calories all agree with a short commute.
    ///
    /// THE MARGIN. `max_speed` is smoothed and `moving_time` excludes stops, so
    /// an average taken over moving time can sit a little above a smoothed
    /// maximum on a short, stop-heavy record — one commute in the history does
    /// exactly that at 1.08×. The threshold is 1.5× so that record survives and
    /// only errors of a whole multiple trip it. The three above are 5.8×, 9.5×
    /// and 16.4×: an order of magnitude of clearance on both sides, which is
    /// what makes 1.5 a margin rather than a number chosen to fit the answer.
    var selfContradictoryDistance: Bool {
        guard let maxSpeed, maxSpeed > 0.5,
              movingTime > 0, distance > 0 else { return false }
        return (distance / Double(movingTime)) > maxSpeed * Self.speedContradictionFactor
    }

    static let speedContradictionFactor: Double = 1.5

    var paceLabel: String? {
        guard let p = paceSecPerKm else { return nil }
        return String(format: "%d:%02d /km", p / 60, p % 60)
    }

    /// Minutes past midnight — used to spot duplicate uploads.
    var startMinuteOfDay: Int {
        let t = startLocal.suffix(8)              // "09:24:06"
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    // MARK: Discipline mapping

    /// Which plan discipline this activity could satisfy, or nil if it's noise.
    var discipline: Discipline? {
        switch sportType {
        case "Run", "TrailRun", "VirtualRun":
            return .run
        case "Swim":
            return .swim
        case "Ride", "VirtualRide", "GravelRide", "MountainBikeRide", "EBikeRide":
            return .bike
        case "WeightTraining", "Workout", "Crossfit", "HighIntensityIntervalTraining":
            return .strength
        default:
            return nil                            // Walk, Kayaking, Rowing, …
        }
    }

    /// Whether this activity may satisfy a *planned* session.
    ///
    /// NOTE: everything is stored regardless — this only gates matching, so the
    /// daily commute never gets mistaken for the weekend aerobic ride. Anything
    /// failing this test still shows under "Extra movement" and still counts
    /// toward total volume.
    ///
    /// Thresholds derived from real history (Apr–Jul 2026): the daily bike
    /// commute is consistently 3.2–4.2 km, while every genuine training ride is
    /// over 20 km. 10 km separates them with a wide margin. Runs need almost no
    /// filtering — every recorded run was real training.
    var isPlanEligible: Bool {
        switch discipline {
        case .bike:     return km >= MatchRules.minRideKm
        case .run:      return km >= MatchRules.minRunKm
        case .swim:     return distance >= MatchRules.minSwimMetres
        case .strength: return movingTime >= MatchRules.minStrengthSeconds
        default:        return false
        }
    }

    /// Human label for the extras list — "Ride · commute", "Walk", "Kayaking".
    var extraLabel: String {
        if discipline == .bike && km < MatchRules.minRideKm { return "Ride · commute" }
        switch sportType {
        case "Walk":                       return "Walk"
        case "Hike":                       return "Hike"
        case "Kayaking":                   return "Kayaking"
        case "Rowing":                     return "Rowing"
        case "VirtualRide":                return "Zwift"
        default:                           return sportType
        }
    }

    var extraSymbol: String {
        switch sportType {
        case "Walk", "Hike":              return "figure.walk"
        case "Kayaking", "Rowing", "Canoeing", "StandUpPaddling":
                                          return "figure.outdoor.cycle"
        case "Ride", "VirtualRide", "EBikeRide":
                                          return "bicycle"
        default:                          return discipline?.symbol ?? "circle.dotted"
        }
    }
}

/// All tunable thresholds in one place, so they can be justified and changed.
enum MatchRules {
    /// Below this a ride is the commute, not a session.
    static var minRideKm: Double = 10.0
    static var minRunKm: Double = 1.5
    static var minSwimMetres: Double = 400
    static var minStrengthSeconds: Int = 5 * 60

    /// Two activities of the same sport starting within this many minutes of
    /// each other, with similar distance, are the same session uploaded twice.
    /// Real case: 21 Apr 2026 has two rides at an identical start time,
    /// 61.7 km and 60.4 km, from two devices.
    static var duplicateWindowMinutes: Int = 10
    static var duplicateDistanceTolerance: Double = 0.15   // ±15 %

    /// Earliest activity ever ingested.
    ///
    /// Moved back from 15 June (the Monday after Ironman Tours) to 1 January
    /// when the training-load engine was specified. CTL is a 42-day
    /// exponential average, so a block that starts on 27 July with six weeks of
    /// history behind it starts from a number that means nothing. From January
    /// the figure on day one is the decayed remains of a real Ironman build —
    /// which is the honest answer to "am I starting from fitness or from zero".
    ///
    /// MOVED AGAIN, TO 1 JULY 2025, IN PATCH 117
    /// ------------------------------------------
    /// The 52-week panel reaches back 52 weeks from the current Monday — 4
    /// August 2025 on the day this changed — and everything before 1 January
    /// was empty. Not thin: empty, because it was never ingested. The volume
    /// stack was drawing a third of its axis with nothing in it.
    ///
    /// The chart is the visible reason and the smaller one. The real one is the
    /// FITNESS CURVE. CTL ramps from zero at the cutoff, so the first six weeks
    /// of any window are a cold-start artefact rather than a measurement — the
    /// curve was climbing through January because the app had just started
    /// looking, not because fitness was being built. Today's figure does not
    /// change (42 days of τ means January washed out months ago); the left edge
    /// of the chart stops lying.
    ///
    /// 1 July rather than 4 August: it costs about one extra month of
    /// activities, it puts the whole Ironman peak inside the window rather than
    /// clipping its first week, and the 52-week window slides forward every
    /// Monday — a cutoff set exactly at the edge is one already at the edge.
    ///
    /// CAPACITY. `StravaClient.activities` pages `while page <= 10` at 100 per
    /// page and stops silently at 1000. At roughly 47 activities a month — the
    /// commutes dominate — 13 months is about 610. Comfortable, but the ceiling
    /// is real and it does not announce itself: any further move back should
    /// raise the page cap in the same patch.
    ///
    /// Changing this triggers a one-time full re-sync: ActivityStore compares
    /// it against `strava.cutoffUsed` and rebuilds when they differ. Ingest is
    /// keyed by activity id, so the rebuild merges rather than duplicates.
    /// `resetCache()` also clears DetailStore, so traces re-fetch on demand —
    /// expect route maps and split tables to be slow for a day.
    static var cutoffDayKey: String = "2025-07-01"

    /// Where the WEEK TAB's grid starts, which is deliberately not the ingest
    /// cutoff.
    ///
    /// They were the same key until patch 117 moved ingest back to July 2025.
    /// The Week tab is a plan-adherence view: it answers "what did I do against
    /// what was asked" week by week, and before the block there is nothing to
    /// answer against. Extending it with the ingest window added fifty rows of
    /// pre-plan weeks in front of week 1 — scrolling, not information.
    ///
    /// The charts keep the full history, because a fitness curve and a volume
    /// stack are exactly the views that need what came before. Two windows,
    /// each set to what its own screen is for.
    static var weekGridDayKey: String = "2026-01-01"

    /// The day Operation Sub-4 actually starts. Days before this have no
    /// planned sessions, so the UI shows recorded training on its own terms
    /// rather than as "extra".
    static var planStartDayKey: String = "2026-07-27"

    /// Floor for storing anything at all. Keeps accidental 20-second
    /// recordings out while still capturing every real walk and commute.
    static var minAnyActivitySeconds: Int = 120

    static func isPrePlan(_ dayKey: String) -> Bool { dayKey < planStartDayKey }
}

// MARK: - Strava API shapes

/// Strava's JSON uses snake_case and a few different field names.
struct StravaActivityDTO: Decodable {
    let id: Int64
    let name: String
    let sport_type: String?
    let type: String?
    let start_date_local: String
    let distance: Double?
    let moving_time: Int?
    let elapsed_time: Int?
    let total_elevation_gain: Double?
    let average_heartrate: Double?
    let max_heartrate: Double?
    let trainer: Bool?
    let gear_id: String?
    let device_watts: Bool?
    let average_watts: Double?
    let max_speed: Double?
    /// UTC. `start_date_local` is the same instant with the offset already
    /// applied and the offset then thrown away.
    let start_date: String?
    /// `[lat, lng]`, and an EMPTY ARRAY rather than null when Strava has no
    /// position — which is why this is read by index rather than destructured.
    let start_latlng: [Double]?

    func toActivity() -> Activity {
        Activity(
            id: String(id),
            name: name,
            sportType: sport_type ?? type ?? "Workout",
            startLocal: String(start_date_local.prefix(19)),
            distance: distance ?? 0,
            movingTime: moving_time ?? 0,
            elapsedTime: elapsed_time ?? moving_time ?? 0,
            elevationGain: total_elevation_gain,
            averageHeartrate: average_heartrate,
            isTrainer: trainer,
            maxHeartrate: max_heartrate,
            gearId: gear_id,
            // ORDER MATTERS. A memberwise initialiser takes its arguments in
            // DECLARATION order, and `maxSpeed` is declared above `deviceWatts`.
            // Passing it last did not produce an out-of-order diagnostic — it
            // produced "the compiler is unable to type-check this expression in
            // reasonable time" on a fourteen-argument literal, which points at
            // the wrong thing entirely. If this initialiser ever times out
            // again, check the order before breaking the expression up.
            maxSpeed: max_speed,
            deviceWatts: device_watts,
            averageWatts: average_watts,
            startUTC: start_date,
            startLat: (start_latlng?.count ?? 0) >= 2 ? start_latlng?[0] : nil,
            startLon: (start_latlng?.count ?? 0) >= 2 ? start_latlng?[1] : nil
        )
    }
}
