//
//  ProposalStore.swift
//  Sub4
//
//  Every monthly review that was run, kept.
//
//  WHY KEEP THEM
//  -------------
//  A single proposal is an opinion. Six of them in sequence are evidence about
//  whether this whole idea works: if October said "ease the easy runs", and
//  November said it again, and nothing changed in between, that is a finding
//  about the plan. If every month says something different, that is a finding
//  about the reviewer, and the right response is to stop running it.
//
//  Neither of those is visible without a history, which is why this exists even
//  though nothing in the app acts on a proposal.
//
//  Each record keeps the EVIDENCE PACK it was based on, not just the answer.
//  Re-reading a verdict without the numbers it was drawn from is how you end up
//  trusting a conclusion you can no longer check — and the thresholds and
//  estimators in Review.swift will change over 34 weeks, so the same window
//  would not produce the same pack twice.
//
//  Like NotesStore, this is ORIGINAL data. It cannot be regenerated: the same
//  request a month later reaches a model in a different state, over data that
//  has moved. So the schema check migrates rather than clears, and there is no
//  reset button.
//

import Foundation

@Observable
final class ProposalStore {

    static let shared = ProposalStore()

    struct Record: Codable, Identifiable, Hashable {
        var id: String                  // window start→end, plus run count
        var ranAt: Date
        var windowLabel: String
        var startDay: String
        var endDay: String
        /// The full markdown the model was given. See the header.
        var evidence: String
        var proposal: ReviewProposal
        /// Which build produced it — thresholds move.
        var appVersion: String
        var model: String
    }

    private(set) var records: [Record] = []

    private let fileURL: URL
    private let schemaKey = "proposals.schema"
    private let schemaVersion = 1

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("proposals.json")
        load()
        migrateIfNeeded()
    }

    // MARK: Reading

    /// Newest first — the order they are read in.
    var newestFirst: [Record] { records.sorted { $0.ranAt > $1.ranAt } }

    var latest: Record? { newestFirst.first }

    var count: Int { records.count }

    /// Previous runs covering the same window. Non-empty means this month has
    /// already been reviewed, which is worth saying before spending another
    /// call on it.
    func existing(startDay: String, endDay: String) -> [Record] {
        records.filter { $0.startDay == startDay && $0.endDay == endDay }
    }

    // MARK: Writing

    @discardableResult
    func add(review: Review, proposal: ReviewProposal, evidence: String) -> Record {
        let n = existing(startDay: review.window.startDay,
                         endDay: review.window.endDay).count
        let r = Record(
            // UUID suffix, not a running count: deleting record 1 would
            // make the next add produce id 2 again and collide in the list.
            id: "\(review.window.startDay)_\(review.window.endDay)_"
                + "\(n + 1)-\(UUID().uuidString.prefix(6))",
            ranAt: Date(),
            windowLabel: review.window.label,
            startDay: review.window.startDay,
            endDay: review.window.endDay,
            evidence: evidence,
            proposal: proposal,
            appVersion: AppVersion.stamp,
            model: ClaudeConfig.model)
        records.append(r)
        save()
        return r
    }

    /// Deleting one record is allowed — deleting the history is not offered
    /// anywhere, for the reason in the header.
    func remove(_ record: Record) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records.remove(at: i)
        save()
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder.sub4.decode([Record].self, from: data)) ?? []
    }


    /// Drops everything held in memory WITHOUT writing to disk.
    ///
    /// The counterpart to `DataLifecycleCoordinator.deleteEverything`, and the
    /// reason it is not simply `resetCache`: reset saves an empty file, which
    /// after a delete recreates the very store that was just removed. Worse,
    /// leaving the in-memory copy alive means the next save resurrects the
    /// whole history from RAM — a delete that undoes itself the first time the
    /// app touches the store. Nothing here writes.
    func dropInMemory() {
        records = []
    }

    /// THE ONE THAT IS NOT RE-FETCHABLE, and the reason it is here rather
    /// than with the notes.
    ///
    /// A monthly review costs a call to a model and cannot be reproduced by
    /// asking Strava again. But it is written by the review runner, not by an
    /// editor the athlete is sitting in front of — there is no sheet to hold
    /// open and no text field to copy from. So it takes the journal's route
    /// and keeps the record in memory, where the export can still reach it.
    ///
    /// First real run is 24 August 2026. If a write ever fails there, the
    /// unsaved row in Settings is the difference between noticing that day and
    /// noticing next month.
    private func save() {
        StoreWriteJournal.shared.attempt("proposals.json") {
            try StoreWrite.encode(records, to: fileURL, store: "proposals.json")
        }
    }

    private func migrateIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: schemaKey)
        guard stored != schemaVersion else { return }
        UserDefaults.standard.set(schemaVersion, forKey: schemaKey)
    }

    // MARK: Export

    /// One record as Markdown — the verdict, the reasoning, the changes, and
    /// the evidence it was drawn from, in that order.
    func markdown(_ r: Record) -> String {
        var m = "# Sub4 — review proposal\n\n"
        m += "**\(r.proposal.verdictLabel)** · \(r.windowLabel) "
        m += "(\(r.startDay) → \(r.endDay))\n\n"
        m += "_\(r.model) · confidence \(r.proposal.confidence)/5 · \(r.appVersion)_\n\n"
        m += "\(r.proposal.summary)\n\n"

        m += "## Reasoning\n\n\(r.proposal.reasoning)\n\n"

        let accepted = r.proposal.acceptedChanges(plan: PlanStore.shared)
        if accepted.isEmpty {
            m += "## Changes\n\nNone proposed.\n\n"
        } else {
            m += "## Proposed changes\n\n"
            m += "Nothing here has been applied — the app does not modify the "
            m += "plan.\n\n"
            for c in accepted {
                m += "### `\(c.sessionUid)`\n\n"
                m += c.skip ? "**Skip this session.**\n\n"
                            : "**New prescription:** \(c.newDetail)\n\n"
                m += "- Evidence: \(c.evidence)\n- Reason: \(c.reason)\n\n"
            }
        }

        let rejected = r.proposal.rejections(plan: PlanStore.shared)
        if !rejected.isEmpty {
            m += "## Rejected by the guardrails\n\n"
            // Not `r` — that is the Record parameter, and shadowing it here
            // would make `r.proposal` mean something different inside the loop
            // than three lines above it.
            for rej in rejected {
                m += "- `\(rej.change.sessionUid)` — \(rej.why)\n"
            }
            m += "\n"
        }

        if !r.proposal.watchFor.isEmpty {
            m += "## Watch for next month\n\n"
            for w in r.proposal.watchFor { m += "- \(w)\n" }
            m += "\n"
        }

        m += "---\n\n# The evidence it was given\n\n\(r.evidence)\n"
        return m
    }

    func writeMarkdown(_ r: Record) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-proposal-\(r.startDay)-to-\(r.endDay).md")
        guard let data = markdown(r).data(using: .utf8) else { return nil }
        do {
            // Temporary, but it holds the same words as the store it came
            // from, so it gets the same protection class — patch 190.
            try data.write(to: url, options: FileProtection.options)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Running one

enum ReviewRunner {

    /// Builds the pack, sends it, stores the answer. Throws rather than
    /// swallowing: the caller has a screen to put the error on.
    /// Builds the review and the payload, and sends NOTHING.
    ///
    /// Split from `run` in patch 192 so a preflight screen can sit between
    /// them. The payload this returns is the value the athlete is shown and the
    /// value that is then handed back to `run` — so what they read and what the
    /// provider receives cannot differ. A single `run(weeksBack:)` that did
    /// both would make that guarantee impossible to state.
    @MainActor
    static func prepare(weeksBack: Int = 4) throws -> (Review, ReviewPayload) {
        guard let review = ReviewBuilder.build(weeksBack: weeksBack) else {
            throw ClaudeError.badShape("no finished plan weeks to review yet")
        }
        return (review, review.payload())
    }

    /// Sends the payload exactly as configured and stores the answer. Throws
    /// rather than swallowing: the caller has a screen to put the error on.
    @MainActor
    static func run(review: Review,
                    payload: ReviewPayload) async throws -> ProposalStore.Record {
        // The refusal, restated at the boundary. `prompt` returns nil for an
        // unusable payload; turning that into a thrown error here means a
        // caller cannot accidentally send an empty string.
        guard let evidence = ReviewRequest.prompt(payload: payload,
                                                  review: review,
                                                  plan: PlanStore.shared) else {
            throw ClaudeError.badShape(
                "this review cannot be sent — "
                + payload.blocked.map(\.title).joined(separator: ", ")
                + " are computed from Strava activities and may not go to an AI "
                + "provider (ADR-0002). The review is rebuilt on Apple Health "
                + "figures at Phase 4A.")
        }
        var proposal = try await ClaudeClient.structured(
            prompt: evidence,
            system: ReviewRequest.system,
            schema: ReviewRequest.schema,
            as: ReviewProposal.self)

        // The API strips numeric bounds from schemas, so 1–5 is enforced here.
        proposal.confidence = min(max(proposal.confidence, 1), 5)

        return ProposalStore.shared.add(review: review, proposal: proposal,
                                        evidence: evidence)
    }
}
