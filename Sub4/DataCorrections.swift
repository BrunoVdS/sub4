//
//  DataCorrections.swift
//  Sub4
//
//  A short, explicit list of recordings known to be wrong.
//
//  WHY A TABLE AND NOT A RULE
//  --------------------------
//  On 14 June 2026 the watch lost the athlete under the surface for most of the
//  Ironman Tours swim. Strava's `moving_time` for it reads 44:00 against an
//  elapsed 68:33 — twenty-four minutes of real swimming recorded as standing
//  still. Scored over 44 minutes, the biggest single session of the year enters
//  the fitness curve 56% short.
//
//  The obvious fix is a rule: "for swims, use elapsed time". It was rejected.
//  Elapsed time on a pool session includes the rest between sets, the stop to
//  fix goggles, and the two minutes on the side talking — 5 June is 1 250 m
//  across 43 minutes of elapsed time, and scoring all of it as swimming would
//  invent load that was never done. A rule fixing one session by damaging five
//  others is not a fix.
//
//  A threshold rule — "use elapsed when moving is more than a third short" —
//  fares no better. It would happen to catch only 14 June on today's data, and
//  it would be a constant chosen to produce a known answer, which is a hard-
//  coded exception wearing a formula's clothes. This file is the same decision
//  made honestly: one activity, named, with the reason next to it.
//
//  RULES FOR THIS FILE
//  -------------------
//  · Every entry names the session and says what was wrong with it.
//  · Every correction is FLAGGED where it is applied, never silent. A number
//    the app changed by hand and did not mention would be worse than the
//    number it replaced.
//  · Nothing goes in here that a general rule could handle correctly. This is
//    for individual bad recordings, not for a class of them — if a second
//    open-water swim loses time the same way, that is evidence for a rule and
//    the rule should be built instead.
//

import Foundation

enum DataCorrections {

    /// Activities whose `movingTime` is known to be wrong, and whose
    /// `elapsedTime` is the honest figure.
    ///
    /// Emptied in patch 122 when the 14 June swim moved to `officialTiming`,
    /// and refilled in patch 137 by the marathon leg of the same race.
    ///
    /// 18919775168 — 14 Jun 2026, Ironman Tours run leg, part 1. 7.43 km.
    /// 18919775352 — 14 Jun 2026, Ironman Tours run leg, part 2. 5.01 km.
    ///
    ///   THE OFFICIAL LEG IS 13.8 km IN 2:44:18, mat to mat, 14:28:25 to
    ///   17:12:42. The watch produced two files inside that window:
    ///
    ///     part 1   14:28:16 → 15:26:04   7.43 km   moving 55:23   elapsed 57:48
    ///     part 2   15:32:04 → 16:48:05   5.01 km   moving 54:24   elapsed 76:01
    ///
    ///   Two gaps account for the difference: six minutes between the files, and
    ///   twenty-five after the second one ends, during which he covered the last
    ///   1.35 km to the mat and stopped. He did not finish.
    ///
    ///   WHY ELAPSED AND NOT THE OFFICIAL SPLIT. A chip time exists here, which
    ///   would normally make this an `officialTiming` entry — but 2:44:18 belongs
    ///   to the LEG and this app scores activities. Dividing it between two files
    ///   means inventing an apportionment, and inventing one in order to fix a
    ///   recording is how a correction stops being a correction. Elapsed is the
    ///   honest alternative and it is not a guess: 8 029 seconds against the
    ///   leg's 9 858, recovering 24 of the 30 missing minutes, every second of it
    ///   a second the watch was actually running.
    ///
    ///   The remaining six minutes and 1.35 km stay missing and stay
    ///   uncorrected. The chart is short by that much and does not pretend
    ///   otherwise.
    ///
    ///   PACE IS UNAFFECTED — `PaceSeries` reads `movingTime`, not this — and
    ///   both runs are flagged off-the-bike anyway, so neither has ever set the
    ///   pace scale. What changes is LOAD: the biggest running day of the year
    ///   was being scored over 1:49 instead of 2:44.
    static let useElapsedTime: Set<String> = [
        "18919775168",
        "18919775352"
    ]

    // CHECKED AND DELIBERATELY NOT CORRECTED
    // --------------------------------------
    // 18929070111 — 14 Jun 2026, Ironman Tours bike leg.
    //   Official 5:53:36 mat to mat, 08:23:31 to 14:17:06, averaging 30.42 km/h.
    //   Strava has the same leg starting at 08:23:43 with 179.36 km and a moving
    //   time of 5:54:21 — twelve seconds and forty-five seconds apart
    //   respectively, or 0.2%.
    //
    // Written down so nobody re-checks it in six months. On a day when the swim
    // recording was thirty-one minutes short and the run thirty, the natural
    // assumption is that the whole file is suspect. It is not: the bike is the
    // one leg the watch got right, and both failures were in and out of the
    // water rather than in the device.
    //
    // A plain comment and not a doc comment, deliberately — a `///` block with
    // no declaration under it silently attaches itself to whatever comes next.

    /// A duration measured by somebody other than the watch.
    struct OfficialSplit {
        /// The authoritative duration, in seconds.
        let seconds: Int
        /// Where it came from, shown on the activity's detail page. Never
        /// optional: an overridden figure with no provenance is indistinguishable
        /// from a made-up one.
        let source: String
    }

    /// Chip times, which outrank every clock in the app.
    ///
    /// WHY THIS IS A THIRD MECHANISM AND NOT A SECOND ENTRY ABOVE
    /// ----------------------------------------------------------
    /// `useElapsedTime` picks between two numbers the watch produced. This
    /// replaces them both, because on 14 June neither survives arithmetic.
    ///
    /// 18919774557 — 14 Jun 2026, Ironman Tours swim.
    ///   Official: start 06:54:38, swim finish 08:09:23, split 1:14:46 — 4 486
    ///   seconds, average 1:59 per 100 m. Strava has the same session at
    ///   3 792.8 m with moving 44:00 and elapsed 68:33, and its start stamped
    ///   06:30:00. Take that at face value and the recording ends at 07:38:33,
    ///   half an hour before he left the water. The watch went off course and
    ///   stopped; every duration derived from it is short, and the earlier
    ///   correction to elapsed time was short by 6:13 rather than by 30:46.
    ///
    ///   The DISTANCE is left as recorded. The official display implies about
    ///   3 770 m at its stated pace, which is within 0.6% of Strava's 3 792.8 —
    ///   close enough that overriding it would be inventing precision. Our pace
    ///   therefore reads 1:58 against their 1:59: the same measurement, rounded
    ///   on a slightly different distance, and not worth forcing a number to
    ///   hide.
    static let officialTiming: [String: OfficialSplit] = [
        "18919774557": OfficialSplit(
            seconds: 4486,
            source: "IRONMAN Tours, bib 2021 — official swim split 1:14:46")
    ]

    static func official(_ a: Activity) -> OfficialSplit? { officialTiming[a.id] }

    /// The number of seconds a session should be SCORED over.
    ///
    /// Used by the load engine, the volume card's hours, sRPE, and the activity
    /// detail page — a correction that reached the fitness curve but not the
    /// number printed on the session itself is the kind of split-brain that
    /// makes a reader distrust both.
    ///
    /// PACE DOES NOT USE THIS, AND THAT IS THE POINT OF HAVING TWO MECHANISMS.
    /// `PaceSeries` consults `official` directly and ignores `useElapsedTime`,
    /// because the two tables mean different things to a pace:
    ///
    ///   officialTiming   a chip time is the real duration of a real distance,
    ///                    so a pace computed over it is the official pace.
    ///   useElapsedTime   elapsed includes standing still. A pace over it is
    ///                    not a slow pace, it is not a pace — the 14 June run
    ///                    legs would read 7:47 and 15:11 per kilometre against
    ///                    moving figures of 7:27 and 10:51, and neither pair
    ///                    describes running.
    ///
    /// An earlier version of this comment claimed the pace chart went through
    /// here. It never did, and it should not.
    static func scoringSeconds(_ a: Activity) -> Int {
        if let o = officialTiming[a.id] { return o.seconds }
        return useElapsedTime.contains(a.id) ? a.elapsedTime : a.movingTime
    }

    static func isCorrected(_ a: Activity) -> Bool {
        useElapsedTime.contains(a.id) || officialTiming[a.id] != nil
    }

    /// Recordings that are not ingested at all, keyed to the reason.
    ///
    /// A DIFFERENT KIND OF ENTRY FROM `useElapsedTime`
    /// -----------------------------------------------
    /// There the session was real and one of its two clocks was honest, so the
    /// correction picks the honest one. Here nothing in the recording can be
    /// trusted against anything else in it, and the first attempt at this —
    /// removing the session from the pace chart only — was the wrong shape. It
    /// left the app half-believing a recording: absent from one chart, present
    /// in the load curve, the zone totals and the volume stack, each of those
    /// needing its own future argument about whether to keep it. A recording
    /// either describes what happened or it does not.
    ///
    /// So the gate is at the door. `ActivityStore` applies this on ingest AND on
    /// load, so a row already sitting in activities.json disappears on the next
    /// launch without needing a re-sync.
    ///
    /// 16775873379 — 18 Dec 2025, "Lunch Swim", 400 m over 45:32 moving.
    ///   11:23 per 100 m against a normal 2:20, and three independent figures
    ///   agree the CLOCK is what is wrong. Eleven of the sixteen laps recorded
    ///   zero distance, including single blocks of 17 and 8 minutes. Average
    ///   heart rate 102, maximum 124. The session burned 147 kcal against 671
    ///   and 660 for the 2 200 m and 2 300 m swims either side of it — about
    ///   eleven minutes of work. Distance, calories and heart rate all describe
    ///   roughly ten minutes of swimming inside a forty-five minute pool visit.
    ///   Checked against the source by the athlete: faulty, not slow.
    ///
    ///   WHAT DROPPING IT COSTS, STATED. Roughly 23 TRIMP leaves that day, and
    ///   18 December 2025 now scores zero — the three rides on it are all
    ///   commutes and score nothing either. Defensible rather than merely
    ///   convenient: at 147 kcal and an average heart rate of 102, calling it a
    ///   rest day is closer to what happened than scoring three-quarters of an
    ///   hour of swimming would be. It is also seven months before the block,
    ///   so with CTL on a 42-day time constant it changes nothing that is on
    ///   screen today.
    ///
    /// Per the rules at the top of this file, a second recording failing this
    /// way is evidence for a rule — a plausibility band on seconds per 100 m —
    /// rather than a second line here.
    ///
    /// 18883849470 — Aug 2025, Romania. 199.2 km and 2,403 m of climbing across
    /// 694,865 seconds elapsed, which is 8.04 days, against 70,153 seconds
    /// moving. No heart rate. 62.5 W average, estimated rather than measured.
    /// Maximum speed 30.6 m/s — 110 km/h.
    ///
    ///   THE SEGMENT EFFORTS SETTLE IT. Thirty-five matched around the
    ///   Transfăgărășan and Poiana Mărului at sustained 55–66 km/h over tens of
    ///   kilometres: 29.6 km at 63 km/h, 20.8 km at 57 km/h, a "fastest 10k" at
    ///   85 km/h. Those are car speeds. The file contains some real riding, some
    ///   road transfer, and eight days of a holiday with the device never
    ///   stopped.
    ///
    ///   ADDED 5 AUGUST 2026, AND IT REVERSES PART OF THE 4 AUGUST DECISION.
    ///   That decision — ADR §12.12.5 — was to leave it refused by the database
    ///   and keep it in the app, with the consequence stated: the two disagree
    ///   permanently on this one activity. A day later that consequence had
    ///   grown three heads. Every import printed a raw SQLite CHECK failure on
    ///   the health screen; the refusal meant no `activity_alias`, so its trace
    ///   and its detail both reported "with no activity"; and one decision was
    ///   producing three lines that all read as faults on the screen whose job
    ///   is to show faults.
    ///
    ///   The deciding argument is the semantic verifier, two patches away,
    ///   whose whole job is that the database and the stores agree. A permanent
    ///   known disagreement would mean an exception list on the day it was
    ///   born. Excluding the activity in both places costs 199 km and 2,403 m
    ///   from August 2025 — a figure that was never real — and buys agreement.
    ///
    ///   It contributes no training load either way: no heart rate, and the
    ///   estimated power is refused by `PowerLoad`.
    /// NONISOLATED — patch 258. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// puts every member of this enum on the main actor by default, and the
    /// three importers that read this table are `nonisolated static func`.
    ///
    /// The isolation was never doing anything. This is a literal `[String:
    /// String]` fixed at compile time: nothing mutates it, so there is no race
    /// for an actor to prevent, and `[String: String]` is `Sendable`, so
    /// crossing the boundary costs nothing either. It was isolated because the
    /// build setting isolates everything, not because anyone decided it.
    nonisolated static let ignoredActivities: [String: String] = [
        "16775873379":
            "18 Dec 2025 swim — 400 m recorded across 45 minutes of moving "
            + "time, 11 of 16 laps logging no distance.",
        "18883849470":
            "Aug 2025 Romania ride — 8.04 days of elapsed time against 19.5 "
            + "hours moving, with segment efforts at car speeds. A holiday "
            + "with the recording left running, not a 199 km ride."
    ]

    static func isIgnored(_ a: Activity) -> Bool {
        isIgnored(id: a.id)
    }

    /// By id, for the stores that hold something ABOUT an activity rather than
    /// the activity itself — patch 256.
    ///
    /// `DetailStore` keys its traces and details by Strava id and never sees an
    /// `Activity`. Without this the detail and the trace of an excluded
    /// recording would still be offered to the importer, fail to resolve, and
    /// be counted as "with no activity" — which is true, and reads as a gap
    /// rather than as the decision it is.
    ///
    /// NONISOLATED — patch 258, and this is the one that has to be. Every
    /// caller is inside `Sub4Import`, which does its whole write on a database
    /// queue and is `nonisolated` throughout. Hopping to the main actor to read
    /// a compile-time dictionary from inside a write is not something to make
    /// work; it is something to not ask for.
    ///
    /// `isIgnored(_ a: Activity)` below stays on the main actor deliberately.
    /// It takes an `Activity`, its callers are the stores and the views, and
    /// nothing nonisolated has one to hand.
    nonisolated static func isIgnored(id: String) -> Bool {
        ignoredActivities[id] != nil
    }

    /// For the diagnostics row in Settings. Sorted, so the list does not
    /// reshuffle between launches.
    static var ignoredReasons: [String] {
        ignoredActivities.keys.sorted().compactMap { ignoredActivities[$0] }
    }
}
