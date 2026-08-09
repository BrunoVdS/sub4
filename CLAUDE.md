# Sub4 — Operation Sub-4 iOS training app

Personal single-user iOS app for Bruno's Operation Sub-4 marathon plan
(34 weeks, restart Mon 2026-07-27 → marathon Sun 2027-03-21, target 4:00:00 / 5:41 per km).

This file is what you read first, every session. It is deliberately short.
The detail lives in `docs/` — the index is at the bottom.

**Current at patch 332 (2026-08-09).** Patch 318 installed this file with its state
sections still describing patch 278c — forty patches behind — which is the failure
this file exists to prevent. §5 is the part that goes stale; if the patch number in
its heading is far behind `Sub4/AppVersion.swift`, trust the ADR and the code, not §5.

---

## 1. Read before you touch anything

In this order, and only what the task needs:

1. **`docs/ADR-0003-database-contract.md`** — authoritative for all persistence work, and
   the only document that is always current. §3 identity, §9 decisions, §12 what the import
   writes and every patch decision from 200 onward. **§12 is the running log; there is no
   CHANGELOG and there should not be one.** Newest sections are appended before §12.10, not
   at the end of the file.
2. **`docs/context/sub4-database.md`** — the shorter map of the same ground.
3. **`docs/context/working-agreement.md`** — how Bruno wants you to work. Read it once per
   session; it is 200 words and it is not optional.
4. **`docs/D6C-SHADOW-PARITY-GROUNDWORK.md`** — if the task is D6c. §6 has the slice order.
5. **`docs/D6C-SLICE-8-GROUNDWORK.md`** — if the task is slice 8. Checked against the
   source at 328a; §1.1 lists what slices 1–7 already cover and must not be re-proved.

**The handoffs are history, not state.** `HANDOFF-2026-08-05.md`,
`HANDOFF-2026-08-05-late.md` and `HANDOFF-2026-08-06.md` were snapshots; the newest is
already three days and forty patches old. Read one only to understand how something got
the way it is. ADR §12 supersedes all three.

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

- A migration is **history**. Vocabularies inside one are frozen literals, coupled to the
  Swift enums by test. Never assert `Sub4Migrations.all.last == <a migration>`.
  A new column means a **new dated migration file**, registered in `Sub4Migrations.migrator`
  *and* appended to `Sub4Migrations.all` — and the identifiers must sort into run order,
  because `all == all.sorted()` is asserted.
- **Strava ids are never primary keys** (§3.1).
- The import is **idempotent by lookup, not by luck** — it UPDATEs, it does not skip.
- Each imported row gets its **own SAVEPOINT**.
- Write the **§12 mapping before the importer**, not after. Seven mappings written before
  their importer; seven found something.
- A migration may lose the old **shape**, not the **data**: guard the removal of a
  retired key on the new blob actually landing (this is what 278c fixed).

**Swift / concurrency — and the three at the top are recent and expensive:**

- **SE-0434: stored properties of `Sendable` type in a main-actor-isolated value type are
  implicitly `nonisolated`. Computed properties are NOT** — they are methods.
  `Sub4Import+Athlete` has read `constants.hrMaxOverride` off the main actor since 228 with
  no keyword; `AthleteConstants.hrMax` beside it needed one at 317.
- **`nonisolated` on a type reaches the members written in its own body. It does not reach
  its extensions.** `AthleteStore.HRZone` went nonisolated at 317 and `HRZone.titled` broke,
  because `name` lives in `extension AthleteStore.HRZone` in `Theme.swift`, which takes the
  module default. Five instances: 207, 219, 228, and both ends of 317.
- **Reading a stored property off the main actor works; CONSTRUCTING the type does not.**
  SE-0434 covers the read, not the initialiser — `Sub4Import` had read `ActivityWeather`
  fields since 133 and 324 was the first code to build one off the actor. Mark the type
  `nonisolated`, and grep for `extension <Type>` first.
- **`optional == nil` is a call to `Optional.==` and needs `Wrapped: Equatable`.** In a
  `nonisolated` context the conformance must be nonisolated too, so `dict[key] == nil`
  fails on a main-actor value type with nothing on the line naming it. Ask the keys:
  `Set(a.keys).subtracting(Set(b.keys))`. Sixth isolation instance — 322a; the first
  invisible in review.
- `Sub4Import` is `nonisolated` end to end. Anything main-actor it needs is computed
  by the caller and passed in.
- **A test that builds an invalid state through SQL is subject to the schema's own CHECK
  constraints.** If the reader must survive a state the schema forbids, force it with
  `PRAGMA ignore_check_constraints` inside `writeWithoutTransaction`, and assert the
  refusal separately. 322's two failures were setup failures, not assertion failures.
- Never put `try` inside `#expect` / `#require` — hoist to a `let`. `#expect`'s message
  is a `Comment?`: an interpolated literal converts, `"a" + "\(b)"` does not.
- A synthesised `init(from:)` does not use Swift default values.
- `Self` in a default argument is covariant Self even on a `final class`.
- **A view body has TWO size limits, and only one of them fails on your laptop.** The
  compile-time one is below. The RUNTIME one is `EXC_BAD_ACCESS` inside `___chkstk_darwin`
  at a stack address — a **stack overflow** evaluating the body. It compiles clean, passes
  the suite, and only appears on the device. §12.75.10, §12.76.
- **The budget is DEPTH, not rows, and a child that draws nothing still spends it.**
  A `@ViewBuilder` block is built pairwise, so N children are N−1 nested `TupleView`s and
  SwiftUI walks that chain recursively before drawing anything. 330 crashed on pressing
  Compare; 330b "fixed" it by giving the new rows their own `Section` — one more top-level
  child — and it crashed **on opening the tab**, where those rows render nothing. When a
  size fix makes the crash EARLIER, the size was not the size you thought it was.
  Remedy, in order: **fewer children per block** (group into `@ViewBuilder` functions —
  21 in a row is depth 20, six groups is depth 9), then **a separate `View` struct** for
  any subtree whose dependency surface is small enough to move without moving `@State`.
  330c did both: `ShadowParitySections.swift` is 700 lines that left the screen's type.
  §12.76.
- **`DatabaseHealthView` is where this keeps happening.** Adding to it is a structural
  change, not an edit. Read §12.76 before adding rows to it. 331 added a Section by
  putting it inside an existing group and splitting its rows into two functions — the
  screen's depth did not move.
- **A computed diagnostic behind a `@State` precondition is not a diagnostic** (§12.77.5).
  It is one for whoever pressed the button, in the launch they pressed it, and for nobody
  afterwards. `TraceCoverage` counted 674 activities into five buckets from patch 277 and
  `DetailStore.backfillRemaining` was `pending.count` from the day it was written — both
  drawn only inside `if let importReport`, and both invisible on the two days a backfill
  made them the only numbers that mattered. Same shape as §12.57. When you add a counter,
  ask *who can read it and when*; the answers must be **anybody** and **whenever the screen
  is open**.
- **The "unable to type-check in reasonable time" failure is not a SwiftUI failure.** A
  large `Form`/`body` as one expression is the common case — split Sections into computed
  properties, hoist long strings to constants — but 327a hit it in a plain `[String]`:
  `diagnosticLines` was one array literal of 38 interpolated elements, two of them `+`
  concatenations. `PlanExtrasRoundTrip`'s 34 compiles, so the threshold is between them
  and is not worth locating. **A list of interpolated strings is an expression, not a
  list** — build it with `append` statements once it is longer than a screenful, in a view
  or out of one. §12.71.9. `ViewBuilder` takes more than ten children — variadic generics
  since 5.9.
- `NSException` cannot be caught by Swift do/catch. Pre-flight Info.plist keys with
  `Bundle.main.object(forInfoDictionaryKey:)` — a missing `NSHealthShareUsageDescription`
  is a hard crash.
- Swift Charts: `AxisContent` cannot be an existential — return `some AxisContent` from a
  function, not a property typed as the bare protocol.
- `ProgressView` is SwiftUI's. The progress tab is `ProgressTabView`.
- `DayKey`'s formatters are `nonisolated(unsafe)` — never mutate them, add a new one.
- Dates are compared as `"yyyy-MM-dd"` strings, never as `Date`.

- **`./scripts/test.sh` reported nothing at all from 318 to 325** — it passed `-quiet`,
  which suppresses swift-testing's summary, and then printed advice about a count it had
  never seen. Fixed at 325b: no summary line now exits 1, and so does a run reporting
  under 500 tests. **A guard that cannot fail has not been tested** — the first time you
  install one, break something on purpose and watch it complain. §12.69.
- **`error: unexpected variant during dependency scanning on module 'X'`** is a poisoned
  module cache, not your code. Xcode.app and command-line `xcodebuild` share
  `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex` and disagree on
  `-fmessage-length`, which is part of the module context hash — so alternating ⌘R and
  `./scripts/test.sh` can leave two PCM variants and the scanner refuses to choose.
  Cure: `rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`. Same family as
  the rule above: two front-ends, one DerivedData.

**Searching this codebase:**

- Sweep the **bare identifier, then filter**. `\.rejected\b` finds reads and misses
  `rejected = []`.
- **Changing a type's shape means grepping `Sub4CoreTests/` too, before the build.**
  Four instances: 315 (a function gained a parameter), 317b (an array gained an element),
  327a (a fix-up reworded a printed string while rebuilding the function around it).
  **A fix-up is a patch** — 327a followed this rule when 327 was written and skipped it
  when fixing 327.
  Both times `Sub4/*.swift` was swept and the test target was not. The three shapes that
  carry assertions elsewhere are **a function's arity, an array's length, and a printed
  string's content**.
- **A grep tells you where a symbol appears, not what the line does with it.** 328 counted
  the copies of a rule from `grep isDone` output and treated one hit as a call site without
  opening it; it was a sixth copy, and a seventh only appeared under `grep isRest`. If the
  NUMBER of copies matters, open each one. §12.72.7.
- **Do not infer a type's name from its filename.** `ZoneTime.swift` declares `ZoneTotals`.
  Cost patch 316 a fix-up.
- **Read the view before naming a control.** The match picker has four entry points and
  three labels: "Fix match…" (Today), "Change match" (activity sheet), "Change" / "Match…"
  (session detail). "Fix match" is the sheet's navigation title, not a button.

**Two rules of argument, both bought with a patch:**

- **Do not reimplement a rule; call it** (§12.43). Eleven applications: `isKept`/`dedup`
  (310), `byDay` (312), `recordedByWeek` (313), `LoadSeries.build` (314), `MatchResolver`
  (321), `PlanRepository.activeVersion` (326), `changeSummary` (327), `SessionTally` (328).
  *A derivation with one caller looks like part of that caller. It stops being that the
  moment something else must agree with it.* **328 is the worst instance so far**: five
  copies of "done of total", four counting optional sessions and one not, disagreeing on
  two tabs for 230 patches. A rule copied five times is not five checks — it is five
  chances to drift, and patch 98 fixed one of them.
- **Do not reason by analogy about two numbers without checking whether one determines the
  other** (§12.60.1). Patch 316 argued that two heart-rate distributions could integrate to
  the same TRIMP. They cannot — both come from one walk over one set of bins, and the
  histogram determines the TRIMP. The argument was rewritten rather than the patch dropped.

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

**Never run `xcodebuild test` while Xcode is building.** They share DerivedData and the
collision surfaces as `invalid reuse after initialization failure` on files that are fine.

**CI is not a check.** The GitHub account is free (2,000 Actions minutes/month) and the
allowance is spent. Exhaustion looks like an instant 2–4 s failure of *every* job with the
annotation about payments / spending limit — that is billing, not code. **It resets
2026-09-01.** Until then, local verification is the source of truth. Never say
"once CI is green" and never treat a push as a check. See `docs/context/ci-budget.md`.

**Simulator cannot answer everything.** Six of eleven Phase 2 defects were hardware-only.
Anything about real activity data, HealthKit, Keychain, or on-device row counts needs the
phone — and Bruno's eyes, because **the app logs nothing at all**. Ask him to look; do not
infer from a green suite. When you ask, give **numbered navigation and a row-by-row table
of what each figure should read**, including what a failure would look like. "Check the
Database screen" has been rejected as too thin twice.

**Xcode, the hard-won bits:**

- Open **`Sub4.xcodeproj`** (at the repo root), not the `Sub4/` source folder. Cost time twice.
- **Never use Xcode's "Add Files".** Xcode 16+ uses synchronized folders — a new file
  written into `Sub4/` appears in the target automatically. Add Files creates a
  second reference → `Models 2.swift` → invalid redeclaration. Wrecked the project twice.
  This is a real advantage now: you can add Swift files with `Write` and never touch
  `project.pbxproj`.
- **A NEW file needs ⌘Q and a reopen before the app target sees it.** The test target picks
  new files up without one; the app target does not. Patch 317 lost a build to this — forty
  errors, all `cannot find 'AthleteRepository' in scope`.
- **Nothing that is not Swift source goes under `Sub4/Sub4/`.** Docs go to `docs/`,
  scripts to `scripts/`.
- GRDB **7.11.1**, pinned Exact Version, revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
  Product `GRDB` (static) on the `Sub4` target only; `GRDB-dynamic` deliberately not linked.
  Tests reach it via `@testable import Sub4`. Xcode's Exact Version field pre-fills `1.0.0`
  (a 2017 tag Swift 6.3 refuses) — type the version and press **Tab**, not Return.
- SwiftUI Preview canvas errors are cosmetic and never block ⌘R.
- Free Personal Team: HealthKit **is** allowed. Push/iCloud/App Groups are gated. €99 buys
  relief from the 7-day provisioning expiry and nothing else that matters here.
  Provisioning expiry means the app stops launching until rebuilt from Xcode.

**`AppVersion.swift` ships in every patch, without exception** — `patch` bumped and
`revision` nil for a numbered patch, `patch` unchanged and `revision` set to a lowercase
letter for a fix-up. The version is on the Settings screen and in the diagnostics paste, and
a stale reading there is how you find out a patch did not land.

---

## 4. Working with Bruno

Full version in `docs/context/working-agreement.md`. The short form:

- Ask a clarifying question **once**, then proceed. Never re-ask the same set.
- When he interrupts, **stop immediately** — first time, not the third.
- Do not assert facts derived from files you have not read **this session**. That includes
  this file.
- Direct and concise. No flattery, no padding. Push back when something is thin or wrong.
- **Never write police operational data anywhere near a cloud service.** Unrelated to this
  repo, but it is a standing rule and it does not have exceptions.

**Two surfaces work on this repo, and they ship differently.** Claude Code on the Mac edits
files in place and git is the undo. Cowork cannot write into the repo — it reads through the
device bridge and delivers **patch zips that Bruno unzips himself**, which is why patches
310–317 exist as zips and why `AppVersion.swift` rides in every one. Neither surface touches
git; Bruno commits.

---

## 5. State — patch 332, 2026-08-09

**The database ladder: D0–D5 complete. D6a complete. D6b complete. D6c COMPLETE — all eight
slices, at 330. D7 has not started, and nothing in the app reads the database yet.**

**Two sentences belong together in the D7 decision, and §12.75.8 states them:** D6c proves
the database can feed the app — every record round-trips and every derivation agrees from
either side. It does **not** prove the app is right; §12.72 found seven copies of one rule
disagreeing for 230 patches, and no slice could have caught it, because every slice compares
the app against the database and that was the app disagreeing with itself.

**That last clause is the whole of what is left, and it is worth restating because the
read-backs make it easy to forget.** All nine repositories are reachable only from
`DatabaseHealthView` and the parity types. `ActivityStore.load()` still opens
`activities.json`; so does every other store. D6c proves the data can be *reconstituted*;
it does not prove a store *fed from* the database would behave identically, and only
`ActivityStore` has the extracted-rules shape (`ActivityRoster`) that would make that
provable. Repointing each store's load path is the substance of D7 and is covered by no
slice completed so far.

- **Eleven migrations**, 51 tables, ~214,000 rows, ~37 MB on the phone. On the device:
  674 activities, 674 details, 649 recordings, ~194,000 trace samples, 7,986 splits,
  4,700 laps, 582 weather, 11 gear, 15 resting months, 5 HR zones, 7 notes,
  4 corrections, 3 rejections.
- **1005 tests in 92 suites** at 322b, plus `PlanRepository` (323) and
  `WeatherGearRepository` (324). The run prints the current total. 165 Swift files in
  `Sub4/`, ~60,000 lines.
- **`migration_run` reaches `verified`.** The semantic verifier compares per-table counts,
  sync state, identity, an activity fingerprint and the domain checks. **The number of
  comparisons is printed on the Database screen — it is not restated here**, because a
  second answer to a question the screen already answers is how §12.29's problem starts.

**D6a — seven repositories, every field compared.**
`ActivityRepository` (289), `ActivityDetailRepository` (291), `RecordingRepository` (294),
`AthleteRepository` (317), `AuthoredRepository` (322), `PlanRepository` (323),
`WeatherGearRepository` (324), `PlanExtrasRepository` (326), `ReviewRepository` (327). Each returns a load type that distinguishes *nothing there*
from *could not look* — §12.15, twelve instances, and 323's has four shapes rather than
three because "stored but not activated" and "two plans both active" are states the schema
permits and nothing else could name.

**D6b — write-through (302–307).** Every path that writes a store now reaches the database.
**Its boundary, learned at 325:** gear distance is not a store write — it is a refresh from
Strava's athlete endpoint — so it was never in D6b's scope, and the value sat frozen at
first import until 324's read-back found it. The boundary of a completeness claim is the
thing worth writing down, because everything outside it looks finished from inside.

**D6c — shadow parity.** Slice order is in `docs/D6C-SHADOW-PARITY-GROUNDWORK.md` §6.

| slice | what | patch |
|---|---|---|
| 1 activities — identity, order, days | `ActivityParity` | 312 ✔ |
| 2 daily and weekly volume | `VolumeParity` | 313 ✔ |
| 3 fitness and load, incl. the HR histogram | `LoadParity` | 314–316 ✔ |
| 4 details, splits, laps, reps | `DetailParity` | 320 ✔ |
| 5 plan matching | `MatchResolver` + `MatchParity` | 321 ✔ |
| 5b notes and corrections | `AuthoredRepository` + `AuthoredRoundTrip` | 322 ✔ |
| 6 zones, weather, gear | `AthleteRoundTrip` (317) + `WeatherGearRepository` | 324 ✔ |
| 6b the plan — weeks, sessions, breakdowns, blocks | `PlanRepository` + `PlanRoundTrip` | 323 ✔ |
| 6c the plan's trimmings — exercises, fuel, warm-up | `PlanExtrasRepository` | 326 ✔ |
| 7 review payloads | `ReviewRepository` + `ReviewRoundTrip` | 327 ✔ |
| 8 Today / Week / Plan / Progress summaries | `SessionTally` 328 + `TabSummary` 329 + `SummaryParity` | 330 ✔ |

**9 AUGUST: THE PHONE WAS WIPED.** The app was deleted by hand during the 330b crash loop,
which took every JSON store with it. Recovered from Strava: 674 activities, 586 weather
readings, 11 gear. **Gone for good:** 7 session notes with their sRPEs (`notes.json`) and
4 commute decisions (`commutes.json`, which is what fills the `correction` table — the
`DataCorrections` overrides are source and survived). Also gone: the eleven review
rehearsal records, which had to be deleted before 24 August anyway. **The first protected
snapshot in this project's history was taken at 09:39 UTC on 9 August** — 67 of 67 files,
zero failures, `2026-08-09-083914`. D0 contract item 3 had been open since patch 246.

**The detail backfill is a two-day job and that is Strava's ceiling, not ours.**
`DetailStore` drains 30 activities per sync at up to two requests each; Strava allows
**100 reads per 15 minutes and 1,000 per day**, windows resetting at :00/:15/:30/:45 and
the day at midnight UTC. ~1,180 requests are needed. A bigger batch would mean fewer
presses, not more activities per day. **Do not read shadow parity as a verdict until
`Still to fetch` reaches zero** — the detail and recording slices will report gaps that
are the drain. §12.77.

**Slice 8's code was right at 330a and the SCREEN was not.** 330, 330b and 330c are three
consecutive fix-ups on one patch, two of them shipped on a wrong diagnosis, and the
Database tab could not be opened in between. Nothing about the comparison changed; the
crash was `DatabaseHealthView`'s own size. 330c moved the six parity sections into
`Sub4/ShadowParitySections.swift` and grouped the rest. **No test in this project can see
a stack overflow** — 1136 were green through all three. §12.76.

**328 is slice 8's extraction, shipped alone because it CHANGES WHAT TWO TABS PRINT.**
"Done of total" had **seven** implementations; six counted the plan's 30 optional Zwift
rides and one did not, so the Week tab and the Progress tab printed different denominators
for the same week — since patch 98, which fixed one site of seven. `SessionTally` is now
the only copy. **Verified on the device:** week 2 reads 6/7 on Week, Plan and Progress
(three screens that had not agreed before), week 1 stays 4/4, the block total is 10/208 =
238 − 30. §12.72.

**328 found five of the seven and the device found the other two**, because the campaign
predicted a NUMBER — adherence 236 → ~206 — and the screen read 236. `MatchParity` had its
own loop whose comment described a delegation it did not perform, and `Review.swift`'s
`countable` is what the MODEL is told each month: left alone it would have reported "6 of 8"
for a week the athlete's screens call "6 of 7", live on 24 August. Both fixed at 328a.

**No D6c slice could have found this**, and that bounds what D6c is evidence of: shadow
parity proves the database can feed the app, and says nothing about whether the app is
right. Slice 8's comparison is patch 329.

**Slice 7 was verified on the device on 8 August, earlier than expected.** The rehearsal
button was pressed about eleven times, and the import reported `Reviews: 5 new, 6 refreshed`
— eleven records where one was expected. The read-back: **56 compared · 3 differences**,
`11 vs 8` reviews, 224 field comparisons with **zero** differences, **16 of 16** changes
resolving against 260 plan uids, and the only red row being *App records sharing a run
time: 3*. Every denominator is an exact product — 8×5, 8×4, 8×5, 16×6.

**It found a real identity mismatch** — see §12.71.12. The app keys a review by
`Record.id` (window + run count); the database keys it by `(accountID, ranUTC)` at
**one-second** resolution, with no unique constraint behind it. Eleven records became eight
rows, silently on the writing side; `duplicateRunTimes` is the only thing in the app that
noticed. **Asked and answered on 8 August: record it, do not fix it** — unreachable outside
the internal-build rehearsal button, and D7 is the next rung. It becomes a defect rather
than a note if a second writer of `review` appears.

**The eleven rehearsal records must be deleted before 24 August**, or `ReviewDue` pushes
the first real review to 21 September.

**The slice still has no evidence from a REAL review, and cannot before
24 August 2026.** `ReviewDue.state()` needs four finished plan weeks; the first review is
due Monday 24 August. Until then `ProposalStore` holds nothing or the rehearsal record,
the six review tables hold nothing or one synthetic tree, and the read-back's correct
output is *"no review stored yet · first due 24 Aug 2026"* — green, because both sides are
empty. Its 23 tests are the only evidence the reader works. Two findings it surfaced stay
open: **nothing writes `review_evidence_source`**, so ADR-0002's lineage purge has no rows
to query (§12.71.3); and **`confidence` has two live contracts** — the type says 1–5, the
column's CHECK says 0–100, and 70 has been written since patch 225 (§12.71.4).

**On the device, every slice run so far is clean.** 674 activities · 324 days · no
differences; 403 vs 403 load days, 222 vs 222 traces, 7,112 heart-rate buckets, Fitness
33 vs 33; athlete 27 compared, 0 differences, HR max 181 vs 181, FTP 270 vs 270; 674
details with 8,088 pace figures (6,562 answered), 7,986 splits, 4,700 laps, 1,141 reps,
all zero; 518 days matched, 252 sessions, 10 matched and 664 extras — and
`extras + matches = 674` exactly — with adherence 10 of 236 on both sides. **Slice 5b
(322) has not been verified on the device yet.**

**`LoadParity` now verifies sRPE outright** and `MatchParity` verifies the plan — both
lines shortened at 323 because `plan_session` is read back. The match decisions are the
only held input still uncorroborated, and `match_decision` holding zero rows is why.

**The approved-difference list has exactly five entries** — `AthleteConstants.version`
(317), a local cache counter with no column; `user_note.activityID` and
`user_note.planVersionID` (322), two columns the writer has never populated; and
`Shoe.primary` and `gear.retiredUTC` (324), the only two that are structural rather than
a value left NULL. A test pins each count. An entry nobody can justify is a bug that has
been given a hiding place — and **an entry nothing exercises is a suppression nobody has
checked**, which 324 tests for the first time. 317's and 322's entries still have no such
test.

### Still open, and the first one is Bruno's call

> **THE MATCH PICKER OFFERS ACTIVITIES THE MATCHER WILL REFUSE.** Confirmed on device
> 2026-08-05 22:00, still open at 322a. `MatchPickerView.choiceSection` lists
> `activities(on: dayKey)` unfiltered; `Matcher.resolve` builds its pool from
> `all.filter(\.isPlanEligible)`, and `Activity.isPlanEligible` returns `false` by
> `default:` — so a walk is never eligible. Choosing the walk stores the override, the
> matcher cannot find it, and the session falls through to the same branch as "explicitly
> nothing". Week showed *Not done*, Sessions went 4/4 → 3/4, nothing on screen said why.
> Worse since 272: the import *does* write the row, so the store, `match_decision` and the
> screen disagree — and the verifier cannot see it, because it counts rows and the count
> is right.
>
> **Two fixes and the decision is Bruno's, not yours:**
> (a) the picker lists only plan-eligible activities, extras greyed with a reason;
> (b) an explicit override wins over `isPlanEligible` — which is patch 251's own argument,
> three lines above the walk case: *"the athlete's answer has to be able to win in BOTH
> directions."* (b) has consequences: the walk's distance and load would enter that
> session's adherence and effort figures.
> **Ask, then implement. Do not pick.**
>
> **321 asserted it as it behaves today.** `MatchResolverTests`
> `.anOverrideNamingAnIneligibleActivityIsLost` states the defect in a test, so the day it
> is fixed the test inverts rather than the change going unnoticed. The decision is still
> Bruno's.

- ~~Background refresh has never fired.~~ **Closed.** `backgroundRefresh: 1` appeared in
  the ledger during the 320 device run. Patch 307's path works; iOS had simply never woken
  the app. Open from 311 to 320 on evidence that was an absence, which is §12.54.2's
  shape.
- **`Interrupted runs: 1`** as of 331, from that morning's ⌘R cycles. Should not climb on a
  day with no rebuilds.
- **`Sub4/manual.html` is 38 patches stale** — last touched at 284, and it has zero
  mentions of the Database screen, shadow parity, write-through, GRDB or migrations. It is
  a *user* document and §11 "Where the data lives" is the part that will be wrong; deferred
  until D7 settles that answer rather than writing it twice.
- **`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` is untouched since the baseline**
  (3 August). Deferred until the D-ladder finishes, for the same reason.
- `review_evidence_source` — **nothing writes it**, so ADR-0002's lineage purge has no rows
  to query (§12.71.3). Confirmed on the device at 327b: `0 — nothing writes this table`.
  Separately, the proposals import stays unverified against a REAL review until
  **24 August 2026**.
- **Two identities for one review** (§12.71.12) — `Record.id` vs `(accountID, ranUTC)` at
  one-second resolution, no unique constraint. Eleven rehearsal records became eight rows.
  **Decided 8 August: recorded, not fixed.** Revisit if `review` gains a second writer.
- **`confidence` has two live contracts** (§12.71.4) — the type says 1–5, the column's
  CHECK says 0–100, and 70 has been written since patch 225. The device reads `3`.
- `content_revision` — **probably has no correct occupant** among the preference keys. Its
  real first occupant is likely the plan's content hash. Settle before building.
- `lateArrivals` has been computed since patch 45 and is displayed nowhere.
- ~~**The protected snapshot goes stale.**~~ **Closed 9 August** — and closed the hard way.
  The button shipped at 247 and had never been pressed, so a hand-delete of the app took
  every store AND the thing that would have protected them. The phone now holds
  `2026-08-09-083914`, 67 of 67 files. **Take a second one when `Still to fetch` reaches
  zero**, because the current copy holds 33 of ~674 details. §12.78.
- **`ActivityStore.load()` still has the two-`try?` shape** patch 273 fixed on the four
  authored stores. Left deliberately: it is a cache and re-fetchable.
- **STRAVA IS BEING SWITCHED OFF.** Once the database holds everything, the import stops
  and the same data arrives from Apple Health and Workout data — ADR-0002's Phase 4A, and
  the athlete's stated intent as of 325. Two consequences that change how patches are
  judged: **a cache that stops being refreshed is harmless until it becomes the only
  copy**, so any importer-fed column freezing an old value is a permanent loss with a
  date on it; and **any rule built on a Strava-only signal has a shelf life shorter than
  the patch that writes it** — which is why `gear.retiredUTC` stays unwritten (§12.68.4).
- **2026-09-01 — GitHub Actions allowance resets.**

**329 landed the extraction.** `TabSummary` holds `weekPoints`, `actualVolume` and
`weekActuals`; `PlanStore.plannedRunKm`, `plannedVolume`, `sessions(inWeek:)` and
`accumulate` gained static forms taking their inputs, with the instance methods as
one-line wrappers. Behaviour-neutral. **`todayKey` is a parameter** — groundwork §7's
cutoff, and the hinge the whole slice turns on. §12.73.

**330 closed slice 8, and D6c with it.** `SummaryParity` compares the Progress chart's week
points, the four volume rows and the block tally. **It is the only slice that reads the plan
from the database** — every other one holds it from the app and lets `PlanRoundTrip` verify
it — so it holds only the match decisions, which makes it the closest thing on that screen
to what D7 does. §12.75.

**331 and 332 are the backfill's tooling, not the ladder.** 331 pulled the trace account out
from behind `if let importReport` so `Still to fetch` is readable without pressing Import,
and drew every row unconditionally — §12.77. 332 added **Share diagnostics** beside Copy:
same text, written to `sub4-diagnostics-<day>-p<patch>.txt` and handed to the existing
`ShareSheet`, so it AirDrops to the Mac and the capture names its own build — §12.79.
Neither touches the database.

**Next:** D7. Before it is pressed, two things that are not slices: fold the nine read-backs
into one roll-up with a durable result, and refresh the protected snapshot. Then D7 activate, D8, and 4A. Before D7 is pressed,
two things that are not slices: fold the nine read-backs into one roll-up with a durable
result — §12.57 corrected `@State`-evaporation for `ShadowParity` and never for the
read-backs, and nine buttons that must each be pressed is not a gate anybody can lean on —
and refresh the protected snapshot, which is still `2026-08-05-202320` from patch 279.
Then D7 activate — `Sub4Launch.migrationFailureBlocksTheApp` flips to `true`. Then D8,
stabilise one release window and remove the JSON writers. Phase 4A (Apple Health canonical)
cannot start before D7's exit gate.

---

## 6. What this project keeps re-learning

- **Real data beats tests.** The ghost review was found by reading table counts after a run
  that passed 15 comparisons. `work_queue` wrote 2 rows where 23 were predicted.
- **Read the code that produces the number, not the numbers either side of it.**
- A test that keeps passing can stop describing the system.
- A warning-shaped defect needs a test.
- **A diagnostic that cannot say why it has no answer will be read as having one**
  (§12.15). Thirteen instances — and at 327b the first one wearing a NUMBER rather than a
  sentence: a count that could not tell "the question could not be asked" from "the answer
  was wrong" reported a missing plan as a model inventing sessions. **Could not be checked
  is not the same as failed.**
- **A row that vanishes at zero cannot be told from a row nobody wired in** (§12.54.2).
  A count beside its denominator is evidence; a bare zero is noise; a missing zero is
  nothing. Every diagnostic line is unconditional.
- **A comparison must have a real way to fail.** Zero compared to zero agrees perfectly and
  proves nothing, which is why every parity report carries a denominator and a negative
  control.
- **A method written in anticipation is not a feature.** `ProposalStore.remove` waited 45
  patches for a caller.
- **An account beats a list.** Five counters can each be right while the set is missing a
  case; a residual cannot hide one.
- Six controls have been found reporting work they did not do.
- **A step that can be skipped without symptom will be** (§12.59.6). The `apply-NNN.py`
  script was dropped from patches at 315 for exactly this: twice it was not run and nothing
  showed, because its only remaining job was the ADR.

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

**Every one of those carries a date, and most are from late July.** They are a map, not the
territory — verify a number against the code before building on it.

Other documents worth knowing exist: `docs/D6A-DETAIL-GROUNDWORK.md`,
`docs/D6A-RECORDING-GROUNDWORK.md`, `docs/D6B-WRITE-THROUGH-GROUNDWORK.md`,
`docs/D6C-SHADOW-PARITY-GROUNDWORK.md` (read §6 before any D6c slice),
`docs/D6C-SLICE-8-GROUNDWORK.md` (read before slice 8),
`docs/PLAN-cutover-v2.md` (the ladder and the calendar constraint),
`docs/ADR-0001-product-definition.md`, `docs/ADR-0002-strava-retirement.md`.

`docs/SWITCHOVER.md` records how this repo moved from Cowork to Claude Code and what
changed. Read once, then it is history.
