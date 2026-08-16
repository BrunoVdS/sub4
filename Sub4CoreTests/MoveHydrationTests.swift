//
//  MoveHydrationTests.swift
//  Sub4CoreTests
//
//  The sixth family — patch 377, ADR-0003 §12.121.
//
//  THE ONE THAT IS THE PATCH
//  -------------------------
//  `theStoreTakesTheStoredMoves`. B2 hydrated notes, commute decisions and
//  match decisions at 357; the plan moves were built at 365 and stayed on
//  `moves.json` because the slice table of 10 August has no row for them.
//
//  THE ONE THAT KEEPS THE SLICE REVERSIBLE
//  ---------------------------------------
//  `hydratingDoesNotWrite`. `PersistenceMode` states it: hydration MUST NOT
//  WRITE. That is what makes taking `.moves` back out of `hydratedFamilies` a
//  full rollback instead of a data loss.
//
//  WHAT IS TESTED AT THE LOAD RATHER THAN THE BOOTSTRAP
//  ----------------------------------------------------
//  `anEmptyFamilyKeepsItsFile` and `aFailedReadHandsOverNothing` ask
//  `PlanMoveLoad` directly. `AuthoredHydrationTests` constructs no
//  `DatabaseBootstrap` either — six loads is a fixture that tests the fixture
//  — and both facts are DECIDED on the load. `hydratableMoves` composes them,
//  and the apply script's guard is what says it still asks `holdsContent`.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The plan moves are the sixth family")
struct MoveHydrationTests {

    private func move(_ uid: String, to day: String = "2026-08-18") -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day,
                 decided: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    // MARK: The store

    /// **THE ONE THAT IS THE PATCH.**
    @Test("The store takes the stored moves")
    @MainActor
    func theStoreTakesTheStoredMoves() throws {
        let store = PlanMoveStore(directory: try directory())
        #expect(store.all.isEmpty)

        store.hydrate(from: [move("wk-06-tue-steady"), move("wk-06-thu-easy")])

        #expect(store.all.count == 2)
        #expect(store.moves["wk-06-tue-steady"]?.movedTo == "2026-08-18")
    }

    /// §12.121.1. The file stays complete and authoritative while the slice is
    /// under test — that is the whole of what makes a slice a slice.
    @Test("Hydrating does not write")
    @MainActor
    func hydratingDoesNotWrite() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("moves.json")
        let store = PlanMoveStore(directory: dir)

        store.hydrate(from: [move("wk-06-tue-steady")])

        #expect(!FileManager.default.fileExists(atPath: file.path),
                "hydration wrote a file, so the slice is no longer reversible")
    }

    /// The diagnostics must stop saying the store reads its files, or the
    /// paste describes a build that no longer exists. §12.54.2.
    @Test("servedFrom moves to the database")
    @MainActor
    func servedFromMovesToTheDatabase() throws {
        let store = PlanMoveStore(directory: try directory())
        #expect(store.servedFrom == .files)

        store.hydrate(from: [move("wk-06-tue-steady")])
        #expect(store.servedFrom == .database)
    }

    // MARK: What the load decides

    /// §12.121.3. A clean read of an empty table is not proof the athlete has
    /// moved nothing — it can be a write-through that has not caught up, and
    /// hydrating there would blank the legacy side's only copy.
    @Test("An empty family keeps its file")
    func anEmptyFamilyKeepsItsFile() {
        let empty = PlanMoveLoad.loaded(moves: [], skipped: 0)
        #expect(empty.wasReadCleanly, "empty is not a fault")
        #expect(!empty.holdsContent,
                "holdsContent is what stops an empty family being handed over")
    }

    @Test("A failed read hands over nothing")
    func aFailedReadHandsOverNothing() {
        let failed = PlanMoveLoad.failed("no such table: correction")
        #expect(!failed.wasReadCleanly)
        #expect(failed.moves == nil,
                "nil rather than [] — a failed read is not an empty one")
        #expect(!failed.holdsContent)
    }

    // MARK: The two lists that must agree

    /// §12.121.4 — the number that did not move. `fieldCount` is pinned so
    /// that adding a family is a thing somebody has to acknowledge; moves
    /// became a family everywhere else and never here, so it never had to.
    @Test("The family count includes it")
    func theFamilyCountIncludesIt() {
        #expect(DatabaseBootstrap.fieldCount == 6)
        // `PersistenceAuthority`, NOT `PersistenceMode` — patch 377b.
        // `HydrationPlanner.decide` calls
        // `PersistenceAuthority.hydrates(.authored)`, which 377's own
        // header quoted. §12.121.6.
        #expect(PersistenceAuthority.Family.allCases.count == 6)
        #expect(PersistenceAuthority.hydratedFamilies.contains(.moves))
        #expect(PersistenceAuthority.hydrates(.moves))
    }

    /// An entry naming a comparison that does not exist is what
    /// `unmatchedHydratedEntries` reports — a defect, not a note. The string
    /// is the verifier's own.
    @Test("Every hydrated family is named")
    func everyHydratedFamilyIsNamed() throws {
        let entry = try #require(
            HydratedStores.all.first { $0.check == "session moves" },
            "the moves have no hydration entry")
        #expect(entry.store == "PlanMoveStore.moves")
        #expect(entry.slice == "B2")
    }
}
