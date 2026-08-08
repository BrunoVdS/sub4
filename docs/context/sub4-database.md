# Sub4 Phase 3 — the SQLite/GRDB persistence rewrite

*Origin: Cowork project memory `sub4-database.md`, state as of 2026-08-05 patch 278c.
Exported 2026-08-07. The Cowork patch-delivery workflow has been removed — see
"Working directly in the repo" below for what replaced it.*

**Read `docs/ADR-0003-database-contract.md` first.** It is long, current and authoritative:
§3 (identity), §9 (decisions), §12 (what the import writes). Every rule here is stated
there with its reasoning. The long-form state is `docs/HANDOFF-2026-08-05-late.md`
(the earlier `HANDOFF-2026-08-05.md` is superseded).

## Where it stands — 2026-08-05, patch 278c

**D0 to D4 complete and verified on the device. D5 in progress — 3 of 5 slices done.**

- GRDB **7.11.1**, pinned Exact Version, revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
  Product `GRDB` (static) on the `Sub4` target only; `GRDB-dynamic` deliberately not linked.
  Tests reach it via `@testable import Sub4`.
- Xcode's Exact Version field pre-fills `1.0.0` — a 2017 tag Swift 6.3 refuses. Type the
  version and press **Tab**, not Return.
- **Ten migrations, 51 tables, 212,295 rows, ~37 MB.** On the phone: 668 activities,
  668 details, 645 traces, 7,990 splits, 192,954 trace samples, 580 weather, 11 gear,
  6 notes, 1 sync_state, 2 work_queue, 3 rejection.
- **`migration_run` reaches `verified`** — the semantic verifier compares **19** things
  across four layers.
- **931 tests in 88 suites.**
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
  `.unreadable`, `isTrustworthy` false only for the last. Instrumented on `notes.json`,
  `proposals.json`, `commutes.json`, `match.decisions`. Singleton inits record; the test
  seams deliberately do not.
- **274 — the reconciliation pass.** The importer had been **additive-only since it was
  written**: the rehearsal review deleted from `proposals.json` was still in the database a
  day later. Now deletes `user_note`, `match_decision` and `review` rows whose record is
  gone from the store — `review` cascades to its four children. Gated on
  `StoreReadJournal.canReconcile`, which **fails closed**. Nothing fetched is reconciled.

## D5 so far, patches 275–278

- **275 — `sync_state`.** The column is opaque by §8's own comment, so the epoch goes in
  **verbatim**. **The app's cursor stopped being a cursor in patch 249** — high-water mark,
  not query bound. The verifier compares the CURSOR, not the row count. The cursor is kept
  out of any redacted paste (it is a date from the athlete's history) by putting it in
  `detail`, which is screen-only.
- **276 — `work_queue`.** `detail.failed` → `detail`/`failed`; `detail.noStreams` →
  `stream`/`done`. **Neither set is a retry queue** — both are terminal verdicts.
  `attempts: 1` is a floor. This importer PRUNES its own kinds, which §12.21 refused for
  notes — safe because the source is a preference array with no decode step.
- **277 — the trace account.** Six buckets that must sum to the total; **`unexplained` is
  the only line worth watching**. Device: 23 missing = 2 asked-nothing-there + 21 under
  500 m + 0 unexplained.
- **278 — `rejection`.** `strava.rejectedByRule` held a rendered sentence with every column
  inside it as text. `RejectionReceipt` carries them as fields; `ActivityStore.rejected` is
  now computed so `SettingsView` cannot tell. Migrated receipts carry
  `dateIsKnown == false` and NULLs; `rule` is honest because there has only ever been one.
  **3 receipts on the device.**
- **278c — a migration may lose the old SHAPE, not the DATA.** Both key migrations deleted
  the retired key whether or not the new blob landed. `persist()` returns a `Bool` and the
  removal is guarded. Caught before the rejection migration ran.

## The rules that keep costing when forgotten

- **A migration is history.** Vocabularies inside one are FROZEN literals, coupled to the
  Swift enums by test.
- **Strava ids are never primary keys** (§3.1).
- **The import is idempotent by lookup, not by luck.** It UPDATEs rather than skipping.
- **Each imported row gets its own SAVEPOINT.**
- **Write the §12 mapping before the importer.**
- **Anything that is data rather than state says `nonisolated` when it is written** — and
  **code that moves from an isolated home to a nonisolated one inherits nothing.**
  `a.km` is a MainActor computed property; `a.distance` beside it is stored and is not.
  That broke 278.
- **`Sub4Import` is `nonisolated` end to end.** Anything main-actor it needs must be
  computed by the CALLER and passed in.
- **Never put `try` inside `#expect` or `#require`** — hoist to a `let`. And `#expect`'s
  message is a `Comment?`: an interpolated literal converts, `"a" + "\(b)"` does not.
- **Sweep the BARE IDENTIFIER, then filter.** `\.rejected\b` finds reads and misses
  `rejected = []`.
- **`Self` in a default argument is covariant Self even on a `final class`.**
- **Never assert `Sub4Migrations.all.last == <a migration>`.**
- **A synthesised `init(from:)` does not use Swift default values.**
- **The repo's own tests police PROSE.** `gapsAreActionable` requires every recorded gap to
  cite `step ` or `ADR-`.

## Working directly in the repo (replaces the Cowork patch workflow)

Under Cowork, changes were shipped as zips of whole new files plus an anchored
`apply-NNN.py`, preflighted against a byte-exact copy via `SUB4_ROOT`, because the tooling
could not write into this repo. **All of that is gone.** Claude Code edits files in place
and git is the undo. Retired with it: the `SUB4_ROOT` preflight, the anchor-uniqueness
rules, "put the apply commands in ONE message only", the stale-staged-copy rule, and
`git --no-optional-locks status` (the `.git/index.lock` problem was a bridge artefact).

What survives, and matters more now that edits are direct:

- **Run the suite before building onto the phone.** ⌘R compiles the app target only, so
  test-target errors accumulate invisibly — 275, 276 and 277 all ran on the device while
  the suite had not compiled since 273. `./scripts/test.sh`.
- **Commit per logical change with the patch number in the subject** (`278c — guard the
  retired-key removal`). The patch numbering is the project's own history and the ADR and
  handoffs cite it — keep the sequence going rather than restarting.
- **Take a fresh protected snapshot before anything destructive.** See "Known open items".
- New Swift files: write them into `Sub4/` (the source folder at the repo root) and Xcode's
  synchronized folders pick them
  up. Never use Xcode's "Add Files"; never hand-edit `project.pbxproj` to add a source.

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
- **Six controls have been found reporting work they did not do** — patch 270's delete
  button, the verifier itself, and the match picker (below).
- **A method written in anticipation is not a feature.** `ProposalStore.remove` waited 45
  patches for a caller; `DetailStore.backfillRemaining` waited until 277.
- **An account beats a list.** Five counters can each be right while the set is missing a
  case; a residual cannot hide one.

## Next, in order

1. **THE MATCH PICKER DEFECT — confirmed on the device 2026-08-05, do this first.**
   See "Known open items". **The choice of fix is Bruno's.**
2. **D5, remaining slices** — `lifecycle_event` + `lifecycle_line` (export and disconnect
   receipts; not in UserDefaults at all and they persist nowhere today),
   `review_evidence_source`, and `correction` — for which **`commutes.json` is the natural
   first occupant**, because it already carries `decided` and so needs no reshape.
   `DataCorrections` is compile-time constants with no `authoredUTC` and can follow.
   **`content_revision` probably has no correct occupant** among the preference keys: the
   four backfill flags and three schema versions are build markers, not content hashes.
   Its real first occupant is likely the plan's content hash. **Settle before building.**
   **Four preference keys are staying** — `appearance.selected`, `discipline.selected`,
   `volume.unit`, `zones.window` describe the reader, not the training.
3. **D6** shadow parity — read both, compare in diagnostics, zero unexplained divergence.
   Where CTL is compared.
4. **D7** activate. `Sub4Launch.migrationFailureBlocksTheApp` flips to `true`.
5. **D8** stabilise one release window, then remove the JSON writers.

Phase 4A (Apple Health canonical) cannot start before D7's exit gate — see
`review-data-pool.md`.

## Known open items

- **THE MATCH PICKER OFFERS ACTIVITIES THE MATCHER WILL REFUSE — confirmed on device,
  2026-08-05 22:00.**
  `MatchPickerView.choiceSection` lists `activities(on: dayKey)` unfiltered, but
  `Matcher.resolve` builds its pool from `all.filter(\.isPlanEligible)` — and
  `Activity.isPlanEligible` returns `false` by `default:`, so a WALK is never eligible.
  Choosing the walk stored the override, the matcher could not find it in the pool, and the
  session fell through to the same branch as "explicitly nothing": **Week showed Not done
  and Sessions went 4/4 → 3/4, with nothing on screen saying why.**
  Worse since 272: the import DOES write the row, resolved through `activity_alias`. So the
  store says "the walk", `match_decision` says "the walk", and the screen says "not done" —
  and the verifier cannot see it, because it counts rows and the count is right.
  **Two fixes, and the codebase argues for the second.** (a) the picker lists only
  plan-eligible activities, extras greyed with a reason; (b) an explicit override WINS over
  `isPlanEligible` — which is patch 251's own argument, three lines above the walk case:
  *"the athlete's answer has to be able to win in BOTH directions."* (b) has consequences:
  the walk's distance and load would enter that session's adherence and effort figures.
  **Bruno's decision, not Claude's.**
- **The whole D4 round trip is proven on real data** (2026-08-05): override → `Match
  decisions: 1 new` → Back to automatic → `Reconciled: yes, match decisions removed: 1` →
  19 comparisons all agreed.
- **A red badge appeared on the Settings tab** at ~22:06 on 2026-08-05, between two
  imports, cause unknown. `needsAttention` is `!auth.isConnected ||
  activities.lastError != nil || StoreWriteJournal.hasUnsaved ||
  StoreReadJournal.hasUnreadable`. Check what it is before assuming.
- **The proposals import is unverified against real data until 2026-08-24.** The review
  still cannot be SENT — see `review-data-pool.md`.
- **The protected snapshot goes stale.** The one on the phone was taken by patch 247 at
  08:17 on 2026-08-05 and predates `commutes.json`, the bikes, the retired shoe,
  `match.decisions` and `strava.rejections` — while the import ledger cites it as that run's
  captured inputs. Take a fresh one before any destructive patch.
- **`work_queue` has a third state it cannot hold**: "never asked, under 500 m". No row is
  the honest answer; patch 277's account explains it instead.
- **`ActivityStore.load()` still has the two-`try?` shape** patch 273 fixed on the four
  authored stores. It is a cache and re-fetchable, which is why it was left.
- **Gear is closed.** `Naming unknown gear` reached **0**. **Refused is 0.**
- **`details.json` and `streams.json` are NOT on this phone.**
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
- The protected snapshot (patch 247) copies every legacy input before anything decodes it —
  1003 files, 14.3 MB.
