# SUB4 post-B5 execution plan

## SQLite authority, Apple Health cutover, Strava retirement and legacy cleanup

| | |
|---|---|
| **Status** | Sequential execution runbook. **Task 0 is blocked until B5 is accepted.** |
| **Reviewed** | 21 August 2026 |
| **Repository window inspected** | Review began at `ae12549` / patch 426; B5 advanced during drafting to `f691bd5` / patch 427 with further changing uncommitted work. Task 0 must re-read the final state rather than trust either frozen ID |
| **Committed verification at that point** | 1,833 tests in 172 suites and preflight green; future tasks must re-measure rather than reuse this number |
| **Purpose** | Give a new AI one bounded, dependency-safe task at a time from the end of B5 through SQLite activation, Health replacement, Strava retirement, D8 and the architecture handoff |
| **Current-state authority** | `CLAUDE.md` §5 and the current source |
| **Persistence authority** | `docs/ADR-0003-database-contract.md` |
| **Source-retirement authority** | `docs/ADR-0002-strava-retirement.md` |
| **Sequence authority** | `docs/PLAN-codebase-modernization-and-feature-delivery.md` |

This document supersedes the post-B5 portions of
`docs/PLAN-database-cutover-findings-and-ai-prompts.md`. That older document is
a patch-399 review and remains useful history; its status labels are not current.
This document does not supersede either ADR or the modernization plan. If a
statement here disagrees with current source, the source wins and this document
must be corrected in the same task.

## The answer before the plan

After B5, SUB4 will still **not** be ready to disconnect Strava.

- D7's exit gate is not met until B6, B7, B8, B9 and B10 pass.
- Strava still supplies new activity summaries, details, recordings, athlete
  refreshes and background updates.
- Apple Health is currently an in-memory diagnostic/enrichment source, not a
  durable canonical source. The existing anchored query is a route census with
  no persisted anchor; there is no canonical Health ingest transaction.
- A protected legacy snapshot is migration input. It deliberately excludes the
  database and is **not** a post-activation database backup.
- The current readable export excludes SQLite and turns binary preference values
  into strings such as `N bytes`; it is neither complete nor restorable.
- `migration_run.snapshotID` associates a run with a name. It does not prove the
  importer or verifier read those exact bytes.
- The current Strava disconnect remains file-era behavior. It can remove the
  database directory while an open database queue still exists and must not be
  used after SQLite becomes authoritative.

The safe end-to-end order is:

```text
accept B5
  → finish B6/B7/B8
  → build backup, export, audit and exact dataset binding
  → activate SQLite and prove fail-closed operation (B9/B10)
  → make Apple Health canonical and recover/reconcile history
  → rehearse without Strava
  → revoke and purge Strava deliberately
  → hold the compatibility window and retire runtime JSON (D8)
  → perform the behavior-neutral architecture restructure
```

Database activation and Strava retirement are separate decisions. Neither one
is evidence for the other.

## Scope and final outcome

This plan begins **after** B5. It does not authorize an AI to finish, rewrite or
commit the active B5 work. Task 0 only decides whether B5 has actually passed.

The plan is complete when:

1. SQLite is the continuously current, independently verified and restorable
   authority for all app data and operational state.
2. A database failure cannot look like a legitimate empty training history.
3. Apple Health, supported recovery imports and app-authored facts supply every
   accepted feature input without Strava.
4. A fresh workout can arrive, reconcile, render and affect derived outputs while
   Strava is unavailable.
5. Remote Strava revocation and local lineage purge have a checked, resumable
   receipt and preserve every permitted authored/canonical record.
6. Runtime JSON and obsolete preferences are gone or isolated as a version-bounded
   upgrade path with an owner, test and deletion condition.
7. The surviving code is handed to the already-approved R0-R15 behavior-neutral
   restructure with a new baseline and peer review.

The current architecture is intentionally transitional:

```text
SQLite → repositories/bootstrap → observable stores → SwiftUI
```

That is the right D7 landing position because it changes persistence without also
changing the view object graph. The final clean boundary is reached only after
Health and D8:

```text
source adapters/platform → database repositories → source-neutral domain services
                         → feature presentation models → SwiftUI
```

An in-process repository/domain-service boundary is the app's API layer. A remote
HTTP API is not required unless a later sync/multi-device decision creates that
requirement.

## How to execute this document

1. Run the tasks in numeric order. Do not start a later task because an earlier
   one is slow, date-gated or needs a decision.
2. Paste the **common clean-start preamble** followed by exactly one task prompt.
3. An AI may decompose that prompt into smaller patches, but it may not silently
   expand into the next numbered task.
4. Groundwork and decisions come before code. A task with an owner decision stops
   for that decision.
5. A task is complete only when its binary exit gate is evidenced. Passing unit
   tests alone never closes a device/runtime slice.
6. The AI reports the diff and asks before committing or pushing. This document
   grants neither permission.

## Common clean-start preamble for every prompt

~~~text
Work in /Users/bruno/Documents/Developer/sub4/Sub4.

Before changing anything:
1. Read AGENTS.md if one exists.
2. Read docs/context/working-agreement.md.
3. Read CLAUDE.md completely, especially section 5.
4. Read this plan's current-state warning, shared manual-campaign contract and the
   selected task in full.
5. Read the task's referenced sections of ADR-0003, ADR-0002 and the modernization
   plan. Treat dated context/groundwork as evidence, not current state.
6. Inspect git status, git diff and the latest 20 commits. All modified/untracked
   files belong to the user. Preserve them and stop before overlapping active work.
7. Confirm AppVersion.patch, migration list/schema, current hydrated families and
   test count from source. Do not reuse the historical numbers in this document.

Implementation rules:
- State the question, current behavior, affected production/test call sites,
  non-goals, data owner, rollback and binary exit gate before editing.
- Never edit a migration that may have run. Use an additive migration and a
  populated upgrade test.
- Preserve missing, null, zero, empty, unavailable, denied/unknown, stale, partial,
  corrupt and failed when they mean different things.
- Reuse the existing domain calculation/mapping. Do not copy a formula into SQL or
  create a second provider-specific truth.
- Hydration never writes. Authoritative mutations commit before observable success.
- Source rows, deletions, revision and checkpoint/anchor commit atomically.
- Add a negative control that fails when the new protection/mapping is disconnected,
  and sabotage it once when practical so the test is known to discriminate.
- Run focused tests, python3 scripts/check-invariants.py and ./scripts/test.sh.
  Run a Release build/device measurement for launch, background, Health, rendering,
  activation, backup/restore or performance work. Restore the shared Run action to
  Debug after a Release campaign.
- Update ADR/current-state/manual text whose truth changed; preserve historical ADR
  decisions and add a superseding entry instead of rewriting history.
- Never send Strava-lineage evidence to an AI provider.
- Never disconnect Strava, revoke credentials, purge lineage, delete phone data,
  corrupt the only database, commit, push or change external state unless this exact
  task permits it and Bruno gives the required confirmation.
- Report files changed, automated evidence, device evidence, remaining risks and the
  exact next gate. Do not call the next task started.

Manual campaign rule:
- Decide explicitly whether this task needs a manual campaign.
- If it does, build the full campaign as part of the task when the need becomes
  known, before claiming completion.
- If it does not, name the automated evidence that makes it unnecessary.
- Apply the shared campaign contract in this document and the task-specific clause.
~~~

## Shared manual test campaign contract

Every prompt below contains a task-specific campaign clause. A campaign is
mandatory whenever the task touches real activity/Health/Keychain data, file
protection, background execution, termination, UI behavior/performance, actual
cross-store counts, snapshot/backup/export/restore, activation, deletion or
disconnect.

The AI builds the campaign when the relevant behavior and diagnostic names are
known. It may not defer it to “manual QA later” or ask Bruno merely to “check it.”
Put it in the task's groundwork/ADR entry or a bounded
`docs/DEVICE-CAMPAIGN-<task>.md`.

Every campaign must contain:

1. **Question and risk** — what automation cannot prove and which failure the
   campaign is intended to reveal.
2. **Build and dataset identity** — patch, commit, Debug/Release, device model,
   iOS, timezone, schema/migration count, snapshot/backup ID, migration run,
   evidence version and source/database fingerprints when available.
3. **Safety and rollback** — protected artifacts required first, disposable data
   boundaries, what may be mutated, what must not be touched, rollback steps and
   the point after which rollback is no longer lossless.
4. **Exact current navigation** — derive tap-by-tap labels from current SwiftUI.
   The current top-level tabs are Today, Week, Plan, Progress and Settings; do not
   invent an “Activities tab.” If the required record is unreachable, build the
   smallest redacted evidence navigation/diagnostic before asking for the test.
5. **Independent expectation** — name the direct file read, immutable snapshot,
   audit report, repository query, Health/FIT source or captured pre-flip baseline.
   Two screens hydrated from the same store are not independent.
6. **Observed app evidence** — exact screen, section and diagnostic line. Add the
   missing redacted diagnostic first if the state is otherwise invisible.
7. **Pass/fail table** using:

   `step | action | observed in app | expected from | pass condition | evidence`

   Include numeric tolerances, legitimate-empty behavior and negative states.
8. **Evidence capture and redaction** — screenshots, copied diagnostics, exported
   files, hashes and timestamps. Exclude tokens, API keys, raw private routes,
   precise coordinates and unrelated free-text notes.
9. **Cleanup and rollback** — restore files/settings/build configuration, remove
   disposable fixtures and re-check starting counts/fingerprints.
10. **Uncovered cases** — a partial campaign proves only its rows.

Preferred in-app evidence areas, subject to current labels in source:

- Settings → Database: authority/source lines, table census, comparisons,
  read-backs, ledger, snapshot/backup identities and copied diagnostics.
- Today / Week / Plan: session identity, planned day, completion, match, note/RPE.
- Existing activity-detail links from Today/Week/Plan or diagnostic rows: summary,
  weather, gear, route, profile, splits, laps and no-trace behavior.
- Progress: volume, load, zones, fitness/PMC and monotony.
- Settings → Apple Health: coverage, source overlap, checkpoint, pending work and
  authorization state.
- Settings data/lifecycle controls: export, backup, restore, previews and receipts.
- A downloaded Xcode `.xcappdata` package for independent file/database evidence.

## Ordered task map

| # | Task | Starts only after | Principal exit |
|---|---|---|---|
| 0 | Accept B5 and freeze the starting evidence | B5 implementation claims complete | B5 is independently proven and a fresh legacy snapshot exists |
| 1 | Resolve match-picker behavior and match-decision fidelity | 0 | picker/resolver agree and the decision round-trips |
| 2 | Build a disposable authored repair/removal fixture | 1 | restore, scoped removal and durable attribution are proven, not merely no-ops |
| 3 | Write B6/B6a derivation and persisted-load groundwork | 2 | complete input/invalidation/lineage contract accepted |
| 4 | Implement and flip B6/B6a | 3 | outputs unchanged; launch no longer constructs all traces |
| 5 | Resolve and execute B7 review persistence | 4 | privacy-safe proof of the full graph under the accepted gate |
| 6 | Write B8 operational-state groundwork and field tranche | 5 | cursor/queue/rejection/revision contract accepted |
| 7 | Implement B8 atomic authority | 6 | rows and checkpoint cannot diverge across interruption |
| 8 | Close the complete source-field matrix | 7 | every source field is preserved, normalized, derived or explicitly excluded |
| 9 | Build authoritative backup, readable export, restore and lifecycle receipts | 8 | SQLite can be protected and restored independently |
| 10 | Build the external auditor and exact dataset binding | 9 | one verified run identifies exact source and DB states |
| 11 | Build B9 fail-closed activation groundwork | 10 | all negative controls and recovery path exist, activation still off |
| 12 | Activate SQLite and execute B10 | 11 + explicit approval | DB-only Release campaign passes; Strava remains connected |
| 13 | Refresh Health coverage and accept raw/canonical contracts | 12 | C0/C0.1/C0.2 accepted |
| 14 | Build durable Health workouts, quantities, routes and events | 13 | C1/C2 batches are exactly-once and reconstructable |
| 15 | Build canonical projection and source reconciliation | 14 | C3/C4 are deterministic and authored links survive |
| 16 | Recover gaps and rebuild dependent features | 15 | C5/C6 feature matrix passes |
| 17 | Run Health/Strava shadow and disconnected rehearsal | 16 | C7 has zero unexplained product differences |
| 18 | Activate Health, revoke and purge Strava | 17 + explicit destructive approval | C8 receipt and immediate Health ingest pass |
| 19 | Retire runtime JSON and remaining Strava code | 18 + stable compatibility window | D8 inventory is clean and upgrade path bounded |
| 20 | Hand off to the behavior-neutral restructure | 19 | new baseline, decisions and R0-R15 inputs accepted |

---

## Task 0 — Accept B5 and freeze the starting evidence

### Why this exists

This review began at committed patch 426 while B5 follow-on work was actively
changing the worktree. B5 advanced to committed patch 427 during drafting and the
worktree continued changing afterward. `docs/D7-B5-GROUNDWORK.md` was written
before the approved decisions and is no longer sufficient proof. Task 0 is a gate,
not permission to continue B5 under this plan.

### Exit gate

B5 is accepted only when weather and all supported gear facts hydrate from
SQLite; kind, retirement fact and retirement date semantics are independently
read back; `knownActivityIDs` comes from an independent legacy roster; rollback
remains selectable; focused/full tests and a Release-device campaign pass; the
current docs agree; and a new preference-inclusive protected legacy snapshot is
retained off-device. If any item is false, stop and return ownership to B5.

### AI prompt 0

~~~text
Apply the common preamble and shared campaign contract from
docs/PLAN-post-B5-database-cutover-execution.md.

Task 0: audit B5 at the actual current commit. Do not implement missing B5 work
under this post-B5 plan and do not overwrite the active worktree.

Trace the complete weather/gear path: athlete/weather legacy decode, array
membership recovery, GearKind/unknown handling, isRetired, retiredUTC definition,
import/reconciliation, repository load, round-trip, bootstrap, PersistenceMode,
AthleteStore/WeatherStore hydration, read provenance and every UI consumer.

Require evidence for:
- additive migration upgrade from a populated pre-B5 DB;
- active shoe, bike, retired shoe, unknown kind/reference and missing weather;
- old athlete.json without new fields;
- a gear-only/authored import not erasing retirement date;
- direct file-side activity roster rather than ActivityStore-fed filtering;
- machinery patch separate from hydration flip and hydration writing nothing;
- legacy rollback after removing B5 families from the hydration set;
- current DataLifecycle/export/lineage disclosures.

Run focused tests, invariants and the full suite. Reconcile CLAUDE §5, README,
ADR-0003 and B5 groundwork with source. If B5 is already evidenced, do not rerun
destructive steps just to produce new prose.

Manual-campaign decision: mandatory unless an already-accepted post-flip B5
campaign contains every row above. Otherwise build/amend it from actual labels.
Derive expected weather/gear from direct athlete.json/weather.json reads and the
independent read-back; navigate to records through current Today/Week/Plan or
diagnostic links; run in Release; move legacy inputs aside rather than delete;
relaunch and roll back. After acceptance, create and verify a fresh
preference-inclusive protected legacy snapshot and retain its manifest/digest and
an off-device container copy. This snapshot is not a database backup.

Stop with either a binary B5 acceptance record or an exact blocker list. Do not
start Task 1 and do not commit/push without approval.
~~~

---

## Task 1 — Resolve match-picker behavior and match-decision fidelity

### Finding

The picker offers activities the resolver filters out. Selecting an ineligible
walk can persist an override and still leave the session “Not done.” The DB also
omits `MatchDecision.dateIsKnown`. The behavioral choice affects completion,
extras, adherence and load; it is not a cosmetic picker fix.

### Exit gate

Bruno has selected one contract; picker and resolver share it; an impossible
silent override cannot be stored; `dateIsKnown` and accepted match fields survive
source → DB → read model; cross-day/double-claim behavior is explicit; all affected
screens/derivations and relaunch are proven.

### AI prompt 1

~~~text
Apply the common preamble and shared campaign contract.

Task 1: resolve the match-picker contract, then implement only the accepted
behavior and match-decision fidelity. Start with a decision package; do not guess.

Trace MatchPickerView entry points, Matcher.setOverride, MatchResolver.day,
Activity.isPlanEligible, cross-day windows, double-claim prevention, extras,
completion, adherence, load and persistence/read-back. Reproduce the existing
ineligible-override defect and identify the exact current UI reachability.

Present at least these choices with consequences:
A. eligibility is absolute; ineligible activities are disabled/explained;
B. explicit override beats automatic eligibility;
C. a separately confirmed manual override may beat eligibility.
Recommend one, but stop for Bruno's choice.

After the choice, put the rule in one domain owner used by picker and resolver.
Replace the defect test with accepted behavior tests. In a separate attributable
schema tranche, add/approve the additive mapping for MatchDecision.dateIsKnown;
test legacy missing values, null versus false, source alias resolution, relaunch,
same-day/cross-day and double-claim cases. Do not redesign matching generally or
begin B6.

Manual-campaign decision: required after implementation because UI selection and
derived consequences are involved. Build it from actual navigation. Select a
known ineligible activity through the current session match flow; derive its
eligibility independently from activity discipline/source evidence; verify picker
explanation, persisted choice/refusal, completion, extras, adherence and Progress
load, then clear it and prove the baseline returns. Include force-quit/relaunch and
record the match read-back/date-known state. Use disposable decisions only.
~~~

---

## Task 2 — Prove authored repair and removal with a disposable fixture

### Finding

Existing campaigns proved clean no-op restore and zero-removal states. They could
not prove a real DB-to-legacy repair, family-scoped orphan removal or a non-zero
`migration_run_removal` surviving retention because normal database-first writes
no longer create those mismatches. Three patches independently asked for one safe
fixture before B9.

### Exit gate

A protected, internal-only disposable fixture produces one repair and one scoped
removal; unrelated authored families are unchanged; the removal survives ledger
retention; cleanup returns to the exact starting identity; no production control
can mutate the only phone dataset into the fixture state.

### AI prompt 2

~~~text
Apply the common preamble and shared campaign contract.

Task 2: build the smallest safe fixture and campaign that can prove authored
repair, scoped removal and durable removal attribution. Do not use a real review,
real note or the only production database as disposable data.

Re-read StoreRestore, family-scoped reconciliation, migration_run_removal,
retention and the completed 1A/1B/1C campaigns. Choose a fixture boundary that
cannot ship as an ordinary destructive control: preferably an in-memory/test DB
plus a cloned disposable container; if physical-device proof needs an internal
debug action, gate it by internal build, explicit fixture identity and confirmation.

The fixture must create:
1. a DB-authored record missing only from its legacy mirror, so Restore adds one;
2. an orphan in exactly one reconciliation family, so that family removes one;
3. unrelated notes/commutes/moves/matches/reviews whose counts cannot change;
4. enough automatic ledger churn to prove the non-zero removal row is retained.

Assert idempotence, unclean-source refusal, family permission, total/family count
agreement, rollback on write failure and fixture cleanup. Do not add broad repair
behavior or proposal restore; B7 owns the review graph.

Manual-campaign decision: mandatory for the device evidence the fixture exists to
obtain. Build exact current taps and add redacted fixture diagnostics first. The
campaign records pre/post counts from Settings → Database direct queries/read-backs,
the Restore receipt and removal ledger, verifies the affected UI record, relaunches,
forces ledger retention, then removes the fixture and proves the original
fingerprint/counts return. Start from a protected off-device copy; abort if the app
cannot prove it is operating on the disposable fixture.
~~~

---

## Task 3 — Write B6/B6a derivation and persisted-load groundwork

### Finding

Release measurements show a roughly 0.6 s post-first-frame main-thread stall;
0.32–0.40 s is `DetailStore` construction over all recordings. The launch read is
load-bearing because `LoadEngine` prefers trace evidence. Making it asynchronous
would hide the freeze but still retain all traces and still delay correct values.

B6 and B6a therefore share one job: define one repository-backed derivation input
snapshot and persist the output of the existing pure load engine. Persisting that
output also creates a new privacy/lifecycle fact: a row may be derived from Apple
Health HR that DataLifecycle currently says is memory-only.

### Exit gate

Groundwork pins every derivation input, invalidation, revision, lineage, retention,
export/purge rule, schema, repository API, independent baseline, patch decomposition
and manual campaign. No formula or production source changes yet.

### AI prompt 3

~~~text
Apply the common preamble and shared campaign contract.

Task 3: write B6/B6a groundwork only. Do not change formulas, persist load or
flip production behavior in this task.

Inventory every input and consumer for matching, volume, pace, zones, TRIMP/load,
power conversion, PMC/CTL/ATL/TSB, monotony and Today/Week/Plan/Progress summaries.
Include activities, details/recordings, corrections/exclusions, athlete constants,
zones/FTP, notes/RPE, matches, commutes, plan/moves, Health cache and engine/config
versions. Treat purity as a hypothesis: trace `MatchResolver.day`, `LoadSeries`,
`LoadEngine` and `TabSummary` through `Activity.isPlanEligible`/`isLoadEligible`
and `CommuteStore.shared`. The new snapshot must carry explicit eligibility input;
no derivation may reach a mutable singleton. Identify same-count edits and global
`PowerLoad.calibrate` changes the current signature misses, and define a
source-neutral replacement for `stravaMovingSeconds` before choosing schema names.

Design one immutable Sendable DerivationInputs snapshot. Existing pure functions
remain the only formula owners; no calculation queries SQLite. Design a persisted
WorkoutLoad output keyed by canonical activity plus engine/input/config/source
revisions. Specify late trace, Health HR, RPE, correction, match, commute, plan,
profile/FTP and merge invalidation. Traces become lazy detail inputs after the
cache is trustworthy.

Write the lineage/lifecycle decision before schema: a persisted load may be
Health-derived, so update the planned retention, readable export, Health-revocation,
Strava-purge, AI-sharing and disclosure behavior. Revoking/changing Health access
must invalidate affected cache rows; cachedWorkouts.count is not a content
fingerprint.

Define a frozen independent pre-flip baseline that can disagree after B6. Cover
longest run, mixed sport, partial/no trace, no HR, Health-HR fallback, RPE edit,
commute toggle, match override and plan move. Decompose implementation into
additive schema/repository, gathering, shadow comparison, flip and cleanup patches.

Manual-campaign decision: no execution is expected for a documentation-only
groundwork patch, but the future Task-4 campaign is a mandatory deliverable now.
Write exact current navigation and independent baseline sources, same-count edit
steps, Release launch/stall measurements, lazy trace proof, safety/rollback and the
pass/fail table. Add any missing redacted diagnostic to the proposed first
implementation tranche.
~~~

---

## Task 4 — Implement and flip B6/B6a

### Exit gate

All current derived values match the independent baseline; every material edit
invalidates exactly the right rows; `LoadEngine` remains the formula owner; launch
does not construct the whole `DetailStore`; detail traces load lazily; lineage and
export/purge behavior are true; the Release-device campaign passes.

### AI prompt 4

~~~text
Apply the common preamble and shared campaign contract.

Task 4: implement the accepted B6/B6a groundwork in attributable tranches. Stop
between tranches if an assumption or migration decision differs from the approved
groundwork.

Recommended order:
1. additive stored-WorkoutLoad/revision schema and populated upgrade tests;
2. repository API and pure DerivationInputs assembly, not yet selected by UI;
3. deterministic backfill through the existing LoadEngine;
4. invalidation hooks for every approved input, with same-count negative controls;
5. independent shadow comparison against the frozen pre-flip baseline;
6. narrow hydration/selection flip;
7. remove the launch dependency on whole-trace construction and make detail reads
   lazy without changing chart/detail behavior.

Do not change scoring formulas or begin the later load redesign. Test interruption,
late trace, Health cache change/revocation, correction/exclusion, RPE, match,
commute, plan/move, profile/zones/FTP, source merge and engine-version changes.
Include unchanged-count source replacements and a global power-calibration change
that invalidates every affected power-only workout. Prove deterministic rebuild,
no hidden singleton eligibility input and no self-referential parity claim.

Manual-campaign decision: mandatory on a physical device in Release. Execute the
campaign designed in Task 3 and update it from current labels. Capture before/after
Today/Week/Plan/Progress values from the frozen independent report, same-count edit
invalidations, first-free-turn/longest-stall and Detail-store timing. Open a rich
trace and a zero-length trace through existing links; prove lazy detail behavior,
rotation/interaction and no value drift. Restore the shared scheme to Debug and
restore every authored test edit.
~~~

---

## Task 5 — Resolve and execute B7 review persistence

### The circular gate that must be decided

Current documents say all of these:

1. B7 must wait for a real review.
2. A real AI review is blocked while its evidence has Strava lineage.
3. Health removes that lineage only after D7 exits.
4. D7 cannot exit until B7 passes.

That is a circular dependency. No AI may solve it by sending prohibited evidence,
creating a fake production review, or calling a rehearsal “real.”

The recommended privacy-safe resolution is: accept B7 persistence on a legitimate
empty device state plus a deterministic local full-graph fixture that never calls
the model and never affects `ReviewDue`; defer the first real policy-permitted
review and its final device proof to Health C6. Alternatives are to build an
explicit athlete-authored local non-AI review path now, or move the required Health
work ahead of B7. Bruno must select/amend the gate before implementation.

### Exit gate

The gate is explicitly approved; full review/evidence/lineage/proposal/change/watch
identity and ordering hydrate from SQLite; create/delete is atomic; proposal restore
is safe; source-purge behavior is proven; production contains no fabricated review
and no prohibited outbound transfer occurred.

### AI prompt 5

~~~text
Apply the common preamble and shared campaign contract.

Task 5: resolve the B7/Health circular dependency first, then execute only the
approved privacy-safe B7 contract. Do not call Claude/another model, send a review
payload, or create a fake record in production.

Read ADR-0002, review-data-pool.md, ReviewRunner, ReviewPayload, ReviewDue,
ProposalStore, ReviewRepository/read-back, rehearsal code and the current device
state. Present the three gate options stated in this plan, their schedule/product/
evidence consequences and a recommendation. Stop for Bruno's decision.

Under the recommended fixture-plus-legitimate-empty option:
- use a local in-memory/disposable full graph with multiple evidence lineage rows,
  ordered proposals/changes/watches and duplicate timestamps/record keys;
- ensure it cannot affect ReviewDue or production history and makes no network call;
- implement DB-first atomic full-graph create/delete and database hydration;
- fix the current `ProposalStore.add` contract so a failed repository/legacy save
  cannot append/publish memory and report success; never ignore a persistence Bool;
- reconstruct the rollback mirror/ProposalStore.Record exactly and safely restore;
- represent available, policy-purged and unreadable evidence distinctly rather
  than reconstructing purged evidence as an invented empty string;
- preserve record identity and ordering;
- test partial failure, duplicate identity/time, invalid references, relaunch,
  deletion, source-lineage purge and unrelated authored families;
- document that real policy-permitted device proof remains a C6 closure item.

If Bruno selects a local non-AI path or sequence change, write separate accepted
groundwork before code rather than adapting the fixture plan silently.

Manual-campaign decision: mandatory, but its scope follows the chosen gate. For
the recommended option, run the full graph only in a disposable fixture and prove
the real device's legitimate-empty B7 hydration/read-back without fabricating a
review. Capture structural counts/IDs/order only; redact evidence prose. Test
restore/delete/relaunch on the fixture. Schedule the first real review-history UI
campaign at C6 when Health-derived evidence is permitted.
~~~

---

## Task 6 — Write B8 operational-state groundwork and close its field tranche

### Finding

Runtime authority remains split across SQLite, JSON, `UserDefaults` and transient
memory:

- Strava cursor/high-water and last sync;
- detail failure and intentional-no-stream sets;
- queue/retry/lease state;
- rejection receipts;
- background result/scheduling state;
- content/data revisions.

The `rejection` table omits `RejectionReceipt.label` and `dateIsKnown` and the
verifier checks mostly counts. `work_queue.subjectID` remains provider/external
identity without an explicit account/source/canonical contract. The four one-shot
legacy backfill markers are upgrade state and should remain preferences until D8.

### Exit gate

Groundwork defines source identity, high-water/checkpoint semantics, rejection
fidelity, queue lease/recovery/backoff, terminal detail states, B6/B8 revision
ownership, background diagnostics, migrations, compatibility import, kill points,
patch decomposition and the physical campaign. Only an independently reviewable
field/schema tranche may land here; runtime authority does not flip.

### AI prompt 6

~~~text
Apply the common preamble and shared campaign contract.

Task 6: write D7-B8 groundwork and, only if independently attributable, close the
rejection-field schema/repository tranche. Do not flip cursor, queue or revision
authority yet.

Inventory every read/write of strava.cursor, strava.lastSync, strava.rejections,
detail.failed, detail.noStreams, sync_state, work_queue, content_revision,
background result/schedule preferences and every write-through trigger. Draw the
real transaction boundaries and every path that advances a high-water value.

Decide and document:
- cursor/high-water versus durable checkpoint and late-arrival behavior;
- account/source/canonical identity for queue subjects;
- queue claim/lease, stale-running recovery, attempts, bounded backoff,
  cancellation and redacted last error;
- successful-no-detail/no-stream versus permanent rejection versus retryable
  failure;
- which background fields are runtime authority versus diagnostics;
- one B6/B8 content/data revision contract;
- Strava scalar checkpoint versus future opaque Health anchor;
- the four one-shot legacy backfill markers that stay as upgrade preferences.

Add field-coverage tests proving the current rejection omissions. Design/add an
additive migration for verbatim label and dateIsKnown, preserving legacy unknown
state rather than inventing values. Include populated upgrade, repository
round-trip, unknown enum/value and verifier/read-back tests. Do not edit the old
migration.

The source transaction contract is non-negotiable: source rows + deletions +
details/recordings in the batch + rejection receipts + content/data revision +
checkpoint commit atomically after network I/O completes.

Manual-campaign decision: no physical execution is required for pure groundwork,
but the full Task-7 termination campaign is mandatory and must be written now.
Derive exact current Settings/Database/background controls from source; specify
safe one-shot internal kill points before transaction, during rollback,
post-commit/pre-publish, queue claim and queue completion. For each, state expected
row count, revision, checkpoint, lease and relaunch result and which redacted
diagnostic must be built first.
~~~

---

## Task 7 — Implement B8 atomic operational authority

### Exit gate

Activities/details/rejections and their checkpoint/revisions cannot diverge across
any injected interruption; queue items claim/recover/retry deterministically;
production publishes only after DB commit; legacy mirrors are diagnostic; cursor,
receipts, queue and revision provenance all report SQLite; the physical campaign
passes.

### AI prompt 7

~~~text
Apply the common preamble and shared campaign contract.

Task 7: implement the accepted B8 groundwork in separate repository, orchestration,
shadow and flip tranches.

Network calls remain outside database transactions. One repository transaction
must apply source additions/changes/deletions, canonical rows, received details/
recordings, rejection receipts, content/data revisions and checkpoint. Only after
commit may ActivityStore/DetailStore/BackgroundRefresh publish memory and write
temporary JSON/UserDefaults mirrors. A cancelled or expired task cannot advance
the checkpoint.

Build queue APIs for idempotent enqueue, atomic claim/lease, completion, bounded
retry/backoff, permanent terminal outcomes, cancellation and stale-running launch
recovery. Do not let a scene event or whole-world write-through be the recovery
mechanism. Translate provider IDs at the repository boundary; new operational rows
must have explicit account/source/canonical identity.

Add redacted diagnostics before the flip: source checkpoint/high-water, batch ID/
result, content/data revision, queue totals by kind/state, oldest due, stale-running
recovery, receipt source, mirror failure and background scheduling/result.

Automated fault tests must cover: before transaction, after row insert, after
deletion, before revision, before checkpoint, post-commit/pre-publish, duplicate
delivery/enqueue, late activity/detail/trace, source deletion, 404/no-detail,
successful-no-stream, retryable error/exhaustion, expiration, cancellation,
stale-running relaunch, alias/multi-source identity and mirror failure.

Manual-campaign decision: mandatory on a physical phone with Release/internal
instrumentation. Execute the campaign written in Task 6. Use current Settings
sync/background controls and Database diagnostics; force-quit at each safe one-shot
kill point; foreground/relaunch; compare the app lines with an independent
downloaded DB/container read. Exercise duplicate delivery, late detail, no-stream
and retry exhaustion without exposing source IDs/routes/private errors. Remove all
fault switches and restore the starting queue/revision state.
~~~

---

## Task 8 — Close the versioned source-to-database field matrix

### Finding

The August external comparison proved equality for fields its one-off script
explicitly mapped. It did not prove literal information identity, and neither the
script nor a machine-readable coverage matrix is in the repository.

Known items requiring preservation or an explicit accepted classification include:

- `plan.meta.source`;
- source ordering for plan weeks/sessions/exercises (repository reads may sort by
  UID rather than source ordinal);
- fractional fetched timestamp precision;
- Strava gear `primary`;
- athlete/constants fetched/cache version metadata;
- all binary/data-valued preferences;
- match/rejection fields owned by Tasks 1 and 6;
- B5 kind/retirement fields.

### Exit gate

Every modeled JSON field, nested collection, supported vocabulary and declared
preference has exactly one versioned classification: preserve, normalize, derive
or intentionally exclude. Preserved fields round-trip. Normalizations/exclusions
are deterministic, tested and accepted. CI detects an added but unmapped source
field.

### AI prompt 8

~~~text
Apply the common preamble and shared campaign contract.

Task 8: create the complete versioned source-to-database field matrix and close
the remaining mapping gaps before final verification.

Generate the inventory from Codable models, plan.json, every LegacyStore shape,
DataLifecycle.preferenceKeys and repository schemas. For every field record:
source path/type/nullability/order/vocabulary; database target; read-model consumer;
classification (preserve/normalize/derive/exclude); exact rule/reason; owner task;
and automated test. Nested arrays and Data preferences are fields, not footnotes.

Verify Tasks 1, 5, 6 and B5 closed their owned fields. Implement plan.meta.source
and semantic plan ordering with additive schema/repository changes if they are
accepted as preserved. Explicitly obtain/document decisions for fractional timestamp
rounding, gear primary and athlete/constants cache metadata. Never use “not needed”
without naming the consumer/retention rationale.

Add a machine-readable artifact consumed later by the auditor and a check that
fails when a modeled source field/preference/vocabulary lacks exactly one entry.
Tests must distinguish missing/null/empty/zero, preserve required list order,
exercise legacy decode and reject/diagnose unknown vocabulary rather than silently
coercing it.

Manual-campaign decision: required for the final current-device field closeout,
although most mapping tests are automated. Build a read-only campaign using a fresh
preference-inclusive snapshot and Settings → Database read-backs. Derive expected
values from direct legacy snapshot bytes, not hydrated stores; select representative
plan order, gear, match and rejection states; record only structural/redacted values.
Do not mutate data to manufacture a missing source case. Any field not observable
on this device remains fixture evidence and must be labelled as such.
~~~

---

## Task 9 — Build authoritative backup, readable export, atomic restore and lifecycle receipts

### Finding

Three artifacts currently risk being confused:

1. **Protected legacy snapshot** — lossless migration inputs, including declared
   preferences, excluding `db`.
2. **Authoritative database backup** — does not exist.
3. **Human-readable personal export** — JSON stores and lossy preference
   descriptions, excluding SQLite; not restorable.

The database is marked `isExportable: false`. No safe live-WAL backup or staged
restore exists. Export lifecycle schema exists but production does not durably
record the complete operation. Database close/reopen coordination is absent.

### Exit gate

A transaction-consistent protected SQLite backup can be retained off-device and
atomically restored after validation; a versioned readable export accounts for all
categories and preserves declared binary preferences losslessly without secrets;
both have durable receipts; tamper/wrong-version/failure paths cannot damage the
live database.

### AI prompt 9

~~~text
Apply the common preamble and shared campaign contract.

Task 9: implement three explicitly named artifacts and their lifecycle receipts.
Do not call a legacy snapshot a database backup and do not claim the readable
export is restorable unless a separately versioned import contract is built.

Build authoritative DB backup with SQLite/GRDB's transaction-consistent backup
mechanism. Never copy a live sqlite file while ignoring WAL/journal state. The
manifest includes artifact/schema version, app patch/commit, migration/evidence
identity, created UTC, account scope where appropriate, logical dataset fingerprint
and per-file hashes. Apply file protection at creation and verify it.

Build staged restore: validate manifest/hash/version/account; copy to a temporary
area; run integrity and foreign-key checks; quiesce writers and close the live DB
queue; retain a rollback copy; atomically swap; reopen/migrate/recheck authority and
fingerprint; automatically restore the prior DB on any failure. Do not construct
normal stores during restore.

Repair readable export so the database authority is represented in a stable,
versioned human-readable form, all DataLifecycle categories are accounted for,
tokens/keys/raw sensitive material are excluded and Data preferences use a
lossless typed/base64 representation. Correct stale AuthoredExport counts/coverage,
including preference-backed authored/operational data where policy permits. Wire
durable export/backup/restore lifecycle receipts.

Keep Strava disconnect disabled. Replace any path that could remove an open
authoritative database with a fail-closed preview/guard; row-level purge arrives
only after Health reconciliation.

Automated tests: concurrent-write/WAL backup, full authored+operational round-trip,
tampered/corrupt/missing manifest, wrong schema/account, reopen failure rollback,
file protection, temporary cleanup, no credential leakage and durable receipts.

Manual-campaign decision: mandatory. Add progress, manifest, integrity, rollback
and reopen diagnostics first. Build exact current Settings data/Database backup,
readable export and restore navigation. Run restore only on a cloned/disposable
container; compare pre/post fingerprints and authored/operational state; test a
tampered artifact refusal; download and retain the verified backup/export/receipt;
prove rollback and clean up. Never use the only phone database as the first restore
test.
~~~

---

## Task 10 — Build the external `.xcappdata` auditor and exact dataset binding

### Finding

`tools/` has no cutover auditor. `SemanticVerifier.fingerprintCheck` covers a
small activity fingerprint, not the dataset. `runsSinceVerified == 0` proves only
that the ledger did not move. Import and verify read live stores independently;
the snapshot name on the ledger is not proof of input bytes or current DB state.

### Exit gate

A committed read-only tool reproduces JSON/preferences/snapshot/SQLite comparison;
one versioned `DatasetIdentity` binds validated source manifest, logical source,
logical database, schema/app and field-matrix evidence to the verified ledger row;
any relevant source/DB change blocks verification or activation.

### AI prompt 10

~~~text
Apply the common preamble and shared campaign contract.

Task 10: create a reproducible external audit gate and bind migration verification
to exact immutable evidence. Stop before B9 activation.

Build a read-only tool under tools/ that accepts an .xcappdata bundle or extracted
container. It discovers live legacy stores, filtered preferences/snapshots,
SQLite and sidecars; never mutates the package; copies DB+WAL/hot journal to a temp
workspace before recovery/open; validates JSON/plist parsing, snapshot manifests/
hashes, SQLite integrity/foreign keys, schema/migrations and counts; and compares
field-by-field through Task 8's matrix/normalizations.

Emit versioned JSON plus concise Markdown. Use stable natural-key/canonical ordering
so generated UUIDs do not create false differences. Report missing/null/empty/zero/
unreadable separately. Redact credentials, free text and private coordinates.
Synthetic tests include exact match, changed same-count field, missing input,
corrupt DB, WAL/hot journal, fractional time, array order, binary preference,
unknown vocabulary and deterministic repeat.

Design/implement additive ledger identity fields for validated snapshot manifest
digest, raw source-package fingerprint, logical source fingerprint, database
logical fingerprint, matrix/evidence version, verified UTC, schema and patch.
Final import must read an immutable validated snapshot, or quiesce writers and
prove the live source identity is unchanged before/after. Verification compares
that independent evidence with DB and records both identities. Activation later
recomputes the DB identity and requires an exact match.

Negative controls: preference-only change changes source identity; post-import
source mutation refuses verify; post-verify DB mutation refuses activate; one
same-count field change fails; tampered/incomplete snapshot fails; a newer running/
pending/failed/interrupted run blocks; UUID-only changes do not affect logical
identity.

Manual-campaign decision: mandatory. Build exact current Settings → Database
snapshot/import/verify/ledger steps and Xcode Devices and Simulators container
download steps. Capture snapshot/manifest digest, run ID, evidence version and
source/DB fingerprints from redacted app diagnostics; run the tool; retain audit
JSON/Markdown and package hash. First capture before import, then a second
post-import/post-verify quiescent package so the evidence is self-contained.
~~~

---

## Task 11 — Build B9 fail-closed activation groundwork

### Finding

`migrationFailureBlocksTheApp` is still false. `activateVerified` and
`recordActivation` have no production activation call. The launch failure state
can finish the gate and construct normal content. Retry is not a proven reopen.
The external activation mirror is written after ledger activation; a kill between
the two needs a conservative protocol. Documentation promises protected-snapshot
restore even though only Task 9 creates a real post-activation DB restore.

### Exit gate

All B1-B8/read/backup/audit prerequisites are machine-evaluated; owner rollback
decisions are recorded; activation/fail-closed/retry/restore code and every negative
control exist; normal stores/network cannot initialize under blocked authority;
activation remains off pending explicit approval.

### AI prompt 11

~~~text
Apply the common preamble and shared campaign contract.

Task 11: build B9 activation eligibility, fail-closed recovery and negative
controls. Do not activate the production database.

Create a pure eligibility report covering: all B1-B8 families database-fed;
current B6 cache generation; B7 accepted proof rule; latest verified run bound to
current DatasetIdentity/evidence/schema; zero unexplained independent audit
differences; database-first authored/operational writes; authoritative backup,
readable export and restore; disposable authored repair/removal proof; and Strava
disconnect explicitly blocked.

Stop for Bruno's post-activation rollback choice (export-assisted is the documented
recommendation; alternatives read-only/unsupported), fresh-install behavior and
activation evidence contract if not already decided.

Replace launch's fail-open path with explicit opening/ready/blocked/recovery states.
Missing/corrupt/incompatible/fingerprint-invalid DB, migration/integrity/ledger/
bootstrap failure must show recovery only, with retry/reopen, redacted diagnostics,
authoritative DB-backup restore and export guidance. Normal stores, auth and network
work must not be constructed. Legitimate empty remains a valid ready state.

Design the ledger+external mirror protocol so every kill point can only over-block,
never authorize stale legacy content. Test mirror true/no activated row, activated
row/no mirror, ledger/mirror write/read failure, stale verified run, newer mutation,
wrong cache/fingerprint, missing runtime JSON and retry after failure. Remove
suppressed critical errors once authority depends on them.

Make DataLifecycle activation-aware and prevent any disconnect/delete path from
removing the authoritative database while open. Keep actual Strava disconnect
refused with a user-facing reason until Task 18.

Manual-campaign decision: mandatory to design, not yet to perform the activation.
Build a safe disposable-database fault-injection campaign covering recovery UI,
retry, diagnostics, tampered backup refusal, successful restore, missing/corrupt DB,
runtime JSON absent and authored save/relaunch. Derive exact labels from the new UI
and specify independent fingerprint/audit expectations. No production corruption.
~~~

---

## Task 12 — Activate SQLite and execute the B10 Release-device campaign

### Exit gate

Only the newest verified run over the exact current dataset activates; mirror and
ledger resolve conservatively across kill points; every production read/operational
state uses SQLite; runtime legacy files can be moved aside; every principal feature,
authored mutation, backup/export/restore and recovery state passes on a Release
physical device; Strava remains connected and source ingest continues.

### AI prompt 12

~~~text
Apply the common preamble and shared campaign contract.

Task 12: perform B9/B10 only after Task 11's eligibility report is entirely green.
If any prerequisite is false, stop without changing activation state.

Before activation require Bruno's explicit approval. Record patch/commit/build,
device/iOS/timezone/schema, queue/revision/cache state and accepted rollback. Create
and independently verify a fresh legacy snapshot and authoritative off-device DB
backup/export. Run the final immutable-source import/verify; record snapshot digest,
run/evidence version and source/DB fingerprints; prevent or detect any intervening
write.

Activate in the checked transaction, then record/read back the conservative mirror.
Switch the single persistence authority; never infer it from repository emptiness.
Relaunch twice and re-evaluate identity. Do not disconnect Strava.

Manual-campaign decision: the complete B10 campaign is mandatory. Use this table:
screen/flow | independent baseline | D7 value/state | result | evidence file.
Cover Today, Week, Plan, Progress, every reachable activity detail/route/chart/split,
weather/gear, notes/RPE, commute/matching, Review legitimate-empty/policy state,
Settings/Database/Health/data controls, load, background/queue, backup/export/
restore and lifecycle preview. Exercise success, legitimate empty, stale, partial,
unavailable, failed and recovery states.

After another backup, move every runtime LegacyStore input aside (do not delete)
on a disposable/restorable copy and repeat cold launch, relaunch, authored saves and
principal screens. Test missing/corrupt/fingerprint-invalid DB only on a disposable
container: recovery UI must be the only app content, then restore. Download the
post-activation .xcappdata, run Task 10's auditor, retain all redacted evidence and
restore temporary files/build settings.

Do not call D7 complete unless all rows pass. D7 completion still does not permit
Strava retirement; it means database-authoritative persistence while Strava remains
the current source adapter.
~~~

---

## Task 13 — Refresh Health coverage and accept raw/canonical contracts

### Finding

The last documented Health census is a useful historical baseline, not a current
cutover measurement. The present Health path reads an in-memory diagnostic cache;
its anchor is not durable, its authorization wording can overstate what the app can
know, and it has no raw workout/quantity/route/event persistence. The existing
`recording_sample` distance alignment cannot faithfully store Health quantities or
routes whose samples have independent timestamps.

### Exit gate

A current physical-device census and authorization truth table exist; raw evidence,
checkpoint, deletion, route/quantity/event, projection provenance and reconciliation
audit contracts are accepted; all canonical duration/title/sport/timezone/indoor/
quality/source-priority policies are decided; migrations and fixture campaigns are
specified but no production Health authority has been enabled.

### AI prompt 13

~~~text
Apply the common preamble and shared campaign contract.

Task 13: write and accept Health C0/C0.1/C0.2 groundwork. Do not make Health
canonical or change source priority in this task.

First refresh the on-device source/coverage census. Distinguish authorization the
app can prove from prompt-shown, unavailable, not-determined and denied/restricted
states; HealthKit intentionally does not reveal every read-denial state. Correct UI
wording and diagnostics where they claim more.

Design additive raw-source storage for:
- opaque anchored-query checkpoint plus reset/expiry metadata;
- raw workout identity, source/bundle/device/version, modification/deletion facts;
- timestamped quantity samples with unit and source metadata;
- routes and independently timestamped route points;
- workout events/pauses and available metadata;
- projection provenance, quality/completeness and projector version;
- durable reconciliation candidates/decisions/audit without prematurely merging.

Do not force independently timed Health evidence into distance-aligned
recording_sample. Decide whether supported original payloads are retained, and set
retention/export/revocation rules. Write the transaction boundary: raw additions,
deletions, projected rows, queue/revision and new anchor commit together; on failure
the previous anchor remains authoritative.

Decide source-neutral canonical policy for sport/subtype, local date/timezone,
title, elapsed/moving/paused duration, distance, zero versus missing, indoor,
measured versus estimated, route privacy, edits/deletions, quality/partial state,
source priority and future policy versioning. Decide whether app-facing Activity
IDs move to canonical UUIDs now or use a tightly time-bounded adapter, with explicit
authored-link migration and rollback.

Produce the populated-upgrade fixtures, repository/coordinator interfaces,
threat/privacy analysis, patch decomposition and C1/C2/C3 negative controls. Do not
store a JSON blob as a substitute for queryable identity/provenance unless every
trade-off is explicitly accepted.

Manual-campaign decision: mandatory for C0 on a physical phone. Build and execute
a campaign from the current Settings -> Apple Health navigation. Copy the redacted
coverage/source report and independently compare counts/date ranges/source bundles
against Health data available on the phone. Include missing permission, changed
permission, no route, delayed route, edited/deleted workout, third-party writer and
timezone cases. The groundwork must also contain the exact future C1/C2 campaign,
including the redacted raw/checkpoint diagnostics that must be built before it runs.
~~~

---

## Task 14 — Build durable Health workouts, quantities, routes and events

### Exit gate

Health C1/C2 is durable, idempotent and restart-safe: observer delivery, foreground
catch-up and anchored additions/deletions converge through one transaction; raw
workouts, quantities, routes and events can reconstruct supported source evidence;
pending/delayed evidence is explicit; the physical-device interruption campaign
passes. Strava is still connected and remains production priority.

### AI prompt 14

~~~text
Apply the common preamble and shared campaign contract.

Task 14: implement the accepted C1/C2 raw Health ingest contract. Do not reconcile
or promote Health above Strava yet.

Build a Health adapter, repository and coordinator behind source-neutral protocols.
Register observers early enough for background delivery, enable the approved
delivery types, and route observer wakes plus foreground catch-up through the same
anchored batch engine. Complete HealthKit callbacks promptly while durable work is
queued. Persist the opaque anchor only in the same commit as additions, deletions,
raw evidence, projection/work state and revision.

Fetch supported quantities, route objects/points and workout events without
assuming identical sample clocks. Model delayed/absent routes and partial quantity
availability as state, not empty success. Keep source metadata and measured units;
do not invent unavailable pauses, coordinates, distance, HR or power. Handle
updates, duplicate delivery, deleted objects, anchor invalidation/reset and
permission changes deterministically.

Add populated migration, repository, concurrency and coordinator tests. Cover
duplicate batches, crash before/after commit, queue lease expiry, repeated observer
wakes, foreground/background overlap, deletion before projection, route arriving
later, corrupt/expired anchor, authorization changes and samples from several
devices/apps. Prove an unchanged replay performs no logical mutation.

Manual-campaign decision: mandatory on a Release physical device. Build the full
C1/C2 campaign before execution, using exact current Settings -> Apple Health and
Settings -> Database labels. Add redacted checkpoint, pending-work, raw-count and
last-batch diagnostics first. Exercise a run, ride, paused workout, swim or other
available structured sport, strength/non-distance workout and a third-party-written
workout; include delayed route, edit and delete where the source app permits it.
Force-quit and relaunch between delivery phases, wait for background observation,
then download the container and independently query/audit SQLite. Record unsupported
cases rather than simulating them. Strava network/source priority must remain
unchanged throughout.
~~~

---

## Task 15 — Build canonical projection and source reconciliation

### Finding

SQLite currently has canonical IDs and aliases internally, but app-facing activity
identity and many source assumptions remain Strava-shaped. A second source cannot
be added safely by matching timestamps alone or by letting the richer row overwrite
the thinner one. Raw source facts, canonical projection and reversible source
association must stay separate.

### Exit gate

Health C3/C4 produces deterministic, versioned source-neutral activities/details/
recordings and explicit reconciliation candidates. Automatic and reviewed merges
are explainable and reversible, double claims are impossible, conflicting raw facts
remain intact, and notes/RPE/commutes/matches/reviews survive merge, unmerge, source
update and source deletion.

### AI prompt 15

~~~text
Apply the common preamble and shared campaign contract.

Task 15: implement the accepted C3 canonical projection and C4 reconciliation
contract. Strava remains connected; do not revoke or purge it.

Remove provider-specific identity from domain-facing repository contracts. If the
accepted design changes app-facing IDs to canonical UUIDs, migrate every authored
and derived foreign key with aliases and a populated upgrade test. If a temporary
adapter was approved, add a tested removal deadline and prevent new provider IDs
from entering UI/domain state.

Project Health raw evidence through one versioned source-neutral mapper. Define
honest availability for summary/detail/recording, moving/elapsed/paused durations,
route, HR/power/cadence/altitude, laps/splits/swim/best efforts and provenance.
Replace stravaMovingSeconds and similar provider-labelled domain inputs with the
approved neutral fact; never infer a measured value from a display fallback.

Build reconciliation as its own deterministic service. Version its candidate
algorithm and field-priority policy; store score/reasons/evidence; separate high-
confidence automatic associations from explicit review; prohibit one source record
from being claimed twice. Retain raw facts and make merge/unmerge/reproject safe.
Preserve canonical identity and all authored links. Source deletion must recompute
from surviving evidence or expose unavailable state, never silently erase the
athlete's authored facts.

Test DST/timezone boundaries, near-simultaneous doubles, multisport, manual entries,
third-party duplicates, thin Strava versus rich Health, rich Strava versus thin
Health, indoor/zero/missing distance, edited duration, route belonging to only one
source, source deletion and reconciliation policy upgrades. Add sabotage tests for
double claim and authored-link loss.

Manual-campaign decision: mandatory. Build a deterministic fixture campaign plus a
physical overlap campaign. If reconciliation cannot be inspected safely in current
navigation, build the smallest redacted Settings diagnostic/review UI before asking
Bruno to test it. Use actual activity links from Today/Week/Plan or diagnostics,
not an invented Activities tab. Compare candidate reasons and projected fields to
direct raw-source rows and captured source records; exercise merge, reject, unmerge,
relaunch, update and delete. Redact precise route points and free-text notes.
~~~

---

## Task 16 — Recover gaps and rebuild every Strava-dependent feature

### Exit gate

Health C5/C6 is complete: accepted historical gaps are recovered or explicitly
classified; every product feature has a source-neutral input and honest degraded
state; athlete zones/FTP, gear, weather, matching, load and review no longer require
Strava; the deferred first policy-permitted review proof closes B7 if evidence is
available. No unsupported metric is fabricated.

### AI prompt 16

~~~text
Apply the common preamble and shared campaign contract.

Task 16: execute Health C5 historical recovery and C6 feature-dependency closure.
Do not retire Strava in this task.

Create a durable gap ledger from the current source/Health/database census. For
each gap choose: recover with supported FIT/TCX/GPX import, retain a permitted
canonical summary, mark unavailable/partial, or explicitly accept loss. Implement
only approved file formats. Preview before mutation; hash the original import;
parse atomically and idempotently; preserve source/provenance and import receipt;
never convert an absent metric into a measured one. Decide original-file retention,
route privacy and re-import/version behavior.

Replace every remaining Strava-owned product dependency with an app-owned or
source-neutral contract: athlete profile facts used by the app, HR zones, FTP,
gear identity/category/retirement/assignments and history, weather enrichment,
matcher/moves/commutes, notes/RPE, derived load/Progress, detail presentations and
review evidence. Classify what Health can supply, what the athlete authors, what a
file import supplies and what becomes visibly unavailable. Do not present last-
known Strava athlete metadata as current unless labelled and retained by policy.

When Health-derived review evidence is policy-permitted, perform the deferred B7
real-path proof without mixing prohibited Strava evidence. If no eligible review is
due, retain the accepted fixture/legitimate-empty gate and schedule the first real
run; do not fabricate one or weaken ReviewDue. Verify create, hydrate, delete,
export, source purge and lineage behavior for whatever real run is permitted.

Add a machine-readable dependency matrix mapping each visible feature and derived
field to source, repository, availability semantics, lineage, purge behavior and
test. Fail invariants on direct Strava references outside the adapter/lifecycle
boundary.

Manual-campaign decision: mandatory. Build disposable FIT/TCX/GPX fixtures with
known expected values and an on-device import campaign with preview, duplicate,
malformed, partial, cancel, relaunch and cleanup. Then build the full C6 product
matrix across Today, Week, Plan, Progress, reachable activity details and Settings.
Derive expectations from Health/raw rows, import fixtures, authored settings and
the pre-cutover baseline—not another presentation screen. Include missing data and
permission-loss rows. Run the first real review campaign only if policy and due
state genuinely permit it; capture redacted structural evidence, not review prose.
~~~

---

## Task 17 — Run the Health/Strava shadow and disconnected rehearsal

### Exit gate

During the agreed observation window, Health ingest/reconciliation has no
unexplained loss, duplicate or feature drift. With Strava deliberately unreachable
but credentials retained, a new real workout reaches SQLite, Today/Week/Progress
and its supported detail state; edits/deletions/background delivery converge; the
rollback rehearsal succeeds. No remote revocation or lineage purge has occurred.

### AI prompt 17

~~~text
Apply the common preamble and shared campaign contract.

Task 17: execute C7 shadow observation and a reversible disconnected rehearsal.
Do not revoke Strava, delete credentials or purge source rows.

Before starting, define observation duration, supported workout/source matrix,
acceptable numeric tolerances, zero-unexplained-difference rule, owners and rollback.
Build a redacted daily convergence report over raw Health arrivals, projected
activities, reconciliation decisions, duplicates, edits/deletions, pending routes,
derived recomputation and visible feature results. Compare independent source facts;
do not use Strava parity as truth where the accepted Health policy intentionally
differs.

Exercise real representative workouts available during the window: at minimum the
supported run/ride/non-distance mix, plus paused, third-party, delayed, edited and
deleted cases when possible. Investigate every unexplained item to a policy, source
limitation or bug; accepted limitations must be visible in product state and docs.

For the disconnected rehearsal, preserve credentials and a fresh backup, then
block/disable only Strava network refresh through an approved reversible mechanism.
Cold-launch and relaunch. Create a new real workout and prove observer/background or
foreground catch-up, canonical projection, reconciliation, Today/Week/Progress,
supported detail, load and export while Strava is unreachable. Re-enable Strava and
prove convergence without duplicates. Exercise the accepted database rollback path.

Manual-campaign decision: this task is itself a mandatory Release-device campaign.
Build the full document before the observation window using exact current taps and
redacted Settings -> Apple Health/Database diagnostics. Each row must name its
direct Health/source/raw-table expectation, app observation, tolerance and evidence.
Include network-negative proof, force quit/background timing, a downloaded final
container, cleanup, restored network state and credential-presence check. A missing
representative case remains explicitly open; it is not silently waived.
~~~

---

## Task 18 — Activate Health, revoke Strava and purge restricted lineage

### Destructive boundary

This is the first task that may disconnect Strava. It requires a separate explicit
approval after Task 17, a fresh independently verified backup/export and a completed
preview. The current disconnect implementation must not be reused as-is.

### Exit gate

The resumable C8 state machine has a durable receipt; Strava work and network use
are stopped; remote revocation outcome is checked; local credentials are removed at
the safe point; only policy-selected Strava lineage/evidence is purged; permitted
canonical and authored records survive; no restricted review evidence remains; a
fresh Health workout ingests immediately afterward.

### AI prompt 18

~~~text
Apply the common preamble and shared campaign contract.

Task 18: design, test and—only after Bruno's explicit destructive approval—execute
Health activation, remote Strava revocation and lineage-aware local purge. Do not
map this onto the old folder-delete coordinator.

First build a persisted resumable state machine with preview and receipts:
1. stop/cancel Strava refresh, background work and retries;
2. create and independently validate the authoritative DB backup/readable export;
3. fail closed on unknown lineage, unresolved reconciliation or stale identity;
4. prove supported product operation with Strava network unavailable;
5. call the supported remote revoke endpoint and classify checked success, already
   revoked, offline, timeout, 4xx and 5xx without pretending success;
6. if remote revoke is unresolved, keep local stop state and expose retry—do not
   erase the only credential needed to retry unless the accepted policy says so;
7. transactionally activate Health source priority and purge only the approved raw
   Strava rows, derived evidence and restricted review evidence;
8. preserve canonical rows backed by permitted evidence, aliases required by ADR,
   authored notes/RPE/commutes/matches/moves/reviews allowed by policy and bundled
   plan data; reproject/recompute affected derived rows;
9. delete Keychain credentials with a checked result at the approved commit point;
10. remove/suspend remaining Strava tasks/config/network use, close/reopen database
    safely where lifecycle work requires it, and trigger immediate Health catch-up;
11. finalize a durable redacted lifecycle receipt and post-state fingerprint.

Test every kill point and repeat/retry, offline revoke, server failures, Keychain
failure, open database handles, unknown lineage, mixed-source canonical activity,
review-evidence purge, authored-link preservation, rollback-before-irreversible and
post-commit relaunch. Make retry converge without a second purge or duplicate rows.

Manual-campaign decision: mandatory and destructive. Build and pass the full
campaign first against a cloned/disposable container and test account/credential
boundary. The production campaign must state the irreversible point, expected
remote-account check, exact preview counts by lineage/table, backups and hashes,
rollback limits, exact UI diagnostics and emergency stop. Require Bruno to confirm
the preview immediately before execution. Afterward prove network-negative launch,
absence of credentials/work/restricted lineage, preserved authored data and one new
real Health workout through the full product path. Retain redacted receipts; never
capture tokens or precise routes.
~~~

---

## Task 19 — Retire runtime JSON and remaining Strava code

### Exit gate

After the accepted compatibility window, D8 has one executable legacy inventory;
runtime JSON writers then readers are removed; obsolete preferences/journals/
endpoints/config are gone or held only in a bounded upgrade component; fresh and
oldest-supported upgrades, repeated migration, export/restore and DB-only Release
campaigns pass; authoritative current export is generated from SQLite.

### AI prompt 19

~~~text
Apply the common preamble and shared campaign contract.

Task 19: execute D8 only after Task 18 and the accepted stable compatibility window.

Stop first for the D8 contract if it is not already accepted: oldest supported app/
schema, one-release-window duration, rollback promise, backup requirement, owner
and deletion date. Build a machine-readable inventory with one row per legacy file,
preference, journal, Keychain item, snapshot/receipt, URL/background trigger,
endpoint, entitlement, reader, writer, destination, migration version, removal
condition, owner and automated/manual proof.

Remove or disable legacy writers before readers. Keep any required one-time upgrade
reader isolated under a Data/Upgrade/LegacyJSON boundary; it must be idempotent,
version-gated, absent from normal runtime and have a dated deletion condition.
Remove obsolete dual-write comparisons, file-era disconnect paths, retired Strava
client/model/config code, tasks and build settings only after the inventory proves
no supported upgrade needs them. Do not delete protected historical evidence merely
because it is no longer runtime input.

Replace stale JSON 'recovery/export' language: after writers stop it is frozen
migration evidence or a bounded rollback input, not a current export. Current
readable export/restore comes from the SQLite authority built in Task 9.

Add source-tree invariants and fresh-install, oldest-supported populated upgrade,
repeat-upgrade, partial/corrupt legacy input, no-runtime-reader, export/restore and
sunset tests. Prove no normal launch touches legacy payloads and no Strava endpoint,
credential or background identifier remains outside an explicitly retained upgrade
fixture/document.

Manual-campaign decision: mandatory. Build a disposable oldest-supported upgrade
campaign and a clean-install/DB-only Release campaign. Back up first; upgrade,
relaunch repeatedly, edit authored data, export, restore, move runtime JSON aside,
cold-launch and download the container. Compare to the accepted post-Task-18
database/product baseline and inventory. Verify no files/preferences are recreated,
no network request targets Strava and the bounded upgrade path still works. Restore
shared build settings and retain redacted inventory/evidence.
~~~

---

## Task 20 — Hand off to the behavior-neutral restructure

### Exit gate

The post-D8 baseline is tagged and reproducible; remaining architecture decisions
and dependency/ownership inventories are accepted; R0-R15 can start without mixing
persistence/source-cutover behavior into moves; each restructure tranche retains
the accepted device behavior and finishes with a new peer review.

### AI prompt 20

~~~text
Apply the common preamble and shared campaign contract.

Task 20: prepare and begin the already-approved R0-R15 behavior-neutral restructure
in docs/PLAN-codebase-modernization-and-feature-delivery.md. Do not invent a second
restructure plan and do not combine feature/persistence changes with file moves.

Re-read the modernization plan against the post-D8 tree. Record the new baseline:
tag/commit/patch, green suites, preflight, Release launch/device product matrix,
schema, backup/restore/audit identities and accepted limitations. Resolve every
pre-R0 decision named in that plan, including ownership, module boundaries,
dependency direction, platform seams, observation strategy and compatibility floor.

Generate or refresh inventories for files/types, dependency edges, singletons,
global mutable state, feature ownership, repository/domain/presentation boundaries,
test targets/resources and generated/config inputs. Add architecture checks before
moves. Follow R0-R15 in order, one behavior-neutral tranche at a time: first create
seams and move within the existing app target; create modules only when dependency
evidence proves the boundary. Keep the database/repository/source-neutral contracts
from Tasks 12-19 intact.

Every tranche must compile/test before cleanup, preserve public behavior and update
the inventory. Stop if a move exposes a behavioral bug; fix it as a separately
scoped change with its own evidence rather than hiding it in the restructure. End
with the independent peer review and cleanup gates specified by R15.

Manual-campaign decision: mandatory for the baseline and at each plan checkpoint
that changes app composition, lifecycle, background delivery, navigation or
presentation ownership. Build the initial full behavior-neutral Release campaign
from the accepted Task-19 product matrix and exact current UI labels. Compare each
checkpoint to that independent baseline, including cold launch/relaunch, Health
background catch-up, Today/Week/Plan/Progress, reachable details, authored edits,
Settings diagnostics and backup/export/restore. A purely internal move may cite
that campaign plus automated architecture/behavior evidence only when its risk
assessment explains why no additional manual row is needed.
~~~

---

## Decisions that must not be guessed

Record each decision in the controlling ADR/groundwork before the task shown. An AI
must stop rather than infer a product, privacy or destructive-lifecycle choice.

| Decision | Required before | Recommended starting position |
|---|---:|---|
| Whether a manually selected match may override automatic eligibility | 1 | Keep non-negotiable exclusions absolute; make the picker explain them |
| B7 circular-gate proof | 5 | Legitimate-empty plus deterministic local full-graph fixture; real run at C6 |
| Health-derived load retention/export/revocation | 3 | Persist explicit lineage and invalidate/purge on lost source permission |
| Every lossy source field classification | 8 | Preserve authoritative facts; explicitly version approved normalization/exclusion |
| Post-activation rollback promise | 11 | Export-assisted rollback with a tested authoritative DB restore |
| Health raw evidence representation/retention | 13 | Queryable identities and provenance; originals only where policy and value justify it |
| Canonical app-facing activity identity | 13 | Canonical UUID, with aliases at source boundaries and migrated authored links |
| Health anchor reset/expiry policy | 13 | Transactional anchor; full bounded rescan with visible audit on invalidation |
| Duration/timezone/title/indoor/missing-value rules | 13 | Measured facts first; preserve unknown and expose policy/version |
| Source priority and reconciliation thresholds | 13 | Versioned per-field policy; conservative auto-merge, reversible review otherwise |
| Import formats and original-file retention | 16 | FIT first when needed; add formats only for proven gaps; hash and receipt originals |
| Disposition of unrecoverable history gaps | 16 | Honest partial/unavailable state, never fabricated metrics |
| Remote-revocation failure behavior | 18 | Keep local source stopped and retryable; never report disconnected without evidence |
| Source aliases after Strava purge | 18 | Retain non-secret durable aliases required for identity/audit unless ADR is amended |
| Compatibility window and oldest supported upgrade | 19 | One measured release window with an owner and explicit sunset date |

## Release gates at a glance

### SQLite activation (end of Task 12)

- Every B1-B8 family and operational mutation is database-first.
- The newest verified run is bound to the exact immutable source and DB fingerprints.
- Independent field-complete audit, backup, readable export and restore pass.
- Launch is fail-closed; recovery cannot be mistaken for empty data.
- The Release DB-only campaign passes with Strava still connected.

### Strava retirement (end of Task 18)

- Health background/foreground ingest handles additions, updates, deletions, delayed
  evidence and source reconciliation without duplicates.
- Every accepted product feature has a source-neutral input or honest unavailable
  state; historical gaps and review policy are resolved.
- The shadow/disconnected observation window and fresh-workout test pass.
- Lineage preview, remote revoke, Keychain handling, purge, retry, backup and receipt
  state machines pass every interruption control.
- Bruno has approved the exact destructive preview.

### Legacy/code retirement (end of Task 19)

- The compatibility window has elapsed with no unexplained authority drift.
- The oldest supported populated upgrade and clean install both pass.
- No normal runtime JSON reader/writer or Strava endpoint/credential/work item remains.
- Authoritative export/restore is SQLite-based and the retained upgrade boundary has
  an owner and sunset date.

## Current readiness statement

At the reviewed point, B5 is still active and no task in this document has started.
The database migration is advanced, but the app is not ready to disconnect Strava.
The next action is **Task 0 only**: accept the finished B5 work without modifying it,
freeze fresh evidence and then proceed one prompt at a time. Database activation is
Task 12; Strava disconnection is Task 18; runtime JSON and code retirement is Task
19. Those milestones must remain separate in status reports and release decisions.
