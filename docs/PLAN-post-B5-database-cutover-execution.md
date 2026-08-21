# SUB4 post-B5 execution plan

## SQLite authority, Apple Health cutover, Strava retirement and legacy cleanup

| | |
|---|---|
| **Status** | Sequential execution runbook. **B5 implementation is accepted at patch 433a; one residual physical gear-independence proof closes in Task 0A. Task 0 also closes the evidence, lifecycle and tooling handoff; Task 1 is the next functional product task.** |
| **Reviewed** | 21 August 2026 |
| **Repository/evidence identities** | B5 implementation: patch 433a at `debcfd6`. Final device-observation prose and current verification tree: clean synchronized `main` at `60c52dc` |
| **Recorded B5 verification** | Against `60c52dc`: 1,876 tests in 179 suites and all 15 source invariants. Release physical-device campaign records 22/22, with the row-19 gear-file proof ambiguity explicitly retained for Task 0A. Future tasks must re-measure rather than reuse these numbers |
| **Purpose** | Give a new AI one bounded, dependency-safe task at a time from the end of B5 through SQLite activation, Health replacement, Strava retirement, D8 and the architecture handoff |
| **Current-state evidence** | Current source, tests and accepted device evidence establish behavior. `CLAUDE.md`, README, lifecycle copy and groundwork must be reconciled in Task 0 where they lag source; a disagreement is a defect, not permission to silently redefine the contract |
| **Persistence authority** | `docs/ADR-0003-database-contract.md` |
| **Source-retirement authority** | `docs/ADR-0002-strava-retirement.md` |
| **Project-roadmap context** | `docs/PLAN-codebase-modernization-and-feature-delivery.md` |
| **Post-D8 restructure proposal** | `docs/PLAN-post-database-strava-project-restructure.md` (proposed; Bruno's §24/R0 approval required) |

This document supersedes the post-B5 portions of
`docs/PLAN-database-cutover-findings-and-ai-prompts.md`. That older document is
a patch-399 review and remains useful history; its status labels are not current.
This document does not supersede either ADR or the modernization plan. The source
and tests establish current behavior; accepted ADRs establish intended contracts
unless explicitly superseded. A disagreement must be surfaced and resolved in the
owning task rather than silently making either side true by assertion.

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
close the completed B5 handoff and trustworthy evidence path
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

## Re-baseline after completed B5

The 21 August review separates the accepted implementation slice from the remaining
handoff work:

| Item | Status | Evidence / consequence |
|---|---|---|
| Weather and gear SQLite hydration | **Complete** | Patch 433a; 606 weather rows; 11 gear rows (6 shoes, 4 bikes, 1 unknown); one retired item with the accepted derived date; zero unexplained mapped differences |
| B5 automated implementation acceptance | **Complete** | 1,876 tests in 179 suites and 15 invariants against `60c52dc` |
| B5 Release-device campaign | **22/22 recorded; one targeted proof remains** | Row 19 demonstrated the product state but `athlete.json` had been rewritten during the gear half, so Task 0A repeats only the small network-disabled SQLite-provenance check—not the full campaign |
| Post-B5 Release launch baseline | **Accepted baseline** | longest main-thread stall 0.608/0.613 s; `DetailStore` 0.344/0.349 s; bootstrap 0.055/0.057 s; first free turn 0.035/0.037 s |
| On-phone protected legacy snapshot | **Complete on device** | `2026-08-21-123201`, 1,380/1,380 entries, about 19.7 MB, no capture failures |
| Xcode `.xcappdata` download | **Rejected as authority** | the downloaded package omitted the database, live stores and part of the verified snapshot; an Xcode download is supplemental evidence only until a manifest proves it complete |
| Task 0 handoff | **Open** | current disclosures, lifecycle inventory, evidence schema/validator, collision-safe test evidence and a complete off-device evidence artifact still need closure |
| Tasks 1–20 | **Not started** | Task 1 remains the next functional task after Task 0 closes |

### Post-B5 housekeeping ledger

| Phone/repository note | Status | Required disposition |
|---|---|---|
| `hidden-for-test/athlete.json.written-while-hidden` | **Open; low runtime risk, real lifecycle gap** | Classify it as non-authoritative internal-test evidence, not migration input. Task 0 should bind its metadata/hash and perform scoped receipted removal after last-copy checks; if Bruno retains the bytes, move them to immutable private encrypted evidence with an owner/expiry and remove the live-container copy no later than Task 18. Task 19 proves future remnants cannot escape cleanup. Never use Xcode Replace Container |
| Shared Xcode Run scheme | **Complete** | Working tree, index and HEAD use Debug; RULE 14 is green. Do not carry the old “scheme is Release” remark as open work |
| Debug build installed on the phone | **Open; non-gating housekeeping** | Install and run Debug, then capture Settings → Version showing `Configuration = Debug` before Task 3 establishes the next comparable timing baseline. It does not require rerunning B5 and does not block Task 1 |

## Scope and final outcome

This plan begins **after the accepted B5 implementation slice**. It does not authorize
an AI to reopen or rewrite B5 without a newly demonstrated defect. Task 0 closes
the handoff evidence, lifecycle and documentation gaps listed above; it does not
repeat the 22-row B5 campaign merely to create newer prose.

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
7. The surviving code is handed to the proposed behavior-neutral restructure with
   a new baseline; Bruno accepts its §24/R0 decisions before execution.

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

The controlling runbook is
docs/PLAN-post-B5-database-cutover-execution.md. Read its opening/current-state
warning, full selected task (finding, exit gate and prompt), decision table and
release gates—not only the pasted prompt.

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
8. For Task 1 and later, locate the predecessor's accepted evidence under
   docs/evidence/post-b5/task-NN/ and every required ADR owner decision. If an
   accepted artifact/approval is absent, stale, contradictory or does not identify
   its commit/schema/dataset, stop and report the prerequisite rather than recreate
   or assume it.

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
  Never run the full suite concurrently against the same simulator/DerivedData.
  Until Task 0 lands a repository-enforced lock and unique evidence identity, first
  prove no other suite is running and set a unique task-specific `SUB4_LOG`; preserve
  the command's own exit status rather than inferring it from a shared log.
  Run a Release build/device measurement for launch, background, Health, rendering,
  activation, backup/restore or performance work. After every Release campaign,
  restore the shared Run action to Debug, install/run a Debug build once and capture
  Settings → Version proving `Configuration = Debug`, unless an intentionally
  retained Release installation is named in the acceptance record.
- Update ADR/current-state/manual text whose truth changed; preserve historical ADR
  decisions and add a superseding entry instead of rewriting history.
- Never send Strava-lineage evidence to an AI provider.
- Never disconnect Strava, revoke credentials, purge lineage, delete phone data,
  corrupt the only database, commit, push or change external state unless this exact
  task permits it and Bruno gives the required confirmation.
- Report files changed, automated evidence, device evidence, remaining risks and the
  exact next gate. Do not call the next task started.
- Produce a durable redacted acceptance index at
  docs/evidence/post-b5/task-NN/acceptance.md plus manifest.json. It names executor,
  UTC, task/campaign version, commit/patch/schema, predecessor artifacts/decisions,
  pass/fail rows and hashes/locations of retained evidence. Keep restorable/private
  packages outside the repository in protected storage; never redact or modify the
  only backup in place. A failed or partial task writes a blocker record, not an
  acceptance.
- Validate each manifest against the versioned repository schema/command created by
  Task 0. It carries status, explicit owner approvals/decision references and the
  tested implementation tree digest. Because a file cannot truthfully contain the
  commit hash that first adds itself, use two phases: implementation/tree evidence
  first with `awaitingOwnerAcceptance`, then a follow-up evidence commit or approved
  external signed record binds the final implementation commit and `accepted`
  status. Never invent approval or self-certify the same commit.

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
   the point after which rollback is no longer lossless. Destructive/fault campaigns
   list explicit abort conditions before the first mutation.
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
   precise coordinates and unrelated free-text notes. Preserve complete backup/
   evidence artifacts unchanged in protected storage and share only separately
   generated redacted reports.
9. **Cleanup and rollback** — restore files/settings/build configuration, remove
   disposable fixtures and re-check starting counts/fingerprints.
10. **Uncovered cases** — a partial campaign proves only its rows.
11. **Durable result index** — executor, UTC, commit/patch/schema, campaign version,
    every pass/fail row and hashes of evidence files in the task acceptance manifest.

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
- An app-generated, manifest-verified evidence package or authoritative database
  backup, independently validated after export.

An Xcode `.xcappdata` download is **supplemental and untrusted by default**. B5
proved that Xcode can return a partial package even when the on-phone snapshot is
complete. It may support an investigation only after its contents match an in-app
manifest/digest; a missing database, sidecar, preference or declared payload is a
hard completeness failure. Never use Xcode **Replace Container** as a restore,
cleanup or test mechanism.

## Ordered task map

| # | Task | Starts only after | Principal exit |
|---|---|---|---|
| 0 | Close the completed B5 handoff and freeze trustworthy evidence | accepted patch 433a implementation / recorded campaign | residual gear proof and lifecycle/docs/tooling gaps close; a complete app-generated evidence package verifies off-device |
| 1 | Resolve match-picker behavior and match-decision fidelity | 0 | picker/resolver agree and the decision round-trips |
| 2 | Build a disposable authored repair/removal fixture | 1 | restore, scoped removal and durable attribution are proven, not merely no-ops |
| 3 | Write B6/B6a derivation and persisted-load groundwork | 2 | complete input/invalidation/lineage contract accepted |
| 4 | Implement and flip B6/B6a | 3 | outputs unchanged; launch no longer constructs all traces |
| 5 | Resolve and execute B7 review persistence | 4 | privacy-safe proof of the full graph under the accepted gate |
| 6 | Write B8 operational-state groundwork and field tranche | 5 | cursor/queue/rejection/revision contract accepted |
| 7 | Implement B8 atomic authority | 6 | rows and checkpoint cannot diverge across interruption |
| 8 | Close the complete source-field matrix | 7 | every source field is preserved, normalized, derived or explicitly excluded |
| 9 | Build authoritative backup, readable export, restore and lifecycle receipts | 8 | SQLite can be protected and restored independently |
| 10 | Build the external auditor and exact dataset binding | 9 | one quiescent activation checkpoint identifies exact evidence and DB state |
| 11 | Build B9 fail-closed activation groundwork | 10 | all negative controls and recovery path exist, activation still off |
| 12 | Activate SQLite and execute B10 | 11 + explicit approval | DB-only Release campaign passes; Strava remains connected |
| 13 | Refresh Health coverage and accept raw/canonical contracts | 12 | C0/C0.1/C0.2 accepted |
| 14 | Build durable Health workouts, quantities, routes and events | 13 | C1/C2 batches are exactly-once and reconstructable |
| 15 | Build canonical projection and source reconciliation | 14 | C3/C4 are deterministic and authored links survive |
| 16 | Recover gaps and rebuild dependent features | 15 | C5/C6 feature matrix passes |
| 17 | Run Health/Strava shadow and disconnected rehearsal | 16 | C7 passes; losses, cutover and D0 window are accepted |
| 18 | Activate Health, revoke and purge Strava | 17 + explicit destructive approval | terminal revoke, C8 receipt and immediate Health ingest pass |
| 19 | Retire runtime JSON and remaining Strava code | 18 + objectively elapsed D0 window | D8 inventory/cleanup is clean and upgrade path bounded |
| 20 | Validate and hand off to the proposed behavior-neutral restructure | 19 | new baseline, §24/R0 approval and first R1 prompt accepted |

---

## Task 0 — Close the completed B5 handoff and freeze trustworthy starting evidence

### Why this exists

The B5 implementation slice is accepted at patch 433a: the committed suite/
invariants pass and the Release campaign records 22/22. Row 19's gear half was
weakened by an `athlete.json` rewrite, so Task 0A closes only that residual physical
independence proof. Do not rerun the whole campaign or reopen weather/gear
implementation merely because this runbook previously called B5 active.

The handoff is nevertheless incomplete. Current user-facing lifecycle text and
README/current-state prose predate the weather/gear flip. The retained
`hidden-for-test/athlete.json.written-while-hidden` is ignored at runtime but is
also absent from snapshot, export, deletion and disconnect inventories. The
on-phone snapshot is complete, while the Xcode-downloaded `.xcappdata` is provably
partial. No post-B5 evidence schema/validator exists, and concurrent full-suite
runs can share a simulator and overwrite `/tmp/sub4-test.log`. Finally, the B5 gear
file-removal observation also saw `AthleteStore` rewrite `athlete.json` without
binding that write to a proven cause, so one small network-disabled physical check
should close the hydration/provenance ambiguity.

### Exit gate

Task 0 closes when the accepted B5 evidence is recorded without being
misrepresented or needlessly repeated; current docs/UI disclosures agree with the
actual SQLite-fed families; `hidden-for-test/` has an explicit non-authoritative
lineage/lifecycle classification and its current phone copy has a receipted removal
or protected external-retention disposition; a populated pre-B5 migration
regression exists; the short Strava-disabled gear check passes; evidence manifests
validate; full-suite evidence cannot collide; and a fresh app-generated package
containing the complete protected legacy snapshot plus a transaction-consistent
diagnostic database copy verifies off-device. The package is starting evidence,
not Task 9's authoritative restore backup. The shared scheme is recorded complete;
the phone Debug reinstall may remain a named non-blocker only until immediately
before Task 3.

Execute 0A and 0B as separate AI tasks. Task 0B starts only after an accepted 0A
artifact; Task 1 starts only after the combined Task 0 acceptance manifest.

### AI prompt 0A — Close current truth, lifecycle and evidence tooling

~~~text
Apply the common preamble and shared campaign contract from
docs/PLAN-post-B5-database-cutover-execution.md.

Task 0A: close the accepted B5 implementation handoff at the actual current commit.
Do not reimplement B5, rerun its complete 22-row campaign, overwrite the worktree
or start Task 0B/Task 1.

First bind the identities separately: patch 433a implementation at `debcfd6`; final
device-observation documentation/current verification tree at `60c52dc`; and the
1,876/179 suite result plus 15 invariants against `60c52dc`. Record the 22/22 device
campaign together with its residual row-19 ambiguity, exact Release timings and
on-phone snapshot `2026-08-21-123201`. Independently re-read source and evidence;
if they contradict those facts, stop with a blocker rather than rewriting history.

Close these handoff defects in bounded tranches:

1. Reconcile current-state truth in CLAUDE §5, README, DataLifecycle user-facing
   disclosure, Database diagnostics, this plan and B5 groundwork. Mark the old
   groundwork historical/accepted rather than deleting its chronology. State that
   activities, details, recordings, plan, zones/FTP/resting figures, weather and
   gear now hydrate from SQLite while authority is still transitional.
2. Add `hidden-for-test/` and every known `*.written-while-hidden` output to the
   executable lifecycle/lineage inventory, completeness tests, delete/disconnect
   preview and receipts under an explicit `nonAuthoritativeInternalTestArtifact`
   role. It is not canonical migration input and must be excluded from ordinary
   legacy snapshots, source parity and the personal readable export. Record only
   path/hash/bytes/status in redacted support output. If raw bytes are retained for
   forensics, put them in a separately named immutable private encrypted annex that
   must never be sent to an AI provider; remove the live copy no later than Task 18.
   Recommend scoped app-owned removal in Task 0 after Bruno confirms the preview.
   Refuse unless no input remains hidden, every expected live counterpart exists and
   is readable, the target is an exact allow-listed path (not a wildcard), and a
   verified canonical snapshot/evidence hash or accepted no-retention decision
   exists. Preview exact path/hash/bytes; confirm; remove; verify absence; receipt.
   Never use Xcode Replace Container or an unreceipted raw delete.
3. Add the missing populated upgrade regression: migrate a populated pre-B5
   database, apply both B5 migrations, and prove rows survive with honest defaults
   before reconciliation supplies kind/retirement facts.
4. Harden `scripts/test.sh` so two runs cannot share evidence or mutate the same
   simulator/DerivedData concurrently. Use a repository-scoped exclusive lock,
   unique per-run log/evidence identity, trap-safe cleanup and the actual process
   status. Test contention without launching two full suites.
Create the versioned `docs/evidence/post-b5/` manifest JSON schema, validator command
and fixture tests if they do not exist. Require explicit status/owner approval,
predecessor references, tested implementation tree digest, final commit/external-
signature binding and evidence hashes. Prove invalid/missing/stale/circular manifests
fail before any later task treats them as machine-evaluable.

Manual-campaign decision: mandatory but narrowly scoped; do not repeat the accepted
B5 campaign. Build current tap-by-tap instructions from Settings source. Disable
“Read activities from Strava” (or use an approved reversible network-off state).
Before hiding, require both live `athlete.json` and `weather.json` to exist/read or
record an explicitly accepted absence; record the control's exact moved set. Use the
internal B5 hide control, cold launch, and prove gear/weather still render with
SQLite hydration/UI provenance before any file-side read. Prove every Strava/network
attempt was disabled or refused. Observe the live-file state directly; if a legacy
mirror reappears, classify its exact writer/time/hash and prove it was a post-DB
mirror rather than failing solely because the file exists. Restore every moved input;
account for any newly written mirror without overwriting the original and prove the
starting canonical fingerprint. Then preview and record Bruno's chosen safe
disposition for the older retained copy. If removal is approved, exercise the
last-copy guards and receipt above. If the current phone is intentionally left on
Release, record the Debug reinstall as due before Task 3; otherwise install/run
Debug now and capture Settings → Version. Derive every label from the current app.

Stop with either an accepted Task 0A record or an exact blocker list. Do not start
Task 0B/Task 1 and do not commit/push without approval.
~~~

### AI prompt 0B — Build and verify the complete starting-evidence package

~~~text
Apply the common preamble and shared campaign contract from
docs/PLAN-post-B5-database-cutover-execution.md.

Task 0B: after Task 0A is accepted, build the app-generated evidence path that
replaces Xcode `.xcappdata` as the authoritative post-B5 analysis input. Do not
implement general database restore/retention, run a legacy import or start Task 1.

Build one private exportable **starting-evidence package** containing:
- a fresh preference-inclusive protected legacy snapshot and its exact manifest;
- a non-authoritative test-artifact inventory with path/hash/bytes/disposition, but
  no raw `hidden-for-test/` bytes in canonical migration inputs or ordinary export;
- a transaction-consistent diagnostic SQLite copy created through the supported
  SQLite/GRDB backup API, never by copying a live database without its WAL state;
- schema/migration/integrity/foreign-key results, app/commit/patch, snapshot ID,
  proven available revisions, capture UTC, pre/post source+database fingerprints/
  counts and per-file hashes;
- a private complete manifest and a separately generated redacted support report.

Use a bounded evidence-export barrier: obtain exclusive ownership, drain/pause/refuse
every currently known source refresh, background job, queue claim and authored
writer; capture pre-state hashes/fingerprints/counts; create the legacy snapshot and
database copy; then recalculate the same values before releasing the barrier. Bind
both components to one package capture ID. Use a current revision as supporting
evidence only after tracing and proving that every relevant writer advances it;
do not invent B8's future global revision authority in Task 0. Any pre/post change,
unowned writer path, background timeout, partial copy, low space or cancellation
must fail the package rather than publish mismatched
evidence. Never construct normal stores as a side effect of export.

If Bruno explicitly retains raw internal-test bytes for forensics, place them in a
separately named immutable private encrypted annex with owner/expiry; never feed it
to migration/import parity and never send it to an AI provider. Only the redacted
support report is casually shareable.

Exclude Keychain tokens/credentials and unrelated system data, but do not silently
omit app-owned domain/preference data. Apply the accepted on-device file-protection
class. The package may contain notes, routes and other private data, so its share UI
must require an explicit protection warning and encrypted off-device destination.
The diagnostic database copy is read-only evidence, not a supported restore artifact;
factor reusable capture/manifest code for Task 9 without claiming Task 9's backup,
retention, restore or recovery guarantees.

Build a pinned, read-only off-device validator for this package now. It validates
every path/hash, declared absence, plist/JSON parse, database integrity/foreign keys,
schema/migrations and the cross-artifact capture/fingerprint boundary. It never edits
or recovers the only package in place. Add fixtures for exact success, omitted DB,
missing preference, partial snapshot, changed same-count file, tampered manifest,
hot-WAL input, duplicate/unsafe path, mismatched pre/post state, an unowned-writer
negative control, low-space/interrupt output and deterministic repeat. Unit tests
use synthetic redacted fixtures. During external acceptance, feed the protected
known partial B5 `.xcappdata` capture to the completeness-negative test while
keeping it outside the repository; it must fail and may never be installed with
Xcode Replace Container.

Manual-campaign decision: mandatory because this touches protected files, a live
database and off-device export. Build exact current Settings navigation and any
missing progress/identity diagnostics first. Start from the accepted Task 0A state;
create/share the package through the app; independently validate it in encrypted
off-device storage; compare the on-phone and off-device IDs, counts and hashes; lock
the phone during capture to test the accepted file-protection behavior; exercise a
safe cancellation/low-space refusal; and prove the app, writers and queue resume
after both success and failure. Do not expose private payloads in screenshots or
repository evidence.

Record one accepted Task 0 handoff manifest binding both 0A and 0B evidence. Stop
before Task 1 and do not commit/push without approval.
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
plus an isolated simulator or app-supported restore into a disposable database;
if physical-device proof needs an internal debug action, gate it by internal build,
explicit fixture identity and confirmation. Xcode Replace Container is forbidden.

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
fingerprint/counts return. Start from Task 0's manifest-verified evidence package;
abort if the app cannot prove it is operating on the disposable fixture.
~~~

---

## Task 3 — Write B6/B6a derivation and persisted-load groundwork

### Finding

The accepted post-B5 Release baseline is 0.608/0.613 s for the longest main-thread
stall, 0.344/0.349 s for `DetailStore`, 0.055/0.057 s for bootstrap and
0.035/0.037 s to the first free turn. The launch read is
load-bearing because `LoadEngine` prefers trace evidence. Making it asynchronous
would hide the freeze but still retain all traces and still delay correct values.

B6 and B6a therefore share one job: define one repository-backed derivation input
snapshot and persist the output of the existing load algorithm/formula owner.
Hidden eligibility dependencies must be removed before it can be called pure. Persisting that
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

Before collecting a new Debug timing baseline, install/run Debug on the phone and
capture Settings → Version proving `Configuration = Debug`. Keep Debug and Release
series separate. Use the accepted post-B5 Release figures above as the performance
baseline; do not substitute the older B4 range.

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

Design one immutable Sendable DerivationInputs snapshot. Existing formula owners
remain the only algorithm owners; after hidden mutable eligibility inputs are made
explicit, keep calculations pure and never query SQLite from a formula. Design a persisted
WorkoutLoad output keyed by canonical activity plus engine/input/config/source
revisions. Specify late trace, Health HR, RPE, correction, match, commute, plan,
profile/FTP and merge invalidation. Traces become lazy detail inputs after the
cache is trustworthy.

Specify the complete stored contract rather than a convenient subset: canonical
activity FK with alias translation; day/name/sport/discipline; TRIMP; load source;
flags; HR coverage; sRPE; HR max/rest used; engine version; scored seconds;
source-neutral source-recorded moving seconds; plan eligibility; and the complete
one-BPM `hrSeconds` histogram. Define staging and active generations, atomic
publication from one consistent database snapshot/revision and explicit
ready/rebuilding/stale/failed states. Missing, stale, partial or corrupt cache must
never render as a valid zero, and no screen may mix generations.

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

Stop before tranche 6. Continue only after Bruno accepts exact every-field shadow
agreement, all invalidation negative controls, complete active-generation
publication and the Release pre-flip evidence. Add an architecture invariant that
opening the launch load path cannot construct or bulk-read `DetailStore` recordings.

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
rotation/interaction and no value drift. Require the longest Release stall below
the documented 1.0-second ceiling, no first-free-turn regression and the pre-agreed
improvement target against the accepted post-B5 baseline: 0.608/0.613 s longest
stall, 0.344/0.349 s DetailStore, 0.055/0.057 s bootstrap and 0.035/0.037 s first
free turn. Restore every authored test edit, restore the shared scheme to Debug,
install/run Debug once and capture Settings → Version.
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

First check the actual current date, `ReviewDue` and on-device review history. The
first real review was scheduled for 24 August 2026; use the circular-gate workaround
only if a real policy-permitted review still does not exist. Do not assume either
state from this 21 August plan.

Read ADR-0002, review-data-pool.md, ReviewRunner, ReviewPayload, ReviewDue,
ProposalStore, ReviewRepository/read-back, rehearsal code and the current device
state. Present the three gate options stated in this plan, their schedule/product/
evidence consequences and a recommendation. Stop for Bruno's decision.

Under the recommended fixture-plus-legitimate-empty option:
- use a local in-memory/disposable full graph with multiple evidence lineage rows,
  ordered proposals/changes/watches and duplicate timestamps/record keys;
- ensure it cannot affect ReviewDue or production history and makes no network call;
- implement DB-first atomic full-graph create/delete and database hydration;
- fix the current `ProposalStore.add` contract: a DB transaction failure cannot
  publish memory or report success; a legacy JSON mirror failure after DB commit
  must publish the committed result and record a diagnostic rather than roll back
  SQLite or tell the athlete the whole save failed; never ignore a persistence Bool;
- reconstruct the rollback mirror/ProposalStore.Record exactly and safely restore;
- represent available, policy-purged and unreadable evidence distinctly rather
  than reconstructing purged evidence as an invented empty string;
- preserve record identity and ordering;
- test partial failure, duplicate identity/time, invalid references, relaunch,
  deletion, source-lineage purge and unrelated authored families;
- fail closed on unknown review-evidence lineage during purge; never default an
  unknown source to removable or safe-to-keep;
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
migration. Compatibility import must take `label` verbatim from the current
UserDefaults receipt; it cannot reconstruct moving-time/max-speed prose from the
structured SQLite columns. An unreadable receipt blob or a receipt with required
verbatim data missing blocks the flip and emits a redacted diagnostic.

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
kill point; foreground/relaunch; compare the app lines with an independently
validated fresh app-generated evidence package/diagnostic database copy. Exercise duplicate delivery, late detail, no-stream
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

Any mapping/schema change here must raise the accepted B8 content revision, rebuild
and independently recompare affected B6 cache generations, and rerun every affected
earlier slice/campaign. Reopen that earlier gate if values or availability change;
Task 8 cannot retroactively invalidate an already-accepted B6/B8 proof.

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
record the complete operation, and its current operation vocabulary does not cover
backup/restore. Database close/reopen coordination and an external crash-recovery
journal are absent.

### Exit gate

A transaction-consistent protected SQLite backup can be retained off-device and
atomically restored in pre-activation state after validation, with an injected
authority interface ready for Task 11; a versioned readable export accounts for all
categories and preserves declared binary preferences losslessly without secrets;
both have durable receipts; tamper/wrong-version/failure paths cannot damage the
live database.

### AI prompt 9

~~~text
Apply the common preamble and shared campaign contract.

Task 9: implement three explicitly named artifacts and their lifecycle receipts.
Do not call a legacy snapshot a database backup and do not claim the readable
export is restorable unless a separately versioned import contract is built.

Before code, accept Task 9's backup-snapshot identity scope/canonicalization over
authoritative included state. Task 10 will compose separate migration-semantic and
activation identities; it must reuse, not redefine, this backup identity.

Build authoritative DB backup with SQLite/GRDB's transaction-consistent backup
mechanism. Never copy a live sqlite file while ignoring WAL/journal state. The
manifest includes artifact/schema version, app patch/commit, migration/evidence
metadata already available, created UTC, the accepted stable non-secret account
scope, a backup-snapshot identity over every authoritative included value and
per-file hashes. Do not depend on Task 10's later migration-semantic identity.
Define exactly which B8 one-shot upgrade preferences are deliberately excluded/
recomputed or include them in a filtered lossless companion plist; a SQLite-only
artifact cannot claim a full operational round trip otherwise. Apply the accepted
iOS file-protection class at creation and verify locked/unlocked behavior. State
separately that protection does not follow an Xcode/off-device copy: require an
encrypted archive/trusted encrypted storage or a clear user-responsibility warning.

Define local retention/deduplication before the first backup: always protect the
pinned pre-activation and only known-good rollback copy; never let automatic cleanup
delete the sole verified backup; leave corrupt/unknown artifacts untouched and
surface them for manual review.

Build staged restore behind an exclusive maintenance gate that drains or refuses UI
saves, source batches, Health/background callbacks and queue work. Validate manifest/
hash/account and compatibility (same schema, supported older schema followed by
migration, newer/unsupported refusal); copy to a bounded temporary area; run
integrity/foreign-key checks; close the queue; retain a rollback copy; and use a
small protected external restore journal/state machine around staging, swap, reopen,
authority reconciliation and receipt. Launch must deterministically finish or roll
back after death at every phase. Put authority reconciliation behind an injected,
tested interface. Task 9 supplies the pre-activation implementation only; Task 11
must supply/retest the activated ledger/mirror implementation after that protocol is
decided. Do not guess it here and do not construct normal stores during restore.

Build two deliberately different outputs: (1) the athlete's versioned personal
export, which accounts for every included category and may contain their private
notes/routes/Health facts with clear protection guidance; and (2) a separately
redacted support/audit report. Tokens, Keychain secrets and unrelated system data
are excluded from both. Preserve included Data preferences losslessly with typed/
base64 representation. Correct stale AuthoredExport counts/coverage and make
preference/account portability a binary decision, not “where appropriate.” The
personal export is not restorable unless a separately tested importer is approved.

Add an additive populated migration for backup/restore lifecycle-operation
vocabulary and wire durable export/backup/restore receipts. Because the live DB may
be the object being replaced, the external restore journal—not an in-DB receipt—is
the interruption authority. Define receipt results for success, rollback and launch
recovery.

Keep Strava disconnect disabled. Replace any path that could remove an open
authoritative database with a fail-closed preview/guard; row-level purge arrives
only after Health reconciliation.

Automated tests: concurrent-write/WAL backup, full authored+operational round-trip,
arriving writer during maintenance, tampered/corrupt/missing manifest, same/older/
newer schema, wrong account, low disk, locked protected files, cancellation,
reopen failure, retention safety, no credential leakage and durable receipts. Kill
after maintenance entry, queue close, old-DB staging, new-DB placement, reopen,
authority update, receipt write and cleanup; every relaunch converges without data
loss or split authority.

Manual-campaign decision: mandatory. Add progress, manifest, integrity, rollback
and reopen diagnostics first. Build exact current Settings data/Database backup,
readable export and restore navigation. Run restore only on a cloned/disposable
database created through the app-supported staging/restore path or an isolated
simulator; never use Xcode Replace Container. Compare pre/post fingerprints and authored/operational state; test a
tampered artifact refusal, file protection while locked/unlocked, low-space/
cancellation and every restore kill point; download and retain the verified backup,
personal export, redacted support report and receipts in their correct protection
domains. Prove rollback, retention and cleanup. Never use the only phone database
as the first restore test.
~~~

---

## Task 10 — Build the external evidence-artifact auditor and exact dataset binding

### Finding

`tools/` has no cutover auditor. `SemanticVerifier.fingerprintCheck` covers a
small activity fingerprint, not the dataset. `runsSinceVerified == 0` proves only
that the ledger did not move. Import and verify read live stores independently;
the snapshot name on the ledger is not proof of input bytes or current DB state.
B5 additionally proved that an Xcode `.xcappdata` download may silently omit the
database, live stores and part of a verified snapshot, so it cannot be the auditor's
authoritative input format.

### Exit gate

A committed read-only tool reproduces JSON/preferences/snapshot/SQLite comparison;
separate versioned identities bind validated source artifacts, migrated semantic
facts, the backup snapshot and immutable activation evidence without hashing their
own ledger/receipt fields; subsequent legitimate database-first mutations advance
revisions without making the activated app falsely corrupt; any unaccounted relevant
change blocks verification or activation.
A verification-only activation checkpoint exists for current database-first state;
it never invokes the legacy importer and is the exact newest evidence consumed by
activation.

### AI prompt 10

~~~text
Apply the common preamble and shared campaign contract.

Task 10: create a reproducible external audit gate and bind migration verification
to exact immutable evidence. Stop before B9 activation.

Build a read-only tool under tools/ whose primary source input is Task 0's
app-generated, manifest-verified evidence package. It discovers the declared live
legacy snapshot/preferences/internal-test artifacts and transaction-consistent
diagnostic SQLite copy; never mutates the package; validates JSON/plist parsing,
every manifest/hash, SQLite integrity/foreign keys, schema/migrations and counts;
and compares field-by-field through Task 8's matrix/normalizations. If a supported
package can contain a WAL/hot journal, copy the complete declared set to a temporary
workspace before recovery/open and make missing sidecars a completeness failure.

An `.xcappdata` mode is optional and explicitly supplemental. Before reading any
values, require it to match the selected in-app manifest/package identity. Missing
database, sidecar, preference, manifest or declared payload exits non-zero and
forbids a parity/activation claim. Include the known partial B5 download as a
negative fixture. Never use Xcode Replace Container.

Add a separate Task-9 backup-artifact input mode. Without restoring, validate its
manifest, observable encryption/protection metadata, hashes, SQLite integrity,
foreign keys, schema/account scope, included companion preferences and backup-
snapshot identity. The activation checkpoint binds this exact audit/report digest.

Require explicit CLI selection of evidence-package ID, source snapshot ID, manifest
digest and migration run;
multiple plausible inputs are an ambiguity failure. Define the raw artifact digest
as a canonical sequence of sorted relative paths plus exact declared file/preference
bytes, excluding unrelated package metadata. Define how the directory-package
hash is produced. Pin tool/runtime dependencies, prohibit network access and prove
temporary cleanup plus byte-unchanged input.

Emit versioned JSON plus concise Markdown. Use stable natural-key/canonical ordering
so generated UUIDs do not create false differences. Report missing/null/empty/zero/
unreadable separately. Sensitive values participate in equality without being
emitted. Record tool, report-schema, canonicalization and matrix versions plus the
report digest; exit non-zero on integrity failure or unexplained difference. Redact
credentials, free text and private coordinates.
Synthetic tests include exact match, changed same-count field, missing input,
corrupt DB, WAL/hot journal, fractional time, array order, binary preference,
unknown vocabulary, deterministic repeat and cross-language golden fixtures shared
with Swift canonicalization. Keep source-equivalence checks separate from DB-only
operational invariants.

Design/implement and document distinct identities:
- source artifact identity: exact declared immutable snapshot bytes;
- migration semantic identity: only source-mapped facts under Task 8's rules;
- Task 9 backup snapshot identity: all authoritative state captured at backup time;
- activation evidence identity: immutable pre-activation proof plus source/data
  revision and active B6 cache generation;
- post-activation authority validity: schema/integrity/ledger/mirror/revision rules,
  not permanent equality to a historical pre-activation fingerprint.

Create a versioned inclusion/exclusion matrix for every table/field: normalize or
exclude generated UUIDs, verification fields that store their own digest, ledger/
lifecycle/backup receipts, queue leases/timestamps and staging cache generations as
appropriate. Prove writing verification does not change its recomputed semantic
identity while a relevant content mutation does. A legitimate post-activation save
must advance the accepted revision/backup identity and must not trigger a false
fingerprint-invalid recovery screen.

Additive ledger evidence records validated manifest digest, raw/logical source,
migration semantic/activation evidence identities, exact audit-report digest,
tool/matrix/canonicalization/evidence versions, verified UTC, schema and patch.
Activation evidence also names the required Task-9 rollback artifact ID, manifest
digest, backup-snapshot identity, successful external/in-DB receipt state and the
candidate content revision/active B6 generation; a different or stale valid backup
cannot satisfy the gate.
The last legacy migration import remains bound to the immutable snapshot it used.
After database-first mutations begin, do not run a new legacy import: quiesce writers
and audit/fingerprint current SQLite plus its revisions. Another import is permitted
only if the gate proves zero DB-first changes and exact mirrors. Verification always
compares independent immutable evidence with the mapped DB facts.

Add a distinct `authority_verification` checkpoint (or an equally explicit additive
ledger/API state that is not a pretend migration run). It links the last valid
migration/source evidence to the current quiesced content/data revisions, DB
semantic identity, exact audit-report digest, matrix/tool versions, active B6 cache
generation and bound rollback backup. It performs no import. It becomes the newest
activation evidence object and any later identity-relevant write invalidates it.
Test last import -> database-first mutation -> quiescent verification-only checkpoint
-> activation, plus a mutation after checkpoint refusing activation.

Negative controls: preference-only change changes source identity; post-import
source mutation refuses verify; any post-verify identity-relevant or unapproved DB
mutation refuses activate; one
same-count field change fails; tampered/incomplete snapshot fails; a newer running/
pending/failed/interrupted run blocks; UUID-only changes do not affect logical
identity; recording verification leaves the semantic identity stable; and a valid
database-first save after activation remains valid authority while changing the
backup snapshot identity. A planned backup/verification/activation receipt that the
matrix explicitly excludes leaves activation evidence stable; changing a content
row, revision, active cache generation or bound backup identity does not.

Manual-campaign decision: mandatory. Build exact current Settings → Database
snapshot/import/verify/ledger and evidence-package export/share steps. Capture
package/snapshot/manifest digests, run ID, evidence version and source/DB
fingerprints from redacted app diagnostics; run the tool; retain audit JSON/Markdown,
report digest and the precisely defined package hash in encrypted storage. Quiesce
writers as required by the app's export protocol and explicitly select the package,
snapshot and run. Retain the historical pre-import package if a migration import is
still required, then a second post-verification quiescent package so the evidence is
self-contained. If B8 has already accepted database-first changes, audit current
revisions and do not re-import a stale mirror. Optionally feed the known partial
`.xcappdata` package to the completeness-negative control; it must be refused, not
repaired or installed on the phone.
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
activated-backup authority reconciliation and disposable recovery campaign pass;
activation remains off pending explicit approval.

### AI prompt 11

~~~text
Apply the common preamble and shared campaign contract.

Task 11: build B9 activation eligibility, fail-closed recovery and negative
controls. Do not activate the production database.

Create a pure eligibility report covering: all B1-B8 families database-fed;
current B6 cache generation; B7 accepted proof rule; latest verification-only
activation checkpoint bound to
current activation-evidence identity/revisions/schema; zero unexplained independent
audit differences; database-first authored/operational writes; authoritative DB
backup/restore; separate personal export; disposable authored repair/removal proof; and Strava
disconnect explicitly blocked.

Stop for Bruno's post-activation downgrade/rollback choice, fresh-install behavior
and activation-evidence contract if not already decided. Keep the artifacts
distinct: same-version disaster recovery
uses Task 9's authoritative DB backup; a readable personal export is not rollback;
downgrade to a JSON-era app requires temporarily lossless mirrors, a tested downgrade
importer, a read-only downgrade or an explicitly unsupported policy.

Replace launch's fail-open path with explicit opening/ready/blocked/recovery states.
Refactor the current compile-time `migrationFailureBlocksTheApp` switch into an
authority-aware, injectable policy. During Task 11 the normal unactivated production
build retains the accepted legacy fallback; disposable/internal tests inject the
post-activation `true` policy. Task 12's checked activation state—not Task 11—makes
fail-closed behavior mandatory in production.
Missing/corrupt/incompatible DB, pre-flip activation-evidence mismatch or post-flip
authority-validity failure, migration/integrity/ledger/
bootstrap failure must show recovery only, with retry/reopen, redacted diagnostics,
authoritative DB-backup restore and export guidance. Normal stores, auth and network
work must not be constructed. Legitimate empty remains a valid ready state.

Design the ledger+external mirror protocol so every kill point can only over-block,
never authorize stale legacy content. Test mirror true/no activated row, activated
row/no mirror, ledger/mirror write/read failure, stale migration evidence/checkpoint, newer mutation,
wrong cache/fingerprint, missing runtime JSON and retry after failure. Remove
suppressed critical errors once authority depends on them.

Implement the activated `AuthorityReconciler` for Task 9's restore state machine and
rerun every restore kill phase against unactivated, verified/checkpointed and
activated backups. A restored backup cannot silently inherit or lose authority from
an unrelated external mirror.

Make DataLifecycle activation-aware and prevent any disconnect/delete path from
removing the authoritative database while open. Keep actual Strava disconnect
refused with a user-facing reason until Task 18.

Manual-campaign decision: mandatory now for every non-activation recovery behavior.
Build and execute a safe Release-device campaign against an isolated database
created/restored through the app-supported Task 9 path, covering
recovery UI, retry, diagnostics, tampered-backup refusal, successful restore and
every Task-9 restore-journal kill phase, missing/corrupt DB, runtime JSON absent,
arriving writes refused and authored save/relaunch. Derive exact labels from the new
UI and compare independent identities/audit expectations. Pin that no normal store
or network work initializes under the injected post-activation policy. Also prove
the unactivated production policy retains only the explicitly accepted legacy
behavior. Do not activate or corrupt production; Task 12 owns the production flip.
~~~

---

## Task 12 — Activate SQLite and execute the B10 Release-device campaign

### Exit gate

Only the newest verification-only checkpoint over the exact current authority state
activates; mirror and ledger resolve conservatively across kill points; every
production read/operational state uses SQLite; runtime legacy files can be moved
aside; every principal feature,
authored mutation, backup/export/restore and recovery state passes on a Release
physical device; Strava remains connected and source ingest continues.

### AI prompt 12

~~~text
Apply the common preamble and shared campaign contract.

Task 12: perform B9/B10 only after Task 11's eligibility report is entirely green.
If any prerequisite is false, stop without changing activation state.

Before activation require Bruno's explicit approval. Record patch/commit/build,
device/iOS/timezone/schema, queue/revision/cache state and accepted rollback. Create
and independently verify four purpose-named artifacts at their proper times:
(1) **pre-import rollback**, only if a legacy import is still legitimate;
(2) **pre-activation candidate rollback**, over the quiesced exact content revision/
cache generation that will be checked and activated;
(3) **pre-fault-injection safety**, after activation and before disposable campaign
faults; and (4) **final post-campaign authority**, after every accepted campaign
mutation. The readable personal export is separate and is not a rollback artifact.

Do not perform a “final” legacy import after database-first mutations. Preserve the
identity of the last legitimate migration snapshot. Quiesce writers, run Task 10's
read-only audit over current SQLite/revisions/active cache, create and independently
audit the pre-activation candidate backup, then write only its planned identity-
excluded receipt. Recompute the migration-semantic identity to prove the receipt did
not change it. A new import is allowed only if the eligibility report proves zero
database-first changes and exact
mirrors. Record snapshot/report digests, run/evidence/tool versions and all accepted
identities. Create the verification-only activation checkpoint bound to that exact
backup artifact ID, manifest digest, backup identity, successful receipt, content/
data revision and active cache generation. The checked activation transaction
revalidates all of them. After the checkpoint, permit only explicitly matrix-excluded
checkpoint/activation metadata writes; prevent or detect every identity-relevant or
unapproved write.

Activate in the checked transaction, then record/read back the conservative mirror.
Switch the single persistence authority; never infer it from repository emptiness.
The accepted authority-aware launch policy becomes fail-closed at this activation;
prove a pre-activation failure followed only the accepted legacy path and every
post-activation failure constructs recovery only, with no normal stores/network.
Relaunch twice and re-evaluate post-activation authority validity. Do not disconnect
Strava.

Manual-campaign decision: the complete B10 campaign is mandatory. Use this table:
screen/flow | independent baseline | D7 value/state | result | evidence file.
Cover Today, Week, Plan, Progress, every reachable activity detail/route/chart/split,
weather/gear, notes/RPE, commute/matching, Review legitimate-empty/policy state,
Settings/Database/Health/data controls, load, background/queue, backup/export/
restore and lifecycle preview. Exercise success, legitimate empty, stale, partial,
unavailable, failed and recovery states.

After the named pre-fault-injection safety backup, move every runtime LegacyStore
input aside (do not delete) in an isolated/restorable app-supported test state. Also quarantine every
preference-backed legacy
runtime authority (match decisions, cursor/sync/rejections, detail terminal sets and
other Task-8 inventory), while retaining only explicitly approved one-shot upgrade
markers. Prove every served-from/provenance line is SQLite, the bundled plan is not
a fallback, fresh-install behavior matches Task 11's decision and a deliberately
failed JSON mirror cannot undo or report failure for a committed DB save. Repeat
cold launch, relaunch, authored saves and principal screens. Test missing/corrupt/
authority-validity-invalid DB only in that isolated test state: no normal store or
network work may initialize; recovery UI must be the only app content, then restore.
Export a fresh post-activation app-generated evidence package, run Task 10's auditor,
retain the final post-campaign authority backup and all redacted evidence, and
restore temporary files/build settings. An optional `.xcappdata` download may be
kept only as supplemental evidence and must independently pass completeness before
use; never install it with Xcode Replace Container.

Do not call D7 complete unless all rows pass. D7 completion still does not permit
Strava retirement; it means database-authoritative persistence while Strava remains
the current source adapter.
~~~

---

## Task 13 — Refresh Health coverage and accept raw/canonical contracts

### Finding

The last documented Health census is a useful historical baseline, not a current
cutover measurement. The present Health path reads an in-memory diagnostic cache;
its query anchors are not durable, its authorization wording can overstate what the app can
know, and it has no raw workout/quantity/route/event persistence. The existing
`recording_sample` distance alignment cannot faithfully store Health quantities or
routes whose samples have independent timestamps.

### Exit gate

A current physical-device census and authorization truth table exist; raw evidence,
per-query checkpoint, deletion, route/quantity/event, projection provenance and reconciliation
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

Carry the old anomalies as hypotheses to remeasure, not current facts: three known
app-only dates, 53 Strava-written Health summaries and eight hidden strength gaps.
Explicitly identify Hevy history and prove whether a new Hevy workout actually
writes a usable Health workout; decide historical Hevy disposition rather than
assuming future coverage repairs the past.

Before schema or queries, accept the least-privilege Health contract: exact read-
type inventory, stable sample identity/deletion behavior, required entitlements and
background-delivery capability, accurate usage-purpose text, and lifecycle/privacy/
personal-export/delete disclosures for newly persisted evidence. This supersedes
the current memory-only/no-local-copy claim before persistence begins.

Design additive raw-source storage for:
- opaque anchored-query checkpoints unique by account/source/queryKind, each with
  reset/expiry metadata and advanced only with its own result set;
- raw workout identity, source/bundle/device/version, modification/deletion facts;
- timestamped quantity samples with unit and source metadata;
- routes and independently timestamped route points;
- workout events/pauses and available metadata;
- projection provenance, quality/completeness and projector version;
- durable reconciliation candidates/decisions/audit without prematurely merging.

Do not force independently timed Health evidence into distance-aligned
recording_sample. Decide whether supported original payloads are retained, and set
retention/export/revocation rules. Write each query-kind transaction boundary: its
raw additions/deletions, affected projection/work state, revision and that query's
new checkpoint commit together; on failure its previous checkpoint remains
authoritative. Projection may converge over separately committed workout/quantity/
route/event evidence and must expose pending/partial state rather than requiring a
fictional universal anchor.

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
catch-up and anchored additions/deletions converge through query-scoped transactions; raw
workouts, quantities, routes and events can reconstruct supported source evidence;
pending/delayed evidence is explicit; the physical-device interruption campaign
passes. Strava is still connected and remains production priority.

### AI prompt 14

~~~text
Apply the common preamble and shared campaign contract.

Task 14: implement the accepted C1/C2 raw Health ingest contract. Do not reconcile
or promote Health above Strava yet.

Deliver two bounded accepted tranches; do not start the second until the first has
its acceptance artifact: 14A workout observer/query/checkpoint/raw-workout ingest,
then 14B quantities/routes/events and partial-evidence convergence.

Build a Health adapter, repository and coordinator behind source-neutral protocols.
Register observers early enough for background delivery, enable the approved
delivery types, and route observer wakes plus foreground catch-up through the same
anchored batch engine. Complete HealthKit callbacks promptly while durable work is
queued. Persist each opaque checkpoint only in the same commit as additions,
deletions, raw evidence, projection/work state and revision for that account/source/
queryKind. Never reuse one anchor across query kinds.

Fetch supported quantities, route objects/points and workout events without
assuming identical sample clocks. Model delayed/absent routes and partial quantity
availability as state, not empty success. Keep source metadata and measured units;
do not invent unavailable pauses, coordinates, distance, HR or power. Handle
updates, duplicate delivery, deleted objects, anchor invalidation/reset and
permission changes deterministically.

Detect condensed Health quantity-series samples and expand them through the
supported quantity-series query before persistence/projection. Preserve stable
sample/series provenance and partial/failure state. Add compact-series HR/power/
cadence fixtures so an apparently successful top-level query cannot silently omit
the underlying points.

Add populated migration, repository, concurrency and coordinator tests. Cover
duplicate batches, crash before/after commit, queue lease expiry, repeated observer
wakes, foreground/background overlap, deletion before projection, route arriving
later, corrupt/expired anchor, authorization changes and samples from several
devices/apps. Prove an unchanged replay performs no logical mutation.

Extend Task 9's backup, restore, personal export, support report, lifecycle inventory
and deletion preview in the same schema tranches. Each new Health table/companion
preference must be included or explicitly classified; run a populated backup/restore
round-trip before accepting C2.

Manual-campaign decision: mandatory on a Release physical device. Build the full
C1/C2 campaign before execution, using exact current Settings -> Apple Health and
Settings -> Database labels. Add redacted checkpoint, pending-work, raw-count and
last-batch diagnostics first. Exercise a run, ride, paused workout, swim or other
available structured sport, strength/non-distance workout and a third-party-written
workout; include delayed route, edit and delete where the source app permits it.
Include a real condensed-series device case when the available writer produces one,
or retain a fixture-only limitation explicitly.
Force-quit and relaunch between delivery phases, wait for background observation,
then export a fresh manifest-verified evidence package and independently query/audit
its transaction-consistent SQLite copy. Record unsupported cases rather than
simulating them. Strava network/source priority must remain unchanged throughout.
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

Deliver two bounded accepted tranches: 15A projection/local detail derivation and
15B reconciliation/review. Do not start reconciliation until projection fixtures,
invalidation and backup/export coverage pass.

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

Implement the accepted Strava-independent detail engines rather than only naming
fields: route-point accuracy rejection, smoothing, cumulative distance,
elevation/grade and a versioned display cache; timestamp-derived kilometre splits;
explicit Health lap/event preservation plus a documented fallback lap detector;
pool-swim reconstruction where source evidence supports it; and versioned local
best-effort sliding windows. Define invalidation for raw/query updates, corrections,
canonical merge/unmerge, algorithm/configuration and source-priority changes. Never
claim parity where Health lacks the evidence required by a Strava-only metric.

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

Extend Task 9 backup/restore/export/lifecycle coverage for projection, route/display
cache, reconciliation decisions/audit and all new revisions; prove a populated
round-trip at the end of each tranche.

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

Deliver three bounded accepted tranches: 16A file imports/gap recovery; 16B athlete,
gear and authored overlays; 16C load/weather/review and the complete product matrix.
Do not let one tranche's green tests imply the later product dependencies are done.

Create a durable gap ledger from the current source/Health/database census. For
each gap choose: recover with supported FIT/TCX/GPX import, retain a permitted
canonical summary, mark unavailable/partial, or explicitly accept loss. Implement
only approved file formats. Preview before mutation; hash the original import;
parse atomically and idempotently; preserve source/provenance and import receipt;
never convert an absent metric into a measured one. Decide original-file retention,
route privacy and re-import/version behavior.

Harden imports as hostile input: copy into a bounded private workspace; impose file-
size, record/sample/route-point and time limits; use safe non-expanding XML parsing
for TCX/GPX; support cancellation and deterministic temporary cleanup; test malformed,
truncated, duplicate and resource-exhaustion fixtures. A preview/parser failure must
leave no canonical, queue or temporary durable state.

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

Also fail invariants when feature/domain code reads live HealthKit or `HealthStore`
instead of canonical repositories. Limit direct Health access to the source adapter
and explicitly diagnostic Settings UI. Remove/replace current ad hoc live-cache
consumers in load, PaceCard, Today and swim/summary paths so the product cannot pass
cutover while still depending on an in-memory Health cache.

Before C6 acceptance, update and run Task 9 backup/restore, personal export, support
report, lifecycle and deletion coverage over every raw Health, per-query checkpoint,
import/original-file receipt, projection, reconciliation, provenance and derived
table. Create a fresh post-C6 known-good backup and prove its populated restore.

Produce an explicit owner-facing loss register for Strava-only segments,
achievements/leaderboard/social semantics, titles/device/gear facts and every
unrecoverable history gap or degraded feature. Task 17 may observe with those known;
Task 18 cannot begin until Bruno accepts each retained loss/limitation.

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
Bruno has accepted the measured loss register, destructive scheduling boundary and
the D8/D0 compatibility contract that will start only after successful Task 18.

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
deny and capture at host/endpoint level every Strava API, token-refresh and OAuth
request through an approved reversible mechanism while leaving unrelated integrations
available. Do not rely only on the ordinary activity-source refresh gate.
Cold-launch and relaunch. Create a new real workout and prove observer/background or
foreground catch-up, canonical projection, reconciliation, Today/Week/Progress,
supported detail, load and export while Strava is unreachable. Re-enable Strava and
prove convergence without duplicates. Exercise the accepted database rollback path.

Before closing C7, stop for Bruno's acceptance of every Task-16 loss/degradation and
the destructive scheduling boundary: production cutover date, race/training-calendar
safety, operator and abort conditions. Also accept D8/D0 now: oldest supported app/
schema, active-binary treatment of dormant Strava code, compatibility duration in
both time and release terms, post-revocation rollback promise, backup requirements,
pre-C8 restricted-artifact disposition, owner and sunset condition. The window starts in Task 18's successful terminal
receipt; Task 19 may not define it retroactively.

Manual-campaign decision: this task is itself a mandatory Release-device campaign.
Build the full document before the observation window using exact current taps and
redacted Settings -> Apple Health/Database diagnostics. Each row must name its
direct Health/source/raw-table expectation, app observation, tolerance and evidence.
Include network-negative proof, force quit/background timing, an exported final
app-generated evidence package, cleanup, restored network state and
credential-presence check. A missing representative case remains explicitly open;
it is not silently waived.
~~~

---

## Task 18 — Activate Health, revoke Strava and purge restricted lineage

### Destructive boundary

This is the first task that may disconnect Strava. It requires a separate explicit
approval after Task 17, a fresh independently verified post-C6 database backup plus
separate personal export, accepted D0/loss decisions and a completed preview. The
current disconnect implementation must not be reused as-is.

### Exit gate

The resumable C8 state machine has a durable receipt; Strava work and network use
are stopped; remote revocation has terminal verified success (or independently
verified already-revoked); both local credential items are removed with checked
results; only policy-selected Strava lineage/evidence is purged; permitted
canonical and authored records survive; no restricted review evidence remains; a
fresh Health workout ingests immediately afterward; the accepted D8 window has a
recorded start; every pre-C8 artifact containing restricted Strava lineage has an
accepted disposition and cannot be restored accidentally. Offline/timeout/4xx/5xx
is a blocked cutover, never a passed outcome.

### AI prompt 18

~~~text
Apply the common preamble and shared campaign contract.

Task 18: design, test and—only after Bruno's explicit destructive approval—execute
Health activation, remote Strava revocation and lineage-aware local purge. Do not
map this onto the old folder-delete coordinator.

Deliver 18A first: build and test the state machine against an isolated database
restored through Task 9's supported path, without changing production. Stop with
the exact preview and acceptance artifact.
18B is a separate run requiring Bruno's immediate explicit destructive approval.

First build a persisted resumable state machine with preview and receipts:
1. stop/cancel Strava refresh, background work and retries;
2. create and independently validate a fresh post-C6 authoritative DB backup and
   populated restore; separately create the personal export/support report and prove
   every Health/checkpoint/import/projection/reconciliation/derived family is covered;
3. fail closed on unknown lineage, unresolved reconciliation, unaccepted loss,
   stale identity or missing D0/cutover approval;
4. reversibly activate the final Health/import/app-authored production priority
   while retaining Strava evidence and credentials. With Strava network unavailable,
   run the final product configuration and ingest a new Health workout. On failure,
   roll back priority and remain locally stopped;
5. only after step 4 passes, call the supported remote revoke endpoint and classify
   checked success, independently verified already-revoked, offline, timeout, 4xx
   and 5xx without pretending success;
6. unresolved revocation leaves Task 18 blocked in a durable local-stopped/retry
   state with the credentials needed to retry. Do not purge or report disconnected;
7. after terminal verified revocation, cross the recorded irreversible boundary,
   purge only the approved raw Strava rows, derived evidence and restricted review
   evidence, and resume forward after later failure—never promise Strava rollback;
8. preserve canonical rows backed by permitted evidence, aliases required by ADR,
   authored notes/RPE/commutes/matches/moves/reviews allowed by policy and bundled
   plan data; reproject/recompute affected derived rows;
9. delete both `strava.tokens` and `strava.credentials` Keychain items with checked,
   retryable results at the approved safe point;
10. remove all active Settings connect/status/rate-limit/OAuth, endpoint, scheduled/
    background and network entry points. Any physical Strava source retained for D8
    compatibility must be compile-excluded or provably unreachable with an invariant;
    close/reopen the database safely and trigger immediate Health catch-up;
11. finalize a durable redacted lifecycle receipt/post-state identity, integrity/
    source census and the UTC/release start of the already-accepted D8 window;
12. create and independently restore/audit a new post-purge authoritative backup and
    new personal export. Inventory every Task 0 starting-evidence package/private
    forensic annex as well as every other pre-C8 backup/snapshot/container/export with
    restricted lineage as rollback-only before revoke and unusable after terminal
    revocation; then apply Bruno's accepted delete or bounded protected-retention
    rule. Record every artifact ID/hash/location/disposition in the C8 receipt and
    make restore refuse an artifact prohibited by that receipt/policy.

Hold Task 9's exclusive maintenance gate from the irreversible boundary until
integrity, canonical/source counts, revisions and the final receipt pass. Purge,
canonical remap/reprojection, derived invalidation and database counts/revision
commit in one SQLite transaction where possible. Remote revoke, Keychain and file/
configuration effects use explicit restart-safe phases around that transaction.
Normal stores remain blocked on every relaunch until the state machine either
finishes or exposes recovery; a half-purged projection is never serveable.

Test every kill point and repeat/retry, offline revoke, server failures, Keychain
failure, open database handles, unknown lineage, mixed-source canonical activity,
review-evidence purge, authored-link preservation, rollback-before-irreversible and
post-commit relaunch. Make retry converge without a second purge or duplicate rows.
Add source/binary/Info.plist/scheduled-work/network invariants proving no active
reconnect/OAuth/Strava request path exists in the production configuration.

Manual-campaign decision: mandatory and destructive. Build and pass the full
campaign first against an isolated/disposable database restored through Task 9 and
a test account/credential boundary; never use Xcode Replace Container. The production campaign must state the irreversible point, expected
remote-account check, exact preview counts by lineage/table, backups and hashes,
rollback limits, exact UI diagnostics and emergency stop. Require Bruno to confirm
the preview immediately before execution. Afterward prove network-negative launch,
terminal remote-account revocation, checked absence of both credential items, active
Strava entry points/work/restricted lineage, preserved authored data, post-state
integrity/counts and one new real Health workout through the full product path.
Independently restore/audit the post-purge backup on a clone and test refusal of one
now-prohibited pre-C8 artifact. Retain redacted receipts; never capture tokens or precise routes. Any non-terminal
revocation result records a blocked campaign and preserves retry state.
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

Require Task 17's accepted D0 contract and Task 18's terminal receipt; prove the
window's recorded time-and-release conditions have objectively elapsed. Do not
define or shorten it now. Build a machine-readable inventory with one row per legacy file,
preference, journal, Keychain item, snapshot/receipt, URL/background trigger,
endpoint, entitlement, reader, writer, destination, migration version, removal
condition, owner and automated/manual proof.

The inventory must explicitly include `hidden-for-test/`, every
`*.written-while-hidden` file and any later internal migration/test artifact. Prove
“Delete local data,” disconnect/purge, protected-history rules and cleanup receipts
cannot omit such a directory merely because it is outside a normal LegacyStore
path. Apply the Task 0 disposition to the retained athlete copy and verify no
success message can coexist with an undeclared app-owned personal-data remnant.
Task 19 verifies that Task 0/18 already dispositioned the known copy; it is not the
first permitted purge point for that Strava-lineage artifact.

Remove or disable legacy writers before readers. Keep any required one-time upgrade
reader isolated under a Data/Upgrade/LegacyJSON boundary; it must be idempotent,
version-gated, absent from normal runtime and have a dated deletion condition.
Remove obsolete dual-write comparisons, file-era disconnect paths, retired Strava
client/model/config code, tasks and build settings only after the inventory proves
no supported upgrade needs them. Do not delete permitted protected historical
evidence merely because it is no longer runtime input; do enforce Task 18's explicit
disposition for artifacts that contain restricted Strava lineage and must never be
restored post-revocation.

Separately preview and execute a versioned, receipt-backed cleanup of obsolete live-
container JSON copies, journals, preferences and transient files after verified
off-device protection. Distinguish frozen protected history/required upgrade
fixtures from stale live copies. Unknown/corrupt inputs remain protected for manual
review; unsupported legacy input fails with a named refusal rather than partial use.

Replace stale JSON 'recovery/export' language: after writers stop it is frozen
migration evidence or a bounded rollback input, not a current export. Current
personal export comes from SQLite and is not restorable; disaster recovery uses
Task 9's authoritative database backup/restore.

Add source-tree invariants and fresh-install, oldest-supported populated upgrade,
repeat-upgrade, partial/corrupt legacy input, no-runtime-reader, export/restore and
sunset tests. Prove no normal launch touches legacy payloads and no Strava endpoint,
credential or background identifier remains outside an explicitly retained upgrade
fixture/document.

Manual-campaign decision: mandatory. Build a disposable oldest-supported upgrade
campaign and a clean-install/DB-only Release campaign. Back up first; upgrade,
relaunch repeatedly, edit authored data, export, restore, move runtime JSON aside,
cold-launch and export a fresh app-generated evidence package. Compare it to the
accepted post-Task-18 database/product baseline and inventory. Verify no files/preferences are recreated,
no network request targets Strava and the bounded upgrade path still works. Restore
shared build settings and retain redacted inventory/evidence.
~~~

---

## Task 20 — Validate and hand off to the proposed behavior-neutral restructure

### Exit gate

The post-D8 baseline is tagged and reproducible; remaining architecture decisions
are accepted by Bruno; the detailed proposed restructure plan is current; R0 closes
without mixing persistence/source-cutover behavior into moves and its first R1
prompt is ready. This task does not execute R1-R15.

### AI prompt 20

~~~text
Apply the common preamble and shared campaign contract.

Task 20: validate and hand off to the proposed behavior-neutral restructure in
docs/PLAN-post-database-strava-project-restructure.md, using
docs/PLAN-codebase-modernization-and-feature-delivery.md as its implementation
companion. The controlling plan is currently “Proposed - validate before execution”;
do not call it approved and do not invent a second restructure plan.

Re-read both plans against the post-D8 tree. Record the new baseline:
tag/commit/patch, green suites, preflight, Release launch/device product matrix,
schema, backup/restore/audit identities and accepted limitations. Resolve every
§24/pre-R0 decision named by the controlling plan, including ownership, module
boundaries, dependency direction, platform seams, observation strategy and
compatibility floor. Present the validated decision package and stop for Bruno's
explicit R0 approval.

After R0 approval, produce the first bounded R1 inventory prompt required by the
controlling plan; do not generate that inventory or add R2 architecture checks in
this task. The handoff prompt must require every later tranche to compile/test before
cleanup, preserve the Tasks 12-19 contracts and isolate any behavioral bug from
mechanical moves.

Manual-campaign decision: mandatory for the handoff baseline. Build the initial full behavior-neutral Release campaign
from the accepted Task-19 product matrix and exact current UI labels. Compare each
future checkpoint to that independent baseline, including cold launch/relaunch, Health
background catch-up, Today/Week/Plan/Progress, reachable details, authored edits,
Settings diagnostics and backup/export/restore. A purely internal move may cite
that campaign plus automated architecture/behavior evidence only when its risk
assessment explains why no additional manual row is needed. Task 20 closes when the
baseline, §24/R0 decisions and first R1 prompt are accepted—not when R1 or R15 is
complete.
~~~

---

## Decisions that must not be guessed

Record each decision in the controlling ADR/groundwork before the task shown. An AI
must stop rather than infer a product, privacy or destructive-lifecycle choice.

| Decision | Required before | Recommended starting position |
|---|---:|---|
| Retained `hidden-for-test` artifact disposition | 0 | Prefer scoped receipted removal after last-copy proof; otherwise move to immutable private evidence with owner/expiry and remove the live copy no later than Task 18 |
| Whether a manually selected match may override automatic eligibility | 1 | Keep non-negotiable exclusions absolute; make the picker explain them |
| B7 circular-gate proof | 5 | Legitimate-empty plus deterministic local full-graph fixture; real run at C6 |
| Health-derived load retention/export/revocation | 3 | Persist explicit lineage and invalidate/purge on lost source permission |
| Every lossy source field classification | 8 | Preserve authoritative facts; explicitly version approved normalization/exclusion |
| Backup confidentiality, local retention and sole-copy protection | 9 | Protected in-container; encrypted off-device; pin pre-activation/newest-known-good |
| Backup preference/account scope and restore compatibility | 9 | Stable non-secret account scope; lossless required prefs; supported-old migration/newer refusal |
| Same-version recovery versus old-app downgrade promise | 11 | DB backup for disaster recovery; keep lossless mirrors for the accepted window unless downgrade is explicitly unsupported |
| Backup-snapshot identity inclusion/exclusion/canonicalization | 9 | Cover all authoritative included state; never hash self fields |
| Migration/activation identity inclusion/exclusion/canonicalization | 10 | Compose source, semantic, backup and checkpoint evidence; never redefine Task 9 |
| Health raw evidence representation/retention | 13 | Queryable identities and provenance; originals only where policy and value justify it |
| Health least-privilege types and persisted-data lifecycle | 13 | Request only feature-required types; truthful usage/export/delete disclosure |
| Canonical app-facing activity identity | 13 | Canonical UUID, with aliases at source boundaries and migrated authored links |
| Health checkpoint reset/expiry policy | 13 | Query-scoped transactional anchors; bounded rescan with visible audit on invalidation |
| Duration/timezone/title/indoor/missing-value rules | 13 | Measured facts first; preserve unknown and expose policy/version |
| Source priority and reconciliation thresholds | 13 | Versioned per-field policy; conservative auto-merge, reversible review otherwise |
| Import formats and original-file retention | 16 | FIT first when needed; add formats only for proven gaps; hash and receipt originals |
| Disposition of unrecoverable history gaps | 16 | Honest partial/unavailable state, never fabricated metrics |
| Hevy future Health-write requirement and historical disposition | 16 | Prove future writes; classify/recover history through the gap ledger |
| C7 duration, workout/source matrix, tolerances and owner | 17 | Set before observing; zero unexplained differences at the accepted scope |
| Production cutover date and race/training-calendar safety | 17 | Choose a low-risk owned window with written abort conditions |
| Exact accepted Strava-only feature/history losses | 17 | Itemized owner acceptance before destructive approval |
| Irreversible post-revocation rollback promise | 17 | Rehearse rollback before revoke; after terminal revoke recover forward from DB/Health |
| Terminal remote-revocation success criteria | 18 | Verified success or independently verified already-revoked; every other result blocks |
| Source aliases after Strava purge | 18 | Retain non-secret durable aliases required for identity/audit unless ADR is amended |
| Pre-C8 artifacts containing restricted Strava lineage | 17 | Mark unusable post-revoke; delete or retain only under an explicit bounded protected policy |
| Active-binary treatment of dormant Strava code | 17 | No active path after C8; retained compatibility source is compile-excluded/unreachable |
| Compatibility window and oldest supported upgrade | 17 | Define before C8; start at its terminal receipt; owner and explicit sunset |
| Live-container cleanup versus protected history | 19 | Preview/receipt stale copies; retain protected/required upgrade artifacts |
| Restructure §24/R0 acceptance | 20 | Treat plan as proposed and obtain Bruno's explicit approval |

## Release gates at a glance

### SQLite activation (end of Task 12)

- Every B1-B8 family and operational mutation is database-first.
- The newest verification-only activation checkpoint binds the last migration
  evidence, current DB semantics/revisions, exact audit and rollback backup, and
  active cache generation under the versioned identity matrix.
- Independent field-complete audit, authoritative DB backup/restore and the separate
  personal export pass.
- Launch is fail-closed; recovery cannot be mistaken for empty data.
- The Release DB-only campaign passes with Strava still connected.

### Strava retirement (end of Task 18)

- Health background/foreground ingest handles additions, updates, deletions, delayed
  evidence and source reconciliation without duplicates.
- Every accepted product feature has a source-neutral input or honest unavailable
  state; historical gaps and review policy are resolved.
- The shadow/disconnected observation window and fresh-workout test pass.
- Final Health priority is activated and exercised before remote revoke.
- Remote revocation reaches terminal verified success; both credential items are
  checked absent; no active reconnect/OAuth/Settings/background/endpoint path remains.
- Post-C6 backup/restore/export covers every new family; no unresolved reconciliation
  or unaccepted product/history loss remains.
- A new post-purge backup/export passes and every pre-C8 restricted-lineage artifact
  is blocked from restore and has its accepted receipted disposition.
- Lineage preview, purge, retry and receipts pass every interruption control, and
  Bruno has approved the exact destructive preview.

### Legacy/code retirement (end of Task 19)

- The D0 window was defined before it started and has objectively elapsed with no
  unexplained authority drift.
- The oldest supported populated upgrade and clean install both pass.
- No normal runtime JSON reader/writer or Strava endpoint/credential/work item remains.
- Obsolete live-container files/preferences are previewed, removed and receipted;
  protected evidence is retained deliberately.
- Authoritative DB backup/restore is SQLite-based, personal export is separate and
  the retained upgrade boundary has an owner and sunset date.

## Current readiness statement

At the reviewed point, the B5 implementation is accepted at patch 433a and Tasks
1–20 have not started. Its Release campaign records 22/22, with one targeted
physical gear-independence proof retained for Task 0A. Task 0 is partially satisfied
by the existing B5 evidence but remains open for the post-B5 lifecycle, disclosure,
evidence-package and test-runner closeout described above. The database migration
is advanced, but the app is not ready to disconnect Strava.

The next action is **Task 0 only**; Task 1 is the next functional product task once
that handoff is accepted. Database activation is Task 12; Strava disconnection is
Task 18; runtime JSON and code retirement is Task 19. Those milestones must remain
separate in status reports and release decisions.
