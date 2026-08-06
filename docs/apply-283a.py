#!/usr/bin/env python3
"""
Patch 283a — §12.29.2 stated a number that had not been measured, and it was
wrong. This corrects it with the figures 283 actually produced.

It said: "Health holds 579 of the tracked disciplines against the app's 668 —
the app holds more, by tens of sessions." That compared Health's TRACKED count
against the app's TOTAL, which carries 118 sessions of its own `other`. The
real comparison is 580 against 551: Health holds MORE of the tracked
disciplines, not fewer, and the commute hypothesis built on top of it was
backwards.

The finding that survives is a different one, and a sharper one — strength.

A letter fix-up: documentation only, no `AppVersion` bump, no Swift touched.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


A = "docs/ADR-0003-database-contract.md"

# ------------------------------------------------------------------ §12.29.2

edit(
    A,
    r'''The report counted Health by discipline and the app only in total. On this data
that mattered immediately: 710 against 668 looks like Health holding more,
until you notice 131 of Health's are walks and other types the app does not
track. Take those out and Health holds 579 of the tracked disciplines against
the app's 668 — **the app holds more**, by tens of sessions, while day coverage
sits at 99%.

Which means those sessions land on days that are already covered. The obvious
candidate is commute rides: two legs a day, where Strava has both and the watch
or Health recorded one.

The report could not say any of that, and the fix is one field per discipline
on the stored side.''',
    r'''The report counted Health by discipline and the app only in total, so the two
columns could not be compared at all. The fix is one field per discipline on
the stored side.

**What the comparison shows, once it exists.** From the 283 run, same window:

| discipline | Health | the app | |
|---|---|---|---|
| run | 113 | 110 | Health +3 |
| ride | 405 | 373 | Health +32 |
| swim | 54 | 52 | Health +2 |
| **strength** | **8** | **16** | **the app +8** |
| other | 131 | 118 | Health +13 |
| tracked (run/ride/swim/strength) | **580** | **551** | Health +29 |

**The ride surplus is almost certainly not loss.** 153 of 711 sessions carry no
distance at all, and `HealthReconcile.isRelevant(_ w:)` already documents the
cause in its own comment: the watch's "looks like you are cycling" prompt
accepted and then abandoned — records of 1:35, 2:59 and 11:27 with nothing
attached. Health knowing about fragments Strava never received is not a
shortfall.

**Strength is the finding.** The app has sixteen and Health has eight. That
fits `HealthWorkouts.swift`'s own note about a strength session logged through
Hevy reaching Strava with reps, sets and calories and no heart rate.

And it is the one that matters, because **those eight are not among the three
at-risk days.** They sit on days that also carry a run or a ride, so the day
counts as covered while the session would be destroyed. §12.28.4's day-level
limit, producing its first concrete casualty: the shortfall is not "three
days", it is three days plus an unknown number of sessions on covered days, of
which eight are visible right now.

### 12.29.2.1 How the wrong number got into this file

The paragraph this replaces read: *"Take those out and Health holds 579 of the
tracked disciplines against the app's 668 — the app holds more, by tens of
sessions"*, and built a commute hypothesis on top of it. It compared Health's
TRACKED count against the app's TOTAL, which carries 118 sessions of its own
`other`. Health holds more of the tracked disciplines, not fewer.

Worth recording rather than quietly fixing, because it is the same failure as
§12.27: **a conclusion written into this file from a measurement that did not
exist yet.** Patch 283 was built precisely because that comparison was
impossible, and the conclusion was filed anyway, in the document whose whole
job is to be true. A number in here should be one the reader could have got
off the screen.

### 12.29.2.2 Two mappings that are allowed to disagree

''',
    "§12.29.2 corrected, with the error recorded",
)

edit(
    A,
    r'''an `HKWorkoutActivityType` respectively, and a shared helper would couple two
mappings that are allowed to disagree.''',
    r'''an `HKWorkoutActivityType` respectively, and a shared helper would couple two
mappings that are allowed to disagree. Strength is the case that proves it —
the two sides already disagree about eight sessions, and they are entitled to.''',
    "the switch note keeps its point",
)

# ------------------------------------------------------------------ §12.29.4

edit(
    A,
    r'''Session-level agreement. Day coverage at 99% is consistent with tens of
sessions differing, and §12.29.2 says they probably do. That is **D6c shadow
parity's** question, and the tool for it already exists: `HealthReconcile
.build` matches sessions, and it is filtered on both sides to the ones the app
reasons about — which excludes commutes, which is exactly where the difference
will be.''',
    r'''Session-level agreement. Day coverage at 99% is consistent with dozens of
sessions differing, and §12.29.2 shows that they do — Health is ahead by 29
tracked sessions overall while the app is ahead by 8 on strength, and none of
those 8 appear in the three at-risk days.

That is **D6c shadow parity's** question, and the tool for it already exists:
`HealthReconcile.build` matches sessions. It is filtered on both sides to the
ones the app reasons about, and that filter is why it cannot answer this today
— `isRelevant(_ a:)` admits strength only when the session is plan-eligible,
and rides only when they are, so the two categories where the sides actually
differ are the two it declines to look at.''',
    "§12.29.4 names the measured difference",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
for path, old, new, why in EDITS:
    if not path.exists():
        fail(f"missing: {path}")
    text = buffers.get(path, path.read_text())
    if new in text:
        fail(f"already applied? {path.name} — {why}")
    n = text.count(old)
    if n != 1:
        fail(f"{path.name} — {why}: expected one match, found {n}")
    buffers[path] = text.replace(old, new)
    applied.append((path, why))

if "--check" in sys.argv:
    print(f"All {len(applied)} anchors found. Nothing written (--check).")
    sys.exit(0)

for path, text in buffers.items():
    path.write_text(text)
for path, why in applied:
    print(f"  {path.relative_to(ROOT)} — {why}")
print(f"Done. {len(buffers)} files, {len(applied)} edits.")
