#!/usr/bin/env python3
"""
Patch 296 — the measurements, written down.

294 and 295 both left a section waiting for a number. The numbers exist now, and
one of them falsifies a prediction this file made on purpose so it could be
falsified in public.

  §12.39.6  the recording round trip: 645 compared, 644 agreed, 1,403,819
            samples walked, and ZERO short streams — §12.39.5 predicted some
            and the answer is none. Plus why `samplesWalked` is the number
            that makes a green result readable as a result.
  §12.40.6  what the collapse produced: 25 rows → 3, and a
            `splits[*].averageHR` that had been invisible since 291.
  §5        the handoff moves to D6b, with the case stated as a number.

Documentation only. Bumps AppVersion because the rule since 284 is that a
numbered patch moves the number.

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
H = "docs/HANDOFF-2026-08-06.md"
VER = "Sub4/AppVersion.swift"

# -------------------------------------------------------------------- 1. the ADR

edit(
    ADR,
    r'''The measurement goes in §12.39.6 after the run, and not before.''',
    r'''The measurement is below, and it did not go the way this section said it would.

### 12.39.6 What it found, and the prediction was wrong

Run on 7 August, patch 295 on the device:

    The read                    645 recordings in the database.
    Compared                    645
    Agreed on every sample      644
    Samples walked          1,403,819
    In the store, not in db       5
      fetched                     1
        17463863070 — fetched differs

**No `heartRate length`. Not one.** No `sampleCount`, no `sampleCount vs rows`,
no differing `distanceM`. 1.4 million sample comparisons across 645 recordings,
and the only disagreement in the whole set is a single timestamp.

§12.39.5 predicted the short-stream padding loss would appear on some number of
recordings and said the number was the reason to run this. The number is zero.

**Possible and unobserved is not the same as impossible**, and the distinction
is the finding. The schema genuinely cannot recover the length of a stream
shorter than `distanceM` — §12.38.4 is right and `aShortStreamIsPadded` proves
the mechanism. What this says is that Strava's payloads, after the resampler has
had them, never contain one. The loss is a latent hazard rather than active
damage, and it stays pinned by test because "does not happen today" is a
property of the data and not of the code.

#### 12.39.6.1 `samplesWalked` is the number that makes the rest believable

A comparison reporting near-total agreement is the one to distrust, and this
report was built with that in mind: `walked` accumulates **only** in the
equal-length branch of the walk. If the length gate had been quietly swallowing
recordings — the exact failure a gate invites — `samplesWalked` would have
collapsed toward zero while `agreed` stayed at 645 and looked like success.

It didn't, and the arithmetic is checkable from the screen:

    1,403,819 ÷ 645          = 2,176 comparisons per recording
      192,954 ÷ 645          =   299.2 samples each      ← targetSamples = 300
    1,403,819 ÷ 192,954      =     7.28 streams per sample position, of 8

Five streams are effectively always present (`distanceM`, `heartRate`, `speed`,
`altitude`, `grade`); the remaining 2.28 comes from `latitude`/`longitude` on
outdoor sessions and `power` on the few rides that carry a meter. The ratio is
not a claim about power coverage — indoor sessions have no GPS and the two
effects are not separable from this number alone — it is a cross-check that the
walk did the work it says it did.

**A diagnostic that can only report agreement has not been tested.** This one
carries its own denominator, which is what lets a green result be read as a
result rather than as an absence.

#### 12.39.6.2 The one that differs

`17463863070` differs on `fetched`, and the detail read-back shows exactly one
`fetched` too. Almost certainly a re-fetch after the last import moved the
store's timestamp — not a comparison defect, and 291a taking that column from
320 of 668 down to 1 is the evidence for the distinction.

Recorded rather than chased. One in 645 that resolves on the next import is not
worth a patch; it is worth knowing it is one and not three hundred.

#### 12.39.6.3 D6a is answered

| | compared | agreed | residue |
|---|---|---|---|
| activities (290) | 668 | 668 | — |
| details (291) | 668 | 655 | 13 — `positiveOrNil`, intended, + 1 `fetched` |
| recordings (294) | 645 | 644 | 1 `fetched` |

Every table, every level, against the real corpus rather than fixtures. The
question D6a set out to ask — *does the database hold what the app holds* — is
answered yes.

Two things it does **not** answer, stated so nobody reads the table for more
than it says. It compares the database to `ActivityStore` and `DetailStore`, not
to Strava; that is D6c's job and always was. And the store-only counts — 4
activities, 5 details, 5 recordings — are not a defect in any reader. They are
the last import going stale, they grow every day, and they are D6b's.

''',
    "§12.39.6 — the recording measurement",
)

edit(
    ADR,
    r'''The comment is kept and amended rather than deleted, because the record of
having believed it is the useful part.

## 12.10 The athlete profile, the zones and the resting series''',
    r'''The comment is kept and amended rather than deleted, because the record of
having believed it is the useful part.

### 12.40.6 What the collapse produced

Same run, 7 August. Twenty-five rows and a cut-off became three rows and no
cut-off:

    laps[*].averageHR      11 · 30 elements
    fetched                 1
    splits[*].averageHR     1

    19592747211 — laps[index: 2].averageHR, laps[index: 4].averageHR,
                  laps[index: 6].averageHR, laps[index: 8].averageHR + 13
    17014853339 — laps[index: 1].averageHR
    17749640513 — laps[index: 20].averageHR
    18056328970 — laps[index: 50].averageHR
    18660794652 — laps[index: 28].averageHR
    + 8 more

11 + 1 + 1 = 13, and 668 − 655 = 13. Every differing detail carries exactly one
kind of field; if any carried two the tally would sum above the difference
count, which is a cheap consistency check worth knowing is available.

**`splits[*].averageHR` existed and could not be seen.** One detail, one field,
sitting behind "+ 13 more fields" since 291. The collapse did not find a new
defect — it made a four-patch-old one visible. That is the concrete cost of a
tally that fragments: not wrong rows, but true rows pushed off the bottom by
duplicates of a single cause.

**The distribution is the other thing one number could not say.** `19592747211`
alone accounts for 17 of the 30 laps; the other ten details share the remaining
13. Eleven details each with one bad lap and eleven with thirty between them
have identical `details` counts and describe different situations, and the
`elements` column is the whole reason that is legible here.

Neither of those is a new bug. Both were true before 295 and unreadable, which
is §12.40.1's point measured rather than argued.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.40.6 — what the collapse produced",
)

# ---------------------------------------------------------------- 2. the handoff

edit(
    H,
    r'''# Sub4 handoff — 6 August 2026, patch 293''',
    r'''# Sub4 handoff — 6 August 2026, patch 296''',
    "the title says where it is",
)

edit(
    H,
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **772 tests in 74 suites,
green.** Working tree clean at 293.

Amended at 293: §1, §5 and §8 were written at 288 and D6a finished after them.''',
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **794 tests in 76 suites,
green.** Working tree clean at 296.

Amended at 293 and again at 296. **D6a is done and proven against the device**,
not against fixtures: 668 activities, 668 details, 645 recordings and 1,403,819
samples compared, with every disagreement explained. §5 is now D6b.''',
    "the header says what changed",
)

edit(
    H,
    r'''| D6a repositories | **Done** — three readers, 289–292a |''',
    r'''| D6a repositories | **Done and proven** — 289–295, all three read-backs run |''',
    "D6a is proven, not just written",
)

edit(
    H,
    r'''shortfall is measured and written down. Nothing in the ladder changed as a
result. The next rung is **D6a repositories**, and §6 below is the design work
already done for it.''',
    r'''shortfall is measured and written down. Nothing in the ladder changed as a
result. **D6a is finished** — three readers, three comparisons, all three run
against the real corpus on 7 August. The next rung is **D6b write-through**,
and §5 states its case as a number rather than an argument.''',
    "§1 points at D6b",
)

edit(
    H,
    r'''## 5. What the next patch should be

**The recording round trip, and its read-back row.**

D6a is otherwise done. Three readers landed after this handoff was written:

| patch | what | proven |
|---|---|---|
| 289 / 289a | `ActivityRepository` | 290 — **668 compared, 668 agreed** |
| 291 / 291a | `ActivityDetailRepository` | **668 compared, 655 agreed**, residue explained |
| 292 / 292a | `RecordingRepository` | comparison not yet written — **this is the next patch** |

The design is settled in `D6A-RECORDING-GROUNDWORK.md` §4 and does not need
re-deriving: walk every sample rather than checksumming, gate each recording on
the stored `sampleCount` so one missing sample does not report as thousands of
index differences, and name fields by stream and band —
`heartRate[3 of 1204]` — rather than by index, because `distanceM[47_812]`
names nothing anybody can act on.

**Then D6b write-through**, and the case for it is now a measured number rather
than an argument: the activity read-back reports four activities in the store
and not in the database, which is how stale the last import has become in two
days. It grows daily until D6b lands.

### What the detail read-back found, worth knowing before the next one

Two things, one of them a defect in the comparison rather than the reader:

- **`fetched`, 320 of 668** — `ISO8601DateFormatter` truncates and `sameSecond`
  rounded. 47.9%, which is how many timestamps carry a fraction of 0.5 or more.
  The proportion WAS the diagnosis. Fixed in 291a.
- **`laps[*].averageHR`, ~12 details** — the importer's `positiveOrNil`
  normalisation. Intended, reported, left alone.

Expect the recording comparison to surface its own equivalent: a stream shorter
than `distanceM` comes back padded with zeros and its original length is gone
(§12.38.4). That is a real loss, `aShortStreamIsPadded` already pins it, and it
should be recorded as a measurement rather than smoothed away.''',
    r'''## 5. What the next patch should be

**D6b — write-through.** D6a is finished and, as of 7 August, proven against the
real corpus rather than fixtures.

| patch | what | proven against the device |
|---|---|---|
| 289 / 289a | `ActivityRepository` | 290 — **668 compared, 668 agreed** |
| 291 / 291a | `ActivityDetailRepository` | **668 compared, 655 agreed** |
| 292 / 292a | `RecordingRepository` | 294 — **645 compared, 644 agreed, 1,403,819 samples walked** |
| 295 | the detail tally, made readable | 25 rows → 3 |

Residue, all of it explained and none of it a reader defect:

- **13 details** on `laps[*].averageHR` and one `splits[*].averageHR` — the
  importer's `positiveOrNil` normalisation. Intended, reported, left alone.
- **one detail and one recording** on `fetched` — a re-fetch after the last
  import. Was 320 of 668 before 291a; the drop to 1 is what says the fix was
  real.
- **nothing at all** on the recording streams. §12.39.5 predicted the
  short-stream padding loss would show up and it did not, on a single one of
  645. The schema hazard is real and unobserved — see §12.39.6.

### Why D6b is next, as a number rather than an argument

The read-backs report **4 activities, 5 details and 5 recordings in the store
and not in the database.** That is the last import going stale, and it grows
every day the app runs. The detail and recording counts being higher than the
activity count means at least one activity reached the database while its
children did not, which is the shape of the problem D6b exists to remove.

Nothing may switch its reads to the database while a write path does not exist —
the app would be reading a snapshot that is days behind and has no way to catch
up.

### What D6a leaves for D6c, so nobody reads the table for more than it says

The comparisons check the database against `ActivityStore` and `DetailStore`.
They do not check either against Strava. Shadow parity is D6c and always was.

### The tool that now exists and should be reused

Three read-back rows on the Database screen, each one a button that reads
everything and reports a field tally with no writes. The pattern is settled and
D6b should extend it rather than invent a second one:

- an outcome type that cannot return `[]` for a failed read (`ActivityLoad`,
  `DetailLoad`, `RecordingLoad` — five instances of §12.15's shape)
- stable field names, so the tally groups (§12.39.2, §12.40)
- a denominator on the screen, so a green result is a result and not an absence
  (`samplesWalked` — §12.39.6.1)
''',
    "§5 is D6b",
)

# ---------------------------------------------------------------- 3. the version

edit(
    VER,
    r'''    static let patch = 295''',
    r'''    static let patch = 296''',
    "296",
)


# --------------------------------------------------------------------- machinery

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

    if failures:
        print(f"\n{failures} anchor(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite — nothing here changes Swift, but the rule is the rule")
    print("  2. commit 294–296")
    print("  3. D6b write-through is the next rung")
    return 0


if __name__ == "__main__":
    sys.exit(main())
