//
//  AppTime.swift
//  Sub4
//
//  Machine timestamps, in the timezone the reader is standing in — patch 304,
//  ADR-0003 §12.48.
//
//  THE DEFECT THIS FIXES WAS MINE, AND IT WAS THE WORST KIND
//  ---------------------------------------------------------
//  The write-through row printed `10:50:39`. That is an ISO-8601 UTC string
//  with the `Z` sliced off, so it looked exactly like a wall clock and was two
//  hours wrong. A time that is obviously wrong gets questioned; a time that is
//  quietly wrong gets believed. The ledger beside it at least kept the `Z`.
//
//  TWO KINDS OF TIMESTAMP, AND ONLY ONE OF THEM BELONGS HERE
//  ----------------------------------------------------------
//  **Machine timestamps** — an import ran, a snapshot was taken, a write
//  failed. These belong to *now*, and "now" is wherever the phone is. They are
//  what this type formats.
//
//  **Activity timestamps** — when the athlete ran. These belong to *where the
//  athlete was*, and the app already carries `timeZoneIdentifier` and
//  `startOffsetSeconds` on every `Activity` for exactly that reason. §4.1:
//  `startUTC` is authoritative for ORDER, `startLocal` for BELONGING. Rendering
//  a run in Romania at Belgian time would be a new bug, not a fix, so **nothing
//  in this file touches them.**
//
//  WHAT STAYS IN UTC ON PURPOSE
//  ----------------------------
//  · **The diagnostic paste.** `MigrationRun.line` and
//    `StoreWriteJournal.diagnosticLines` are text copied OUT of the app, read
//    somewhere else, possibly months later. A local time in a paste is
//    ambiguous unless it names its offset; the ISO string carries its own `Z`
//    and is self-describing.
//  · **The snapshot id.** `2026-08-05-202320` is a FOLDER NAME. It is a stamp
//    being used as an identifier, and localising it would break the
//    correspondence between what the screen says and what is on disk — you
//    could no longer find the folder. **A timestamp that is a name is not a
//    time.**
//
//  ONE PARSER, NOT A SECOND ONE
//  ----------------------------
//  This calls `ActivityDetailRepository.parseUTC`, which is the project's
//  reader for these strings and is written to match `Sub4Import.iso8601`, the
//  writer. §12.43 cost three patches to learn that a second implementation of
//  something that already exists will eventually disagree with it.
//

import Foundation

nonisolated enum AppTime {

    /// A UTC ISO-8601 string, rendered where the reader is.
    ///
    /// RETURNS NIL RATHER THAN A GUESS. A string this cannot parse is not a
    /// time and must not become one — the caller falls back to printing the raw
    /// value, which is ugly and true. Sixth instance of §12.15's shape, and
    /// §12.42.1.1 is what happens when a fallback invents an answer instead.
    static func local(_ utcISO: String?,
                      in zone: TimeZone = .current,
                      now: Date = Date()) -> String? {
        guard let utcISO,
              let date = ActivityDetailRepository.parseUTC(utcISO) else { return nil }
        return local(date, in: zone, now: now)
    }

    /// Today gets a clock; anything older gets a date as well. A bare
    /// `13:09:03` on a row that is four days old is the same class of untruth
    /// this file exists to remove.
    static func local(_ date: Date,
                      in zone: TimeZone = .current,
                      now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone

        let f = DateFormatter()
        // `en_US_POSIX` WITH A FIXED PATTERN, always. A `.current` locale with
        // a hand-written format is the classic way to get 12-hour output on a
        // phone set to 12-hour time while the pattern says `HH` — the format
        // wins in some locales and loses in others.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now)
            ? "HH:mm:ss"
            : "d MMM, HH:mm"
        return f.string(from: date)
    }

    /// For a row that wants the day and nothing else — "5 Aug 2026".
    static func localDay(_ utcISO: String?, in zone: TimeZone = .current) -> String? {
        guard let utcISO,
              let date = ActivityDetailRepository.parseUTC(utcISO) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }
}
