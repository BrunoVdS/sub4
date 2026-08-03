//
//  ReviewPayload.swift
//  Sub4
//
//  What a review would send, as a value — patch 192, plan step 2.3.
//
//  THE PROBLEM WITH A STRING
//  -------------------------
//  Until now the thing that would be sent to an AI provider was the return of
//  `Review.markdown()`: one string, several thousand words, assembled from
//  everything the app knows. You cannot ask a string which parts of it came
//  from Strava. You cannot leave the athlete's notes out of it without a second
//  string. And you certainly cannot show somebody what is about to leave their
//  phone in any form more useful than a wall of text.
//
//  Every one of those is a requirement — PRIV-03 asks for notes to be opt-in,
//  ADR-0002 forbids Strava-derived figures reaching an AI provider, and 2.3
//  asks for a preflight screen. All three are impossible against a string and
//  straightforward against a list of sections that each know where they came
//  from.
//
//  THE UNCOMFORTABLE RESULT, STATED UP FRONT
//  -----------------------------------------
//  Once each section declares its lineage, most of the review turns out to be
//  unsendable. Coverage, adherence, weekly volume and pace against plan are all
//  computed from matched Strava activities, and §5.3 and §5.10 of the Strava
//  API Policy prohibit passing that to an AI provider directly or indirectly.
//  What is left — the effort table, the notes, the thresholds — is not a
//  monthly review.
//
//  That is not a flaw in this file. It is ADR-0002's conclusion made concrete:
//  the review has to be rebuilt on Health-derived figures at Phase 4A, and
//  until then the `aiReview` gate stays shut. The value of typing the payload
//  now is that the preflight screen can say exactly WHICH fields block it,
//  rather than leaving "the gate is closed" as an unexplained fact.
//

import Foundation

// MARK: - One section

/// Why a section is or is not in a payload.
enum PayloadInclusion: Equatable {
    /// Always sent. Carries no personal data, or is the evidence the request is
    /// fundamentally about.
    case required
    /// The athlete chooses, and the default is OFF. PRIV-03: notes were in the
    /// payload by default, which is consent by omission.
    case optIn
    /// Cannot be sent at all, with the reason shown verbatim to the reader.
    case blocked(String)

    var canBeSent: Bool { if case .blocked = self { return false }; return true }
}

struct PayloadSection: Identifiable, Equatable {
    let id: String
    /// The heading a reader would recognise from the review itself.
    let title: String
    /// One line for the preflight screen. Plain language, no jargon: this is
    /// read by somebody deciding whether to press send.
    let what: String
    /// Where the numbers in this section came from. The same `DataSource` the
    /// privacy inventory uses, deliberately — one vocabulary for provenance
    /// across the whole app.
    let lineage: Set<DataSource>
    let inclusion: PayloadInclusion
    /// The rendered markdown. Held even when the section is blocked, so the
    /// preflight screen can show its size and the reader can see what is being
    /// withheld rather than taking it on trust.
    let body: String

    var isStravaDerived: Bool { lineage.contains(.strava) }
    var byteCount: Int { body.utf8.count }

    var sourceLabel: String {
        DataSource.allCases
            .filter { lineage.contains($0) }
            .map(\.label)
            .joined(separator: " + ")
    }
}

// MARK: - The whole payload

struct ReviewPayload {

    let sections: [PayloadSection]

    /// What the athlete has chosen to include among the opt-in sections.
    /// Empty by default, which is the point.
    var optedIn: Set<String> = []

    // MARK: What goes, and what does not

    /// Sections that would actually be transmitted right now.
    var sending: [PayloadSection] {
        sections.filter { s in
            switch s.inclusion {
            case .required:  true
            case .optIn:     optedIn.contains(s.id)
            case .blocked:   false
            }
        }
    }

    var blocked: [PayloadSection] {
        sections.filter { !$0.inclusion.canBeSent }
    }

    var optional: [PayloadSection] {
        sections.filter { $0.inclusion == .optIn }
    }

    /// Withheld because the athlete did not opt in — a different thing from
    /// blocked, and worth separating on the screen.
    var withheld: [PayloadSection] {
        optional.filter { !optedIn.contains($0.id) }
    }

    // MARK: Rendering

    /// The text that would be sent. Nothing else in the app may build this
    /// string, so there is exactly one answer to "what leaves the phone".
    func render() -> String {
        sections
            .filter { s in sending.contains(where: { $0.id == s.id }) }
            .map(\.body)
            .joined()
    }

    /// Everything, regardless of lineage or opt-in — the athlete's own export
    /// of their own review, which no policy restricts. Kept distinct from
    /// `render()` by name so the two cannot be confused at a call site.
    func renderForTheAthlete() -> String {
        sections.map(\.body).joined()
    }

    var bytesSending: Int { sending.reduce(0) { $0 + $1.byteCount } }
    var bytesWithheld: Int {
        (blocked + withheld).reduce(0) { $0 + $1.byteCount }
    }

    // MARK: The verdict

    /// Whether this payload could be sent at all.
    ///
    /// FALSE TODAY, and the reason is worth reading rather than working around:
    /// a review whose adherence, volume and pace sections are all withheld is
    /// not a review, and asking a model to judge a block from the effort table
    /// alone would produce a confident answer built on a quarter of the
    /// evidence. Better to refuse than to send a crippled payload and treat
    /// what comes back as a verdict.
    var isUsable: Bool {
        blocked.isEmpty
    }

    /// One sentence for the preflight screen, computed rather than written.
    var verdict: String {
        if blocked.isEmpty {
            return "\(sending.count) of \(sections.count) sections would be sent"
                 + " (\(ByteCountFormatter.string(fromByteCount: Int64(bytesSending), countStyle: .file)))."
        }
        let names = blocked.map(\.title).joined(separator: ", ")
        return "\(blocked.count) section\(blocked.count == 1 ? "" : "s") cannot be sent: \(names). "
             + "Without them a review would be judging the block on a fraction of "
             + "the evidence, so the request is refused rather than sent short."
    }

    // MARK: Rules

    /// Applied to every section as it is built, so a new section cannot be
    /// added without the restriction being considered.
    ///
    /// ADR-0002 §5.3 and §5.10: nothing derived from Strava data may be passed
    /// to an AI provider, directly or indirectly. "Indirectly" is why this is a
    /// LINEAGE test rather than a check for raw Strava fields — the adherence
    /// percentage contains no Strava field and is computed entirely from them.
    static func inclusion(for lineage: Set<DataSource>,
                          optIn: Bool = false) -> PayloadInclusion {
        if lineage.contains(.strava) {
            return .blocked("computed from Strava activities — ADR-0002 §5.3 and "
                          + "§5.10 forbid passing that to an AI provider, directly "
                          + "or indirectly. Rebuilt on Apple Health figures at 4A.")
        }
        return optIn ? .optIn : .required
    }
}
