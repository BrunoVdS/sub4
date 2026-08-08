# Sub4 — Operation Sub-4 iOS training app

Personal single-user iOS app for Bruno's Operation Sub-4 marathon plan
(34 weeks, restart Mon 2026-07-27 → marathon Sun 2027-03-21, target 4:00:00 / 5:41 per km).

This file is what you read first, every session. It is deliberately short.
The detail lives in `docs/` — the index is at the bottom.

---

## 1. Read before you touch anything

In this order, and only what the task needs:

1. **`docs/ADR-0003-database-contract.md`** — authoritative for all persistence work.
   §3 identity, §9 decisions, §12 what the import writes. Long, current, and it
   states the reasoning behind every rule repeated below.
2. **`docs/HANDOFF-2026-08-05-late.md`** — the long form of current state.
   (`HANDOFF-2026-08-05.md` is superseded — ignore it.)
3. **`docs/context/sub4-database.md`** — Phase 3 state, patch 278c, what is next.
4. **`docs/context/working-agreement.md`** — how Bruno wants you to work. Read it once
   per session; it is 200 words and it is not optional.

---

## 2. The rules that cost time when forgotten

**Source of truth — read both, in order:**

- The app was built on **"Strava is the sole source of truth for completed sessions;
  nothing is ever logged manually."** The second half still holds absolutely.
- The first half is **superseded as of 2026-07-31**: Apple Health / HealthKit becomes
  the source of truth and Strava is being removed. See `docs/context/strava-exit.md`.
  The migration has **not started** — the code still reads Strava. Do not "helpfully"
  begin it, and do not write new code that deepens the Strava coupling either.

**Persistence (full reasoning in ADR-0003):**

- A migration is **history**. Vocabularies inside one are frozen literals, coupled to
  the Swift enums by test. Never assert `Sub4Migrations.all.last == <a migration>`.
- **Strava ids are never primary keys** (§3.1).
- The import is **idempotent by lookup, not by luck** — it UPDATEs, it does not skip.
- Each imported row gets its **own SAVEPOINT**.
- Write the **§12 mapping before the importer**, not after.
- A migration may lose the old **shape**, not the **data**: guard the removal of a
  retired key on the new blob actually landing (this is what 278c fixed).

**Swift / concurrency:**

- `Sub4Import` is `nonisolated` end to end. Anything main-actor it needs is computed
  by the caller and passed in.
- Anything that is data rather than state says `nonisolated` when written — and code
  moving from an isolated home to a nonisolated one **inherits nothing**.
  (`a.km` is a MainActor computed property; `a.distance` beside it is stored and is not.
  That broke patch 278.)
- Never put `try` inside `#expect` / `#require` — hoist to a `let`. `#expect`'s message
  is a `Comment?`: an interpolated literal converts, `"a" + "\(b)"` does not.
- A synthesised `init(from:)` does not use Swift default values.
- `Self` in a default argument is covariant Self even on a `final class`.
- SwiftUI type-checker: a large `Form`/`body` as one expression → "unable to type-check
  in reasonable time". Split Sections into computed properties; hoist long strings to
  constants.
- `NSException` cannot be caught by Swift do/catch. Pre-flight Info.plist keys with
  `Bundle.main.object(forInfoDictionaryKey:)` — a missing `NSHealthShareUsageDescription`
  is a hard crash.
- Swift Charts: `AxisContent` cannot be an existential — return `some AxisContent` from a
  function, not a property typed as the bare protocol.
- `ProgressView` is SwiftUI's. The progress tab is `ProgressTabView`.
- `DayKey`'s formatters are `nonisolated(unsafe)` — never mutate them, add a new one.
- Dates are compared as `"yyyy-MM-dd"` strings, never as `Date`.

**Searching this codebase:**

- Sweep the **bare identifier, then filter**. `\.rejected\b` finds reads and misses
  `rejected = []`.
- **Read the view before naming a control.** The match picker has four entry points and
  three labels: "Fix match…" (Today), "Change match" (activity sheet), "Change" / "Match…"
  (session detail). "Fix match" is the sheet's navigation title, not a button.

---

## 3. Build, test, run

**The suite is the gate, and it is fast.** 931 tests in 88 suites, well under a second.

```sh
./scripts/test.sh          # xcodebuild test on the simulator — run before every device build
./scripts/preflight.sh     # test + Release build; run before anything destructive
```

**Why this matters:** ⌘R compiles the app target only, so test-target compile errors
accumulate invisibly. Patches 275, 276 and 277 all ran on the phone while the test target
had not compiled since 273. Run the suite from the CLI so that cannot recur.

**CI is not a check.** The GitHub account is free (2,000 Actions minutes/month) and the
allowance is spent. Exhaustion looks like an instant 2–4 s failure of *every* job with the
annotation about payments / spending limit — that is billing, not code. **It resets
2026-09-01.** Until then, local verification is the source of truth. Never say
"once CI is green" and never treat a push as a check. See `docs/context/ci-budget.md`.

**Simulator cannot answer everything.** Six of eleven Phase 2 defects were hardware-only.
Anything about real activity data, HealthKit, Keychain, or on-device row counts needs the
phone — and Bruno's eyes, because **the app logs nothing at all**. Ask him to look; do not
infer from a green suite.

**Xcode, the hard-won bits:**

- Open **`Sub4.xcodeproj`** (at the repo root), not the `Sub4/` source folder. Cost time twice.
- **Never use Xcode's "Add Files".** Xcode 16+ uses synchronized folders — a new file
  written into `Sub4/` appears in the target automatically. Add Files creates a
  second reference → `Models 2.swift` → invalid redeclaration. Wrecked the project twice.
  This is a real advantage now: you can add Swift files with `Write` and never touch
  `project.pbxproj`.
- GRDB **7.11.1**, pinned Exact Version, revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
  Product `GRDB` (static) on the `Sub4` target only; `GRDB-dynamic` deliberately not linked.
  Tests reach it via `@testable import Sub4`. Xcode's Exact Version field pre-fills `1.0.0`
  (a 2017 tag Swift 6.3 refuses) — type the version and press **Tab**, not Return.
- SwiftUI Preview canvas errors are cosmetic and never block ⌘R.
- Free Personal Team: HealthKit **is** allowed. Push/iCloud/App Groups are gated. €99 buys
  relief from the 7-day provisioning expiry and nothing else that matters here.
  Provisioning expiry means the app stops launching until rebuilt from Xcode.

---

## 4. Working with Bruno

Full version in `docs/context/working-agreement.md`. The short form:

- Ask a clarifying question **once**, then proceed. Never re-ask the same set.
- When he interrupts, **stop immediately** — first time, not the third.
- Do not assert facts derived from files you have not read **this session**.
- Direct and concise. No flattery, no padding. Push back when something is thin or wrong.
- **Never write police operational data anywhere near a cloud service.** Unrelated to this
  repo, but it is a standing rule and it does not have exceptions.

---

## 5. State, as of 2026-08-05 (patch 278c)

- **D0–D4 complete and verified on the device. D5 in progress, 3 of 5 slices done.**
- Ten migrations, 51 tables, 212,295 rows, ~37 MB on the phone.
- `migration_run` reaches `verified`; the semantic verifier compares 19 things across
  four layers.
- **Nothing reads the database yet.** The app still runs entirely off its JSON stores.
  That is D7.

**Do this first, before any new work:**

> **The match picker offers activities the matcher will refuse.** Confirmed on device
> 2026-08-05 22:00. `MatchPickerView.choiceSection` lists `activities(on: dayKey)`
> unfiltered; `Matcher.resolve` builds its pool from `all.filter(\.isPlanEligible)`, and
> `Activity.isPlanEligible` returns `false` by `default:` — so a walk is never eligible.
> Choosing the walk stores the override, the matcher cannot find it, and the session falls
> through to the same branch as "explicitly nothing". Week showed *Not done*, Sessions went
> 4/4 → 3/4, nothing on screen said why. Worse since 272: the import *does* write the row,
> so the store, `match_decision` and the screen disagree — and the verifier cannot see it,
> because it counts rows and the count is right.
>
> **Two fixes and the decision is Bruno's, not yours:**
> (a) the picker lists only plan-eligible activities, extras greyed with a reason;
> (b) an explicit override wins over `isPlanEligible` — which is patch 251's own argument,
> three lines above the walk case: *"the athlete's answer has to be able to win in BOTH
> directions."* (b) has consequences: the walk's distance and load would enter that
> session's adherence and effort figures.
> **Ask, then implement. Do not pick.**

Then: D5's remaining slices, D6 shadow parity, D7 activate, D8 remove the JSON writers.
`docs/context/sub4-database.md` has the ordered list and the open questions inside it.

---

## 6. What this project keeps re-learning

- **Real data beats tests.** The ghost review was found by reading table counts after a run
  that passed 15 comparisons. `work_queue` wrote 2 rows where 23 were predicted.
- **Read the code that produces the number, not the numbers either side of it.**
- A test that keeps passing can stop describing the system.
- A warning-shaped defect needs a test.
- **A method written in anticipation is not a feature.** `ProposalStore.remove` waited 45
  patches for a caller.
- **An account beats a list.** Five counters can each be right while the set is missing a
  case; a residual cannot hide one.
- Six controls have been found reporting work they did not do.

---

## 7. Context index — `docs/context/`

| File | Read it before |
|---|---|
| `working-agreement.md` | anything — how Bruno wants you to work |
| `sub4-database.md` | any database, import or migration work |
| `training-app.md` | any app work — architecture, stores, matcher, plan inventory |
| `strava-exit.md` | any data-source work — the Apple Health migration |
| `review-data-pool.md` | the monthly review, the payload, or Phase 4A |
| `ci-budget.md` | relying on CI or suggesting a push as a check |
| `marathon-plan.md` | editing the plan HTML or regenerating `plan.json` |
| `hevy-setup.md` | anything touching Hevy routines or its API |
| `load-model-research.md` | touching load / TRIMP / CTL calculation |
| `ipad-readiness.md` + `ipad-rebuild-plan.md` | iPad work |
| `mac-readiness.md` | Mac work |

`docs/SWITCHOVER.md` records how this repo moved from Cowork to Claude Code and what
changed. Read once, then it is history.
