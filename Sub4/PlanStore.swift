//
//  PlanStore.swift
//  Sub4
//
//  Loads plan.json from the app bundle once and indexes it for lookup.
//  Deliberately NOT @Observable: plan data never changes at runtime, so there
//  is nothing to observe. Logged data (mutable) will get its own store later.
//

import Foundation

final class PlanStore {

    static let shared = PlanStore()

    let plan: Plan
    let loadError: String?

    /// sessions keyed by "yyyy-MM-dd"
    private(set) var byDate: [String: [Session]] = [:]
    private(set) var weeksByUid: [String: Week] = [:]

    /// Patch 239. Derived once from `plan`, which is `let` and read from the
    /// bundle in `init` — so the answer cannot change and recomputing it per
    /// week would be 260 filters for a constant. Internal rather than private
    /// because the derivation lives in `PlanFocus.swift`, next to the rule it
    /// implements.
    var focusCache: PlanFocus?

    // MARK: Load

    private init() {
        guard let url = Bundle.main.url(forResource: "plan", withExtension: "json") else {
            plan = Plan.empty
            loadError = "plan.json not found in the app bundle. Check Build Phases → Copy Bundle Resources."
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            plan = try decoder.decode(Plan.self, from: Data(contentsOf: url))
            loadError = nil
        } catch {
            plan = Plan.empty
            loadError = "Could not decode plan.json — \(error)"
            return
        }

        for s in plan.sessions where s.date != nil {
            byDate[s.date!, default: []].append(s)
        }
        for key in byDate.keys {
            byDate[key]?.sort { $0.seq < $1.seq }
        }
        for w in plan.weeks { weeksByUid[w.uid] = w }
    }

    // MARK: Queries

    func sessions(on key: String) -> [Session] { byDate[key] ?? [] }

    func week(for session: Session) -> Week? { weeksByUid[session.weekUid] }

    /// The plan week a date falls inside, by date range rather than by session.
    ///
    /// Looking it up via sessions fails on any day with none — Week 1 has no
    /// Monday session, so 27 July showed no week label at all. Weeks are strictly
    /// Mon–Sun, so the range test is exact.
    func week(containing key: String) -> Week? {
        if let w = planWeeks.first(where: { w in
            guard let start = w.startDate else { return false }
            return key >= start && key <= Self.plusDays(6, from: start)
        }) { return w }

        // Fall back to the session lookup for the undated logged weeks (P1–P3).
        return sessions(on: key).first.flatMap { weeksByUid[$0.weekUid] }
    }

    private static func plusDays(_ n: Int, from key: String) -> String {
        guard let d = DayKey.date(key),
              let end = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: n, to: d) else { return key }
        return DayKey.key(end)
    }

    /// Plan weeks only, in order — excludes the logged July prologue.
    var planWeeks: [Week] {
        plan.weeks.filter { !$0.logged }.sorted { ($0.weekNo ?? 0) < ($1.weekNo ?? 0) }
    }

    var totalPlanWeeks: Int { planWeeks.count }

    /// Every session the block actually asks for: not rest, not optional, not in
    /// the logged July prologue.
    ///
    /// The same three exclusions `plannedVolume` applies, for the same reason.
    /// The plan holds 240 non-rest sessions of which 28 are optional Zwift; a
    /// tally that counted those would make the block look larger than the
    /// commitment is, and would be counting a different plan from the distance
    /// figures directly above it on the card.
    var requiredSessionCount: Int {
        plan.sessions.filter {
            weeksByUid[$0.weekUid]?.logged == false
                && $0.date != nil
                && $0.discipline != .rest
                && !Self.isOptional($0)
        }.count
    }

    /// First plan day on or after `key` that has any session. Used when today
    /// falls outside the plan (before Wk 1, or on an empty day).
    func nextSessionDay(onOrAfter key: String) -> String? {
        byDate.keys.filter { $0 >= key }.min()
    }

    // MARK: Race

    var raceDate: Date? { DayKey.date(plan.meta.raceDate) }

    func daysToRace(from date: Date = Date()) -> Int? {
        guard let race = raceDate else { return nil }
        return Calendar(identifier: .iso8601)
            .dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                            to: Calendar.current.startOfDay(for: race)).day
    }

    /// "5:41 /km"
    var targetPace: String {
        let s = plan.meta.targetPaceSecKm
        return String(format: "%d:%02d /km", s / 60, s % 60)
    }

    // MARK: Planned running volume
    //
    // DO NOT USE week.stats["km"] FOR THIS.
    //
    // That figure is the plan author's own, and it is TOTAL MULTISPORT volume —
    // the source HTML for week 12 reads, verbatim:
    //
    //     3 runs · 1 ride · 1 swim · + commute · ~275 km · ~17.5 h
    //
    // 275 km is three runs plus a 2.5 h ride plus optional Zwift plus the daily
    // bike commute. The running in that week is 39 km. Plotting stats["km"] as
    // "planned" against recorded running made every week from 11 onward look
    // like a 200 km shortfall.
    //
    // So planned running volume is summed from the sessions themselves.

    struct PlannedDistance {
        let km: Double
        /// False when part of the session was not stated as a distance — a
        /// bare "+ CD", or work prescribed in minutes and converted at the
        /// session's own pace. The number is then an estimate, not a floor:
        /// it can land either side of the truth, and the UI marks it \u{2248}
        /// rather than presenting it as measured.
        let exact: Bool
    }

    func plannedRunKm(week: Week) -> PlannedDistance {
        let runs = sessions(inWeek: week).filter { $0.discipline == .run }
        var km = 0.0
        var exact = true
        for s in runs {
            let d = Self.plannedRunKm(s)
            km += d.km
            if !d.exact { exact = false }
        }
        return PlannedDistance(km: km, exact: exact)
    }

    func sessions(inWeek week: Week) -> [Session] {
        plan.sessions.filter { $0.weekUid == week.uid }
    }

    /// Longest single planned run, excluding race week — the number the long-run
    /// build is actually aiming at. Previously hard-coded as 32; it's 34.
    var peakLongRunKm: Double {
        let lastWeek = planWeeks.last?.uid
        return plan.sessions
            .filter { $0.discipline == .run && $0.weekUid != lastWeek }
            .map { Self.plannedRunKm($0).km }
            .max() ?? 0
    }

    // MARK: Whole-plan volume, per discipline
    //
    // Each sport is reported in the unit the plan actually writes it in.
    // Forcing everything into kilometres would mean inventing an average
    // cycling speed and multiplying — a number that looks precise and means
    // nothing.
    //
    //   run       km          the only sport given distances
    //   bike      hours       "2.5 h Z2", "60–75 min" — never a distance
    //   swim      km          always metres in the text
    //   strength  sessions    no distance, no consistent duration
    //
    // Optional sessions are excluded. Half the bike sessions are "opt." Zwift;
    // counting them as planned would show a shortfall for skipping work the
    // plan explicitly says is optional.

    struct PlanVolume {
        var runKm = 0.0
        var bikeHours = 0.0
        var swimKm = 0.0
        var strengthSessions = 0
        /// False when a run session's distance could only be bounded below.
        var runExact = true
    }

    /// Planned volume for required sessions dated on or before `day`.
    /// Pass nil for the whole block.
    func plannedVolume(throughDay day: String? = nil) -> PlanVolume {
        var v = PlanVolume()
        for s in plan.sessions {
            guard weeksByUid[s.weekUid]?.logged == false else { continue }
            if let day, let d = s.date, d > day { continue }
            if s.date == nil { continue }
            if Self.isOptional(s) { continue }
            accumulate(s, into: &v)
        }
        return v
    }

    /// The switch, extracted in patch 239 so `plannedVolume(throughDay:)` and
    /// `plannedVolume(week:)` cannot come to disagree about what a session
    /// contributes. The EXCLUSIONS stay at each call site — they differ — but
    /// the accumulation is one piece of code.
    func accumulate(_ s: Session, into v: inout PlanVolume) {
        switch s.discipline {
        case .run:
            let d = Self.plannedRunKm(s)
            v.runKm += d.km
            if !d.exact { v.runExact = false }
        case .bike:
            v.bikeHours += Self.plannedHours(s)
        case .swim:
            v.swimKm += Self.plannedMetres(s) / 1000
        case .strength:
            v.strengthSessions += 1
        default:
            break
        }
    }

    static func isOptional(_ s: Session) -> Bool {
        let t = [s.title, s.detail].compactMap { $0 }.joined(separator: " ")
        return optionalWord.firstMatch(
            in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    /// "2.5 h Z2" → 2.5 · "60–75 min" → 1.125 · "45 min" → 0.75
    static func plannedHours(_ s: Session) -> Double {
        let text = normalise([s.title, s.detail].compactMap { $0 }.joined(separator: " "))
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        if let m = hoursToken.firstMatch(in: text, range: all),
           let v = number(m, 1, ns) { return v }
        if let m = minuteRange.firstMatch(in: text, range: all),
           let a = number(m, 1, ns), let b = number(m, 2, ns) {
            return (a + b) / 2 / 60
        }
        if let m = minutesToken.firstMatch(in: text, range: all),
           let v = number(m, 1, ns) { return v / 60 }
        return 0
    }

    /// "1200 m · 6×100 swim" → 1200. The stated total, not the components.
    static func plannedMetres(_ s: Session) -> Double {
        let text = [s.title, s.detail].compactMap { $0 }.joined(separator: " ")
        let ns = text as NSString
        guard let m = metresToken.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)),
              let v = number(m, 1, ns) else { return 0 }
        return v
    }

    // MARK: Planned distance, whatever the sport
    //
    // WHY THIS EXISTS SEPARATELY FROM plannedRunKm
    // -------------------------------------------
    // This block is a running plan, so running is the only sport it states
    // distances for week after week. The next plan need not be. A plan with
    // "60 km ride" on a Saturday would draw a volume chart that silently
    // ignored the ride, and nothing on screen would say so.
    //
    // THE RULE, AND ITS ONE HARD EDGE
    // -------------------------------
    // Distance stated is distance counted. Time stated is NOT converted — not
    // for the bike, not for strength, not for a swim written as "45 min easy".
    // A converted hour is a guess wearing the same units as a measurement, and
    // in a chart the two become indistinguishable. Running is the single
    // exception, and only because the plan states a pace for every run it
    // writes in minutes; that conversion is marked inexact wherever it is used.
    //
    // WHY STRENGTH AND REST ARE EXCLUDED BY DISCIPLINE
    // ------------------------------------------------
    // Not for tidiness — for correctness. Two strength sessions in this plan
    // read "Heavy · 30 km long run this week — keep 2 RIR honest". The 30 km
    // belongs to Saturday's run, and a parser that trusted the discipline less
    // would add 60 km of squatting to the block. Rest days state real walking
    // distance ("10.7 km walk") and are excluded on judgement rather than
    // arithmetic: a walk is recovery, not training volume.

    /// The sports whose sessions can state their own distance, in the order a
    /// breakdown lists them. One list, used by the week aggregate below and by
    /// the chart's legend — two copies would eventually disagree.
    static let distanceDisciplines: [Discipline] = [.run, .bike, .swim, .other]

    /// One session's planned distance in km, in whatever unit the plan wrote it.
    static func plannedDistanceKm(_ s: Session) -> PlannedDistance {
        switch s.discipline {
        case .run:
            return plannedRunKm(s)
        case .swim:
            // Swims are always written in metres — "1500 m · 6×100 swim + kick".
            return PlannedDistance(km: plannedMetres(s) / 1000, exact: true)
        case .bike, .other:
            return distanceKm(s, convertMinutes: false)
        case .strength, .rest:
            return PlannedDistance(km: 0, exact: true)
        }
    }

    /// A week's planned distance, and where it came from.
    struct WeekDistance {
        let km: Double
        let exact: Bool
        /// Non-zero sports only, in plan order. Drives both the stacked bar and
        /// the sentence under it, so neither can name a sport the other omits.
        let parts: [(discipline: Discipline, km: Double)]

        var runKm: Double { parts.first { $0.discipline == .run }?.km ?? 0 }
        var otherKm: Double { km - runKm }

        /// "run 44 · swim 1.5"
        var composition: String {
            parts.map { String(format: "%@ %@", $0.discipline.label.lowercased(),
                               $0.km < 10 ? String(format: "%.1f", $0.km)
                                          : String(format: "%.0f", $0.km)) }
                 .joined(separator: " · ")
        }
    }

    func plannedDistance(week: Week) -> WeekDistance {
        var byDiscipline: [Discipline: Double] = [:]
        var exact = true
        for s in sessions(inWeek: week) {
            let d = Self.plannedDistanceKm(s)
            guard d.km > 0 || !d.exact else { continue }
            byDiscipline[s.discipline, default: 0] += d.km
            if !d.exact { exact = false }
        }
        let parts = Self.distanceDisciplines
            .compactMap { d -> (discipline: Discipline, km: Double)? in
                guard let v = byDiscipline[d], v > 0 else { return nil }
                return (d, v)
            }
        return WeekDistance(km: parts.reduce(0) { $0 + $1.km },
                            exact: exact, parts: parts)
    }

    private static let optionalWord = re(#"\bopt(?:ional|\.)"#, caseInsensitive: true)
    private static let hoursToken   = re(#"(\d+(?:\.\d+)?)\s*h\b"#)
    private static let minuteRange  = re(#"(\d+)\s*[–-]\s*(\d+)\s*min"#)
    private static let minutesToken = re(#"(\d+)\s*min"#)
    private static let metresToken  = re(#"(\d{3,5})\s*m\b"#)

    // MARK: The estimator
    //
    // Validated against all 105 run sessions: 84 resolve exactly, 21 are
    // estimates. Seventeen of those estimates used to be badly wrong — ten
    // pointer runs written only in minutes contributed nothing at all, which
    // is why weeks 7–9 reported "≥0 km planned" against an actual ~23 km each.
    // The rule that matters:
    //
    //   IF A SESSION STATES AN OVERALL DISTANCE, THAT IS THE SESSION.
    //
    // "Long + MP blocks 30 km, 2×8km @5:38–5:43 (2k float)" is a 30 km run with
    // two 8 km blocks INSIDE it. Summing the components gives 48 km. Likewise
    // "20 km, last 6 km @MP" is 20, not 26. Only when no overall distance is
    // stated — "2k WU + 2×4km (1k float) + CD" — do the components add up.

    static func plannedRunKm(_ session: Session) -> PlannedDistance {
        distanceKm(session, convertMinutes: true)
    }

    /// The same parser, with the minute conversion made optional.
    ///
    /// Converting a duration to a distance is a RUNNING assumption — it needs a
    /// pace, and the plan only ever states one for runs. "2 h outdoor Z2" on a
    /// bike is not 20 km of anything this app can know, so for every other
    /// sport `convertMinutes` is false: a session stated only in time
    /// contributes zero distance, and that zero is exact, not an estimate.
    static func distanceKm(_ session: Session,
                           convertMinutes: Bool) -> PlannedDistance {
        let text = normalise([session.title, session.detail]
            .compactMap { $0 }.joined(separator: " "))
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        // Spans that must not be read as a standalone total.
        var skip: [NSRange] = []
        skip += matches(repBlock, in: text, all).map(\.range)
        skip += matches(warmCool, in: text, all).map(\.range)

        // 1. An overall distance, if one is stated.
        for m in matches(plainKm, in: text, all) {
            if skip.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            // "last 6 km" describes a part of a distance already counted.
            let before = ns.substring(to: m.range.location)
            if segmentWord.firstMatch(in: before,
                                      range: NSRange(location: 0,
                                                     length: (before as NSString).length)) != nil {
                continue
            }
            if let v = number(m, 1, ns) {
                return PlannedDistance(km: v, exact: true)
            }
        }

        // 2. No total stated — add the parts.
        var total = 0.0
        var reps = 0
        for m in matches(repBlock, in: text, all) {
            if let r = number(m, 1, ns), let d = number(m, 2, ns) {
                total += r * d
                reps = Int(r)
            }
        }
        for m in matches(floatLeg, in: text, all) where reps > 1 {
            if let v = number(m, 1, ns) { total += Double(reps - 1) * v }
        }
        for m in matches(warmCool, in: text, all) {
            if let v = number(m, 1, ns) { total += v }
        }

        // 3. Minutes, converted at the session's own pace.
        //
        // Ten sessions in the plan state a duration and no distance at all —
        // "By feel, ~30–45 min". They used to contribute zero, so weeks 7–9
        // reported "≥0 km planned" while actually prescribing about 23 km each.
        // Reading zero there is worse than reading an estimate: it made the
        // whole block look 60–80 km ahead of plan from September onwards, in
        // Progress and in the monthly review alike.
        //
        // Six more sessions are timed reps inside a distance session
        // ("2k WU + 4×8min @4:55–5:10 + CD"): the warm-up and cool-down counted,
        // the 32 minutes of work did not.
        //
        // The result is marked INEXACT, as it was before. What changes is that
        // it is now approximately right rather than approximately zero.
        let minutes = convertMinutes ? timedMinutes(text, ns, all) : 0
        if minutes > 0 {
            total += minutes / 60 * paceKmPerHour(text, ns, all)
        }

        let bareWarmCool = bareWU.firstMatch(in: text, range: all) != nil
        let timedReps = convertMinutes
            && timedWork.firstMatch(in: text, range: all) != nil
            && paceToken.firstMatch(in: text, range: all) != nil
        // A bike hour is not an approximation of a distance — it is a session
        // this chart deliberately does not measure. Only the running path
        // treats "no distance found" as an estimate.
        let inexact = convertMinutes
            ? (bareWarmCool || timedReps || minutes > 0 || total == 0)
            : bareWarmCool
        return PlannedDistance(km: total, exact: !inexact)
    }

    /// Every duration stated in the session, in minutes. Ranges take the
    /// midpoint — "30–45 min" is 37.5, not a floor of 30, because this is an
    /// estimate and a floor would reintroduce the under-reporting.
    ///
    /// Reps are multiplied out ("4×8min" = 32) and floats counted between them
    /// ("5×6min (90s float)" = 4 floats, not 5).
    private static func timedMinutes(_ text: String, _ ns: NSString,
                                     _ all: NSRange) -> Double {
        var mins = 0.0
        var counted: [NSRange] = []

        // n × m min
        for m in matches(timedReps_, in: text, all) {
            guard let r = number(m, 1, ns), let d = number(m, 2, ns) else { continue }
            mins += r * d
            counted.append(m.range)
            // The float between reps, in minutes or seconds.
            for f in matches(timedFloat, in: text, all) {
                guard let v = number(f, 1, ns) else { continue }
                let isSeconds = ns.substring(with: f.range).lowercased().contains("s float")
                mins += (r - 1) * (isSeconds ? v / 60 : v)
                counted.append(f.range)
            }
        }

        // Any remaining bare duration — "25min", "~30–45 min", "60–75 min".
        for m in matches(minuteRange_, in: text, all) {
            if counted.contains(where: { NSIntersectionRange($0, m.range).length > 0 } ) { continue }
            guard let a = number(m, 1, ns), let b = number(m, 2, ns) else { continue }
            mins += (a + b) / 2
            counted.append(m.range)
        }
        for m in matches(minuteOne_, in: text, all) {
            if counted.contains(where: { NSIntersectionRange($0, m.range).length > 0 } ) { continue }
            guard let v = number(m, 1, ns) else { continue }
            mins += v
            counted.append(m.range)
        }
        return mins
    }

    /// km per hour for converting those minutes. The session's own stated pace
    /// band where there is one, otherwise the plan's easy pace — every session
    /// with no pace at all is a pointer run, and the plan writes those as easy.
    private static func paceKmPerHour(_ text: String, _ ns: NSString,
                                      _ all: NSRange) -> Double {
        var secPerKm = 360.0                       // 6:00 /km, the easy band
        if let m = paceBand.firstMatch(in: text, range: all),
           let m1 = number(m, 1, ns), let s1 = number(m, 2, ns),
           let m2 = number(m, 3, ns), let s2 = number(m, 4, ns) {
            secPerKm = ((m1 * 60 + s1) + (m2 * 60 + s2)) / 2
        } else if let m = paceSingle.firstMatch(in: text, range: all),
                  let mm = number(m, 1, ns), let ss = number(m, 2, ns) {
            secPerKm = mm * 60 + ss
        }
        return 3600 / max(secPerKm, 1)
    }

    /// Decimal commas only between digits — "20 km, last 6 km" must keep its
    /// comma as punctuation.
    private static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2",
                               options: .regularExpression)
    }

    private static func number(_ m: NSTextCheckingResult,
                               _ group: Int, _ ns: NSString) -> Double? {
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return Double(ns.substring(with: r))
    }

    private static func matches(_ re: NSRegularExpression,
                                in text: String,
                                _ range: NSRange) -> [NSTextCheckingResult] {
        re.matches(in: text, range: range)
    }

    private static let repBlock = re(#"(\d+)\s*[×x]\s*(\d+(?:\.\d+)?)\s*km"#)
    private static let warmCool = re(#"(\d+(?:\.\d+)?)\s*k\s*(?:WU|CD)"#, caseInsensitive: true)
    private static let plainKm  = re(#"(\d+(?:\.\d+)?)\s*km"#)
    private static let floatLeg = re(#"\((\d+(?:\.\d+)?)\s*k\s*float\)"#)
    private static let segmentWord = re(#"(?:last|final|first|opening|middle)\s+$"#,
                                        caseInsensitive: true)
    private static let bareWU   = re(#"(?<![\dk.])\s(?:WU|CD)\b"#)
    private static let timedWork = re(#"\d+\s*(?:min|h)\b"#)
    private static let paceToken = re(#"@\s*\d:\d\d"#)

    // Minute forms. `timedReps_` and `timedFloat` are matched first and their
    // ranges excluded, so "4×8min (2min float)" is not also counted as two
    // loose durations.
    private static let timedReps_  = re(#"(\d+)\s*[×x]\s*(\d+(?:\.\d+)?)\s*min"#)
    private static let timedFloat  = re(#"\((\d+(?:\.\d+)?)\s*(?:min|s)\s*float"#,
                                        caseInsensitive: true)
    private static let minuteRange_ = re(#"(\d+)\s*[–-]\s*(\d+)\s*min"#)
    private static let minuteOne_   = re(#"(\d+(?:\.\d+)?)\s*min"#)
    private static let paceBand    = re(#"@\s*(\d):(\d\d)\s*[–-]\s*(\d):(\d\d)"#)
    private static let paceSingle  = re(#"@\s*(\d):(\d\d)"#)

    private static func re(_ p: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // Every pattern here is a literal in this file; a failure would be a
        // programming error, not a runtime condition.
        try! NSRegularExpression(pattern: p,
                                 options: caseInsensitive ? [.caseInsensitive] : [])
    }
}

// MARK: - Empty fallback so the UI can render an error instead of crashing

extension Plan {
    static let empty = Plan(
        meta: Meta(plan: "—", week1Monday: "", raceDate: "",
                   targetTime: "—", targetPaceSecKm: 0),
        // `let fuel: Fuel?` gets NO default in the memberwise init — a let
        // optional is not implicitly nil, so this has to be spelled out.
        weeks: [], sessions: [], exercises: [], fuel: nil, warmup: nil
    )
}
