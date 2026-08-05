//
//  StoreWriteJournalTests.swift
//  Sub4CoreTests
//
//  Which stores are behind their memory — D4 step 3, patch 266.
//
//  The journal exists because six stores deliberately do NOT roll back, and
//  that decision is only defensible if the disagreement is visible. So the
//  tests that matter here are the ones about visibility: an entry appears, it
//  counts, it clears on success, and it never carries anything of the
//  athlete's into the diagnostic paste.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct StoreWriteJournalTests {

    private var journal: StoreWriteJournal { .shared }

    private func clean() { journal.forgetEverythingForTesting() }

    private func failing() -> StoreWriteError {
        StoreWriteError(store: "activities.json", stage: .writing, reason: "disk full")
    }

    // MARK: Recording

    @Test("A write that lands records nothing")
    func successIsSilent() {
        clean()
        let ok = journal.attempt("activities.json") { }
        #expect(ok)
        #expect(!journal.hasUnsaved)
        #expect(journal.count == 0)
    }

    @Test("A write that fails is recorded against its store")
    func failureIsRecorded() {
        clean()
        let ok = journal.attempt("activities.json") { throw self.failing() }
        #expect(!ok)
        #expect(journal.hasUnsaved)
        #expect(journal.all.first?.store == "activities.json")
        #expect(journal.all.first?.attempts == 1)
    }

    @Test("Failing ten times is one entry that has failed ten times")
    func repeatsAccumulateInOneEntry() {
        clean()
        for _ in 0..<10 {
            _ = journal.attempt("weather.json") { throw self.failing() }
        }
        // One entry, not ten. The athlete's question is "is anything unsaved",
        // and a list that grows without bound turns that into scrolling.
        #expect(journal.count == 1)
        #expect(journal.all.first?.attempts == 10)
    }

    @Test("The first failure's time is kept, and the latest is updated")
    func bothTimesAreKept() {
        clean()
        _ = journal.attempt("weather.json", now: "2026-08-05T10:00:00Z") { throw self.failing() }
        _ = journal.attempt("weather.json", now: "2026-08-05T11:00:00Z") { throw self.failing() }
        let entry = journal.all.first
        // "Since when" is the question a repeated failure raises, so the first
        // time survives every later one.
        #expect(entry?.firstFailedUTC == "2026-08-05T10:00:00Z")
        #expect(entry?.lastFailedUTC == "2026-08-05T11:00:00Z")
    }

    @Test("A successful write is the only thing that clears an entry")
    func successClears() {
        clean()
        _ = journal.attempt("activities.json") { throw self.failing() }
        #expect(journal.hasUnsaved)
        _ = journal.attempt("activities.json") { }
        #expect(!journal.hasUnsaved, "the next good sync did not clear the warning")
    }

    @Test("One store clearing does not clear another")
    func storesAreIndependent() {
        clean()
        _ = journal.attempt("activities.json") { throw self.failing() }
        _ = journal.attempt("weather.json") { throw self.failing() }
        #expect(journal.count == 2)

        _ = journal.attempt("activities.json") { }
        #expect(journal.count == 1)
        #expect(journal.all.first?.store == "weather.json")
    }

    @Test("An error that is not a StoreWriteError is still recorded")
    func anyErrorLands() {
        clean()
        struct Boom: Error {}
        _ = journal.attempt("constants.json") { throw Boom() }
        // A store that threw something unexpected must not fall through into
        // silence — that is the `try?` this patch removed, wearing a different
        // hat.
        #expect(journal.count == 1)
        #expect(journal.all.first?.error.store == "constants.json")
    }

    // MARK: Order and reading

    @Test("The list is sorted, so it does not reshuffle between renders")
    func theListIsStable() {
        clean()
        for name in ["weather.json", "activities.json", "constants.json"] {
            _ = journal.attempt(name) { throw self.failing() }
        }
        #expect(journal.all.map(\.store) == ["activities.json", "constants.json", "weather.json"])
    }

    @Test("One failure reads as a moment, many read as a condition")
    func theLineChangesWithCount() {
        clean()
        _ = journal.attempt("weather.json", now: "2026-08-05T10:00:00Z") { throw self.failing() }
        let once = journal.all.first?.line ?? ""
        _ = journal.attempt("weather.json", now: "2026-08-05T11:00:00Z") { throw self.failing() }
        let twice = journal.all.first?.line ?? ""
        #expect(once != twice)
        #expect(twice.contains("2"), "a repeated failure does not say how many")
    }

    // MARK: What the paste may carry

    @Test("The diagnostic names stores and stages, and no reason")
    func theDiagnosticIsRedacted() {
        clean()
        _ = journal.attempt("weather.json") {
            // A file-system error can carry a container path, which is a real
            // path on a real phone. Store names and stages are safe; the
            // reason is not, and is left out.
            throw StoreWriteError(store: "weather.json", stage: .writing,
                                  reason: "/var/mobile/Containers/Data/Application/BRUNO/weather.json")
        }
        let text = journal.diagnosticLines.joined(separator: "\n")
        #expect(!text.contains("/var/mobile"))
        #expect(!text.contains("BRUNO"))
        #expect(text.contains("weather.json"))
        #expect(text.contains("writing"))
    }

    @Test("A clean journal says so rather than saying nothing")
    func theDiagnosticSaysNoneExplicitly() {
        clean()
        let text = journal.diagnosticLines.joined(separator: "\n")
        // "Unsaved stores: none" and an absent section read differently. The
        // second could mean the check never ran.
        #expect(text.contains("none"))
    }

    // MARK: The stamp

    @Test("The stamp is UTC and sorts as text")
    func theStampIsComparable() {
        let early = StoreWriteJournal.stamp(Date(timeIntervalSince1970: 1_780_000_000))
        let late = StoreWriteJournal.stamp(Date(timeIntervalSince1970: 1_790_000_000))
        #expect(early < late)
        #expect(early.hasSuffix("Z"))
    }
}
