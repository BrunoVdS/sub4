# D7 activation groundwork — Stage A3

| | |
|---|---|
| **Written against** | patch 341a, commit `150bb67`, 10 August 2026 |
| **Authority for this stage** | `PLAN-codebase-modernization-and-feature-delivery.md` §4 A3 and §5 |
| **Persistence authority** | `docs/ADR-0003-database-contract.md` |
| **Status** | Groundwork. No code. Two decisions are Bruno's and are marked. |

Every fact below was read out of the source at that commit. Where I have not
read something I say so rather than inferring it.

---

## 0. What is already true

The entry gate passed on 10 August with evidence in files:

- roll-up **9 of 9 agree · 0 differ · 0 could not look · 0 nothing to compare**
- Compare **680 activities · 326 days · no differences** across six slices
- Verify **20 comparisons, all agreed**, `Ledger: the run is marked verified`
- `runs ever verified: 2`, snapshot `1344 of 1344` re-hashed off-device
- suite **1245 in 107**

None of that says the app would behave identically if a store were *fed from*
the database. That is the whole of what D7 has to establish, and §12.75.8 is
worth restating before any of it: D6c proves the data can be reconstituted. It
does not prove the app is right — §12.72 found seven copies of one rule
disagreeing for 230 patches and no slice could have caught it, because every
slice compares the app against the database and that was the app disagreeing
with itself.

---

## 1. The call-site ledger

Eleven readers, nine repositories. This is the inventory A3 item 1 asks for.

| data family | current reader | how it reads | repository replacement | slice |
|---|---|---|---|---|
| activities | `ActivityStore.load()` | `activities.json` | `ActivityRepository` | **B3** |
| sync cursor, last sync, cutoff | `ActivityStore` | `UserDefaults` ×7 keys | `sync_state` | **B8** |
| rejection receipts | `ActivityStore.receipts` | `UserDefaults` data blob | `RejectionRepository` — **does not exist** | **B8** |
| details | `DetailStore.load()` | `details/` directory | `ActivityDetailRepository` | **B4** |
| traces | `DetailStore.load()` | `streams/` directory | `RecordingRepository` | **B4** |
| retired monoliths | `DetailStore` | `details.json`, `streams.json` | upgrade path only | D8 |
| work queue / skip lists | `DetailStore.workItems` | `UserDefaults` | `work_queue` | **B8** |
| gear, zones, FTP | `AthleteStore.load()` | `athlete.json` | `AthleteRepository` | **B1** |
| constants | `ConstantsStore` | `constants.json` | `AthleteRepository` | **B1** |
| weather | `WeatherStore` | `weather.json` | `WeatherGearRepository` | **B5** |
| notes | `NotesStore.load()` | `StoreRead.decode`, `notes.json` | `AuthoredRepository` | **B2** |
| commute decisions | `CommuteStore.load()` | `StoreRead.decode`, `commutes.json` | `AuthoredRepository` | **B2** |
| reviews and proposals | `ProposalStore.load()` | `StoreRead.decode`, `proposals.json` | `ReviewRepository` | **B7** |
| match decisions | `Matcher.load()` | `UserDefaults` | `match_decision` — **no reader** | **B2** |
| the plan | `PlanStore.init` | `Bundle.main/plan.json` | `PlanRepository` + `PlanExtrasRepository` | **B1** |

### 1.1 Four things this table makes visible

**`PlanStore` is not a store, it is a seed.** It reads the bundled resource, not
Application Support. B1 does not repoint a file read at a repository; it stops
parsing a bundled resource at runtime and starts reading rows the importer
seeded. The bundled plan stays as a seed and upgrade resource and must not
become a production read fallback — the plan says this and it matters, because
a fallback here would silently serve a *different plan version* from the one
notes and matches were written against.

**Two families have a table and no reader.** `match_decision` holds 0 rows
today and `MatchParity` deliberately takes the decisions from `Matcher` on both
sides — §12.61.1's argument. `rejection` has 3 rows and no repository at all.
Both need a reader written before their slice, and neither has one now. That is
new work D6c never touched, because D6c compared what existed.

**`UserDefaults` is a third store nobody has counted.** Seven keys in
`ActivityStore` alone, plus the work queue, plus the match decisions, plus four
one-shot backfill markers. The backfill markers are migration state, not data —
they must NOT move to the database, and the ledger should say so explicitly so
a later sweep does not helpfully migrate them.

**`DetailStore` reads two retired monoliths** that cannot exist on this install
(`details.json`, `streams.json` — the permanent floor of the snapshot's
`not present` row). Those reads are upgrade-path code and belong in D8's
quarantine, not in B4.

---

## 2. The launch-state diagram

A3 item 2. Eight states; today only three are reachable, and that is the point.

```text
launch
  ├─ no database file            → migrate from scratch, seed the plan
  ├─ opened, migrations current  → normal
  ├─ opened, migrations pending  → migrate, then normal
  ├─ open FAILED                 → today: carry on, JSON serves everything
  │                                after D7: HOLD on recovery, never construct
  │                                empty stores
  ├─ integrity check failed      → same as open failed
  ├─ migration threw             → `migrationFailureBlocksTheApp`
  ├─ interrupted run found       → close as `interrupted`, continue (338)
  └─ activated build, older app  → the rollback question, §6 below
```

### 2.1 The flag, and a contradiction to settle

`Sub4Launch.migrationFailureBlocksTheApp` is `false`, and its own header says:

> *"IT MUST BECOME `true` IN 3.3.3, the moment the first store reads its data
> from the database instead of from JSON: from then on, carrying on after a
> failed migration means showing the athlete an empty training history, and an
> empty history that looks like real data is the worst failure this app has
> available."*

The master plan puts the flip in **B9, after all eight slices**. The source
comment says **at the first slice**. Both cannot be right.

They reconcile only if every slice keeps its legacy read path *selectable* for
the whole of D7 — which is exactly what the plan's per-slice pattern says
("keep the legacy writer/read path available solely for the defined rollback
window"). Under that reading B9 is correct and the comment is describing a
simpler design that was not adopted.

**But the fallback must then be explicit, and today it would not be.** If B1
lands and the database fails to open, something has to decide to read
`athlete.json` instead — and if that decision is "the repository returned
nothing", the app serves an empty profile as though it were real. That is the
§12.15 failure with the highest possible stakes, and it is what
`AthleteLoad.failed` versus `.loaded(empty)` exists to prevent.

### 2.2 DECISION 1 — SETTLED 10 August 2026

**Every slice keeps a selectable legacy path through D7. The flag flips at B9.
The choice is made by an explicit `PersistenceMode`, read once at launch and
derived from the migration ledger — never by a repository returning empty.**

The plan's ordering, with the amendment. What this buys: each slice is
reversible on its own, and a database problem in the middle of D7 leaves a
working app on the phone Bruno trains with.

What it costs, stated plainly because it is the whole risk of this stage: the
mode has to be right. The moment anything derives "read from JSON" from *the
database gave me nothing*, the app serves an empty profile as real data — and
an empty history that looks like real data is, in `Sub4Launch`'s own words, the
worst failure this app has available.

**`Sub4Launch`'s header is therefore now wrong** and says so in a comment that
has been correct since it was written. It describes flipping at the first
slice, which is not the design being built. B1 must correct that comment in the
same patch that first reads a store from the database, or the next person to
read it will believe the flag is late.

**The negative control this decision requires**, and it is not optional: a test
that forces a failed open under `databaseAuthoritative` and asserts the app
does NOT reach normal content. §12.69 — a guard that cannot fail has not been
tested, and this is the guard the whole stage rests on.

---

## 3. One production persistence mode

A3 items 4 and 5. Today the answer to *where does this store read from* is
implicit: it reads JSON because that is the only code there is. After B1 it
becomes a question with two answers, and the plan is explicit that it must be
derived **from the ledger, not from whether a database happens to open**.

Shape:

```text
PersistenceMode
  ├─ legacyAuthoritative    no activated run in the ledger
  ├─ shadow(slice)          the slice under test reads both, compares, serves legacy
  └─ databaseAuthoritative  an activated run exists and the database opened
```

**Settled at decision 1.** `shadow(slice)` is the state the app lives in for the
whole of D7: the slice under test hydrates from the repository, the comparison
runs, and production is served from whichever side the mode names. `B9` is the
single transition to `databaseAuthoritative`, and it is the only one.

Read once, at launch, into a value every store is handed. Three properties it
must have and today's code has none of them:

1. **Nothing may compute it twice.** A store deciding for itself is nine
   decisions that can disagree — §12.43, eleven applications.
2. **A failed open cannot silently produce `legacyAuthoritative`.** After
   activation that is the recovery screen, not a fallback.
3. **It is not a `UserDefaults` flag.** The plan says one activation authority:
   the newest verified `migration_run` becomes `activated` inside a checked
   transaction, and no preference may independently claim activation.
   `MigrationLedger.activateVerified` already exists, already refuses any source
   state but `verified`, and already requires the row to be `MAX(sequence)`.
   **It has never been called.**

---

## 4. `DatabaseBootstrapSnapshot`

A3 item 3. `AppStores` is the existing precedent and the argument is the same
one §12.45 made: `Sub4Import.run` took twenty parameters, eighteen defaulted,
and a forgotten one was not a compile error but a table that quietly stopped
being imported.

The read direction needs the mirror of that: one `Sendable` value holding every
family the app hydrates from, assembled in one place, with `fieldCount` pinned
by a test exactly as `AppStores.fieldCount == 17` is today.

Without it, D7 is nine hand-written load lists in nine stores, and the failure
mode is a store that hydrates from nothing and shows an empty screen.

---

## 5. The fail-closed recovery screen

A3 item 5 in the plan's numbering. After activation, a failed open must reach a
screen that:

- says what failed, in the athlete's terms;
- offers retry, diagnostics, and the protected-snapshot restore;
- explains the off-device export;
- **may not construct apparently valid empty stores.**

`RootView` holds the launch gate today. What it does on failure needs reading
before B9 is written — I have not read it this session and will not assert what
it does.

---

## 6. Rollback, and the date it stops being lossless

A3 item 6. The contract has three states and the plan asks which one applies:

- **Before activation** — rollback to the last committed legacy-authoritative
  build is lossless. That is `150bb67` today.
- **After activation, before any database-only mutation** — still lossless,
  because the JSON mirror is current.
- **After the first database-only mutation** — not lossless. The plan requires
  a written answer: read-only, export-assisted, or unsupported.

**Decision 2, and it is yours**, though it can wait until B9: which of those
three. The honest default is *export-assisted* — the athlete exports the
authored data (which patch 341 made a button) and reinstalls the older build.

The protected pre-activation snapshot and the accepted commit are retained
until D8's compatibility window closes. Both exist: `2026-08-10-084723` and
`150bb67`.

---

## 7. The slice order

The plan's B1–B9, with what this reading adds.

| slice | family | new work D6c did not cover |
|---|---|---|
| **B1** | plan, athlete, constants | `PlanStore` stops parsing the bundled resource; the seed must not become a fallback |
| **B2** | notes, commutes, match decisions | **`match_decision` had a table and no reader — written at 355** |
| **B3** | activities | `ActivityRoster` stays the one filter/dedup rule — do not copy it |
| **B4** | details, traces | the 1.5-million-sample read stays off the main actor |
| **B5** | weather, gear | gear distance is a Strava refresh, not a store write — §12.68.4 |
| **B6** | derived metrics | one input snapshot; no calculation queries SQLite |
| **B7** | reviews | **delete the six rehearsal records first** — see §8 |
| **B8** | sync cursor, work queue, rejections, revisions | seven `UserDefaults` keys; the four backfill markers stay. **`rejection` still has no reader** — moved here from B2 at patch 355, see below |

**Amended 13 August 2026, patch 355.** §7's row for B2 said "notes, commutes,
match decisions, rejections" while §1's call-site ledger put rejection receipts
in B8. §1 is the more considered entry: it names the actual reader
(`ActivityStore.receipts`), the actual storage (a `UserDefaults` data blob) and
the fact that `RejectionRepository` does not exist. Rejection receipts are the
same family as the sync cursor and the work queue, which are already B8, and
they are read by `ActivityStore` rather than by anything authored. The table
still has no reader; it is B8's to write.
| **B9** | activate and fail closed | `activateVerified` called for the first time |

**B1 first because it is the smallest true test.** It has a working repository,
a passing read-back of 298 + 71 comparisons, and no source coupling — nothing
about the plan comes from Strava. If the bootstrap shape is wrong, B1 is where
that is cheapest to find out.

---

## 8. Two things with dates on them

**The six rehearsal records must go before 24 August.** `proposals.json` holds
six `model: "rehearsal"` records, and each says so itself: *"Delete this record
before the first real review runs — a ReviewDue calculation that counted it
would push the real one out by 28 days."* Fourteen days. It is B7's
prerequisite and it is also true whether or not D7 happens.

**GitHub Actions resets 2026-09-01.** Until then local verification is the only
check.

---

## 9. What I have not read, and will before writing B1

Named so the next session does not treat this document as complete:

- `RootView`'s failure branch, for §5.
- `Sub4Launch.opened` in full — the state machine around `.opened(let db)`.
- `ActivityRoster.settle` call sites outside the parity types.
- Whether any view reads a store's `lastLoad` to decide what to draw. If one
  does, it is a fourth persistence-mode reader nobody has counted.

---

## 10. The exit gate for A3

> No production read or launch failure can switch ownership accidentally or
> fall back to a misleading empty state.

**Decision 1 is made (§2.2), so the rule now exists.** The gate is met when
three things are true, and none of them is true today:

1. `PersistenceMode` exists, is derived from the ledger, and is read in exactly
   one place — asserted by a test that fails if a second reader appears.
2. A failed open under `databaseAuthoritative` cannot reach normal content —
   asserted by the negative control named in §2.2.
3. No repository's empty result can select the legacy path. The way to test
   this is to make a repository return `.loaded(empty)` and assert the app
   shows an empty screen rather than silently reading JSON, because after
   activation an empty database IS the answer and must be shown as one.

Everything else in this document is inventory, and the inventory is complete
for the eleven readers and nine repositories named in §1.

**B1 may not begin until those three exist.** They are `B0` in the plan's
numbering, and B0 is now the next patch.
