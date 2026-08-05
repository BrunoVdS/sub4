# Sub4 — next session handoff

Written 5 August 2026 at **patch 278c**, replacing the version written earlier
the same day at patch 271. That one described D4 as the next work and quoted
595 tests; both stopped being true about four hours later.

Everything here is verified on the device unless it says otherwise.

---

## 1. Where the rebuild actually is

| Stage | State |
|---|---|
| D0 Freeze & capture | **Done** — patch 246 (ADR §12.13) |
| D1 Foundation | Done |
| D2 Canonical schema | Done — 51 tables, 10 migrations |
| D3 Legacy importer | Done — `migration_run` reaches `verified` on real data |
| D4 User/plan cutover | **Done** — failable saves (264–266, 270) and the database half (272–274) |
| **D5 Activity cutover** | **In progress — 3 of 5 slices done.** 275 `sync_state`, 276 `work_queue`, 278 `rejection` |
| D6 Shadow parity | Not started |
| D7 Activate | Not started |
| D8 Stabilise & retire | Not started |

### What is in the database, on the phone

51 tables, **212,295 rows**, 37.3 MB, integrity ok, 0 orphaned rows, foreign
keys on, prepared at launch.

668 activities + aliases + source records · 11 gear + 479 references · 6 notes ·
580 weather · profile + 5 zones + 15 resting months · plan across 3 versions ·
645 traces with 192,954 samples · 668 details with 7,990 splits, 2,344 laps,
755 best efforts · **1 sync position · 2 stopped-asking verdicts · 3 refused
recordings**.

**Refused: 0.** `Naming unknown gear: 0`. **Unreadable stores: none.**

**`migration_run` reaches `verified` — 19 comparisons, all agreed.**

### The tables still empty

`correction`, `content_revision`, `lifecycle_event`, `lifecycle_line`,
`review_evidence_source` — and `match_decision` and the five review tables,
both legitimately: no override has ever been made, and no review has been run.

---

## 2. What tonight built

| Patch | |
|---|---|
| 272 | `match_decision`. The store had to learn a DATE before the import could exist |
| 272a | A recorded gap must cite a step or a finding. The repo's own test caught it |
| 273 | `StoreLoad` / `StoreReadJournal` — a store that could not be read must not look empty |
| 274 | **The reconciliation pass.** The importer had been additive-only since it was written |
| 275 | `sync_state`. The verifier compares the CURSOR, not the row count |
| 276 | `work_queue`. Neither set was a retry queue — both are terminal verdicts |
| 276a | The device said 2, not 23. A third state the table cannot hold |
| 277 | The trace account. Six buckets that must sum, and `unexplained` is the point |
| 278 | `rejection`. Prose became fields; 3 receipts migrated |
| 278a/b/c | Two lines the sweep missed, one `#expect` message, one migration fallback |

**676 tests in 67 suites**, from 595 at patch 271.

---

## 3. The rules that keep costing when forgotten

Every one of these cost a patch or a round trip tonight.

- **A migration is history.** Vocabularies inside one are FROZEN literals,
  coupled to the Swift enums by test. `work_queue`'s four states are the newest
  example — the coupling can only run one way, so the test asserts the enum
  still says what the schema was born saying.
- **Anything that is data rather than state says `nonisolated` when it is
  written.** And: **code that moves from an isolated home to a nonisolated one
  inherits nothing.** `rejectionLabel` read `a.km` freely on a main-actor class
  and could not on a `nonisolated struct` — `Activity` is a plain struct, so
  its STORED properties are nonisolated and its COMPUTED ones are not.
- **`Sub4Import` is `nonisolated` end to end.** Anything main-actor it needs
  must be computed by the CALLER and passed in. That is why 274's gate is a
  parameter rather than a lookup.
- **Never put `try` inside `#expect` or `#require`** — hoist to a `let`. And
  `#expect`'s message is a `Comment?`: an interpolated literal converts, `"a" +
  "\(b)"` does not.
- **Sweep the BARE IDENTIFIER, then filter.** `\.rejected\b` finds reads and
  misses `rejected = []`. That one line stopped patch 278 building.
- **Anchors: a 23-space parameter line is a substring of the 24-space one.**
  `verify` and `attempt` have identical parameter lists at different indents —
  include the `func` line. The guard caught it twice.
- **A synthesised `init(from:)` does not use Swift default values.**
- **Never assert `Sub4Migrations.all.last == …`.** The invariant is
  `all == all.sorted()`.
- **The repo's own tests police PROSE.** `gapsAreActionable` requires every
  recorded gap to cite `step ` or `ADR-`.

---

## 4. What to do next, in order

1. **D5's remaining slices.**
   - `lifecycle_event` + `lifecycle_line` — receipts for Export and
     Delete/disconnect. NOT in UserDefaults at all: those operations produce a
     receipt on screen that nothing keeps.
   - `review_evidence_source` — which sources a review's evidence drew on.
     Needs the review writer to record lineage.
   - **`correction` — `commutes.json` is the natural first occupant.** It
     already carries `decided`, so unlike the other three it needs no reshape.
     `DataCorrections` is compile-time constants with no `authoredUTC` and can
     follow.
   - **`content_revision` probably has no correct occupant among the
     preference keys.** The four backfill flags and three schema versions are
     build markers, not content hashes; forcing them in would misuse the table
     to empty a dictionary. Its real first occupant is likely the plan's
     content hash, which already exists and is what makes `Plan: unchanged`
     work. **Settle this before building it.**
   - **Four keys are STAYING.** `appearance.selected`, `discipline.selected`,
     `volume.unit`, `zones.window` describe the reader, not the training. D5 is
     "get the DATA out of UserDefaults", not "empty UserDefaults".
2. **D6 shadow parity** — read both, compare in diagnostics, zero unexplained
   divergence. **This is where CTL is compared**, because the same `PMC` can
   then run over both sides.
3. **D7 activate**, in the plan's slice order.
   `Sub4Launch.migrationFailureBlocksTheApp` flips to `true` here.
4. **D8** stabilise one release window, then remove the JSON writers.

Phase 4A cannot start before D7's exit gate — and see §6.

---

## 5. Dated items

- **24 August 2026** — first real monthly review. The write path is proven
  (269) and the rehearsal record it left was removed by 274. `ReviewDue` reads
  `proposals.json`, which is empty, so the date is clear. **But see §6.**
- **1 September 2026** — GitHub Actions allowance resets. CI unverified since
  the triggers changed; run it manually once.
- **Take a fresh protected snapshot.** The one on the phone was taken by patch
  247 at 08:17 on 5 August and predates `commutes.json`, the bikes, the retired
  shoe, `match.decisions` and `strava.rejections` — while the import ledger
  cites it as that run's captured inputs.

---

## 6. The finding that still matters most

**The monthly review cannot be sent at all.** `Review.payload()` builds nine
sections; five are Strava-derived and blocked by ADR-0002 §5.3/§5.10 —
coverage, flags, adherence, running volume, pace. `ReviewPayload.isUsable` is
`blocked.isEmpty`, `ReviewRequest.prompt` returns nil, and `ProposalStore.run`
throws. On 24 August the button produces the refusal, not a proposal.

That refusal is deliberate: a review whose adherence, volume and pace are all
withheld is not a review.

**The usable evidence pool today is three things** — the bundled plan, the
session notes, and the RPE/feel recorded against them.

**Phase 4A is what unblocks it**, by rebuilding volume, adherence, pace and
coverage on Apple Health figures.

**Bruno's standing item:** build the data pool used to analyse progress and
make changes to the plan. Sleep, fuel and liquid intake are authored or
Health-derived, so none of them is blocked. A note on 1 August already reads
*"Drank 750ml of water during the run"* — the data exists, in free text, where
nothing can count it.

---

## 7. Open items

- **`work_queue` has a third state it cannot hold** — "never asked, under
  500 m". `done` would claim work happened and `pending` would claim work is
  coming. No row is the honest answer; patch 277's account is where it is
  explained instead.
- **`ActivityStore.load()` still has the two-`try?` shape** patch 273 fixed on
  the four authored stores. It is a cache and re-fetchable, which is why it was
  left — but it is the same silent-empty.
- **The review UI feels sluggish** (Bruno, 5 Aug). Deferred until there is a
  real review to design against.
- **`details.json` and `streams.json` are NOT on this phone.**
- **The quarantine table was deliberately not built** (§12.9d). Identity
  detection found nothing on real data.

---

## 8. How this project works

- Patches are **zips**: whole new files, plus an anchored `apply-NNN.py` for
  edits to existing ones. Unzip at the repository root
  (`~/Documents/Developer/sub4/Sub4/`) and everything lands.
- **Every apply script reads `SUB4_ROOT` from the environment**, so it can be
  preflighted against a byte-exact copy of the repo before the zip is built.
  That preflight is why every patch from 272 on applied first time.
- **`device_stage_files` caches by path and does NOT re-fetch.** The "silent
  truncation" recorded earlier on 5 August was **stale staged copies** — the
  bridge is byte-exact. Always delete the staged directory first, then verify
  sizes against the device's own `wc -c`.
- **Run the suite BEFORE building onto the phone.** ⌘R compiles the app target
  only, so test-target errors accumulate invisibly — 275, 276 and 277 all ran
  on the device while the suite had not compiled since 273.
- Put the apply commands in **one** message. Running them twice trips the
  "already applied?" guard and reads as a failure; it happened with 273 and
  274.
- **Nothing that is not Swift source goes under `Sub4/Sub4/`.** Synchronized
  groups copy a stray `.py` into the app bundle. `tools/` and `docs/` live at
  the repository root for exactly this reason.
- `AppVersion.swift` ships in **every** numbered patch with the number bumped.
  Letter-suffixed fix-ups (272a, 278c) do not bump it — the script's own output
  is the receipt.
- Never use Xcode's "Add Files". A **new** file needs ⌘Q and reopen; an
  overwritten one does not.
- No git, and no writing into the repo through the device bridge. Reading is
  fine — but `git status` through the bridge creates `.git/index.lock` and the
  bridge cannot delete it. Use `git --no-optional-locks status`.
- Always give exact steps and say where on screen a thing is — **read the view
  first rather than guessing**.

Test command:

```bash
cd ~/Documents/Developer/sub4/Sub4
xcodebuild test -project Sub4.xcodeproj -scheme Sub4 \
  -destination 'id=8528BBD2-5C8C-4D51-94A2-87F34FA9B4BA' \
  2>&1 | tee ~/Downloads/sub4-tests.log | grep -E "Test run with|✘|warning:|error:|TEST"
```

**676 tests in 67 suites** at patch 278c.

---

## 9. What this project keeps re-learning

- **Read the code that produces the number, not the numbers either side of
  it.** Twice inside one patch tonight: 276's shape was predicted from key
  names, then its row count from arithmetic on two other counters. The line
  that settled both — `minStreamDistance = 500` — was nine lines from the one
  already being read.
- **Real data beats tests.** The ghost review was found by reading table counts
  after a run that had already passed 15 comparisons. `work_queue` wrote 2 rows
  where 23 were predicted.
- **A control that reports work it did not do is this project's recurring
  defect — five found so far.** Most recently patch 270's delete button (it
  dismissed the sheet and left four rows behind) and the verifier itself (it
  said "everything agreed" while not looking at the `review` table at all).
- **A method written in anticipation is not a feature.** `ProposalStore.remove`
  waited 45 patches for a caller; `DetailStore.backfillRemaining` waited until
  277.
- **A migration may lose the old SHAPE; it may not lose the DATA.** Both key
  migrations written tonight deleted the retired key whether or not the new one
  landed. Caught before the second one ran, while writing the instructions to
  install the build that would have run it.
- **An account beats a list.** Five counters can each be right while the set of
  them is missing a case; a residual that has to make the total add up cannot
  hide one.
