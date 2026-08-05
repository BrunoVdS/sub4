//
//  ProposalDeleteTests.swift
//  Sub4CoreTests
//
//  Deleting a review — patch 270.
//
//  `ProposalStore.remove(_:)` was written in patch 225 and had no caller for
//  forty-five patches. It compiled, it was correct, and it did nothing — which
//  is the same shape as the several controls this project has found reporting
//  work they did not do, seen from the other side.
//
//  These tests are on `ProposalStore.shared`, deliberately: it is a singleton
//  with a private init and there is no `init(directory:)` seam. So each one
//  cleans up after itself, and none of them asserts on the store's total count
//  — a test that did would fail the moment a rehearsal record existed.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct ProposalDeleteTests {

    /// A record built through the real `add`, so what is deleted is what the
    /// app actually writes.
    private func addOne() throws -> ProposalStore.Record {
        let review = try #require(ReviewBuilder.build(weeksBack: 1),
                                  "the bundled plan should have one finished week")
        return ProposalStore.shared.add(
            review: review,
            proposal: ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids()),
            evidence: "test",
            model: "test-delete")
    }

    @Test("A record that is added can be removed")
    func removeTakesItOut() throws {
        let before = ProposalStore.shared.records.count
        let record = try addOne()
        #expect(ProposalStore.shared.records.count == before + 1)

        try ProposalStore.shared.remove(record)
        #expect(ProposalStore.shared.records.count == before)
        let stillThere = ProposalStore.shared.records.contains { $0.id == record.id }
        #expect(!stillThere)
    }

    @Test("Removing takes out the right one")
    func removeIsSpecific() throws {
        // Two records with the same window, which is the case the id's UUID
        // suffix exists for — a running count would have collided.
        let a = try addOne()
        let b = try addOne()
        #expect(a.id != b.id)

        try ProposalStore.shared.remove(a)
        let ids = ProposalStore.shared.records.map(\.id)
        #expect(!ids.contains(a.id))
        #expect(ids.contains(b.id))

        try ProposalStore.shared.remove(b)
    }

    @Test("Removing a record that is not there is not a failure")
    func removingNothingIsFine() throws {
        // Otherwise a double tap on the confirmation would throw at the
        // athlete for doing what he asked for twice.
        let record = try addOne()
        try ProposalStore.shared.remove(record)
        try ProposalStore.shared.remove(record)
        let stillThere = ProposalStore.shared.records.contains { $0.id == record.id }
        #expect(!stillThere)
    }

    @Test("A removal survives a reload")
    func removalReachesTheDisk() throws {
        // The claim `remove` makes by not throwing. Reading the file back is
        // the only thing that proves it — "it is gone from memory" is exactly
        // what patch 264 established is not the same statement.
        let record = try addOne()
        try ProposalStore.shared.remove(record)

        let url = try #require(
            AppSupportItem.container?.appendingPathComponent("proposals.json"))
        let data = try #require(try? Data(contentsOf: url),
                                "proposals.json should exist after an add")
        let onDisk = try JSONDecoder.sub4.decode([ProposalStore.Record].self,
                                                 from: data)
        let stillOnDisk = onDisk.contains { $0.id == record.id }
        #expect(!stillOnDisk, "the record was removed from memory and not from disk")
    }

    @Test("The rehearsal record is distinguishable by its model")
    func theRehearsalSaysWhatItIs() throws {
        // Patch 269 marks it `rehearsal`, and `model` is a column on `review`.
        // This is what lets somebody find it three weeks later without
        // remembering which date it was written on.
        let record = try addOne()
        #expect(record.model == "test-delete")
        try ProposalStore.shared.remove(record)
    }
}
