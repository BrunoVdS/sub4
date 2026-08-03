//
//  PlanWorkout.swift
//  Sub4
//
//  Turns a plan session's prose into a structured workout: warmup, interval
//  blocks, steady steps, cooldown, each with a goal and an optional pace band.
//
//  This is the piece WorkoutKit needs, and it is the piece most likely to be
//  wrong, so it is deliberately separate from anything that talks to the Watch.
//  Nothing here imports WorkoutKit — you can read every parse in the app and
//  check it before a single workout is sent anywhere.
//
//  DESIGN NOTE — WHY IT READS LEFT TO RIGHT
//  ----------------------------------------
//  The first version matched on form: "does it have a warm-up? then it's an
//  interval session". That silently discarded whatever the chosen branch wasn't
//  looking for — "Easy + strides 6 km @5:45–6:00 + 4×20s strides" came out as
//  four strides and no run. Four sessions were wrong the same way.
//
//  So it tokenises every quantity WITH its position, sorts by position, and
//  emits in order. Reading left to right cannot lose a token.
//
//  Validated against all 103 run sessions in the plan: 92 parse, 11 refuse.
//  The 11 are the "(pointer) — by feel, leave the watch" runs and the field
//  test, which state no structure on purpose. Refusing is correct there: a
//  wrong workout is worse than no workout, because you'd trust it mid-session.
//

import Foundation

// MARK: - Model

struct PlanWorkout: Hashable {
    let sessionUid: String
    let title: String
    let sourceText: String
    var steps: [PlanStep]
    var notes: [String]

    /// Total prescribed distance. Blocks count their reps and the floats
    /// BETWEEN them — n reps have n−1 recoveries, not n.
    var totalKm: Double? {
        var sum = 0.0
        for s in steps {
            if s.kind == .block {
                if case .distance(let km) = s.goal { sum += Double(s.iterations) * km }
                if let r = s.recoveryGoal, case .distance(let km) = r {
                    sum += Double(max(s.iterations - 1, 0)) * km
                }
            } else if case .distance(let km) = s.goal {
                sum += km
            }
        }
        return sum > 0 ? sum : nil
    }

    /// True when some part is prescribed by time, so the distance total is a
    /// floor rather than the whole session.
    var hasTimedParts: Bool {
        steps.contains { s in
            if case .time = s.goal { return true }
            if let r = s.recoveryGoal, case .time = r { return true }
            return false
        }
    }

    var hasIntervals: Bool { shape == .intervals }

    /// Strides are not intervals. A block of 20-second efforts tacked onto an
    /// easy run is a different session from 4×8 min at threshold, and calling
    /// both "Intervals" tells you nothing.
    enum Shape: String {
        case steady = "Steady"
        case strides = "Easy + strides"
        case intervals = "Intervals"
    }

    var shape: Shape {
        let blocks = steps.filter { $0.kind == .block }
        guard !blocks.isEmpty else { return .steady }
        let allShort = blocks.allSatisfy { b in
            if case .time(let s) = b.goal { return s <= 60 && b.pace == nil }
            return false
        }
        return allShort ? .strides : .intervals
    }

    /// How many things the Watch actually steps through.
    ///
    /// THE FLOAT GOES BETWEEN REPS, NOT AFTER THE LAST ONE. "2×4 km with 1 km
    /// float" is 4 / 1 / 4 — five legs with the warm-up and cool-down, not six.
    /// A block repeated literally would append a trailing float, which is a
    /// kilometre nobody asked you to run, and it's what `totalKm` has always
    /// assumed (n−1 recoveries). This now agrees with it.
    ///
    /// The WorkoutKit mapping has to honour the same rule: n−1 recoveries, so
    /// an IntervalBlock of [work, recovery] × n is WRONG.
    var legCount: Int {
        steps.reduce(0) { total, s in
            guard s.kind == .block else { return total + 1 }
            return total + s.iterations + (s.recoveryGoal != nil ? s.iterations - 1 : 0)
        }
    }

    /// The literal sequence the Watch would run, blocks unrolled.
    struct Leg: Identifiable {
        let id: Int
        let label: String
        let goal: PlanStep.Goal
        let pace: PlanStep.Pace?
        let isEffort: Bool
        var goalLabel: String { PlanStep.label(goal) }
    }

    var legs: [Leg] {
        var out: [Leg] = []
        for s in steps {
            guard s.kind == .block else {
                out.append(Leg(id: out.count, label: s.kind.rawValue.capitalized,
                               goal: s.goal, pace: s.pace, isEffort: s.kind == .work))
                continue
            }
            for i in 1...max(s.iterations, 1) {
                out.append(Leg(id: out.count,
                               label: s.iterations > 1 ? "Rep \(i) of \(s.iterations)" : "Work",
                               goal: s.goal, pace: s.pace, isEffort: true))
                if let rg = s.recoveryGoal, i < s.iterations {
                    out.append(Leg(id: out.count, label: "Float", goal: rg,
                                   pace: s.recoveryPace, isEffort: false))
                }
            }
        }
        return out
    }
}

struct PlanStep: Hashable, Identifiable {

    enum Kind: String, Hashable {
        case warmup, work, cooldown, block
    }

    enum Goal: Hashable {
        case distance(Double)      // km
        case time(Int)             // seconds
        case open
    }

    /// Seconds per kilometre. `fast` is the lower number.
    struct Pace: Hashable {
        let fast: Int
        let slow: Int

        /// "5:45–6:00" — no unit. For the two places a unit does not fit: a
        /// dense row, or a column already headed with one.
        var label: String {
            fast == slow ? Self.fmt(fast) : "\(Self.fmt(fast))–\(Self.fmt(slow))"
        }

        /// "5:45–6:00 min/km" — the form to reach for by default.
        ///
        /// The unit lives on the TYPE rather than being appended at each call
        /// site. `label` feeds the session card, the watch preview and the Week
        /// row, and three appends are three chances to forget one — which is
        /// exactly how "6:00 /km" survived on Progress until patch 82.
        var labelled: String { label + " min/km" }

        /// Seconds per km against a reference — the plan's marathon target.
        /// Positive is slower. nil when the band straddles the reference, where
        /// "1 s faster to 3 s slower" says less than nothing.
        func offset(from reference: Int) -> (fast: Int, slow: Int)? {
            let a = fast - reference, b = slow - reference
            guard a.signum() == b.signum(), a != 0 else { return nil }
            return (a, b)
        }

        nonisolated static func fmt(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    }

    let id: Int
    let kind: Kind
    let goal: Goal
    let pace: Pace?

    // Block only.
    var iterations: Int = 1
    var recoveryGoal: Goal?
    var recoveryPace: Pace?

    var goalLabel: String { PlanStep.label(goal) }
    var recoveryLabel: String? { recoveryGoal.map(PlanStep.label) }

    nonisolated static func label(_ g: Goal) -> String {
        switch g {
        case .distance(let km):
            return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
        case .time(let s):
            return s < 60 ? "\(s)s" : (s % 60 == 0 ? "\(s / 60) min"
                                                   : String(format: "%.1f min", Double(s) / 60))
        case .open:
            return "open"
        }
    }
}

// MARK: - Parser

enum WorkoutParser {

    /// nil means "this session states no structure" — with the reason.
    static func parse(_ session: Session) -> (workout: PlanWorkout?, reason: String?) {
        guard session.discipline == .run else { return (nil, "not a run") }

        let raw = [session.title, session.detail].compactMap { $0 }.joined(separator: " ")
        // "90s float" is the only recovery written in seconds; normalising it
        // here keeps the float token single-form.
        let text = raw.replacingOccurrences(of: "90s float", with: "1.5min float")

        if text.contains("(pointer)") || text.contains("no targets")
            || text.contains("or field test") {
            return (nil, "deliberately unstructured — the plan says leave the watch")
        }
        guard firstPace(text, from: 0) != nil else {
            return (nil, "no pace target stated")
        }

        let toks = scan(text)
        var steps: [PlanStep] = []
        var notes: [String] = []
        var next = 0
        func add(_ s: PlanStep) { steps.append(s); next += 1 }

        let segTok   = toks.first { $0.name == .seg }
        let repsTok  = toks.first { $0.name == .reps }
        let distToks = toks.filter { $0.name == .dist }

        // A long run with a target section inside it: "22 km, last 8 km @MP".
        // The section is PART of the total, never additional.
        if let seg = segTok, let first = distToks.first {
            guard let total = num(first.m, 1, text) else { return (nil, "unreadable distance") }
            let where_ = str(seg.m, 1, text).lowercased()
            guard let part = num(seg.m, 2, text), part < total else {
                return (nil, "target section is longer than the run")
            }
            let target = firstPace(text, from: seg.m.range.upperBound)
            let rest = total - part
            switch where_ {
            case "last":
                add(PlanStep(id: next, kind: .work, goal: .distance(rest), pace: nil))
                add(PlanStep(id: next, kind: .work, goal: .distance(part), pace: target))
            case "first":
                add(PlanStep(id: next, kind: .work, goal: .distance(part), pace: target))
                add(PlanStep(id: next, kind: .work, goal: .distance(rest), pace: nil))
            default:
                add(PlanStep(id: next, kind: .work, goal: .distance(rest / 2), pace: nil))
                add(PlanStep(id: next, kind: .work, goal: .distance(part), pace: target))
                add(PlanStep(id: next, kind: .work, goal: .distance(rest / 2), pace: nil))
            }
            return (PlanWorkout(sessionUid: session.uid, title: session.title ?? "Run",
                                sourceText: raw, steps: steps, notes: notes), nil)
        }

        // Blocks stated INSIDE a total: "Long + MP blocks 24 km, 2×6km (1.5k float)".
        // Distinguished from "5 km easy + 3×1min" — which is additive — by the
        // comma, and by the blocks fitting inside the stated total.
        var blocksAreInside = false
        var leadKm = 0.0
        var tailKm = 0.0
        if let reps = repsTok, let first = distToks.first, first.start < reps.start {
            let unit = str(reps.m, 3, text)
            let between = substring(text, first.start, reps.start)
            if unit == "km", between.contains(","),
               let total = num(first.m, 1, text),
               let n = num(reps.m, 1, text), let amt = num(reps.m, 2, text) {
                let flo = toks.first { $0.name == .float && $0.start > reps.start }
                var floatKm = 0.0
                if let f = flo, let v = num(f.m, 1, text) {
                    let fu = str(f.m, 2, text).lowercased()
                    if fu == "k" || fu == "km" { floatKm = v }
                }
                let blockKm = n * amt + (n - 1) * floatKm
                if blockKm < total {
                    blocksAreInside = true
                    // Round ONE side and derive the other, so the parts always
                    // sum to the stated total. Rounding both independently made
                    // "24 km, 2×6km (1.5k float)" come out as 24.1 — the lead is
                    // 5.25 km, rounded up twice.
                    let remainder = total - blockKm
                    leadKm = (remainder / 2 * 10).rounded() / 10
                    tailKm = ((remainder - leadKm) * 10).rounded() / 10
                    add(PlanStep(id: next, kind: .work, goal: .distance(leadKm), pace: nil))
                }
            }
        }

        for tok in toks {
            switch tok.name {
            case .wu:
                if let v = num(tok.m, 1, text) {
                    add(PlanStep(id: next, kind: .warmup, goal: .distance(v), pace: nil))
                }
            case .cd:
                if let v = num(tok.m, 1, text) {
                    add(PlanStep(id: next, kind: .cooldown, goal: .distance(v), pace: nil))
                }
            case .cdBare:
                add(PlanStep(id: next, kind: .cooldown, goal: .open, pace: nil))
            case .easyK:
                if let v = num(tok.m, 1, text) {
                    add(PlanStep(id: next, kind: .work, goal: .distance(v), pace: nil))
                }
            case .dist:
                if blocksAreInside, tok.start == distToks.first?.start { continue }
                guard let v = num(tok.m, 1, text) else { continue }
                if let hi = num(tok.m, 2, text) {
                    notes.append(String(format: "Plan says %g–%g km — using the lower bound", v, hi))
                }
                add(PlanStep(id: next, kind: .work, goal: .distance(v),
                             pace: firstPace(text, from: tok.m.range.upperBound)))
            case .reps:
                guard let n = num(tok.m, 1, text), let amt = num(tok.m, 2, text) else { continue }
                let unit = str(tok.m, 3, text)
                var step = PlanStep(id: next, kind: .block,
                                    goal: goal(amt, unit),
                                    pace: firstPace(text, from: tok.m.range.upperBound),
                                    iterations: Int(n))
                if let f = toks.first(where: { $0.name == .float && $0.start > tok.start }),
                   let fv = num(f.m, 1, text) {
                    step.recoveryGoal = goal(fv, str(f.m, 2, text).lowercased())
                    if substring(text, f.start, f.m.range.upperBound).contains("@") {
                        // From the token's START, not its end. The float pattern
                        // swallows everything to the closing paren, so searching
                        // from `upperBound` starts AFTER "(2min float @6:00–6:15)"
                        // and finds either nothing or the next step's pace. Every
                        // float in this plan therefore had no recovery pace — on
                        // the preview, and in the workout sent to the watch.
                        step.recoveryPace = firstPace(text, from: f.start)
                    }
                } else if case .time(let secs) = step.goal, secs <= 60, step.pace == nil {
                    // Strides. The plan writes "4×20s strides" and never states
                    // the jog between, because to a runner it's implied. Parsed
                    // literally that becomes 80 seconds of continuous strides,
                    // which is not the session — so this is a deliberate
                    // assumption, surfaced in the preview rather than hidden.
                    step.recoveryGoal = .time(60)
                    notes.append("The jog between strides isn't stated — assuming "
                                 + "60s easy. Run through if you'd rather.")
                }
                add(step)
            case .float, .seg:
                continue                     // consumed by their block / handled above
            }
        }

        if blocksAreInside {
            add(PlanStep(id: next, kind: .cooldown, goal: .distance(tailKm), pace: nil))
        }

        // "2k WU + 25min @4:55–5:10 + CD" — a timed effort with no rep count.
        if steps.contains(where: { $0.kind == .warmup }),
           !steps.contains(where: { $0.kind == .block }),
           !steps.contains(where: { $0.kind == .work }),
           let m = firstMatch(loneMinutes, in: text),
           let v = num(m, 1, text),
           let at = steps.firstIndex(where: { $0.kind == .warmup }) {
            steps.insert(PlanStep(id: 999, kind: .work, goal: .time(Int(v * 60)),
                                  pace: firstPace(text, from: m.range.upperBound)),
                         at: at + 1)
        }

        if firstMatch(bareStrides, in: text) != nil {
            notes.append("Strides are stated without a duration — omitted")
        }
        guard !steps.isEmpty else { return (nil, "nothing quantifiable in the text") }

        return (PlanWorkout(sessionUid: session.uid, title: session.title ?? "Run",
                            sourceText: raw, steps: steps, notes: notes), nil)
    }

    // MARK: Tokens

    private enum Token { case wu, cd, easyK, reps, float, seg, dist, cdBare }
    private struct Hit { let start: Int; let name: Token; let m: NSTextCheckingResult }

    /// Priority order matters — earlier patterns claim their text first, so
    /// "2k WU" is never also read as a bare distance.
    private static let patterns: [(Token, NSRegularExpression)] = [
        (.wu,     re(#"(\d+(?:\.\d+)?)\s*k\s*WU"#, ci: true)),
        (.cd,     re(#"(\d+(?:\.\d+)?)\s*k\s*CD"#, ci: true)),
        (.easyK,  re(#"(\d+(?:\.\d+)?)\s*k\s+easy"#, ci: true)),
        (.reps,   re(#"(\d+)\s*[×x]\s*(\d+(?:\.\d+)?)\s*(km|min|s)\b"#)),
        (.float,  re(#"\((\d+(?:\.\d+)?)\s*(k|km|min|s)\s*float[^)]*\)"#, ci: true)),
        (.seg,    re(#"\b(last|final|first|opening|middle)\s+(\d+(?:\.\d+)?)\s*km"#, ci: true)),
        (.dist,   re(#"(\d+(?:\.\d+)?)(?:\s*[–\-]\s*(\d+(?:\.\d+)?))?\s*km"#)),
        (.cdBare, re(#"(?<![\dk.])\bCD\b"#)),
    ]

    private static let paceRx      = re(#"@\s*(\d):(\d\d)(?:\s*[–\-]\s*(\d):(\d\d))?"#)
    private static let loneMinutes = re(#"(?<![×x]\s)(\d+(?:\.\d+)?)\s*min\b"#)
    private static let bareStrides = re(#"\+\s*\d+\s+strides"#)

    private static func scan(_ text: String) -> [Hit] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []
        var claimed: [NSRange] = []
        for (name, rx) in patterns {
            for m in rx.matches(in: text, range: all) {
                let overlaps = claimed.contains { NSIntersectionRange($0, m.range).length > 0 }
                if overlaps { continue }
                claimed.append(m.range)
                hits.append(Hit(start: m.range.location, name: name, m: m))
            }
        }
        return hits.sorted { $0.start < $1.start }
    }

    private static func goal(_ amount: Double, _ unit: String) -> PlanStep.Goal {
        switch unit.lowercased() {
        case "km", "k": return .distance(amount)
        case "min":     return .time(Int(amount * 60))
        default:        return .time(Int(amount))
        }
    }

    /// The pace band that follows `from` most closely — each quantity binds to
    /// the target written after it, which is how the plan reads.
    private static func firstPace(_ text: String, from: Int) -> PlanStep.Pace? {
        let ns = text as NSString
        let hits = paceRx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = hits.filter({ $0.range.location >= from })
            .min(by: { $0.range.location < $1.range.location }) else { return nil }
        guard let m1 = num(m, 1, text), let s1 = num(m, 2, text) else { return nil }
        let lo = Int(m1) * 60 + Int(s1)
        var hi = lo
        if let m2 = num(m, 3, text), let s2 = num(m, 4, text) { hi = Int(m2) * 60 + Int(s2) }
        return PlanStep.Pace(fast: min(lo, hi), slow: max(lo, hi))
    }

    // MARK: Regex helpers

    private static func num(_ m: NSTextCheckingResult, _ g: Int, _ text: String) -> Double? {
        let r = m.range(at: g)
        guard r.location != NSNotFound else { return nil }
        return Double((text as NSString).substring(with: r))
    }

    private static func str(_ m: NSTextCheckingResult, _ g: Int, _ text: String) -> String {
        let r = m.range(at: g)
        guard r.location != NSNotFound else { return "" }
        return (text as NSString).substring(with: r)
    }

    private static func substring(_ text: String, _ a: Int, _ b: Int) -> String {
        let ns = text as NSString
        let lo = max(0, min(a, ns.length)), hi = max(lo, min(b, ns.length))
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    private static func firstMatch(_ rx: NSRegularExpression,
                                   in text: String) -> NSTextCheckingResult? {
        rx.firstMatch(in: text,
                      range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func re(_ p: String, ci: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : [])
    }
}

// MARK: - Plan-wide coverage

extension WorkoutParser {

    struct Refusal: Identifiable {
        let id: String
        let title: String
        let reason: String
    }

    struct Coverage {
        var parsed: [PlanWorkout] = []
        var refused: [Refusal] = []
        var total: Int { parsed.count + refused.count }
    }

    /// Every run session in the plan, parsed. Used by the audit screen so the
    /// whole block can be checked at once rather than one session at a time.
    static func coverage(_ store: PlanStore = .shared) -> Coverage {
        var c = Coverage()
        let planUids = Set(store.planWeeks.map(\.uid))
        for s in store.plan.sessions
        where s.discipline == .run && planUids.contains(s.weekUid) {
            let r = parse(s)
            if let w = r.workout {
                c.parsed.append(w)
            } else {
                c.refused.append(Refusal(id: s.uid,
                                         title: s.title ?? "—",
                                         reason: r.reason ?? "unparsed"))
            }
        }
        return c
    }
}
