# Sub4 — Operation Sub-4 iOS training app

Personal single-user iOS app for Bruno's Operation Sub-4 marathon plan
(34 weeks, restart Mon 2026-07-27 → marathon Sun 2027-03-21, target 4:00:00 / 5:41 per km).

This file is what you read first, every session. It is deliberately short.
The detail lives in `docs/` — the index is at the bottom.

**Current at patch 424 (2026-08-20).** §5.3 is the 390 device run, Compare and
the roll-up together; §5.4 and §5.4a are the verifier's and the roll-up's
accountings, both derived; §5.5's first bullet is the last read-back still
comparing the database with itself. **BOTH device campaigns ran on 19 August** —
409's sixteen of sixteen and 1A's twelve of twelve; §5.3a. **1A closes**, and
its run found a blind file tally that is B4's, not 1A's — §5.5.

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
- **`Built` READS EARLIER THAN THE BUTTON YOU JUST PRESSED, AND IT IS NOT
  STALE.** `AppVersion.built` is the executable's modification date — its link
  time — and **`scripts/preflight.sh` builds `-configuration Release` into the
  same shared DerivedData Xcode uses.** So after any preflight run, ⌘R in
  Release finds the products up to date, links nothing, and installs
  **preflight's** binary. Measured 20 August: Release linked 23:04:01 by
  preflight, Debug linked 23:06:08 by Xcode, and a ⌘R at 23:20 moved neither.
  **The gate is `Configuration`, which is a `#if DEBUG` literal and cannot be
  wrong; `Built` is identity, not proof of a fresh link.** Same DerivedData
  sharing as the module-cache rule below, different symptom. To force a real
  relink: `touch Sub4/AppVersion.swift`, or Product → Clean Build Folder.
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
  **AND THAT RULE IS ONE WORD SHORT — 386a.** A name can be taken by **a module the
  target imports**, and no grep of this tree can see it. 386 declared
  `Expectation`; `Testing.Expectation` exists, and every one of the 124 test files
  does `import Testing` beside `@testable import Sub4`, so the bare noun was
  ambiguous in all of them. The app target built and the test target did not.
  **The more ordinary the word, the more likely a framework owns it** — prefer a
  project-specific prefix for any type a test file will name. §12.130.6.
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

**And one bought on 19 August, over the authored writes:**

- **WHERE A FAMILY'S PRUNE LIVES IS NOT A DETAIL.** `importNotes` reconciles
  nowhere — the notes' removal pass is in `reconcileAuthored` — so handing it one
  note moves one row, and 408 was safe by accident of layout.
  **`importCorrections` and `importMoves` prune INSIDE themselves**, from a
  keep-set built out of the array they are handed, so handing either ONE record
  with `reconcile: .run` deletes every other row of that family — inside one
  transaction, from a function called "import", with no error. `.skipped(reason)`
  is the guard and the reason reaches the screen. **Read every importer you
  intend to call with one record**; the shape of the first one is not the shape
  of the rest. §12.156.1.
- **A GREP COUNTS APPEARANCES, NOT DECLARATIONS — AND A RULE CAN INHERIT THAT.**
  RULE 13's population test read raw text, so `ReadBacks` and `StoreReadJournal`
  joined it by MENTIONING `init(directory:)` in prose while `Matcher`, which
  declares `init(defaults:)`, was absent. The rule spent three patches examining
  two files with no seam and ignoring one that had one. **Strip comments before
  you decide what a file IS**, and when a rule's population is a shape, ask what
  other shapes are the same risk. §12.157.2.

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

**And one bought on 17 August, enumerating B4:**

- **A CATEGORY DEFINED AS "NOT THE OTHER ONE" WILL EVENTUALLY SWALLOW SOMETHING
  THAT IS NEITHER.** `independentChecks` was every comparison that was not
  self-referential, and `.databaseAlone` — a residual, reading no store — can
  never be self-referential by construction. So it was permanently *evidence*,
  `independentChecks.isEmpty` was unreachable, and `isTrustworthyEvidence`
  could not withhold anything at B9, which is the only place it was ever meant
  to fire. **Two properties had collapsed into one word**: *not
  self-referential* and *evidence about the app*. When a classification is a
  binary complement, ask what a third kind of member would do to it — and when
  you find one, give it a bucket and PRINT the bucket, because a category
  silently dropped from a total is §12.54.2 in the row that hides a gate.
  §12.132.

---

## 3. Build, test, run

**The suite is the gate, and it is fast.** 1,622 tests in 149 suites, well under a second
at patch 387. The run prints the current total; this figure is here for the order of
magnitude, and `test.sh` fails below 500 for the same reason.

```sh
./scripts/test.sh          # xcodebuild test on the simulator — run before every device build
./scripts/preflight.sh     # test + Release build; run before anything destructive
```

**Both fail on a compiler warning from `Sub4/` or `Sub4CoreTests/` since 403.**
One slipped past a green suite AND a successful Release build at 400a and was
found by eye in Xcode. `scripts/no-warnings.sh` reads each build's log, anchored
on PATH rather than on message wording, so a new tool's phrasing cannot reopen
the hole. Hard fail — the tree was at zero when it landed. §12.147.

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

## 5. State — patch 424, 2026-08-20

**THE ONE PLACE THIS PROJECT SAYS WHAT IS TRUE NOW.** Current at 424; §5.3 is
the device at 390, §5.4 the accounting that has been wrong twice. Anything older
is history and lives in ADR §12; if a number here disagrees with the code, the
code wins and this section is the defect.

### 5.1 Where the ladder is

| stage | state |
|---|---|
| D0–D5 | complete |
| D6a, D6b, D6c (all eight slices) | complete |
| **D7 B0** — `PersistenceMode`, one authority | done, 342 |
| **D7 B1** — the plan, the athlete, the constants | done, 344–346 |
| **D7 B2** — notes, commutes, match decisions, plan moves | done, 355–358 and 377 |
| **D7 B3** — the activities | **done, 379–383** |
| **D7 B4** — details, traces | **DONE, 388–398** — `D7-B4-GROUNDWORK.md`, §12.139–§12.142 |
| D7 B5 — weather, gear | not started |
| D7 B6 — derived metrics | not started |
| D7 B7 — reviews | not started, and blocked until a real review exists |
| D7 B8 — sync cursor, work queue, rejections, revisions | not started |
| D7 B9 — activate, fail closed | not started |
| D8 — retire the JSON writers | not started |

### 5.2 What the app reads from the database today

Ten lines in the paste say it — the first fact to check when a screen is wrong:

- **the database**: the plan and its trimmings, the constants, the athlete's
  zones and FTP, the notes, the commute decisions, the match decisions, the
  plan moves, the activities, **and the details and traces**
- **the app's own files**: gear and weather (B5), reviews (B7), the sync
  cursor, work queue and rejection receipts (B8, all `UserDefaults`).
  `AthleteStore` is half-and-half and says so.

**THE LAUNCH READS SEVEN AND 394 IS WHY IT IS NOT NINE.** 394 put both in the
bootstrap and measured **3.963 s in front of first paint**; 395 took them back
out, so the launch is 0.021 s and **`DetailStore` reads for itself when built** —
the one store here not constructed with `ContentView`. `hydratedFamilies` is
still the switch and the store is what consults it. §12.139, §12.142.

**Every JSON store is still written and still complete.** That is what makes a
slice reversible by deleting one family from `hydratedFamilies`, and why
hydration must never write — RULE 8 checks all eight `hydrate` bodies, because
no assertion in the suite can reach it.

**AND SINCE 410 THAT CLAIM IS MEASURED RATHER THAN ASSERTED.** `Detail and
trace files:` counts the directories on the hydrated path — a listing, never a
decode, so 394's 3.963 s does not come back — and says which of *decoded*,
*counted* or *nobody looked* produced the number. From **398 to 410 it read
`0 … all readable`** over files nobody had opened. **Device, 19 August: 698
detail files and 671 trace files, matching `activity_detail` and `recording`
exactly** — the mirror is complete and B4 is genuinely reversible. Cost:
`Detail store built: 1.127 s` against 409a's own 0.997 and 1.214 without it.
§12.155.

**AND SINCE 412 ALL FOUR AUTHORED STORES WRITE THE OTHER WAY ROUND.** Notes at
409, the commutes, plan moves and match decisions at 411–412. Each commits to
SQLite before it publishes and writes `notes.json` as a mirror afterwards. A
shut database is still not a refusal — the file takes it and the next import
catches up — so **`Notes reaching the database` prints unconditionally** in the
export from *The app's own files* (a paste line, **not a screen row**) — one
line naming any family that missed, §12.157.4. **`Matcher` cannot throw**, so
its refusal is a decision that does not stick rather than an alert. §12.153,
§12.157.

**409a MADE THAT LINE THREE-VALUED, AND WRITING THE CAMPAIGN IS WHAT FOUND IT.**
It was a `Bool` reset every launch, so `false` — printed `yes` — was ALSO what a
launch said having written nothing, and the campaign reads it after a
force-quit. **The row could only ever pass.** `NoteCommit` now has
`no note written since this launch`, `yes` and `NO`. §12.15's fifteenth
instance, and the general lesson is that **writing the manual campaign is the
first thing that asks what each figure says when it is wrong**. §12.153.9.

**RULE 13 is what stops the next store repeating it.** 409's first draft read
`Sub4Launch.shared.database` at the write, so a store built by `init(directory:)`
into a temp folder reached past it into the app's own database — two suites call
`Sub4Launch.shared.begin()`, so it was leaking on every run. **A seam-bearing
file may now only reach the singleton from `private init()`, from a member called
solely by it, or from a nested type** — a value the initialiser chose. 9 seams,
2 mediated. §12.153.1, §12.153.7.

### 5.3 The evidence, from the device at 398 on 17 August 15:50

**Six slices, zero unexplained differences, ON THE LAUNCH THAT FLIPPED.**
- **THE SEAM HELD.** Slice 4 read `details/` and `streams/` directly — 694 and
  668 files, all readable — while `DetailStore.shared` served rows. First day it
  could have failed.
- **SLICE 4'S TWENTY-FOUR FIGURES ARE IDENTICAL TO 389a AND 390** — 694 ·
  8328/6738/0 · **8129** · 4748 · 1144 · 638 · 629. 390 moved where that side is
  READ; 398 moved what the store HOLDS; nothing moved. Groundwork §3.1.
- Activity parity 694 · 332 days · order 0 of 694 · both lists settled ·
  `activities.json, read directly`; volume 332/284/12 zero; match 518 days ·
  adherence 15 of 207; summary 27 vs 27.
- **Load parity 413 days, SELF-REFERENTIAL since 398** — §5.5; 399 says so.
- **Roll-up at 390: 8 of 9 agree · 0 differ · 0 could not look · 1 nothing to
  compare · 1 reading a store the database feeds** — `Athlete`.
- **`runs ever verified: 18`**, newest `patch 392 · 12 independent` — **7 after
  398** (§5.4).
- **Tables**: `activity_detail 694`, `activity_split 8206`, `recording 668`,
  **`recording_sample 199848`**, `weather 603`. **`Traces still to fetch: 0`**;
  26 of 694 have none (24 under 500 m, 2 empty, 0 unexplained).

**AND THE APP WAS DRIVEN BY HAND ON ROWS — 17 August 17:02.** Every earlier
device check was DATA evidence; **B4 is the first slice whose data gets DRAWN.**
Routes (one across two commute parts), zone distributions with an absent Z5,
splits, laps, the Progress curve and the rotated landscape all render, and
§12.76 did not fire. **The four-panel profile scrubbed to 9.72 km — HR 145 ·
6:05 · 47 m · 1.0% — carries the weight**: four nullable columns aligned to one
sample position, §12.141.3's named risk. **Uncovered: an activity with no
trace**, now a trace of LENGTH ZERO rather than absent — 26 of 694. §12.142.6.

**What it does and does not prove.** The app derives the same answers from
either side for everything the slices cover — **except slice 3, which since 398
cannot disagree.** Not a lossless round trip: gear status, rejection and
match-date metadata, plan source and order and fractional fetch-time precision
are outside the mapped set — §12.86.

### 5.3a The 409a device run — 19 August 2026, 21:44–21:59

**THE FIRST TIME A MUTATION PATH HAS BEEN DRIVEN BY HAND ON THIS PROJECT.**
`docs/DEVICE-CAMPAIGN-409.md`, run against 698 activities and 220,837 rows.
**Sixteen of sixteen.** Subject: *Strength B · core only, 7 August*, a session
with no note. `N = 7`.

- **`user_note` = 8 after a force-quit taken immediately on Save** — a raw
  `COUNT(*)`. The commit precedes the editor closing; 1B's window is shut.
- **`Notes reaching the database: yes`** after an in-launch edit. **The database
  IS open when `NotesStore` writes** — observed, not argued from `RootView`'s
  branch ordering.
- **The card reads `Add a note` after deleting and relaunching.** No
  resurrection — the direction `remove` was inverted for.
- Read-back, whose app side is `notes.json` **read directly**: 7 vs 7 → **8 vs
  8** → 8 vs 8 after the edit → **7 vs 7**, with *only in the app*, *only in the
  database* and *fields that differ* at zero throughout.
- **409a's line was honest in all three states** — `no note written since this
  launch`, the same again after the relaunch, then `yes`. Under 409's `Bool` all
  three read `yes`.
- **An edit of a note that came back from the DATABASE** (row 13) — the case no
  control in the suite reaches, since they all create and edit in one process.

**`migration_run` read 257 → 256 → 257 and that is not data loss.** It is
`MigrationLedger.prune` at its ceiling — 200 automatic, 20 interrupted, plus
what is never pruned — with two force-quits adding two interrupted runs. Noted
because the census makes a shrinking ledger look alarming. §12.153.10.

**Uncovered, unchanged:** a refusal from the real database, a mirror failure on
the phone, a termination inside the transaction, and the other three authored
stores.

**AND 1A RAN THE SAME EVENING — TWELVE OF TWELVE, 22:23–22:28.**
`docs/DEVICE-CAMPAIGN-1A-RESTORE.md`. Receipts `notes.json 0/7`,
`commutes.json 0/1`, `moves.json 0/2`, `match decisions 0/8`.
**Two pairs of exports are byte-identical on purpose** — the **Import ledger**
either side of the press (`authored: 45` both times) and the census — while the
read-back pair differs by **exactly five lines**, the receipt and nothing else.
That closes §12.146 (the receipts reach the paste; at 401 they did not) and
**§12.149** (the restore does not announce, so a repair does not arrive carrying
permission to reconcile). `Notes reaching the database` read `no note written
since this launch` on both sides — **the restore does not commit either**, a
check that could not exist before 409a. **`added 0` now has its precondition**:
`only in the database` was 0 for all four before the press, so it is the correct
answer — but a control that repairs and one that no-ops still read alike, and
that half stays the suite's until a device fixture exists. §12.154.

### 5.4 The verifier's accounting, derived end to end, and in THREE buckets

**22 comparisons — 7 independent, 14 reading a store the database feeds, 1
reading no store at all.** **398 moved five**: `traces`, `details`, `splits`,
`trace samples` and `splits of one activity`, all B4's. The other nine are
`heart-rate zones` (B1); `notes`, `commute corrections`, `match decisions`,
`session moves` (B2); `activities`, `activity identities`, `volume by
discipline`, `activity fields` (B3). The one is `unclaimed corrections`.

**THE THIRD BUCKET IS 388 AND IT FIXED A GATE THAT COULD NOT FAIL.** `unclaimed
corrections` reads `.databaseAlone`, so it could never be self-referential and
made `isTrustworthyEvidence` return `true` whatever the report held. **Evidence
means *could this have disagreed about whether the migration carried the app's
data*** — which a comparison consulting no store cannot answer. §12.132.

**THE DERIVATION IS THE ANSWER SINCE 387 AND `HydratedStores` IS GONE.** Every
comparison names the store FIELD it read (`VerificationCheck.reads`, no default)
and `ExpectationSources.live` resolves it by asking that store's `servedFrom`.
**The unit is the field because two stores are split** — `ActivityStore` keeps
receipts and cursor on `UserDefaults` until B8, `AthleteStore` is `.partial`.
`theWholeMapIsPinned` holds EVERY comparison's field, not a subset.
§12.130–§12.132.

**`runs ever verified: 18`, the newest at patch 392**, over data the database
feeds — taken when 12 comparisons could still have disagreed. **After 398 that
is 7**, and the next Verify press will say so. D7's exit criterion is met; the
number falling is what a slice landing looks like, and B9 is where it ends.

### 5.4a The roll-up's own accounting — patches 389 and 390

**The nine read-backs carry the same split, derived the same way**: each row says
where its APP SIDE came from and `ExpectationSources.live` resolves it. **390
gave `Activities`, `Details` and `Recordings` their own reads — the count is 1,
`Athlete`.**

**THE UNIT IS NOT THE FIELD HERE.** `Notes and commutes` reads four fed fields
and is evidence anyway, because 356 gave it its own read: a row says whether it
read the files itself or took the stores, and only the second consults the
sources. **FOUR marks** — *own read*, *self-referential*, *from the stores, not
fed yet* (B7's tripwire), *COULD NOT READ ITS OWN SIDE* (red). §12.133–§12.134.

**AND THE COUNT REACHED ZERO ON THE PHONE — 20 August 22:11, patch 422.**
`8 of 9 agree · 0 differ · 0 could not look · 1 nothing to compare ·
**0 read a store the database feeds**`, with `Athlete` reading
`own read: constants.json and athlete.json, read directly`. It was **1,
`Athlete`**, from 390 until this reading. **Nothing on that screen compares the
database with itself any more.** The two remaining non-own-read marks are
`Weather and gear` and `Review trail`, both *not fed yet* — B5's and B7's
tripwires, which become self-referential the day their slice flips. §12.168.

### 5.5 Open, and the first one is Bruno's call

> **THE MATCH PICKER OFFERS ACTIVITIES THE MATCHER WILL REFUSE.** Confirmed on
> device 2026-08-05 and still open. `MatchPickerView.choiceSection` lists
> `activities(on: dayKey)` unfiltered; `Matcher.resolve` pools
> `all.filter(\.isPlanEligible)` and a walk is never eligible, so choosing one
> stores an override the matcher cannot find and the session reads *Not done*
> with nothing saying why. **Two fixes, your call:** (a) the picker lists only
> eligible activities, extras greyed with a reason; (b) an explicit override
> wins over `isPlanEligible` — patch 251's own argument, and it would let that
> walk's load into the session's figures.
> `MatchResolverTests.anOverrideNamingAnIneligibleActivityIsLost` states the
> defect as a test, so the day it is fixed the test inverts.

- **THE AUTHORED RESTORE PATH IS COMPLETE — §5.5's longest entry closes.** All
  four stores have a way back, and **1A's campaign confirmed all four on 19
  August: added 0 · already held 7/1/2/8**, with the ledger byte-identical
  either side of the press (§12.154). 405 stopped them announcing, so a repair no
  longer arrives carrying permission to delete (§12.149); 407 added the match
  decisions, a `UserDefaults` blob rather than a file (§12.151).
  **`proposals.json` is B7's** — zero-versus-zero proves nothing.
- **SLICE 3 IS SELF-REFERENTIAL AND SAYS SO SINCE 399.** Both varied inputs —
  activities (381), traces (398) — are the database's on both sides, so it proves
  `LoadSeries` is deterministic, not that the migration carried the data.
  **Marked, not rescued**; §12.125.4's "no screen shows it" expired at 378/390.
- **`newest removal` names the trigger, not the family** (1C's other half);
  **`canReconcile` tests readable, not correct**; **Import is not a repair
  path**. **403's gate reads a BUILD LOG** — a clean build at 408 found zero
  (§12.150.4).
- **RULE 8 no longer covers `DetailStore`**; **391 swept the read-backs and not
  the restore receipts** — RULE 11. **AN `.authored` TRIGGER STILL PERMITS
  RECONCILIATION ACROSS EVERY FAMILY** — 405 stopped restores pulling it
  (**device: ledger byte-identical either side of a press**), not the trigger
  being dangerous. Topic 1C.
- **`ReadBacks.athlete` READS THE FILES SINCE 419 — the last self-referential
  read-back is closed.** It compared `ConstantsStore.shared.c`,
  `AthleteStore.shared.ftp` and `.hrZones`, all hydrated since 346: twenty-seven
  comparisons that could not have disagreed, printed as agreement for
  seventy-three patches. `athleteSources()` reads `constants.json` and
  `athlete.json` through 418's seams, and `.ownRead` makes the roll-up derive
  independence. **CONFIRMED ON THE PHONE at 422** — the roll-up's
  self-referential count is 0, from 1 since 390 (§12.168). **Topic 3's campaign
  is written at 420 and PART 1 HAS PASSED, four of four** —
  `docs/DEVICE-CAMPAIGN-B34.md`: the zero-length trace UI, a Release
  `Detail store built`, and interaction behaviour rather than a timestamp.
  420 also made `asked, nothing there` NAME its activities, without which the
  campaign's central step could not be performed (§12.165). **PART 1 PASSED on
  20 August at 422 — four of four**, and it took three attempts to become
  performable: it pointed at the wrong section (§12.166.4), then omitted that
  the roll-up is a BUTTON. **Rows 3 and 3b of part 2 passed too.** Everything
  still outstanding — the two traceless activities and the Release cost — is
  **`docs/DEVICE-CAMPAIGN-TRACE-AND-COST.md`**, written at 423, self-contained,
  and **one Release build for both parts**. **PART A PASSED on 20 August**: an
  activity with a zero-length trace draws **no** HR panel, **no** profile and
  **no** route — one sentence in their place, *"No recorded profile for this one
  — entered by hand, or recorded without GPS"* — and it scrolls, rotates and
  dismisses without a crash. §12.142.6's uncovered case is closed. **Row 9 could
  not discriminate**: both are hand-entered and have no splits either, so
  "splits survive an absent trace" was never asked.
  **421 replaced the stopwatch with an instrument** — process start, first view,
  first free main-thread turn and the longest 60 Hz stall over ten seconds,
  three-valued and with a poisoned-window state (§12.166). **422 made the two
  named ids REACHABLE**: nothing in this app finds an activity by Strava id, so
  the screen now shows the day beside each — §12.7 governs the paste, not the
  owner's own screen (§12.167). **423 made them OPEN** — this device's two are
  `2025-07-24` and `2025-11-10`, the Week grid starts at 2026-01-01 and cannot
  reach either, and the Today stepper is 393 taps away, so each entry is a
  button into the activity's detail (§12.169). **`knownActivityIDs` is B5's**;
  **`DetailStore` is invisible to RULE 1**. §12.164.
- **A DISPOSABLE DEVICE FIXTURE IS NOW ASKED FOR BY THREE PATCHES.** 1A could
  not show the restore REPAIRS, 414 could not show a scoped REMOVAL, 415 cannot
  show a removal recorded and surviving — all for one reason: **409 and 412 made
  authored deletes go straight to the row**, so the orphan state reconciliation
  cleans up is the state the inversion stopped producing. Each wrote its own
  limitation down and proposed the same remedy. **Before B9.** §12.160.6.
- **Snapshot `2026-08-10-084723`** (340); **`manual.html` stale**; **`content_revision` unoccupied** (334).
- **Dates:** first review **24 Aug**; Actions resets **1 Sep**; Japan **7–12 Sep**, `DayKey.key(_:in:)`'s first run outside Europe/Brussels.

### 5.6 Next, in order

**Done and now history — the arguments are in ADR §12, not here.** The Database
screen 391–393a (RULE 7). **B4, 388–398**: 394 measured 3.963 s before first
paint and the answer killed its own design; 395 moved both families into
`DetailStore`'s construction; 397 made the read one cursor and one pass; 398
flipped. **396** replaced `#if DEBUG` with how the build was signed (RULE 9).
**399** marks slice 3; **400/402/404** build the authored restore path and
**405** stops it announcing (RULES 11–12); **401** removes a source compiled by
nothing (RULE 10); **403** makes both gates read warnings; **406** records why a
run happened. §12.135–§12.150.

1. **THE ROLL-UP GATE IS 8 OF 9 UNTIL 24 AUGUST, AND ALL EIGHT ARE NOW
   EVIDENCE.** `provesSomething` wants all nine read-backs to have compared
   something, and `Review trail` reads nothing on either side until **24 August
   2026**. The gate is **eight of nine agree, zero differ, zero could not look,
   abstention named** — B7 blocked on it too. **The device confirmed it on 20
   August at 422, with the self-referential count at 0** (§12.168); it read 1
   from 390 until 419 landed.
2. **1B IS DONE, ON THE PHONE — TOPIC CLOSED.** All four authored stores commit
   before they publish, and **412's campaign ran on 20 August: twelve of
   twelve** (§12.157.7). `correction` **6 → 5** across a clear and a force-quit
   is the row that matters — the delete reaches the rows.
3. **413 PRINTS THE RESIDUAL, AND `skipped` COULD NEVER HAVE.** `correction
   rows: 6 — 3 read as commute decisions, 3 as moved sessions, 0 unaccounted`,
   unconditional. Taken against **what the readers returned**, not against the
   kinds — the invisible row had a valid kind and it was `commuteSQL`'s INNER
   JOIN that dropped it, so a kind-based residual would have read zero.
   Mechanism proven by test; the 20 August instance still unproven. §12.158.
4. **1C IS DONE — 414 SCOPED THE PERMISSION, 415 MADE THE REMOVAL DURABLE.**
   A save may delete only from the family whose mutation completed, and only
   when **that family's own source** read cleanly (§12.159, campaign run 20
   August). **`migration_run_removal(runID, family, rows)`** records which
   family lost what — and **a run that removed rows is now never pruned**,
   because the table cascades and a child cannot outlive a disposable parent.
   The device is what argued it: the ledger had forgotten its only two
   removals inside a day. §12.160. **416 brought the work queue inside the
   gate** — it was pruned on every run with no permission, so a report said
   `does not delete` three lines above `rows removed in total: 1`. One
   vocabulary now, six families. §12.161. **Both readings confirmed on device 20 August** —
   nineteen migrations, fifty-two tables, and `removed by family, durably:` all
   six at zero (§12.160.6).
5. **1B's NOTES — BUILT AT 409, PROVEN 19 AUGUST.** A note save commits to
   SQLite **before** the editor closes, and `remove` with it — 408 the narrow
   write, **409 the order**, **409a the diagnostic** (§12.152, §12.153).
   Six controls; **control 4 does not discriminate the order and says so**.
   **The campaign ran on 19 August and passed sixteen of sixteen** — §5.3a.
   **RULE 13** stops the next store repeating 409's seam leak. Next is the same
   inversion **family by family** — the commutes, the match decisions, the plan
   moves — then 1C's reconciliation scope and removal attribution.
6. **FILE PROTECTION — 417 MEASURES IT; 418 OWES THE LAST TWO STORES.**
   `Protection · Until first unlock` was a **string literal** and
   `FileProtection.protect` swallowed its failure with `try?`. The row now reads
   `N of 7 at the expected class`, measured with `attributesOfItem`, and the
   seven readings reach the paste. **Four states, not three** — an attribute at
   the WRONG class breaks background writes and is not the same as none.
   **The campaign RAN on 20 August: seven of seven**, every item `until first
   unlock`, zero failed writes (§12.162.5). A physical phone was mandatory — on
   a simulator `setAttributes([.protectionKey:…])` stores nothing and fails at
   nothing, so two of the reader's four answers are unreachable in the suite.
   **Running it deleted a step**: there is no reading before first unlock,
   because the app cannot run then.
   **418 CLOSED THE REST OF TOPIC 2**: `AthleteStore` and `AthleteConstants`
   are under the unclean-read guard and **`UNPROTECTED_STORE_CEILING` is 0**,
   from 2 since 378 — it may never rise. Both gained `init(directory:)`, which
   §5.5 wants for `ReadBacks.athlete` anyway. §12.162, §12.163.
7. **Then Bruno's list**, then **B5 — weather and gear**, with
   `knownActivityIDs` and `WeatherGearRoundTrip`'s own read. **Gear is the half
   of `AthleteStore` B1 did not take** — its comparison is still evidence.
8. **B6, B7, B8, then B9** — activate, `activateVerified` called for the first
   time, `migrationFailureBlocksTheApp` flipped to `true`, and the fail-closed
   recovery screen `RootView` lacks.
9. **D8** — stabilise one release window, then remove the JSON writers.

**B4's cost — §5.6's OWED RELEASE FIGURE LANDED ON 20 AUGUST AND IT CHANGES THE
ANSWER.**

| | Debug | **Release** |
|---|---|---|
| the files | 0.443 s | 0.399 s |
| **the database** | 0.683 – 1.233 s | **0.323 / 0.397 s** |

**In the build that ships, the database side is level with or faster than the
files it replaced.** In Debug it looked like a 1.5× to 2.8× regression — and
every figure this project quoted about B4's cost for eight patches came from the
build nobody ships. §12.172.1.

**AND THE LAUNCH IS MEASURED AS THE USER EXPERIENCES IT SINCE 421 — WITH A
FINDING, NOW ATTRIBUTED.** Release, 20 August, two launches:
`first free main-thread turn: 0.020 / 0.029 s` and **`longest main-thread stall:
0.562 / 0.641 s`**. **The app becomes responsive in 20 ms and is then blocked
for six-tenths of a second.**

**424 gave both durations an origin and row 15c is answered: the store's
construction sits INSIDE the stall, twice.** A 0.035→0.676 stall around a
0.199→0.596 read; a 0.051→0.613 stall around a 0.199→0.522 read. One
uninterrupted block starting at first paint — ~0.15 s, then the read (≈60% of
it), then ~0.08 s. §12.170, §12.171, §12.172.

**B4's plan did not hold: 394/395 moved the cost out of first paint rather than
removing it**, and nothing measured where it went — §12.155's shape.
**AND THE FIX IS NOT THE ONE §12.171.3 PREDICTED.** `currentSignature()`'s
"cheap fingerprint" really does construct the store, and repairing that would
change nothing, because `recompute()` reads `DetailStore.shared` itself two
lines later. **The launch recompute is what has to move, not the fingerprint** —
a larger change needing its own investigation. §12.172.2, and it is precisely
what measuring before fixing was for.

Phase 4A (Apple Health canonical) cannot start before D7's exit gate — see
`review-data-pool.md` and `ADR-0002-strava-retirement.md`.

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
- **ASK THE THING THAT OWNS THE ANSWER, AT THE GRANULARITY IT OWNS IT.** Three
  stores in this app serve more than one kind of thing and serve them from
  different places — `ActivityStore` gives the activities from the database and
  the sync cursor from `UserDefaults`; `AthleteStore` gives the zones from the
  database and gear from a file. A per-STORE answer to "are you fed by the
  database" is wrong for five of the verifier's twenty-two comparisons, in both
  directions. **Before deriving anything from an object, check whether the object
  has one answer to give.** §12.130.1.
- **A TRIPWIRE OVER A SUBSET CANNOT SEE WHAT IS MISSING FROM IT; A COMPLETE MAP
  CAN.** `HydratedStores` listed the comparisons that read a hydrated store, so
  a comparison nobody added simply passed — the list had no opinion about it.
  387 replaced it with `theWholeMapIsPinned`, which holds EVERY comparison's
  field: one that is missing fails, and one whose field changed fails. **When a
  guard is a list of things that are wrong, ask what it says about a thing that
  is not on it.** Usually nothing, and nothing reads exactly like a pass.
  §12.131.4.
- **A JOIN THAT IS CHECKED IN ONE DIRECTION IS UNCHECKED IN THE OTHER.**
  `unmatchedHydratedEntries` catches a declared entry naming no comparison, and it
  is a good tripwire — it is also the only one, so a COMPARISON that nobody
  declared counted as evidence in silence for three patches. **When you build a
  tripwire over a join, write down which way it points, and say what watches the
  other way.** Here nothing did. §12.129, and 386 is the patch that stops
  declaring the classification and derives it.
- **WHEN A FLIP MOVES A STORE OFF A SOURCE, ASK WHAT STILL REPORTS ON THE
  SOURCE IT LEFT.** 398 moved `DetailStore` to the database; nothing asked what
  was still counting the files, so `Detail and trace files:` printed
  `0 … all readable` for twelve patches over 694 files nobody had opened. **Four
  instances in two days** — 409a's vacuous `yes`, this, and §12.77.5's two
  counters — all one shape: *a value that stopped being computed, printed as
  though it were*. Cheap to ask at every remaining flip, and B5, B7 and B8 are
  all owed it. §12.155.
- **TWO COUNTERS THAT BOTH READ ZERO CAN BE MEASURING DIFFERENT THINGS.**
  `rows the reader could not read` counts rows that came back and would not
  decode; it read 0 while a `correction` row was invisible, and it was right to
  — an INNER JOIN that matches nothing returns nothing to fail at. The
  diagnostic was not broken and did not need fixing; it could not answer the
  question somebody asked of it. **When a count reassures you, check what it
  actually counts.** §12.158.1.
- **AN IMPLICIT FOREIGN KEY BINDS TO WHATEVER THE PRIMARY KEY IS TODAY.**
  `.references("migration_run", onDelete: .cascade)` emitted
  `REFERENCES "migration_run"("sequence")`, because a rebuild two migrations
  earlier had made `sequence` the primary key and demoted `id`. The migration
  ran clean, the schema was valid, and every insert failed the foreign key at
  write time. **Name the column.** §12.95.4's shape in DDL, and worse, because
  the value it carries is whatever a later migration decides. **A migration
  that applies cleanly has not been tested.** §12.160.2.
- **A TEST CAN ENCODE A CLAIM THE CODE NEVER MADE.** Three tests asserted that
  an automatic write-through reconciles NOTHING — *"whatever it is handed"* —
  while every one of those runs had been pruning `work_queue` for as long as the
  queue existed. They passed because the prune was outside the permission system
  the assertions read. **When a test asserts an absence, ask what it is actually
  looking at**; and two lines of one report that can disagree need something
  owning the sentence they share. §12.161.
- **A SIMULATOR CAN ACCEPT A WRITE AND KEEP NOTHING.**
  `setAttributes([.protectionKey: …])` there stores no attribute and fails at
  nothing — **not even for a directory that does not exist**. So a protection
  test that passed proved only that the call returned. Split the DECISION from
  the READ (`classify` vs `read`), test the decision directly, and say in the
  test file which answers only a device can produce. §12.162.3.
- **A CAMPAIGN STEP THAT CANNOT BE PERFORMED IS WORSE THAN A MISSING ONE.**
  417's opened with *"restart the phone, do not unlock it"* under a heading
  promising a reading — and the app cannot run before first unlock, which is
  what the protection class guarantees. The tester does it, sees nothing, and
  cannot tell that from a pass. §12.69's shape in the instructions rather than
  the code. §12.162.5.
- **A CONTROL WRITTEN TO CATCH A §12.69 CAN BE ONE.** 418's round-trip test
  existed to catch a decoder mismatch that would have made every file on disk
  unreadable — and its first version passed against the wrong decoder, because
  the fixture set the one Date field to nil so the two strategies never met.
  Found by sabotaging the thing it guarded and watching nothing fail.
  **Sabotage the control, not only the code.** §12.163.2.
- **WHEN THE CHANGE IS "CALL B INSTEAD OF A", THE TESTS ABOUT B PROVE
  NOTHING.** 419 reverted to the old wiring and the entire suite stayed green:
  six tests covering every part — the comparison turns red, the seam reads the
  file, absence is clean, `.ownRead` is independent — and **not one asked the
  read-back what it does**. §12.129 in a different costume, and 416's "a test
  can encode a claim the code never made" for the second time in ten patches.
  **Ask the function, not its ingredients.** §12.164.1.
- **A number a device prints is not a number a device verified.** `14 independent`
  was rendered, stored in the ledger and pasted into a diagnostics file, and it was
  wrong — because every one of those steps read the same list. Printing is not
  checking. §12.129.2.
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
