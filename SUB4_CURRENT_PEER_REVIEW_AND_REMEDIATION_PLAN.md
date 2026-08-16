# Sub4 Database Cutover and Strava Exit Plan

**Review date:** 2026-08-10

**Code baseline:** patch 338 worktree

**Device evidence:** `be.apatch.Sub4 2026-08-09 16:35.24.476.xcappdata`

**Status:** HISTORICAL — a review of the patch 338 worktree. Its evidence and
its argument stand; its statement of where the project is does not.

> **THIS IS NOT CURRENT STATE — patch 384.** The filename says CURRENT and the
> file is 46 patches behind. Two things below have been overtaken:
> **"not yet running from the database"** was true at 338 and is not now — D7's
> B0, B1, B2 and B3 landed at 342, 346, 358/377 and 383, so the plan, the
> athlete, the authored data and all 694 activities are read from SQLite on
> every launch. And the destructive-disconnect lifecycle it describes was
> stopped at 372.
>
> **What still stands, and is why this file is kept:** the 2026-08-09 device
> audit, the gap between *mapped-field agreement* and *information identity*
> (ADR §12.86 draws the same line and it has not moved), and the separation of
> the database gate from the Strava gate.
>
> **`CLAUDE.md` §5 is this project's only statement of current state.**

## Executive conclusion

*Written against patch 338 on 2026-08-10. The first sentence is the one that
has been overtaken — see the banner above.*

Sub4 is **not ready to disconnect Strava** and is **not yet running from the
database**.

The database is a strong, normalised shadow copy of the operational JSON data.
The independent device audit found no differences in the fields the importer
explicitly maps and normalises. That is not the same as complete information
identity: several source facts and list ordering are not represented, the
semantic verifier does not check them, and production screens still load the
JSON stores.

Disconnecting Strava today would stop new activity ingestion. The current local
disconnect lifecycle also removes the database directory with the Strava-derived
stores, so it is destructive rather than a supported source handover. Database
cutover (D7/D8) and replacement of Strava with HealthKit (Phase 4A) are separate
gates.

## Evidence from the phone package

### Current live legacy package

| Store | Records | Database result |
|---|---:|---|
| Activities | 678 | 678; all 22 mapped fields agree |
| Details | 483 | 483; scalar fields, 5,941 splits, 1,771 laps and 599 efforts agree |
| Recordings | 470 | 470; all 140,790 samples and mapped series values agree |
| Weather | 586 | 586; all 11 mapped fields agree |
| Reviews | 6 | 6; mapped review/evidence/proposal/change/watch values agree |
| Plan | 1 active version | mapped plan values agree |
| Gear | 11 | names, distances and 488 activity references agree |
| Rejections | 3 in UserDefaults | three database rows; mapped values agree |
| Notes / corrections | absent | zero database rows, which agrees with the rebuilt phone |

All 958 current JSON/file-store payloads parse. The latest two protected
snapshots contain byte-identical source payloads, and all 2,709 copied snapshot
files in the four manifests match their SHA-256 values. SQLite `integrity_check`
is `ok` and `foreign_key_check` returns no rows.

### Coverage, not corruption

The legacy package itself is incomplete because the Strava backfill was still
running:

- 195 activities have no detail;
- 208 have no recording;
- 92 have no weather;
- the missing details are the earlier 2025-07-01 through 2025-10-15 range;
- all six reviews are rehearsal copies, not real monthly reviews.

This means the database faithfully mirrors the mapped portions of the package
it was given; it does not mean the package or field coverage is complete.

## Information not preserved losslessly

These are cutover decisions or fixes, not unexplained row-count differences:

1. **Gear classification and state** — the database flattens bikes, active
   shoes and retired shoes. It does not preserve `primary`, collection kind,
   retirement membership or the athlete fetch timestamp. Activity-to-gear
   references are preserved.
2. **Rejection audit text** — `RejectionReceipt.label` and `dateIsKnown` are not
   stored. The label is not reconstructible from the current rejection row.
3. **Match-date provenance** — `MatchDecision.dateIsKnown` is not stored.
4. **Plan source and order** — `meta.source` is dropped. `plan_session` and
   `plan_exercise` have no top-level ordinal; 225 of 261 session positions and
   all 20 exercise positions differ when read by UID.
5. **Timestamp precision** — fractional source fetch times are normalised to
   whole-second ISO-8601.
6. **Accepted cache-state exclusion** — `AthleteConstants.version` is not stored;
   it is a local cache invalidation value rather than an athlete fact.
7. **Existing snapshot boundary** — all four pre-338 snapshots omit declared
   UserDefaults values, including Data-valued rejection/match payloads and sync
   state. The `.xcappdata` export still contains the live preferences plist,
   but the protected snapshots do not.

The database also contains useful information absent from JSON: canonical ids,
source records and aliases, lineage joins, plan version/hash/activation state,
work queues and the migration ledger. It is a semantic/provenance model, not a
byte mirror.

## Patch 338 remediation implemented in this review

### Protected snapshots

- One captured `Date` now supplies both the folder id and the real ISO-8601
  `createdUTC`; old manifests remain decodable and expose no invented date.
- New snapshots add a filtered, lossless binary `preferences.plist` containing
  every UserDefaults key declared by `DataLifecycle`; Keychain and undeclared
  framework preferences remain outside the boundary.
- A present empty declared directory is copied and verified instead of making
  every clean-install snapshot permanently incomplete.
- Retention independently re-hashes every candidate payload before deletion.
- The just-created snapshot is always protected, including after a device-clock
  rollback. Incomplete, corrupt, empty-manifest, unsafe-path and tampered
  folders never authorise deletion and remain for inspection.
- Two verified snapshots remain fully restorable: the just-created capture and
  the newest other verified copy.
- Before an older payload folder is removed, an atomic audit receipt is written
  and read back. It embeds the complete manifest, exact manifest digest, counts,
  byte total, capture/prune times and app versions. A receipt is not a backup.
- Snapshot/receipt ids cannot be overwritten or reused.
- Audit receipts are bounded to the newest 20 verified records; invalid or
  unknown receipts are retained rather than guessed about.
- Cleanup warnings do not turn a successful capture into a false failure or
  trigger a dangerous retry.

After installing patch 338 and taking one complete snapshot, the expected
state is two full snapshots (the new one and the newest prior verified copy)
plus compact receipts for the other old verified copies.

### Migration ledger

- A sixth terminal state, `interrupted`, distinguishes a killed prior process
  from a run open in this process.
- The new migration rebuilds the table with `recoveredUTC` and an autoincrement
  `sequence`; same-second rows are ordered by insertion, not UUID text.
- Launch recovers pre-existing `running` rows before any new import can open.
  The unknowable finish time stays null. A recovery error remains non-fatal
  before D7 but is shown in Settings and diagnostics instead of being swallowed.
- Automatic interruption history is bounded to the newest 20. Manual and
  pre-trigger evidence remains durable.
- Import completion can write only `pending` or `failed`.
- Only the newest completed `pending` row can transition to `verified`; running,
  interrupted, failed, activated, unknown and superseded rows are refused.
- Verification preserves the import finish time. Activation has its own
  verified-to-activated transition.
- A populated five-state predecessor-table test proves the on-device upgrade
  retains every field and insertion order.

The captured newest row is currently `running`. After patch 338 first launches,
it becomes `interrupted`, so an older pending row cannot be verified. Perform a
new manual import and then verify that new pending row.

## Other peer-review findings

### P0 — blocks database authority or Strava removal

1. The current verifier checks mostly counts plus a limited activity
   fingerprint. It does not prove the unmapped fields above, plan ordering,
   constants/FTP completeness, or literal source equivalence.
2. Production stores and screens still load JSON. Repositories are exercised by
   the database health/parity tooling, not used as the application read path.
3. Database-open failure still fails open because the JSON UI can continue.
4. The current export/delete flow treats the entire database folder as local
   derived data. D7 needs an authoritative readable export and lineage-aware
   row deletion that preserves authored, bundled and future Health data.
5. Destructive lifecycle work does not yet own a close/reopen boundary for the
   live GRDB handle.
6. No production HealthKit workout adapter currently replaces Strava activity
   ingestion. Source priority, deduplication, moving time, routes, gear and
   zones remain Phase 4A work.
7. `migration_run.snapshotID` is currently an association, not proof of the
   bytes imported or verified. Import and Verify each gather live stores
   independently, while automatic writers can resume between them.

### P1 — must be resolved or consciously accepted

1. A reproducible external field-coverage matrix/tool is not committed. The
   current independent audit is evidence, but cannot yet be rerun from the repo.
2. Existing snapshots remain file-store-only; a fresh post-338 snapshot is
   required before relying on snapshot protection for migration inputs.
3. Review parity is six copies of one rehearsal payload. Real review evidence
   cannot exist before the first real review.
4. The user manual and several context documents describe the pre-database or
   pre-wipe state and need a D7 documentation pass.
5. The match picker can persist an activity the matcher refuses; this is a
   separate athlete-policy decision already recorded in `CLAUDE.md`.

## Ordered execution plan

### Gate A — finish the backfill and capture a protected baseline

1. Install patch 338 and let launch recover the three old open ledger rows.
2. Complete the Strava detail/recording/weather backfill until every intentional
   absence is named and work queues are idle.
3. Create one new protected snapshot and confirm:
   - it is complete;
   - `createdUTC` is ISO-8601;
   - `preferences.plist` is present and hashed;
   - two full snapshots remain;
   - older verified copies have detailed receipts;
   - no retention warning is present.
4. Export a pre-cutover `.xcappdata` package as the rollback baseline.

**Exit:** protected baseline inputs and zero unexplained backfill work. This is
not yet a technical freeze: live writers remain active until Gate B binds the
dataset used by import and verification.

### Gate B — prove complete semantic coverage

1. Decide for each lossy field whether to add schema/import/read support or
   document a deliberate, consumer-tested normalisation.
2. Add ordinals for plan sessions/exercises unless every consumer is explicitly
   order-independent and that contract is tested.
3. Extend the verifier for rejection details, gear kind/state, plan/constants,
   and the final field-coverage decisions.
4. Commit a standalone audit tool and coverage matrix.
5. Implement a real currentness binding. Recommended: compute one source-dataset
   plus snapshot-manifest fingerprint, store it on the import run, pause automatic
   writers during the final import/verify window, and require Verify to observe
   the same fingerprint. Importing directly from the protected snapshot is the
   alternative. A bare `snapshotID` label is insufficient.
6. Run one new manual import, then immediately run verification on that newest
   completed pending row under that binding.
7. Export a second, quiescent `.xcappdata` package **after** the import and
   verified transition.
8. Compare that post-verification package's JSON, preferences and SQLite
   database with the independent tool.

**Exit:** no unexplained difference, no unexamined source field, newest import
verified under the declared contract.

### Gate C — D7 database read activation

1. Repoint each store hydration/read path to repositories one domain at a time.
2. Keep frontend/domain models source-neutral; Strava belongs behind an ingest
   adapter, never in views.
3. Add end-to-end tests that launch from database-only fixtures and exercise
   Today, Week, Plan, Progress, details, notes and reviews.
4. Make database-open failure block database-authoritative screens with a clear
   recovery path.
5. Implement readable database export/restore, connection close/reopen, and
   lineage-aware disconnect/deletion.
6. Implement and test JSON rollback before activation, then retain it throughout
   the D8 release window.

**Exit:** in an isolated database-only test, remove/rename live JSON and prove
the app still launches and functions from SQLite; then restore/retain the
production JSON copy for D8 parity and rollback.

### Gate D — D8 stabilisation

1. Run one release window with database reads active and write-through/parity
   still observing both sides.
2. Monitor integrity, foreign keys, work queues, ledger interruptions, UI output
   parity and export/restore.
3. Stop JSON writes only after the observation window is clean.

**Exit:** SQLite is the sole runtime authority and produces the authoritative
current export/restore package. Legacy JSON is frozen migration evidence and
limited rollback material, not a current export.

### Gate E — replace Strava ingestion

1. Build the HealthKit adapter for workouts, routes, samples and events.
2. Define source priority, identity and deduplication against the existing
   Strava history.
3. Implement and validate moving-time, route/history, gear and local-zone
   replacements.
4. Ingest a fresh real workout on device, prove it appears in every relevant UI,
   survives relaunch and is included in export without a Strava request.
5. Stop Strava scheduling, revoke OAuth, and purge only Strava-restricted
   lineage while preserving authored, bundled and Health-owned data.

**Exit:** a new workout completes the full phone-to-database-to-frontend loop
with Strava unavailable. Only then is disconnect safe.

## Final architecture position

The intended structure remains sound:

```text
Source adapters (Strava now; HealthKit later)
                    ↓
          ingestion/application API
                    ↓
      SQLite repositories and provenance
                    ↓
       source-neutral domain/read models
                    ↓
              SwiftUI frontend
```

The repository has most of the database and repository layers, but today the
frontend still reaches JSON-backed stores. The final position is not a remote
web API requirement; for this single-user iOS app, the “API” is the typed local
application/repository boundary. It is validated by dependency tests, database-
only launch/UI tests, source-offline ingestion tests, export/restore, and by
removing the legacy files during a test run.

## Readiness verdict

| Question | Answer |
|---|---|
| Does SQLite contain the mapped current JSON data? | Yes, with zero audited mapped-value differences. |
| Does SQLite contain literally all source information? | No; the listed fields/order/precision remain lossy. |
| Is the current source package complete? | No; backfill was still incomplete at capture. |
| Does the app currently read from SQLite? | Not for normal product screens. |
| Can Strava be disconnected now? | No; it is still the only production activity ingest path. |
| Are the external-audit findings addressed? | The four housekeeping defects plus the snapshot-input boundary are addressed in patch 338; installation, recovery and a new preferences-inclusive capture still need device proof. |
