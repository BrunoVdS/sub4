# Sub4 Phase 3 — the SQLite/GRDB persistence rewrite

*Origin: Cowork project memory `sub4-database.md`, exported to the repo 2026-08-07 at
patch 278c. **Refreshed 2026-08-08 at patch 319** — the exported copy still described
patch 278c after forty further patches, which is the failure this file exists to prevent.
See ADR-0003 §12.62.*

**Read `docs/ADR-0003-database-contract.md` first.** It is long, current and authoritative:
§3 (identity), §9 (decisions), §12 (every patch decision from 200 onward, newest appended
before §12.10). Every rule here is stated there with its reasoning.

**The handoffs are history, not state.** `HANDOFF-2026-08-05.md`,
`HANDOFF-2026-08-05-late.md` and `HANDOFF-2026-08-06.md` were snapshots and all three are
now behind. ADR §12 supersedes them.

## Where it STOOD — 2026-08-08, patch 319 · HISTORICAL

> **This section is history and is kept as history — patch 384.** D6c closed at
> 330 and D7 is four slices in as of 383. **`CLAUDE.md` §5 is current state.**
> The rules and the reasoning below are still good and are why this file is
> worth reading; the counts are not.

**D0–D5 complete. D6a complete. D6b complete. D6c four slices of eight. D7 not started.**

- GRDB **7.11.1**, pinned Exact Version, revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
  Product `GRDB` (static) on the `Sub4` target only; `GRDB-dynamic` deliberately not linked.
  Tests reach it via `@testable import Sub4`.
- Xcode's Exact Version field pre-fills `1.0.0` — a 2017 tag Swift 6.3 refuses. Type the
  version and press **Tab**, not Return.
- **Eleven migrations, 51 tables, 213,698 rows, ~37 MB.** On the phone: 673 activities,
  673 details, 649 recordings, 194,154 trace samples, 8,057 splits, 2,349 laps,
  761 best efforts, 582 weather, 11 gear, 15 resting months, 5 HR zones, 7 notes,
  4 corrections, 3 rejections, 107 ledger rows.
- The eleventh is `2026-08-12-run-trigger` (patch 311), which added
  `migration_run.triggeredBy`. Named `triggeredBy` rather than `trigger` because the latter
  is a SQL keyword.
- **`migration_run` reaches `verified`.** The semantic verifier compares per-table counts,
  sync state, identity, an activity fingerprint and the domain checks. **The comparison
  count is printed on the Database screen and is deliberately not restated here** — the
  exported copy of this file said "19", and a second answer to a question the screen
  already answers is how §12.29's problem starts.
- **931 tests in 88 suites.** 159 Swift files in `Sub4/`, ~56,000 lines; 68 test files.
- **Nothing reads the database yet.** The app still runs entirely off its JSON stores.
  That is D7.

## D4, patches 264–274

**Failable saves** (264 notes, 265 commutes, 266 the six unwatched, 270 review delete),
then the database half:

- **272 — `match_decision`.** `Matcher.overrides` was `[uid: activity id]` in UserDefaults
  with `""` for "explicitly nothing", and the table needs `decidedUTC NOT NULL` — so the
  STORE had to learn a fact first. Now a `MatchDecision` record with `decided` +
  `dateIsKnown`. Stays in UserDefaults deliberately. The one authored store with **no
  failable save** — `UserDefaults.set` has no failure to report.
- **273 — `StoreLoad` / `StoreReadJournal`.** Every authored store loaded with two `try?`s
  that could not tell "no file" from "will not decode". `.loaded` / `.absent` /
  `.unreadable`, `isTrustworthy` false only for the last.
- **274 — the reconciliation pass.** The importer had been **additive-only since it was
  written**. Now deletes `user_note`, `match_decision` and `review` rows whose record is
  gone from the store. Gated on `StoreReadJournal.canReconcile`, which **fails closed**.

## D5, patches 275–288

- **275 `sync_state`** — the column is opaque by §8's own comment, so the epoch goes in
  verbatim. The app's cursor stopped being a cursor at 249: high-water mark, not query
  bound. The verifier compares the CURSOR, not the row count.
- **276 `work_queue`** — neither set is a retry queue; both are terminal verdicts.
- **277 the trace account** — six buckets that must sum to the total; **`unexplained` is the
  only line worth watching.** At 317b: 24 of 674 with no trace = 2 asked-nothing-there +
  22 under 500 m + **0 unexplained**.
- **278 `rejection`**, **278c** — a migration may lose the old SHAPE, not the DATA.
- **279–288** — the protected snapshot, gear reference, plan content, activity detail,
  the benchmark and the remaining slices.

## D6a — repositories, patches 289–301

Four readers, each comparing every field against the store it mirrors:

| repository | patch | round trip |
|---|---|---|
| `ActivityRepository` | 289 | `ActivityRoundTrip`, 19 named fields (290) |
| `ActivityDetailRepository` | 291 | `DetailRoundTrip` — splits, laps, best efforts |
| `RecordingRepository` | 294 | `RecordingRoundTrip` — every sample of every stream |
| `AthleteRepository` | 317 | `AthleteRoundTrip` — profile, resting series, zones |

Every one returns a load type that distinguishes **nothing there** from **could not look**
(§12.15, nine instances now). Every one names the FIELD that differs rather than counting
rows — "12 differ, all on `maxSpeed`" is one fix; "12 activities differ" is an afternoon.

**Two accepted losses, both stated on screen.** A trace shorter than the distance axis comes
back padded with zeros and its original length is gone. Twelve details have a zero heart
rate normalised to nothing by `positiveOrNil`.

## D6b — write-through, patches 302–307

Every path that writes a store now reaches the database. The ledger records what started
each run (311): `manual`, `backgrounded`, `foregrounded`, `backgroundRefresh`. Automatic
runs are pruned to the newest 200; manual, failed and interrupted runs are kept for good,
because **an interrupted run is the only evidence the app was killed while writing**.

## D6c — shadow parity, patches 309–317

The question is no longer *do both sides hold the same records* but *would the app derive
the same answers*. Slice order is in `docs/D6C-SHADOW-PARITY-GROUNDWORK.md` §6.

| slice | what | state |
|---|---|---|
| 1 activities — identity, order, days, zones | `ActivityParity` | 312 ✔ |
| 2 daily and weekly volume | `VolumeParity` | 313 ✔ |
| 3 fitness and load, incl. the HR histogram | `LoadParity` | 314–316 ✔ |
| 4 details, splits, laps, traces | — | **next** |
| 5 notes, corrections, plan matching | — | open |
| 6 zones, weather, gear | `AthleteRoundTrip` = the athlete part | 317 ✔ / rest open |
| 7 review payloads | — | open |
| 8 Today / Week / Plan / Progress summaries | — | open |

**Neither side reimplements anything.** `ActivityRoster` (310), `byDay` (312),
`recordedByWeek` (313) and `LoadSeries.build` (314) were extracted so both sides call one
copy — §12.43, five applications. *A derivation with one caller looks like part of that
caller. It stops being that the moment something else must agree with it.*

**Every comparison prints a denominator and a tolerance.** Volume `1 m · 1 s`; load
`0.01 TRIMP · 0.01 s`; `DayState` compared exactly, because a rest and a gap both carry
zero and the state is the only thing between them.

**Device result at 317b, all four slices clean:** 674 activities · 324 days · no
differences. Load: 403 vs 403 days, 279 sessions, 222 vs 222 scored from a trace, 7,112
heart-rate buckets, 0 of 403 curve points, Fitness 33 vs 33, Fatigue 39 vs 39. Athlete:
27 compared, 0 differences, HR max 181 vs 181, FTP 270 vs 270.

**The approved-difference list has exactly one entry** — `AthleteConstants.version` (317),
a local cache counter with no column. A `struct` carrying `field`, `reason` and `patch`,
with a test pinning the count at one.

## The rules that keep costing when forgotten

- **A migration is history.** Vocabularies inside one are FROZEN literals, coupled to the
  Swift enums by test. A new column is a new dated migration file, registered in
  `Sub4Migrations.migrator` **and** appended to `Sub4Migrations.all`, with an identifier
  that sorts into run order — `all == all.sorted()` is asserted.
- **Strava ids are never primary keys** (§3.1).
- **The import is idempotent by lookup, not by luck.** It UPDATEs rather than skipping.
- **Each imported row gets its own SAVEPOINT.**
- **Write the §12 mapping before the importer.**
- **SE-0434: stored `Sendable` properties of a main-actor value type are implicitly
  `nonisolated`; computed properties are not.** `AthleteConstants.hrMax` needed the keyword
  at 317 while the stored properties beside it never had.
- **`nonisolated` on a type does not reach its extensions.** Five instances: 207, 219, 228,
  and both ends of 317.
- **`Sub4Import` is `nonisolated` end to end.** Anything main-actor it needs must be
  computed by the CALLER and passed in.
- **Never put `try` inside `#expect` or `#require`** — hoist to a `let`.
- **Sweep the BARE IDENTIFIER, then filter.** `\.rejected\b` finds reads and misses
  `rejected = []`.
- **Changing a type's shape means grepping `Sub4CoreTests/` too, before the build** — a
  function's arity, an array's length, a printed string's content. 315 and 317b both lost a
  build to this.
- **Do not infer a type's name from its filename.** `ZoneTime.swift` declares `ZoneTotals`.
- **Never assert `Sub4Migrations.all.last == <a migration>`.**
- **A synthesised `init(from:)` does not use Swift default values.**
- **The repo's own tests police PROSE.** `gapsAreActionable` requires every recorded gap to
  cite `step ` or `ADR-`.

## How changes reach this repo — two surfaces, two workflows

**Claude Code on the Mac** edits files in place and git is the undo. Retired with the move:
the `SUB4_ROOT` preflight, the anchor-uniqueness rules, and `git --no-optional-locks status`
(the `.git/index.lock` problem was a bridge artefact).

**Cowork cannot write into this repo.** It reads through the device bridge and delivers
**patch zips that Bruno unzips himself** — which is what patches 310–319 are. `apply-NNN.py`
was dropped at 315 because twice it was not run and nothing showed (§12.59.6); documents now
ship as files inside the zip and arrive by `cp`.

Neither surface touches git. Bruno commits.

What survives on both:

- **Run the suite before building onto the phone.** ⌘R compiles the app target only, so
  test-target errors accumulate invisibly. `./scripts/test.sh`.
- **Never run `xcodebuild test` while Xcode is building** — shared DerivedData produces
  `invalid reuse after initialization failure` on innocent files.
- **A new Swift file needs Xcode quit and reopened** before the app target sees it.
- **`AppVersion.swift` ships in every patch**, without exception.
- **Commit per logical change with the patch number in the subject.**
- **Take a fresh protected snapshot before anything destructive.**
- Never use Xcode's "Add Files"; never hand-edit `project.pbxproj` to add a source.
- Nothing that is not Swift source goes under `Sub4/Sub4/`.

## Benchmark result — §9.3, settled

Normalised (`recording_sample`, one row per sample) STAYS. iPhone 17 Pro Max at 10,000
activities × 300 samples: read 0.28–0.31 ms/recording (budget 5), import 4.0 ms/activity
(budget 50), storage 224 MB (budget 500). Three **absolute** budgets, not ratios.

## What this project keeps re-learning

- **Real data beats tests.** The ghost review was found by reading table counts after a run
  that passed 15 comparisons; `work_queue` wrote 2 rows where 23 were predicted.
- **Read the code that produces the number, not the numbers either side of it.**
- **A test that keeps passing can stop describing the system.**
- **A warning-shaped defect needs a test.**
- **A diagnostic that cannot say why it has no answer will be read as having one** (§12.15).
- **A row that vanishes at zero cannot be told from a row nobody wired in** (§12.54.2).
- **A comparison must have a real way to fail.** Zero compared to zero agrees perfectly.
- **Do not reason by analogy about two numbers without checking whether one determines the
  other** (§12.60.1).
- **A step that can be skipped without symptom will be** (§12.59.6).
- **Six controls have been found reporting work they did not do.**
- **A method written in anticipation is not a feature.**
- **An account beats a list.**

## Next, in order

1. **THE MATCH PICKER DEFECT — still open, and the choice of fix is Bruno's.** See
   "Known open items". It has been open since 2026-08-05.
2. **D6c slice 4** — details, splits, laps, traces. The reader already exists
   (`ActivityDetailRepository`, 291) and there is a known accepted loss to test against:
   the twelve zero-heart-rate details.
3. **D6c slices 5, the rest of 6, 7, 8.**
4. **D7 activate.** `Sub4Launch.migrationFailureBlocksTheApp` flips to `true`.
5. **D8** stabilise one release window, then remove the JSON writers.

Phase 4A (Apple Health canonical) cannot start before D7's exit gate — see
`review-data-pool.md`.

## Known open items

- **THE MATCH PICKER OFFERS ACTIVITIES THE MATCHER WILL REFUSE — confirmed on device
  2026-08-05 22:00, still open at 319.**
  `MatchPickerView.choiceSection` lists `activities(on: dayKey)` unfiltered, but
  `Matcher.resolve` builds its pool from `all.filter(\.isPlanEligible)` — and
  `Activity.isPlanEligible` returns `false` by `default:`, so a WALK is never eligible.
  Choosing the walk stored the override, the matcher could not find it in the pool, and the
  session fell through to the same branch as "explicitly nothing": **Week showed Not done
  and Sessions went 4/4 → 3/4, with nothing on screen saying why.**
  Worse since 272: the import DOES write the row. So the store says "the walk",
  `match_decision` says "the walk", and the screen says "not done" — and the verifier cannot
  see it, because it counts rows and the count is right.
  **Two fixes, and the codebase argues for the second.** (a) the picker lists only
  plan-eligible activities, extras greyed with a reason; (b) an explicit override WINS over
  `isPlanEligible` — patch 251's own argument, three lines above the walk case:
  *"the athlete's answer has to be able to win in BOTH directions."* (b) has consequences:
  the walk's distance and load would enter that session's adherence and effort figures.
  **Bruno's decision, not Claude's.**
- **Background refresh has never fired.** 107 ledger rows: 1 manual, 34 backgrounded,
  22 foregrounded, **0 backgroundRefresh**, 50 from before the trigger column existed.
  The `Woken by iOS` count on the Settings screen decides whether patch 307's path is dead
  or iOS has simply never woken the app. **Outstanding since 311.**
- **`Interrupted runs: 2`** at 317b, from that night's ⌘R cycles. Should not climb on a day
  with no rebuilds.
- **`Sub4/manual.html` is stale since patch 284** — zero mentions of the Database screen,
  shadow parity, write-through, GRDB or migrations. §11 "Where the data lives" is the part
  that will be wrong, and D7 changes that answer, so it is deferred rather than written
  twice.
- **`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` untouched since the 3 August
  baseline.** Deferred until the D-ladder finishes.
- **The proposals import is unverified against real data until 2026-08-24**, the first real
  review. The review still cannot be SENT — see `review-data-pool.md`.
- **`content_revision` probably has no correct occupant** among the preference keys — the
  four backfill flags and three schema versions are build markers, not content hashes. Its
  real first occupant is likely the plan's content hash. **Settle before building.**
- **Four preference keys are staying** — `appearance.selected`, `discipline.selected`,
  `volume.unit`, `zones.window` describe the reader, not the training.
- **`lateArrivals` has been computed since patch 45 and is displayed nowhere.**
- **The protected snapshot goes stale.** The one on the phone is `2026-08-05-202320`, taken
  by patch 279: 1322 of 1322 copied, 19.1 MB, `details.json` and `streams.json` not present.
  Take a fresh one before any destructive patch.
- **`work_queue` has a third state it cannot hold**: "never asked, under 500 m". No row is
  the honest answer; patch 277's account explains it instead.
- **`ActivityStore.load()` still has the two-`try?` shape** patch 273 fixed on the four
  authored stores. It is a cache and re-fetchable, which is why it was left.
- **The `@State` evaporation trap still applies** to the three older read-backs and the
  legacy survey — a result held in `@State` is discarded when the sheet is dismissed, so the
  diagnostics paste says "not run" a minute after a clean run. Parity was moved to an
  `@Observable` singleton at 313 (§12.57); the athlete read-back sidesteps it by re-running
  on open (§12.61.4).
- **Gear is closed.** `Naming unknown gear` reached 0. Refused is 0.
- **The review UI feels sluggish** (Bruno, 2026-08-05). Deferred until there is a real
  review to design against.
- **2026-09-01 — GitHub Actions allowance resets**; CI unverified since the trigger change.

## The reinstall, 2026-08-04 — ADR §12.8.1

The app was reinstalled mid-session and **all session notes and every past review were
lost**. Activities came back from Strava within minutes; authored content had nowhere to
come back from.

**The JSON files and the database share a fate.** Both live in Application Support and both
die with the app. The kept files protect against a bad migration, not against a reinstall.

- **Device backup is load-bearing**, not incidental.
- **The authored stores are asymmetric.** `user_note` and the review tables are originals;
  activities, recordings and weather are caches.
- The protected snapshot (patch 247, refreshed 279) copies every legacy input before
  anything decodes it.
