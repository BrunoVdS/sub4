//
//  SectionExportTests.swift
//  Sub4CoreTests
//
//  One section's numbers, as a file — patch 392, ADR-0003 §12.136.
//
//  WHAT IS TESTED HERE AND WHAT IS NOT TESTABLE
//  --------------------------------------------
//  `DiagnosticSectionHeader` is a SwiftUI view and the twenty-two call sites
//  that use it are inside `DatabaseHealthView` and `ShadowParitySections`, so
//  no assertion here can prove a section was given the right lines — that is a
//  reviewer's job and §12.136 says so out loud rather than implying it.
//
//  What CAN be tested is everything with a failure mode: the slug a filename is
//  built from, the stamp that makes a capture readable next week, and the
//  ordering that puts the title where a reader meets it first.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A section exports its own numbers")
struct SectionExportTests {

    // MARK: The slug

    /// **A FILENAME IS NOT A TITLE.** Half these titles carry a middle dot, an
    /// apostrophe or an em dash, and a file named with any of them needs
    /// quoting in every shell and mangles in half the transports it will meet.
    @Test("Every real section title becomes a usable filename")
    func everyTitleSlugsCleanly() {
        let cases: [(String, String)] = [
            ("The file", "the-file"),
            ("Read-back · details", "read-back-details"),
            ("Read-back · weather and gear", "read-back-weather-and-gear"),
            ("The plan's versions", "the-plan-s-versions"),
            ("Shadow parity · tab summaries", "shadow-parity-tab-summaries"),
            ("Rows — 51 tables", "rows-51-tables"),
            ("Traces still to fetch", "traces-still-to-fetch"),
            ("Write-through", "write-through")
        ]
        for (title, slug) in cases {
            #expect(SectionExport.slug(title) == slug, "\(title)")
        }
    }

    /// Letters and digits survive; everything else is one hyphen, and no name
    /// begins or ends with one.
    @Test("A slug never doubles a hyphen and never leads or trails with one")
    func slugIsWellFormed() {
        #expect(SectionExport.slug("  ·· leading and trailing ·· ")
                == "leading-and-trailing")
        #expect(SectionExport.slug("a — b") == "a-b")
        #expect(!SectionExport.slug("Read-back · details").hasPrefix("-"))
        #expect(!SectionExport.slug("Read-back · details").hasSuffix("-"))
    }

    /// A title that is nothing but punctuation still has to produce a file.
    /// §12.15: a button that writes `sub4--2026-08-17-p392.txt` has not failed
    /// in any way anybody can act on.
    @Test("A title with nothing usable in it still names a file")
    func aTitleOfPunctuationStillNamesAFile() {
        #expect(SectionExport.slug("···") == "section")
        #expect(SectionExport.slug("") == "section")
    }

    // MARK: The filename

    @Test("The filename carries the section, the day and the build")
    func theFilenameCarriesAllThree() {
        let e = SectionExport(title: "Read-back · recordings", lines: [])
        #expect(e.filename(day: "2026-08-17", patch: "392")
                == "sub4-read-back-recordings-2026-08-17-p392.txt")
        // A LETTER FIX-UP MUST SHOW. `patchLabel` is what the caller passes and
        // 284a is a different build from 284 — the whole reason that constant
        // exists. §12.79.
        #expect(e.filename(day: "2026-08-17", patch: "392a")
                .hasSuffix("-p392a.txt"))
    }

    // MARK: The text

    /// **THE STAMP IS NOT DECORATION — §12.79.** A section exported alone has
    /// LESS context than the full file, so it needs the build more, not less.
    @Test("The file names its own build and its own section, in that order")
    func theTextLeadsWithTheStampAndTheTitle() {
        let e = SectionExport(title: "Write-through",
                              lines: ["Write-through: Not run since this launch.",
                                      "  runs this launch: 0"])
        let lines = e.text(stamp: "Sub4 1.0 (1) · patch 392").split(separator: "\n",
                                                                   omittingEmptySubsequences: false)
        #expect(lines[0] == "Sub4 1.0 (1) · patch 392")
        #expect(lines[1] == "", "a blank line, so the stamp reads as a header")
        #expect(lines[2] == "Write-through")
        #expect(lines[3] == "Write-through: Not run since this launch.")
        #expect(lines.count == 5)
    }

    /// A section that has nothing to say still produces a file that says so —
    /// §12.54.2. An empty file and a section nobody wired up look identical.
    @Test("A section with no lines still writes its stamp and its title")
    func anEmptySectionStillSaysWhatItIs() {
        let e = SectionExport(title: "Benchmark", lines: [])
        let text = e.text(stamp: "stamp")
        #expect(text == "stamp\n\nBenchmark")
        #expect(!text.isEmpty)
    }

    /// The lines go in as they are. This type formats nothing and decides
    /// nothing — the blocks it carries already satisfied §12.7 to be in the
    /// paste, and re-rendering them here would be a second copy that can drift.
    @Test("The lines are carried verbatim")
    func theLinesAreCarriedVerbatim() {
        let given = ["  fields that differ: distance 3, movingTime 1",
                     "  samples walked: 199848"]
        let e = SectionExport(title: "Read-back · recordings", lines: given)
        for line in given {
            #expect(e.text(stamp: "s").contains(line))
        }
    }
}
