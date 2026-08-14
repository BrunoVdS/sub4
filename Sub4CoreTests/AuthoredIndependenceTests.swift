//
//  AuthoredIndependenceTests.swift
//  Sub4CoreTests
//
//  The authored read-back keeps its own read — patch 356, D7 slice B2,
//  ADR-0003 §12.101.
//
//  WHAT IS TESTED HERE AND WHAT IS GUARDED INSTEAD
//  ----------------------------------------------
//  The defect this patch removes is a NEGATIVE: `ReadBacks.authored` must not
//  ask `NotesStore.shared`, `CommuteStore.shared` or `Matcher.shared`. There is
//  no assertion that can see that — the singletons and the files hold the same
//  values today, which is precisely why this patch changes no number — so it is
//  held by `apply-356.py`, which names all three and fails the patch if any
//  reappears.
//
//  346a is why all three are named rather than one. Its sweep for the literal
//  `PlanStore.shared` converted six occurrences and missed five more sitting
//  inside a default argument, and the tests passed for four patches because two
//  plans happened to agree.
//
//  WHAT IS TESTED is the part that CAN fail: the provenance the report now
//  carries, the three states of the independent read, and the one thing this
//  patch adds that has a real failure mode — Application Support being
//  unreachable must not read as three empty stores.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The authored read-back reads for itself")
@MainActor
struct AuthoredIndependenceTests {

    // MARK: The independent read

    /// A SMOKE TEST AND IT IS HONEST ABOUT BEING ONE. It reads whatever the
    /// test host's container holds, so it cannot assert counts. What it does
    /// assert is that the read HAPPENS and reports itself as clean — a
    /// container this build cannot reach would fail here rather than on a
    /// device.
    @Test("The sources read cleanly and say where they came from")
    func theSourcesRead() {
        let s = ReadBacks.authoredSources()
        #expect(s.directoryFound, "Application Support was not reachable")
        #expect(s.isTrustworthy)
        #expect(s.line.contains("notes.json"))
        #expect(s.line.contains("commutes.json"))
        #expect(s.line.contains("match decisions"))
        #expect(!s.line.contains("stores"),
                "the whole point is that it did not ask the stores")
    }

    /// **THE ONE WITH A REAL FAILURE MODE.** A container the app cannot reach
    /// and three stores with nothing in them produce identical counts. §12.15:
    /// one says the athlete has written nothing, the other says the app cannot
    /// tell, and a read-back must never report the second as the first.
    @Test("An unreachable container is not three empty stores")
    func unreachableIsNotEmpty() {
        let lost = ReadBacks.AuthoredSources(
            notes: [], commutes: [], decisions: [],
            notesLoad: .absent, commutesLoad: .absent, decisionsLoad: .absent,
            directoryFound: false)

        #expect(!lost.isTrustworthy,
                "every load says .absent and none of them was performed")
        #expect(lost.line.contains("unreachable"))

        let empty = ReadBacks.AuthoredSources(
            notes: [], commutes: [], decisions: [],
            notesLoad: .absent, commutesLoad: .absent, decisionsLoad: .absent,
            directoryFound: true)
        #expect(empty.isTrustworthy,
                "a fresh install has no notes.json and that is a clean read")
        #expect(empty.line != lost.line)
    }

    /// `.absent` is trustworthy and `.unreadable` is not — `StoreLoad`'s own
    /// rule, and this checks the struct actually applies it rather than
    /// reporting the aggregate as clean because two of three were.
    @Test("One unreadable source spoils the read")
    func oneUnreadableSourceSpoilsIt() {
        func sources(notes: StoreLoad = .loaded,
                     commutes: StoreLoad = .loaded,
                     decisions: StoreLoad = .loaded) -> ReadBacks.AuthoredSources {
            ReadBacks.AuthoredSources(
                notes: [], commutes: [], decisions: [],
                notesLoad: notes, commutesLoad: commutes,
                decisionsLoad: decisions, directoryFound: true)
        }
        #expect(sources().isTrustworthy)
        #expect(!sources(notes: .unreadable("bad json")).isTrustworthy)
        #expect(!sources(commutes: .unreadable("bad json")).isTrustworthy)
        #expect(!sources(decisions: .unreadable("bad blob")).isTrustworthy)
        #expect(sources(notes: .absent, commutes: .absent,
                        decisions: .absent).isTrustworthy,
                "absent is a clean read of nothing on all three")
    }

    // MARK: The provenance the report carries

    /// THE DEFAULT NAMES THE SINGLETONS, DELIBERATELY. Any caller that has not
    /// been updated announces itself in the paste instead of hiding — and
    /// after B2, "the app's stores" on this line IS the defect.
    @Test("A report nobody told says it came from the stores")
    func theDefaultAnnouncesItself() {
        let r = AuthoredRoundTrip.Report()
        #expect(r.appSideCameFrom == "the app's stores")
        #expect(r.appSideWasReadCleanly)
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("the app side came from: the app's stores")
        }))
    }

    /// §12.54.2 — it prints on a healthy run too. A line that appeared only
    /// when the provenance was wrong could not be told from one nobody wired
    /// in, and this is the line a reader six months from now uses to decide
    /// whether the counts below it mean anything.
    @Test("The paste says where the app side came from, always")
    func thePasteSaysItAlways() {
        var r = AuthoredRoundTrip.Report()
        r.appSideCameFrom = ReadBacks.authoredSources().line
        let lines = r.diagnosticLines

        #expect(lines.contains(where: { $0.contains("the app side came from:") }))
        #expect(lines.contains(where: {
            $0.contains("the app side was read cleanly: yes")
        }))
        #expect(lines.contains(where: { $0.contains("notes.json") }))
    }

    @Test("A failed independent read says NO in capitals")
    func aFailedReadSaysSo() {
        var r = AuthoredRoundTrip.Report()
        r.appSideWasReadCleanly = false
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("the app side was read cleanly: NO")
        }))
    }

    /// The provenance line is FIRST after the heading, because it is what every
    /// count below it means. Pinned so a later edit cannot bury it.
    @Test("The provenance is the first thing under the heading")
    func theProvenanceComesFirst() {
        let lines = AuthoredRoundTrip.Report().diagnosticLines
        #expect(lines.first?.hasPrefix("Authored read-back:") == true)
        #expect(lines.count > 2)
        #expect(lines[1].contains("the app side came from:"))
        #expect(lines[2].contains("the app side was read cleanly:"))
    }
}
