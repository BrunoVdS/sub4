#!/usr/bin/env python3
"""
Patch 314 — the day walk, extracted. D6c slice 3, part one.

NO NEW COMPARISON IN THIS PATCH. It moves one function and adds the first tests
it has ever had. 315 builds the twin against a base already known good — patch
274's rule, that a mechanical extraction and a behaviour change in one patch
make both harder to check.

  · WHAT MOVED. `LoadStore.recompute` walked four hundred days over a four-rung
    scoring engine and, inside the walk, reached into eight singletons:
    ActivityStore, DetailStore, ConstantsStore, AthleteStore, NotesStore,
    PlanStore, Matcher and HealthStore. The walk is now
    `LoadSeries.build(from:to:byDay:inputs:)` and every one of those inputs is
    an argument.

    `LoadStore` still decides WHAT to feed it — it reads the stores, measures
    the power factor, maps sRPE through the plan and the matcher, and asks
    Apple Health for the heart rates Strava does not have. That division is the
    point: slice 3 builds the same series from the DATABASE's activities and
    traces with every other input held identical, and that is only possible if
    the walk has no hidden inputs.

  · WHY PMC ITSELF NEEDED NOTHING. §12.16 left slice 3 a note — *one PMC over
    two readers, not two builders*. `PMC.build` was already a pure function of
    `[DailyLoad]` with twelve tests. The builder that needed splitting was one
    layer down, and reading `recompute` is what said so.

  · AND THE SLICE ORDER IS WRONG, WHICH IS WORTH RECORDING. The load series
    needs constants, FTP, notes and plan matching, and the database has no
    repository for any of them — those are slices 5 and 6. Slice 3 sits before
    its own inputs. 315 does the half the database can answer and says on
    screen which inputs were held from the app.

  · THE FIRST TESTS THE WALK HAS EVER HAD. It could not have one before: a test
    would have had to stand up eight singletons. Seventeen now, and the two
    with teeth are that every day is present including the empty ones — an
    average is only defined over a series with no holes — and that a gap is not
    a rest. Both produce a load of zero, so the state is the only thing that
    tells them apart, which is exactly the shape a refactor can flatten without
    any number moving.

WHAT TO WATCH ON THE DEVICE. Thirteen files read what this produces. Nothing
should move anywhere.

ONE NEW APP FILE AND ONE NEW TEST FILE, so this needs a full quit and reopen:
  Sub4/LoadSeries.swift
  Sub4CoreTests/LoadSeriesTests.swift

Files replaced wholesale (they are in the zip, copy them over)
  Sub4/LoadStore.swift                 the walk moves out
  Sub4/AppVersion.swift                314

Files this script edits in place
  docs/ADR-0003-database-contract.md   + §12.58

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

ADR_SECTION = r'''## 12.58 The day walk, extracted — patch 314

D6c slice 3, part one. No new comparison: one function moves and gets the first
tests it has ever had.

### 12.58.1 The note §12.16 left was aimed one layer too high

It said: *one `PMC` over two readers, not two builders*. Reading the source says
that was already true. `PMC.build` takes `[DailyLoad]`, returns `[PMCPoint]`,
touches no clock and no singleton, and has twelve tests.

The builder that needed splitting is underneath it. `LoadStore.recompute` walked
four hundred days over a four-rung scoring engine and, inside the walk, read
**eight** singletons: `ActivityStore`, `DetailStore`, `ConstantsStore`,
`AthleteStore`, `NotesStore`, `PlanStore`, `Matcher` and `HealthStore`.

That is the fourth instance of one rule in five patches — `isKept` and `dedup`
at 310, `byDay` at 312, `recordedByWeek` at 313:

> **A derivation with one caller looks like part of that caller. It stops being
> that the moment something else must agree with it.**

This is the largest of the four. Thirteen files read what it produces: Today's
load strip, the PMC card, monotony, the Week tab, the monthly review.

### 12.58.2 The split is not tidiness, it is what makes a twin possible

`LoadSeries.build` walks the days. `LoadStore` still decides what to feed it —
reads the stores, measures the power factor, maps sRPE through the plan and the
matcher, asks Apple Health for the heart rates Strava does not have.

Slice 3's method is to hold every input identical on both sides except the
activities and the traces, and vary those. **That is only possible if the walk
has no hidden inputs.** An argument list of eight is the honest shape of a
function that genuinely depends on eight things.

One input is a closure and stays one: `hrRest(dayKey)`. The rule behind it —
that month, then the nearest month within three, then the override — lives in
`ConstantsStore` and belongs there. Flattening it to a dictionary here would be
the exact mistake this section is about.

### 12.58.3 The slice order is wrong, and it is worth recording

The load series needs constants, FTP, notes and plan matching. The database
holds all of them in tables and has a repository for **none** of them — those
are slices 5 and 6. Slice 3 sits before its own inputs.

The groundwork's order was written before anybody had read `recompute`. It is
not corrected by reordering, because there is a reason to do slice 3 now:

> D6a accepted a known loss in the traces — *a stream shorter than the distance
> axis comes back padded with zeros and its original length is gone.* Nothing
> has ever asked whether that costs a number the athlete reads.

`LoadEngine` scores from the trace when it has one, so slice 3 is the first
thing that could say. A comparison with a real way to fail is worth more than
one that waits for its inputs — §2.1 of the groundwork.

One input can never come from a database: Apple Health's average heart rate,
which engine version 4 uses where Strava has none. It is a cache of somebody
else's store. Named in `Inputs`, held identical on both sides, and stated rather
than quietly ignored.

### 12.58.4 Seventeen tests where there were none

`recompute` has never had a unit test and could not have had one: a test would
have had to stand up eight singletons. That is why `PMC.build` has twelve and
the thing feeding it had zero — not neglect, a shape.

Two have teeth.

**`everyDayIsPresentIncludingTheEmptyOnes`.** An exponential moving average is
only defined over a series with no holes. Treating "no row" as "no load" is the
single most common way a home-rolled fitness curve goes wrong, and it shortens
the window silently.

**`nothingScoredIsAGap`.** A rest day and a gap both produce `load == 0`. The
**only** thing that distinguishes them is `DayState`, and a curve drawn across a
gap is wrong for six weeks afterwards. A refactor could flatten that distinction
without a single number moving — which is precisely the class of defect a green
suite over numbers would not see.

`aPartialDayCountsOnlyWhatScored` is the same argument at the day level: adding
an unscorable session must move the state and must not move the total.

### 12.58.5 What this patch deliberately does not do

It adds no comparison, no screen row and no repository. The only proof it offers
is that thirteen screens are unmoved — the suite, and Today, Week and Progress
on the device.

Splitting it that way is patch 274's rule: a mechanical extraction and a
behaviour change in one patch make both harder to check, and here a moved load
figure would have had two candidate causes on the most visible screens in the
app.

'''

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     ADR_SECTION + "## 12.10 The athlete profile, the zones and the resting series",
     "§12.58")


def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0

    # THE PREVIOUS PATCH'S DOCUMENTATION, CHECKED — new at 314.
    #
    # 313 moved every Swift file to a wholesale copy, which left its script with
    # one job: the ADR. Skipping the script therefore cost the documentation and
    # NOTHING ELSE — green build, green suite, correct device. A failure with no
    # symptom is the shape this project keeps writing down, and it happened to
    # this project's own tooling.
    #
    # So each patch now checks that the previous one's section landed. It is the
    # chain of custody `AppVersion` already provides for the source.
    adr = ROOT / ADR
    if adr.exists() and "## 12.57 " not in adr.read_text(encoding="utf-8"):
        print("MISSING  docs/ADR-0003 has no §12.57 — run apply-313.py first")
        failures += 1

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

    copied = ["Sub4/LoadSeries.swift",
              "Sub4/LoadStore.swift",
              "Sub4/AppVersion.swift",
              "Sub4CoreTests/LoadSeriesTests.swift"]
    for g in copied:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
        if not here:
            failures += 1

    store = ROOT / "Sub4/LoadStore.swift"
    if store.exists() and "LoadSeries.build" not in store.read_text(encoding="utf-8"):
        print("STALE    Sub4/LoadStore.swift  (still the 313 copy)")
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
    print("\nNEXT — this patch changes no behaviour. Everything below is a")
    print("check that NOTHING MOVED.")
    print("  1. TWO NEW FILES — quit Xcode entirely (⌘Q) and reopen")
    print("  2. run the suite")
    print("  3. ⌘R, check Settings → Version reads patch 314")
    print("  4. Today tab. The load strip under the day: the TRIMP figure, the")
    print("     fitness and fatigue numbers and the freshness word must read")
    print("     exactly what they read on 313.")
    print("  5. Progress tab → the FITNESS card. The two curves and the")
    print("     'n days filled in · n partial' line under them, unmoved.")
    print("  6. Progress tab → LOAD PATTERN. Monotony is derived from the same")
    print("     series; the headline number and 'n of 120 windows not drawn'")
    print("     must be identical.")
    print("  7. Week tab. The per-day load figures.")
    print("  8. Settings → Sync & data → Load diagnostics. 'Coverage', the gap")
    print("     and partial counts and the unscored list — the whole screen is")
    print("     a direct readout of this function.")
    print("\n  If any figure moves, the extraction is wrong. Say which screen")
    print("  and what it said before.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
