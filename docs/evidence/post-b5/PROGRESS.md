# Post-B5 runbook — where the build is standing

**Updated at the end of every patch.** The controlling runbook is
`docs/PLAN-post-B5-database-cutover-execution.md`; this file says how far
through it we are and what the next gate is. It never restates the runbook's
prompts or exit gates — a second copy of those would go stale.

**It is kept HERE and not inside the runbook** because the runbook is Bruno's
document and has been carrying uncommitted hand edits; the working agreement's
rule is not to overwrite those. `docs/evidence/post-b5/` is the directory the
runbook itself designates for task evidence, so a progress index belongs in it.

---

## Now

| | |
|---|---|
| **Current task** | **Task 0A** — close current truth, lifecycle and evidence tooling |
| **Patch** | 440 |
| **Tree** | verified from source at each patch, not from the runbook's recorded numbers |
| **Next gate** | **tranche 2b — the scoped receipted removal — is the last open Task 0A item.** Then the Task 0A record, then Task 0B |

## Task 0A tranches

| # | Tranche | Patch | State |
|---|---|---|---|
| 1 | Reconcile current-state truth: CLAUDE §5, README, Database diagnostics | **434** | **done** — `sliceUnderTest` had said weather and gear came from files since the 430 flip; a two-way join now couples the disclosure to `hydratedFamilies` (§12.189) |
| 1b | `DataLifecycle` names which copy is read | **437** | **done** — a disclosure-only field, derived sentence, joined to `hydratedFamilies`; NOT a `StorageLocation`, because `removeEverything` walks those (§12.192) |
| 2a | `hidden-for-test/` role, inventory, exclusions, redacted paste | **439** | **done** — `AppSupportItem.internalTestArtifact`; deletable, excluded from snapshots and parity BY CASE, export names the omission, disconnect keeps it as a last-copy guard; path/hash/bytes/status only (§12.194) |
| 2b | the scoped, receipted removal of the leftover copy | — | **open** — preview → confirm → remove → verify → receipt, with the four refusals. *Needs Bruno's disposition decision first* |
| 3 | Populated pre-B5 upgrade regression | **436** | **done** — migrates to `2026-08-20-run-removal`, populates as the pre-426 importer did, then applies B5; proves honest defaults *then* reconciliation (§12.191) |
| 4 | `scripts/test.sh` cannot share a simulator or overwrite evidence | **435** | **done** — repository lock, run-stamped logs, trap-safe release, inherited by `preflight.sh` (§12.190) |
| 5 | `docs/evidence/post-b5/` manifest schema, validator, fixtures | **438** | **done** — v1 schema, `scripts/evidence-manifest.py`, ten fixtures and thirteen properties in `scripts/selftest-evidence.sh`, run as preflight stage 4. MISSING ≠ STALE; validating nothing exits 2; `--require-recompute` refuses an unrecomputable tree digest (§12.193) |
| 6 | Narrow Strava-disabled gear-provenance campaign | **written at 440, RUN 22 Aug** | **DONE — seventeen of seventeen.** B5 row 19's residual is closed: gear and weather drawn from a cold launch with both files renamed out of reach, Strava off and its refusal observed, rendering read before any file-side diagnostic. Findings: the two `athlete.json` copies are the same size and different hashes; no mirror reappeared with the gates shut, so launch hydration does not write |
| 1c | B5 groundwork marked historical/accepted | **440** | **done** — status row and banner; the chronology is kept, and the file no longer reads as a statement about today |

## Decisions waiting on Bruno

| Decision | Blocks | Runbook's recommended starting position |
|---|---|---|
| ~~Retained `hidden-for-test/athlete.json.written-while-hidden` disposition~~ | ~~tranche 2~~ | **DECIDED 22 Aug: scoped receipted removal.** Preview is on the device — `hidden-for-test/athlete.json.written-while-hidden · 1507 bytes · d8cc76b5f678622fc18f53e7cd2a2552d6dde122c3096721e2da2ebbebda1ad2` |

## Found while working, not yet closed

| Finding | Where | State |
|---|---|---|
| **`SkipStandingTests.recordingASkipRoundTrips` passed only on a dirty simulator** | found at 437 | **closed at 440** — the test used `Matcher.shared`, which commits to the app's REAL database; `match_decision.accountID` references `account` and a fresh container has none, so the FK refused and the refusal was correct. On the seam now, with the no-account state driven on purpose. **The full suite is green on a freshly erased simulator** — a run nobody had ever done (§12.195) |

## Housekeeping carried from B5

| Item | State |
|---|---|
| Shared Xcode Run scheme | **closed** — Debug in working tree, index and HEAD; RULE 14 green |
| Debug build on the phone | **open, non-blocking** — due before Task 3 sets the next timing baseline |
| `hidden-for-test/athlete.json.written-while-hidden` | **on the phone**, named by the app's own line since 433a |

## Tasks 1–20

Not started. Task 1 is the next functional product task and begins only after the
combined Task 0 acceptance manifest.

---

## Patch log since the runbook took over

| Patch | What it closed |
|---|---|
| 434 | Task 0A tranche 1 — the disclosure that had been false for five patches, its two-way guard, and RULE 5's case-counting parser |
| 435 | Task 0A tranche 4 — the repository lock and per-run evidence identity |
| 436 | Task 0A tranche 3 — the only test where `ALTER TABLE` runs over rows |
| 437 | Task 0A tranche 1b — the lifecycle screen says which copy is read |
| 438 | Task 0A tranche 5 — the evidence manifest schema, validator and ten fixtures |
| 439 | Task 0A tranche 2a — `hidden-for-test/` gets a role, and the delete flow stops walking past it |
| 440 | the order dependency found at 437 — a test that passed only on a dirty simulator |
