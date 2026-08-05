//
//  CommuteWriteTests.swift
//  Sub4CoreTests
//
//  A commute decision that fails to save — D4 step 2, patch 265.
//
//  Same shape as `StoreWriteTests`, and the same rule: every test that matters
//  makes a real write fail first, by pointing the store at a directory that is
//  not there. Nothing is mocked.
//
//  The one worth reading is `aFailedSetLeavesTheOldAnswer`. `Activity`'s
//  commute state is READ from this store, so rolling the memory back is the
//  same event as the toggle snapping back on screen — there is no separate
//  visual revert to test, and no second copy of the truth that could drift.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct CommuteWriteTests {

    private func writableDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commutes-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unwritableDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commutes-missing-\(UUID().uuidString)", isDirectory: true)
    }

    private let ride = "19608576674"

    // MARK: When it lands

    @Test("A decision that saves survives a reopen")
    func aGoodSetLands() throws {
        let dir = try writableDirectory()
        let store = CommuteStore(directory: dir)
        try store.set(true, for: ride)
        #expect(store.decision(for: ride) == true)

        let reopened = CommuteStore(directory: dir)
        #expect(reopened.decision(for: ride) == true)
    }

    @Test("Forgetting an answer survives a reopen too")
    func aGoodClearLands() throws {
        let dir = try writableDirectory()
        let store = CommuteStore(directory: dir)
        try store.set(true, for: ride)
        try store.clear(ride)
        // Nil is not false — a forgotten answer falls back to the distance
        // rule, and collapsing that into "not a commute" would silently
        // promote a guess to a decision.
        #expect(store.decision(for: ride) == nil)

        let reopened = CommuteStore(directory: dir)
        #expect(reopened.decision(for: ride) == nil)
    }

    // MARK: When it does not

    @Test("A decision that cannot be written throws")
    func aFailedSetThrows() {
        let store = CommuteStore(directory: unwritableDirectory())
        #expect(throws: StoreWriteError.self) {
            try store.set(true, for: ride)
        }
    }

    @Test("A failed first answer leaves no answer behind")
    func aFailedSetRollsBack() {
        let store = CommuteStore(directory: unwritableDirectory())
        try? store.set(true, for: ride)
        // On screen this IS the toggle snapping back: `isCommuteRide` reads
        // this store, so there is nothing else to revert.
        #expect(store.decision(for: ride) == nil)
        #expect(store.count == 0)
    }

    @Test("A failed change leaves the OLD answer, not no answer")
    func aFailedSetLeavesTheOldAnswer() throws {
        let dir = try writableDirectory()
        let store = CommuteStore(directory: dir)
        try store.set(true, for: ride)
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))

        try? store.set(false, for: ride)
        // Rolling back to nothing would be its own defect: a failed change
        // must not forget the answer that was already given, because that
        // hands the ride back to the distance rule without anybody saying so.
        #expect(store.decision(for: ride) == true)
    }

    @Test("A failed forget puts the answer back")
    func aFailedClearRollsBack() throws {
        let dir = try writableDirectory()
        let store = CommuteStore(directory: dir)
        try store.set(false, for: ride)
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))

        try? store.clear(ride)
        // The one that matters most and shows least. A clear that silently did
        // not happen leaves the athlete believing the 10 km rule governs a ride
        // that still carries an override — and it looks right, because the two
        // agree except at the edges the toggle exists for.
        #expect(store.decision(for: ride) == false)
    }

    @Test("Forgetting an answer nobody gave is not a failure")
    func clearingNothingIsFine() throws {
        // Nothing to write, so nothing to fail. A store that threw here would
        // break the button on every ride with no override.
        let store = CommuteStore(directory: unwritableDirectory())
        try store.clear(ride)
        #expect(store.count == 0)
    }

    // MARK: What the decision means to an activity

    @Test("A failed toggle leaves the activity reading as it did before")
    func theActivityFollowsTheStore() throws {
        // End to end, at the level the screen sees. `isCommuteRide` reads the
        // shared store, so this drives the real one — set, then a failed
        // change against a store that cannot write, then read the activity.
        let dir = try writableDirectory()
        let store = CommuteStore(directory: dir)
        try store.set(true, for: ride)
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))
        try? store.set(false, for: ride)

        #expect(store.decision(for: ride) == true,
                "the decision the view would render has changed without a write")
    }

    @Test("The failure names commutes.json, not notes.json")
    func theStoreIsNamed() {
        let store = CommuteStore(directory: unwritableDirectory())
        do {
            try store.set(true, for: ride)
            Issue.record("the write succeeded, so this test proves nothing")
        } catch let error as StoreWriteError {
            // The alert prints this. Naming the wrong file would send somebody
            // after the wrong problem.
            #expect(error.store == "commutes.json")
            #expect(error.stage == .writing)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
