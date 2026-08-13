# Operation Sub-4 — the plan file

*Origin: Cowork project memory `marathon-plan.md`. Exported 2026-08-07. Read before editing
the plan HTML or regenerating `plan.json`.*

"Operation Sub-4" — 34-week plan (restart Mon 2026-07-27 → marathon Sun 2027-03-21, target
4:00:00 / 5:41 per km).

**Source file: `tools/marathon_plan_sub_4hr.html`** (in this repo since 5 Aug 2026;
`Sub4/plan.json` is the frozen, hand-corrected seed — see `tools/README.md` before
regenerating anything).
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

**Rev 5 (2026-08-12, patch 349)** — weeks 4–6 rebuilt around the changed travel
(ADR-0003 §12.94). Wk 4–5 are build-up weeks: the two August tempo sessions became
steady blocks (2k easy + 5/6 km @5:25–5:40 + 2k easy), long runs capped at **12 km**
on Bruno's instruction, strength slots untouched. Wk 6 is a Berlin run block —
Berlin Mon–Fri, no bike, no barbell, no pool: five runs (7 easy · 10 steady ·
5 recovery · 8 easy + strides · 12 long at home Sat), one bodyweight hotel circuit
Wed, return flight now **Fri 4 Sep (SN2588)**, Japan departure Sun 6 Sep. Weeks 7–9
(Japan) and everything later are untouched; race stays 21 Mar 2027. First run past
12 km: week 10. First tempo: week 11.

**Rev 5.1 (2026-08-12, patch 350)** — every run pace from Fri 14 Aug through Sun
11 Oct (end of wk 11, two weeks after Japan) moved **+15 s/km**: easy 6:00–6:15,
recovery 6:15–6:30, steady 5:40–5:55, long 5:50–6:10, wk-11 tempo 5:10–5:25 and MP
finish 5:53–5:58. HR was running too high at the base paces; plan paces resume wk 12
(from 12 Oct). Already-run sessions, the Japan by-feel pointers, swim rep times, bike
and strides untouched. ADR-0003 §12.95.

**Rev 5.2 (2026-08-12, patch 351)** — the Berlin stay is 29 Aug–4 Sep and holds
**running and bodyweight strength only**. Sunday 30 Aug's "Walk / rest" card is gone
(the day keeps its bodyweight circuit — a rest card beside a strength session said two
things at once), and Tuesday 1 Sep is the rest instead, so the four Berlin run days are
split Mon | Wed–Thu rather than run four days straight. Wk 6 is now 4 runs / ~32 km.
ADR-0003 §12.96.

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
