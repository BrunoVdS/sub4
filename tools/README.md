# tools/ — the plan seed's provenance

**Nothing in this folder is a build step. Read the warning before running
anything here.**

## What is here

| File | What it is |
|---|---|
| `marathon_plan_sub_4hr.html` | The source training document. 283,010 bytes, SHA-256 `5d04c722`. |
| `extract_plan.py` | The extractor that turned it into `Sub4/plan.json`. 21,648 bytes, SHA-256 `665a6f5b`. |

Usage, as the script itself states:

```
python3 extract_plan.py "marathon_plan sub_4hr.html" plan.json
```

## The warning

**Running `extract_plan.py` today would revert patches 238 and 242.**

`Sub4/plan.json` is no longer what this extractor produces. It has been
corrected twice since:

- **Patch 238** — 22 of 37 weeks stated a cycling volume that implied an average
  speed of 58–79 km/h. One factor of two, applied to one contiguous block of
  weeks, reconciled all of them. Corrected to a realistic 29.5 km/h.
- **Patch 242** — the weekly totals were rebuilt from `PlanStore.plannedVolume`
  itself, so the stated figures and the derived line beneath them in the app are
  now the same arithmetic.

Both corrections live in `plan.json`. **Neither lives in the HTML.** The factor
of two is still in the source document, so a re-run overwrites both and the week
headers go back to claiming 125 km and 8 h for week 11 instead of 95 km and 7 h.

ADR-0003 §12.11.5 records this in full.

**Patch 351 (12 Aug 2026) moved the Berlin rest day in BOTH files** (§12.96).

**Patch 350 (12 Aug 2026) moved every run pace +15 s/km through 11 Oct in BOTH
files** (§12.95) — 18 detail lines, same sync-and-diff procedure as 349.

**Patch 349 (12 Aug 2026) revised weeks 4–6 in BOTH files** (§12.94): the HTML
cards, popups and phase strip were edited together with `plan.json`, and the
extractor's session output was diffed against the bundle before shipping —
sessions agree verbatim; the weekly stat lines of the 34 untouched weeks remain
the only divergence. The same was done at 329a for week 2 (this inventory line
was left stale then; it is current again as of 349).

## Why the files are here at all

Until 5 August 2026 they were on no machine anywhere — the seed the whole app is
built on had no reproducible provenance, and the ADR's claim that "the extractor
regenerates `plan.json`" could not be checked by anyone, because there was
nothing to run.

**The decision, 5 August 2026 (D0, ADR-0003 §12.13): archive, do not maintain.**
`plan.json` is the authoritative hand-corrected artefact and is frozen by
`PlanSeedTests`. These two files are history — kept so the seed's origin is
answerable, not so it can be rebuilt.

If the plan ever needs regenerating for real, the correct order is: fix the
weekly totals table in the HTML first, re-run, diff against `Sub4/plan.json`,
and only then update `PlanSeedTests.Frozen` and ADR-0003 §9.2 in the same
commit.

## Why not inside `Sub4/`

The project uses file-system-synchronized groups. A `.py` or `.html` placed
under `Sub4/Sub4/` would be picked up and copied into the app bundle — shipping
a 283 KB training document and a Python script to the phone. `tools/` sits at
the repository root, outside the target's folder, where the synchronized group
cannot reach it.
