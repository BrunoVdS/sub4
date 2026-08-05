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

    // MARK: Which clock `startLocal` was read from — patch 196, ADR-0003 §4.3
    //
    // STILL THE LAST STORED PROPERTIES IN THIS STRUCT, for the same reason as
    // the block above. Everything below this point is computed.
    //
    // WHY THIS IS URGENT RATHER THAN TIDY
    // -----------------------------------
    // `startLocal` is a wall clock with the offset applied and then discarded,
    // so this app has always known that a run started at 07:00 and never where.
    // At home that costs nothing. After a trip it is the difference between a
    // morning run and a run at some unknown hour, and the loss is silent — a
    // 07:00 Tokyo run and a 07:00 Antwerp run render identically.
    //
    // Strava sends both fields on every activity and always has. ADR-0002
    // retires Strava at Phase 4A and Apple Health carries neither, so this is
    // knowledge that exists today, costs nothing to capture today, and is gone
    // permanently the day the Strava connection ends. That is the whole reason
    // this is not waiting for Phase 3.
    //
    // Both nullable, and NULL means UNKNOWN — never Greenwich (ADR-0003 §6).
    // An offset of zero is a real place.

    /// The IANA identifier, validated — `"Asia/Tokyo"`, never Strava's
    /// `"(GMT+09:00) Asia/Tokyo"` display form. Nil when Strava sent nothing,
    /// or sent something this device's zone database does not recognise.
    var timeZoneIdentifier: String?

    /// Seconds east of UTC at the moment the activity started.
    ///
    /// THE AUTHORITY, per ADR-0003 §4.3: unambiguous, needs no zone database,
    /// and already resolved for daylight saving at that instant, where the
    /// identifier still has to be looked up and evaluated. The identifier is
    /// kept beside it for the abbreviation and for anything that later needs
    /// real zone rules.
    var startOffsetSeconds: Int?

    // NO COMMUTE FIELD HERE, and its absence is the decision — patch 251.
    //
    // Patch 250 put one here, read from Strava's own flag. It lasted one
    // patch. Two reasons it had to go, and the second is the one that matters:
    //
    //  1. ADR-0002 retires Strava. A classification whose source of truth is a
    //     field in a service this app is leaving has to be rebuilt the day that
    //     service goes away.
    //  2. Since patch 249 the sync re-reads every activity on every run and
    //     `ingest` replaces each row whole. Anything the athlete wrote onto an
    //     `Activity` would survive until the next launch and no longer.
    //
    // Authored data lives beside the fetched data, never inside it. See
    // `CommuteStore`.

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
    ///
    /// `nonisolated` — patch 207. `DayZones.from` reads this while building the
    /// day-zone map off the main actor. This target compiles with default
    /// MainActor isolation, and a struct's COMPUTED members inherit that while
    /// its stored properties do not — which is why `startOffsetSeconds` beside
    /// it needed nothing and this did.
    nonisolated var dayKey: String { String(startLocal.prefix(10)) }

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

    // MARK: Saying which clock — ADR-0003 §4.3

    /// `"09:24"`, or `"09:24 JST"` when the activity happened on a different
    /// clock from the one the reader is standing on.
    ///
    /// This is the display rule, and the whole of it. A zone marker on all 660
    /// activities would be noise; a zone marker on none of them loses the only
    /// interesting cases.
    var startTimeLabel: String { timeLabel(forReaderIn: .current) }

    /// The same thing with the reader's zone passed in.
    ///
    /// SPLIT FROM THE PROPERTY SO IT CAN BE TESTED. `TimeZone.current` is the
    /// simulator's zone and cannot be changed from inside a test, so a rule
    /// written against it directly can only be asserted in the one zone CI
    /// happens to run in — which for a feature whose entire subject is other
    /// zones is no assertion at all.
    func timeLabel(forReaderIn zone: TimeZone) -> String {
        let time = String(startLocal.dropFirst(11).prefix(5))
        guard let suffix = zoneSuffix(forReaderIn: zone) else { return time }
        return "\(time) \(suffix)"
    }

    /// The abbreviation to append, or nil when there is nothing to say.
    ///
    /// THE COMPARISON IS AGAINST THE DEVICE'S OFFSET *AT THAT INSTANT*, and
    /// getting this wrong is the obvious bug in this feature.
    ///
    /// The naive version compares the stored offset against
    /// `TimeZone.current.secondsFromGMT()` — the device's offset NOW. Brussels
    /// is +2 in July and +1 in December, so read that way, every summer run
    /// sprouts a zone suffix once the clocks go back, and every winter run
    /// sprouts one all summer. Roughly half the history would be labelled as
    /// foreign, and the labels would change twice a year on their own.
    ///
    /// The question being asked is "did the clock this was recorded on differ
    /// from the clock the reader keeps", and that has to be evaluated at the
    /// moment of the activity — where DST is already resolved on both sides.
    ///
    /// COMPARED BY OFFSET, NOT BY IDENTIFIER, for the same reason: a run in
    /// Paris and a run in Brussels are on the same clock, and saying "CET" on
    /// one of them would be true and useless.
    var zoneSuffix: String? { zoneSuffix(forReaderIn: .current) }

    func zoneSuffix(forReaderIn zone: TimeZone) -> String? {
        // Requires the instant. In practice every row carrying a zone also
        // carries `startUTC` — the backfill that fetches one fetches both — so
        // this guard is a correctness statement rather than a live path.
        guard let instant = startDateUTC,
              let activityOffset = offsetSeconds(at: instant) else { return nil }
        guard activityOffset != zone.secondsFromGMT(for: instant) else { return nil }
        return zoneAbbreviation(at: instant, offset: activityOffset)
    }

    /// The offset actually in force, preferring the stored one.
    func offsetSeconds(at instant: Date) -> Int? {
        if let startOffsetSeconds { return startOffsetSeconds }
        guard let id = timeZoneIdentifier, let tz = TimeZone(identifier: id) else { return nil }
        return tz.secondsFromGMT(for: instant)
    }

    /// True when Strava had a position to work from, which is the only
    /// circumstance in which `timeZoneIdentifier` names a real place.
    ///
    /// WHY THIS EXISTS — FOUND IN THE PATCH 196 BACKFILL, IN THE REAL DATA.
    ///
    /// Backfilling 661 activities produced these identifiers:
    ///
    ///     476 Europe/Brussels    38 Europe/Berlin      38 Europe/Paris
    ///      28 Africa/Blantyre    27 Africa/Algiers     27 Europe/Istanbul
    ///      24 Europe/Bucharest    3 Europe/Amsterdam
    ///
    /// The two African zones are not trips. `Africa/Algiers` is the
    /// alphabetically first IANA zone at +1 and `Africa/Blantyre` the first at
    /// +2, neither observes daylight saving, and cross-referencing showed all
    /// 55 of them have no coordinate: 43 pool swims, six gym sessions, five
    /// workouts and one indoor ride. Strava fills in a representative zone for
    /// the offset when it has no position to geolocate.
    ///
    /// So the identifier is not always a place. The OFFSET always is correct —
    /// it is what the uploading device reported — which is why ADR-0003 §4.3
    /// makes the offset the authority, and why nothing about the comparison
    /// rule is affected.
    ///
    /// Six no-GPS activities did come back `Europe/Brussels`, so the fill-in is
    /// not purely mechanical and a real identifier cannot be told from a
    /// substituted one at ingest. Having a coordinate is the proxy that can be
    /// checked, and it is conservative in the right direction: a genuine pool
    /// swim in Brussels loses `CEST` and gains `GMT+2`, which is less pretty
    /// and never wrong.
    nonisolated var hasStartPosition: Bool { startLat != nil && startLon != nil }

    /// `"JST"` where the system knows a real abbreviation and the identifier
    /// can be trusted, `"GMT+9"` where either is missing.
    ///
    /// Apple returns a genuine short name for some zones and a `GMT±n` string
    /// for others, and which is which is an ICU detail this app does not
    /// control. Rather than promise `JST` and print `GMT+9` in half the cases,
    /// the fallback is computed from the offset — so the label is always
    /// correct and sometimes prettier.
    func zoneAbbreviation(at instant: Date, offset: Int) -> String {
        // The coordinate check is not defensive tidiness — without it a July
        // pool swim in Antwerp, read from Tokyo in September, prints "CAT" and
        // tells you it happened in Malawi. It cannot misfire at home, because
        // no suffix is shown at all when the offsets agree, which is exactly
        // why it would have shipped unnoticed.
        if hasStartPosition,
           let id = timeZoneIdentifier, let tz = TimeZone(identifier: id) {
            let style: NSTimeZone.NameStyle = tz.isDaylightSavingTime(for: instant)
                ? .shortDaylightSaving : .shortStandard
            if let name = tz.localizedName(for: style, locale: Locale(identifier: "en_US_POSIX")),
               !name.isEmpty, !name.hasPrefix("GMT"), !name.hasPrefix("UTC") {
                return name
            }
        }
        return Self.gmtLabel(offset)
    }

    /// `"GMT+9"`, `"GMT-4"`, `"GMT+5:45"` — Kathmandu is why the minutes case
    /// is here rather than assumed away.
    nonisolated static func gmtLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "GMT\(sign)\(h)" : String(format: "GMT%@%d:%02d", sign, h, m)
    }

    /// Strava sends `"(GMT+09:00) Asia/Tokyo"`. Only the identifier is worth
    /// keeping — the parenthesised part is a rendering of `utc_offset`, which
    /// is already stored properly, and it is a display string rather than data.
    ///
    /// VALIDATED BEFORE IT IS STORED. An identifier this device cannot resolve
    /// is worth nothing to the abbreviation lookup and would sit in the column
    /// looking like information, so it is discarded and the column reads NULL —
    /// which is the honest answer under §6. The offset survives either way, and
    /// the offset is the authority.
    nonisolated static func zoneIdentifier(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var candidate = raw
        if let close = raw.range(of: ") ") {
            candidate = String(raw[close.upperBound...])
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, TimeZone(identifier: trimmed) != nil else { return nil }
        return trimmed
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
    ///
    /// `nonisolated` since patch 219: `Sub4Import` reads it away from the main
    /// actor, and this is a pure switch on a stored string. The same finding as
    /// patch 207 — a computed member inherits the type's isolation even when it
    /// touches nothing that needs it, while the stored properties beside it do
    /// not, which is why `a.distance` compiled and `a.discipline` did not.
    nonisolated var discipline: Discipline? {
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

    /// What the app would guess with nobody to ask — patch 251.
    ///
    /// PURE, and kept pure on purpose. It reads nothing but this activity, so
    /// it can be tested against a distance and reasoned about without a store
    /// in the room. `isCommuteRide` is the impure one and says so.
    ///
    /// The threshold comes from thirteen months of real history: the daily bike
    /// commute is 3.2–4.2 km and every genuine training ride is over 20 km. It
    /// is right almost every time, and "almost" is why there is a toggle — on
    /// 16 July 2026 a 9,985.9 m ride was a commute by fourteen metres.
    var commuteByDistance: Bool {
        discipline == .bike && km < MatchRules.minRideKm
    }

    /// Whether this ride is a commute — the ONE definition, patch 251.
    ///
    /// The athlete's answer if he has given one, the distance rule if he has
    /// not. `CommuteStore` holds the answers; `nil` there means "not asked",
    /// which is a third state and not a `false`.
    ///
    /// IMPURE, and there is no way around it that is worth the cost. It reads a
    /// singleton, so it cannot be tested without one, and the alternative —
    /// threading a decision dictionary through `extraLabel`, `isPlanEligible`
    /// and fourteen call sites — would put the store in the signature of half
    /// the app to avoid saying so here. `DataCorrections.isIgnored` set this
    /// precedent and `ActivityStore.isKept` already depends on it.
    ///
    /// Both call sites route through this, so they cannot drift apart again.
    var isCommuteRide: Bool {
        guard discipline == .bike else { return false }
        return CommuteStore.shared.decision(for: id) ?? commuteByDistance
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
        // `!isCommuteRide` and nothing else — patch 251. The distance floor
        // used to be repeated here as well; it is not, because the athlete's
        // answer has to be able to win in BOTH directions. Marking a 4 km ride
        // as "not a commute" now makes it plan-eligible, which is the point of
        // a toggle: patch 250's asymmetry existed because Strava's flag was a
        // side-effect of somebody else's app, and an answer given here is not.
        case .bike:     return !isCommuteRide
        case .run:      return km >= MatchRules.minRunKm
        case .swim:     return distance >= MatchRules.minSwimMetres
        case .strength: return movingTime >= MatchRules.minStrengthSeconds
        default:        return false
        }
    }

    /// Human label for the extras list — "Ride · commute", "Walk", "Kayaking".
    var extraLabel: String {
        if isCommuteRide { return "Ride · commute" }
        switch sportType {
        case "Walk":                       return "Walk"
        case "Hike":                       return "Hike"
        case "Kayaking":                   return "Kayaking"
        case "Rowing":                     return "Rowing"
        case "VirtualRide":                return "Zwift"
        default:                           return sportType
        }
    }

    /// The extras-row TITLE — patch 252.
    ///
    /// A single commute used to be titled with its Strava name ("Morning Ride")
    /// while two or more collapsed into a row titled "Commutes". Same
    /// classification, two different words, and the difference was how many
    /// happened to be on one day. `MergedExtra.title` says "Commutes"; this is
    /// the same sentence in the singular.
    ///
    /// Everything else keeps its own name, because a walk called "Lunch Walk"
    /// is better identified by that than by the word "Walk".
    var extraTitle: String { isCommuteRide ? "Commute" : name }

    /// The extras-row CAPTION, which must never repeat the title above it.
    ///
    /// For a commute the title already says what it is, so the caption says
    /// WHEN — matching the merged row's "3 commutes · 07:26 – 17:43". For
    /// anything else it is the kind, which the name usually does not carry.
    var extraCaption: String { isCommuteRide ? startTimeLabel : extraLabel }

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
///
/// `nonisolated` — patch 199.
///
/// This target compiles with default MainActor isolation, so a plain `struct`
/// gets it, and with it a main-actor-isolated conformance to `Decodable`.
/// `JSONDecoder` is nonisolated and may call `init(from:)` on any thread, so
/// Swift 6.2 warns that the conformance cannot be used there. Today it is a
/// warning; the direction of travel makes it an error.
///
/// Marking it nonisolated is also right on the merits rather than a way to
/// quiet a diagnostic. This is a transfer object with no identity, no state and
/// no relationship to the UI. Isolating it to the main actor says the opposite
/// of everything true about it, and it is the reason the decode of a
/// seven-page, 660-activity backfill currently happens on the main actor —
/// see the note on `activities(after:token:)`.
nonisolated struct StravaActivityDTO: Decodable {
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

    /// `"(GMT+09:00) Asia/Tokyo"` — a display string with the identifier on the
    /// end. Occasionally a bare identifier. Parsed by `Activity.zoneIdentifier`.
    let timezone: String?

    /// Seconds east of UTC. A DOUBLE in Strava's JSON — `32400.0`, not
    /// `32400` — and decoding it as `Int` fails the whole activity, taking
    /// every other field with it. Decoded as sent, narrowed on the way in.
    let utc_offset: Double?

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
            startLon: (start_latlng?.count ?? 0) >= 2 ? start_latlng?[1] : nil,
            // LAST, after `startLon`, matching the declaration order in
            // `Activity`. See the note above — this initialiser is the one that
            // times out rather than complaining when the order is wrong.
            timeZoneIdentifier: Activity.zoneIdentifier(from: timezone),
            startOffsetSeconds: utc_offset.map { Int($0) }
        )
    }
}
