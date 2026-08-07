#!/usr/bin/env python3
"""
Patch 304 — a time that is quietly wrong gets believed.

The write-through row printed `10:50:39` while the phone said `12:50`. It was an
ISO-8601 UTC string with the `Z` sliced off, so it looked exactly like a wall
clock and was two hours out. `10:50:39` is a plausible clock reading, so nothing
about it invited checking — the ledger beside it kept its `Z` and was honest, if
inconvenient.

TWO KINDS OF TIMESTAMP, AND ONLY ONE MOVES.

  machine   an import ran, a snapshot taken, a write failed → the phone's zone
  activity  when the athlete ran                            → the ACTIVITY's zone

The second is already handled — every Activity carries `timeZoneIdentifier` and
`startOffsetSeconds`, and §4.1 says startUTC is authoritative for ORDER and
startLocal for BELONGING. Rendering a run in Romania at Belgian time would be a
new bug wearing the fix's clothes. Nothing here touches it.

WHAT STAYS IN UTC, AND IT IS NOT AN EXCEPTION:

  · The diagnostic paste — read elsewhere, months later, by somebody who does
    not know where the phone was. The ISO string carries its own Z.
  · The snapshot id — `2026-08-05-202320` is a FOLDER NAME. Localising it would
    break the correspondence with what is on disk.

    A timestamp that is a name is not a time.

AND IT REFUSES RATHER THAN INVENTS. `AppTime.local` returns String?; every call
site falls back to the raw value. `?? .distantPast` cost a patch three weeks ago
(§12.42.1.1) and this is the same shape.

ONE NEW FILE EACH SIDE, so this needs a full quit and reopen:
  Sub4/AppTime.swift
  Sub4CoreTests/AppTimeTests.swift

Files touched
  Sub4/DatabaseHealthView.swift        the ledger, and why the snapshot id stays
  Sub4/DatabaseWriteThrough.swift      the row that started this
  Sub4/StoreWriteJournal.swift         the day boundary, which was UTC's
  docs/ADR-0003-database-contract.md   + §12.48
  Sub4/AppVersion.swift                304

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


VIEW = "Sub4/DatabaseHealthView.swift"
WT = "Sub4/DatabaseWriteThrough.swift"
JOURNAL = "Sub4/StoreWriteJournal.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(VIEW, r'''                LabeledContent("Started", value: r.startedUTC).font(.caption)
                if let f = r.finishedUTC {''', r'''                // LOCAL, WITH THE RAW STRING AS THE FALLBACK — patch 304.
                //
                // These were the ISO-8601 UTC values verbatim, which are
                // correct and are two hours from what the clock on the phone
                // says. A `Z` is self-describing and a reader still has to do
                // the arithmetic; a screen should not ask them to. §12.48.
                //
                // If `AppTime` cannot parse it the raw value is printed, ugly
                // and true, rather than a guess — §12.42.1.1.
                LabeledContent("Started",
                               value: AppTime.local(r.startedUTC) ?? r.startedUTC)
                    .font(.caption)
                if let f = r.finishedUTC {
''', "the ledger reads where the reader is")
edit(VIEW, r'''                    LabeledContent("Finished", value: f).font(.caption)''', r'''                    LabeledContent("Finished", value: AppTime.local(f) ?? f).font(.caption)
''', "and so does Finished")
edit(VIEW, r'''                LabeledContent("Last snapshot", value: m.id)
                    .font(.caption)''', r'''                // NOT LOCALISED, and that is the decision — patch 304.
                //
                // `2026-08-05-202320` is a FOLDER NAME. It is a stamp being
                // used as an identifier, and rendering it as local time would
                // break the correspondence between this row and what is on
                // disk: you could no longer find the directory it names.
                //
                // A timestamp that is a name is not a time. §12.48.
                LabeledContent("Last snapshot", value: m.id)
                    .font(.caption)
''', "the snapshot id stays a name")
edit(WT, r'''    var line: String {
        switch last {
        case .never:
            "Not run since this launch."
        case .wrote(let r, let at):
            "\(at.suffix(9).prefix(8)) — \(r.activitiesSeen) activities, "
            + String(format: "%.3f s", r.seconds)
        case .noDatabase:
            "The database is not open, so nothing was written."
        case .failed(_, let at):
            "\(at.suffix(9).prefix(8)) — the write failed."
        }
    }''', r'''    var line: String {
        switch last {
        case .never:
            "Not run since this launch."
        case .wrote(let r, let at):
            // LOCAL — patch 304. This used to slice the `Z` off the ISO string
            // and print `10:50:39`, which looked exactly like a wall clock and
            // was two hours out. A time that is obviously wrong gets
            // questioned; a time that is quietly wrong gets believed. §12.48.
            "\(AppTime.local(at) ?? at) — \(r.activitiesSeen) activities, "
            + String(format: "%.3f s", r.seconds)
        case .noDatabase:
            "The database is not open, so nothing was written."
        case .failed(_, let at):
            "\(AppTime.local(at) ?? at) — the write failed."
        }
    }
''', "the row that started this")
edit(JOURNAL, r'''    /// One line for Settings. No paths, no error domains.
    var line: String {
        attempts == 1
            ? error.errorDescription ?? "could not be saved"
            : "\(attempts) attempts since \(firstFailedUTC.prefix(10))"
    }''', r'''    /// One line for Settings. No paths, no error domains.
    ///
    /// LOCAL, patch 304 — the day this started failing, where the reader is.
    /// `prefix(10)` on the ISO string gave the UTC date, which is the wrong day
    /// for anything that failed after 22:00 in Brussels. §12.48.
    var line: String {
        attempts == 1
            ? error.errorDescription ?? "could not be saved"
            : "\(attempts) attempts since "
              + (AppTime.localDay(firstFailedUTC) ?? String(firstFailedUTC.prefix(10)))
    }
''', "the day boundary was UTC's")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.48 A time that is quietly wrong gets believed — patch 304

The write-through row printed `10:50:39` while the phone said `12:50`. Bruno
asked why, and the answer is that I had sliced the `Z` off an ISO-8601 UTC
string and printed what was left.

**A time that is obviously wrong gets questioned. A time that is quietly wrong
gets believed.** `10:50:39` is a plausible reading of a clock, so nothing about
it invites checking. The ledger row beside it at least kept the `Z` and was
therefore honest, if inconvenient.

### 12.48.1 Two kinds of timestamp, and only one moves

| | belongs to | rendered in |
|---|---|---|
| **machine** — an import ran, a snapshot was taken, a write failed | *now* | the phone's current zone |
| **activity** — when the athlete ran | *where the athlete was* | the activity's own zone |

The second category is already handled and must not be touched. Every `Activity`
carries `timeZoneIdentifier` and `startOffsetSeconds` for exactly this, and §4.1
says `startUTC` is authoritative for ORDER while `startLocal` is authoritative
for BELONGING. Rendering a run in Romania at Belgian time would be a new bug
wearing the fix's clothes.

`AppTime` formats the first category only, and its header says so.

### 12.48.2 What stays in UTC, and why that is not an exception

**The diagnostic paste.** `MigrationRun.line` and
`StoreWriteJournal.diagnosticLines` are text copied *out* of the app and read
somewhere else, possibly months later, by somebody who does not know where the
phone was. A local time in a paste is ambiguous unless it names its offset; the
ISO string carries its own `Z`.

**The snapshot id.** `2026-08-05-202320` is a **folder name**. It is a stamp
being used as an identifier, and localising it would break the correspondence
between the row on screen and the directory on disk — you could no longer find
what it names.

> **A timestamp that is a name is not a time.**

That line is the whole of the distinction, and it is why the fix is not "convert
every UTC string on screen".

### 12.48.3 The day boundary is local, which is the half that gets missed

`StoreWriteJournal`'s row said *"3 attempts since 2026-08-06"* by taking
`prefix(10)` of the ISO string. For anything that first failed after 22:00 in
Brussels that is the wrong day — the athlete's evening is already tomorrow in
UTC.

`theDayBoundaryIsLocal` pins it in both directions: 22:30 UTC on the 6th is
*today* in Brussels and *yesterday* in UTC, and both readings are correct for
their own zone.

### 12.48.4 A formatter that cannot parse must not invent

`AppTime.local` returns `String?`, and every call site falls back to printing
the raw value. Ugly and true.

The alternative was live for a while and cost a patch: `?? .distantPast` in
`RecordingRepository` turned an unparseable timestamp into a date in the year 1,
which the comparison then reported as a disagreement about *when* something was
fetched (§12.42.1.1). Sixth instance of §12.15's shape and the second time in
three patches that a date fallback was the thing that lied.

### 12.48.5 Two ways to get this wrong that are pinned rather than avoided

- **A hardcoded offset.** Brussels is UTC+1 in winter and UTC+2 in summer. A fix
  written in August with `+2` in it passes every test written in August and is
  an hour wrong for five months — small enough to read as a rounding problem
  rather than a bug. `theSameInstantMovesWithTheSeason` runs the same clock
  reading through both seasons.
- **`Locale.current` with a fixed pattern.** A phone set to 12-hour time can
  make `HH` render as 12-hour in some locales. `en_US_POSIX` is the fix and
  `alwaysTwentyFourHour` is the pin, because the symptom would be an
  off-by-twelve nobody could reproduce on their own device.

Every test names its zone and its `now` explicitly. A date-formatter test that
reads the machine's own settings passes on the machine that wrote it and proves
nothing.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.48")

edit(VER, "    static let patch = 303", "    static let patch = 304", "304")


def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0
    writes = {}
    for path, old, new, why in EDITS:
        if not path.exists():
            print(f"MISSING  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        text = writes.get(path, path.read_text(encoding="utf-8"))
        if new in text and old not in text:
            print(f"already  {path.relative_to(ROOT)}  ({why})")
            continue
        n = text.count(old)
        if n != 1:
            print(f"ANCHOR x{n}  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        writes[path] = text.replace(old, new, 1)
        print(f"ok       {path.relative_to(ROOT)}  ({why})")

    for g in ["Sub4/AppTime.swift", "Sub4CoreTests/AppTimeTests.swift"]:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
        if not here:
            failures += 1

    if failures:
        print(f"\n{failures} item(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. TWO NEW FILES — quit Xcode entirely (\u2318Q) and reopen")
    print("  2. run the suite")
    print("  3. \u2318R, Database: the ledger and the write-through row should now")
    print("     read the same clock your phone does. The snapshot id stays a")
    print("     stamp on purpose — it is the folder's name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
