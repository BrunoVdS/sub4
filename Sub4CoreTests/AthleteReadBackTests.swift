//
//  AthleteReadBackTests.swift
//  Sub4CoreTests
//
//  The last self-referential read-back, closed — patch 419, ADR-0003 §12.164,
//  plan topic 3.
//
//  WHAT IT WAS COMPARING
//  ---------------------
//  `ReadBacks.athlete` read `ConstantsStore.shared.c`, `AthleteStore.shared.ftp`
//  and `.hrZones` — **all three hydrated from SQLite since B1 (346)**. So the
//  row compared the database with itself: twenty-seven comparisons that could
//  not have disagreed, printed as agreement for seventy-three patches.
//
//  §5.5 has named it since 399 marked the other one. The fix is the move 343
//  made on the plan, 356 on the authored files and 364 on the moves: read the
//  source directly, through an instance that is not the singleton.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("The athlete read-back reads the files")
@MainActor
struct AthleteReadBackTests {

    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("athlete-rb-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Writes `constants.json` in the format the store actually uses — a bare
    /// encoder, for 418's reason.
    private func writeConstants(_ c: AthleteConstants, to dir: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StoreWrite.encode(c, to: dir.appendingPathComponent("constants.json"),
                              store: "constants.json", encoder: e)
    }

    // MARK: 1 — the negative control the prompt asks for

    /// **"Add a negative control where the file and DB differ and prove the row
    /// turns red."** Topic 3's own words.
    ///
    /// Before 419 this could not be written at all: both sides came from the
    /// same hydrated store, so no fixture could make them disagree.
    @Test("A file that disagrees with the database turns the row red")
    func aDisagreementIsVisible() throws {
        var onDisk = AthleteConstants()
        onDisk.hrMaxOverride = 181

        var inDatabase = AthleteConstants()
        inDatabase.hrMaxOverride = 175

        let r = AthleteRoundTrip.compare(store: onDisk, storeFTP: 270,
                                         storeZones: [],
                                         database: .loaded(constants: inDatabase, ftp: 270, zones: []))
        #expect(!r.differences.isEmpty,
                "the file says 181 and the database says 175 — the row must say so")
        #expect(!r.isHealthy)
    }

    @Test("Agreement is still agreement")
    func agreementIsStillAgreement() throws {
        var both = AthleteConstants()
        both.hrMaxOverride = 181

        let r = AthleteRoundTrip.compare(store: both, storeFTP: 270,
                                         storeZones: [],
                                         database: .loaded(constants: both, ftp: 270, zones: []))
        #expect(r.differences.isEmpty)
        #expect(r.lookedAtSomething, "a pass has to have compared something")
    }

    // MARK: 2 — the source reads the files, not the stores

    @Test("The sources read constants.json from the directory it is given")
    func theSourcesReadTheFile() throws {
        let dir = try directory()
        var c = AthleteConstants()
        c.hrMaxOverride = 177
        try writeConstants(c, to: dir)

        // The seam, not the singleton. `ConstantsStore.shared` is hydrated from
        // SQLite and would have answered whatever the database said.
        let store = ConstantsStore(directory: dir)
        #expect(store.c.hrMaxOverride == 177)
        #expect(store.lastLoad == .loaded)
    }

    @Test("An unreadable file is not a clean read of nothing")
    func anUnreadableFileIsNotEmptiness() throws {
        let dir = try directory()
        try Data("{ not json".utf8)
            .write(to: dir.appendingPathComponent("constants.json"))

        let store = ConstantsStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)
        // §12.15. The read-back must be able to say "I could not look", which
        // is a different fact from "there was nothing there".
        let sources = ReadBacks.AthleteSources(
            constants: store.c, ftp: nil, zones: [],
            constantsLoad: store.lastLoad, athleteLoad: .absent,
            directoryFound: true)
        #expect(!sources.isTrustworthy)
    }

    @Test("An absent file is a clean read")
    func absenceIsClean() throws {
        let dir = try directory()
        let store = ConstantsStore(directory: dir)
        // A new install has no `constants.json`, and that is not a fault —
        // `StoreLoad.absent` is trustworthy, and a read-back that called it
        // unclean would report every fresh phone as broken.
        #expect(store.lastLoad == .absent)
        let sources = ReadBacks.AthleteSources(
            constants: store.c, ftp: nil, zones: [],
            constantsLoad: store.lastLoad, athleteLoad: .absent,
            directoryFound: true)
        #expect(sources.isTrustworthy)
    }

    // MARK: 3 — the provenance, which is what the roll-up derives from

    @Test("The row is no longer self-referential")
    func theRowIsIndependent() {
        // `ReadBackSource.isSelfReferential` answers false for `.ownRead`
        // whatever the stores are serving — the roll-up DERIVES independence
        // rather than being told (387, §12.131). Switching the case is the
        // whole of the fix, and this pins it.
        let own = ReadBackSource.ownRead("constants.json and athlete.json, read directly")
        #expect(!own.isSelfReferential(given: .allFromFiles))
        #expect(own.appSideWasReadCleanly)

        // What it used to be, and what that answered.
        // What it used to be, against sources that say `.zones` is fed by the
        // database — which it has been since B1.
        let old = ReadBackSource.liveStores([.from(.zones, "the zones")])
        #expect(old.isSelfReferential(
                    given: ExpectationSources(fedByTheDatabase: [.zones])),
                "the case this row carried until 419")
    }

    @Test("The sources say where they read and whether it was clean")
    func theSourcesSayWhereTheyRead() throws {
        let dir = try directory()
        let sources = ReadBacks.AthleteSources(
            constants: AthleteConstants(), ftp: nil, zones: [],
            constantsLoad: .loaded, athleteLoad: .loaded, directoryFound: true)
        #expect(sources.line.contains("constants.json"))
        #expect(sources.line.contains("athlete.json"))
        #expect(sources.line.contains("read directly"))
        // §12.7 — a container path names the device's user.
        #expect(!sources.line.contains(dir.path))

        let lost = ReadBacks.AthleteSources(
            constants: AthleteConstants(), ftp: nil, zones: [],
            constantsLoad: .absent, athleteLoad: .absent, directoryFound: false)
        #expect(!lost.isTrustworthy)
        #expect(lost.line.contains("unreachable"))
    }

    // MARK: 4 — the wiring, which the other tests do not touch

    /// **THE CONTROL THE FIRST DRAFT WAS MISSING, AND SABOTAGE FOUND IT.**
    ///
    /// Reverting `ReadBacks.athlete` to the shared stores and `.liveStores`
    /// left **the whole suite green**: every test above exercises a piece —
    /// that `compare` can disagree, that `.ownRead` is not self-referential,
    /// that the seam reads the file — and none of them asserted that the
    /// read-back USES any of it.
    ///
    /// §12.129's lesson in a different costume: a set of tests over the parts
    /// of a join says nothing about the join. And 416's: a test can encode a
    /// claim the code never made. This one asks the function itself.
    @Test("The athlete read-back reports its own read, not the stores")
    func theReadBackReportsItsOwnRead() async throws {
        let db = try Sub4Database.inMemory()
        let (_, report, source) = await ReadBacks.athlete(db)

        guard case .ownRead(let where_) = source else {
            Issue.record("the row is self-referential again — got \(source)")
            return
        }
        #expect(where_.contains("read directly") || where_.contains("unreachable"))
        #expect(report.appSideCameFrom == where_,
                "the row's provenance and the roll-up's must be one sentence")
        #expect(!source.isSelfReferential(
                    given: ExpectationSources(fedByTheDatabase: [.zones])),
                "fed or not, a row that went and read the files can disagree")
    }
}

