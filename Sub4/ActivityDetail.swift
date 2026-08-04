//
//  ActivityDetail.swift
//  Sub4
//
//  The per-activity extras: kilometre splits, best efforts, laps, calories.
//  One call to /activities/{id}, fetched during sync and cached — so the detail
//  sheet opens instantly and works offline.
//
//  IMPORTANT: splits come from Strava's `splits_metric`, which reports MOVING
//  time per kilometre. Deriving splits from the raw streams gives wrong answers —
//  a downsampled stream hides stopped time, so every water stop reads as a
//  collapse in pace.
//

import Foundation
import CoreLocation

struct ActivityDetail: Codable, Hashable {

    let activityId: String
    var calories: Double?
    var descriptionText: String?
    var averageCadence: Double?
    var averageWatts: Double?
    var maxWatts: Double?
    var deviceName: String?
    var polyline: String?
    var splits: [Split]
    var bestEfforts: [BestEffort]
    var laps: [Lap]
    var fetched: Date

    struct Split: Codable, Hashable, Identifiable {
        let index: Int          // 1-based kilometre
        let distanceM: Double
        let movingTime: Int     // seconds — the honest one
        let elapsedTime: Int
        let elevationDiff: Double?
        let averageHR: Double?

        var id: Int { index }

        /// Pace in sec/km — always moving time over the distance actually
        /// covered.
        ///
        /// It used to return raw moving time for anything under 50 m, which is
        /// a number of seconds printed in a column of paces. On a run ending
        /// 14 m into the last kilometre that read "0:04 /km", and the damage
        /// was not only cosmetic: the split table scales its bars to the
        /// largest deviation on show, so one nonsense value of 337 seconds
        /// flattened all thirteen real kilometres into stubs and the panel
        /// stopped saying anything.
        ///
        /// A fragment's normalised pace is still noisy — 14 m of GPS is not a
        /// measurement — which is why `isFragment` keeps it out of the panel
        /// entirely. But nothing here invents a figure in the wrong unit.
        var paceSecPerKm: Int {
            guard distanceM >= 5 else { return 0 }
            return Int((Double(movingTime) / (distanceM / 1000)).rounded())
        }

        var paceLabel: String {
            let p = paceSecPerKm
            // A fragment has no pace to label. Printing "0:00" beside real
            // kilometres would be the same class of mistake this whole rule
            // exists to remove.
            guard p > 0 else { return "—" }
            return String(format: "%d:%02d", p / 60, p % 60)
        }

        /// True when this split is short — the tail end of the run. Shown, and
        /// labelled with its distance, but never averaged or compared.
        var isPartial: Bool { distanceM < 950 }

        /// The few metres left over when the watch stops mid-kilometre.
        ///
        /// Not a slow or a fast kilometre — not a kilometre at all. Under 100 m
        /// there is no pace in it to read: the sample is shorter than the GPS
        /// error around it, and rounding a couple of seconds either way swings
        /// the derived pace by minutes. It is dropped from the panel rather
        /// than dimmed, because a row that must not be read is better absent.
        var isFragment: Bool { distanceM < 100 }
    }

    struct BestEffort: Codable, Hashable, Identifiable {
        let name: String
        let seconds: Int
        var id: String { name }

        var timeLabel: String {
            let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                         : String(format: "%d:%02d", m, s)
        }
    }

    struct Lap: Codable, Hashable, Identifiable {
        let index: Int
        let distanceM: Double
        let movingTime: Int
        let averageHR: Double?
        var id: Int { index }
    }

    // MARK: Derived

    var coordinates: [CLLocationCoordinate2D] {
        Polyline.decode(polyline ?? "")
    }

    var hasRoute: Bool { (polyline?.count ?? 0) > 20 }

    /// Average pace over the final `n` complete kilometres — the question the
    /// plan actually asks ("last 4 km at MP").
    func closingPace(km n: Int) -> Int? {
        let complete = splits.filter { !$0.isPartial }
        guard complete.count >= n, n > 0 else { return nil }
        let tail = complete.suffix(n)
        let secs = tail.reduce(0) { $0 + $1.movingTime }
        let dist = tail.reduce(0.0) { $0 + $1.distanceM } / 1000
        guard dist > 0 else { return nil }
        return Int((Double(secs) / dist).rounded())
    }

    func openingPace(km n: Int) -> Int? {
        let complete = splits.filter { !$0.isPartial }
        guard complete.count >= n, n > 0 else { return nil }
        let head = complete.prefix(n)
        let secs = head.reduce(0) { $0 + $1.movingTime }
        let dist = head.reduce(0.0) { $0 + $1.distanceM } / 1000
        guard dist > 0 else { return nil }
        return Int((Double(secs) / dist).rounded())
    }

    var fastestSplit: Split? {
        splits.filter { !$0.isPartial }.min { $0.paceSecPerKm < $1.paceSecPerKm }
    }

    /// Fastest rolling window of `n` complete kilometres.
    ///
    /// The plan writes intervals as "2×4 km @5:38–5:43". Splits can't tell which
    /// kilometres were the work and which were the float, so rather than guess we
    /// report the best continuous block of that length and label it as such.
    func bestWindowPace(km n: Int) -> Int? {
        let c = splits.filter { !$0.isPartial }
        guard n > 0, c.count >= n else { return nil }
        var best: Int?
        for start in 0...(c.count - n) {
            let w = c[start..<(start + n)]
            let secs = w.reduce(0) { $0 + $1.movingTime }
            let dist = w.reduce(0.0) { $0 + $1.distanceM } / 1000
            guard dist > 0 else { continue }
            let pace = Int((Double(secs) / dist).rounded())
            if best == nil || pace < best! { best = pace }
        }
        return best
    }

    /// Median kilometre pace — the fallback baseline for a session the plan
    /// gives no number for (every ride, most easy runs).
    ///
    /// NOT the measure for a whole-run pace target. It was used for that once,
    /// and produced a screen reading 6:03 /km at the top with "5:57 — faster
    /// than asked" underneath. On a 5 km run the median is simply the third
    /// kilometre and the other four are discarded. See `overallPace`.
    var medianSplitPace: Int? {
        let p = splits.filter { !$0.isPartial }.map(\.paceSecPerKm).sorted()
        guard !p.isEmpty else { return nil }
        return p[p.count / 2]
    }

    /// Average moving pace over the whole activity — total moving time divided
    /// by total distance, partial final split included.
    ///
    /// This is what "the whole run" means, and it is the same arithmetic that
    /// produces the pace in the header, so the two can never disagree.
    var overallPace: Int? {
        let secs = splits.reduce(0) { $0 + $1.movingTime }
        let dist = splits.reduce(0.0) { $0 + $1.distanceM } / 1000
        guard dist > 0.2, secs > 0 else { return nil }
        return Int((Double(secs) / dist).rounded())
    }

    /// The splits worth putting on screen: everything except a trailing
    /// fragment under 100 m.
    ///
    /// Every aggregate on this type already excluded fragments by way of
    /// `isPartial`; only the table drew them, and it was the table that the
    /// fragment ruined. Filtering here rather than in the view keeps the panel,
    /// the HR chart and any future reader on one definition.
    var displaySplits: [Split] { splits.filter { !$0.isFragment } }

    var hasSplits: Bool { displaySplits.count >= 2 }
    var hasHRSplits: Bool { displaySplits.contains { ($0.averageHR ?? 0) > 0 } }

    var totalElevationFromSplits: Double {
        splits.compactMap(\.elevationDiff).filter { $0 > 0 }.reduce(0, +)
    }
}

// MARK: - Formatting

enum Fmt {
    /// 3725 → "1:02:05", 1925 → "32:05"
    nonisolated static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// 341 → "5:41"
    nonisolated static func pace(_ secPerKm: Int) -> String {
        String(format: "%d:%02d", secPerKm / 60, secPerKm % 60)
    }

    /// Signed gap against a target, in seconds per km: -7 → "7 s/km faster".
    nonisolated static func gap(_ delta: Int) -> String {
        let a = abs(delta)
        if a < 2 { return "on target" }
        return "\(a) s/km \(delta < 0 ? "faster" : "slower")"
    }
}

// MARK: - Strava DTO

struct StravaDetailDTO: Decodable {
    /// Strava sends `average_heartrate: 0` for a lap or split it has no reading
    /// for — patch 244. Zero bpm is a strap that was not worn, not a dead
    /// athlete, and it is the same rule `activity.averageHeartrate` already
    /// carries as a CHECK.
    ///
    /// Left unconverted, twelve details on this device were REFUSED WHOLE on
    /// import: the lap insert violated `averageHeartrate IS NULL OR > 0`, the
    /// savepoint rolled back, and the detail took its splits with it. On screen
    /// the same zero rendered as a lap at 0 bpm.
    static func positiveOrNil(_ v: Double?) -> Double? {
        guard let v, v > 0 else { return nil }
        return v
    }

    struct SplitDTO: Decodable {
        let distance: Double?
        let elapsed_time: Int?
        let moving_time: Int?
        let elevation_difference: Double?
        let average_heartrate: Double?
        let split: Int?
    }
    struct EffortDTO: Decodable {
        let name: String?
        let elapsed_time: Int?
    }
    struct LapDTO: Decodable {
        let lap_index: Int?
        let distance: Double?
        let moving_time: Int?
        let average_heartrate: Double?
    }
    struct MapDTO: Decodable {
        let polyline: String?
        let summary_polyline: String?
    }

    let id: Int64
    let calories: Double?
    let description: String?
    let average_cadence: Double?
    let average_watts: Double?
    let max_watts: Double?
    let device_name: String?
    let map: MapDTO?
    let splits_metric: [SplitDTO]?
    let best_efforts: [EffortDTO]?
    let laps: [LapDTO]?

    func toDetail() -> ActivityDetail {
        ActivityDetail(
            activityId: String(id),
            calories: calories,
            descriptionText: description,
            averageCadence: average_cadence,
            averageWatts: average_watts,
            maxWatts: max_watts,
            deviceName: device_name,
            polyline: map?.polyline ?? map?.summary_polyline,
            splits: (splits_metric ?? []).enumerated().map { i, s in
                ActivityDetail.Split(
                    index: s.split ?? (i + 1),
                    distanceM: s.distance ?? 0,
                    movingTime: s.moving_time ?? s.elapsed_time ?? 0,
                    elapsedTime: s.elapsed_time ?? 0,
                    elevationDiff: s.elevation_difference,
                    averageHR: Self.positiveOrNil(s.average_heartrate))
            },
            bestEfforts: (best_efforts ?? []).compactMap {
                guard let n = $0.name, let t = $0.elapsed_time else { return nil }
                return ActivityDetail.BestEffort(name: n, seconds: t)
            },
            laps: (laps ?? []).enumerated().map { i, l in
                ActivityDetail.Lap(index: l.lap_index ?? (i + 1),
                                   distanceM: l.distance ?? 0,
                                   movingTime: l.moving_time ?? 0,
                                   averageHR: Self.positiveOrNil(l.average_heartrate))
            },
            fetched: Date()
        )
    }
}

// MARK: - Google encoded polyline

enum Polyline {

    /// Decodes Strava's encoded polyline (Google's algorithm, precision 5).
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        guard !encoded.isEmpty else { return [] }
        var coords: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0

        func nextValue() -> Int? {
            var result = 0, shift = 0
            while index < encoded.endIndex {
                guard let ascii = encoded[index].asciiValue else { return nil }
                index = encoded.index(after: index)
                let chunk = Int(ascii) - 63
                result |= (chunk & 0x1F) << shift
                shift += 5
                if chunk < 0x20 {
                    // zig-zag decode
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < encoded.endIndex {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5,
                                                 longitude: Double(lon) / 1e5))
        }
        return coords
    }
}
