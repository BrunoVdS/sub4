//
//  LateArrivalTests.swift
//  Sub4CoreTests
//
//  A number nobody was told — patch 376, ADR-0003 §12.120.
//
//  THE ONE THAT IS THE POINT
//  -------------------------
//  `noSyncIsNotZero`. `lateArrivals` was `Int = 0`, so a launch on which no
//  sync had run reported "none arrived late" while meaning "nobody has
//  looked". §12.15 is the rule this project applies everywhere else, and the
//  diagnostics screen is the one place that difference is worth a word.
//
//  WHY THESE TEST A FUNCTION AND NOT A STORE
//  -----------------------------------------
//  `ActivityStore` is a singleton pointed at the athlete's real cache, and the
//  count is set by a network sync. Neither state below can be produced on a
//  simulator on demand.
//
//  So the sentence is built by a `nonisolated static` function over the
//  optional — `PersistenceMode.derive`'s reasoning, applied to a smaller
//  thing: pure, so that every combination can be driven from a test without a
//  device. Two of the three states here have never occurred on Bruno's phone.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Late arrivals are reported, and absence is not zero")
struct LateArrivalTests {

    /// **THE ONE THAT IS THE POINT.**
    @Test("No sync is not zero")
    func noSyncIsNotZero() {
        let never = ActivityStore.lateArrivalLine(nil)
        let none = ActivityStore.lateArrivalLine(0)

        #expect(never != none,
                "a launch with no sync must not read like a sync that found none")
        #expect(never.contains("no sync"))
        #expect(!never.contains("0"),
                "the never-synced line must not print a count it does not have")
    }

    @Test("A counted sync says how many")
    func aCountedSyncSaysHowMany() {
        #expect(ActivityStore.lateArrivalLine(3).contains("3"))
        #expect(ActivityStore.lateArrivalLine(0).contains("0"),
                "zero is a finding and gets said, not omitted")
    }

    /// The boundary that reads wrong in every app that does not check it.
    @Test("One arrival reads as one")
    func oneArrivalReadsAsOne() {
        let line = ActivityStore.lateArrivalLine(1)
        #expect(line.contains("1"))
        #expect(!line.contains("11"))
    }

    /// A count with no subject is not a fact. The figure is about the MOST
    /// RECENT sync and is replaced by the next one, so the line has to say so
    /// or a reader will take it for a running total.
    @Test("The line names which sync it is about")
    func theLineNamesWhichSync() {
        let line = ActivityStore.lateArrivalLine(3)
        #expect(line.contains("most recent sync"))
        #expect(line.hasPrefix("Activities arriving late:"),
                "it sits beside the roster block and needs its own subject")
    }
}
