//
//  SnapshotAbsenceTests.swift
//  Sub4CoreTests
//
//  Patch 336. Not every absence means the same thing.
//
//  `missingCount` counts declared paths that are not on disk, and on 9 August
//  it read 5 over three stores the wipe took and two file formats that were
//  retired years of patches ago. One number, two facts, and the reader had no
//  way to tell which five — so the row read as five losses.
//
//  These pin the split and, more importantly, pin the FLOOR: `details.json`
//  and `streams.json` cannot exist on an install that never held the pre-split
//  format, so `missingCount` can never reach zero and only `storesNotWritten`
//  can. A test that only checked the sum would keep passing while the sentence
//  the screen tells stayed wrong.
//

import Testing
@testable import Sub4

@Suite("Snapshot absences")
struct SnapshotAbsenceTests {

    private func entry(_ declared: String, exists: Bool) -> SnapshotEntry {
        exists
            ? .init(declared: declared, relativePath: declared, exists: true,
                    bytes: 10, modifiedUTC: nil, sha256: "abc",
                    copied: true, error: nil)
            : .missing(declared: declared, relativePath: declared)
    }

    private func manifest(_ entries: [SnapshotEntry]) -> SnapshotManifest {
        .init(id: "2026-08-09-083914", createdUTC: "2026-08-09T08:39:14Z",
              appVersion: "336", entries: entries)
    }

    /// THE VOCABULARY DECIDES, NOT A HARDCODED PAIR. If `LegacyStore` ever
    /// retires a third format, this follows without an edit — and if it stops
    /// having any, this notices.
    @Test func theRetiredNamesComeFromLegacyStore() {
        let names = SnapshotManifest.retiredFormatNames
        #expect(names == ["details.json", "streams.json"])
        for name in names {
            let match = LegacyStore.allCases.first {
                if case .legacyFile(let n) = $0.item { return n == name }
                return false
            }
            #expect(match != nil, "\(name) is not a .legacyFile in LegacyStore")
        }
    }

    /// THE 9 AUGUST READING, and what it should have said.
    @Test func theNineAugustSnapshotSplitsThreeAndTwo() {
        let m = manifest([
            entry("activities.json", exists: true),
            entry("athlete.json", exists: true),
            entry("constants.json", exists: true),
            entry("weather.json", exists: true),
            entry("commutes.json", exists: false),
            entry("notes.json", exists: false),
            entry("proposals.json", exists: false),
            entry("details.json", exists: false),
            entry("streams.json", exists: false)
        ])
        #expect(m.missingCount == 5)
        #expect(m.retiredFormatsAbsent == 2)
        #expect(m.storesNotWritten == 3)
    }

    /// THE FLOOR. A phone with every store written still reports two absent,
    /// for ever, and that is not a fault — it is the shape of the vocabulary.
    @Test func aCompleteInstallStillReportsTheRetiredFormats() {
        let m = manifest([
            entry("activities.json", exists: true),
            entry("notes.json", exists: true),
            entry("details.json", exists: false),
            entry("streams.json", exists: false)
        ])
        #expect(m.missingCount == 2)
        #expect(m.retiredFormatsAbsent == 2)
        #expect(m.storesNotWritten == 0, "the only number that can reach zero")
    }

    /// A DEVICE THAT UPGRADED THROUGH THE SPLIT still holds them, and then
    /// they are present rather than retired-and-absent.
    @Test func aRetiredFormatThatIsStillOnDiskIsNotAnAbsence() {
        let m = manifest([
            entry("details.json", exists: true),
            entry("streams.json", exists: false)
        ])
        #expect(m.missingCount == 1)
        #expect(m.retiredFormatsAbsent == 1)
        #expect(m.storesNotWritten == 0)
    }

    /// UNCONDITIONAL IN THE PASTE, including at zero — the two lines appear
    /// whatever they say, because a line that only shows up when a retired
    /// format is absent cannot be told from one nobody wired in.
    @Test func bothSplitLinesAlwaysReachThePaste() {
        let m = manifest([entry("activities.json", exists: true)])
        #expect(m.missingCount == 0)
        let lines = m.redactedLines
        #expect(lines.contains { $0.contains("retired formats: 0") })
        #expect(lines.contains { $0.contains("stores not written: 0") })
    }

    /// The total still means what it always meant. `LegacySnapshotTests`
    /// asserts it and the header prints it; 336 added rows beside it rather
    /// than changing it.
    @Test func theTotalIsUnchangedAndTheSplitSumsToIt() {
        let m = manifest([
            entry("notes.json", exists: false),
            entry("details.json", exists: false),
            entry("streams.json", exists: false)
        ])
        #expect(m.retiredFormatsAbsent + m.storesNotWritten == m.missingCount)
        #expect(m.redactedLines[1].contains("3 not present"))
    }
}
