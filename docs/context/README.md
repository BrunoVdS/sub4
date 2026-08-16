# `docs/context/` — project knowledge carried over from Cowork

These files were the Cowork project memory for Sub4. They were exported to the repo on
2026-08-07 so Claude Code can read them, because Cowork's memory store does not travel with
the code.

**They are a map, not the territory.** Every one has a date. Where a file states a number or
a line reference, verify it against the code before building on it — that is the standing
rule in `working-agreement.md`, and it applies to these files most of all.

**NONE OF THEM IS CURRENT STATE — patch 384.** `CLAUDE.md` §5 is the only place this
project says what is true now, and `scripts/check-invariants.py` RULE 6 keeps it that way.
`sub4-database.md` is the one to be careful with: its rules are the best short account of
the persistence work in the repository, and its "Where it stood" section is marked history
because it stopped at patch 319 while the code went on to 383.

| File | Date of state | Read before |
|---|---|---|
| `working-agreement.md` | 2026-07-27 | anything |
| `sub4-database.md` | **2026-08-08, patch 319** | any database, import or migration work |
| `training-app.md` | 2026-07-27 | any app work |
| `strava-exit.md` | 2026-07-31 | any data-source work |
| `review-data-pool.md` | 2026-08-05 | the review, the payload, Phase 4A |
| `ci-budget.md` | 2026-08 | relying on CI |
| `marathon-plan.md` | 2026-08-02 (Rev 4.1) | editing the plan HTML / `plan.json` |
| `hevy-setup.md` | 2026-08-02 | Hevy routines or API |
| `load-model-research.md` | 2026-08-02 | load / TRIMP / CTL calculation |
| `ipad-readiness.md` | 2026-07-30 | iPad work |
| `ipad-rebuild-plan.md` | 2026-07-30 | iPad work |
| `mac-readiness.md` | 2026-07-30 | Mac work |

## Two things to know about this set

**One contradiction is deliberate.** `training-app.md` states "Strava is the sole source of
truth"; `strava-exit.md` supersedes that half of the rule as of 2026-07-31. The other half —
nothing is ever logged manually — still holds absolutely. Both files are kept because the
architecture described in the first is what is running today.

**The two device-readiness audits read a reconstructed source tree**, not the live project,
because Cowork could not reach `~/Documents/Developer/sub4`. Claude Code can. Anything those
files mark as "not verifiable" is now a one-minute check — do the check rather than trusting
the audit.

## Keeping them current

These are working notes, not archives. When something here turns out to be wrong or is
superseded, edit the file in the same commit as the code change. A file that stops describing
the system is worse than no file, which is the same lesson the test suite taught this project.

**That rule was broken by the commit that created this directory.** Patch 318 exported the
set and fixed the test counts and the repo-relative paths, but left `sub4-database.md`'s
state sections — and `CLAUDE.md` §5 with them — describing patch 278c, forty patches behind.
A fresh session reading them would have believed the project was mid-D5. Patch 319 refreshed
both; ADR-0003 §12.62 records why it counts as a defect rather than as tidying.

**The date in the table above is the contract.** If a file's date is far behind
`Sub4/AppVersion.swift`, treat its numbers as history and read the code.
