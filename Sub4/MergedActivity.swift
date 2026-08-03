//
//  MergedActivity.swift
//  Sub4
//
//  One day's same-type extras, presented as one thing — patch 177.
//
//  THE PROBLEM. Walking arrives split: a morning leg, a lunch leg, an evening
//  leg, each its own Strava file. Step 0 of the load work measured it — 103
//  walk files on 64 walk days, so the average walking day is recorded in two
//  or three pieces. The extras list showed every piece as its own row, which
//  is three statements of one fact: you walked today.
//
//  THE RULE. Extras of the SAME SPORT TYPE on the SAME DAY collapse into one
//  entry — one row on Today and Week, one detail page, one map carrying every
//  leg. Two commute rides become "Commutes"; four walks become "Walks".
//
//  WHAT DOES NOT MERGE, DELIBERATELY:
//   · Anything plan-eligible. `extras` includes plan-eligible activities that
//     found no session — an unmatched 40 km training ride. Folding that into
//     the commutes would file real training under a commute heading, so the
//     merge takes only the non-eligible rows and an unmatched session stays
//     its own entry.
//   · A type that appears once. A single walk is an activity, not a group of
//     one — it keeps its own name, its own row and its own detail page.
//
//  PRESENTATION-LEVEL ONLY. Nothing here writes anything: the parts stay
//  untouched in ActivityStore, the load engine still scores them one by one,
//  and ungrouping is deleting this file. The merge is how the day is SHOWN,
//  which is exactly the shape the load work's step 1 wants — the day as the
//  unit — arriving in the UI first.
//

import Foundation
import CoreLocation

// MARK: - The row model

/// What an extras list actually contains once same-type days collapse.
enum ExtraItem: Identifiable {
    case single(Activity)
    case merged(MergedExtra)

    var id: String {
        switch self {
        case .single(let a): a.id
        case .merged(let m): m.id
        }
    }
}

// MARK: - The group

struct MergedExtra: Identifiable, Hashable {

    /// At least two, same dayKey, same sportType, sorted by start time.
    let parts: [Activity]

    var id: String { "merged-\(dayKey)-\(sportType)" }
    var dayKey: String { parts[0].dayKey }
    var sportType: String { parts[0].sportType }
    var symbol: String { parts[0].extraSymbol }
    var discipline: Discipline? { parts[0].discipline }

    // MARK: Totals — sums of the parts, no invention

    var distance: Double { parts.reduce(0) { $0 + $1.distance } }
    var km: Double { distance / 1000 }
    var movingTime: Int { parts.reduce(0) { $0 + $1.movingTime } }
    var minutes: Int { movingTime / 60 }

    var elevationGain: Double { parts.reduce(0) { $0 + ($1.elevationGain ?? 0) } }

    /// Weighted by moving time, and only over the parts that measured one —
    /// averaging a 90-minute walk with HR against a 10-minute one without by
    /// simple mean would let the short one move a number it never touched.
    var averageHeartrate: Double? {
        var beats = 0.0, secs = 0.0
        for p in parts {
            guard let hr = p.averageHeartrate else { continue }
            beats += hr * Double(p.movingTime)
            secs += Double(p.movingTime)
        }
        guard secs > 0 else { return nil }
        return beats / secs
    }

    var paceSecPerKm: Int? {
        guard km > 0.2, movingTime > 0 else { return nil }
        return Int((Double(movingTime) / km).rounded())
    }

    // MARK: Labels

    /// "Walks", "Commutes" — the type said once, plural because the row IS the
    /// plurality. The part names ("Lunch Walk", "Evening Walk") stay on the
    /// detail page's part list; a merged row titled by one of them would claim
    /// the day was that walk.
    var title: String {
        switch sportType {
        case "Walk":        return "Walks"
        case "Hike":        return "Hikes"
        case "Ride":        return "Commutes"
        case "VirtualRide": return "Zwift rides"
        case "Kayaking":    return "Kayak outings"
        case "Rowing":      return "Rows"
        default:            return sportType + " ×\(parts.count)"
        }
    }

    /// "3 walks", for captions.
    var countLabel: String {
        let noun: String
        switch sportType {
        case "Walk":        noun = "walks"
        case "Hike":        noun = "hikes"
        case "Ride":        noun = "commutes"
        case "VirtualRide": noun = "Zwift rides"
        default:            noun = "parts"
        }
        return "\(parts.count) \(noun)"
    }

    /// "09:12 – 19:45" — first start to last END, the last start plus its
    /// moving time. First-to-last-start would end the day's walking the moment
    /// the evening walk began, which is off by the whole evening walk.
    var timeSpan: String {
        guard let first = parts.first, let last = parts.last else { return "" }
        let start = String(first.startLocal.dropFirst(11).prefix(5))
        let endMin = (last.startMinuteOfDay + last.movingTime / 60) % (24 * 60)
        return String(format: "%@ – %02d:%02d", start, endMin / 60, endMin % 60)
    }

    // MARK: Grouping

    /// Collapses an extras list. Order is preserved: a merged group sits where
    /// its FIRST part sat, so the list still reads chronologically.
    ///
    /// Only non-plan-eligible rows merge — see the header. `extras` is already
    /// sorted by start (Matcher sorts it), so buckets come out sorted too.
    static func group(_ extras: [Activity]) -> [ExtraItem] {
        var buckets: [String: [Activity]] = [:]
        for a in extras where !a.isPlanEligible {
            buckets[a.sportType, default: []].append(a)
        }

        var emitted: Set<String> = []
        var out: [ExtraItem] = []
        for a in extras {
            if a.isPlanEligible {
                out.append(.single(a))
                continue
            }
            let bucket = buckets[a.sportType] ?? [a]
            if bucket.count < 2 {
                out.append(.single(a))
            } else if !emitted.contains(a.sportType) {
                emitted.insert(a.sportType)
                out.append(.merged(MergedExtra(parts: bucket)))
            }
        }
        return out
    }
}

// MARK: - Joined streams

/// The parts' traces laid end to end on one distance axis.
///
/// WHY DISTANCE MAKES THIS CLEAN. Streams are distance-binned, not
/// time-binned — see ActivityStreams. Concatenating by cumulative distance
/// therefore produces a genuinely continuous axis: "the day's ninth kilometre
/// of walking" is a real place on it, and the hours between the legs occupy
/// no metres, so there is nothing to draw a gap for. The same merge on a time
/// axis would be mostly empty space.
///
/// WHAT THE BOUNDARIES ARE FOR. The map must NOT draw the joins — a straight
/// line from where the lunch walk ended to where the evening walk began is a
/// route nobody moved along. `boundaries` marks where each new part starts in
/// the merged sample space so playback can split its travelled line there,
/// and `segments` carries the per-part coordinate runs for the route drawing.
struct MergedStreams {
    let streams: ActivityStreams
    /// Sample index where each part after the first begins. Never contains 0.
    let boundaries: [Int]
    /// Per-part coordinate runs, for drawing the route without join lines.
    let segments: [[CLLocationCoordinate2D]]
    /// Moving seconds of the parts actually included — the playback clock must
    /// be scaled to the time behind the samples it has, not the whole day's.
    let movingSeconds: Int
    /// How many parts made it in, so the page can say "profile covers 2 of 3".
    let included: Int
}

extension MergedExtra {

    /// nil until at least one part's trace is cached.
    ///
    /// A series survives the merge only when EVERY included part carries it —
    /// splicing zeros into the gap would draw a heart rate of nothing as a
    /// heart rate of zero. Dropping the series for the day is the honest form.
    func joinedStreams(from store: DetailStore) -> MergedStreams? {
        let included: [(Activity, ActivityStreams)] = parts.compactMap { p in
            guard let s = store.streams(for: p.id), s.isUsable else { return nil }
            return (p, s)
        }
        guard !included.isEmpty else { return nil }
        let all = included.map(\.1)

        func joined(_ series: (ActivityStreams) -> [Double]?) -> [Double]? {
            var out: [Double] = []
            for s in all {
                guard let v = series(s), v.count == s.count else { return nil }
                out += v
            }
            return out
        }

        var dist: [Double] = []
        var boundaries: [Int] = []
        var offset = 0.0
        for s in all {
            if !dist.isEmpty { boundaries.append(dist.count) }
            dist += s.distanceM.map { $0 + offset }
            offset = dist.last ?? offset
        }

        let merged = ActivityStreams(
            activityId: id,
            distanceM: dist,
            heartRate: joined { $0.heartRate },
            speed: joined { $0.speed },
            altitude: joined { $0.altitude },
            grade: joined { $0.grade },
            // Never merged: no extra in this history carries a meter, and a
            // partial power series would fail the count check anyway.
            power: nil,
            latitude: joined { $0.latitude },
            longitude: joined { $0.longitude },
            fetched: all.map(\.fetched).max() ?? Date.distantPast)

        // Stream coordinates per part — the line playback's clock indexes
        // against, split so the map can draw each leg separately.
        var segments: [[CLLocationCoordinate2D]] = []
        for s in all where s.hasCoordinates {
            guard let lat = s.latitude, let lon = s.longitude else { continue }
            let run = (0..<s.count).compactMap { i -> CLLocationCoordinate2D? in
                let c = CLLocationCoordinate2D(latitude: lat[i], longitude: lon[i])
                return CLLocationCoordinate2DIsValid(c) ? c : nil
            }
            if run.count > 1 { segments.append(run) }
        }

        return MergedStreams(
            streams: merged,
            boundaries: boundaries,
            segments: segments,
            movingSeconds: included.reduce(0) { $0 + $1.0.movingTime },
            included: included.count)
    }
}
