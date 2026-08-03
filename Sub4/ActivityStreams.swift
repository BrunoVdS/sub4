//
//  ActivityStreams.swift
//  Sub4
//
//  The sample-by-sample record behind an activity: heart rate, speed, altitude
//  and grade, each aligned to cumulative distance.
//
//  WHY STREAMS ARE RIGHT HERE AND WRONG FOR SPLITS
//  -----------------------------------------------
//  Kilometre splits still come from `splits_metric` (see ActivityDetail). A
//  split is a *derived* number — average pace over a kilometre — and deriving
//  it by integrating a downsampled stream folds stopped time into the average.
//  Measured that way, a 5:58/km run reads as 6:58/km.
//
//  A profile chart integrates nothing. Every sample is an instantaneous reading
//  at a known distance, so a stop appears as a genuine dip rather than
//  contaminating a neighbour. Same data, different job, opposite verdict.
//
//  Stored downsampled. Strava's `resolution` parameter is deprecated and may be
//  ignored, so a 34 km long run could return 12 000 samples per series. The app
//  resamples to a few hundred distance-aligned bins before writing to disk.
//

import Foundation
import CoreLocation

struct ActivityStreams: Codable, Hashable {

    let activityId: String
    var distanceM: [Double]          // cumulative metres — the x axis
    var heartRate: [Double]?         // bpm
    var speed: [Double]?             // m/s
    var altitude: [Double]?          // metres
    var grade: [Double]?             // percent
    /// Watts, and only ever from a meter — Strava's estimate is refused at the
    /// ingest boundary.
    ///
    /// STORED BUT NOT YET SCORED. Several long rides in this history carry
    /// power and no heart rate at all, so this is what will eventually let them
    /// count. Nothing reads it today: converting watts into the heart-rate
    /// currency needs a factor measured from rides that have both, and those
    /// rides have to be collected first. It is fetched now because a full trace
    /// backfill is already running, and asking for it later means paying for
    /// all 250 traces a second time.
    var power: [Double]?
    var latitude: [Double]?          // degrees, index-aligned with distanceM
    var longitude: [Double]?
    var fetched: Date

    /// Target sample count after resampling. Roughly one point per pixel on a
    /// phone-width chart; more is storage spent on detail nobody can see.
    static let targetSamples = 300

    var count: Int { distanceM.count }
    var isUsable: Bool { distanceM.count >= 8 }

    var totalKm: Double { (distanceM.last ?? 0) / 1000 }

    // MARK: Availability

    func has(_ series: StreamSeries) -> Bool {
        switch series {
        case .heartRate: return (heartRate?.contains { $0 > 0 }) ?? false
        case .speed:     return (speed?.contains { $0 > 0 }) ?? false
        case .elevation: return (altitude?.count ?? 0) == count && count > 0
        case .grade:     return (grade?.count ?? 0) == count && count > 0
        }
    }

    var availableSeries: [StreamSeries] {
        StreamSeries.allCases.filter { has($0) }
    }

    func values(_ series: StreamSeries) -> [Double]? {
        switch series {
        case .heartRate: return heartRate
        case .speed:     return speed
        case .elevation: return altitude
        case .grade:     return grade
        }
    }

    // MARK: Terrain honesty
    //
    // On flat ground the altitude stream wobbles more than the terrain does.
    // A real measurement of that wobble is worth more than a chart of it.

    var elevationRange: Double {
        guard let a = altitude, let lo = a.min(), let hi = a.max() else { return 0 }
        return hi - lo
    }

    /// Below this the "profile" is GPS jitter, and the chart says so.
    var hasRealRelief: Bool { elevationRange >= 15 }

    var gradeRange: Double {
        guard let g = grade, let lo = g.min(), let hi = g.max() else { return 0 }
        return hi - lo
    }

    var hasRealGrade: Bool { gradeRange >= 4 }

    // MARK: Lookup

    /// Index of the sample nearest a distance in km — for the scrub readout.
    /// Binary search: this runs on every drag frame.
    func index(nearestKm km: Double) -> Int? {
        guard !distanceM.isEmpty else { return nil }
        let target = km * 1000
        var lo = 0, hi = distanceM.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if distanceM[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(distanceM[lo - 1] - target) < abs(distanceM[lo] - target) {
            return lo - 1
        }
        return lo
    }

    func value(_ series: StreamSeries, atKm km: Double) -> Double? {
        guard let i = index(nearestKm: km),
              let v = values(series), i < v.count else { return nil }
        return v[i]
    }

    // MARK: Position

    var hasCoordinates: Bool {
        (latitude?.count ?? 0) == count && count > 0
    }

    /// Where on the ground a point on the chart's x-axis actually was.
    ///
    /// Taken from the `latlng` stream, which shares an index with `distance`,
    /// so this is a lookup rather than an estimate. Interpolating along the
    /// encoded polyline instead would have cost nothing extra to fetch, but the
    /// polyline is a simplified line — it measured 1.1 % short on a real route,
    /// which is ~50 m of drift by the end of a 5 km run. That's a city block in
    /// the wrong place.
    func coordinate(atKm km: Double) -> CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude,
              let i = index(nearestKm: km),
              i < lat.count, i < lon.count else { return nil }
        guard CLLocationCoordinate2DIsValid(
            CLLocationCoordinate2D(latitude: lat[i], longitude: lon[i]))
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat[i], longitude: lon[i])
    }
}

// MARK: - Series

enum StreamSeries: String, CaseIterable, Identifiable, Codable {
    case heartRate, speed, elevation, grade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .speed:     return "Pace"
        case .elevation: return "Elevation"
        case .grade:     return "Grade"
        }
    }

    /// Short form for the segmented picker — full words don't fit on a phone.
    var shortLabel: String {
        switch self {
        case .heartRate: return "HR"
        case .speed:     return "Pace"
        case .elevation: return "Elev"
        case .grade:     return "Grade"
        }
    }

    var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .speed:     return "speedometer"
        case .elevation: return "mountain.2.fill"
        case .grade:     return "angle"
        }
    }
}

// MARK: - Strava DTO

/// Response shape for `/activities/{id}/streams?key_by_type=true`.
///
/// Note the API's own spelling: `heartrate`, not `heart_rate`.
struct StravaStreamsDTO: Decodable {

    struct Numeric: Decodable { let data: [Double]? }
    /// `latlng` arrives as [[lat, lng], …], not two parallel arrays.
    struct Pairs: Decodable { let data: [[Double]]? }

    let distance: Numeric?
    let heartrate: Numeric?
    let altitude: Numeric?
    let velocity_smooth: Numeric?
    let grade_smooth: Numeric?
    let watts: Numeric?
    let latlng: Pairs?

    /// Resamples onto equal-distance bins and averages within each.
    ///
    /// Distance bins, not index bins: one pixel then means the same amount of
    /// ground everywhere on the chart. A consequence worth knowing — a two
    /// minute stop puts many samples into one bin, so that bin's average speed
    /// collapses toward zero. That is what actually happened at that point on
    /// the route, so it stays.
    /// `hasDeviceWatts` comes from the activity, not from the stream. Strava
    /// serves ESTIMATED power for rides without a meter and it is identical in
    /// the payload — ingesting that as real would poison everything built on it.
    func toStreams(activityId: String,
                   hasDeviceWatts: Bool = false,
                   samples: Int = ActivityStreams.targetSamples) -> ActivityStreams? {

        guard let dist = distance?.data, dist.count >= 8,
              let total = dist.last, total > 0 else { return nil }

        let n = min(samples, dist.count)
        let binWidth = total / Double(n)

        // Which bin each raw sample lands in.
        var binOf = [Int](repeating: 0, count: dist.count)
        for i in dist.indices {
            binOf[i] = min(Int(dist[i] / binWidth), n - 1)
        }

        func resample(_ raw: [Double]?) -> [Double]? {
            guard let raw, raw.count == dist.count else { return nil }
            var sum = [Double](repeating: 0, count: n)
            var hits = [Int](repeating: 0, count: n)
            for i in raw.indices {
                sum[binOf[i]] += raw[i]
                hits[binOf[i]] += 1
            }
            var out = [Double](repeating: 0, count: n)
            var last = raw.first ?? 0
            for b in 0..<n {
                if hits[b] > 0 { last = sum[b] / Double(hits[b]) }
                out[b] = last                 // carry forward across empty bins
            }
            return out
        }

        let centres = (0..<n).map { (Double($0) + 0.5) * binWidth }

        // Averaging coordinates inside a bin is safe at this scale: a bin is a
        // hundred metres or so of road, and the samples in it are essentially
        // collinear. Averaging would only distort on a hairpin tighter than one
        // bin, which no road has.
        let pairs = latlng?.data
        let lats = pairs?.map { $0.first ?? 0 }
        let lons = pairs?.map { $0.count > 1 ? $0[1] : 0 }

        return ActivityStreams(
            activityId: activityId,
            distanceM: centres,
            heartRate: resample(heartrate?.data),
            speed: resample(velocity_smooth?.data),
            altitude: resample(altitude?.data),
            grade: resample(grade_smooth?.data),
            power: hasDeviceWatts ? resample(watts?.data) : nil,
            latitude: resample(lats),
            longitude: resample(lons),
            fetched: Date())
    }
}
