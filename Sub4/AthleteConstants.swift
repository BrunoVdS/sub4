//
//  AthleteConstants.swift
//  Sub4
//
//  The numbers every load figure will be divided by.
//
//  WHY THIS EXISTS BEFORE ANY METRIC DOES
//  --------------------------------------
//  Banister TRIMP is an exponential function of ΔHR = (HR − rest) / (max − rest).
//  Both ends of that fraction are estimates, and both sit under an exponent — a
//  wrong HR_max does not shift the load a little, it bends the whole curve. The
//  literature is blunt about the usual mistake: never 220 − age, whose error is
//  10–20 bpm.
//
//  So the constants are built, shown and argued with FIRST, before a single
//  load is computed. Nothing downstream is trustworthy until the numbers on
//  this screen are ones you recognise.
//
//  HR_MAX IS GLOBAL. HR_REST IS NOT.
//  ---------------------------------
//  These two behave differently and the model reflects it.
//
//  HR_max is a physiological property we are ESTIMATING. When a harder effort
//  reveals a higher maximum, the old figure was not "the value back then" — it
//  was wrong, and every load computed under it was wrong with it. So there is
//  one HR_max, it applies to all history, and raising it invalidates every
//  computed load. That is what `version` is for.
//
//  HR_rest genuinely changes. It is one of the cleanest signals of accumulating
//  fitness, and using today's figure to score January would misprice seven
//  months. So it is stored per calendar month, and a January activity is scored
//  against January's resting rate.
//
//  WHY MONTHS RATHER THAN A ROLLING WINDOW
//  ---------------------------------------
//  The source spec asks for a rolling 30-day 10th percentile. Monthly buckets
//  are used instead because they are inspectable — you can look at the list and
//  see the number that scored a given session. The cost of the approximation is
//  small enough to write down: a 2 bpm error in resting HR at HR 150, max 190
//  moves ΔHR by 0.6% and TRIMP by about 1.3%. That is far inside the error of
//  the wrist that measured the heart rate in the first place.
//
//  THE TENTH PERCENTILE, NOT THE MINIMUM
//  -------------------------------------
//  A single low reading is a measurement artefact — a nap, a cold morning, a
//  bad contact. The 10th percentile of a month's daily values is the resting
//  rate you actually live at, and it needs five days before it is computed at
//  all.
//

import Foundation
import Observation

// MARK: - The stored value

struct AthleteConstants: Codable, Hashable {

    /// Yours, entered by hand. Beats anything derived, always.
    var hrMaxOverride: Int?

    /// The highest heart rate seen in any activity in the observation window.
    var hrMaxObserved: Int?
    var hrMaxObservedOn: String?          // dayKey — so you can go and look at it
    var hrMaxObservedName: String?

    /// Resting HR by calendar month, "yyyy-MM" → bpm.
    var restByMonth: [String: Int] = [:]

    /// Used when Health has nothing for a month, and there is no neighbour
    /// close enough to borrow from.
    var restOverride: Int?

    /// Banister's sex weighting: 1.92 male, 1.67 female. Not a preference —
    /// it is the exponent's coefficient, and the wrong one rescales everything.
    var sexCoefficient: Double = 1.92

    /// Bumped ONLY when HR_max changes.
    ///
    /// HR_max is global, so a change to it invalidates every load ever
    /// computed — one counter is exactly the right shape for that. Resting HR
    /// is not: the current month gains a reading every day and its percentile
    /// drifts, and a shared counter would mark January stale each morning,
    /// which makes the counter useless as a staleness filter. Per-day staleness
    /// for resting HR is detected by storing the resting figure ON the load row
    /// and comparing it, so no second counter is needed.
    var version: Int = 1

    /// The value in force. Override first — it is the only figure a human
    /// asserted rather than the app inferred.
    var hrMax: Int? { hrMaxOverride ?? hrMaxObserved }

    var hrMaxSource: String {
        if hrMaxOverride != nil { return "your value" }
        if hrMaxObserved != nil { return "highest recorded" }
        return "unknown"
    }
}

// MARK: - The store

@Observable
final class ConstantsStore {

    static let shared = ConstantsStore()

    private(set) var c = AthleteConstants()

    /// Set when the derived maximum rises. Not an error — a signal that every
    /// load computed under the old figure needs recomputing, and that the new
    /// figure should be looked at before it is believed.
    private(set) var hrMaxRoseFrom: Int?

    private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("constants.json")
        load()
    }

    // MARK: Plausibility
    //
    // Bounds, not guesses. A heart rate of 260 is a sensor artefact and a
    // maximum of 110 is a strap that fell off; either, taken as HR_max, would
    // quietly rescale the entire block.

    static let hrMaxPlausible = 120...230
    static let hrRestPlausible = 30...90
    /// Below this spread the ΔHR denominator is too small to divide by, and a
    /// single noisy sample swings the result wildly.
    static let minSpread = 40

    // MARK: Reading

    /// Resting HR to use for a given day.
    ///
    /// That day's month first; then the nearest month within three, because a
    /// gap in Health is a gap in wearing the watch, not a change in physiology;
    /// then your override. nil means we genuinely do not know, and nothing
    /// should be computed for that day.
    func hrRest(on dayKey: String) -> Int? {
        let month = String(dayKey.prefix(7))
        if let v = c.restByMonth[month] { return v }
        for step in 1...3 {
            if let v = c.restByMonth[Self.month(month, offsetBy: -step)] { return v }
            if let v = c.restByMonth[Self.month(month, offsetBy: step)] { return v }
        }
        return c.restOverride
    }

    // View-facing accessors, so no screen has to reach through `c` into the
    // stored shape. The stored shape is free to change; these are the contract.
    var hrMax: Int? { c.hrMax }
    var version: Int { c.version }
    var hrMaxSource: String { c.hrMaxSource }
    var hrMaxObserved: Int? { c.hrMaxObserved }
    var hrMaxObservedOn: String? { c.hrMaxObservedOn }
    var hrMaxObservedName: String? { c.hrMaxObservedName }
    var hasHRMaxOverride: Bool { c.hrMaxOverride != nil }
    var sexCoefficient: Double { c.sexCoefficient }

    /// The floor of the top heart-rate zone, as configured in Strava.
    ///
    /// A derived maximum BELOW it is a contradiction — the athlete has said
    /// they train above that number, so the highest figure ever recorded cannot
    /// be their maximum. It means the hardest efforts in the window were not
    /// maximal, or the wrist under-read, and every load figure is inflated by
    /// the gap. Flagged rather than corrected: an estimate from zone boundaries
    /// would be another guess wearing the same units.
    var hrMaxContradictsZones: Bool {
        guard let max = hrMax, let floor = AthleteStore.shared.topZoneFloor
        else { return false }
        return max <= floor
    }

    /// Whether the constants are complete enough for the engine to run at all.
    ///
    /// Tested against the HIGHEST monthly resting rate, not the lowest — that
    /// is the month with the smallest spread, and therefore the one that fails
    /// first. Testing the lowest would report "complete" while some month in
    /// the middle of the block still could not be scored.
    var isComplete: Bool {
        guard let max = hrMax else { return false }
        // The widest of the resting figures in play, because that is the
        // narrowest spread. `hrRest(on:)` falls through to the override for any
        // month it cannot cover, so the override has to be in this comparison —
        // otherwise this reports "complete" while some month cannot be scored.
        let candidates = [c.restByMonth.values.max(), c.restOverride].compactMap { $0 }
        guard let rest = candidates.max() else { return false }
        return max - rest >= Self.minSpread
    }

    var monthsCovered: Int { c.restByMonth.count }

    /// Changes whenever any month's resting rate does. The load engine keys its
    /// recompute on this rather than on `version`, which deliberately only
    /// tracks HR_max.
    var restFingerprint: String {
        c.restByMonth.keys.sorted()
            .map { "\($0):\(c.restByMonth[$0] ?? 0)" }
            .joined(separator: ",")
            + "|\(c.restOverride ?? 0)"
    }

    /// "2026-01 … 2026-07" — what the resting series actually spans.
    var restSpanLabel: String {
        let keys = c.restByMonth.keys.sorted()
        guard let first = keys.first, let last = keys.last else { return "none" }
        return first == last ? first : "\(first) … \(last)"
    }

    /// The months between the history cutoff and today with no resting rate.
    func missingMonths(since cutoff: String, today: String = DayKey.key()) -> [String] {
        var out: [String] = []
        var m = String(cutoff.prefix(7))
        let end = String(today.prefix(7))
        var guardCount = 0
        while m <= end, guardCount < 240 {
            if c.restByMonth[m] == nil { out.append(m) }
            m = Self.month(m, offsetBy: 1)
            guardCount += 1
        }
        return out
    }

    // MARK: Deriving

    /// Recompute both constants from their sources.
    ///
    /// Idempotent, and cheap enough to call on every launch: the maximum is one
    /// pass over the activity list, and the resting series is a dictionary the
    /// HealthKit query already produced.
    /// No default arguments: the two sources are passed in explicitly so this
    /// stays a pure function of what it is given, and so a caller can never be
    /// surprised by which snapshot it read.
    @MainActor
    func refreshFromSources(activities: [Activity],
                            restingByDay: [String: Double],
                            windowDays: Int = 365) {
        var next = c
        let cutoff = Self.dayKey(daysAgo: windowDays)

        // --- HR_max: the highest plausible maximum in the window.
        var best: (bpm: Int, day: String, name: String)?
        for a in activities where a.dayKey >= cutoff {
            // Bounds-check the Double, not the Int. `Int(1e20)` traps, and a
            // corrupt max_heartrate would then crash the app on launch inside a
            // refresh — checking after the conversion is checking too late.
            guard let m = a.maxHeartrate, m.isFinite,
                  m >= Double(Self.hrMaxPlausible.lowerBound),
                  m <= Double(Self.hrMaxPlausible.upperBound) else { continue }
            let bpm = Int(m.rounded())
            if best == nil || bpm > best!.bpm { best = (bpm, a.dayKey, a.name) }
        }
        if let best {
            let previous = next.hrMaxObserved
            next.hrMaxObserved = best.bpm
            next.hrMaxObservedOn = best.day
            next.hrMaxObservedName = best.name
            // Only a RISE matters. A fall means the hardest effort has aged out
            // of the window, which is not evidence that your maximum dropped —
            // so the figure is kept and the window is simply where it came from.
            // Only worth announcing when the observed figure is the one in
            // force. With an override set, nothing downstream changes, and
            // "everything will be recomputed" would simply be untrue.
            if c.hrMaxOverride == nil, let previous, best.bpm > previous {
                hrMaxRoseFrom = previous
            } else if let previous, best.bpm < previous {
                next.hrMaxObserved = previous
                next.hrMaxObservedOn = c.hrMaxObservedOn
                next.hrMaxObservedName = c.hrMaxObservedName
            }
        }

        // --- HR_rest: tenth percentile of each month's daily values.
        var byMonth: [String: [Int]] = [:]
        for (day, bpm) in restingByDay {
            let v = Int(bpm.rounded())
            guard Self.hrRestPlausible.contains(v) else { continue }
            byMonth[String(day.prefix(7)), default: []].append(v)
        }
        var rest: [String: Int] = [:]
        for (month, values) in byMonth where values.count >= 5 {
            rest[month] = Self.percentile(values, 0.10)
        }
        // MERGED, never replaced. HealthKit's window is 420 days and its
        // retention is not guaranteed — a new phone, a watch swap, or Health
        // sync turned off leaves only recent months, and an assignment here
        // would delete January permanently, with no source left to recompute it
        // from. A month is only ever overwritten by a newer reading of itself.
        next.restByMonth.merge(rest) { _, new in new }

        // Version tracks HR_max alone — see the note on the property.
        if next.hrMax != c.hrMax { next.version = c.version + 1 }
        guard next != c else { return }
        c = next
        save()
    }

    // MARK: Editing

    @MainActor
    func setHRMaxOverride(_ bpm: Int?) {
        var next = c
        next.hrMaxOverride = bpm.flatMap { Self.hrMaxPlausible.contains($0) ? $0 : nil }
        if next.hrMax != c.hrMax { next.version = c.version + 1 }
        c = next
        hrMaxRoseFrom = nil
        save()
    }

    @MainActor
    func setRestOverride(_ bpm: Int?) {
        var next = c
        next.restOverride = bpm.flatMap { Self.hrRestPlausible.contains($0) ? $0 : nil }
        guard next != c else { return }
        c = next
        save()
    }

    @MainActor
    func acknowledgeHRMaxRise() { hrMaxRoseFrom = nil }

    // MARK: Helpers

    /// Linear-interpolation percentile. Small samples (a month is 28–31 values)
    /// make the interpolation worth having — the nearest-rank version jumps a
    /// whole beat at a time.
    static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        if s.count == 1 { return s[0] }
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let frac = pos - Double(lo)
        return Int((Double(s[lo]) + frac * Double(s[hi] - s[lo])).rounded())
    }

    /// "2026-01" + 2 → "2026-03". String arithmetic on months, because that is
    /// the only calendar operation this file needs.
    static func month(_ m: String, offsetBy n: Int) -> String {
        let parts = m.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return m }
        let total = parts[0] * 12 + (parts[1] - 1) + n
        return String(format: "%04d-%02d", total / 12, total % 12 + 1)
    }

    private static func dayKey(daysAgo: Int) -> String {
        let d = Calendar(identifier: .iso8601)
            .date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return DayKey.key(d)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AthleteConstants.self, from: data)
        else { return }
        c = decoded
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: fileURL, options: .atomic)
    }
}
