# SUB4 database cutover: remaining findings and AI task prompts

| | |
|---|---|
| **Reviewed** | 17 August 2026 |
| **Committed baseline** | `96a65d6`, app patch 399 |
| **Active work inspected** | uncommitted patch 400 restore work |
| **Verification** | 1,700 tests in 154 suites passed; all continuous invariants passed |
| **Purpose** | Execution companion for the remaining database, Health and Strava work |
| **Current authority** | `CLAUDE.md` section 5, `ADR-0003-database-contract.md`, and `PLAN-codebase-modernization-and-feature-delivery.md` |

This document records the findings behind work items 0–12 and supplies
clean-start prompts for future AI sessions. It does **not** replace the
architecture plan or ADRs. If this document disagrees with the current source,
the source wins and this document must be updated.

## Current position

D7 B0 through B4 are complete. The app now reads the plan, athlete constants,
authored stores, activities, details and traces from SQLite. B5 is the next
database slice, but the data-safety closeout below comes first.

The repository changed during this review:

- `main` is synchronized with `origin/main` at `96a65d6`.
- Uncommitted patch-400 work is active in `StoreRestore.swift`,
  `NotesStore.swift`, `CommuteStore.swift`, `Weather.swift`,
  `DatabaseHealthView.swift`, the current-state documents and their tests.
- That work adds an additive database-to-file restore for notes and commutes.
- The full suite passes with that uncommitted work.
- Future AI sessions must inspect `git status` before acting and must not
  overwrite or re-create this work.

## How to use the prompts

Each numbered topic contains findings, scope and acceptance criteria. The prompt
is the **first bounded task** for that topic, not permission to implement every
later stage in one change.

Paste the common preamble followed by the selected task prompt.

### Common clean-start preamble

~~~text
Work in /Users/bruno/Documents/Developer/sub4/Sub4.

Before changing anything:
1. Read AGENTS.md if one exists.
2. Read CLAUDE.md completely, especially section 5 and the repository rules.
3. Read docs/ADR-0003-database-contract.md sections referenced by the task.
4. Read docs/PLAN-codebase-modernization-and-feature-delivery.md for the stage.
5. Inspect git status and the latest 20 commits. Existing modified and untracked
   files belong to the user. Preserve them and do not overwrite overlapping work.
6. Confirm AppVersion.patch and the current test count instead of trusting this
   prompt's historical baseline.

Implementation rules:
- Do not edit a migration body that may already have run. Add a new migration.
- Use the existing repository/store types and one-owner rules. Do not create a
  second implementation of an existing mapping or calculation.
- Preserve legitimate empty, unavailable, corrupt and partial as distinct states.
- Hydration must not write. User-authored mutations must not report success before
  their authoritative commit succeeds.
- Do not disconnect Strava, revoke credentials, purge source rows, delete user
  data, commit, push or change external state unless this task explicitly asks
  for it and the user confirms.
- Make the smallest attributable change. Add a negative-control test that fails
  before the fix and passes after it.
- Run focused tests, scripts/check-invariants.py, then ./scripts/test.sh.
- Decide explicitly whether this task needs a manual device-test campaign under
  the contract below. If it does, write the campaign before declaring the task
  complete. If it does not, state which automated evidence makes it unnecessary.
- Report files changed, test evidence, remaining risks and any required device
  validation. Do not call a slice complete from unit tests alone.
~~~

### Manual test campaign contract

Every prompt below carries a task-specific campaign clause. Apply this complete
contract whenever that clause says a campaign is required, or whenever the
implementation touches a behavior the simulator cannot prove:

- real activity, route, recording, HealthKit or Keychain data;
- file-protection attributes, background execution or process termination;
- UI rendering, navigation, orientation, accessibility or interaction latency;
- actual database/file/UserDefaults counts or cross-store reconciliation;
- backup, snapshot, export, restore, deletion, disconnect or fail-closed flows.

The AI must **build the campaign when the need becomes known**. It may not defer
the design to “manual QA later” or ask Bruno to “check that it works.” Put the
campaign in the task's groundwork/ADR section, or create a bounded
`docs/DEVICE-CAMPAIGN-<task>.md` when there is no suitable task document.

Every campaign must contain:

1. **Question and risk.** State exactly what automated tests cannot prove and
   what failure the campaign is designed to reveal.
2. **Build and data identity.** Record app patch, commit, configuration
   (Debug/Release), device model, iOS version, timezone, database schema,
   snapshot ID and migration-run/dataset fingerprint when available.
3. **Safety preconditions.** Name the protected snapshot/export required before
   the test, what may be mutated, what must not be deleted, and the rollback
   procedure. Never use the only copy of authored data for a destructive test.
4. **Exact navigation.** Give tap-by-tap directions using the labels in the
   current SwiftUI source: starting tab, row, disclosure section, button,
   destination screen and any activity/session that must be selected.
5. **Independent expected result.** For every value or state, name where the
   expectation comes from. Do not derive the expected answer from the same
   database-fed store that supplies the screen being tested.
6. **App evidence source.** Name the exact screen/section/diagnostic line from
   which Bruno reads the observed result. If the needed line does not exist,
   the implementation task must add a redacted diagnostic before asking for the
   campaign.
7. **Pass/fail table.** Use:

   `step | action | observed in app | expected from | pass condition | evidence`

   State numeric tolerances, legitimate-empty behavior and every failure state.
8. **Evidence capture.** Name screenshots, copied diagnostic blocks, exported
   files or timestamps to retain. Redact tokens, keys, precise private
   coordinates and free-text notes unless their exact content is the subject.
9. **Cleanup and rollback.** Restore temporary files/settings, reconnect only
   when the task explicitly permits it, and verify the app returns to the
   pre-campaign counts/state.
10. **Uncovered cases.** Record anything not exercised. A partial campaign is
    evidence for its rows only, never for the whole slice.

Preferred independent derivation sources inside the app:

- **Settings → Database:** store-source lines, table census, read-backs,
  comparison sections, trace coverage, write-through result, migration ledger,
  snapshot/receipt information and copied diagnostics.
- **Today / Week / Plan:** planned session identity, scheduled day, completion,
  explicit match and authored note/RPE state.
- **Activities and activity detail:** canonical activity identity, summary
  fields, weather, gear, route, profile, splits, laps and no-trace behavior.
- **Progress:** volume, load, zones, PMC/fitness and monotony derived from the
  accepted input snapshot.
- **Settings → Health coverage:** Health/app overlap, Health-only/app-only
  sessions, summary-only coverage, route and quantity availability.
- **Settings → Data controls / lifecycle previews:** export, deletion,
  disconnect and retained/removed categories.

When two app screens both read the same hydrated store, they are not independent
sources. Derive the expectation from a direct legacy-file read, repository query,
snapshot/audit report, HealthKit coverage result or separately captured
pre-flip baseline, and state which one was used.

---

## 0. Protect the current work and remove repository ambiguity

### Status

**Partly resolved.** The 102 local commits identified in the earlier review have
now reached `origin/main`. The current risk is uncommitted patch-400 restore work,
not an unpushed commit chain.

### Findings

1. The restore work is in progress and must be treated as user-owned.
2. `DetailStore.swift` exists twice:
   - `/DetailStore.swift`
   - `/Sub4/DetailStore.swift`
3. The two files are currently byte-identical and both are tracked.
4. The app source belongs under `Sub4/`. The root copy is not referenced by the
   Xcode project and creates an edit-the-wrong-file risk.
5. Removing the duplicate must be a separate mechanical change after verifying
   target membership and references.

### Acceptance criteria

- The current restore work is committed or otherwise protected before unrelated
  changes begin.
- Only the intended `Sub4/DetailStore.swift` remains.
- Xcode still compiles the intended file exactly once.
- The full suite and invariant checker pass.
- No commit or push happens without the user's approval.

### AI prompt — safe checkpoint and duplicate audit

~~~text
Task 0: protect the current patch-400 work and remove the duplicate root
DetailStore.swift safely.

Start read-only. Inspect git status and classify every modified/untracked file.
The current restore work may have advanced since this prompt was written; do not
edit it or stage it unless the user explicitly asks.

Then prove which DetailStore.swift is compiled:
- inspect the Xcode project/file-system synchronized groups;
- search all project and script references;
- compare the two files byte-for-byte;
- identify whether any tooling deliberately reads the root copy.

If and only if the root file is an accidental, unreferenced duplicate, remove
that root copy in one mechanical patch. Do not touch Sub4/DetailStore.swift.
Add or update an invariant only if it can cheaply prevent a second tracked
source duplicate without hard-coding this one filename.

Run the full suite. Present the exact diff and ask before committing or pushing.

Manual-campaign decision: normally no device campaign is needed for deleting an
unreferenced duplicate. If target membership or runtime loading remains
ambiguous, build a short launch campaign: derive the expected compiled path from
the Xcode build log, then confirm Settings → Database shows the intended app
patch and opens without a duplicate-symbol or missing-store failure. Record why
that evidence is sufficient; do not invent a data campaign for a mechanical fix.
~~~

---

## 1. Close the authored-data safety package

### Status

**In progress. Highest data-safety priority.**

### Findings

#### Restore work

Patch-400 work introduces `StoreRestore` and implements additive restore for:

- `notes.json` through `NotesStore.restore`
- `commutes.json` through `CommuteStore.restore`

The implementation preserves a newer file-side record, moves unreadable bytes
aside instead of overwriting them, rolls memory back on write failure and does
not trigger a database write-through loop. Tests cover additive merge,
idempotence, unreadable-file preservation and disk persistence.

Three authored stores remain in the original five-store risk:

- Match decisions in `UserDefaults` under `Matcher.decisionsKey`
- `moves.json` through `PlanMoveStore`
- `proposals.json` through `ProposalStore` and `ReviewRepository`

The match-decision source is a Data-valued preference, not a file. It needs a
lossless set-aside/backup of undecodable bytes before replacement; it must not
pretend `StoreRestore.setAsideIfUnreadable` is a file solution.

The accepted patch-400 follow-up is match decisions plus moves. Proposal restore
is deferred to B7: the real review table is currently empty, so there is no
device record from which to prove reconstruction. The proposal store is an
ordered array and its database representation is a graph; when B7 owns it,
reconstruction must preserve record identity, order, evidence, proposal changes,
watch items and dates.

#### Database-first writes

`DatabaseWriteThrough.noteAuthoredChange` still starts a fire-and-forget
whole-world import **after** the legacy save succeeds. A process termination
before that import commits can leave SQLite older than the file. On the next
launch, a database-hydrated store can publish the old value.

This does not satisfy the master plan's database-first mutation contract:
SQLite commits before observable success; the temporary JSON mirror follows.

#### Reconciliation blast radius

An `.authored` trigger enables whole-authored reconciliation. A note, commute,
move, athlete or constants save can therefore authorize pruning of notes, match
decisions and reviews based on all current stores. The header in
`DatabaseWriteThrough.swift` still says automatic runs do not delete, while the
`trigger == .authored` branch does permit deletion.

`canReconcile` proves that files were readable, not that their contents were
complete. A valid but truncated `proposals.json` can therefore authorize review
deletion.

#### Removal evidence

`migration_run.rowsRemoved` stores one total. It cannot identify which family
lost rows. The existing `note` column is not suitable because verification and
activation own it.

### Required order inside topic 1

1. Finish and commit patch-400 notes/commutes restore support.
2. Add match-decision and plan-move restore as the next bounded patch.
3. Defer proposal reconstruction/restore proof to B7 and a real review.
4. Make one authored mutation family database-first and prove the pattern.
5. Extend the pattern family by family.
6. Scope reconciliation to the changed family.
7. Add durable family-level removal accounting.

Do not mix all five into one patch.

### Acceptance criteria

- Notes, commutes, match decisions and plan moves can be restored without
  overwriting newer records.
- Proposal reconstruction/restore is explicitly gated on B7 and a real review.
- Unreadable source bytes are preserved losslessly.
- A failed SQLite commit does not publish false UI success.
- A termination between stages cannot lose or revert the edit.
- A note save cannot delete a review or another family's records.
- Every removal is attributable to a migration run and family.
- Save, delete, restore, relaunch and failure paths are tested.

### AI prompt 1A — continue the restore work

~~~text
Task 1A: finish the existing authored-store restore implementation.

This is continuation work, not a rewrite. First inspect the uncommitted
StoreRestore, NotesStore, CommuteStore, Weather, DatabaseHealthView and test
changes. Preserve their contract and current tests.

Add restore support in separate, reviewable increments for:
1. PlanMoveStore from PlanMoveRepository.load.
2. Matcher decisions from MatchDecisionRepository.load.

Important differences:
- moves are a String-keyed dictionary and can use the shared additive merge;
- match decisions live in a Data-valued UserDefaults key, so preserve unreadable
  original bytes losslessly before writing a replacement.

Do not implement ProposalStore restore in this patch. The review table currently
holds no real record, and B7 owns the graph reconstruction and its device proof.
Record that deferral rather than fabricating evidence.

The current file/store copy wins on identity collision. An empty database touches
nothing. Failed database reads and legitimate empty loads remain different.
Restore must not trigger DatabaseWriteThrough.

Extend the Database screen with one receipt per store and clear partial-failure
reporting. Add focused tests for every store, then run the full suite. Do not
start database-first mutations or reconciliation changes in this patch.

Manual campaign required because restore changes real authored files. Build it
before completion. In Settings → Database → authored read-back, derive the
expected per-store database counts from the repository/read-back lines, press
the restore control, read each receipt, then verify the corresponding note,
commute, match or move on Today/Week/activity detail. Relaunch and verify it
persists. Include unreadable-source handling only with a protected disposable
fixture or backup—never corrupt the only authored file on the phone.
~~~

### AI prompt 1B — establish the database-first mutation pattern

~~~text
Task 1B: replace the file-first/fire-and-forget durability window for one
authored family, starting with NotesStore only.

Read the D7 mutation contract and ADR sections around authored write-through.
Trace note create, edit and delete from UI through NotesStore, the repository,
SQLite import/write APIs, observable state and JSON mirror.

Design one narrow SQLite transaction owned by the repository. The required order:
1. validate the edit;
2. commit the authoritative SQLite mutation;
3. publish observable state/UI success;
4. update the temporary JSON mirror;
5. report a mirror failure diagnostically without rolling back a committed DB edit.

Do not run a whole-world import for a single note mutation. Preserve session UID,
timestamps and plan-version semantics. Failed DB commits must retain the user's
edit for retry and identify the unsaved subject.

Add negative controls for:
- DB commit failure before observable publication;
- process/operation cancellation between DB commit and mirror;
- mirror write failure after DB commit;
- create, edit, delete and relaunch from SQLite.

Implement NotesStore only, document the reusable pattern, and stop. Do not migrate
commutes, moves, match decisions or reviews in the same patch.

Manual campaign required for observable save ordering. Create a disposable test
note from Today or Week, record its session UID/day, and derive the expected DB
row from Settings → Database → authored read-back rather than from the hydrated
NotesStore alone. Verify save, edit, relaunch and delete. Include a test-build
failure injection for DB-commit failure and JSON-mirror failure, and specify the
exact alert/diagnostic line expected for each. Restore the original note state.
~~~

### AI prompt 1C — family-scoped reconciliation and removal evidence

~~~text
Task 1C: make reconciliation family-scoped and make every removal attributable.

Map every call that sets AppStores.reconcile and every table pruned by
Sub4Import+Reconcile.swift. Prove the current cross-family path with a failing
test: a note-authored trigger must not be able to remove a review row.

Replace the one global permission with an explicit set of families. A trigger may
reconcile only the family whose mutation completed, and only when that family's
source read is trustworthy. Manual full reconciliation may request several
families explicitly but must preserve the existing safety gates.

Add an additive migration for durable per-run removal detail, preferably
migration_run_removal(runID, family, rows), rather than overloading the ledger
note. Preserve existing migration rows and ordering. Update reports, diagnostics,
retention and tests.

Do not edit an applied migration. Do not combine this with database-first store
rewrites. Run upgrade tests from a populated pre-migration database and the full
suite.

Manual campaign required only after family-scoped reconciliation is wired to a
real control. Use protected disposable records. Derive the pre/post counts from
Settings → Database read-backs and the family-level removal ledger. Delete one
record in the chosen family, run its reconciliation, and prove every unrelated
family count is unchanged. Capture the ledger row naming the exact family.
Never use the first real review as disposable test data.
~~~

---

## 2. Verify storage protection instead of asserting it

### Status

**Open. Security and recovery integrity.**

### Findings

- `FileProtection.protect` uses `try?` when setting protection attributes.
- The Database screen prints “Until first unlock” as a fixed value.
- Simulator tests verify the requested mapping, not the real device attribute.
- `AthleteStore` and `AthleteConstants` remain outside the read-before-write
  protection guard; the invariant ceiling is two.
- A security property that fails silently and is reported as successful is not
  an observable guarantee.

### Acceptance criteria

- Protection writes return/report success or failure.
- Diagnostics read the actual protection attribute from representative files
  and directories.
- The UI distinguishes correct, missing and unreadable attributes.
- Athlete and constants stores gain the same unclean-read overwrite guard, and
  the invariant ceiling falls from two to zero.
- Simulator unit tests and a real-device check are both recorded.

### AI prompt — file protection truth and remaining guards

~~~text
Task 2: make file protection and unclean-read write protection observable.

Inventory every FileProtection.protect call and every file/directory represented
on the Database diagnostics screen. Refactor the protection API so callers can
observe failure without crashing or swallowing it. Add a read-back type that
inspects FileManager attributes and returns three explicit states: expected
protection, no protection attribute, or inspection failure.

Make the diagnostics screen render the measured state, not a constant sentence.
Keep unit tests platform-independent, and document the one real-device acceptance
step needed because simulator protection semantics are not authoritative.

Then bring AthleteStore and AthleteConstants under the same "do not overwrite
after unclean read" contract used by the other writing stores. Lower
UNPROTECTED_STORE_CEILING only after both are covered.

Do not change the chosen protection class or reset user data. Run all tests and
provide the exact on-device inspection steps.

Manual campaign mandatory on a physical locked device. The expected protection
class comes from FileProtection's declared mapping; the observed value must come
from the new FileManager attribute read-back shown in Settings → Database, not
from a fixed label. Cover the database, snapshots, details/streams directories,
authored files and preferences export. Include before-first-unlock/after-unlock
behavior where safe, and record “no attribute” and inspection-failure rendering
using a test fixture rather than weakening real user files.
~~~

---

## 3. Close evidence and behavior gaps left by B1–B4

### Status

**Open closeout work. B1–B4 remain operationally active.**

### Findings

1. `ReadBacks.athlete` compares SQLite with `ConstantsStore.shared` and
   `AthleteStore.shared` values that have been database-fed since B1. It is the
   last read-back still reporting agreement from a database-against-database
   comparison.
2. Patch 399 correctly marks load parity self-referential: both varied inputs,
   activities and traces, now come from SQLite. It proves deterministic
   calculation, not migration parity.
3. `RecordingRepository.all` deliberately represents a `recording` row with
   zero sample rows as a present, zero-length `ActivityStreams`. Several views
   correctly test `isUsable`, but a complete device path for this state has not
   been exercised.
4. Database detail/trace construction measured roughly 0.9 seconds in Debug.
   The comparable Release measurement remains outstanding.
5. The B4 plan expected large sample reads to remain off the main actor. Current
   construction happens synchronously when `DetailStore.shared` is first
   materialized from a post-first-frame task. It still needs interaction/jank
   evidence, not only a construction timestamp.

### Recommended decomposition

1. Give athlete/constants read-back its own file-root instances.
2. Exercise and test the zero-length trace UI state.
3. Take Release and responsiveness measurements.
4. Rescue load parity with an independent file-side input during B6, or keep it
   explicitly classified as a deterministic-only check.

### Acceptance criteria

- Every row counted as independent evidence can genuinely disagree.
- A zero-sample recording renders a clear no-trace state without empty charts,
  broken maps or crashes.
- Release timing and interaction behavior are recorded on-device.
- Self-referential checks remain visibly classified and cannot satisfy the B9
  independent-evidence gate.

### AI prompt — independent athlete read-back

~~~text
Task 3: close the last self-referential read-back, athlete/constants only.

Read ReadBacks.athlete, AthleteRepository, AthleteStore, AthleteConstants and the
existing own-read patterns used by activities, details, recordings and authored
data. Add directory-rooted, non-writing readers for athlete.json and
constants.json, or reuse an existing safe seam if one now exists.

The app side of the athlete read-back must be read directly from the legacy
source files without touching or mutating the shared stores. Preserve legitimate
absence, corrupt reads, optional FTP/zones and resting-month semantics. Compare
the same profile, zone, FTP, resting-month and activity-gear-reference scope the
row claims.

Update ReadBackSource/provenance accounting so the roll-up derives independence
rather than hard-coding it. Add a negative control where the file and DB differ
and prove the row turns red.

Do not change hydration, B5 gear behavior or load parity in this patch. Run the
full suite and state the remaining B3/B4 evidence closeouts.

Manual campaign required for the B3/B4 closeout even if the athlete read-back
patch itself is test-covered. Derive athlete/profile expectations from the new
direct athlete.json/constants.json read-back. For zero traces, select an ID
classified in Settings → Database → trace coverage as answered-empty, then open
Activities → activity detail and exercise route/profile/HR panels. For timing,
use a Release build and the “Detail store built” diagnostic while recording
first interaction latency. Keep each evidence source independent and name it.
~~~

---

## 4. Resolve the match-picker contract

### Status

**Open product decision; code should not guess.**

### Findings

- `MatchPickerView.choiceSection` offers every activity on the day.
- `MatchResolver.day` filters the candidate pool by `isPlanEligible`.
- A user can select a walk, persist the override, and then see the session remain
  “Not done” because the resolver cannot select that activity.
- `MatchResolverTests.anOverrideNamingAnIneligibleActivityIsLost` deliberately
  records the current defect.

### Decision options

1. **Eligibility is absolute:** show ineligible activities disabled with a reason.
2. **Explicit choice overrides eligibility:** allow the selection and make a
   deliberate override win over automatic filtering.
3. **Recommended combined UX:** eligible activities are normal; ineligible
   activities are explained and require a separately confirmed manual override.

The decision affects completion, matching, load and adherence and therefore
cannot be inferred as a UI-only fix.

### Acceptance criteria

- The picker cannot silently store an impossible choice.
- UI and resolver enforce the same rule.
- The current defect test is replaced by tests for the accepted behavior.
- Today, Week, session detail, matching, adherence and load consequences are
  covered.

### AI prompt — decision package before implementation

~~~text
Task 4: prepare and obtain the match-picker product decision. Do not implement
behavior until Bruno chooses.

Trace MatchPickerView, Matcher.setOverride, MatchResolver.day, Activity
.isPlanEligible, adherence and load consumers. Reproduce the existing walk
override defect from its test.

Present three concrete options:
A. filter/disable ineligible choices;
B. explicit override beats eligibility;
C. ineligible choice requires a confirmed manual override.

For each, show the exact effect on session completion, extras, distance, load,
adherence and stale/ghost decisions. Recommend one option with reasoning and
list the tests that would change.

Stop and ask Bruno to select the contract. After the decision, implement the
smallest shared-domain change so picker and resolver cannot disagree. Replace,
do not merely delete, the current defect test. Run the full suite.

After Bruno selects and the behavior is implemented, a manual campaign is
required. Start from Today or Week, open the session's match picker and choose a
known ineligible activity shown in Activities for that day. Derive eligibility
from the activity discipline and Activity.isPlanEligible contract; observe the
picker explanation, session completion, extras placement, adherence and Progress
load. Clear the override and prove every screen returns to its baseline.
~~~

---

## 5. Execute B5: weather and gear

### Status

**Next D7 slice after topics 1–4 are accepted.**

### Findings

Weather is already represented and has a tested restore path. Gear is not yet a
lossless database-backed presentation:

- `AthleteStore` separates shoes, bikes and retired gear.
- `AppStores` flattens them through `allGear`.
- The `gear` table has no kind/category column.
- `Shoe.primary` is not stored.
- `gear.retiredUTC` exists but the importer never writes it.
- Current parity compares name and distance and treats some omissions as
  approved; it cannot prove bike/shoe/retired rendering.
- Activity-to-gear references are retained, but classification is not.

B5 must decide what is authoritative after Strava retirement. “Strava primary”
may be disposable, while bike/shoe kind and retirement are needed for local gear
history and future shoe tracking.

### Acceptance criteria

- An additive schema represents every accepted gear fact needed after Strava.
- Import and repository preserve bike, active shoe, retired shoe and unknown
  reference states.
- Weather and gear comparisons use an independent legacy read until the flip.
- Settings and activity detail render correctly from SQLite.
- Legacy weather/athlete files can be removed in an isolated B5 device test.

### AI prompt — B5 groundwork, no flip

~~~text
Task 5: write the bounded D7 B5 groundwork for weather and gear. Do not flip
production reads in this task.

Follow the B3/B4 groundwork pattern. Inventory every production consumer of
WeatherStore, AthleteStore shoes/bikes/retired/allGear, gear lookup and
knownActivityIDs. Inventory the gear schema, import, repository, parity and
device screens.

Build a field matrix for:
- external ID and canonical ID;
- name and lifetime distance;
- bike versus shoe kind;
- active versus retired state and retirement timestamp;
- primary/default status;
- source/provenance;
- unknown gear references and activity associations.

Classify each field as preserve, intentionally normalize, derive or discard.
Recommend the additive migration required before B5, explicitly considering
post-Strava local gear ownership. Identify independent comparison seams and the
one-line hydration flip.

Write docs/D7-B5-GROUNDWORK.md with negative controls, focused tests, device
screens, performance expectations, rollback and acceptance evidence. Update the
authoritative ADR only with accepted decisions. Stop before implementation and
present the decisions Bruno must approve.

The groundwork must include the future B5 manual campaign in full. Derive the
expected weather and gear inventory from an independent athlete.json/weather.json
read or the B5 read-back, then name the exact Settings gear rows, activity-detail
gear/weather cards and Database comparison lines to inspect. Include an active
shoe, retired shoe, bike, unknown gear reference, missing weather and one normal
weather reading. Specify file-removal rehearsal, relaunch and rollback steps.
~~~

---

## 6. Execute B6: derived metrics

### Status

**Queued after B5.**

### Findings

Derived metrics currently gather inputs from several observable stores:
activities, traces, athlete constants, notes/RPE, matches, commutes and plan
state. As more stores hydrate from SQLite, parity checks can become
self-referential without changing their displayed numbers.

B6 must assemble one explicit repository-backed input snapshot and feed existing
pure calculations. It must not put formula logic into SQL or create parallel
database-specific versions of matching, TRIMP, zones, PMC or volume.

The cache signature currently uses counts and selected versions. B6 must prove
that every material input change invalidates the derived snapshot; count-only
signatures can miss an edit that keeps the same count.

### Acceptance criteria

- One typed input snapshot owns the complete derivation boundary.
- Existing pure functions remain the formula owners.
- Revision/fingerprint changes for edits, deletes and replacements, not only
  count changes.
- Independent legacy evidence exists for matching, volume, zones, load, PMC,
  monotony and screen summaries.
- No unexplained baseline differences remain.

### AI prompt — B6 groundwork and invalidation audit

~~~text
Task 6: prepare D7 B6 derived-metrics groundwork. Do not change formulas or flip
production behavior yet.

Trace every input to matching, volume, pace, zones, TRIMP/load, power conversion,
PMC, monotony and Today/Week/Plan/Progress summaries. Identify which store field
owns each input and whether that field is database-fed.

Design one Sendable repository-backed DerivationInputs snapshot. Existing pure
functions must consume it; SQL must not calculate training formulas.

Audit LoadStore.currentSignature and all derived caches. Add tests demonstrating
whether an edit that preserves record counts can leave a stale result. Propose a
content-revision/fingerprint contract covering every input family.

Define an independent file-side baseline using the existing seams so B6 parity
can still disagree after the flip. Include longest run, mixed sport, partial
trace, no HR, RPE edit, commute toggle, match override and plan move fixtures.

Write bounded groundwork and stop before the hydration flip. Run the full suite
if any audit tests or instrumentation are added.

The groundwork must build the B6 manual campaign. Capture an independent
pre-flip baseline for Today, Week and Progress: matching, volume, zones, load,
PMC/fitness and monotony. State exactly which app card supplies each observed
number and which file-side parity/baseline report supplies its expectation.
Include same-count edits (RPE change, commute toggle, match override, plan move)
to prove revision invalidation, then restore each edit and confirm the baseline.
~~~

---

## 7. Execute B7: reviews and proposals

### Status

**Date/data gated. First real review is due 24 August 2026.**

### Findings

- The rehearsal rows have been removed.
- The current legitimate state is zero real reviews.
- A zero-versus-zero comparison cannot prove reconstruction of the review graph.
- The graph includes review, evidence, evidence lineage, proposal, changes and
  watch rows.
- `ProposalStore.Record` is the rollback/mirror shape and is part of topic 1's
  restore work.
- Review evidence may contain Strava-derived analytics. ADR-0002 requires the
  athlete's verdict to survive while prohibited source-derived evidence is
  purged or rebuilt during the Health transition.

### Acceptance criteria

- At least one real, policy-permitted review exists before final B7 proof.
- The complete graph saves atomically or not at all.
- Record identity and list ordering survive relaunch.
- Delete/restore does not affect unrelated authored families.
- Independent read-back covers real content, not rehearsal duplicates.
- Source lineage determines what survives Strava retirement.

### AI prompt — conditional B7 start

~~~text
Task 7: start D7 B7 only if a real review exists and its creation was permitted.

First inspect ProposalStore, ReviewRepository, ReviewRunner/review policy gates,
ADR-0002 and the Database read-back. Query only local app/database state; do not
send a review payload or call an external model.

If no real review exists, do not fabricate one and do not reuse rehearsal data.
Report the gate and limit work to fixtures/groundwork that cannot be mistaken for
device evidence.

If a real review exists, capture a redacted structural baseline: record identity,
window, evidence count/lineage, proposal count, change/watch ordering and source
classification. Design database-first atomic creation and deletion of the full
graph, plus a temporary mirror and restore path.

Add negative controls for partial graph failure, duplicate timestamps, duplicate
record keys, invalid plan-session references, delete/relaunch and source purge.
Flip reads only after independent parity on the real record and explicit device
acceptance.

Manual campaign mandatory once a real review exists. Derive the expected graph
from Settings → Database → Review trail read-back and the repository's redacted
counts/identity, then inspect Today's review entry and review-history detail for
window, verdict, summary, changes and watch items. Test relaunch and a protected
export/restore path. Do not expose evidence prose in screenshots and do not call
an external model merely to manufacture campaign data.
~~~

---

## 8. Execute B8: sync, retry and operational state

### Status

**Queued after B7.**

### Findings

The database has `sync_state`, `work_queue` and `content_revision` tables, but
runtime authority remains split across `UserDefaults` and store-private state:

- Strava cursor and last sync
- Detail failure/no-stream sets
- Retry and queue state
- Rejection receipts
- Content revisions

The `rejection` table omits two source fields:

- `RejectionReceipt.label`
- `RejectionReceipt.dateIsKnown`

The verifier currently checks rejection count, not those fields. A migrated
verbatim label may be impossible to reconstruct from the existing columns.

The final sync transaction must prevent a cursor/anchor from advancing beyond
rows that failed to commit.

### Acceptance criteria

- Runtime cursor/checkpoint and work queue are repository-owned.
- Source rows, deletions, revision and checkpoint commit atomically.
- Rejection receipts round-trip every accepted field.
- Stale running work recovers deterministically after termination.
- Retry/backoff is bounded and diagnostics retain a safe last error.
- Kill-before/after-commit tests prove no missing-data cursor advance.

### AI prompt — B8 groundwork and rejection gap

~~~text
Task 8: prepare D7 B8 operational-state groundwork and close the rejection schema
gap without flipping runtime authority.

Inventory every read/write of strava.cursor, strava.lastSync,
strava.rejections, detail.failed, detail.noStreams, sync_state, work_queue and
content_revision. Draw the current transaction boundaries and identify every
place a cursor can advance separately from data.

Add a field-coverage test for RejectionReceipt. Prove that label and dateIsKnown
are currently omitted. Propose an additive migration and repository mapping that
preserves them, including legacy migrated labels that cannot be reconstructed.
Do not edit the original rejection migration.

Write D7-B8 groundwork defining queue claim/recovery, retry bounds, source
checkpoint types for Strava epoch versus Health anchor, content revisions and
kill-point tests. The required transaction is rows + deletions + revision +
checkpoint.

Implement only the additive rejection-field tranche if it is independently
reviewable. Do not flip cursor or queue authority in the same patch.

The B8 groundwork must include a physical-device background/termination
campaign. Derive expected activity, cursor, queue and rejection state from
Settings → Database table/read-back/ledger lines. Specify Xcode steps for
backgrounding, force termination before/after commit, foreground catch-up and
retry exhaustion. For every kill point, state the expected cursor/anchor and row
count. Add diagnostics first if the app cannot currently expose those facts.
~~~

---

## 9. Build the final cutover evidence package

### Status

**Open mandatory gate before B9.**

### Findings

The independent August audit found zero differences across explicitly mapped
fields, but its executable and field matrix are not committed. The repository
has no standalone tool that can reproduce the full JSON/preferences/SQLite
comparison.

`migration_run.snapshotID` is an association with a folder name. Import and
verification still read live stores; neither proves it acted on the exact
snapshot bytes named by the row.

Known non-lossless or normalized fields include:

- gear kind, primary and retirement state;
- rejection label and `dateIsKnown`;
- match-decision `dateIsKnown`;
- plan `meta.source` and top-level array ordering;
- fractional fetched timestamps;
- athlete/constants cache metadata such as fetched/version where intentionally
  excluded.

These must be fixed or explicitly accepted. “Verified” under the current
semantic verifier is not equivalent to byte- or field-complete parity.

### Acceptance criteria

- A committed, rerunnable audit tool compares a supplied `.xcappdata` package.
- A machine-readable field matrix names every mapped, normalized, excluded and
  missing field.
- Snapshot/import/verification are bound by a deterministic dataset fingerprint.
- A fresh preferences-inclusive protected snapshot is taken.
- A second quiescent `.xcappdata` export is captured after import and verify.
- The final report records hashes, schema/app version, counts and differences
  without exposing secrets.

### AI prompt — reproducible audit tool and dataset binding design

~~~text
Task 9: turn the one-off JSON-versus-SQLite audit into a committed reproducible
cutover gate.

Read SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md, LegacySnapshot,
Sub4Import, SemanticVerifier, MigrationLedger and the August xcappdata findings
recorded in ADR-0003. Do not assume the old downloaded package is present.

Build a standalone read-only tool under tools/ that accepts an xcappdata path,
discovers Application Support JSON stores, filtered preferences export,
snapshots and SQLite, and emits:
- parse/integrity/FK results;
- record and sample counts;
- field-by-field mapped comparisons with documented normalization;
- unmapped/excluded field inventory;
- deterministic source and database fingerprints;
- machine-readable JSON plus a concise Markdown report.

Commit a versioned field-coverage matrix consumed by the tool or checked against
its mappings. Add synthetic fixtures for mismatch, missing file, corrupt DB,
fractional timestamp normalization, array-order loss and omitted preference
fields.

Separately design the runtime dataset binding: snapshot manifest hash plus a
canonical source fingerprint recorded on the migration run and checked at import
and verification. Do not claim snapshotID alone provides this.

Do not modify phone data or require secrets. Provide the exact final on-device
capture/import/verify/export runbook, but stop before B9 activation.

Manual evidence campaign mandatory and part of the deliverable. Give exact
Settings → Database taps for protected snapshot, Import and verify, copy
diagnostics and export. Then give the Xcode Devices and Simulators steps for
downloading the post-verification xcappdata package. Derive expected snapshot
hash/fingerprint/run ID from the app lines, and expected field/count parity from
the standalone audit report. Name every file retained and the pass/fail rule.
~~~

---

## 10. Execute B9/B10: activate and prove fail-closed behavior

### Status

**Not started. Blocked by B5–B8 and topic 9.**

### Findings

- `Sub4Launch.migrationFailureBlocksTheApp` remains `false` by design until B9.
- `MigrationLedger.activateVerified` exists but has not been used in production.
- Normal app launch still has a legacy rollback path.
- The fail-closed recovery screen required after activation does not yet exist.
- Lifecycle/disconnect behavior still treats the database as removable in the
  pre-activation state. It must become row/lineage-aware before Strava
  disconnect, but disconnect must remain blocked until Health reconciliation.

### Acceptance criteria

- Only the newest verified run over the bound current dataset can activate.
- Activation is transactional and has one authority.
- A failed database open after activation reaches recovery UI, never normal
  empty stores or JSON fallback.
- The complete app works with runtime legacy JSON moved aside.
- Authored save/relaunch works from SQLite.
- Export, restore and lifecycle previews are safe and truthful.
- The B10 device campaign records screen-by-screen evidence.

### AI prompt — B9 groundwork and negative controls

~~~text
Task 10: prepare B9 activation and B10 device proof. Do not flip activation until
all prerequisites are demonstrably closed.

First build a gate report from current code and docs:
- B1–B8 production families database-backed;
- latest import verified against the bound current dataset;
- independent parity gate accepted;
- database-first authored writes complete;
- protected snapshot/export/restore available;
- Health/Strava disconnect still explicitly blocked.

If any prerequisite is false, stop before changing migrationFailureBlocksTheApp
and report the blockers.

Build the negative controls first:
1. ever-activated mirror with missing/corrupt database;
2. unverified or stale newest migration run;
3. database open/migration failure;
4. runtime JSON removed;
5. authored save followed by relaunch;
6. zero-sample recording and legitimate empty families.

Implement one fail-closed recovery state with retry, redacted diagnostics,
protected restore and export guidance. It must not construct normal stores.
Then wire the single transactional activation path and mirror ordering.

Produce a B10 acceptance table for every principal screen and failure state.
Require explicit user approval and a fresh device package before the final flip.
Never disconnect Strava in this task.

The complete B10 manual campaign is mandatory before activation can be accepted.
It must be a screen-by-screen table covering Today, Week, Plan, Progress,
Activities/list/detail/route/charts/splits, weather, gear, notes/RPE, matching,
Review, Settings, Database and background refresh. Derive expectations from the
accepted pre-flip baseline and independent audit—not from the hydrated screens.
Include runtime JSON moved aside, corrupt/missing DB recovery, save/relaunch,
export/restore and rollback. Record exact evidence filenames and uncovered cases.
~~~

---

## 11. Make Apple Health canonical and disconnect Strava

### Status

**Starts after the D7 exit gate. M0 was measured once; durable canonical
ingestion has not started.**

### Findings

- Health M0 on 6 August measured 711 Health sessions across 323 days versus 669
  app sessions across 323 days.
- Fifty-three Health sessions were summary-only; route/quantity completeness is
  not implied by workout coverage.
- The app contains Health coverage/query code, but production activity ingestion
  still calls `StravaClient.activities`.
- Detail and stream ingestion still call Strava endpoints.
- There is no durable Health checkpoint/anchor driving the canonical activity
  repository.
- Disconnecting now would stop new complete ingestion and can remove data under
  current lifecycle rules.

### Required sequence

1. Refresh M0.
2. Add source-neutral raw storage.
3. Define canonical activity construction and source priority.
4. Add durable anchored workout ingestion.
5. Add quantities, routes and events.
6. Rebuild details and derivations locally.
7. Reconcile Health and Strava identities.
8. Add FIT/TCX/GPX recovery for accepted gaps.
9. Run a disconnected rehearsal.
10. Activate Health, revoke Strava, remap authored references and purge
    Strava-lineage data according to ADR-0002.

### Acceptance criteria

- New, updated and deleted Health workouts ingest durably.
- Anchor advances only with the committed batch.
- Duplicate Health/Strava sessions resolve to one canonical activity.
- Routes, samples, moving time, splits and derivations meet accepted coverage.
- Authored notes/matches/commutes survive identity remap.
- Every historical gap is accepted as recovered, degraded or intentionally lost.
- A new workout appears and fully renders while Strava is disconnected.
- Only then are OAuth, networking and Strava-lineage rows removed.

### AI prompt — Stage C0/C0.1 start

~~~text
Task 11: begin the Apple Health canonical-source transition with C0 refresh and
C0.1 source-neutral storage design. Do not disconnect, revoke or purge Strava.

Read ADR-0002, PLAN-cutover-v2 and Stage C of the modernization plan. Re-run the
existing Health coverage measurement on the current database window and produce
a redacted structural report: workout/day overlap, app-only/Health-only,
summary-only, route availability, quantity availability and source/device
families. Do not infer route/sample completeness from workout counts.

Then inventory the current canonical/source/raw recording schema against the
timestamp-first Health requirements. Propose additive migrations for raw workout
identity, quantities, routes/events, source provenance and opaque Health anchor.
The Health UUID is a source identifier, not the canonical activity ID.

Define the atomic batch contract: inserted/updated/deleted source rows,
canonical projection, content revision and anchor commit together. Add
kill-before/after-commit test design and dedup candidate rules.

Write bounded C0/C0.1 groundwork and stop for schema/field-priority approval.
Do not call Strava endpoints unnecessarily, change credentials, purge rows or
claim Health is active.

The groundwork must build the Stage-C physical-device campaign. Derive coverage
from Settings → Health coverage, canonical/table state from Settings → Database,
and rendered results from Activities and activity detail. Specify a newly
recorded Health workout, an update, a deletion, route/no-route cases and the
expected anchored checkpoint after each committed batch. The later disconnected
rehearsal must prove a fresh workout reaches summaries, route/charts and Progress
with Strava unavailable; do not run that destructive/revocation step in C0/C0.1.
~~~

---

## 12. Execute D8: retire JSON and Strava code

### Status

**Last. Starts after Health activation, Strava retirement and the accepted
stability/compatibility window.**

### Findings

Runtime JSON still provides:

- pre-activation rollback;
- independent parity evidence;
- upgrade input for older installations;
- temporary mirrors while authored writes move database-first.

Removing it before D7 and Stage C gates would destroy rollback and audit
evidence. After Health/Strava cutover, stale JSON is not a current backup; the
authoritative export must come from SQLite.

D8 must distinguish:

- production readers/writers to remove;
- time-bounded upgrade readers to retain;
- snapshots/evidence to archive or expire;
- obsolete UserDefaults keys;
- Strava OAuth/network/background code to delete.

### Acceptance criteria

- Minimum supported upgrade version and sunset are explicit.
- Production JSON writers are removed family by family.
- Production JSON readers are removed after writer proof.
- Legacy upgrade code is isolated and fixture-tested.
- SQLite export/restore is authoritative and readable.
- No active source calls Strava networking or OAuth.
- An exhaustive inventory proves no obsolete preference/file path remains.
- One stability release passes before compatibility removal.

### AI prompt — D8 inventory before deletion

~~~text
Task 12: prepare the executable D8 retirement inventory. Do not delete runtime
paths until D7, Health activation and Strava purge gates are proven complete.

Read Stage D of the modernization plan, DataLifecycle, all StoreRead/StoreWrite
call sites, snapshots, preferences, Keychain, StravaAuth/StravaClient and upgrade
fixtures. Determine the minimum supported upgrade version and the one-release
compatibility contract; stop for user approval if they are not already accepted.

Create a machine-checked inventory classifying every legacy file, directory,
preference key and Strava component as:
- production reader;
- production writer;
- supported upgrade input;
- protected evidence/snapshot;
- obsolete and removable;
- retained non-Strava authored/device data.

Add invariants that fail when a new production JSON or Strava call site appears
outside the inventory. Plan removals one family at a time: writer first, prove
SQLite save/relaunch/export, then reader. Keep upgrade fixtures for the accepted
oldest version.

Do not remove or purge user data in the groundwork patch. Produce the ordered
deletion plan, rollback limits, tests and device acceptance campaign first.

The D8 groundwork must include the final manual campaign. Derive the expected
remaining filesystem/preferences inventory from the executable legacy inventory
and an xcappdata export, then verify normal screens, authored save/relaunch,
SQLite export/restore and supported-old-version upgrade. Settings → Database must
show SQLite authority with no legacy fallback; Xcode's downloaded container
provides independent proof that retired runtime files/keys are absent. Include
rollback limits and never delete the only supported upgrade fixture.
~~~

---

## Dependency summary

~~~text
0 protect current work
        ↓
1 authored safety ── 2 protection truth ── 3 completed-slice evidence
        ↓                         ↓
4 product decision                │
        ↓                         │
5 B5 weather/gear ←───────────────┘
        ↓
6 B6 derived metrics
        ↓
7 B7 real reviews
        ↓
8 B8 operational state
        ↓
9 reproducible final audit and dataset binding
        ↓
10 B9 activation + B10 device campaign
        ↓
11 Apple Health canonical + Strava retirement
        ↓
12 D8 JSON and Strava code retirement
~~~

## Final readiness statement

The database migration is progressing well and B1–B4 are operational. The
highest remaining risk is not whether SQLite can hold activity data; it is
whether authored changes, reconciliation and recovery remain safe while SQLite
becomes authoritative.

Strava must remain connected until topic 11's Health ingestion, reconciliation
and disconnected rehearsal have passed. D8 follows the Health/Strava transition,
not the other way around.
