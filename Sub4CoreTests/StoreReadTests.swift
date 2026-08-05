//
//  StoreReadTests.swift
//  Sub4CoreTests
//
//  A store that could not be read must not look empty — patch 273,
//  ADR-0003 §12.20.
//
//  THE TEST THAT MATTERS IS `aCorruptNotesFileDoesNotLookLikeNoNotes`.
//  Everything else here checks a classification; that one checks the defect.
//  Until this patch a `notes.json` the app could not decode produced exactly
//  the same state as a fresh install — an empty dictionary, no error, no row,
//  no log — and the reconciliation pass in 274 would have read that state and
//  deleted thirteen months of notes from the database.
//
//  ABSENT IS ASSERTED AS A PASS, NOT AS A FAILURE. Every fresh install has no
//  `notes.json` and §12.9e found `proposals.json` legitimately missing on the
//  real device. A gate that refused on those would refuse always, and a gate
//  that always refuses is not a gate.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct StoreReadTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("storeread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `if case` into a local rather than `==` against a literal. The reason
    /// carried by `.unreadable` is prose meant for a human, and a test that
    /// pinned it would fail the day somebody improved the wording.
    private func isUnreadable(_ outcome: StoreLoad) -> Bool {
        if case .unreadable = outcome { return true }
        return false
    }

    // MARK: The three outcomes

    @Test("No file is absent, and absent is believable")
    func noFileIsAbsent() throws {
        let dir = try directory()
        let (value, outcome) = StoreRead.decode([String: String].self,
                                                at: dir.appendingPathComponent("nothing.json"))
        #expect(value == nil)
        #expect(outcome == .absent)
        #expect(outcome.isTrustworthy)
    }

    @Test("A good file loads")
    func aGoodFileLoads() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("good.json")
        try JSONEncoder.sub4.encode(["a": "b"]).write(to: url)

        let (value, outcome) = StoreRead.decode([String: String].self, at: url)
        #expect(value == ["a": "b"])
        #expect(outcome == .loaded)
        #expect(outcome.isTrustworthy)
    }

    @Test("A file that will not decode is unreadable, not empty")
    func aCorruptFileIsUnreadable() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("bad.json")
        try Data("{ this is not json".utf8).write(to: url)

        let (value, outcome) = StoreRead.decode([String: String].self, at: url)
        #expect(value == nil)
        #expect(isUnreadable(outcome))
        // THE ASSERTION THE WHOLE PATCH IS FOR.
        #expect(outcome.isTrustworthy == false)
    }

    @Test("A zero-byte file is unreadable, not absent")
    func anEmptyFileIsUnreadable() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("empty.json")
        try Data().write(to: url)

        let (_, outcome) = StoreRead.decode([String: String].self, at: url)
        // An interrupted write leaves this behind — §12.9c's `truncated` at
        // its limit. Calling it "you have nothing" is the mistake.
        #expect(isUnreadable(outcome))
    }

    // MARK: The stores

    @Test("A corrupt notes file does not look like no notes")
    func aCorruptNotesFileDoesNotLookLikeNoNotes() throws {
        let dir = try directory()
        try Data("{ truncated".utf8)
            .write(to: dir.appendingPathComponent("notes.json"))

        let store = NotesStore(directory: dir)
        // The memory is empty either way — that has always been true and is
        // not what changed.
        #expect(store.notes.isEmpty)
        // What changed: the store can now say WHY it is empty.
        #expect(isUnreadable(store.lastLoad))
    }

    @Test("A fresh notes store is absent rather than unreadable")
    func aFreshNotesStoreIsAbsent() throws {
        let store = NotesStore(directory: try directory())
        #expect(store.notes.isEmpty)
        #expect(store.lastLoad == .absent)
    }

    @Test("A corrupt commutes file does not look like no decisions")
    func aCorruptCommutesFileIsUnreadable() throws {
        let dir = try directory()
        try Data("[".utf8).write(to: dir.appendingPathComponent("commutes.json"))

        let store = CommuteStore(directory: dir)
        #expect(store.decisions.isEmpty)
        #expect(isUnreadable(store.lastLoad))
    }

    @Test("A match-decision blob that will not decode is unreadable")
    func aCorruptDecisionBlobIsUnreadable() throws {
        let name = "sub4.tests.readbad"
        UserDefaults.standard.removePersistentDomain(forName: name)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        defaults.set(Data("not a decisions blob".utf8), forKey: Matcher.decisionsKey)

        let matcher = Matcher(defaults: defaults)
        #expect(matcher.decisions.isEmpty)
        #expect(isUnreadable(matcher.lastLoad))
    }

    @Test("A phone that has never overridden a match reads as absent")
    func aFreshMatcherIsAbsent() throws {
        let name = "sub4.tests.readfresh"
        UserDefaults.standard.removePersistentDomain(forName: name)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(Matcher(defaults: defaults).lastLoad == .absent)
    }

    // MARK: The journal

    @Test("An unreadable store is recorded, named, and its reason withheld")
    func theJournalRecordsAndRedacts() {
        let journal = StoreReadJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        journal.record("notes.json", .unreadable("the contents did not decode"))

        #expect(journal.hasUnreadable)
        #expect(journal.count == 1)
        #expect(journal.all.first?.store == "notes.json")

        let lines = journal.diagnosticLines
        #expect(lines.contains("Unreadable stores: 1"))
        // The paste names the store and NOT the reason — a file-system error
        // can carry a path, the same judgement `StoreWriteJournal` made.
        let leaks = lines.filter { $0.contains("did not decode") }
        #expect(leaks.isEmpty, "the reason reached the redacted paste: \(leaks)")
    }

    @Test("A clean read clears an earlier failure")
    func aCleanReadClearsIt() {
        let journal = StoreReadJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        journal.record("notes.json", .unreadable("the file is empty"))
        journal.record("notes.json", .loaded)

        #expect(journal.hasUnreadable == false)
        #expect(journal.diagnosticLines == ["Unreadable stores: none"])
    }

    // MARK: The gate 274 will stand on

    @Test("The gate refuses a store that never reported")
    func theGateFailsClosed() {
        let journal = StoreReadJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        journal.record("notes.json", .loaded)
        // `proposals.json` was never wired in. Silence must not read as
        // success, or forgetting a store looks exactly like remembering one.
        #expect(journal.canReconcile(["notes.json", "proposals.json"]) == false)
    }

    @Test("The gate refuses on one unreadable store and passes on absent ones")
    func theGateRefusesOnlyWhatItShould() {
        let journal = StoreReadJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        journal.record("notes.json", .loaded)
        journal.record("proposals.json", .absent)
        journal.record("match.decisions", .absent)
        #expect(journal.canReconcile(["notes.json", "proposals.json", "match.decisions"]))

        journal.record("proposals.json", .unreadable("the file is empty"))
        #expect(journal.canReconcile(["notes.json", "proposals.json", "match.decisions"]) == false)
        // And the others are still fine on their own — the refusal is about
        // the named store, not a mood.
        #expect(journal.canReconcile(["notes.json", "match.decisions"]))
    }
}
