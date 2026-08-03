//
//  DayZones.swift
//  Sub4
//
//  Which clock a training day was lived on — patch 198, ADR-0003 §4.5.
//
//  WHAT WAS WRONG
//  --------------
//  `HealthStore` asks HealthKit for daily totals with
//  `anchorDate: Calendar.current.startOfDay(for: start)`, and labels the
//  buckets with `DayKey.formatter`, which sets no `timeZone`. Both therefore
//  use the device's zone AT THE MOMENT OF THE QUERY.
//
//  While the phone is in Japan those days bucket by JST. On landing back in
//  Belgium the same historical samples re-bucket by CEST — a seven-hour shift
//  applied RETROACTIVELY. Numbers that were on screen last week are different
//  this week, with nothing to say why, and the day boundaries move under a
//  month of training that is already in the past.
//
//  THE DECISION: FREEZE AT THE ZONE IT HAPPENED IN
//  ----------------------------------------------
//  A day in Japan stays a Japanese day forever. 14 September keeps the step
//  count it had while you were standing in it.
//
//  The alternative — re-bucket by wherever the phone is now — is what happens
//  today, and its defence is that it needs no extra state. Its cost is that
//  history is not history: every figure is provisional, and a block review in
//  February reads different numbers from the ones the block was lived with.
//
//  WHERE THE ZONE COMES FROM, AND WHY THERE IS NO NEW STORE
//  -------------------------------------------------------
//  Freezing needs a per-day zone that is the same on every launch. Health data
//  is never written down — `Retention.forThisSessionOnly` — so there is nothing
//  to freeze IN; what has to be deterministic is the recomputation.
//
//  The obvious answer is a persisted log of the device's zone per day. It is
//  also unnecessary, because patch 196 already put an offset on all 661
//  activities and those ARE persisted. An activity is direct evidence of where
//  its athlete was that morning, recorded at the time, and it survives a
//  reinstall.
//
//  So the zone for a day is the offset of the nearest activity on or before it.
//  Rest days inherit from the last session, which is right — you did not fly
//  home to sleep. The failure mode is a boundary day with no recording: land on
//  the 7th, first run on the 8th, and the 7th buckets as home. One day, at each
//  end of a trip, deterministically — which is the property that was asked for.
//  A new store would fix that one day and add state that can disagree with the
//  activities.
//
//  FIXED OFFSETS, NOT IDENTIFIERS
//  ------------------------------
//  `TimeZone(secondsFromGMT:)`, deliberately, and not `TimeZone(identifier:)`.
//  A named zone is re-evaluated against whatever tzdata the device carries, and
//  governments amend zone rules several times a year. A fixed offset is the
//  clock that was actually on the wall and cannot be revised later. Freezing
//  against a mutable rule set would not be freezing.
//

import Foundation

nonisolated struct DayZones: Sendable, Equatable {

    /// A day on which the offset became something new. Only changes are stored:
    /// a year at home is one entry, and a trip is two.
    struct Change: Sendable, Equatable {
        let dayKey: String
        let offsetSeconds: Int
        /// Carried only from an activity that had a coordinate — patch 197's
        /// rule, for patch 197's reason. Strava substitutes a representative
        /// zone for the offset when it has no position, so `Africa/Blantyre`
        /// on a pool swim would otherwise make a day at home announce itself
        /// as Central Africa Time.
        let identifier: String?
    }

    /// Ascending by `dayKey`.
    let changes: [Change]

    /// For days after the last activity — including today. The device's own
    /// offset is the right answer there: nothing has been recorded yet, and
    /// live readings are being taken on the clock the phone is on.
    let trailingOffsetSeconds: Int

    // MARK: Building

    static func from(activities: [Activity],
                     deviceOffset: Int = TimeZone.current.secondsFromGMT()) -> DayZones {
        // One entry per day, latest activity of that day winning. Two sessions
        // on a travel day disagree; the later one is the one that says where
        // the day ended.
        var byDay: [String: (offset: Int, id: String?, startLocal: String)] = [:]
        for a in activities {
            guard let offset = a.startOffsetSeconds else { continue }
            let day = a.dayKey
            if let existing = byDay[day], existing.startLocal >= a.startLocal { continue }
            byDay[day] = (offset, a.hasStartPosition ? a.timeZoneIdentifier : nil, a.startLocal)
        }

        var out: [Change] = []
        var previous: Int?
        for day in byDay.keys.sorted() {
            let entry = byDay[day]!
            if entry.offset != previous {
                out.append(Change(dayKey: day, offsetSeconds: entry.offset,
                                  identifier: entry.id))
                previous = entry.offset
            }
        }
        return DayZones(changes: out, trailingOffsetSeconds: deviceOffset)
    }

    // MARK: Asking

    /// The offset in force on a day.
    ///
    /// Before the first known activity the earliest recorded offset is used
    /// rather than the device's. A day in January 2025 was not lived on today's
    /// clock, and the nearest evidence is better than the nearest guess.
    func offset(forDay dayKey: String) -> Int {
        guard let first = changes.first else { return trailingOffsetSeconds }
        if dayKey < first.dayKey { return first.offsetSeconds }
        var current = first.offsetSeconds
        for change in changes {
            if change.dayKey > dayKey { break }
            current = change.offsetSeconds
        }
        return current
    }

    func zone(forDay dayKey: String) -> TimeZone {
        TimeZone(secondsFromGMT: offset(forDay: dayKey)) ?? TimeZone(identifier: "UTC")!
    }

    /// The change in force on a day, so a caller can reach the identifier too.
    func change(forDay dayKey: String) -> Change? {
        guard let first = changes.first else { return nil }
        if dayKey < first.dayKey { return first }
        var current = first
        for change in changes {
            if change.dayKey > dayKey { break }
            current = change
        }
        return current
    }

    // MARK: Saying so
    //
    // The freeze on its own is silent: a Japanese day keeps its own step count
    // and looks exactly like a Belgian one. That is correct and incomplete —
    // the number is right and the reader has no way to know it is counted from
    // a different midnight. So a day on another clock says which.
    //
    // Same rule as the activity card in patch 196: shown only when it DIFFERS
    // from the reader's clock, and compared at the day itself rather than
    // against the device's offset now, so daylight saving does not mark half
    // the year as foreign.

    /// `"JST"`, `"GMT+9"`, or nil when the day was on the reader's own clock.
    func marker(forDay dayKey: String, readerIn zone: TimeZone = .current) -> String? {
        guard let noon = DayKey.noon(dayKey, in: self.zone(forDay: dayKey)) else { return nil }
        let dayOffset = offset(forDay: dayKey)
        guard dayOffset != zone.secondsFromGMT(for: noon) else { return nil }

        // Midday rather than midnight, deliberately: a reader whose own zone
        // changes at midnight would otherwise be compared against whichever
        // side of the change the boundary instant happened to land on.
        if let id = change(forDay: dayKey)?.identifier,
           let named = TimeZone(identifier: id) {
            let style: NSTimeZone.NameStyle = named.isDaylightSavingTime(for: noon)
                ? .shortDaylightSaving : .shortStandard
            if let name = named.localizedName(for: style, locale: Locale(identifier: "en_US_POSIX")),
               !name.isEmpty, !name.hasPrefix("GMT"), !name.hasPrefix("UTC") {
                return name
            }
        }
        return Activity.gmtLabel(dayOffset)
    }

    /// True when this day's totals are counted from a different midnight than
    /// the reader's own. What a view checks before drawing the marker.
    func isForeign(dayKey: String, readerIn zone: TimeZone = .current) -> Bool {
        marker(forDay: dayKey, readerIn: zone) != nil
    }

    /// True when the whole history is on one clock, which is the case on a
    /// device that has never left home. Lets the caller keep the single-query
    /// path rather than paying for the general one.
    var isUniform: Bool { changes.count <= 1 }

    // MARK: Runs

    /// A stretch of days sharing one offset, as real instants.
    struct Run: Sendable, Equatable {
        let start: Date
        let end: Date
        let offsetSeconds: Int
        var zone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(identifier: "UTC")! }
    }

    /// The window split into stretches that each sit on one clock.
    ///
    /// WHY THE BOUNDARY IS WHERE IT IS, which is the one judgement in this file.
    ///
    /// Each run begins at midnight of its first day IN ITS OWN ZONE. Flying
    /// Brussels to Tokyo on the 6th, that puts the start of the 7th at 15:00Z —
    /// seven hours before Brussels' own midnight on the 7th, at 22:00Z. The two
    /// runs would overlap by seven hours and every sample in them would be
    /// counted twice, once under the 6th and once under the 7th.
    ///
    /// So each run ENDS where the next one begins, rather than at its own
    /// midnight. The travel day is short — it ends when you cross — and the
    /// samples partition exactly. That is also the truer description of the day:
    /// nobody gets 31 hours on the 6th of September.
    func runs(from start: Date, to end: Date) -> [Run] {
        guard start < end else { return [] }
        guard !isUniform else {
            return [Run(start: start, end: end,
                        offsetSeconds: offset(forDay: DayKey.key(start, in: zone(forDay: DayKey.key(start)))))]
        }

        // Boundaries, in order: the window start, then the first midnight of
        // every day on which the offset changed and which falls inside it.
        var boundaries: [(at: Date, offset: Int)] = [
            (start, offset(forDay: DayKey.key(start, in: zone(forDay: DayKey.key(start)))))
        ]
        for change in changes {
            let z = TimeZone(secondsFromGMT: change.offsetSeconds) ?? TimeZone(identifier: "UTC")!
            guard let midnight = DayKey.startOfDay(change.dayKey, in: z),
                  midnight > start, midnight < end else { continue }
            boundaries.append((midnight, change.offsetSeconds))
        }
        boundaries.sort { $0.at < $1.at }

        // COALESCED, and this was a bug rather than an optimisation.
        //
        // `changes` records the first day of every stretch, INCLUDING the very
        // first one — the earliest activity's own day. For a window that opens
        // before it, that boundary carries the offset the window had already
        // started on, so it cuts one run into two identical halves. The buckets
        // come out the same, which is why it survived `runsPartitionTheWindow`,
        // and it costs a whole extra HealthKit query for nothing.
        //
        // Adjacent boundaries on one clock are one stretch.
        var coalesced: [(at: Date, offset: Int)] = []
        for b in boundaries {
            if let last = coalesced.last, last.offset == b.offset { continue }
            coalesced.append(b)
        }

        var out: [Run] = []
        for (i, b) in coalesced.enumerated() {
            let runEnd = i + 1 < coalesced.count ? coalesced[i + 1].at : end
            guard b.at < runEnd else { continue }
            out.append(Run(start: b.at, end: runEnd, offsetSeconds: b.offset))
        }
        return out
    }
}
