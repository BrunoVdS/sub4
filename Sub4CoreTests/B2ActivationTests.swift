//
//  B2ActivationTests.swift
//  Sub4CoreTests
//
//  B2 is switched on — patch 358, D7 slice B2, ADR-0003 §12.103.
//
//  WHAT THE FLIP IS. One line: `hydratedFamilies` gains `.authored` and
//  `.decisions`. Everything else this patch touches is a consequence of that
//  line — the slice label, the three comparisons that stop being evidence, and
//  a diagnostic header that could no longer be read without lying.
//
//  WHY IT IS ITS OWN PATCH. 344 built B1's machinery and 346 flipped it; the
//  flip found four failures, and every one of them was attributable BECAUSE
//  the diff contained nothing else. 357 was B2's 344 and this is B2's 346.
//
//  THE PROPERTY THIS SUITE EXISTS FOR — and it is not "does it hydrate".
//
//  Before this patch, `hydratableAuthored` returned nil for two independent
//  reasons: the build did not hydrate the family, and the family held nothing.
//  Either alone produced nil, so no test could tell which one was doing the
//  work. This patch removes the first reason. If the second was never really
//  implemented, an empty database now blanks `notes.json` on the next launch of
//  a device that has notes and no rows — and the athlete's writing is the one
//  thing in this app that cannot be re-fetched from anywhere.
//
//  `anEmptyFamilyStillHandsOverNil` is that test, and it is the reason this
//  file is not just three constant assertions.
//

import Testing
import Foundation
@testable import Sub4

@Suite("B2 is switched on")
@MainActor
struct B2ActivationTests {

    // MARK: Fixtures
    //
    // Shapes copied from `DatabaseBootstrapTests` and `AuthoredHydrationTests`
    // rather than invented, so a compile failure here is a real signature
    // change and not this file guessing.

    private func plan() -> PlanLoad {
        .loaded(meta: Meta(plan: "stored", week1Monday: "2026-07-27",
                           raceDate: "2027-03-21", targetTime: "04:00:00",
                           targetPaceSecKm: 341),
                weeks: [], sessions: [],
                version: PlanLoad.VersionNote(sourceLabel: "test",
                                              importedUTC: "2026-08-10T00:00:00Z",
                                              versionsPresent: 1),
                rows: PlanLoad.TableRows(), skipped: 0)
    }

    private func extras() -> PlanExtrasLoad {
        .loaded(fuel: nil, warmup: nil, exercises: [], skipped: 0)
    }

    private func athlete() -> AthleteLoad {
        .loaded(constants: AthleteConstants(hrMaxObserved: 181, version: 1),
                ftp: 270,
                zones: [.init(index: 1, min: 0, max: 115),
                        .init(index: 2, min: 116, max: nil)])
    }

    private func note() -> NotesStore.Note {
        NotesStore.Note(sessionUid: "wk-01-tue-easy", rpe: 5, feel: nil,
                        text: "ok",
                        created: Date(timeIntervalSince1970: 1_000),
                        edited: Date(timeIntervalSince1970: 1_000))
    }

    private func commute() -> CommuteDecision {
        CommuteDecision(activityId: "1", isCommute: true,
                        decided: Date(timeIntervalSince1970: 1_000))
    }

    /// **`activityId: nil` DELIBERATELY.** "Explicitly nothing satisfied this
    /// session" is a row with a NULL in it, and it is the shape the device
    /// recorded on 14 August — the first one `match_decision` has ever held.
    private func decision() -> MatchDecision {
        MatchDecision(sessionUid: "wk-01-thu-easy", activityId: nil,
                      decided: Date(timeIntervalSince1970: 1_000),
                      dateIsKnown: true)
    }

    private func full() -> DatabaseBootstrap {
        DatabaseBootstrap(
            plan: plan(), extras: extras(), athlete: athlete(),
            authored: .loaded(notes: [note()], commutes: [commute()], skipped: 0),
            decisions: .loaded(decisions: [decision()], skipped: 0))
    }

    // MARK: The line this patch is

    @Test("Every family the bootstrap reads is now hydrated")
    func everyFamilyHydrates() {
        #expect(PersistenceAuthority.hydratedFamilies
                == [.plan, .extras, .athlete, .authored, .decisions])
        #expect(PersistenceAuthority.hydratedFamilies.count
                == PersistenceAuthority.Family.allCases.count,
                "B2 is the slice where those two numbers meet")
        // A LITERAL COMMENT, NOT AN INTERPOLATED ONE — 343b. `Comment` is
        // `ExpressibleByStringLiteral`; anything that is an expression rather
        // than a literal does not convert, and the failure is a compile error
        // in a file nobody has compiled yet.
        for f in PersistenceAuthority.Family.allCases {
            #expect(PersistenceAuthority.hydrates(f),
                    "a family the bootstrap reads and this build does not feed")
        }
    }

    /// §12.43, as the constant's own doc demands: B2 EXTENDS the sentence
    /// rather than replacing it. A label that dropped B1 would read as B1
    /// having been switched off, which is the opposite of what happened.
    @Test("The slice label names both slices")
    func theSliceNamesBoth() {
        let slice = PersistenceAuthority.sliceUnderTest
        #expect(slice != nil, "358 is the flip — nil means it did not happen")
        #expect(slice?.contains("B1") == true, "B1 did not stop")
        #expect(slice?.contains("B2") == true, "and B2 started")
        #expect(PersistenceAuthority.derive(activatedRun: false,
                                            databaseOpened: true,
                                            everActivated: false)
                == .shadow(slice ?? ""),
                "and the launch derives it rather than a second copy of it")
    }

    // MARK: THE ONE THAT MATTERS

    /// **THE TEST THIS SUITE EXISTS FOR — §12.8.1.**
    ///
    /// `hydrates(.authored)` is now true, so the only thing standing between an
    /// empty database and a blanked `notes.json` is `hydratableAuthored`'s own
    /// emptiness check. Until this patch that check could not be tested in
    /// isolation, because the build refused the family for a second reason
    /// anyway. It can be now, and this is that test.
    @Test("An empty family still hands over nil, now that the build wants it")
    func anEmptyFamilyStillHandsOverNil() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(PersistenceAuthority.hydrates(.authored),
                "the first reason for nil is gone — that is what 358 did")
        #expect(PersistenceAuthority.hydrates(.decisions))
        #expect(b.authored.wasReadCleanly, "and the read did succeed")
        #expect(!b.authored.holdsContent)

        #expect(b.hydratableAuthored == nil,
                "a clean read of nothing must not be able to blank notes.json")
        #expect(b.hydratableDecisions == nil)
        #expect(b.emptyAuthoredFamilies == ["notes and commutes",
                                            "match decisions"])
    }

    /// The other half of the same decision, in the planner rather than the
    /// bootstrap: an empty database must not reach `.hydrate` carrying empty
    /// payloads. It does not reach `.hydrate` at all, and the outcome says
    /// "nothing stored" rather than naming a fault.
    @Test("An empty database still leaves every store on its files")
    func anEmptyDatabaseStillLeavesTheFiles() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        switch HydrationPlanner.decide(mode: .shadow("B2 — a test"), bootstrap: b) {
        case .leaveOnFiles(let outcome):
            #expect(!outcome.isFault)
            #expect(outcome.line.contains("nothing stored"))
        case .hydrate:
            Issue.record("an empty database hydrated after the flip")
        }
    }

    // MARK: The payloads now travel

    @Test("A database holding authored rows now hands them to the planner")
    func thePayloadsTravel() {
        switch HydrationPlanner.decide(mode: .shadow("B2 — a test"),
                                       bootstrap: full()) {
        case .hydrate(_, _, _, _, let authored, let decisions):
            #expect(authored != nil)
            #expect(authored?.notes.count == 1)
            #expect(authored?.commutes.count == 1)
            #expect(decisions?.count == 1)
            // BOUND RATHER THAN CHAINED. `decisions?.first?.activityId` is a
            // `String??`, and comparing THAT to nil asks about the outer
            // optional — whether a decision arrived, not whether it names an
            // activity. `DatabaseBootstrapTests` hit the identical shape on
            // `Fuel??`. Two different questions wearing one `nil`.
            if let first = decisions?.first {
                #expect(first.activityId == nil,
                        "the explicitly-nothing row survives the whole path")
            } else {
                Issue.record("the decision did not reach the planner")
            }
        case .leaveOnFiles:
            Issue.record("every family loaded and held content, and it refused")
        }
    }

    /// The families are still INDEPENDENT of each other. Notes present and
    /// decisions empty is this device's state for most of B2's life, and it
    /// must hydrate one without the other rather than refusing both.
    @Test("One empty authored family does not withhold the other")
    func oneEmptyFamilyDoesNotWithholdTheOther() {
        let b = DatabaseBootstrap(
            plan: plan(), extras: extras(), athlete: athlete(),
            authored: .loaded(notes: [note()], commutes: [], skipped: 0),
            decisions: .loaded(decisions: [], skipped: 0))

        #expect(b.hydratableAuthored != nil, "one note is content")
        #expect(b.hydratableDecisions == nil, "and no decision is not")
        #expect(b.emptyAuthoredFamilies == ["match decisions"])
        #expect(b.firstFault == nil, "neither of those is a fault")
    }

    // MARK: What stopped being evidence — §12.99

    /// THREE COMPARISONS DIE HERE, and the list is what says so. `notes`,
    /// `corrections` and `match decisions` all read a store this build now
    /// feeds from the database, so each is the database agreeing with itself.
    /// §12.69: a check that cannot fail has not been tested.
    @Test("The three comparisons B2 made self-referential are declared")
    func theListNamesWhatB2Took() {
        #expect(HydratedStores.all.count == 4, "one from B1 and three from B2")
        for (check, store) in [("notes", "NotesStore.notes"),
                               ("commute corrections", "CommuteStore.decisions"),
                               ("match decisions", "Matcher.decisions")] {
            let e = HydratedStores.entry(for: check)
            #expect(e != nil, "a comparison B2 made self-referential is undeclared")
            #expect(e?.store == store)
            #expect(e?.slice == "B2")
        }
        #expect(HydratedStores.entry(for: "heart-rate zones")?.slice == "B1",
                "B1's entry did not move")
        #expect(HydratedStores.entry(for: "activities") == nil,
                "activities are read from the app's own files and still can")
    }

    /// The tripwire, re-run at B2. Every declared entry must name a comparison
    /// the real verifier actually makes — a name that drifted on one side would
    /// move a self-referential check back into the evidence column and every
    /// number below it would read better than the truth.
    @Test("Every B2 entry names a comparison the verifier actually makes")
    func everyEntryNamesARealComparison() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        #expect(r.unmatchedHydratedEntries.isEmpty,
                "an entry naming no comparison is a rename nobody finished")
        #expect(r.selfReferentialChecks.count == 4)
        #expect(Set(r.selfReferentialChecks.map(\.name))
                == ["notes", "commute corrections", "match decisions",
                    "heart-rate zones"])
        #expect(!r.independentChecks.isEmpty,
                "B2 is not B9 — there is still evidence left")
        #expect(r.independentChecks.count == r.checks.count - 4)
    }

    /// THE NUMBER THAT MOVED, and the reason 354 built this accounting at all.
    /// It went 20 to 19 at B1 and nobody noticed. Three more go here, and the
    /// paste is what says so before somebody reads a green run as evidence.
    @Test("The independent count falls by exactly three")
    func theIndependentCountFalls() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])
        #expect(r.checks.count - r.independentChecks.count == 4)
        #expect(r.ledgerNote.contains("\(r.independentChecks.count) independent"))
    }

    // MARK: The paste stops contradicting itself

    /// **THE FINDING FROM 14 AUGUST.** The device recorded two match decisions,
    /// imported them, and the paste then said `match decisions: 0` twenty-six
    /// lines above `match_decision: 2`.
    ///
    /// Both numbers were right. `Sub4Launch.bootstrap` is read once, at launch,
    /// on purpose — 345's whole argument is that it records what the bootstrap
    /// saw on the launch that decided hydration, and refreshing it would
    /// destroy that. The table counts are live. Nothing said which was which.
    ///
    /// §12.15: a diagnostic that cannot say why it disagrees with the document
    /// it is printed in will be read as broken. One line, in the header, where
    /// a reader meets the block.
    @Test("The bootstrap header says the counts are from the launch read")
    func theHeaderSaysWhenItWasRead() throws {
        let db = try Sub4Database.inMemory()
        let lines = DatabaseBootstrapReader.read(db).diagnosticLines
        let head = try #require(lines.first)

        #expect(head.hasPrefix("Database bootstrap: 5 families"),
                "the prefix every earlier pin was written against")
        #expect(head.contains("read at launch"))
        #expect(head.lowercased().contains("live"),
                "and it names the counts a reader will compare it against")
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount,
                "the header is one line, not two — the pin does not move")
    }
}
