# SUB4 codebase modernization and feature-delivery plan

| | |
|---|---|
| **Status** | Execution companion. **Its early stages have shipped — see the note below.** |
| **Baseline read** | Source patch 334 working tree, 9 August 2026 — **historical** |
| **Owner and decider** | Bruno |
| **Purpose** | Turn the accepted database, Health, restructure and product roadmap into implementable slices |
| **Architecture source** | `docs/PLAN-post-database-strava-project-restructure.md` |
| **Persistence authority** | `docs/ADR-0003-database-contract.md` |
| **Source-transition authority** | `docs/ADR-0002-strava-retirement.md` and `docs/PLAN-cutover-v2.md` |

> **CURRENT STATE IS NOT IN THIS DOCUMENT — patch 406.**
>
> It was written against patch 334 and its opening stages describe work that has
> since shipped: D6c closed at 330, and D7's B0, B1, B2 and B3 landed at 342,
> 346, 358/377 and 383. Its A-stage items about "committing patch 334" are
> history.
>
> **`CLAUDE.md` §5 is the one place this project states what is true now.** This
> plan remains the authority for what comes NEXT — B4 onward, then Health, D8,
> the restructure and feature delivery. Where the two disagree about the present,
> §5 wins; where they disagree about the sequence, this document does.
>
> **Progress against this plan, at 406.** Stage A's database-shadow work is
> closed. D7 has run B0 through B3 and the app reads the plan, the athlete, the
> authored data and all 694 activities from SQLite on every launch, with a
> verified migration run over that data. 385 through 388 are not slices: they
> correct, mechanise, make operative and then repair the verifier's own
> accounting of how much of its agreement is evidence — the number B9's gate
> reads. **That accounting is now derived end to end and counted in three
> buckets**: every comparison names the store field its expectation came from,
> which fields the database feeds is resolved by asking each store, and a
> residual that reads no store is no longer counted as evidence — which is what
> made `isTrustworthyEvidence` capable of failing at B9 rather than only
> appearing to be. §12.130–§12.132.
>
> **B4 — details and traces — is one patch from its flip.** Its enumeration is
> `docs/D7-B4-GROUNDWORK.md`: the flip empties five verifier comparisons,
> Compare's slice 4 and two read-backs, and §12.125's rule is that the patch
> before a flip is the one that asks what the flip makes vacuous. 388 through
> 390 did that, and 389 extended the same accounting to the read-back roll-up,
> where two rows had been the database against itself since 346 and 382 with no
> way for the screen to say so. 391 through 393a were the Database screen,
> interleaved at Bruno's request.
>
> **394 built the machinery, switched it off, and took the measurement B4's
> plan called its one open question** — what reading 668 traces and 199,848
> samples costs in front of first paint. The device said **3.963 s, 94% of it
> the traces**, and that answer killed the design rather than confirming it
> (§12.139).
>
> **395 is the correction, and it is what a measurement is for.** Both families
> left the launch bootstrap — `fieldCount` back to 7, the launch back to
> 0.038 s — and `DetailStore` now reads for itself when it is constructed,
> which is after the first frame rather than in front of it. **396 is the flip**
> and waits on the other half of the comparison: nobody has ever measured what
> the 1,362 files cost, so 3.730 s is only a regression if the files are
> faster. §5.6 of `CLAUDE.md` carries the order.
>
> **B4 CLOSED AT 398.** 397 fixed the read the benchmark exposed — 668 queries
> became one ordered cursor and eight name-keyed passes over 199,848 rows became
> one positional pass — and 398 is the flip: two enum cases, with `DetailStore`
> consulting the switch rather than `Sub4Launch` feeding it. Five verifier
> comparisons stopped being evidence, which is what a slice landing looks like,
> and the roll-up is unaffected because 388–390 gave Compare's slice 4 and the
> two read-backs their own reads. §12.141, §12.142. **B5 — weather and gear —
> is next.**
>
> **399 MARKS SLICE 3.** Load parity's two varied inputs — the activities (381)
> and the traces (398) — are now the database's on both sides, so it proves the
> load engine is deterministic and not that the migration carried the data. It
> printed identically to the five slices that can still disagree; it now says
> which it is. Marked rather than rescued: the rescue changes what the slice
> means. §12.143.
>
> **THE NEXT TWO ARE NOT SLICES EITHER.** The five authored stores still have no
> restore path — §5.5 has called that the largest open risk while eleven patches
> went to B4 — and file protection is a security property applied with a
> silenced error and reported by a string literal. Both come before B5.
>
> **396 IS NOT A SLICE — it is the instrument.** Asking for that Release
> measurement found that `ReleaseGates.isInternalBuild` was `#if DEBUG`, so
> every diagnostic screen vanished in Release and **no device number this
> project has ever taken was a Release number**. The predicate now asks how the
> build was signed rather than how it was optimised, which is stricter; three
> copies of it existed, one inside the comment forbidding copies; and the
> distributed branch is testable and tested for the first time. §12.140.

## 1. Outcome

This plan takes SUB4 from its current database shadow state to a codebase that can safely
accept the planned feature expansions.

The order is deliberately strict:

```text
Finish database evidence
        ↓
Activate database reads (D7)
        ↓
Make Apple Health canonical and retire Strava
        ↓
Retire legacy JSON (D8)
        ↓
Restructure without behavior changes (R0-R15)
        ↓
Re-baseline correctness and product behavior
        ↓
Build load/manual/activity foundations
        ↓
Add product features in dependency order
```

Skipping forward would build new features on stores, source adapters and file locations that
are already scheduled to disappear.

## 2. Current position and immediate next work

Verified from the live repository at the patch-334 working tree:

- Database write-through is in place.
- D6c's eight shadow-parity slices are complete.
- The database can reproduce the app's current tab summaries and core derivations.
- Production still reads the legacy stores; D7 is not active.
- Apple Health canonical ingestion has not started.
- The phone was reinstalled and is rebuilding activity details and recordings within Strava's
  rate limits.
- A protected snapshot and shareable diagnostics now exist, but the first useful protected
  snapshot was taken only after the reinstall.
- The read-back roll-up planned as A2 has been implemented locally in
  `ReadBackRollUp.swift`, `ReadBacks.swift` and `ReadBackRollUpTests.swift`.
- Patch 334 and the current documentation work are not yet an accepted committed baseline.
- Patch 334 adds the new confidence-scale migration and tests so proposal confidence uses the
  same 1–5 contract as the product. This must be included in the next migration/read-back
  evidence rather than treated as an unrelated post-baseline change.
- Health M0 was completed on the real device on 6 August 2026. It is refreshed at cutover;
  it is not future first-time discovery work.

The next executable sequence is:

1. Let the current detail/recording backfill complete.
2. Export and retain one final patch-334 diagnostic showing the settled counts.
3. Take and verify a fresh protected snapshot after the backfill.
4. Re-run every read-back and shadow-parity slice and record zero unexplained differences.
5. Run and accept the patch-333/333a read-back roll-up on patch 334: every line looked,
   every expected empty state is named and there are zero unexplained differences.
6. Run the full suite and real-device verification for patch 334, then commit/tag the
   accepted evidence baseline.
7. Write D7 activation groundwork against that exact source.
8. Activate database reads in the approved slice order.

No restructure or new product feature begins before those steps.

## 3. The implementation contract for every slice

Every step below is delivered as a reviewable slice. A slice must contain:

1. **Groundwork:** the current behavior, exact call sites, invariants, expected device value,
   failure states and non-goals written before code.
2. **One behavioral purpose:** moves, refactors, schema changes and product changes are not
   combined unless one cannot be proven without the other.
3. **Database decision:** state `none`, `new additive migration`, or `data backfill`. Never
   edit a migration that has run.
4. **Automated evidence:** a negative control that fails when the new check is disconnected,
   plus focused unit/integration tests.
5. **Device evidence:** exact screens, values and failure/recovery states to exercise.
6. **Documentation:** update the ADR/context/manual section whose statement changed.
7. **Rollback point:** identify the preceding known-good commit and whether new data remains
   readable after rollback.
8. **Exit gate:** a binary statement that can be accepted or rejected.

An implementation-ready build card contains all of the following. A stage heading or feature
wish is not a substitute for this information:

1. Objective, athlete-visible result and explicit non-goals.
2. Current behavior and every production/test call site.
3. Prerequisites, decisions and upstream data guarantees.
4. Domain types, repository interfaces and mutable-state owner.
5. Data model, migration/backfill and compatibility behavior.
6. Field mapping, algorithms, units, time rules and provenance.
7. Success, empty, unavailable, denied, stale, partial, duplicate and failed states.
8. Concurrency boundary, retry/idempotency and cancellation behavior.
9. Automated unit/integration/architecture evidence and one negative control.
10. Real-device matrix and accepted figures/tolerances.
11. Rollout, shadow comparison, feature-flag removal and rollback.
12. Privacy, accessibility, localization, performance and diagnostics consequences.
13. ADR/context/manual changes and a binary exit gate.

The master plan owns ordering and acceptance. Slice groundwork owns volatile call-site and
line-number inventories so this file does not become stale after each patch.

Recommended patch shape:

```text
groundwork → pure extraction (if needed) → database/repository change
           → production wiring → UI → device verification → cleanup
```

A feature flag is used when old and new behavior need a shadow period. Flags have an owner,
default, removal condition and test; permanent forgotten flags are not acceptable.

## 4. Stage A — close the database shadow phase

### A1 - Finish and prove recovery

**Work**

1. Continue ordinary syncs until details, recordings and route coverage reach the expected
   settled state or every remaining exception has a named reason.
2. Verify rate-limit state is visible and does not masquerade as missing data.
3. Export the final diagnostics file and retain it outside the app container.
4. Take a new protected snapshot containing the recovered stores and verify its manifest,
   file count, protection and readable bytes.
5. Export authored data separately. A snapshot inside the app container is recovery input,
   not an off-device backup.

**Tests and device checks**

- Backlog counts persist across screen dismissal and relaunch.
- Missing, queued, excluded and unavailable records remain different states.
- Snapshot failure is visible and a zero-byte/partial copy cannot report success.

**Exit gate:** recovery is settled, the final diagnostic is retained off-device and a fresh
verified snapshot exists.

### A2 - Accept the implemented read-back roll-up

**Status:** implemented in patches 333/333a in the patch-334 working tree; not accepted until
tests and device evidence pass and the work is committed.

**Purpose:** turn nine individual read-backs into one durable pre-D7 answer without expanding
`DatabaseHealthView` back into an unsafe SwiftUI expression.

**Work**

1. Review `ReadBackRollUp`, `ReadBacks` and `ReadBackRollUpTests` against ADR-0003 §12.80.
2. Run the focused tests and complete suite; record the expected test count.
3. On the phone, press **Read everything back** after recovery has settled.
4. Require every category to have looked, every legitimate empty comparison to say why and
   zero unexplained differences.
5. Close and reopen the sheet and confirm the result survives for the launch.
6. Export diagnostics and confirm all individual lines and the summary are present.
7. Run a negative-control fixture whose mismatch makes the roll-up fail.
8. Commit the current patch-334 baseline only after the source, migrations, tests, ADR entry
   and device result agree.

**Database impact:** none unless a durable diagnostic history is explicitly approved. The
default is recomputable/current evidence, not a new user-data table.

**Exit gate:** patch 334 is committed with passing automated evidence and an exported
real-device result showing every required read-back looked and zero unexplained differences.

### A3 - Write the D7 activation groundwork

**Work**

1. Enumerate every production read of legacy JSON and every repository alternative.
2. Enumerate every launch path that can observe a missing/unverified database.
3. Record the exact D7 slice order and the files/call sites in each slice.
4. Define the activation ledger transaction and the condition that permits it.
5. Define the behavior when the database cannot open after activation.
6. Define how legacy files become read-only and how a rollback build can still use them.
7. Define the temporary-file-removal device rehearsal.
8. Re-read lifecycle/disconnect rules because their meaning changes when SQLite becomes the
   source of truth.

**Exit gate:** no production read or launch failure can switch ownership accidentally or
fall back to a misleading empty state.

## 5. Stage B — activate SQLite as the source of truth (D7)

D7 is implemented in the already approved sequence. Each slice switches reads only after its
repository result is proven against the legacy result.

### B0 - D7 implementation architecture

D7 changes persistence ownership without performing the later R0-R15 restructure. The least
risky implementation keeps the current observable store/view APIs temporarily and changes
where those stores are hydrated and where mutations commit:

```text
Sub4Launch opens and verifies SQLite
        ↓
Database bootstrap loads repository snapshots
        ↓
Existing observable stores publish database-backed values
        ↓
Existing features continue to observe the same store-shaped interfaces
        ↓
Mutations commit SQLite first; temporary JSON mirrors are diagnostic only
```

This deliberately postpones broad dependency injection and file movement to R12 and R3-R11.
It avoids combining a persistence cutover with a new object graph and new navigation/view
lifetimes.

**Required groundwork artifacts**

1. A call-site ledger with one row for every production read and write:

   ```text
   data family | current store/member | consumers | repository replacement
   hydration owner | mutation path | parity proof | D7 slice
   ```

2. A launch-state diagram covering fresh install, verified database, unverified database,
   failed open, corrupt database, interrupted migration and post-activation rollback build.
3. A `DatabaseBootstrapSnapshot` or equivalent source-neutral value whose field count and
   forwarding are asserted, avoiding a second hand-written whole-app load list.
4. One activation authority. The newest verified `migration_run` becomes `activated` inside
   a checked transaction; no preference or feature flag may independently claim activation.
5. One production persistence mode derived from that ledger, not from whether a database
   happens to open.
6. One fail-closed recovery screen after activation. It may offer retry, diagnostics,
   protected restore and export instructions; it may not construct empty legacy stores.

**Per-slice cutover pattern**

1. Freeze the legacy result and repository result using the existing round-trip/parity type.
2. Add database hydration behind the existing observable API.
3. Make writes database-first and surface a failed commit without publishing false success.
4. Run legacy and database reads in shadow for that slice.
5. Switch production selection only after zero unexplained differences.
6. Keep the legacy writer/read path available solely for the defined rollback window.
7. Record the device result, then move to the next slice.

**Database mutation policy during D7**

- User-authored changes are committed transactionally before the UI reports success.
- A post-activation JSON mirror failure is diagnostic; it does not undo a successful SQLite
  commit or tell the athlete the save failed.
- Sync data and its checkpoint/cursor advance in one transaction.
- Derived caches are invalidated by content revision after the source transaction commits.
- No migration body that has run is edited; activation schema changes are additive.
- Database-loaded empty history is accepted only where the repository result explicitly says
  the authoritative database contains no rows. A failed/unreadable load is a different state.

**D7 rollback contract**

- Before activation, rollback can return to the last committed legacy-authoritative build.
- After a database-only mutation exists, that older build cannot be called lossless. The plan
  records whether rollback is read-only, requires export, or is no longer supported.
- The temporary JSON mirror remains frozen/read-only once SQLite owns reads; it is not silently
  promoted after a database failure.
- The protected pre-activation snapshot and accepted build/commit are retained until D8's
  compatibility window closes.

### B1 - Plan and athlete profile

1. Switch active plan, weeks, sessions, fuel/warm-up and athlete profile/zone/resting reads to
   repositories.
2. Keep stable plan/session identity and active-version selection unchanged.
3. Test missing active plan, corrupt row, profile without optional fields and timezone rules.
4. Verify Plan, Week, fuel, warm-up and Settings on device.

**Implementation:** add one repository load result that distinguishes loaded, legitimate
empty/missing optional data and failed/corrupt data. Hydrate `PlanStore`, `AthleteStore` and
`ConstantsStore` through a single bootstrap owner without parsing `plan.json`, `athlete.json`
or `constants.json` at runtime. The bundled plan remains a seed/upgrade resource, not a
production read fallback. Profile/zone/FTP changes commit SQLite before observable state and
raise the profile/content revision used by load.

**Proof:** active plan/version/hash and every session/fuel/warm-up count match the accepted
read-back; HRmax/HRrest/FTP/zone optionality and month/timezone behavior match; removing the
legacy files leaves Plan/Week/Settings unchanged.

### B2 - Notes and authored decisions

1. Switch notes, RPE, match decisions, commute/corrections and rejections to database reads.
2. Prove save-then-read, relaunch persistence, failure visibility and orphan recovery.
3. Verify the data lost in the earlier reinstall cannot be silently represented as an empty
   successful import.

**Implementation:** repository transactions own note/RPE save, commute, matcher decision,
correction and rejection. Preserve plan-session UID/version and canonical activity links.
Publish observable changes only after commit; failed writes retain the edit for retry and name
the unsaved subject. Database empty is valid only when a trustworthy import/read proves both
sides empty; unavailable/corrupt is never converted to `[:]`.

**Proof:** create/edit/delete/restore where supported, relaunch, source disconnect/remap and
orphaned session/activity fixtures. Authored data survives source deletion and legacy-file
removal.

### B3 - Activity summaries

1. Switch canonical activity list, ordering, day grouping, source aliases and exclusions.
2. Reuse `ActivityRoster`; do not create a database-specific copy of filtering/dedup rules.
3. Verify Today, Week, Activities consumers, matching inputs and mixed-sport totals.

**Implementation:** `ActivityRepository` returns canonical domain activities plus source
aliases/provenance and exclusion state. The observable activity store no longer decodes
`activities.json` or treats a Strava ID as primary identity. Ordering uses start instant plus
stable ID; day grouping uses stored local/timezone contract. `ActivityRoster` remains the one
filter/dedup/cutoff implementation.

**Proof:** compare count, ordering, day keys, discipline, included/excluded, timezones and all
summary fields; run duplicate/canonical-alias fixtures and the Today/Week/matcher/tab parity
checks.

### B4 - Details and recordings

1. Switch detail, splits/laps, route metadata and recording samples.
2. Keep raw/canonical/display-resolution distinctions explicit.
3. Test missing detail, partial recording, excluded recording, unreadable timestamp and a
   source record that legitimately has no route.
4. Verify route, playback, charts and split tables on device.

**Implementation:** lazy repository loads replace detail/stream-directory reads. Distinguish
no source detail, pending fetch, intentionally excluded, partial/unreadable and complete.
Retain current raw/canonical/display-resolution meaning through D7; the timestamp-first Health
schema arrives separately in C0.1. Cache by canonical activity/content revision and cancel
loads when navigation changes.

**Proof:** detail/split/lap/effort field parity, sample count/series parity, route playback and
chart/scrub behavior. A 1.5-million-sample read stays off the main actor and within the
accepted benchmark.

### B5 - Weather and gear

1. Switch weather, gear lookup, retired gear and lifetime baseline reads.
2. Confirm weather source/provenance and missing-gear behavior remain visible.
3. Do not add new shoe-management behavior in this slice.

**Implementation:** database rows hydrate the existing weather/gear presentation. Weather is
joined by canonical activity ID with provider/fetch provenance; missing location, denied
consent and failed fetch remain different. Resolve source gear reference to canonical gear;
unknown gear stays visible rather than becoming a fabricated row. No local gear CRUD yet.

**Proof:** all current weather and all-gear rows round-trip, retired/bike/shoe cases render,
unknown gear is named and legacy weather/athlete files are unnecessary.

### B6 - Derived metrics

1. Feed matching, volume, zones, load, PMC and tab summaries from repository-backed inputs.
2. Re-run every parity result against the frozen pre-activation evidence.
3. Do not implement the new load model yet; D7 preserves current calculations.

**Implementation:** assemble one repository-backed derivation input snapshot containing
activities, details/recordings, athlete constants, notes/RPE, match/commute/correction and plan
state. Existing pure functions consume that snapshot; no calculation queries SQLite itself
and no database-specific duplicate formula is introduced. Cache revision includes every
input family.

**Proof:** matching, volume, pace, zones, load/PMC/monotony and Today/Week/Plan/Progress
summary parity against the frozen baseline, including longest-run and mixed-sport cases.

### B7 - Reviews and proposals

1. Switch review history, evidence, proposals and proposal changes/watch data.
2. Keep the current policy gate: a review that lacks permitted evidence remains blocked.
3. Test save/delete/relaunch, duplicate rehearsal timestamp behavior and deterministic
   proposal validation boundaries.

**Implementation:** hydrate review/evidence/proposal/change/watch through `ReviewRepository`.
Review creation writes the review graph atomically or leaves no partial proposal. Preserve
the current lineage policy; switching persistence does not make Strava evidence permitted.
Keep review identity versus plan-revision identity explicit and remove any rehearsal records
required by the accepted pre-review date.

**Proof:** empty legitimate pre-review state, save/delete/relaunch, duplicate time, invalid
proposal boundary, source purge retention and blocked-payload behavior.

### B8 - Sync, retry and operational state

1. Switch sync cursor/checkpoint, work queue, revisions and retry state.
2. Prove data write and cursor advance remain atomic.
3. Test interruption, late arrival, deletion, partial failure and restart.

**Implementation:** repository-owned sync state, work queue, revisions and migration/lifecycle
ledger replace operational `UserDefaults`/JSON reads. Claim queue work transactionally, reset
stale running work on launch according to policy, bound retries/backoff and record last error
without secrets. A source transaction commits rows, deletions, revision and cursor together.

**Proof:** kill before/after commit, duplicate enqueue, late detail, deletion, retry exhaustion,
background expiration, foreground catch-up and queue relaunch; no cursor can pass missing data.

### B9 - Activate and fail closed

1. Require the latest migration ledger run to be verified.
2. Set `Sub4Launch.migrationFailureBlocksTheApp` to its D7 behavior.
3. Mark activation transactionally.
4. Stop production fallback to JSON.
5. Make post-activation JSON mirror failures diagnostic rather than application-authoritative
   save failures.
6. Land the activation-coupled lifecycle/disconnect behavior required by the existing tests
   and plan; disconnect must still fail closed until Health reconciliation permits it.

**Implementation:** an additive migration/ledger rule enforces the single active migration
run if current schema cannot. Activation verifies the exact latest run and evidence version,
updates it transactionally, and makes launch derive persistence mode from the ledger. On a
failed database open after activation, `RootView` remains on recovery UI with retry,
diagnostics/restore guidance; it never constructs apparently valid empty stores.

**Negative control:** force an unverified ledger, database-open failure and removed legacy
files; none may reach normal content or activate.

### B10 - D7 device campaign

1. Cold launch and existing-database launch.
2. Launch with database unavailable/corrupt and verify the blocking recovery state.
3. Exercise every principal feature and compare the recorded baseline figures.
4. Temporarily move legacy JSON files out of their runtime paths and repeat the campaign.
5. Save authored data, relaunch and verify it comes from SQLite.
6. Run backup, export, restore and deletion previews without risking the only copy.

Record an acceptance table rather than a prose “looks good” result:

```text
screen/flow | baseline values/state | D7 values/state | result | evidence filename
```

Include Today, Week, Plan, Progress, Activities/list/detail/route/charts/splits, Commute,
weather, notes/RPE, matching, Review/history, Settings, Diagnostics, background refresh,
backup/export/restore and lifecycle previews. Exercise success, legitimate empty, stale,
partial, unavailable, denied/unknown, failure and recovery where applicable.

**D7 exit gate:** all production reads use SQLite, the app works without runtime JSON and a
database failure cannot look like valid empty history.

## 6. Stage C — make Apple Health canonical and retire Strava

Follow ADR-0002 and the M0-M8 sequence. This is a source replacement, not an extra importer.
The target is:

```text
Apple Health automatic source
        +
FIT/TCX/GPX recovery imports
        +
App-authored athlete, gear and activity decisions
        ↓
Source records and raw evidence in SQLite
        ↓
Canonical activity projection
        ↓
Local details, splits, load, weather, matching and Review
```

Apple Health is not a drop-in Strava response. The source transition must replace every
Strava-provided field and every Strava-derived feature deliberately.

### C0 / Health M0 - Refresh the completed coverage measurement

**Status:** the first real-device measurement is complete. `PLAN-cutover-v2.md` §3 is the
authority; this step refreshes it immediately before permanent implementation/cutover.

The 6 August 2026 result was:

- Health: 711 sessions across 323 training days.
- App/Strava: 669 activities across 323 days.
- 320 days in both sources.
- Three app-only days: 2026-05-23, 2026-05-29 and 2026-06-07.
- 53 Health sessions written by Strava alone.
- Of those 53, five had a route, none had a varying HR series, 42 had distance and nine had
  neither useful route, distance nor HR detail.
- The app had 16 strength sessions while Health had eight; day-level coverage hid the eight
  missing sessions.

**Work**

1. Re-run the read-only diagnostic against the final pre-cutover period.
2. Record workout UUID, source/device, source revision, type, start/end, duration, distance,
   HR sample count/range, route count, events and sport-specific quantities.
3. Recheck run, ride, swim, strength, paused, edited, delayed, deleted, indoor and
   third-party-device cases.
4. Name every missing or degraded historical activity and its recovery source: original FIT,
   TCX, GPX, Hevy/API/manual record or accepted unavailable.
5. Verify future Hevy workouts write to Apple Health. Historical Hevy gaps need separate
   recovery because enabling Health sync is not retroactive.

**Exit gate:** the refreshed report is exported and every gap has an accepted recovery or
explicit degraded-history decision.

### C0.1 - Required source-neutral storage amendments

The current `recording_sample` model is a Strava-shaped, distance-aligned display stream. It
requires cumulative distance and assumes HR, speed, altitude, grade, power and coordinates
share an ordinal. Health quantities are independent timestamped series and routes are a
separate series. Do not align them by inventing values.

Additive migrations must define authoritative raw source storage. Exact names are confirmed
in slice groundwork, but the responsibilities are fixed:

#### `source_checkpoint`

- account/source/query kind;
- opaque Health anchor bytes or an explicitly versioned reversible encoding;
- last committed sync and result;
- unique per account/source/query kind.

`sync_state.cursor` may be extended instead only if its text contract can preserve and
round-trip the opaque anchor without ambiguity. The anchor advances in the same transaction
as the source rows it represents.

#### `activity_quantity_sample`

- source-record/activity association;
- quantity type;
- start/end UTC;
- canonical SI value and unit vocabulary;
- source revision/device;
- measured, estimated, imported or derived provenance;
- stable external sample identifier where available.

#### `activity_route` and `activity_route_point`

- route/source/activity identity and ingestion/update state;
- timestamped latitude/longitude;
- altitude, speed and horizontal/vertical accuracy when present;
- source ordinal;
- raw route retained separately from display/downsample cache.

#### `activity_event`

- pause, resume, lap, segment, marker and supported multisport transition;
- start/end UTC;
- source metadata and ordinal.

#### source-field/projection provenance

`activity_source_record` currently identifies an arrival but does not retain every source's
field values. The source transition must preserve enough source evidence to rebuild and
explain the canonical projection. Choose and document either versioned source payload rows
or typed source-value rows; do not overwrite one source with another and call the survivor
canonical without lineage.

The existing `recording`/`recording_sample` may remain as a revision-keyed display cache built
from raw timestamped evidence. It is not the Health authority.

### C0.2 - Canonical activity construction contract

Before ingestion, define these policies in ADR groundwork:

1. Source-neutral sport mapping and unknown-type behavior.
2. Default title when the source provides none; never claim it came from the device.
3. Recorded, active, moving and elapsed time definitions by sport.
4. Pause/resume-event priority and timestamped distance/speed fallback.
5. Zero-distance behavior for strength, yoga and stationary sessions.
6. UTC, local time, timezone identifier and offset acquisition/fallback.
7. Indoor/trainer metadata and unknown state; unknown is not outdoor.
8. Measured versus estimated power, cadence, energy and elevation.
9. Summary derivation: distance, elevation gain, avg/max HR, avg/max power/cadence and max
   speed.
10. Field-level source priority and the rule for replacing a thin summary with better data.
11. Revision/content hash and downstream invalidation.
12. Data-quality result for every feature: available, partial, derived, estimated, missing or
   failed.

### C1 / Health M1 - Source registration, authorization and durable workout ingestion

1. Register the Apple Health source/account without using a Health UUID as a canonical ID.
2. Inventory the least-privilege read types and generate accurate purpose text/disclosures.
3. Register observer queries during the application launch path early enough for background
   delivery.
4. On notification, execute anchored queries for actual additions and deletions.
5. Persist source rows, aliases, deletions, content revisions and the new anchor atomically.
6. Make every write idempotent by source/account/external identity.
7. Add foreground catch-up, durable work queue, bounded retry/backoff and cancellation.
8. Preserve source revision, device, metadata and raw workout statistics.
9. Distinguish never asked, unavailable, denied/unknown, no data, failed, stale, partial and
   complete. Health read authorization cannot always distinguish denial from no data, so the
   UI must not claim more than the API proves.
10. Test kill/relaunch between query and commit, duplicate delivery, update, deletion, anchor
    corruption and a background notification whose work cannot finish.

**Exit gate:** new, changed and deleted Health workouts reach source tables exactly once and
the checkpoint never advances past uncommitted data.

### C2 / Health M2 - Quantities, condensed samples, routes and events

1. Ingest workout-scoped heart rate, distance, running/cycling speed, cycling power, running
   power, cycling cadence, active energy, swimming distance and supported swim metrics.
2. Keep original timestamps, units, source/device and provenance.
3. Detect condensed quantity series and expand them with the Health quantity-series query.
4. Query routes separately, because a route can arrive or change after its workout.
5. Queue missing routes as pending enrichment; do not permanently record “no route” after one
   early empty query.
6. Ingest route timestamp, coordinate, altitude, speed and accuracy; retain raw points and
   build a separate display cache.
7. Ingest workout activities/events for pause, resume, lap, segment, marker and multisport
   transitions when present.
8. Validate out-of-order/batched samples, large routes, thin third-party summaries, missing
   types, route updates, interruption and delete/re-add.

**Exit gate:** representative run, ride, swim and strength sessions can be reconstructed from
stored Health evidence after the device query is no longer available to the test.

### C3 / Health M3 - Local detail and derivation engines

Build one source-neutral derivation pipeline:

1. Moving/active time: source events first; integrate timestamped evidence as fallback;
   recorder duration remains separately labelled.
2. Route processing: accuracy rejection, smoothing, cumulative distance, altitude/elevation,
   grade, start coordinate and playback cache.
3. Kilometre splits: derive from timestamped distance; preserve explicit laps separately.
4. Laps/intervals: use source events when available; provide a documented detector only when
   explicit structure is absent.
5. Pool swim: use swim samples/length metadata when present; show limitations otherwise.
6. Best efforts: calculate local 400 m/1 km/5 km/10 km and accepted distances through a
   tested sliding-window algorithm.
7. Canonical detail: calories, description overlay, cadence, power, device, route, splits,
   efforts and laps with per-field quality/provenance.
8. Rebuild volume, matching, adherence, pace and coverage from canonical activity inputs.

Exact Strava segments, achievements, leaderboards and social semantics are not replicated.
Local personal bests are a new SUB4 calculation and must say so.

**Exit gate:** activity history/detail, routes, charts, splits and the accepted local-best
feature work offline from Strava and explain every absent or derived field.

### C4 / Health M4 - Reconcile sources and duplicates

1. Generate candidates using account, sport, UTC/local time, duration, distance, route and
   source/device metadata.
2. Define a versioned confidence score and high-confidence auto-merge threshold from fixtures.
3. Prefer evidence field by field; a detailed FIT/Watch record must not be replaced by a thin
   Strava-written Health summary merely because it arrived later.
4. Route ambiguous and conflicting candidates to a reversible review decision.
5. Add every source record/alias to one canonical activity so notes, corrections, matches,
   weather and reviews keep their links.
6. Preserve merge/unmerge audit history and recompute the canonical projection.
7. Handle one source deleting its record while another source still proves the activity.
8. Prove replay, merge and unmerge are idempotent and never delete raw source evidence.

**Exit gate:** all known duplicate shapes resolve deterministically or await explicit review,
and authored links survive merge/unmerge.

### C5 / Health M5 - FIT/TCX/GPX and historical recovery

Use FIT as the high-fidelity recovery format, TCX as secondary and GPX as route/time-only
fallback.

1. Add document selection and copy the selected file into a bounded import workspace.
2. Parse into source records without touching canonical rows during preview.
3. Validate timestamps, sport, units, duration, GPS, HR, power/cadence, laps/events and device
   metadata according to format capability.
4. Show duplicate/merge candidates and field coverage before commit.
5. Commit source evidence, aliases, canonical projection, audit result and receipt atomically.
6. Preserve file hash, original filename, format/version and warnings; do not retain the
   original file unless the lifecycle policy explicitly says so.
7. Support safe retry; a failed or cancelled preview writes no training history.
8. Use available originals to recover the three app-only days, the 53 degraded summaries and
   missing strength sessions. Accept that absent original evidence cannot be reconstructed.

Manual recovery may create only fields accepted by the manual-activity ADR. It must never
present hand-entered HR, power, distance or calories as device-measured.

**Exit gate:** a representative FIT imports with full available detail, TCX and GPX degrade
honestly, duplicate import is idempotent and recovery results are exported.

### C6 / Health M6 - Rebuild app-owned data and every dependent feature

#### Athlete configuration

- Make HRmax, HRrest, zones, sex/model coefficient and cycling FTP athlete-owned/versioned.
- Treat Health's estimated FTP as a suggestion unless explicitly accepted.
- Recalculate affected derived data with the configuration revision; never rewrite history
  without retaining the calculation/configuration version.

#### Gear and activity metadata

- Preserve permitted shoe/bike identity and lifetime baseline.
- Build local defaults, per-activity assignment, retirement and history.
- Store local title/description, indoor/trainer, commute, exclusion and manual corrections as
  authored overlays, not source rewrites.
- Re-key current commute decisions and authored records to canonical activity IDs.

#### Load, strain and fatigue

- Feed current TRIMP/load from Health/import HR samples, with an explicit average-HR fallback.
- Use power only where measured provenance and accepted FTP exist.
- Rebuild CTL/ATL/TSB only for parity during source transition; the later adaptation/burden
  redesign remains Stage H.
- Invalidate load when source, merge, exclusion, profile or FTP changes.

#### Weather

- Use canonical start time/location and re-key retained provider results to canonical IDs.
- If route/location is absent, show unavailable or request a manual location; never guess.

#### Monthly Review

- Rebuild coverage, adherence, volume, pace and load evidence from Health/import/app-authored
  data.
- Include minimized provenance and coverage so missing evidence is visible.
- Purge old Strava evidence while retaining permitted verdict/proposal history as decided in
  ADR-0002.

#### Plan matching and product screens

- Reuse the current matcher over canonical activities and remapped decisions.
- Verify Today, Week, Plan, Progress, Activities, Activity Detail, Commute, weather, gear,
  matching, Review and background refresh feature by feature.

**Exit gate:** every current feature has a named source-neutral input and works or degrades
honestly when route, HR, power, gear or metadata is unavailable.

### C7 / Health M7 - Shadow evaluation and disconnected rehearsal

1. Run Health/import and Strava adapters together for an approved observation window without
   allowing both to create duplicate canonical activities.
2. Compare source coverage, selected canonical fields, routes, summaries, details, matches,
   load, weather eligibility and Review evidence.
3. Include outdoor/indoor run, ride, pool/open-water swim, strength, paused workout,
   third-party writer, delayed route, edit and deletion.
4. Separate explained provider differences from unexplained product differences.
5. Exercise Settings states for Health access, last successful ingestion, pending enrichment,
   failed work, duplicate review and file import.
6. Stop Strava network access in a rehearsal build and exercise every principal feature.
7. Complete rollback rehearsal while credentials and pre-purge evidence still exist.

**Exit gate:** the disconnected rehearsal passes, all unexplained differences are zero and
accepted provider limitations are visible in the product/manual.

### C8 / Health M8 - Activate Health, revoke and purge Strava

1. Verify a protected backup and complete personal-data export first.
2. Activate Health/import/app-authored source priority transactionally.
3. Stop foreground/background Strava synchronization and cancel pending Strava work.
4. Verify every principal screen offline from Strava before destructive cleanup.
5. Revoke the OAuth token remotely and record success/failure.
6. Delete tokens/API credentials locally only with checked status.
7. Purge policy-restricted Strava source rows and derived evidence in the documented table
   order; fail closed on any unknown lineage.
8. Preserve/remap authored notes, matches, commute/exclusion/correction decisions and retained
   verdict/proposal records according to ADR-0002.
9. Remove Strava settings, status, rate-limit, OAuth, endpoint and background entry points.
10. Issue a lifecycle receipt naming removed, retained, failed and not-applicable categories.
11. Search the source/binary configuration and run a network-negative test proving the final
    build makes no Strava request.

**Unavoidable accepted limitations**

- Exact Strava segments, achievements and social data disappear.
- The 53 summary-only historical sessions remain degraded unless original files are recovered.
- The three missing days and historical strength gaps disappear unless another source or
  permitted manual record recovers them.
- Titles, descriptions, device details and gear assignments that exist nowhere else cannot be
  invented.
- Some Health writers omit routes, events, quantities or metadata; every consumer needs a
  partial-data state.

**Health/Strava exit gate:** Health and supported imports cover the accepted product promise,
all retained data has permitted provenance, historical limitations are named, and no active
Strava code, credential, scheduled work or network path remains.

### C9 - Feature replacement and independence matrix

| Current/planned capability | Replacement after Strava | Expected result |
|---|---|---|
| Activity history/basic detail | Canonical Health/import summary | Full when summary exists |
| Route/playback | Health route or FIT/TCX route | Full when route exists; honest partial otherwise |
| HR zones/TRIMP | Health/import HR plus athlete-owned zones | Full with samples; documented fallback |
| Power load | Measured source power plus athlete-owned FTP | Full only with trustworthy provenance |
| Splits/laps/intervals | Source events plus local derivation | Full or derived according to evidence |
| Personal bests | Local versioned best-effort engine | Available; not Strava achievements/segments |
| Matching/adherence | Existing matcher over canonical activities | Full |
| Weather | Canonical start time/location | Full where location/time exist |
| Gear | App-owned gear, baseline and assignment | Full after J2; minimal retention before it |
| Commute | Existing authored decisions remapped to canonical IDs | Full |
| Monthly Review | Rebuilt permitted canonical evidence | Full after C6 |
| Background sync | Health observer/anchor plus work queue | Full within iOS delivery limits |
| Plan display, notes/RPE, fuel/warm-up, WorkoutKit | Already plan/authored-owned | Not source-dependent |
| Plan builder, Calendar, exports, intake, sleep | App/Apple platform-owned | Not dependent on Strava |
| iPad presentation | Same domain/repositories; explicit device sync limits | Not dependent on Strava |
| Strava social/segments/leaderboards | No local equivalent in scope | Removed |

## 7. Stage D — retire legacy persistence (D8)

### D0 - Decide the compatibility contract

Before deletion, record:

1. Oldest SUB4 app/schema version allowed to upgrade directly.
2. Number of accepted releases or date through which the legacy importer remains.
3. Whether a post-D7 rollback build is read-only, export-assisted or unsupported after the
   first database-only mutation.
4. Exact protected backup/export required before removing the compatibility path.
5. Owner and removal condition for every retained legacy reader.

### D1 - Build the executable legacy inventory

Produce one checked manifest with:

```text
legacy file/key | current reader | current writer | database destination
upgrade needed from | removal release | retained reason | focused test
```

Include application-support JSON, detail/stream directories, domain `UserDefaults`, Keychain
credentials and old snapshot/import paths. Classify `plan.json`, generated JSON exports and
fixtures as seed/interchange/test data rather than runtime authority.

### D2 - Remove writers, then readers

1. Hold the agreed stable release window after D7 and Health activation.
2. Confirm no database-only mutation would be lost by installing the rollback build.
3. Remove production JSON writers one data family at a time and prove SQLite save/relaunch.
4. Remove JSON readers not required by the supported upgrade path.
5. Isolate retained readers under `Data/Upgrade/LegacyJSON`; they cannot be callable as a
   runtime fallback after launch.
6. Remove obsolete domain `UserDefaults` keys while retaining true reader preferences and
   migration markers still required by the supported floor.
7. Remove write-failure UI/journals whose only purpose was authoritative JSON, retaining
   equivalent database failure visibility.
8. Update backup/export/delete inventories and lifecycle receipts after every removal.

### D3 - Compatibility and removal tests

- Clean install from an empty container.
- Supported oldest-version fixture upgrades exactly once.
- Current database opens without touching legacy inputs.
- Corrupt/partial/unsupported legacy data gets a named recovery/refusal, never empty success.
- Repeated upgrade is idempotent.
- Database backup/export/restore remains valid after writers disappear.
- A source-tree check proves no production legacy reader exists outside the upgrade folder.
- A sunset test fails when the declared removal release arrives while compatibility code is
  still active.

**D8 exit gate:** no authoritative runtime JSON remains and every retained compatibility
reader has a tested reason, minimum input version, owner and removal condition.

## 8. Stage E — execute the behavior-neutral restructure

Use `docs/PLAN-post-database-strava-project-restructure.md` R0-R15 as the source of detail.
This stage does not add features or change calculations.

The restructuring document is already the most implementation-ready part of this program.
Do not duplicate its R0-R15 detail here. The artifacts that still have to be produced at the
post-D8 baseline are:

1. Bruno's acceptance or amendment of the 21 decisions in its §24.
2. Baseline commit, app patch, schema/migration count, test count and device figures.
3. Complete source/test/resource disposition manifest generated from the source that actually
   survives D8.
4. `.shared`/mutable-state ownership inventory and direct framework/filesystem/network access
   inventory.
5. Architecture-check implementation plus named transitional exceptions and removal stage.
6. Exact move batches from the manifest; today's candidate table is guidance, not authority.
7. Written adopt/defer decision for the optional `Sub4Domain` module.

The manifest cannot be frozen before Health activation and D8 because those stages add,
reshape and delete source families. Generating it then is evidence gathering, not postponed
architecture.

Implementation batches:

1. **E0:** accept the architecture decisions and tag the post-migration baseline.
2. **E1:** inventory every surviving source/test/resource and assign one owner.
3. **E2:** install architecture, resource and baseline checks before moves.
4. **E3:** create the physical App/Domain/Data/Features/DesignSystem/Platform/Resources tree.
5. **E4:** move DesignSystem leaf UI.
6. **E5:** move pure Domain code.
7. **E6:** move database repositories, migrations, verification and supported upgrades.
8. **E7:** move Health/weather source adapters.
9. **E8:** move Platform services.
10. **E9:** move features one at a time.
11. **E10:** move App composition and resources; verify target membership and bundle paths.
12. **E11:** split mixed-responsibility files without changing behavior.
13. **E12:** introduce dependency injection only at selected seams.
14. **E13:** decide whether the proven pure Domain boundary earns one module.
15. **E14:** update documentation/tooling and remove stale architecture descriptions.
16. **E15:** run the complete automated and device verification campaign and tag the result.

Each move batch gets its own commit. A failing batch is reverted as a batch; fixes are not
piled across multiple unverified moves.

**Restructure exit gate:** the R15 definition of done passes with no unexplained behavior or
data difference.

## 9. Stage F — re-baseline before feature growth

### F1 - Fresh peer review

1. Re-run code architecture, data safety, privacy, concurrency, numerical correctness,
   performance, accessibility and UX reviews against the restructured source.
2. Reproduce every carried finding and close stale premises.
3. Convert surviving P0/P1 findings into regression-tested slices.
4. Verify onboarding, recovery, lifecycle, Settings/Diagnostics separation and release gates.

Use one review record shape so a report becomes executable work:

```text
id | area | severity | current evidence | reproduction | affected feature/data
accepted decision | dependency | regression test | rollback | owner | target stage
```

Review at least:

- database migration/integrity/backup and destructive lifecycle behavior;
- source provenance, duplicate/reconciliation and partial-data honesty;
- actor ownership, cancellation and background task completion;
- calculation correctness, units, clocks/timezones and invalidation;
- launch/onboarding, permissions, offline/recovery and no-source/demo states;
- privacy manifest, Health/Calendar/export disclosure and redacted diagnostics;
- VoiceOver, Dynamic Type, contrast, touch targets, Reduce Motion and chart summaries;
- maximum-history performance, route memory, database query plans and SwiftUI body depth;
- iPhone/iPad navigation, empty/error states and consumer versus developer settings.

### F2 - Recover decisions and write the required ADRs

1. Recover the detailed load implementation plan into active version control.
2. Write the manual-entry ADR separating plan creation from completed-activity entry.
3. Accept the living-manual source/rendering decision.
4. Accept Calendar ownership, export formats, sleep informative-only behavior and planned
   versus consumed intake semantics.

The ADR set is complete only when it answers:

1. Planned-session creation/editing versus manual completed-activity entry and which measured
   fields an athlete may author.
2. Adaptation/burden formula, eligibility, required physiology inputs, versioning and removal
   of ratio-derived freshness vocabulary.
3. Modular Markdown manual source, renderer/generator, version/link validation and ownership.
4. One-way managed Calendar publication, dedicated calendar ownership, permission level and
   conflict/recovery behavior.
5. PDF/ICS/CSV/versioned JSON plan-export scope and schema ownership.
6. Sleep read-only/informative-first boundary and the separate evidence required before it may
   affect training advice.
7. Planned versus consumed intake, units, Health read/write boundary and missing-log meaning.
8. iPad local-only versus cross-device state and single-window versus multi-window support.

### F3 - Install shared feature foundations

1. Add stable feature/navigation identifiers and deep-link routing.
2. Add reusable provenance, data-quality, stale/error and target/recorded presentation.
3. Add audit-history primitives for reversible user decisions.
4. Add revision-based invalidation for derived calculations and caches.
5. Add the manual manifest, anchors and feature-to-help linking.

**Required shared contracts**

- `FeatureID`/`NavigationDestination`: stable, Codable deep-link destinations independent of
  dates and display strings.
- `ValueProvenance`: Health measured, imported measured, app-authored, corrected, estimated,
  derived and unknown, with source/device where permitted.
- `DataAvailability`: available, partial, empty, never requested, denied/unknown, unavailable,
  stale and failed with last successful update.
- `ActivityEligibility`: included/excluded plus reason, decision revision and downstream use.
- `AuditEvent`: subject, action, before/after, actor, time, reason and undo relationship.
- `ContentRevision`: entity/data/configuration/calculation versions used by caches.
- `InvalidationRequest`: durable subject/scope/reason/state/attempts; coalesces safely and
  survives termination.
- `TargetRecordedPresentation`: the single vocabulary and formatting contract for target,
  recorded, matched and unavailable values.
- `HelpAnchor`: stable feature-to-manual section mapping checked at build time.

Concrete implementations are supplied from App composition. Domain consumers depend on the
smallest question they need; features do not construct database, Health or export clients.

**Exit gate:** features can be added without inventing persistence, provenance, audit,
invalidation or documentation behavior independently.

## 10. Stage G — correctness and Activities foundation

### G1 - Durable per-activity exclusion

1. Add a dedicated additive `activity_decision` schema and repository for
   included/excluded-faulty decisions. Do not disguise this as an unrelated generic field
   correction.
2. Seed existing compile-time ignored activities without changing current output.
3. Centralize exclusion at the canonical query/eligibility boundary.
4. Add consequence preview, exclude, restore, history and Diagnostics visibility.
5. Invalidate matches, totals, load, gear and route aggregates consistently.
6. Remove compile-time ID exceptions after parity proves the migration.

Minimum row contract:

```text
id | accountID | activityID | kind | state | reason | note
createdUTC | updatedUTC | actor | revision | supersedesID
```

- Raw activity/source/route/sample rows remain untouched.
- A restore creates auditable state/history; it is not deletion of the earlier decision.
- `ActivityEligibility` is computed once and consumed by matching, totals, load, gear,
  heatmap and Review.
- Consequence preview names every affected derived output before commit.
- The decision transaction writes its audit event and durable invalidation request together.

```text
activity decision
  → matching and plan/adherence
  → day/weekly totals
  → load and adaptation/burden caches
  → gear wear
  → heatmap aggregation
  → Review evidence
```

Tests cover seed parity, exclude/restore/relaunch, repeated action, invalidation interruption,
merged activities, deleted source record and all downstream consumers.

### G2 - Repair shared semantics and states

1. Standardize Target, Recorded and Matched labels.
2. Replace mixed-sport kilometre totals with sport breakouts/duration/count where appropriate.
3. Introduce one `PlanPhase` and shared loading/stale/error states.
4. Correct adherence/timeline naming and expose last-updated data.

Write the vocabulary table before UI edits:

```text
term | definition | valid inputs | missing/partial form | screens | manual anchor
```

One shared implementation formats sport-aware totals: run/ride/swim distances are not added
into one kilometre number; strength and mixed blocks use duration/count where that is the
honest comparison. `PlanPhase`, stale/error/loading and target/recorded/matched terms are
tested once and reused.

### G3 - Build the Activities library

1. Add list/calendar/search and sport/date/source/data-quality filters.
2. Add source-aware detail navigation.
3. Add merge/unmerge review and audit history.
4. Productize FIT/TCX/GPX preview/recovery.
5. Add manual completed-activity entry only if its ADR is accepted.

**Query and navigation contract**

- Repository query supports bounded pagination, deterministic start-time/id ordering and
  filters for date, sport, source, included/excluded, route, HR, power, data quality and
  unresolved duplicates.
- Search covers local title/description and permitted metadata without loading every route or
  sample.
- List/calendar views fetch summaries only; detail loads source evidence and heavy series on
  demand.
- Every row can explain source, merge state, available detail and exclusion.
- Merge/unmerge and import preview are routed through audit/invalidation foundations.
- Maximum-history tests cover query plan/index use, cancellation and scroll memory.

### G4 - First run, source setup and recovery

Build an explicit launch/setup state machine after D7/Health ownership is stable:

```text
opening database
  → recovery required OR database ready
  → profile/plan ready OR setup required
  → Health never requested / granted-like / unavailable / partial
  → initial ingestion progress OR import/no-source/demo choice
  → normal app
```

1. Never request Health before explaining the value and required data.
2. Show initial ingestion progress, pending enrichment and safe interruption/relaunch.
3. Support Health unavailable/no data, import-only and a clearly labelled demo/no-source mode
   if accepted.
4. Recovery offers retry, protected restore, import/export guidance and diagnostics without
   requiring reinstall.
5. Separate empty training history from failed/unreadable persistence or denied/unknown Health.
6. Test every transition, relaunch point, permission change and late data arrival.

### G5 - Consumer Settings, Diagnostics and support evidence

1. Keep athlete-facing profile, sources, gear, units, privacy/export/delete and app help in
   Settings.
2. Put database health, queues, parity, raw coverage, migration ledger and developer controls
   behind Advanced Diagnostics and external-build policy.
3. Add a redacted support bundle with app/schema/version, feature states and bounded errors;
   exclude tokens, API keys, raw routes, private notes and full Health samples.
4. Every control names effect, last result and recovery; an action is not proven by the button
   being tappable.
5. Verify source disclosures, consent revocation guidance and export/delete consequences.

### G6 - Cross-feature product readiness

1. Remove remaining hard-coded athlete/date/sex/zone/FTP/commute assumptions into profile,
   plan or audited decisions.
2. Add a String Catalog, localized dates/numbers/units/plurals and metric/imperial display
   choice while retaining canonical SI storage.
3. Run pseudo-localized and right-to-left layouts where supported.
4. Complete VoiceOver labels/order/actions, Dynamic Type, contrast, target size, Reduce Motion,
   keyboard/pointer and chart textual summaries.
5. Make Progress/Activities heavy sections lazy and cancellable; cache by revision and profile
   maximum retained history before external release.
6. Reassess minimum OS/device support from actual Health, WorkoutKit, EventKit and navigation
   API needs rather than an inherited deployment target.

**Exit gate:** all activity evidence can be found, explained, corrected or excluded without
destroying a source record; setup/recovery and consumer settings are usable without developer
knowledge; shared accessibility/localization/performance foundations are active.

## 11. Stage H — implement the load/strain redesign

### H0 - Recover and accept the mathematical specification

The repository copy of `docs/context/load-model-research.md` is evidence, not a complete
implementation. Recover `load-model-implementation-plan.md` from the former Triathlon
document set or reconstruct it into version control before changing calculations.

The accepted specification must state:

1. Adaptation input formula and units.
2. Burden input formula and units.
3. Per-HR-sample floor, currently proposed at 60% HRmax, and boundary behavior.
4. Required measured HRmax/HRrest and later LT1; estimated-value policy.
5. `ScoreEligibility`: plan-linked, discretionary and incidental.
6. Missing-HR, average-only HR, measured power, no-power cycling and strength behavior.
7. Walking and other incidental-activity treatment.
8. Day aggregation, impulse-response initial condition and history cutoff/warm-up.
9. Calculation/configuration version and whether history is recalculated or frozen.
10. Display terms, uncertainty, missing/partial result and explanation text.
11. Explicit removal of TSB/ATL:CTL/freshness ratio bands from user guidance.

Bruno supplies or accepts measured HRmax, HRrest and LT1 availability. Run floored versus
unfloored calculations over the full retained history before approval.

### H1 - Build the comparison harness

1. Freeze real fixtures for short/long run, ride with HR, ride with power only, swim,
   strength, walking, excluded, partial HR and no-HR activity.
2. Add synthetic boundary fixtures at/below/above the floor, timezone boundaries, empty days,
   long gaps and extreme duration.
3. Compute old and proposed series from identical canonical evidence and configuration.
4. Persist/export comparison evidence without making either result production authority.
5. Add negative controls for eligibility, floor, initial condition and invalidation.

### H2 - Implement versioned engines

1. Implement pure `AdaptationEngine` and `BurdenEngine`; neither reads stores or the clock.
2. Return value plus eligibility, input coverage, configuration/calculation version and
   explanation components.
3. Add repository/cache keyed by activity revisions, decisions, athlete configuration and
   calculation version.
4. Write durable invalidation requests with every relevant source/profile/merge/exclusion
   change.
5. Burden remains descriptive and never changes a plan automatically.

### H3 - Shadow, cut over and retire

1. Run a Diagnostics shadow period across every H1 fixture shape and real history.
2. Record explained differences and accepted tolerances; investigate unexplained differences.
3. Cut Activity Detail, Today and Progress to adaptation/burden vocabulary together.
4. Rebuild Review evidence only after the new meanings are accepted.
5. Update manual glossary, equations/limits and troubleshooting in the same cutover.
6. Remove old calculation UI/cache only after rollback evidence and comparison export exist.

**Exit gate:** every displayed state can explain its inputs, eligibility and calculation
version; sleep or intake does not steer it, old/new differences are accepted and unsupported
freshness-ratio guidance is absent.

## 12. Stage I — living manual

Build this continuously from Stage F onward; the sequence below controls completeness.

### I0 - Manual architecture

Recommended source:

```text
Resources/Manual/
├── manifest.json
├── getting-started.md
├── data-and-privacy.md
├── today.md
├── week.md
├── plan.md
├── progress.md
├── activities.md
├── review.md
├── settings-and-data.md
└── troubleshooting.md
```

The manifest defines stable section ID, order, title, minimum app/manual version, owning
feature and keywords. Choose and ADR-record either validated native Markdown rendering or a
deterministic build step that generates bundled HTML. Markdown remains the editable source;
generated output is not hand-edited.

Build checks must fail for duplicate/missing anchors, broken internal links, missing feature
help mappings, stale generated output, missing bundle resources and unsupported external
links. Search uses manifest/headings and does not require a network connection.

### I1 - Section delivery

1. Help shell, section manifest, stable anchors and search.
2. Getting Started and Data & Privacy.
3. Today, Week and Plan.
4. Progress and load glossary.
5. Activities, matching, exclusion, imports and manual entry.
6. Review and plan-change behavior.
7. Settings, diagnostics, backup/export/delete and troubleshooting.
8. Current screenshots, alt text and accessibility review.
9. Build/link validation and release ownership.

Each feature slice updates its section, glossary, privacy/source explanation, failure states
and troubleshooting. Screenshots are current, localized where needed, carry alt text and are
rechecked when the surrounding UI changes. The feature owner owns its manual section; the
release gate owns whole-manual link/version/accessibility validation.

**Exit gate:** every public feature has a reachable, searchable and current manual section.

## 13. Stage J — feature expansions in dependency order

### J1 - Plan builder

**Product boundary:** planning a future session is different from manually recording a
completed activity. J1 builds plan creation/editing. Manual completed activity entry remains
the separate G3/P4B decision and must be visibly app-authored.

**Data contract**

- Keep stable `plan.id` and session identity independent of date, display title and plan
  version.
- Treat a plan version as immutable published content. An edit creates a new version/mutation
  history rather than rewriting the row notes/matches were written against.
- Add plan/session mutation audit with action, before/after version, actor, reason, timestamp
  and undo/supersession.
- Persist lifecycle state: draft, active, archived; session state: planned, rescheduled,
  skipped, substituted, completed/linked where appropriate.
- Preserve bundled/imported/app-authored provenance and parent version.

**Implementation**

1. Build draft repository transactions for create/edit/reschedule/skip/substitute/archive and
   restore/undo.
2. Validate sport, date/time/timezone, target type/unit, duration/distance, intensity,
   structured blocks, recurrence/template, duplicate identity and plan range.
3. Preserve notes, match decisions, Review references and external Calendar/WorkoutKit links
   through stable IDs.
4. Show a consequence preview: sessions changed, matches affected, WorkoutKit items and
   Calendar events to add/update/remove.
5. Publish a draft transactionally as a new active version; failed external publication does
   not roll back the valid local plan and instead creates retryable link work.
6. Add templates only after one-off creation/editing is stable; recurrence expands into stable
   sessions at a documented boundary.
7. Test concurrent-looking edits in one process, repeated publish, undo after external sync,
   timezone/DST, plan replacement and orphan protection.

**Exit gate:** create/edit/reschedule/skip/substitute/archive/undo survive relaunch, preserve
stable references and preview every external consequence.

### J2 - Shoe and gear tracking

**Schema additions**

- Expand gear with kind, name, active/retired state, purchase/start date, starting lifetime
  distance, optional guidance threshold, notes and created/updated times.
- Keep imported source identity/provenance separately; local edits do not erase imported
  history.
- Add sport/subtype default rules with deterministic priority.
- Add per-activity assignment history/override with actor, reason, revision and time.
- Store wear-calculation version/revision or make it reproducible from source rows and
  content revisions.

**Implementation**

1. Reconcile permitted historical shoes/bikes and record explicit starting baselines before
   Strava rows are purged.
2. Build local create/edit/retire/restore; retired gear remains linked historically.
3. Select default gear for new canonical activities, but allow no gear/unknown and explicit
   override.
4. Calculate wear from included canonical activity distance plus starting baseline; do not
   copy a provider lifetime total forward on every refresh.
5. Recalculate on activity merge/unmerge, exclusion/restore, distance correction,
   reassignment and source deletion.
6. Show Gear list/detail, activity assignment and history. Thresholds warn; they do not
   auto-retire or imply a safety guarantee.
7. Test one activity with multiple source records, historical retired gear, no-distance
   activity, duplicate assignment and invalidation interruption.

**Exit gate:** gear history and wear remain stable after Strava removal and every calculated
distance can be traced to baseline plus included canonical activities.

### J3 - Structured fuel, fluid and electrolyte intake

Keep planned and consumed concepts separate. Missing logging is unknown, not zero consumed.

**Schema**

- `intake_target`: plan session/day, fluid ml, carbohydrate g, energy kJ, sodium mg and
  optional accepted nutrients; provenance/version.
- `intake_entry`: timestamp, local day/timezone, optional activity/session, quantities,
  source, note, created/edited/deleted/audit state.
- `intake_product`: reusable name/brand and lifecycle state.
- `intake_serving`: product amount plus contributed canonical quantities.

A gel or drink is a product/serving, not a scientific unit. Canonical storage uses ml, g, kJ
and mg; display conversion happens at the edge. Potassium/caffeine are added only with a
defined product/display use.

**Implementation**

1. Build target editing with plan-builder integration.
2. Build quick consumed-entry actions for water, electrolyte drink, gel and custom serving.
3. Permit activity or day linkage; define reassignment when an activity merges or its day
   changes.
4. Compare target/consumed only where logging coverage is explicit; never infer adherence
   from an unlogged day.
5. Add corrections, undo, duplicate detection and export.
6. Feed Review minimized totals plus logging coverage only after payload consent/meaning is
   approved.
7. Evaluate Health read/write in a separate ADR after app-authored behavior is stable. A
   write bridge needs confirmation, update/deletion ownership and duplicate rules.
8. Avoid medical/precision recommendations that the data cannot support.

**Exit gate:** target and consumed values cannot be confused, conversions round-trip, missing
logs remain unknown and Review can state coverage.

### J4 - Sleep from Apple Health

**Raw storage and ingestion**

1. Add least-privilege `sleepAnalysis` authorization and a dedicated anchored checkpoint.
2. Store source samples with UUID/source revision, start/end UTC, category value, timezone
   metadata, device/source and deletion state.
3. Ingest in-bed, awake, asleep-unspecified, core, deep and REM without fabricating a stage
   when only generic sleep exists.
4. Reconcile overlapping writers deterministically while retaining every source sample.

**Night derivation contract**

- Define the local night boundary and travel timezone source.
- Group cross-midnight intervals without assuming the current phone timezone.
- Resolve overlapping in-bed and staged samples without double counting.
- Keep naps separate according to a stated gap/duration/day rule.
- Represent uncovered time and missing stages as missing, not awake or zero.
- Version the night algorithm and retain input coverage/provenance.

**Product and validation**

1. Show duration, consistency and stage availability with available/partial/no-data/denied-
   unknown/unavailable/stale/failed states.
2. Run DST spring/fall, timezone travel, nap, multiple-device overlap, generic-only sleep and
   deleted sample fixtures.
3. Observe without feeding plan changes. Review receives a minimized summary only after
   meaning, consent and coverage are approved.
4. Manual correction, if later accepted, is an overlay and never overwrites Health evidence.

**Exit gate:** derived nights are explainable across DST/travel/overlap, missing stages are
honest and sleep does not steer training.

### J5 - Apple Calendar publication

**Accepted starting direction:** one-way SUB4-to-Calendar publication into a dedicated,
user-approved **SUB4 Training** calendar. Bidirectional Calendar edits are deferred until a
conflict model is designed.

**Permission decision**

- Write-only EventKit access can create events but cannot read them back, including events the
  app created. Managed reconciliation therefore needs full event access unless v1 deliberately
  accepts create-only, non-reconciling publication.
- Record the chosen permission and purpose string in the Calendar ADR before code.

**Persistence**

Add a sync link containing account/plan/session stable ID, calendar identifier, event
identifier, last external identifier where useful, last-published fingerprint, state,
last-seen/published time and error/retry information.

Event identifiers are not permanent: moving calendars can change them and a full calendar
sync can invalidate a cached identifier. Store a recovery fingerprint and SUB4 deep link;
never use the EventKit identifier as session identity.

**Implementation**

1. Add stable app URL routes that open the exact session independent of date/version.
2. Preview date range, chosen calendar, permission, add/update/remove counts and fields.
3. Create/reuse the dedicated calendar only after explicit approval.
4. Publish title, start/end, concise summary and deep link; exclude sensitive notes by
   default because Calendar may sync externally.
5. Reconcile reschedule/edit/skip/archive/plan replacement using stable session ID and
   fingerprint.
6. Detect missing calendar, missing/changed event and user edit; offer rebuild/keep choices.
7. Never modify/delete an event the app cannot prove it owns.
8. Disconnect previews keep all events or remove only proven SUB4-owned events and writes a
   receipt.
9. Test denied/revoked access, timezone/DST/travel, deleted calendar, hundreds of sessions,
   repeated publish, user edit and identifier loss.

**Exit gate:** repeated publication reconciles without duplicates, foreign events are never
touched and every disconnect consequence is previewed.

### J6 - Plan exports

**One source snapshot**

`PlanExportSnapshot` is a Sendable, immutable value loaded once for selected week, calendar
month, phase/custom range or full active plan. It contains plan/version, generation time,
timezone, display-unit selection, stable session IDs and explicit target versus optional
recorded fields. Every format encoder consumes the same snapshot.

**Formats**

- PDF: default human-readable/print format; define typography, sections, page header/footer,
  pagination, long-description wrapping and accessibility metadata.
- ICS: calendar interchange separate from managed EventKit; define stable UID, timezone,
  update/reimport behavior and no accidental recurrence expansion.
- CSV: stable documented UTF-8 columns, quoting/newline/null behavior and schema version.
- JSON: lossless versioned technical interchange with compatibility policy; not the default
  user document.
- Markdown remains optional after the four core formats.

**Implementation**

1. Preview scope, session count, target/recorded choice and sensitive fields.
2. Generate off the main actor into a protected temporary export location.
3. Validate with golden semantic fixtures; PDF also receives rendered visual inspection.
4. Use stable readable filenames with plan/scope/date/version.
5. Share through Platform, then remove temporary files on completion/expiry/next launch.
6. Keep this separate from complete personal-data export and database backup.
7. Test empty scope, long plan, DST/timezone, Unicode, repeated ICS import, PDF page breaks,
   share cancellation and cleanup failure.

**Exit gate:** all formats represent one accepted snapshot consistently, validate against
their schemas and leave no unintended temporary data.

### J7 - Route heatmap

1. Measure canonical route coverage by sport/source/device after Health reconciliation and
   publish included/total counts in the feature.
2. Define inclusion: date/sport, accepted route quality, canonical duplicate, exclusion,
   activity-level opt-out and privacy mask.
3. Choose and document aggregation: fixed local spatial grid/tiles or simplified weighted
   segments. Cache by route/decision/privacy/filter revision rather than redrawing raw points.
4. Downsample by zoom while retaining original route rows independently.
5. Apply home/start/end privacy masking before aggregation/display/export. Mask invalidation
   removes affected cache immediately.
6. Keep processing local unless a separately approved map/provider transfer has consent and
   policy support.
7. Add date/sport filters, partial-coverage explanation, empty/error state and textual
   accessibility summary such as activity/route coverage and most-used areas at a coarse
   non-sensitive level.
8. Exclude heatmap/precise route data from routine support diagnostics.
9. Profile maximum retained history on oldest supported iPhone and iPad: query time, peak
   memory, cache size, pan/zoom responsiveness and invalidation latency.

**Exit gate:** the heatmap never implies complete history when routes are missing, privacy/
exclusion changes invalidate correctly and performance budgets pass.

### J8 - iPad designed experience

**Decisions before code**

1. Re-read `docs/context/ipad-readiness.md` and `ipad-rebuild-plan.md` against the final tree.
2. Verify target device family, Health capability requirements and all supported iPad
   orientations from the live project.
3. Decide local-only versus cross-device state before implying the same plan/adherence data
   appears on iPhone and iPad.
4. Decide one scene or multiple windows. If multiple, define scene-owned navigation/selection
   and shared mutation behavior.

**Implementation**

1. Put adaptive navigation at App/Feature composition: regular width uses two/three-column
   `NavigationSplitView`; compact width retains the proven phone stack/tab behavior.
2. Use stable feature/destination IDs and scene-owned selection; no iPad-only domain stores.
3. Define DesignSystem metrics for readable width, sidebar/list columns, grid, spacing, chart
   aspect and empty detail.
4. Convert navigational sheets to panes/popovers; keep true modal creation/edit/confirmation
   tasks as sheets.
5. Make charts lazy, width-responsive and revision-cached. Add discipline filters so mixed
   distance scales do not flatten running data.
6. Define initial/cleared/deleted selection, deep-link routing and compact-column restoration.
7. Support pointer, keyboard focus/shortcuts, Dynamic Type, VoiceOver chart summaries, Reduce
   Motion, rotation, Split View, Slide Over and Stage Manager.
8. Test identical repository/feature semantics on iPhone and iPad; state local-only and
   multi-window limitations in onboarding/manual.

**Performance budgets**

- No eager loading of full route/sample history for navigation.
- Maximum-history dashboard and Activities browsing stay within accepted memory/frame/query
  budgets recorded before implementation.
- Wide charts remain readable and compact fallback remains unchanged.

**Exit gate:** regular width has intentional hierarchy, compact width remains correct,
selection/state ownership is deterministic and device/sync limitations are explicit.

**Feature-program exit gate:** every feature passes its build card in the architecture plan,
updates the manual and completes the shared accessibility/privacy/localization/release checks.

## 14. Stage K — later platform programs

These are deliberately not hidden inside the feature plan:

1. Cloud/device synchronization with explicit account, encryption and conflict rules.
2. Apple Watch companion and direct workout recording as canonical source adapters.
3. Multiple goals and active plans after second-athlete generalization passes.
4. Individualized load coefficients, DFA-alpha1 and subjective readiness only after separate
   research/validation decisions.

Each requires its own ADR and implementation plan before code.

Minimum questions for those future plans:

- **Cloud/device sync:** identity/account model, end-to-end protection, authoritative server or
  peer model, database change log, conflict rules per authored entity, deletion/tombstones,
  offline convergence, key recovery, migration and local-only opt-out.
- **Watch/direct recording:** workout configuration, sensor/sample ownership, offline queue,
  interruption/resume, phone/watch clock drift, duplicate reconciliation, Health write/read
  loop prevention and battery/storage budgets.
- **Multiple plans/goals/athletes:** remove account-singleton and Bruno-specific constants,
  scope every query/unique key, define active-plan conflicts and prove a second-athlete fixture.
- **Advanced recovery/research:** pre-register question, evidence/validation data, uncertainty,
  non-medical limits, calculation version and observation before steering behavior.

## 15. Global release gates

At the end of every stage:

- [ ] Debug and Release build from a clean checkout.
- [ ] Focused tests and full test suite pass with an expected test count.
- [ ] No new compiler or concurrency warning.
- [ ] Database migration/open/integrity tests pass where persistence changed.
- [ ] Backup/export/restore consequences are verified where durable data changed.
- [ ] Device checks cover success, empty, denied/unavailable, stale, partial and recovery.
- [ ] Accessibility and privacy behavior were reviewed for changed screens/data.
- [ ] Documentation and manual claims match the build.
- [ ] Diagnostics and logs contain no tokens, private notes or raw routes.
- [ ] A rollback path and preceding known-good commit are recorded.
- [ ] The worktree contains no unexplained change.
- [ ] Every newly read Apple type has purpose text, lifecycle inventory and a real-device
      permission/data test.
- [ ] Every new durable field has provenance, backup/export/delete and migration behavior.
- [ ] Every cache names all input revisions and has an invalidation test.
- [ ] Every destructive/bulk action previews scope and produces a checked result/receipt.
- [ ] Source/network-negative tests prove retired providers cannot be contacted.

## 16. How to turn this into daily work

Only one stage is active at a time. For the active stage:

1. Select the first unmet exit-gate condition.
2. Write a bounded groundwork document checked against the current source.
3. List all production and test call sites before editing a shared type.
4. Add or identify the failing negative-control test.
5. Implement the smallest slice that changes that condition.
6. Run focused tests, then the complete suite.
7. Verify the exact device state and export diagnostics when relevant.
8. Update the authoritative ADR/context/manual section.
9. Commit the slice with its app patch label.
10. Start the next slice only after the previous evidence is accepted.

At the patch-334 working-tree baseline, the first unmet condition is **A1: finish and prove
the current detail/recording recovery**. A2 is implemented but remains an acceptance task:
full-suite, negative-control and real-device roll-up evidence, followed by commit. The first
new design/code work after that is **A3: D7 activation groundwork**. Feature work begins only
after Stages A-E.

## 17. Decisions required before their stage begins

These are intentional stop points, not details for an implementation session to guess:

1. Accept the D7 bootstrap-through-existing-observable-APIs strategy or replace it in A3.
2. Define post-activation rollback once the first database-only mutation can exist.
3. Accept the timestamp-first Health raw schema and choose source-field payload/value storage.
4. Choose Health anchor encoding/storage and prove atomic checkpoint behavior.
5. Accept moving/active/elapsed definitions and canonical field/source priority.
6. Choose FIT decoding implementation and retained-original-file policy.
7. Accept every historical gap as recoverable, degraded or intentionally lost before purge.
8. Set D8 minimum supported upgrade version and compatibility sunset.
9. Accept the restructuring plan's §24 decisions and optional Domain-module evaluation rule.
10. Accept the manual-activity ADR, including whether completed manual activities ship.
11. Recover/accept the exact adaptation/burden mathematical specification and physiology
    inputs.
12. Choose manual Markdown renderer/generator and section ownership.
13. Choose Calendar full-access reconciliation or explicitly reduced create-only behavior.
14. Choose intake Health read/write boundary.
15. Keep sleep informative-only until a later validated steering decision.
16. Decide iPad local-only/cross-device promise and multi-window support.
17. Approve performance budgets for maximum history, routes, heatmap, charts and iPad.

## 18. Authoritative implementation references

### Local project decisions

- `docs/ADR-0001-product-definition.md`
- `docs/ADR-0002-strava-retirement.md`
- `docs/ADR-0003-database-contract.md`
- `docs/PLAN-cutover-v2.md`
- `docs/PLAN-post-database-strava-project-restructure.md`
- `docs/STRAVA-DATA-FLOW-INVENTORY.md`
- `docs/context/load-model-research.md`
- `docs/context/review-data-pool.md`
- `docs/context/ipad-readiness.md`
- `docs/context/ipad-rebuild-plan.md`
- `docs/context/hevy-setup.md`

### Apple Health and platform contracts

- Health workout and associated samples:
  <https://developer.apple.com/documentation/healthkit/hkworkout>
- Health anchored changes/deletions:
  <https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery>
- Observer/background delivery:
  <https://developer.apple.com/documentation/healthkit/executing-observer-queries>
- Reading workout routes:
  <https://developer.apple.com/documentation/healthkit/reading-route-data>
- Condensed workout sample expansion:
  <https://developer.apple.com/documentation/healthkit/accessing-condensed-workout-samples>
- Workout events:
  <https://developer.apple.com/documentation/healthkit/hkworkoutevent>
- Sleep categories and overlap semantics:
  <https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis>
- EventKit access levels:
  <https://developer.apple.com/documentation/eventkit/accessing-the-event-store>
- Calendar identifier limitations:
  <https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier>
- Adaptive iPad navigation:
  <https://developer.apple.com/documentation/swiftui/navigationsplitview>

### Import/recovery references

- Garmin FIT activity file:
  <https://developer.garmin.com/fit/file-types/activity/>
- Garmin FIT activity decoding:
  <https://developer.garmin.com/fit/cookbook/decoding-activity-files/>
- Hevy Apple Health behavior/troubleshooting:
  <https://help.hevyapp.com/hc/en-us/sections/36957443687831-Apple-Health>

External references inform implementation mechanics. Local ADRs remain authoritative for
SUB4 product, persistence, provenance, lifecycle and cutover decisions.
