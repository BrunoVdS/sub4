#!/usr/bin/env python3
"""
Patch 313 — D6c slice 2: daily and weekly distance.

Slice 1 proved both sides derive the same LIST. This compares the numbers
computed from it, over the whole history rather than the window a chart draws.

  · THREE THINGS, AND EACH ANSWERS SOMETHING THE OTHERS CANNOT.

    DayDistance.of — one day's distance, and it is not a sum. Patch 249 made it
    refuse to add kilometres across sports, so it answers .km(13.3, .bike) or
    .minutes(74) or .none. A day that changes from kilometres to minutes is a
    difference no field comparison could ever see: every field on every activity
    would still agree.

    VolumeSeries.recordedByWeek — training and commute volume per ISO week, per
    discipline, per unit. Three disciplines times two units times every week.

    VolumeSeries.mix — the whole history in six bands in both units. The one
    volume figure in this app with no clock in it.

  · THE EXTRACTION, AND WHY IT WAS NECESSARY. VolumeSeries.weeks bucketed only
    the 26 weeks it draws. Comparing what it returns would have reported a clean
    half year and said nothing about the eight months before it. So the twelve
    lines that bucket recorded activities became a shared function with no clock
    in it, and weeks() reads its window out of that. Four charts read weeks();
    theWeekBucketingIsUnmoved is what holds the claim that nothing moved.

  · A TOLERANCE, STATED ON SCREEN. Both sides sum the same doubles from lists
    settle put in the same order, so exact equality should hold. Should is not a
    mechanism — §12.49 cost a patch to learn that. One metre and one second;
    below that a difference is arithmetic, above it it is data. Both numbers are
    on screen beside the verdict, because a threshold nobody can see is a
    threshold nobody can argue with. theToleranceIsNotAWildcard pins that it
    admits a rounding difference and refuses a ten-metre one.

  · ONE SECTION, ONE BUTTON, EVERY SLICE — groundwork §7, which left this open
    until there was more than one comparison to lay out. Both slices need the
    same 672-row read and the same settle. Two buttons would do that work twice
    and would let somebody run half of it and see something that looked whole.

  · AND THE RESULT SURVIVES DONE. It was @State on the sheet, so the diagnostics
    paste — the thing somebody reads later — said "Not compared since this
    launch" a minute after the comparison passed. True of the @State and false
    about the world. It lives on a singleton now, like DatabaseWriteThrough
    since 302. Only parity moves; the three read-backs keep their behaviour.

THREE NEW FILES, so this needs a full quit and reopen:
  Sub4/VolumeParity.swift
  Sub4/ShadowParity.swift
  Sub4CoreTests/VolumeParityTests.swift

Files replaced wholesale (they are in the zip, copy them over)
  Sub4/VolumeCard.swift                + recordedByWeek, weeks() reads it
  Sub4/DatabaseHealthView.swift        one section, both slices, off @State
  Sub4/ActivityParity.swift            Outcome and run move to ShadowParity
  Sub4/AppVersion.swift                313
  Sub4CoreTests/ActivityParityTests.swift   follows the move

Files this script edits in place
  docs/ADR-0003-database-contract.md   + §12.57

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


ADR = "docs/ADR-0003-database-contract.md"

ADR_SECTION = r'''## 12.57 The numbers derived from the list — patch 313

D6c slice 2. Slice 1 proved both sides derive the same list; this compares what
the app computes from it.

### 12.57.1 Three figures, and each sees something the others cannot

| | what it is | what only it can catch |
|---|---|---|
| `DayDistance.of` | one day's distance | a day that stops being a distance |
| `recordedByWeek` | training + commute, per week, per discipline, per unit | a week that moved between units |
| `VolumeSeries.mix` | the whole history in six bands | a ride that changed band |

The first is the interesting one. Patch 249 made `DayDistance` **refuse to add
kilometres across sports** — a day with a ride and a swim is reported in
minutes, because minutes add and kilometres do not. So the answer is not a
number, it is one of three shapes, and a day that changes shape is a difference
that **every field comparison in this project would call agreement**: every
field on every activity still matches.

That is the argument for comparing derivations rather than records, made
concrete. §12.16 warned that equal counts can hide changed values; this is one
layer further out — equal *values* hiding a changed answer.

### 12.57.2 The window was the problem, and the fix is the 312 move again

`VolumeSeries.weeks` bucketed only the 26 weeks it draws. Comparing what it
returns would have reported a clean half year and said nothing about the eight
months before it — a denominator of 26 where the honest one is 58, and no line
on screen saying which.

So the twelve lines that bucket recorded activities became
`VolumeSeries.recordedByWeek`: no clock in it, keyed by the Monday's day-key,
covering everything. `weeks()` reads its window out of that.

**This is the third time in four patches.** `byDay` at 312, `isKept` and `dedup`
at 310, this now. The pattern is the same each time: a rule written where its
only caller lived, and a second caller arriving that must not reimplement it.
Worth naming as a rule rather than three incidents:

> **A derivation with one caller looks like part of that caller. It stops being
> that the moment something else must agree with it.**

`theWeekBucketingIsUnmoved` is the test the extraction owes, because four charts
read `weeks()`. It asserts the drawn figures are what the shared function
produced, which is the half a refactor can get wrong silently.

`recordedByWeek` returns an **empty dictionary** for a discipline with nothing
recorded, not a row of zeros. Absent means "this sport does not appear in this
history"; a zero would mean "it appears and did nothing", and only one of those
is true of somebody who has never swum. §12.15's shape, in a dictionary.

### 12.57.3 A tolerance, and why it is on screen

Both sides sum the same doubles from lists `settle` put in the same order, so
exact equality should hold today.

**Should is not a mechanism** — §12.49 cost a patch to learn that sentence. One
reordering anywhere upstream and `==` starts reporting 1e-15 as a data
difference. The first time a gate cries wolf is the last time anybody reads it,
and this project has spent five patches on diagnostics that could not be
believed.

So: **one metre, one second.** Below that a difference is how two identical sums
ended in a different last bit; above it, it is data.

Two things about it are deliberate. It is **printed on screen beside the
verdict**, because a threshold nobody can see is a threshold nobody can argue
with — and a hidden `==` with a fudge factor is exactly the shape of the
diagnostics this file keeps having to correct. And it applies **only to
doubles**: `DayDistance.minutes` and `.none(minutes:)` are `Int`, the
discipline is compared exactly, and the *case* is compared exactly. A tolerance
on an integer would be an invitation.

`theToleranceIsNotAWildcard` pins both ends: half a millimetre passes, ten
metres does not. An untested tolerance is a hole nobody has measured.

### 12.57.4 One section, one button — groundwork §7, answered

§7 left the shape open until there was more than one comparison to lay out.
There are two, and they need the **same** 672-row read and the **same**
`settle`. Two buttons would do that work twice, and — the real argument —
somebody who pressed one and not the other would get an answer that looked
complete and was half.

So `ShadowParity` runs both and holds the result, and `ActivityParity` and
`VolumeParity` become pure comparisons: two `[Activity]` in, a `Report` out, no
database, no store, no clock. That is what lets their tests build the two sides
from genuinely different places, and slice 3 inherits it.

### 12.57.5 The result used to evaporate, and the paste said so

312 held the result in `@State` on the sheet. Pressing Done discarded it, so the
diagnostics paste — the thing read later by somebody who was not there — said
*"Not compared since this launch"* one minute after the comparison passed.

The line was **true of the `@State` and false about the world**. Not a wrong
number; a right number about the wrong subject, which is harder to spot and is
why it survived a screenshot and a paste in the same minute.

It lives on a singleton now, like `DatabaseWriteThrough` since 302, and survives
dismissal within a launch. **Not persisted** — the question is "does the
database agree with the app right now", and a stored answer from three launches
ago would be a second answer to a question the current data already settles
(§12.29).

Only parity moved. The three read-backs and the survey keep their `@State` and
the same trap; changing five things to fix one is how a slice patch stops being
checkable, which is patch 274's rule about not mixing a permissions change into
a mechanical extraction.

'''

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     ADR_SECTION + "## 12.10 The athlete profile, the zones and the resting series",
     "§12.57")


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

    copied = ["Sub4/VolumeParity.swift",
              "Sub4/ShadowParity.swift",
              "Sub4/VolumeCard.swift",
              "Sub4/DatabaseHealthView.swift",
              "Sub4/ActivityParity.swift",
              "Sub4/AppVersion.swift",
              "Sub4CoreTests/VolumeParityTests.swift",
              "Sub4CoreTests/ActivityParityTests.swift"]
    for g in copied:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
        if not here:
            failures += 1

    # THE STALENESS CHECKS. Four files are replaced wholesale, and a wholesale
    # replacement that did not arrive is a red BUILD twenty minutes from now
    # rather than a red script. `AppVersion` is the number this project already
    # trusts for this question; these are the same question, per file.
    stale = [("Sub4/VolumeCard.swift", "recordedByWeek"),
             ("Sub4/DatabaseHealthView.swift", "ShadowParity.shared"),
             ("Sub4/ActivityParity.swift", "MOVED UP FROM `Outcome` AT 313"),
             ("Sub4CoreTests/ActivityParityTests.swift", "VolumeParityTests.neverIsAnAnswer")]
    for rel, marker in stale:
        path = ROOT / rel
        if path.exists() and marker not in path.read_text(encoding="utf-8"):
            print(f"STALE    {rel}  (still the 312 copy)")
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
    print("  1. THREE NEW FILES — quit Xcode entirely (⌘Q) and reopen")
    print("  2. run the suite")
    print("  3. ⌘R → Settings → Sync & data → Database health.")
    print("     The section is now called 'Shadow parity' (no '· activities'),")
    print("     still between 'Read-back · recordings' and 'The app's own files'.")
    print("  4. Press 'Compare the derived lists'. Two blocks appear:")
    print("       The list                  — the thirteen rows from 312")
    print("       Daily and weekly volume   — five new rows")
    print("     Expected: '0 of 324 disagree', '0 of ~350 disagree',")
    print("     '0 of 12 disagree', 'yes', and 'Tolerance  1 m · 1 s'.")
    print("  5. THE ONE TO CHECK DELIBERATELY: press Done, reopen Database")
    print("     health, and Copy diagnostics WITHOUT pressing Compare again.")
    print("     The paste must still carry both slices' figures. On 312 it said")
    print("     'Not compared since this launch' — that is the bug this fixes.")
    print("  6. Open the Progress tab and look at the weekly volume chart.")
    print("     313 changed the function behind it; the bars must be unmoved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
