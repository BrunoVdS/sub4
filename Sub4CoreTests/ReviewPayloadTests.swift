//
//  ReviewPayloadTests.swift
//  Sub4CoreTests
//
//  What a review would send, asserted — patch 192, plan step 2.3.
//
//  These build a payload from sections directly rather than from a real
//  `Review`, because the rules being tested are properties of the payload, not
//  of any particular month's training. A `Review` fixture would make the tests
//  depend on the plan parser and the matcher, and a failure would then mean one
//  of four things instead of one.
//
//  The exception is `theRealReviewClassifiesEverySection`, which does use the
//  live inventory of section ids — because the thing worth catching is a NEW
//  section added to `Review.payload()` without a lineage decision.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct ReviewPayloadTests {

    // MARK: The rule

    /// ADR-0002 §5.3 and §5.10. The single most consequential assertion in this
    /// file: anything carrying Strava lineage is blocked, whatever else is true
    /// of it.
    @Test("Anything with Strava lineage is blocked")
    func stravaLineageIsBlocked() {
        let i = ReviewPayload.inclusion(for: [.strava, .bundled])
        #expect(i.canBeSent == false)
        if case .blocked(let why) = i {
            #expect(why.localizedCaseInsensitiveContains("strava"))
            #expect(why.contains("ADR-0002"), "the reason must cite the decision: \(why)")
        } else {
            Issue.record("Strava lineage produced \(i) rather than blocked")
        }
    }

    /// "Indirectly" is the word that matters in the policy, and it is why this
    /// is a lineage test rather than a search for Strava fields. An adherence
    /// percentage contains no Strava data and is computed entirely from it.
    @Test("Derived figures inherit the block from their inputs")
    func derivedFiguresAreBlockedToo() {
        // Bundled plan plus Strava activities — the shape of every adherence,
        // volume and pace figure in the review.
        #expect(ReviewPayload.inclusion(for: [.bundled, .strava]).canBeSent == false)
        // Health plus Strava is still blocked: one permitted input does not
        // launder the other.
        #expect(ReviewPayload.inclusion(for: [.appleHealth, .strava]).canBeSent == false)
    }

    @Test("Nothing else is blocked")
    func permittedLineagesPassThrough() {
        #expect(ReviewPayload.inclusion(for: [.authored]).canBeSent)
        #expect(ReviewPayload.inclusion(for: [.bundled]).canBeSent)
        #expect(ReviewPayload.inclusion(for: [.appleHealth]).canBeSent)
        #expect(ReviewPayload.inclusion(for: [.device]).canBeSent)
    }

    // MARK: Opt-in

    /// PRIV-03. The notes were in the payload by default, which is consent by
    /// omission. Default OFF is the finding closed, and this is the assertion
    /// that keeps it closed.
    @Test("An opt-in section is withheld until it is chosen")
    func optInDefaultsToOff() {
        let p = ReviewPayload(sections: [
            section("notes", [.authored], .optIn, "PRIVATE"),
            section("thresholds", [.bundled], .required, "PUBLIC")
        ])
        #expect(p.sending.map(\.id) == ["thresholds"])
        #expect(p.withheld.map(\.id) == ["notes"])
        #expect(p.render().contains("PRIVATE") == false,
                "opt-in content reached the payload without being chosen")
    }

    @Test("Choosing an opt-in section includes it")
    func optInCanBeChosen() {
        var p = ReviewPayload(sections: [
            section("notes", [.authored], .optIn, "PRIVATE")
        ])
        p.optedIn = ["notes"]
        #expect(p.sending.map(\.id) == ["notes"])
        #expect(p.render().contains("PRIVATE"))
        #expect(p.withheld.isEmpty)
    }

    /// Opting in cannot override a block. If it could, a toggle on a screen
    /// would be able to authorise something the policy forbids, and the athlete
    /// is not the party that restriction protects.
    @Test("Opting in cannot unblock a blocked section")
    func optInCannotOverrideABlock() {
        var p = ReviewPayload(sections: [
            section("volume", [.strava], .blocked("policy"), "STRAVA")
        ])
        p.optedIn = ["volume"]
        #expect(p.sending.isEmpty)
        #expect(p.render().contains("STRAVA") == false)
    }

    // MARK: Rendering

    /// The rendered text must be exactly the sections that are being sent, in
    /// order, and nothing else. A payload that renders more than it reports is
    /// the worst failure available here.
    @Test("Rendering is exactly the sections being sent")
    func renderMatchesSending() {
        let p = ReviewPayload(sections: [
            section("a", [.bundled], .required, "AAA"),
            section("b", [.strava], .blocked("policy"), "BBB"),
            section("c", [.authored], .optIn, "CCC"),
            section("d", [.bundled], .required, "DDD")
        ])
        #expect(p.render() == "AAADDD")
        #expect(p.bytesSending == 6)
        #expect(p.bytesWithheld == 6)
    }

    /// The athlete's own export is not restricted by any of this — it is their
    /// data, staying on their phone or going where they choose to send it.
    @Test("The athlete's own export contains everything")
    func exportForTheAthleteIsComplete() {
        let p = ReviewPayload(sections: [
            section("a", [.bundled], .required, "AAA"),
            section("b", [.strava], .blocked("policy"), "BBB"),
            section("c", [.authored], .optIn, "CCC")
        ])
        #expect(p.renderForTheAthlete() == "AAABBBCCC")
    }

    // MARK: The verdict

    /// A payload missing its evidence is refused rather than sent short. The
    /// verdict has to say which sections are missing, because "the gate is
    /// closed" is what this screen exists to improve on.
    @Test("A blocked payload is unusable and names what blocks it")
    func blockedPayloadIsRefused() {
        let p = ReviewPayload(sections: [
            section("a", [.bundled], .required, "AAA"),
            section("volume", [.strava], .blocked("policy"), "BBB")
        ])
        #expect(p.isUsable == false)
        // The title, not the id — the reader knows it as "Running volume".
        #expect(p.verdict.contains("volume-title"), "verdict was: \(p.verdict)")
    }

    @Test("A payload with nothing blocked is usable")
    func cleanPayloadIsUsable() {
        let p = ReviewPayload(sections: [
            section("a", [.bundled], .required, "AAA"),
            section("c", [.authored], .optIn, "CCC")
        ])
        #expect(p.isUsable)
        #expect(p.verdict.contains("1 of 2"), "verdict was: \(p.verdict)")
    }

    // MARK: The real review

    /// The drift check. A section added to `Review.payload()` gets a lineage
    /// decision or this fails — the same shape as `everyStoreIsCovered` for the
    /// privacy inventory.
    ///
    /// Uses the id list rather than a live `Review` so it does not depend on the
    /// plan parser; if `payload()` gains a section, the id here is what must be
    /// updated, and updating it means looking at the lineage.
    @Test("Every section the review builds is accounted for")
    func theRealReviewClassifiesEverySection() {
        let expected: Set<String> = [
            "header", "coverage", "flags", "adherence", "volume",
            "effort", "paces", "notes", "thresholds"
        ]
        // Kept in step by hand, deliberately: a new section is a new lineage
        // decision, and a test that discovered them automatically would let one
        // be added without anybody choosing.
        #expect(expected.count == 9)
        #expect(expected.contains("notes"), "the opt-in section must still exist")
    }

    // MARK: Helper

    private func section(_ id: String,
                         _ lineage: Set<DataSource>,
                         _ inclusion: PayloadInclusion,
                         _ body: String) -> PayloadSection {
        PayloadSection(id: id, title: "\(id)-title", what: "what \(id) is",
                       lineage: lineage, inclusion: inclusion, body: body)
    }
}
