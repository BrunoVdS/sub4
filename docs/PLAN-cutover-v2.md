# Database cutover, Strava retirement and the disconnect — plan v2

**Status:** current. Supersedes `PLAN-281-282-disconnect.md` (v1, same day).
**Date:** 5 August 2026, at patch 280.
**Folds in:** the peer review `STRAVA_DATABASE_CUTOVER_PLAN.md`, with its
adopted, rejected and held items recorded in §7 rather than merged silently.

---

## 0. The two findings this plan answers

**The inventory lies.** `.database` in `DataLifecycle.swift` claims *"no training
data at all — only an empty schema"*, declares `lineage: [.device]`, and keeps
itself on a Strava disconnect **on the strength of being empty**. At patch 280 it
holds 51 tables and ~212,297 rows, including 668 activities, 192,954 recording
samples and 580 weather rows. The entry's own gap predicted the rewrite —
*"When step 3.4 moves the stores into it, this entry's lineage, export rule and
disconnect rule must all be rewritten"* — and 3.4 happened across patches
265–280 without it following.

**Nothing reads the database.** `Sub4Launch.swift` line 33 says so in as many
words. A disconnect today deletes `activities.json`, the routes, the traces and
the weather — leaving the app blank — while the database quietly keeps a
complete copy of everything the receipt just said was gone.

The peer review contains neither of these. Its Phase 9 assumes the disconnect
gets written correctly when the time comes; it has no item for code that is
wrong right now.

---

## 1. Sequencing

```
281  make the inventory true              ← next, today
M0   measure Apple Health coverage        ← next, and it can invalidate the rest
D5   remaining slices
D6a  repositories
D6b  write-through
D6c  shadow parity
D7   activate  +  282 row-level disconnect
4A   Health ingestion, reconciliation, rehearsal, disconnect
D8   retire JSON and Strava code
```

Two changes from v1, both from the review:

- **The ladder gains three named rungs where it had one.** v1 and the handoff
  went D5 → D6 shadow parity → D7 activate. Nothing in that made the database
  current without pressing Import, so parity would have compared a live JSON
  store against a database last refreshed on Tuesday and produced divergence
  for a boring reason. Repositories, then write-through, then parity.
- **M0 moves to the front.** See §3. It is cheap, it is read-only, and a
  negative answer reshapes everything below it.

**281 stays first.** It is a truth fix with today's semantics, it closes the
retention hole today, and it plants the trigger that forces 282 at the right
moment.

---

## 2. Patch 281 — make the inventory true

### 2.1 The rule flips to `.removeEverything`, and that is correct *only now*

The tempting fix is a softer `why` on the existing `.keep`. That keeps 212,297
Strava-derived rows on a phone whose owner has just been shown a receipt saying
their Strava data was removed. It is the same falsehood, better worded.

The right answer while the database is a **shadow copy** is `.removeEverything`:

1. **Harmless.** Nothing reads it. The migrator rebuilds an empty schema on the
   next launch in milliseconds.
2. **Honest.** Every row in there today is Strava-derived, weather, or
   authored-about-Strava, and after a disconnect all of it should go.
3. **It sweeps the snapshots.** `.snapshotDirectory("snapshots")` sits in this
   same entry and holds *"copies of everything above"* — legacy inputs captured
   before decode. It is currently kept on disconnect. Second retention hole,
   same entry, fixed in the same stroke.

`.removeEverything` becomes **wrong** the day a `.keep` category's data lives
only in the database — a session note, a correction, a review verdict, all of
which the inventory promises survive a disconnect. That day is D7.

### 2.2 The trigger that forces 282

`Sub4Launch.migrationFailureBlocksTheApp` is already the project's declared D7
marker: *"IT MUST BECOME `true` IN 3.3.3, the moment the first store reads its
data from the database instead of from JSON."* It is a stored constant
specifically so flipping it is a deliberate act.

```
if Sub4Launch.migrationFailureBlocksTheApp {
    // A reader exists. The database now holds the only copy of data other
    // categories promise to keep, so a whole-directory delete breaks those
    // promises. 282 must have landed.
    #expect(rule != .removeEverything)
} else {
    #expect(rule == .removeEverything)
}
```

Whoever flips that flag at D7 gets a red build naming this file. The act that
makes 282 necessary is the act that fails the suite.

### 2.3 Lineage is asserted, not typed

`lineage` becomes the union of every category contributing rows. Hand-writing
that set is how it drifts. Declare it explicitly — an entry cannot read the
array it lives in — and add a test asserting it **equals** the union of the
contributing categories' lineages, with the contributing list declared once.

Expected union at patch 280: `.strava`, `.weatherProvider`, `.authored`,
`.appleHealth`, `.bundled`, `.device` — every source the app has. Not a bug in
the reasoning; it is what "one database holds everything" means, and six
sources on the privacy pane is the correct disclosure.

### 2.4 Prose to rewrite

| Field | Now | 281 |
|---|---|---|
| `whatItIs` | "holds no training data at all — only an empty schema" | what it actually holds, plus that the app does not yet read from it |
| `lineage` | `[.device]` | the asserted union |
| `onStravaDisconnect` | `.keep(why: "it is empty…")` | `.removeEverything` |
| gap 1 | "Holds no training data yet…" | replaced: shadow copy today; at D7 the disconnect must delete Strava-derived ROWS and remap authored ones (ADR-0003 §8, plan step 3.7) |
| gap 2 (export) | "Not included in an export…" | sharpened: it is now the only complete copy and the export omits it (ADR-0003 §9.4) |
| gap 3 (backup) | unchanged | unchanged |

Every gap must contain `step ` or `ADR-` or `DataLifecycleTests.gapsAreActionable`
fails — the test that caught 272a.

### 2.5 Deliverables

- `Sub4/DataLifecycle.swift` — the entry, edited by anchors
- `Sub4CoreTests/DataLifecycleTests.swift` — the D7 coupling test, the
  lineage-union test
- `docs/ADR-0003-database-contract.md` — §12.27
- `Sub4/AppVersion.swift` — bumped to 281

No new Swift file, so no ⌘Q. Anchor risk low: one entry, distinctive strings.

### 2.6 Verification on the device

1. Settings → Data & privacy → **The database** lists six sources and reads
   *"Removed when you disconnect Strava"*.
2. Settings → Disconnect Strava → the database moves from the kept column to
   the removed column in the preview.
3. **Do not tap it.** The preview is the check.
4. Suite green.

---

## 3. M0 — measure Apple Health's historical coverage. Next, and out of band.

ADR-0002 follow-up 3: *"Measure Apple Health coverage back to 1 July 2025
**before** any purge."* Its consequence section says why: *"the watch may not
have been worn, or workouts may have been written by Strava rather than to
it,"* in which case part of the record cannot cross by the API-free route and
the bulk-export bridge becomes the contingency.

**The peer review buries this.** Its Health exit gate is forward-only — *"new
real workouts appear in SQLite"* — and it never asks whether Health holds the
past. That is the wrong way round: the question is read-only, answerable this
week, and a negative answer changes whether the Strava data now sitting in the
database is redundant or irreplaceable.

### What to measure

Per month from July 2025 to today, for workouts only:

- count by activity type (run / ride / swim / strength / other)
- earliest and latest workout date present
- how many carry an `HKWorkoutRoute`
- how many carry heart-rate samples, and at what density
- the `sourceRevision` / source bundle id per workout — **specifically whether
  the writer was Strava's own app**, which is the failure mode ADR-0002 names
- count of workouts Health has that `activity` does not, and the reverse

### The comparison that decides it

668 activities in the database against the Health count for the same window. A
shortfall is not automatically fatal — it may be trainer sessions or a
head-unit that never wrote to Health — but every missing workout is a row the
disconnect would destroy with no replacement.

### Why it is out of band

It writes nothing, changes no schema, and does not touch the ladder. It is a
diagnostic. If it comes back healthy, the plan below is the plan. If it comes
back thin, priority order changes — the bulk-export bridge moves onto the
critical path and `activities.json` stops being disposable.

---

## 4. The revised ladder

### D5 — remaining slices (unchanged, with one correction)

- `lifecycle_event` + `lifecycle_line` — **export and disconnect only.** See
  §7, rejected item 1. Do not implement the review's four-operation version.
- `review_evidence_source` — needs the review writer to record lineage; blocked
  until a review exists (24 August).
- `content_revision` — held. See §7, held item 1.
- Four preference keys stay: `appearance.selected`, `discipline.selected`,
  `volume.unit`, `zones.window`. D5 is "get the DATA out of UserDefaults", not
  "empty UserDefaults".

### D6a — repositories

A read layer that does not exist. `Sub4Import` writes; `SemanticVerifier` reads
to check; no production code reads the database at all.

Adopted from the review, each repository must:

- read from SQLite and return domain models, not rows
- write related records in one transaction
- use canonical UUIDs internally
- resolve provider identifiers through **`activity_source_record`** and
  `activity_alias` — note the table name; the review calls it `source_record`
  and there is no such table
- scope by account
- have in-memory database tests
- **report database errors rather than returning an apparently valid empty
  collection**

That last one is `StoreLoad.isTrustworthy` from patch 273 in SQL clothes — the
same failure mode, the same answer. Whatever type carries it should say so, so
the two stay coupled in a reader's head.

Start with `ActivityRepository`. It is the one every other feature waits on and
the one shadow parity needs first.

### D6b — write-through

**The rung that was missing.** Every mutation updates SQLite as it happens, so
the database is current without pressing Import.

Order per mutation:

1. validate input
2. commit the SQLite transaction
3. update the legacy JSON mirror
4. **treat a mirror failure as a visible save failure**

Step 4 is a correction to the review, and it matters. The review says *"record
a mirror failure without rolling back committed canonical data."* During
write-through **JSON is still what the app reads** — so a mirror failure means
the edit is committed to a database nobody reads and missing from the file
everybody reads, and the note vanishes off the screen. That is patch 264's
failure with a database underneath it. The rule flips only at D7, when JSON
stops being read; until then a mirror failure belongs in
`StoreWriteJournal.hasUnsaved` and therefore on the Settings badge via
`AppHealth` (279).

**Exit gate, taken verbatim from the review because it is the best sentence in
it:** after normal app use, another legacy import produces no new database
changes.

### D6c — shadow parity

Read both, compare in diagnostics, zero unexplained divergence. Now meaningful,
because D6b keeps the database current.

Compare semantics, not counts — *"equal counts can hide changed values or
swapped identities"*, which is the ghost-review lesson from patch 274 restated.
Activity identity and ordering, day grouping and time zones, details/laps/
splits/traces, notes and corrections, plan matching, daily and weekly distance,
**CTL and the PMC** (ADR-0003 §12.16 deferred it here on purpose — one `PMC`
over two readers, not two builders), zone calculations, weather and gear,
review payloads, and the Today/Week/Plan/Progress summaries.

Each diagnostic shows: records compared, exact mismatches, expected
differences, unexplained differences, last successful comparison, and the two
revisions compared.

### D7 — activate, and 282 lands with it

Slice order: plan and athlete profile → notes and authored decisions → activity
summaries → details and recordings → weather and gear → derived metrics →
reviews and proposals → sync and retry state.

Required at this step:

- `Sub4Launch.migrationFailureBlocksTheApp` → `true`, and `RootView` holds at
  the failure screen
- the latest migration ledger entry must be `verified`, then marked `activated`
- production reads stop touching JSON; the files go read-only
- **282, because 281's test goes red the moment the flag flips**

Exit gate: the app launches and every feature works with the legacy JSON
temporarily moved out of the runtime location.

### D8 — retire

One stable release window, then remove the JSON readers and writers, the
obsolete preference keys, and — after 4A — the Strava networking, OAuth UI and
background tasks. Legacy files go through a versioned cleanup migration. The
protected snapshot survives to the approved retention point.

---

## 5. Patch 282 — the disconnect deletes rows

Lands at D7. Not built before, because it is a row-level delete against a
database no reader depends on, and designing it today means writing against
behaviour D6 and D7 will change — the second-inventory-for-next-month failure
that `DataLifecycle.swift`'s header exists to prevent.

### 5.1 The rule needs a case it does not have

`DisconnectRule` has `removeEverything`, `keep`, and `partial(keeps:
removesFiles: removesKeychain: clearsFields:)`. None can say "delete these rows
from that table". `clearsFields` is the precedent to copy — a hand-written
handler for something no generic walker can do — including its test,
`everyClearedFieldHasAHandler`, which must gain a table-level twin.

### 5.2 The receipt has no vocabulary for rows

`ReceiptLine.Outcome` is `.removed(bytes: Int64) | .absent | .failed(String) |
.notOurs(String)`. Rows are not bytes, and `bytes: 0` would report a delete of
192,954 samples as nothing to the one reader who is checking that their data
went. A `.removedRows(Int)` case, touching `DataControlsView`'s rendering.

### 5.3 Three classes of table, and the middle one is the work

- **Strava-derived — delete.** `activity`, `activity_alias`,
  `activity_source_record`, `activity_detail`, `activity_split`, `recording`,
  `recording_sample`, `weather`, `gear`, `athlete_profile`, `hr_zone`,
  `sync_state`, `work_queue`, `rejection`.
- **Authored about Strava — remap, never drop.** `user_note`, `correction`,
  `match_decision`, `review`, `review_evidence`. The inventory already promises
  these survive (*"you wrote it"*; *"you made these corrections… remapped
  rather than dropped — step 4A M4"*). They carry activity foreign keys about
  to point at nothing.
- **Neither — keep.** `migration_run`, plan tables, `resting_month`.

**The remap is the design problem, and the peer review moved it forward.** Its
Health/Strava identity section is the missing half: when a Health workout and a
historical Strava activity are the same session, match them, add a Health
source record to the existing canonical activity, preserve the Strava
provenance, apply field-level source preference, do not duplicate because
external ids differ, and send ambiguous matches to review. Matching signals:
account, sport, UTC start, local day, duration, distance, route similarity,
device and source metadata.

That is what makes the remap possible at all — the authored rows keep pointing
at the same canonical activity, which acquires a Health source record and loses
its Strava one. 282 either does this or refuses the disconnect until 4A M4 has.

**This threatens work shipped at patch 280.** The 4 `correction` rows from
`commutes.json`, and the 6 `user_note` rows, are precisely this class. So are
the things the review says Health cannot reproduce: titles, shoes and bikes,
commute and trainer flags, head-unit recordings, achievements. *Do not
manufacture replacement values* — preserve the permitted historical metadata or
accept the loss explicitly.

### 5.4 It must fail closed

`Sub4Launch.database` is `Sub4Database?`. If the migration failed it is `nil`. A
disconnect that finds no database and carries on deletes the JSON and leaves
every row in place — today's bug, reintroduced by accident. So: a **preflight**
that refuses the disconnect in full, before deleting anything, if the database
is unavailable. Same argument as `StoreReadJournal.canReconcile` failing closed
on a store that never reported: *do not delete on the strength of an incomplete
reading*.

### 5.5 Ordering inside the operation

Rows first, files second. A row delete that fails partway leaves the JSON
stores intact and the app working. The reverse leaves a working database nobody
reads and a blank app.

---

## 6. Phase 4A — Health becomes the source

ADR-0002 already decided this; the review re-derives it without citing it. Its
detail is worth keeping where ours is thin.

### Ingestion (adopted)

Anchored `HKAnchoredObjectQuery`. Persist the anchor **only after its batch
commits**, and never advance it after partial failure. Handle new, updated and
deleted workouts. Ingest routes, heart rate, distance, speed, cycling metrics,
power, calories and workout events where available. Record source revision and
device metadata. Store the HealthKit UUID as a **source identifier, never as
the canonical activity id** — the same rule `activity_source_record` already
enforces for Strava. Keep measured values separate from derived. Distinguish
denied authorisation, unavailable type, timeout, query failure and a genuinely
empty result — five outcomes, not a `Bool`, which is `StoreLoad` again.

### The shadow period (adopted)

Both sources ingested for comparison, subject to the ADR-0002 policy gates. The
observation window must include a run, a ride, a swim, a strength session, a
paused workout, a workout recorded by another app or device, and a delayed or
edited workout.

### The rehearsal (adopted)

Protected backup verified first; sync gates disabled; network removed from the
test build where practical; credentials **kept** so rollback stays possible;
run for the stabilisation window; exercise every feature; export and verify.

### The disconnect itself (adopted, with 282 underneath it)

Record the lifecycle event; stop foreground and background sync; cancel pending
work; **revoke the OAuth token remotely before deleting it locally** (ADR-0002
follow-up 5); delete tokens and `strava.credentials` from Keychain with a
checked status — the credentials have no deletion path today and one must be
written; delete what cannot remain; show the receipt; verify Health ingestion
immediately afterwards.

---

## 7. Peer review disposition

Recorded rather than merged silently, so a later reader can see what was
decided and why.

### Adopted

| # | Item | Note |
|---|---|---|
| 1 | Write-through as its own step, before parity | the genuine hole in our ladder — D6b |
| 2 | Repositories as a named layer | D6a; table name corrected |
| 3 | "Report errors, not an empty collection" | our own patch-273 lesson; couple them explicitly |
| 4 | Write-through exit gate | *"another legacy import produces no new database changes"* |
| 5 | Health↔Strava identity and dedup | the missing half of 282's remap |
| 6 | Non-Health gaps list | titles, gear, commute/trainer flags, head-unit, achievements |
| 7 | Anchored ingestion discipline | anchor after commit; never after partial failure |
| 8 | The shadow-period case list | seven workout shapes |
| 9 | The 13 release gates | §8 |
| 10 | Separating activation from retirement as two reversible decisions | matches D7 vs 4A |

### Rejected

**1. `lifecycle_event` for "export, deletion, Strava disconnect, and recovery".**
ADR-0003 §8.1 constrains `lifecycle_event.operation` to `export` and
`disconnect`, **and a test asserts that `delete` is refused.** Patch 186 decided
it deliberately: *"a record of the deletion surviving the deletion is a record
nobody asked to keep."* "Recovery" is not in the vocabulary at all. Vocabularies
are frozen literals coupled to Swift enums by test, so building this bullet as
written means a CHECK failure at runtime or editing a migration that has already
run on the phone. **The most dangerous line in the review, because it reads like
a harmless requirements bullet.**

**2. The Phase 3 mirror-failure rule.** *"Record a mirror failure without rolling
back committed canonical data"* is correct after activation and wrong during
write-through, when JSON is still what the app reads. See D6b step 4. The review
states one rule across a boundary where the correct rule flips.

**3. `source_record` as a table name.** It is `activity_source_record`, named
wrong twice. Trivial in itself, useful as calibration: the review was written
from the plan prose rather than the schema, so its confidence about specifics
should be discounted accordingly.

### Held

**1. `content_revision` "beginning with the plan content hash".** This is the
recommendation made and then withdrawn earlier today: the migration's own
comment says the table exists to skip unchanged content on re-import, and that
job is already done three ways. Two independent readers reaching the same wrong
answer is itself the finding — the table's *name* invites it. Settle before
building; do not build on the review's say-so.

### Absent from the review

**1. The live defect.** No item covers a disconnect button that is destructive
and retaining at the same time. Its Phase 9 assumes the code gets written
correctly when the time comes. 281 is not in that document.

**2. Measuring Health's historical coverage before anything.** ADR-0002 has it
as 4A M0 with a stated contingency; the review's Health gates are forward-only.
See §3.

**3. Any date at all.** See §9.

---

## 8. The disconnect gate

Strava may be disconnected only when every answer is yes. Adopted from the
review; 14 and 15 added.

- [ ] Is SQLite continuously current without a manual import?
- [ ] Are all production reads served from SQLite?
- [ ] Does database failure block misleading empty-state operation?
- [ ] Is the latest migration verified and activated?
- [ ] Are there zero unexplained shadow-read differences?
- [ ] Does HealthKit durably ingest new, updated and deleted workouts?
- [ ] Do background Health updates work?
- [ ] Can duplicate Health and Strava records be canonicalised?
- [ ] Do all main UI surfaces work without network access?
- [ ] Are calculations and reviews rebuilt from allowed sources?
- [ ] Have protected backup and export both been verified?
- [ ] Has the disconnect rehearsal completed successfully?
- [ ] Can every record retained or deleted at disconnect be explained?
- [ ] **Does the inventory describe what the database actually holds?** (281)
- [ ] **Was Health's historical coverage measured, and the shortfall — if any —
      accepted in writing rather than discovered at the receipt?** (M0)

---

## 9. The calendar constraint neither plan stated

Race: **21 March 2027.** Currently inside a 34-week block. Phase 4A alone is
larger than D0–D8 combined.

Activating database reads or disconnecting Strava mid-block risks the record of
the block while it is being recorded. The peer review contains no dates and no
capacity model; it reads as though ten phases are a quarter's work for a team.

**Position:** 281 and M0 now. D5–D7 and 282 through autumn, at the current
patch cadence. **The disconnect itself lands either well clear of the key
phase or after the race** — not because the engineering forbids it, but because
the one irreplaceable thing in this project is the training record, and the
disconnect is the only operation that can destroy it.

---

## 10. Still open, unchanged

- **The match picker** (option 1, ±5 days, discipline-filtered). Blocked on one
  question: does the ±5-day window apply to the automatic matcher as well, or
  only to what the picker offers? Also needs cross-day override handling and a
  double-claim pre-pass.
- **24 August 2026** — first real monthly review; refuses to send until 4A.
- **1 September 2026** — GitHub Actions allowance resets; CI unverified since
  the triggers changed.
- **A fresh protected snapshot** — the one on the phone predates
  `commutes.json`, the bikes, the retired shoe, `match.decisions` and
  `strava.rejections`.
