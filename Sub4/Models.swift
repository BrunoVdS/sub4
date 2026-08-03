//
//  Models.swift
//  Sub4
//
//  Codable mirror of plan.json, produced by extract_plan.py.
//  Plan data is READ-ONLY at runtime — it ships in the app bundle and is
//  replaced wholesale on app update. Logged data lives elsewhere (see spec D3).
//

import Foundation

// MARK: - Root

struct Plan: Codable {
    let meta: Meta
    let weeks: [Week]
    let sessions: [Session]
    let exercises: [Exercise]
    /// Sections 09 and 10 of the source document — see Fuel.swift. Optional so
    /// a plan.json produced before the extractor learned to read them still
    /// decodes rather than failing the whole app to launch.
    let fuel: Fuel?
    /// Section 10b — see Warmup.swift. Optional for the same reason.
    let warmup: Warmup?
}

struct Meta: Codable {
    let plan: String
    let week1Monday: String
    let raceDate: String
    let targetTime: String
    let targetPaceSecKm: Int
}

// MARK: - Week

struct Week: Codable, Identifiable, Hashable {
    let uid: String
    let weekNo: Int?          // nil for the logged July prologue weeks (P1–P3)
    let label: String
    let dateRange: String?
    let startDate: String?
    let tag: String?
    /// The plan's own badge — "Peak long run", "Test", "Down", "Taper".
    let badge: String?
    /// The badge's class in the source document, which is how the plan itself
    /// weights the week: race, peak, cut, done. Nil for an ordinary week.
    let kind: String?
    let logged: Bool
    let stats: [String: Double]

    var id: String { uid }

    /// "Week 14" / "Logged P1"
    var display: String { logged ? "Logged \(label)" : "Week \(label)" }
}

// MARK: - Session

/// `CaseIterable` added in patch 195, for a test rather than for the UI.
///
/// `activity.discipline` carries a CHECK constraint listing these values, and
/// that list is FROZEN inside the migration that created the table — a
/// migration body is history and must not change when a Swift enum does. So the
/// two are held together by `SchemaAgreementTests` instead: add a case here and
/// the test fails, which is the prompt to write the migration that adds it to
/// the constraint.
enum Discipline: String, Codable, Hashable, CaseIterable {
    case run, bike, swim, strength, rest, other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Discipline(rawValue: raw) ?? .other
    }

    var symbol: String {
        switch self {
        case .run:      "figure.run"
        case .bike:     "bicycle"
        case .swim:     "figure.pool.swim"
        case .strength: "dumbbell.fill"
        case .rest:     "moon.zzz.fill"
        case .other:    "questionmark"
        }
    }

    var label: String {
        switch self {
        case .run: "Run"; case .bike: "Bike"; case .swim: "Swim"
        case .strength: "Strength"; case .rest: "Rest"; case .other: "Other"
        }
    }
}

/// Run sub-type — drives the accent colour, mirroring the HTML plan's swatches.
enum Intensity: String, Codable, Hashable {
    case easy, long, threshold
    case marathonPace = "marathon_pace"
}

struct Session: Codable, Identifiable, Hashable {
    let uid: String
    let weekUid: String
    let day: String?
    let date: String?          // "yyyy-MM-dd", nil for logged prologue weeks
    let discipline: Discipline
    let intensity: Intensity?
    let title: String?
    let detail: String?        // the one-line summary from the week card
    /// The plan's own fuelling line for this session — "Water only",
    /// "~65 g/hr · Leppin + gels — see ladder". 180 of the 260 sessions carry
    /// one; strength, rest, travel and walks correctly do not.
    let fuel: String?
    /// Warm-up marker — the three long runs where the race protocol is
    /// rehearsed, plus race day itself. nil on the other 256.
    let prep: String?
    let seq: Int

    let swimDetail: SessionDetail?
    let strengthDetail: SessionDetail?

    var id: String { uid }

    /// Full session breakdown, if this card has one.
    var breakdown: SessionDetail? { swimDetail ?? strengthDetail }

    var isRest: Bool { discipline == .rest }
}

// MARK: - Detail (identical shape for swim and strength)

struct SessionDetail: Codable, Hashable {
    let total: String?
    let tag: String?
    let focus: String?
    let blocks: [Block]
}

struct Block: Codable, Hashable, Identifiable {
    let d: String?   // duration or reps  — "5′", "×10/leg", "600 m"
    let t: String?   // title             — "Warm-up", "Back squat"
    let x: String?   // explanation / cue
    let u: String?   // video URL

    var id: String { (t ?? "") + (d ?? "") + (u ?? "") }
    var videoURL: URL? { u.flatMap(URL.init(string:)) }
}

// MARK: - Exercise library

struct Exercise: Codable, Identifiable, Hashable {
    let uid: String
    let name: String
    let videoUrl: String
    let cue: String?
    let uses: Int

    var id: String { uid }
    var url: URL? { URL(string: videoUrl) }
}

// MARK: - Date helpers
//
// Plan dates are plain calendar days ("2026-07-27") with no time component.
// Comparing formatted strings sidesteps every timezone and DST trap — the plan
// says Saturday, and Saturday is Saturday regardless of where you are.

enum DayKey {

    // `nonisolated`, not `nonisolated(unsafe)`.
    //
    // These need to be reachable from nonisolated contexts — DayKey.key() is
    // called from background sync and from the parser, not just from views. The
    // original version used the unsafe escape hatch because DateFormatter
    // wasn't Sendable; it is on this SDK, so the compiler can verify these on
    // its own and `(unsafe)` would only suppress a check that already passes.
    //
    // Configured once and never mutated. Never mutate them after creation.

    nonisolated static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static let prettyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    nonisolated static func key(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    nonisolated static func date(_ key: String) -> Date? {
        formatter.date(from: key)
    }

    nonisolated static func pretty(_ date: Date) -> String {
        prettyFormatter.string(from: date)
    }

    /// "14 Jun" — for captions naming a specific day inside a sentence, where
    /// the full `pretty` form is longer than the point being made.
    nonisolated static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    nonisolated static func short(_ date: Date) -> String {
        shortFormatter.string(from: date)
    }
}

// MARK: - Bounds-checked indexing

extension Array {
    /// `array[safe: i]` — nil instead of a crash on a bad index.
    ///
    /// Born in RoutePlayback, which indexes several parallel stream series at
    /// once where any one can be shorter than the distance axis on an old
    /// cached row; moved here in patch 174 because a general-purpose extension
    /// buried in a feature file is how a second copy gets written. Use it where
    /// the arrays genuinely may disagree — not as a reflex, since a nil that
    /// papers over an impossible index hides the bug it should have surfaced.
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
