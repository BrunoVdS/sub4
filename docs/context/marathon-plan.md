# Operation Sub-4 — the plan file

*Origin: Cowork project memory `marathon-plan.md`. Exported 2026-08-07. Read before editing
the plan HTML or regenerating `plan.json`.*

"Operation Sub-4" — 34-week plan (restart Mon 2026-07-27 → marathon Sun 2027-03-21, target
4:00:00 / 5:41 per km).

**Source file: `marathon_plan sub_4hr.html`**, currently in `~/Documents/Triathlon/`.
A PDF export of section 07 week cards only exists (WeasyPrint); **since Rev 4 the PDF is
stale** — it lacks the strength cards.

**Week cards are canonical.** They are the source of truth for any edit.

## Revisions

**Rev 3 (2026-07-25)** — every swim day card is clickable → floating modal with the full
session (WU/main/kick/CD). Swim data lives in a `SWIM_DATA` JS object keyed by week number
(`"02"`..`"33"`); the old mis-numbered swim table was replaced by a pointer note.

**Rev 4 (2026-07-25)** — strength built in. 56 static orange `.ses` cards (colour var
`--str`, in all 3 palettes) across Wk 1–33; Wk 34 has none. Tue = Strength A (home gym,
alternating A1 squat / A2 hinge, 2-RIR, plyo from Wk 13), Thu = Strength B (bodyweight/core,
also the vacation version — Wk 7–10 Japan are B-only). Popups mirror the swims:
`STRENGTH_DATA` keyed by week then `"Day|Title"`; each exercise line has a ▸ VIDEO link.
Section 08b (before 09 Fueling): rationale, two-slots table, phase map, 20-movement exercise
library, rules box. Rules: RPE 8 / 2 RIR, no Valsalva, no heavy legs within 48 h of the Sat
long run, drop order B → A. **Strength never counts in km/h totals.**

**Rev 4.1 (2026-08-02)** — light/deload week cards renamed to "· light" (Wk 2, 3, 4, 5, 6,
19, 33) so every card title maps 1:1 to a Hevy routine. Before this, Wk 2/4/6 and Wk 12
shared the title "Strength A1 · squat (evening)" while prescribing different work.
Prescriptions unchanged. **Renaming a card means renaming BOTH the static `.ttl` (literal
"·", not `&middot;`) and the matching `"Day|Title"` key in `STRENGTH_DATA`, or the popup
silently stops opening.**

## Companion files

The 56 sessions are only **8 distinct workouts**. `Sub-4 strength sessions.md` writes out
every distinct session (prescription, rest, cue, video) plus a week-by-week routine lookup
table. It is **GENERATED from the plan file — regenerate rather than hand-edit.**
Verified 2026-08-02: plan and Hevy agree 56/56 (see `hevy-setup.md`).
Also in that folder: `strength_integration_investigation.md`.

## Design rationale worth keeping

- Why Tue/Thu: Fri is the only free day but is 24 h before the long run — deliberately
  avoided.
- The Jan–Feb Z2 block (Wk 24–31) is the heaviest strength block: lowest interference,
  and economy gains mature for March.

## How to apply

- Week cards stay canonical.
- Strength cards are static HTML (they survive a PDF re-export; popups do not).
- The wiring JS matches titles starting with `"Strength"` — keep that prefix.
- The plan is **pace + RPE driven; HR is a ceiling only.** rTSS in TrainingPeaks is
  miscalibrated — ignore TSS/CTL from there.
- After any plan change: re-run `extract_plan.py` against the HTML, drop the new `plan.json`
  into the app source folder, rebuild. The extractor validates and exits non-zero on failure.
