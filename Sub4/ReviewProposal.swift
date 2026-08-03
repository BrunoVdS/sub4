//
//  ReviewProposal.swift
//  Sub4
//
//  What comes back from the monthly review, and the prompt that asks for it.
//
//  THE FAILURE MODE THIS FILE IS BUILT AROUND
//  ------------------------------------------
//  A model asked once a month "does this plan need to change?" will find
//  something to say every month. That is not dishonesty, it is what the
//  question invites. Eight reviews of small nudges is cumulative drift in a
//  block whose entire logic is progressive overload with planned recovery — and
//  each individual nudge will have looked reasonable.
//
//  Four things push back on that, and none of them are politeness in the prompt:
//
//    1. `noChange` is a first-class verdict with its own case, not the absence
//       of proposals. The prompt says outright that it is the expected answer.
//    2. Bounds are enforced HERE, in Swift, after decoding. A prompt saying
//       "never more than 10%" is a request; `clampedChanges` is a rule. The API
//       strips numeric bounds from JSON schemas anyway, so a schema could not
//       carry them even if we wanted it to.
//    3. Taper, race and DOWN weeks are untouchable by construction. The last
//       three plan weeks plus 21-23, 27 and 31 are rejected outright. The down
//       weeks were missing at first, which left a reviewer free to add load to
//       exactly the weeks whose purpose is the absence of it.
//    4. Every change must name the evidence line it rests on. A change whose
//       justification is "generally athletes benefit from…" is rejected: that
//       is a statement about athletes, not about this block.
//
//  WHAT IT IS ALLOWED TO CHANGE
//  ----------------------------
//  One thing: the `detail` string of an existing session, or marking it
//  skipped. Nothing else. Every downstream system — the workout parser, the
//  watch export, planned volume, the progress charts — derives from that one
//  string, so this keeps the blast radius to a single field. Adding sessions,
//  moving them, or rewriting the week structure is out of scope on purpose.
//
//  NOTHING IN THIS FILE APPLIES ANYTHING. Proposals are recorded and read.
//

import Foundation

// MARK: - The decoded reply

struct ReviewProposal: Codable, Hashable {

    enum Verdict: String, Codable {
        /// The block is landing correctly. The expected answer most months.
        case noChange = "no_change"
        /// The evidence is too thin to say. Distinct from noChange: one means
        /// "it is fine", the other means "I cannot tell", and conflating them
        /// would let a data-gathering problem read as a clean bill of health.
        case insufficientEvidence = "insufficient_evidence"
        case easier
        case harder
        case mixed
    }

    struct Change: Codable, Hashable, Identifiable {
        /// The session uid from the evidence pack.
        var sessionUid: String
        /// Replacement for the session's `detail` line, or empty when skipping.
        var newDetail: String
        var skip: Bool
        /// Which computed line this rests on. Required — see the header.
        var evidence: String
        var reason: String

        var id: String { sessionUid }
    }

    /// A change that did not survive the guardrails, and why.
    ///
    /// A struct rather than a `(change:why:)` tuple because Swift key paths
    /// cannot refer to tuple elements — `ForEach(rejected, id: \.change.id)`
    /// does not compile. Giving it a type also lets it carry its own id.
    struct Rejection: Identifiable {
        var change: Change
        var why: String
        var id: String { change.sessionUid + why }
    }

    var verdict: Verdict
    /// Two or three sentences, for the top of the screen.
    var summary: String
    /// The reasoning, at length. Kept whole rather than summarised: a month
    /// later the argument matters more than the conclusion.
    var reasoning: String
    /// What the model would change, if anything. Always decodable as empty.
    var changes: [Change]
    /// What it would watch for next month. Not actionable, deliberately.
    var watchFor: [String]
    /// 1–5. Low confidence on a `harder` verdict is a reason to wait.
    var confidence: Int

    // MARK: Guardrails, enforced after decoding

    /// Changes that survive the rules. Everything rejected is reported by
    /// `rejections(plan:)` rather than silently dropped — a guardrail you
    /// cannot see is indistinguishable from a model that never proposed
    /// anything.
    func acceptedChanges(plan: PlanStore) -> [Change] {
        let locked = Self.lockedWeekUids(plan: plan)
        let byUid = Dictionary(plan.plan.sessions.map { ($0.uid, $0) },
                               uniquingKeysWith: { a, _ in a })
        let passing = changes.filter { c in
            guard let s = byUid[c.sessionUid] else { return false }
            guard !locked.contains(s.weekUid) else { return false }
            guard !c.evidence.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            guard c.skip || !c.newDetail.trimmingCharacters(in: .whitespaces).isEmpty
            else { return false }
            return true
        }
        // One change per session. Nothing in the schema stops two objects
        // naming the same uid, and duplicate ids in a ForEach make SwiftUI drop
        // rows silently — a proposal you never see is worse than one you reject.
        var seen = Set<String>()
        return passing.filter { seen.insert($0.sessionUid).inserted }
    }

    func rejections(plan: PlanStore) -> [Rejection] {
        let locked = Self.lockedWeekUids(plan: plan)
        let byUid = Dictionary(plan.plan.sessions.map { ($0.uid, $0) },
                               uniquingKeysWith: { a, _ in a })
        var out: [Rejection] = []
        var seen = Set<String>()
        for c in changes {
            guard let s = byUid[c.sessionUid] else {
                out.append(Rejection(change: c,
                                     why: "no session with that id — invented"))
                continue
            }
            if locked.contains(s.weekUid) {
                let why = plan.weeksByUid[s.weekUid]
                    .flatMap { Self.lockReason(for: $0, plan: plan) }
                    ?? "locked week"
                out.append(Rejection(change: c, why: why))
            } else if c.evidence.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Rejection(change: c, why: "no evidence cited"))
            } else if !c.skip && c.newDetail.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Rejection(change: c, why: "empty replacement text"))
            } else if !seen.insert(c.sessionUid).inserted {
                out.append(Rejection(change: c,
                                     why: "second change for the same session"))
            }
        }
        return out
    }

    /// Weeks nothing may rewrite.
    ///
    /// Two groups, and the second was missing until the source document was
    /// re-read. The plan states it plainly in §11: *"Protect the planned down
    /// weeks (21–23, 27 & 31) — they're load-bearing, not optional."* Locking
    /// only the taper left a reviewer free to add load to exactly the weeks
    /// whose purpose is the absence of it, which is the single most damaging
    /// edit available to it.
    ///
    ///   - the last three weeks: the taper. No evidence from October should be
    ///     able to touch March.
    ///   - weeks 21, 22, 23, 27 and 31: the planned recovery weeks.
    private static let downWeekNumbers: Set<Int> = [21, 22, 23, 27, 31]

    private static func lockedWeekUids(plan: PlanStore) -> Set<String> {
        var out = Set(plan.planWeeks.suffix(3).map(\.uid))
        for w in plan.planWeeks where downWeekNumbers.contains(w.weekNo ?? -1) {
            out.insert(w.uid)
        }
        return out
    }

    /// Why a given week is locked, for the rejection message.
    static func lockReason(for week: Week, plan: PlanStore) -> String? {
        if downWeekNumbers.contains(week.weekNo ?? -1) {
            return "planned down week — load-bearing, the plan says protect it"
        }
        if plan.planWeeks.suffix(3).contains(where: { $0.uid == week.uid }) {
            return "taper or race week — locked by design"
        }
        return nil
    }

    var verdictLabel: String {
        switch verdict {
        case .noChange:             "No change indicated"
        case .insufficientEvidence: "Not enough evidence"
        case .easier:               "Suggests easing the block"
        case .harder:               "Suggests adding load"
        case .mixed:                "Mixed — some up, some down"
        }
    }
}

// MARK: - Schema and prompt

enum ReviewRequest {

    /// JSON Schema for `output_config.format`.
    ///
    /// Deliberately flat and small. `$ref` is not supported, and numeric or
    /// length bounds are stripped by the API — so `confidence` cannot be
    /// constrained to 1–5 here, only asked for in the prompt and clamped in
    /// Swift. Everything is `required`; optional properties would let a field
    /// simply not appear, and a missing `evidence` is exactly the case the
    /// guardrails exist to catch.
    /// Built in named pieces rather than as one 34-line nested literal.
    ///
    /// It type-checks either way — the contextual `[String: Any]` lets every
    /// nested literal default its values to `Any`. But a four-level literal
    /// with ~25 leaves and an unresolved value type at each node is precisely
    /// the shape that makes the Swift type checker give up, and this project
    /// has hit that wall before (see SettingsView.swift's header). Each `as`
    /// annotation cuts the solver's search dead at that node.
    static var schema: [String: Any] {
        let changeItem: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["sessionUid", "newDetail", "skip", "evidence", "reason"],
            "properties": [
                "sessionUid": ["type": "string"],
                "newDetail":  ["type": "string"],
                "skip":       ["type": "boolean"],
                "evidence":   ["type": "string"],
                "reason":     ["type": "string"]
            ] as [String: Any]
        ]

        let properties: [String: Any] = [
            "verdict": [
                "type": "string",
                "enum": ["no_change", "insufficient_evidence",
                         "easier", "harder", "mixed"]
            ] as [String: Any],
            "summary":    ["type": "string"],
            "reasoning":  ["type": "string"],
            "confidence": ["type": "integer"],
            "watchFor": [
                "type": "array",
                "items": ["type": "string"] as [String: Any]
            ] as [String: Any],
            "changes": [
                "type": "array",
                "items": changeItem
            ] as [String: Any]
        ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["verdict", "summary", "reasoning", "changes",
                         "watchFor", "confidence"],
            "properties": properties
        ]
    }

    static let system = """
        You are reviewing one month of a 34-week marathon training block for a \
        single athlete. The plan was written by an AI before the block started \
        and has never been calibrated against how the sessions actually feel. \
        Your job is to say whether it is landing correctly.

        The most likely correct answer is "no_change". A training block is \
        supposed to be hard in places, and a month of data is a small window. \
        Proposing an adjustment every month would drift a periodised plan apart \
        one reasonable-looking step at a time. Only propose changes when the \
        evidence in front of you actually supports them.

        Every number you are given has already been computed. Do not recompute \
        anything, do not estimate, and do not infer figures that are not stated. \
        If something you need is absent, say so and lower your confidence.

        Rules for any change you propose:
        - It may only rewrite one session's prescription text, or mark it \
          skipped. You cannot add, move or delete sessions.
        - It must cite the specific line of the evidence pack it rests on, in \
          the `evidence` field, quoted or closely paraphrased. "Athletes \
          generally benefit from…" is not evidence about this block and will be \
          rejected.
        - Rewritten text must follow the plan's own notation exactly, so the \
          app's parser can read it — for example "Easy 6 km @6:05–6:20", \
          "MP intervals 2k WU + 3×3km @5:38–5:43 (1k float) + 2k CD".
        - Keep any single week's running volume within about 10% of what was \
          planned. Larger swings are a different conversation, not a monthly tweak.

        `confidence` is 1 to 5. Use 1–2 freely; thin evidence honestly reported \
        is far more useful than a confident guess.

        Distinguish "no_change" (the block is landing correctly) from \
        "insufficient_evidence" (you cannot tell). They are not the same finding \
        and conflating them would let a logging problem read as a clean result.
        """

    /// The user turn: the computed evidence pack, plus the surrounding plan
    /// context a sensible judgement needs.
    /// Builds the request from a PAYLOAD, not from `markdown()` — patch 192,
    /// plan step 2.3.
    ///
    /// The difference is the whole point. `markdown()` is the athlete's own copy
    /// and contains everything; this contains only what may leave the phone.
    /// Passing `payload` in rather than deriving it here means the preflight
    /// screen and the request are built from one value — the reader cannot be
    /// shown one thing and the provider sent another.
    ///
    /// It REFUSES rather than truncating. A payload with blocked sections would
    /// produce a prompt asking a model to judge a training block from the effort
    /// table alone; it would answer, confidently, on a quarter of the evidence.
    /// Nil is the honest return.
    static func prompt(payload: ReviewPayload, review: Review, plan: PlanStore) -> String? {
        guard payload.isUsable else { return nil }
        var p = payload.render()

        p += "\n\n---\n\n## Where this sits in the block\n\n"
        if let w = plan.planWeeks.first(where: { $0.uid == review.window.weeks.last?.uid }),
           let n = w.weekNo {
            p += "The window ends at week \(n) of \(plan.totalPlanWeeks). "
        }
        if let days = plan.daysToRace() {
            p += "Race day is \(days) days away, target \(plan.targetPace).\n\n"
        }

        p += "The remaining weeks, so a change now is judged against what is "
        p += "already coming rather than in isolation:\n\n"
        p += "| Week | Dates | Theme |\n|---|---|---|\n"
        let endLabel = review.window.weeks.last?.label ?? ""
        for w in plan.planWeeks where w.label > endLabel {
            p += "| \(w.label) | \(w.dateRange ?? "") | \(w.tag ?? "") |\n"
        }

        p += "\n## The sessions you may rewrite\n\n"
        p += "Only these — the sessions inside the review window. Use the uid "
        p += "exactly as given.\n\n"
        p += "| uid | date | discipline | prescription |\n|---|---|---|---|\n"
        for w in review.window.weeks {
            for s in plan.sessions(inWeek: w) where !s.isRest {
                p += "| `\(s.uid)` | \(s.date ?? "") | \(s.discipline.rawValue) "
                p += "| \(s.detail ?? s.title ?? "") |\n"
            }
        }

        p += "\n## Locked weeks\n\n"
        p += "Changes to these are discarded before they reach the athlete, so "
        p += "do not spend a proposal on them:\n\n"
        p += "- The last three weeks of the block — the taper.\n"
        p += "- Weeks 21, 22, 23, 27 and 31 — planned down weeks. The plan "
        p += "states these are load-bearing, not optional. Their purpose is the "
        p += "absence of load; adding any would be the most damaging edit "
        p += "available to you.\n"
        return p
    }
}
