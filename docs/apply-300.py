#!/usr/bin/env python3
"""
Patch 300 — D6a, closed.

The measurement 299 predicted, and it held to the number:

    recordings   648 of 649, fetched 1   →   649 of 649
    details      659 of 672, 13 differing →  660 of 672, 12 differing
    activities   672 of 672               →  672 of 672

`fetched` gone from both tallies. 1,412,819 samples compared, no disagreement.
Store-only records zero everywhere; the only residue in the whole corpus is
twelve details carrying the importer's deliberate `positiveOrNil` on a zero
heart rate, and two records the app refuses on purpose.

Three numbers that took the rung to reach zero, none of them a defect in the
data and all three defects in what the diagnostic could SAY about the data:

    fetched differing      320  →  1  →  0        291, 291a, 299
    detail tally rows       25  →  3  →  2        295, 298
    store-only records   4/5/5  →  0/0/0          one import

Documentation only.

  §12.43.6  the measurement, and the prediction recorded as HELD — beside
            §12.39.6 where the other one was falsified. Both were useful.
  §12.44    D6a closed: the final table, the three numbers, what it does not
            say, and what D6b inherits.
  §5        the handoff, moved to where the work actually is.

Files touched
  docs/ADR-0003-database-contract.md   + §12.43.6, + §12.44
  docs/HANDOFF-2026-08-06.md           title, header, §5
  Sub4/AppVersion.swift                300

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
    r'''If either number is different, the inference in §12.43.3 was wrong and there is
a second cause. The measurement goes in §12.43.6, after the run.''',
    r'''If either number is different, the inference in §12.43.3 was wrong and there is
a second cause. The measurement goes in §12.43.6, after the run.

### 12.43.6 The measurement: it held

Run on 7 August at 12:02, patch 299 on the device:

| | before 299 | after |
|---|---|---|
| recordings | 648 of 649, `fetched 1` | **649 of 649** |
| details | 659 of 672, 13 differing | **660 of 672, 12 differing** |
| activities | 672 of 672 | 672 of 672 |

`fetched` is gone from both tallies. The detail tally is exactly
`laps[*].averageHR 11 · 30 elements` and `splits[*].averageHR 1` — eleven plus
one is twelve — and every one of those is the importer's `positiveOrNil`
normalisation, which is intended and documented at §12.37.5. **1,412,819 samples
compared, no disagreement.**

§12.43.5 predicted `fetched 0` and twelve differing details with those two rows
untouched. It held, to the number.

Worth writing down beside §12.39.6, where the other prediction was falsified:
**both outcomes were useful and neither was embarrassing.** The point of writing
a prediction down is not to be right. It is that a measurement taken against a
written prediction cannot be quietly reinterpreted to fit whatever it turns out
to be, which is the failure §12.29.2.1 exists to record.

The inference in §12.43.3 stands: `floor` and `ISO8601DateFormatter` disagree
somewhere, and the only comparison that cannot disagree with a writer is the one
that calls it.

## 12.44 D6a, closed

Ten patches, 289 through 299. Three readers, three comparisons, and four defects
found in the comparisons themselves rather than in the data.

### 12.44.1 The final state

| | in the database | compared | agreed | store-only |
|---|---|---|---|---|
| activities | 672 | 672 | **672** | 0 |
| details | 672 | 672 | **660** | 0 + 1 excluded |
| recordings | 649 | 649 | **649** | 0 + 1 excluded |

1,412,819 samples walked. The only residue in the entire corpus is twelve
details carrying the importer's deliberate `positiveOrNil` normalisation on a
zero heart rate, and two records the app refuses on purpose.

**The database holds what the app holds.** That is what D6a set out to
establish, and it is now a measurement rather than a belief.

### 12.44.2 Three numbers that took the whole rung to reach zero

    fetched differing      320  →  1  →  0        291, 291a, 299
    detail tally rows       25  →  3  →  2        295, 298
    store-only records   4/5/5  →  0/0/0          one import

None of the three was a defect in the data. All three were defects in what the
diagnostic could say about the data, and all three were invisible until the
comparison ran against the real corpus rather than fixtures — §12.36's argument,
now with four more instances behind it.

### 12.44.3 What it does not say

It compares the database to `ActivityStore` and `DetailStore`. It does not
compare either to Strava. That is D6c, it always was, and nothing in this rung
should be read as evidence about it.

### 12.44.4 What D6b inherits

Three read-back rows that now report zero. Their job changes from discovery to
regression: after write-through lands they should read zero for ever without
anybody pressing anything, and any other number is news.

The pattern they establish is the one D6b should extend rather than reinvent:

- an outcome type that cannot return `[]` for a failed read — six instances now
- stable field names, so a tally groups (§12.39.2, §12.40)
- a denominator on the screen, so a green result reads as a result rather than
  as an absence (`samplesWalked`, §12.39.6.1)
- absent-on-purpose kept apart from absent (§12.42.2)
- and, when a comparison must agree with a writer, **call the writer** (§12.43)

''',
    "§12.43.6 and §12.44",
)

# ---------------------------------------------------------------- 2. the handoff

edit(
    H,
    r'''# Sub4 handoff — 6 August 2026, patch 296''',
    r'''# Sub4 handoff — 6 August 2026, patch 300''',
    "the title says where it is",
)

edit(
    H,
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **794 tests in 76 suites,
green.** Working tree clean at 296.

Amended at 293 and again at 296. **D6a is done and proven against the device**,
not against fixtures: 668 activities, 668 details, 645 recordings and 1,403,819
samples compared, with every disagreement explained. §5 is now D6b.''',
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **806 tests in 79 suites,
green.** Working tree clean at 300.

Amended at 293, 296 and 300. **D6a is closed** — not merely written, but run
against the device and reduced to zero: 672 activities, 672 details, 649
recordings and **1,412,819 samples** compared, every read-back reporting zero
store-only records, and the only residue in the corpus one deliberate
normalisation on twelve details. ADR §12.44. §5 is D6b, and its groundwork is
already written.''',
    "the header says what changed",
)

edit(
    H,
    r'''| D6a repositories | **Done and proven** — 289–295, all three read-backs run |''',
    r'''| D6a repositories | **Closed** — 289–299, every read-back at zero |''',
    "D6a is closed",
)

edit(
    H,
    r'''result. **D6a is finished** — three readers, three comparisons, all three run
against the real corpus on 7 August. The next rung is **D6b write-through**,
and §5 states its case as a number rather than an argument.''',
    r'''result. **D6a is closed** — three readers, three comparisons, run against the
real corpus on 7 August and reduced to zero disagreements outside one deliberate
normalisation. The next rung is **D6b write-through**; its groundwork is written
(`D6B-WRITE-THROUGH-GROUNDWORK.md`) and §5 says what is left to decide.''',
    "§1 points at D6b's groundwork",
)

edit(
    H,
    r'''Live docs: `PLAN-cutover-v2.md` (the plan, with M0's result in §3),
`ADR-0003-database-contract.md` §12.27–§12.34 (this session's reasoning),
`STRAVA_DATABASE_CUTOVER_PLAN.md` (the peer review it folds in).''',
    r'''Live docs: `PLAN-cutover-v2.md` (the plan, with M0's result in §3),
`D6B-WRITE-THROUGH-GROUNDWORK.md` (**the next rung, already designed**),
`ADR-0003-database-contract.md` §12.27–§12.44 (this session's reasoning),
`STRAVA_DATABASE_CUTOVER_PLAN.md` (the peer review it folds in).''',
    "the groundwork is a live doc",
)

edit(
    H,
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
  (`samplesWalked` — §12.39.6.1)''',
    r'''## 5. What the next patch should be

**D6b — write-through.** D6a is **closed**, and closed means measured: as of 7
August every read-back reports zero store-only records and the only residue in
the corpus is one deliberate normalisation.

The design work is done and does not need re-deriving:
**`D6B-WRITE-THROUGH-GROUNDWORK.md`**, written at 297, corrected at 298.

### Where D6a ended

| | in the database | compared | agreed | store-only |
|---|---|---|---|---|
| activities | 672 | 672 | **672** | 0 |
| details | 672 | 672 | **660** | 0 + 1 excluded |
| recordings | 649 | 649 | **649** | 0 + 1 excluded |

1,412,819 samples walked, no disagreement. The twelve details are
`laps[*].averageHR` on eleven and `splits[*].averageHR` on one — the importer's
`positiveOrNil` on a zero heart rate, intended and documented. The two excluded
are the sessions `DataCorrections` refuses; the store keeps them and the
database never will. ADR §12.44.

| patch | what | proven against the device |
|---|---|---|
| 289 / 289a | `ActivityRepository` | 290 — 672 compared, 672 agreed |
| 291 / 291a | `ActivityDetailRepository` | 672 compared, 660 agreed |
| 292 / 292a | `RecordingRepository` | 294 — 649 compared, 649 agreed, 1,412,819 samples |
| 295 | the detail tally, made readable | 25 rows → 3 |
| 297 | the import says how long it took | **0.361 s** |
| 298 | both dates printed; excluded ≠ missing | the last `fetched` made legible |
| 299 | `sameSecond` calls the writer | 320 → 1 → **0** |

### What D6b has to do, in one sentence

Make those zeros stay zero without anybody pressing a button.

### The decision the groundwork already made

**Do not write seventeen incremental writers.** `Sub4Import.run` is already the
write-through — it takes every store's entire contents, upserts in one
transaction, and is now proven idempotent against the whole corpus. D6b is a
question about *triggering and failure*, not about SQL. §12.41.1.

**Measured at 297: a full run takes 0.361 s** in steady state, because the
importer already skips a trace whose stored `fetchedUTC` matches. So the answer
is §4.3's first row: fire it after every sync, on a detached task. The cold path
— a first import or one after `resetCache()` — is unmeasured and written down as
unmeasured. §12.42.3.

### The exit gate, as corrected

Not "0 / 0 / 0", which §5.5 of the groundwork proposed and 298 showed could
never be met. **`missing` at zero after a sync the athlete did not trigger by
hand**, with `excluded` shown beside it and free to be non-zero — plus one
deliberate failure leaving a journal entry Settings shows. §12.42.2.1.

### The five questions, all still in the groundwork

Trigger, coalescing, failure record, what the ledger keeps, and file-first
ordering. §5.1 to §5.5 there. None of them needs new investigation; they need
deciding and then writing.

### What D6a leaves for D6c, so nobody reads the table for more than it says

The comparisons check the database against `ActivityStore` and `DetailStore`.
They do not check either against Strava. Shadow parity is D6c and always was.

### The tool that now exists and should be reused

Three read-back rows on the Database screen, each a button that reads everything
and reports a tally with no writes. The pattern is settled; D6b should extend it
rather than invent a second one:

- an outcome type that cannot return `[]` for a failed read (`ActivityLoad`,
  `DetailLoad`, `RecordingLoad`, `Reading`, `RouteCensus`, `StoreLoad` — six
  instances of §12.15's shape)
- stable field names, so a tally groups (§12.39.2, §12.40)
- a denominator on the screen, so a green result is a result and not an absence
  (`samplesWalked` — §12.39.6.1)
- absent-on-purpose kept apart from absent (§12.42.2)
- and when a comparison must agree with a writer, **call the writer** (§12.43)
''',
    "§5 — D6a closed, D6b next",
)

# ---------------------------------------------------------------- 3. the version

edit(
    VER,
    r'''    static let patch = 299''',
    r'''    static let patch = 300''',
    "300",
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
    print("  1. run the suite — 806 in 79, nothing here touches Swift")
    print("  2. commit 297–300")
    print("  3. D6b: decide the five questions in the groundwork, then code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
