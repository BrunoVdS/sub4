# Sub4 — Operation Sub-4 iOS training app

Personal single-user iOS app for Bruno's Operation Sub-4 marathon plan
(34 weeks, restart Mon 2026-07-27 → marathon Sun 2027-03-21, target 4:00:00 / 5:41 per km).

This file is what you read first, every session. It is deliberately short.
The detail lives in `docs/` — the index is at the bottom.

**Current at patch 384 (2026-08-16).** 384 is documentation only — it changes no
behaviour, so every fact about the app in §5 is the state proved on the device at 383.

**§5 IS THIS PROJECT'S ONLY STATEMENT OF CURRENT STATE.** Every other document
either points at it or is dated history. That rule exists because the opposite
kept happening: patch 318 installed this file describing patch 278c, forty
patches behind, and by 383 it was describing 343 while `README.md` said 332 and
the master plan's baseline said 334 — four documents, four different answers to
one question.

**And it is now checked.** `scripts/check-invariants.py` RULE 6 reads
`Sub4/AppVersion.swift` and fails the build if this file, §5 or `README.md`
names a patch more than twelve behind it. A stale state document is no longer
something somebody has to notice.

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

**Where each kind of answer lives, and there is one place for each:**

| question | document |
|---|---|
| what is true right now | **§5 of this file** |
| why a decision was taken | `docs/ADR-0003-database-contract.md` §12 |
| what happened on a given day | `git log`, and the handoffs |
| where the work is going | `docs/PLAN-codebase-modernization-and-feature-delivery.md` |

**The handoffs are history, not state.** `HANDOFF-2026-08-05.md`,
`HANDOFF-2026-08-05-late.md`, `HANDOFF-2026-08-06.md` and `HANDOFF-2026-08-16.md`
were snapshots and every one of them is behind. Read one only to understand how
something got the way it is. ADR §12 supersedes all four.

**The `docs/context/` files are dated exports and several are months behind.**
Their index says so per file. `sub4-database.md` is the one to be careful with:
its rules are still good and its state section stopped at patch 319.

**`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` is a review of patch 338,
not the present, whatever its filename says.** It sits at the repository root
beside `README.md` and it is the easiest document here to mistake for current —
384 banner-marked it for that reason. Its device audit, its information-identity
argument (ADR §12.86 draws the same line) and its separation of the database gate
from the Strava gate all still stand; its "not yet running from the database"
stopped being true at 342. Rename it `docs/REVIEW-2026-08-10-…` when convenient.

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
- **A count derived from a cache answers a question about the cache** (§12.81.4). Both of
  333's defects were this. `DetailStore.pending` is not persisted and is rebuilt only at the
  end of a sync, so `backfillRemaining = pending.count` read **0 on a fresh launch with 475
  traces outstanding** — and `Fetch now` greyed itself out. A report's `lookedAtSomething`
  answers *did this compare anything*; a load's `isTrustworthy` answers *did the read
  happen* — passing the first where the second belonged reported "could not look" over a
  database that had been read perfectly and simply held nothing. Both were correct
  properties read for the wrong question. **Derive a backlog from the predicate, not from
  the work list.** §12.81.
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
  Both times `Sub4/*.swift` was swept and the test target was not. The shapes that carry
  assertions elsewhere are **a function's arity, an array's length, a printed string's
  content — and a type's NAME**. 335 grepped for the first three and declared
  `ReviewLineageTests`, which `DomainSchemaTests` had used since the schema was written:
  `invalid redeclaration`, and a fix-up. Grep the name you are about to declare, not only
  the names you are about to change.
  **A sixth shape, from 350a: a DEFAULT ARGUMENT.**
  `WorkoutParser.coverage(_ store: PlanStore = .shared)`. Patch 346a converted
  `PlanCoverageTests` off the singleton by sweeping for the literal
  `PlanStore.shared`, and five call sites in that same file kept reading it
  through the default — each one on the line after a `#require` that decoded the
  bundle. It passed for four patches because both plans held 103 run sessions,
  and failed the day a plan revision made it 105. **A default argument is a call
  site that carries a value the caller never writes**, so no grep for the value
  finds it: grep the FUNCTION's name too, and read each hit's signature. §12.95.4.
  **A fifth shape, from 337: a value a FIXTURE DERIVES rather than states.**
  `ReviewRepositoryTests.record()` built its `id` from the window days, so the moment the
  id became the pairing key, the test that changes `endDay` to provoke a field difference
  was changing the key instead. Invisible to a grep for the field's name, because the
  field's name does not appear. §12.85.7.
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

**Four bought on 16 August, over the B3 slice:**

- **The patch before a flip is the one that asks what the flip is about to make
  vacuous.** 381 exists because switching `ActivityStore` to the database would have made
  shadow parity compare the database with itself — agreeing perfectly, proving nothing, and
  saying so nowhere, because two sides agreeing is what a pass looks like. §12.125.
- **A grep piped through `head` is an enumeration with a silent cap on it.** It looks
  exactly like a complete answer. It hid a file from the B3 enumeration twice in one
  session, and both times `check-invariants.py` found what it had missed. §12.72.7's cousin.
- **When a patch adds a line to any `diagnosticLines`, grep `Sub4CoreTests/` for
  `.count ==` BEFORE the build.** Seven such pins exist; three are literals. §12.125.7.
- **A sentence about what a store currently HOLDS cannot be a constant.** `"none —
  match_decision holds no rows"` was true at 330 and false from 358, printed unchanged
  until 383. The same shape at 356 and 381: a value describing the world, stored as though
  it described the code. Derive it from the counts and keep the constant as the default
  that announces a caller nobody updated. §12.127.5.

---

## 3. Build, test, run

**The suite is the gate, and it is fast.** 1,614 tests in 148 suites, well under a second
at patch 383. The run prints the current total; this figure is here for the order of
magnitude, and `test.sh` fails below 500 for the same reason.

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

## 5. State — patch 384, 2026-08-16

**THE ONE PLACE THIS PROJECT SAYS WHAT IS TRUE NOW.** 384 is a documentation
patch and changes no behaviour; everything below is the app as it stood at 383,
read off the device on 16 August. Anything older than
this section is history and lives in ADR §12; if a number here disagrees with
the code, the code wins and this section is the defect.

### 5.1 Where the ladder is

| stage | state |
|---|---|
| D0–D5 | complete |
| D6a, D6b, D6c (all eight slices) | complete |
| **D7 B0** — `PersistenceMode`, one authority | done, 342 |
| **D7 B1** — the plan, the athlete, the constants | done, 344–346 |
| **D7 B2** — notes, commutes, match decisions, plan moves | done, 355–358 and 377 |
| **D7 B3** — the activities | **done, 379–383** |
| D7 B4 — details, traces | not started |
| D7 B5 — weather, gear | not started |
| D7 B6 — derived metrics | not started |
| D7 B7 — reviews | not started, and blocked until a real review exists |
| D7 B8 — sync cursor, work queue, rejections, revisions | not started |
| D7 B9 — activate, fail closed | not started |
| D8 — retire the JSON writers | not started |

### 5.2 What the app reads from the database today

Eight lines in the diagnostics paste say it, and they are the fact to check
first when a screen looks wrong:

- **the database**: the plan and its trimmings, the constants, the athlete's
  zones and FTP, the notes, the commute decisions, the match decisions, the
  plan moves, **and the activities**
- **the app's own files, still**: gear (B5), weather (B5), details and traces
  (B4), reviews and proposals (B7), the sync cursor, work queue and rejection
  receipts (B8, all `UserDefaults`)

`AthleteStore` is deliberately half-and-half and says so: `partial(fromDatabase:
"zones and FTP", fromFiles: "gear")`.

**Every JSON store is still written and still complete.** That is what makes any
slice reversible by deleting one family from `PersistenceAuthority.hydratedFamilies`,
and it is why hydration must never write.

### 5.3 The evidence, from the device at 383

Compare and the nine read-backs, 16 August:

- **six parity slices, zero differences**: 694 activities · 332 days; volume
  0 of 332 days and 0 of 284 week figures; load 412 days with fitness 35 vs 35
  and fatigue 47 vs 47; details 694 with 8,328 pace figures and 8,129 splits;
  matching 518 days, adherence 15 of 207 both sides; summaries 3 weeks and
  4 volume rows, block sessions 15 of 18 both sides
- **activity parity's app side is `activities.json`, read directly** — patch 381,
  so the comparison survived B3's flip instead of becoming the database agreeing
  with itself
- `Activities hydrated: 694 kept of 694 offered from the database` — settling the
  stored rows drops nothing
- nine read-backs, zero unexplained differences, all approved differences named

**What that does and does not prove.** It proves the app derives the same
answers from either side for everything the slices cover. It does not prove a
lossless round trip: gear classification and status, rejection and match-date
metadata, plan source and top-level order, and fractional fetch-time precision
are still outside the mapped set — §12.86 draws that line and it has not moved.

### 5.4 The verifier's accounting

`HydratedStores.all` holds **eight** entries: `heart-rate zones` (B1), `notes`,
`commute corrections`, `match decisions`, `session moves` (B2), and `activities`,
`activity identities`, `volume by discipline` (B3). Each names a comparison whose
expectation now comes from a store the database feeds, so each is the database
agreeing with itself.

**`runs ever verified: 12`, the newest at patch 368 — and none since the flip.**
The independent count in that row is 18 and is expected to fall by three the next
time Verify runs. Until it does, no verified run exists over the current data,
which is D7's own exit criterion and step 5 of §5.6.

### 5.5 Open, and the first one is Bruno's call

> **THE MATCH PICKER OFFERS ACTIVITIES THE MATCHER WILL REFUSE.** Confirmed on
> device 2026-08-05 and still open. `MatchPickerView.choiceSection` lists
> `activities(on: dayKey)` unfiltered; `Matcher.resolve` builds its pool from
> `all.filter(\.isPlanEligible)` and a walk is never eligible, so choosing one
> stores an override the matcher cannot find and the session reads *Not done*
> with nothing on screen saying why. **Two fixes and the decision is yours:**
> (a) the picker lists only eligible activities, extras greyed with a reason;
> (b) an explicit override wins over `isPlanEligible`, which is patch 251's own
> argument — and would let that walk's distance and load into the session's
> figures. `MatchResolverTests.anOverrideNamingAnIneligibleActivityIsLost`
> states the defect as a test, so the day it is fixed the test inverts.

- **Five authored stores have no restore path.** `notes.json`, the match
  decisions, `moves.json`, `commutes.json` and `proposals.json` cannot be put
  back if something destroys them. 372 stopped the mechanism that was destroying
  them; weather got a restore at 374 because its repository was finished and
  unused. **Largest open risk in the project.**
- **`newest removal` names the trigger and the count, not the family.** A
  breakdown needs a migration — a column or a `migration_run_removal` table.
  369's argument one level down.
- **`canReconcile` tests readable, not correct** (§12.120.3). A clean read of a
  wrong file goes through that gate; the 601 weather readings survived only
  because weather is not in `reconcileRequires`, and it is not in there for an
  unrelated reason.
- **The import no longer carries the file into the database for activities**
  (§12.126.5). `AppStores.gather` feeds `Sub4Import` from the hydrated store, so
  Import writes the database's own rows back. Idempotent and harmless; not a
  repair path. `resetCache` and a re-sync are.
- **`LoadParity`'s app side is `LoadStore`**, which derives from the hydrated
  store, so slice 3 compares a database-derived app side after the flip. Slices
  1, 2, 5 and 8 were rescued at 381; this one cannot be without comparing
  something no screen shows. §12.125.4.
- **`ReadBacks.knownActivityIDs` is B5's**, under the rule 381 made general: a
  read-back gets its own read in the slice that hydrates its own store.
- **The protected snapshot is `2026-08-10-084723`**, taken by patch 340 — before
  the flip. It holds `preferences.plist`, which is what 338 fixed, and it now
  protects files the app no longer reads for activities. A fresh capture is
  step 1 below.
- **`Sub4/manual.html` is a hundred patches stale** — last touched at 284. It is
  a *user* document and §11 "Where the data lives" is the part that is wrong;
  deferred until D7 settles that answer rather than writing it twice.
- **Two stores remain unprotected** by §12.116's guard: `AthleteStore` and
  `AthleteConstants`, both the milder `guard … else { return }` shape, both
  re-fetchable, both hydrated at B1. `UNPROTECTED_STORE_CEILING` is 2 and may
  only go down.
- **`content_revision` is reserved and unoccupied**, decided at 334: its real
  subject is per-activity hashes so a re-sync can skip unchanged rows, and the
  last full import of 694 took 1.1 s. Revisit when that is slow enough to matter.
- **Dates:** first real monthly review **24 August 2026**; GitHub Actions
  allowance resets **1 September 2026**; Japan **7–12 September**, the first time
  `DayKey.key(_:in:)` runs outside Europe/Brussels — exercise it before flying.

### 5.6 Next, in order

1. **A fresh protected snapshot**, post-383 and preferences-inclusive. The
   current one predates the flip.
2. **Press the read-back roll-up** and get `provesSomething`, not merely
   healthy — it needs every read-back to have looked at something.
3. **Import once, then Verify immediately.** This is the first verification over
   data the database feeds. Watch the ledger row beside the verdict, and expect
   `independent` to fall by three.
4. **B4 — details and traces.** The 1.5-million-sample read stays off the main
   actor; the read-back keeps its own read, per 381's rule.
5. **B5 — weather and gear**, including `ReadBacks.knownActivityIDs` and the
   `WeatherGearRoundTrip` read-back's own read.
6. **B6, B7, B8, then B9** — activate, `activateVerified` called for the first
   time, `migrationFailureBlocksTheApp` flipped to `true`, and the fail-closed
   recovery screen `RootView` does not yet have.
7. **D8** — stabilise one release window, then remove the JSON writers.

Phase 4A (Apple Health canonical) cannot start before D7's exit gate — see
`docs/context/review-data-pool.md` and `docs/ADR-0002-strava-retirement.md`.

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
- **A count derived from the thing it counts never needs chasing.** Paid for at 369a, 372,
  377, 377d, 381a and 383; RULE 5 and RULE 6 are what that lesson looks like as code.
- **A document that names itself CURRENT is a claim with nothing holding it up.**
  `SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` sat at the repository root for
  46 patches saying *Status: active* and *not yet running from the database*, and it
  was found by listing the root directory — not by anybody remembering it. **Enumerate
  the tree when you audit documentation; the stale document is the one nobody names.**
  §12.128.1.
- **Two patches must never share a delivery filename.** On 16 August the flip and the patch
  meant to precede it were both delivered as `sub4-patch-382.zip`; the one already in
  Downloads won, and the flip went in a patch early. Nothing broke — the tree stayed
  self-consistent and the device proved the flip — but the ordering that had been argued
  for was spent by a file name. §12.127.

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
territory — verify a number against the code before building on it. `docs/context/README.md`
gives the date of each.

**None of them states current state, and `sub4-database.md` is the one to watch**: its rules
are still the best short account of the persistence work, and its "Where it stands" section
stopped at patch 319 and is now marked as history. §5 of this file is the only current
answer; RULE 6 in `check-invariants.py` is what keeps it that way.

Other documents worth knowing exist: `docs/D6A-DETAIL-GROUNDWORK.md`,
`docs/D6A-RECORDING-GROUNDWORK.md`, `docs/D6B-WRITE-THROUGH-GROUNDWORK.md`,
`docs/D6C-SHADOW-PARITY-GROUNDWORK.md` (read §6 before any D6c slice),
`docs/D6C-SLICE-8-GROUNDWORK.md` (read before slice 8),
`docs/PLAN-cutover-v2.md` (the ladder and the calendar constraint),
`docs/ADR-0001-product-definition.md`, `docs/ADR-0002-strava-retirement.md`.

`docs/SWITCHOVER.md` records how this repo moved from Cowork to Claude Code and what
changed. Read once, then it is history.
