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
| **Current task** | **Task 0B** — the starting-evidence package, **all five tranches landed at 442–446; the campaign is next**. Task 0A is ACCEPTED — `docs/evidence/post-b5/task-0a.json`, 22 August 2026 08:18 UTC, *"I accept 0A."* Next is **Task 0B** |
| **Patch** | 446 |
| **Tree** | verified from source at each patch, not from the runbook's recorded numbers |
| **Next gate** | **Task 0B** — the starting-evidence package. Its manifest cites `task-0a` as a predecessor by hash, which is the first real use of 438's chain |

## Task 0B tranches

| # | Tranche | Patch | State |
|---|---|---|---|
| 1 | the evidence barrier — quiesce, fingerprint, detect | **442** | **done** — 6 writers asked, 4 detected only, RULE 16 joins the claim to the wiring (§12.198) |
| 2 | the transaction-consistent database copy, through GRDB's backup API | **443** | **done** — five refusals, counts compared on both sides, one file with its journal folded in, RULE 17 (§12.199) |
| 3 | the package: snapshot + copy + manifest + redacted report, one capture id | **444** | **done** — declared in the lifecycle inventory in the same patch as the writer; three unwatched directories named in the manifest with reasons; the snapshot re-hashed inside the package (§12.200) |
| 4 | the off-device validator and its fixtures | **445** | **done** — shares nothing with the app, never writes, sixteen fixtures each damaged one way, twenty properties in `selftest-evidence-package.sh`, run as preflight stage 4 (§12.201) |
| 5 | the share UI, protection warning, cancellation and low-space refusals | **446** | **done** — its own `View` type from the first line; three presses; the warning asserted; cancellation between stages; the zip made outside the package. **Driving it on the simulator found the empty-directory bug thirteen tests missed** (§12.202) |
| 6 | the campaign — one run, after all five | — | **next** — not yet written. A package captured through the UI to completion is the one thing no test can prove |

**Findings that shaped it**, both measured rather than assumed: `content_revision`
has a table and **zero writers**, so the runbook's "use a current revision as
supporting evidence only after proving every relevant writer advances it"
resolves to *there is no such revision* and the package must say so. And GRDB's
`DatabaseReader.backup(to:)` drives SQLite's own online-backup API, so tranche 2
needs no hand-rolled copy — which the runbook forbids.

## Task 0A tranches

| # | Tranche | Patch | State |
|---|---|---|---|
| 1 | Reconcile current-state truth: CLAUDE §5, README, Database diagnostics | **434** | **done** — `sliceUnderTest` had said weather and gear came from files since the 430 flip; a two-way join now couples the disclosure to `hydratedFamilies` (§12.189) |
| 1b | `DataLifecycle` names which copy is read | **437** | **done** — a disclosure-only field, derived sentence, joined to `hydratedFamilies`; NOT a `StorageLocation`, because `removeEverything` walks those (§12.192) |
| 2a | `hidden-for-test/` role, inventory, exclusions, redacted paste | **439** | **done** — `AppSupportItem.internalTestArtifact`; deletable, excluded from snapshots and parity BY CASE, export names the omission, disconnect keeps it as a last-copy guard; path/hash/bytes/status only (§12.194) |
| 2b | the scoped, receipted removal of the leftover copy | **441 · 441a · 441b** | **DONE ON THE PHONE, 22 Aug 09:13.** `removed hidden-for-test/athlete.json.written-while-hidden · 1507 bytes · d8cc76b5… · snapshot 2026-08-22-071101 · 2026-08-22T07:13:14Z · verified absent`. 441a fixed a device-only crash the rows caused (§12.76); 441b fixed the stale row 441a's extraction caused (§12.197) |
| 3 | Populated pre-B5 upgrade regression | **436** | **done** — migrates to `2026-08-20-run-removal`, populates as the pre-426 importer did, then applies B5; proves honest defaults *then* reconciliation (§12.191) |
| 4 | `scripts/test.sh` cannot share a simulator or overwrite evidence | **435** | **done** — repository lock, run-stamped logs, trap-safe release, inherited by `preflight.sh` (§12.190) |
| 5 | `docs/evidence/post-b5/` manifest schema, validator, fixtures | **438** | **done** — v1 schema, `scripts/evidence-manifest.py`, ten fixtures and thirteen properties in `scripts/selftest-evidence.sh`, run as preflight stage 4. MISSING ≠ STALE; validating nothing exits 2; `--require-recompute` refuses an unrecomputable tree digest (§12.193) |
| 6 | Narrow Strava-disabled gear-provenance campaign | **written at 440, RUN 22 Aug** | **DONE — seventeen of seventeen.** B5 row 19's residual is closed: gear and weather drawn from a cold launch with both files renamed out of reach, Strava off and its refusal observed, rendering read before any file-side diagnostic. Findings: the two `athlete.json` copies are the same size and different hashes; no mirror reappeared with the gates shut, so launch hydration does not write |
| 1c | B5 groundwork marked historical/accepted | **440** | **done** — status row and banner; the chronology is kept, and the file no longer reads as a statement about today |

## Decisions waiting on Bruno

| Decision | Blocks | Runbook's recommended starting position |
|---|---|---|
| ~~Retained `hidden-for-test/athlete.json.written-while-hidden` disposition~~ | ~~tranche 2~~ | **DECIDED 22 Aug: scoped receipted removal.** Preview is on the device — `hidden-for-test/athlete.json.written-while-hidden · 1507 bytes · d8cc76b5f678622fc18f53e7cd2a2552d6dde122c3096721e2da2ebbebda1ad2` |

## Carried forward as design, not yet scheduled

| Item | Where | State |
|---|---|---|
| **An acceptance is the one field a manifest cannot check** | `docs/DESIGN-evidence-attestation.md`, written at 441b | **design only.** Tier 1 (commit-once rule, `--require-git` bracketing, push-as-witness) is free and needs no secrets; Tier 2 (SSH-signed acceptance tags) needs a NEW key — this machine has none and the remote is HTTPS — so it waits on a key-custody decision; Tier 3 (public timestamping) is rejected with a reason. Proposed home: **Task 10** |

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
| 441 | Task 0A tranche 2b — clearing one internal-test leftover, with four refusals |
| 441a | the rows crashed the Database screen on the device — a separate `View` type (§12.76) |
| 441b | and the extraction had gone on printing a file that was gone (§12.197) |
| 442 | Task 0B tranche 1 — the evidence barrier, and RULE 16 |
| 443 | Task 0B tranche 2 — the diagnostic database copy, and RULE 17 |
| 444 | Task 0B tranche 3 — the package, and the lifecycle declaration that comes with it |
| 445 | Task 0B tranche 4 — the off-device validator and sixteen fixtures |
| 446 | Task 0B tranche 5 — the control, the warning, and the bug driving it found |
