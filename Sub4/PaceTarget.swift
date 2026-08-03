//
//  PaceTarget.swift
//  Sub4
//
//  Parsing the plan's pace band out of a session's own words.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI

// MARK: - Pace target
//
// Parsed out of the plan's own wording. The plan is consistent about this:
//   "8 km @5:45–6:00"                         → whole run
//   "Long + MP finish 18 km, last 5 km @5:38–5:43" → closing 5 km
//   "MP intervals 2k WU + 2×4km @5:38–5:43"   → best continuous 4 km
//   "Long + MP block 26 km, middle 10 km @…"  → best continuous 10 km
//
// Where the plan gives no number, there is no verdict. Guessing one would turn
// an easy run into a failure it was never asked to pass.

struct PaceTarget {

    enum Scope: Equatable {
        case whole
        case closing(Int)
        case opening(Int)
        case best(Int)

        /// The target is stated in MINUTES, not kilometres — "2k WU + 4×8min
        /// @4:55–5:10 + CD". Kilometre splits cannot isolate an 8-minute rep,
        /// and judging the whole run (most of which is warm-up and cool-down)
        /// against a threshold target would fail a session that was executed
        /// perfectly. So the target is shown and no verdict is given.
        case unmeasurable
    }

    let low: Int          // seconds/km, fast bound
    let high: Int         // seconds/km, slow bound
    let scope: Scope

    var midpoint: Int { (low + high) / 2 }

    var rangeLabel: String {
        low == high ? Fmt.pace(low) : "\(Fmt.pace(low))–\(Fmt.pace(high))"
    }

    var scopeLabel: String {
        switch scope {
        // Names the measure, not just the extent. "whole run" left it open
        // whether this was an average or something cleverer — and it was
        // something cleverer, which is how it came to disagree with the header.
        case .whole:          return "average, whole run"
        case .closing(let n): return "last \(n) km"
        case .opening(let n): return "first \(n) km"
        case .best(let n):    return "best \(n) km"
        case .unmeasurable:   return "timed intervals"
        }
    }

    /// True when the target can be checked against kilometre splits at all.
    var isMeasurable: Bool { scope != .unmeasurable }

    func measured(in d: ActivityDetail, fallback: Int?) -> Int? {
        switch scope {
        // The activity's own average pace first — that is the number in the
        // header, and a verdict that disagrees with the headline figure is a
        // verdict nobody can act on. Splits are only the fallback, and then as
        // an overall average, never a median.
        case .whole:          return fallback ?? d.overallPace
        case .closing(let n): return d.closingPace(km: n)
        case .opening(let n): return d.openingPace(km: n)
        case .best(let n):    return d.bestWindowPace(km: n)
        case .unmeasurable:   return nil
        }
    }

    enum State {
        case on, faster, slower

        var headline: String {
            switch self {
            case .on:     return "Held the target"
            case .faster: return "Faster than asked"
            case .slower: return "Off the target"
            }
        }
        var symbol: String {
            switch self {
            case .on:     return "checkmark.circle.fill"
            case .faster: return "arrow.down.circle.fill"
            case .slower: return "exclamationmark.circle.fill"
            }
        }
        var colour: Color {
            switch self {
            // One definition of these three, shared with the split and
            // interval tables. Until patch 102 this card said "faster" in bike
            // cyan while the tables below said it in the diverging pair's cyan —
            // two nearly identical colours for the same word, from two places.
            case .on:     return Color.onTargetColor
            case .faster: return Color.fasterColor
            case .slower: return Color.slowerColor
            }
        }
    }

    func state(for measured: Int) -> State {
        if measured < low - 2 { return .faster }
        if measured > high + 2 { return .slower }
        return .on
    }

    // MARK: Parsing

    private static let pacePattern =
        #"@\s*(\d):(\d{2})(?:\s*[–\-—]\s*(\d):(\d{2}))?"#

    static func parse(_ session: Session) -> PaceTarget? {
        let text = [session.title, session.detail]
            .compactMap { $0 }.joined(separator: " ")
        guard let re = try? NSRegularExpression(pattern: pacePattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0,
                                                             length: ns.length))
        else { return nil }

        func group(_ i: Int) -> Int? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
        guard let m1 = group(1), let s1 = group(2) else { return nil }
        let low = m1 * 60 + s1
        let high: Int
        if let m2 = group(3), let s2 = group(4) { high = m2 * 60 + s2 } else { high = low }
        guard low > 120, high < 900 else { return nil }   // sanity

        let prefix = ns.substring(to: m.range.location)
        return PaceTarget(low: min(low, high), high: max(low, high),
                          scope: scope(from: prefix))
    }

    /// Reads the words immediately before the pace token.
    private static func scope(from prefix: String) -> Scope {
        let tail = String(prefix.suffix(30)).lowercased()

        // "25min @", "4×8min @", "2×15 min @" — a duration, not a distance.
        if matches(tail, pattern: #"\d+\s*(?:min|sec|s)\s*$"#) { return .unmeasurable }

        if let n = firstInt(in: tail, pattern: #"(?:last|final)\s+(\d+)\s*km\s*$"#) {
            return .closing(n)
        }
        if let n = firstInt(in: tail, pattern: #"(?:first|opening)\s+(\d+)\s*km\s*$"#) {
            return .opening(n)
        }
        if let n = firstInt(in: tail, pattern: #"middle\s+(\d+)\s*km\s*$"#) {
            return .best(n)
        }
        // "2×4km", "4×1km" — the rep length is what the target applies to.
        if let n = firstInt(in: tail, pattern: #"\d+\s*[×x]\s*(\d+)\s*k?m?\s*$"#) {
            return .best(n)
        }
        return .whole
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        return re.firstMatch(in: text,
                             range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return Int(ns.substring(with: r))
    }
}
