//
//  AppTimeTests.swift
//  Sub4CoreTests
//
//  Patch 304, ADR-0003 §12.48.
//
//  `theSameInstantMovesWithTheSeason` is the one with teeth. Brussels is UTC+1
//  in winter and UTC+2 in summer, so any fix that hardcoded an offset would
//  pass a summer test and be an hour wrong for five months of the year — and
//  the wrongness would be small enough to look like a rounding problem rather
//  than a bug.
//
//  Every test pins an explicit zone and an explicit `now`. A test of a date
//  formatter that reads the machine's own settings passes on the machine that
//  wrote it and proves nothing.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct AppTimeTests {

    private let brussels = TimeZone(identifier: "Europe/Brussels")!
    private let utc = TimeZone(identifier: "UTC")!

    /// THE ONE WITH TEETH.
    @Test("The same clock time moves with the season, not by a fixed offset")
    func theSameInstantMovesWithTheSeason() {
        // 11:09 UTC in August — CEST, +2.
        let summer = "2026-08-07T11:09:03Z"
        #expect(AppTime.local(summer, in: brussels,
                              now: Date(timeIntervalSince1970: 1_786_100_943))
                == "13:09:03")

        // The SAME clock reading in January — CET, +1.
        let winter = "2026-01-07T11:09:03Z"
        #expect(AppTime.local(winter, in: brussels,
                              now: Date(timeIntervalSince1970: 1_767_784_143))
                == "12:09:03")
    }

    @Test("UTC renders as itself")
    func utcIsUnchanged() {
        #expect(AppTime.local("2026-08-07T11:09:03Z", in: utc,
                              now: Date(timeIntervalSince1970: 1_786_100_943))
                == "11:09:03")
    }

    // MARK: Today versus not

    /// A bare clock time on a four-day-old row is the same class of untruth
    /// this whole patch removes.
    @Test("Anything but today carries its date")
    func olderRowsCarryTheirDate() {
        let now = Date(timeIntervalSince1970: 1_786_100_943)   // 2026-08-07T11:09:03Z

        #expect(AppTime.local("2026-08-07T06:00:00Z", in: brussels, now: now) == "08:00:00",
                "same local day — a clock is enough")
        #expect(AppTime.local("2026-08-05T18:23:20Z", in: brussels, now: now) == "5 Aug, 20:23",
                "two days ago — the date has to be there")
    }

    /// The boundary is the LOCAL day, not the UTC one. 22:30 UTC on the 6th is
    /// 00:30 on the 7th in Brussels, and calling that "yesterday" would be
    /// wrong in exactly the way this patch is about.
    @Test("Today means today where the reader is")
    func theDayBoundaryIsLocal() {
        let now = Date(timeIntervalSince1970: 1_786_100_943)   // 2026-08-07T11:09:03Z
        #expect(AppTime.local("2026-08-06T22:30:00Z", in: brussels, now: now) == "00:30:00",
                "00:30 local on the 7th, so it is today")
        #expect(AppTime.local("2026-08-06T22:30:00Z", in: utc, now: now) == "6 Aug, 22:30",
                "and in UTC the same instant is yesterday")
    }

    // MARK: It refuses rather than invents

    /// §12.42.1.1 is what happens when a fallback invents an answer. A string
    /// this cannot parse is not a time, and the caller prints the raw value —
    /// ugly and true.
    @Test("Something that is not a timestamp comes back nil")
    func nonsenseIsNil() {
        #expect(AppTime.local(nil) == nil)
        #expect(AppTime.local("") == nil)
        #expect(AppTime.local("not a date") == nil)
        #expect(AppTime.local("2026-08-07") == nil, "no time, no offset")
        #expect(AppTime.localDay(nil) == nil)
    }

    @Test("A day on its own says which day")
    func theDayFormat() {
        #expect(AppTime.localDay("2026-08-07T22:30:00Z", in: brussels) == "8 Aug 2026",
                "past midnight locally, so the local day is the 8th")
        #expect(AppTime.localDay("2026-08-07T22:30:00Z", in: utc) == "7 Aug 2026")
    }

    /// A fixed pattern with a locale-sensitive formatter is the classic way to
    /// get 12-hour output on a phone set to 12-hour time. Pinned because it
    /// would show up as an off-by-twelve nobody could reproduce.
    @Test("It is always a 24-hour clock")
    func alwaysTwentyFourHour() {
        let now = Date(timeIntervalSince1970: 1_786_132_800)   // 2026-08-07T20:00:00Z
        #expect(AppTime.local("2026-08-07T20:00:00Z", in: utc, now: now) == "20:00:00")
        #expect(AppTime.local("2026-08-07T00:30:00Z", in: utc, now: now) == "00:30:00")
    }
}
