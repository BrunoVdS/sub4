//
//  DetailIndependenceTests.swift
//  Sub4CoreTests
//
//  The detail and trace comparisons keep their own read — patch 390,
//  D7 slice B4, ADR-0003 §12.134. `ActivityIndependenceTests` one slice later,
//  and deliberately built to the same shape.
//
//  WHY THIS PATCH EXISTS BEFORE THE FLIP
//  -------------------------------------
//  Three comparisons take their app side from `DetailStore.shared`: Compare's
//  slice 4, the Details read-back and the Recordings read-back. 392 hydrates
//  that store from the database, and on that day all three become the database
//  agreeing with itself — 694 details, 668 traces and 199,848 samples, all
//  guaranteed to agree, printing *no differences*.
//
//  343 answered this for the plan, 356 for the authored data, 381 for the
//  activities. The files are still written and still complete, so the same
//  answer is available here, and it has to land BEFORE the flip or there is a
//  build in which three comparisons are vacuous.
//
//  WHAT IS TESTED HERE AND WHAT IS NOT TESTABLE
//  --------------------------------------------
//  The defect this patch removes is a NEGATIVE — those three sites must not ask
//  `DetailStore.shared` — and no assertion can see it today, because the store
//  and the files hold the same 694. 381 recorded the identical split.
//
//  What CAN be tested is everything this patch adds that has a failure mode,
//  and one of them is the reason the seam was dangerous:
//  `theSeamCannotDestroyTheFiles` deletes nothing on this tree and deleted 19 MB
//  on the last one.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The detail comparisons read for themselves")
@MainActor
struct DetailIndependenceTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-390-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func detail(_ id: String, splits: Int = 3) -> ActivityDetail {
        ActivityDetail(activityId: id,
                       splits: (1...splits).map {
                           .init(index: $0, distanceM: 1000, movingTime: 300,
                                 elapsedTime: 305, elevationDiff: nil,
                                 averageHR: 140)
                       },
                       bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func streams(_ id: String) -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: (0..<12).map { Double($0) * 100 },
                        heartRate: Array(repeating: 140, count: 12),
                        speed: nil, altitude: nil, grade: nil, power: nil,
                        latitude: nil, longitude: nil,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// The store's own encoder, so what is written is what
    /// `loadFromDirectories` expects — a bare `JSONEncoder`, exactly what
    /// `save()` uses. §12.122.4's rule, one store over.
    private func seed(_ dir: URL,
                      details: [ActivityDetail] = [],
                      streams: [ActivityStreams] = []) throws {
        let d = dir.appendingPathComponent("details", isDirectory: true)
        let s = dir.appendingPathComponent("streams", isDirectory: true)
        try FileManager.default.createDirectory(at: d,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s,
                                                withIntermediateDirectories: true)
        for v in details {
            try JSONEncoder().encode(v)
                .write(to: d.appendingPathComponent(v.activityId + ".json"))
        }
        for v in streams {
            try JSONEncoder().encode(v)
                .write(to: s.appendingPathComponent(v.activityId + ".json"))
        }
    }

    // MARK: The seam

    /// **THE ONE WITH TEETH, AND IT IS ABOUT 19 MB OF THE ATHLETE'S DATA.**
    ///
    /// `DetailStore.resetCache()` removes `details/` and `streams/` outright. It
    /// is `internal`, so anything in the module can call it, and
    /// `ActivityStore.resetCache` does. Before 390 a seam rooted at the real
    /// container could therefore delete 694 details and 668 traces — 19 MB with
    /// no restore path — and `mayWrite` is what refuses.
    ///
    /// Run against the 389a tree this test deletes both directories and fails on
    /// the first assertion.
    @Test("The seam cannot destroy the files it was given")
    func theSeamCannotDestroyTheFiles() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1"), detail("2")],
                 streams: [streams("1")])

        let seam = DetailStore(directory: dir)
        #expect(seam.details.count == 2)
        #expect(seam.streams.count == 1)

        seam.resetCache()

        let d = dir.appendingPathComponent("details", isDirectory: true)
        let s = dir.appendingPathComponent("streams", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: d.path),
                "details/ was removed by an instance that may not write")
        #expect(FileManager.default.fileExists(atPath: s.path),
                "streams/ was removed by an instance that may not write")
        // **AND THE FILES, NOT ONLY THE DIRECTORIES — AND THE NEGATIVE CONTROL
        // PROVED THIS HALF IS THE HALF THAT WORKS.** With the guard removed,
        // the two assertions above PASSED: `resetCache` deletes each directory
        // and immediately recreates it, so "the folder exists" is true on both
        // trees. Only these two caught it. A test that had stopped at the
        // folders would have passed over a wipe. §12.69, inside the test
        // written for §12.69.
        let again = DetailStore(directory: dir)
        #expect(again.details.count == 2, "the detail files are still there")
        #expect(again.streams.count == 1, "the trace file is still there")
    }

    /// **AN ABSENT DIRECTORY IS AN ANSWER AND MUST STAY ONE.** The singleton
    /// creates `details/` and `streams/` if they are missing; the seam must not,
    /// because a created-empty directory makes an unreachable container look
    /// like a history the athlete never recorded. §12.15.
    @Test("The seam does not create the directories it did not find")
    func theSeamCreatesNothing() throws {
        let dir = try directory()
        let seam = DetailStore(directory: dir)

        #expect(seam.details.isEmpty)
        #expect(seam.streams.isEmpty)
        #expect(seam.tally.detailFiles == 0)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("details").path),
                "the seam created a directory that was not there")
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("streams").path))
    }

    /// **A FILE THAT WOULD NOT DECODE IS COUNTED, NOT ONLY SKIPPED.** `load()`
    /// has skipped one with `continue` since 169, which is the right behaviour —
    /// `refreshQueue` re-queues it. It is the wrong SILENCE for a comparison: an
    /// unreadable detail shows up as `detailsOnlyInDatabase`, which reads as the
    /// importer having written a row the app never had.
    @Test("An undecodable file is counted rather than only skipped")
    func anUndecodableFileIsCounted() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1")], streams: [streams("1")])
        try Data("not json".utf8)
            .write(to: dir.appendingPathComponent("details/2.json"))

        let seam = DetailStore(directory: dir)
        #expect(seam.tally.detailFiles == 2)
        #expect(seam.tally.detailFilesUnreadable == 1)
        #expect(seam.tally.streamFiles == 1)
        #expect(seam.tally.streamFilesUnreadable == 0)
        #expect(!seam.tally.isClean)
        #expect(seam.details.count == 1, "the readable one still loaded")
        #expect(seam.tally.line.contains("could not be decoded"))
    }

    @Test("A clean tally says both denominators")
    func aCleanTallySaysTheDenominators() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1"), detail("2")],
                 streams: [streams("1")])
        let t = DetailStore(directory: dir).tally
        #expect(t.isClean)
        #expect(t.line == "2 detail files and 1 trace files, all readable")
    }

    // MARK: The read's three states

    /// A SMOKE TEST, AND HONEST ABOUT BEING ONE — `ActivityIndependenceTests`'
    /// first test, for its reason. It reads whatever the test host's container
    /// holds, so it cannot assert a count. What it asserts is that the read
    /// HAPPENS and names itself.
    @Test("The source reads and says where it came from")
    func theSourceReads() {
        let s = DetailSource.read()
        #expect(s.directoryFound, "Application Support was not reachable")
        #expect(s.line.contains("details/ and streams/")
                || s.line.contains("could not be decoded"))
    }

    /// **THE ONE WITH A REAL FAILURE MODE.** A container the app cannot reach
    /// and a device before its first backfill produce the same empty
    /// dictionaries. §12.15: one says the athlete has no details, the other says
    /// the app could not look.
    @Test("An unreachable container is not an empty history")
    func unreachableIsNotEmpty() {
        let lost = DetailSource.Read(details: [:], streams: [:],
                                     tally: DetailStore.FileTally(),
                                     directoryFound: false)
        #expect(!lost.isTrustworthy, "the read was not performed at all")
        #expect(lost.line.contains("unreachable"))

        let fresh = DetailSource.Read(details: [:], streams: [:],
                                      tally: DetailStore.FileTally(),
                                      directoryFound: true)
        #expect(fresh.isTrustworthy,
                "a device before its first backfill has no files, cleanly")
        #expect(fresh.line != lost.line)
    }

    /// An undecodable file costs the READ its independence, which is a third
    /// state again: the directory was found, the files were there, and the app
    /// side is not the file's contents.
    @Test("An undecodable file is not a clean read")
    func undecodableIsNotClean() {
        var t = DetailStore.FileTally()
        t.detailFiles = 4
        t.detailFilesUnreadable = 1
        let bad = DetailSource.Read(details: [:], streams: [:], tally: t,
                                    directoryFound: true)
        #expect(!bad.isTrustworthy)
        #expect(bad.line.contains("the app's own store was compared instead"))
    }

    // MARK: The report refuses to call a fallback a pass

    /// **§12.125.3's TEETH, ONE COMPARISON OVER.** Zero differences over an app
    /// side that could not be read is not a pass — after 392 the fallback IS the
    /// database, so a green row there would be the exact sentence this stage
    /// must never print.
    @Test("An unclean app side is not healthy, however few differences")
    func anUncleanAppSideIsNotHealthy() {
        let one = detail("1")
        var r = DetailParity.compare(app: [one], database: [one])
        #expect(r.unexplained == 0)
        #expect(r.lookedAtSomething)
        #expect(r.isHealthy, "identical sides, cleanly read")

        r.appSideWasReadCleanly = false
        #expect(r.unexplained == 0, "a fallback is not a difference")
        #expect(!r.isHealthy, "but it is not a pass either")
    }

    /// The provenance reaches the paste, at the top, where a reader meets it
    /// before any number it qualifies. §12.54.2.
    @Test("The paste says where the app side came from, and whether it was clean")
    func theProvenanceReachesThePaste() {
        let one = detail("1")
        var r = DetailParity.compare(app: [one], database: [one])
        r.appSideCameFrom = "details/ and streams/, read directly"
        let clean = r.diagnosticLines
        #expect(clean.contains(
            "  the app side came from: details/ and streams/, read directly"))
        #expect(clean.contains("  the app side was read cleanly: yes"))

        r.appSideWasReadCleanly = false
        #expect(r.diagnosticLines.contains("  the app side was read cleanly: NO"),
                "capitalised, because it is the line that costs the pass")
    }

    /// The default is what a caller that built its own list carries. It matches
    /// `ActivityParity`'s rather than `liveStoreIsSettled`'s three states, and
    /// §12.134 argues why.
    @Test("A report nobody told reads as its own list, cleanly")
    func theDefaultProvenance() {
        let r = DetailParity.compare(app: [], database: [])
        #expect(r.appSideCameFrom == "DetailStore.shared")
        #expect(r.appSideWasReadCleanly)
    }
}
