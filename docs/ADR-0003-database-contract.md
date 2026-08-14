# ADR-0003 — The source-neutral database contract

**Status:** ACCEPTED — all six questions answered 3 August 2026, folded into §9
**Date:** 3 August 2026
**Plan step:** 3.1
**Findings addressed:** DB-01 … DB-05, DATA-04, MIG-02, ARCH-01
**Supersedes nothing. Constrains:** every table written in 3.2 and every import in 3.3–3.5

---

## 1. Why this document exists before any code

Phase 3 replaces the persistence layer under an app that already holds thirteen
months of training. The conventions below are the ones that cannot be changed
cheaply afterwards: an identity decision is discovered to be wrong at step 3.7,
when six repositories, a migration engine and every calculation are built on it.

So this is decided first, in prose, and approved before a table exists.

Nothing here is a preference. Each convention is chosen because the alternative
has a named failure mode, and the failure mode is written down.

---

## 2. The engine

**SQLite via GRDB, pinned to an exact version.**

Not Core Data, not SwiftData, not a hand-rolled file format.

- SwiftData is the obvious modern answer and is rejected for one reason: the
  migration this app needs is not schema-to-schema, it is *file-format to
  relational*, with quarantine, resumability and byte-level verification. That
  is ordinary SQL work and awkward inside a framework that wants to own the
  model layer. SwiftData's migration story is also younger than the data it
  would be migrating.
- Core Data would work and brings an object graph nobody asked for.
- GRDB gives migrations as ordered, named, testable functions; `DatabaseQueue`
  with real serial access; and — decisively — an online backup facility, which
  §3.8 requires and which copying a file cannot provide.

**`DatabaseQueue`, not `DatabasePool`, for v1.**

A pool needs WAL and concurrent readers, and its benefit is a read path that
does not block writes. This app has one writer and a handful of readers on the
main actor. Before any pool adoption, the SQLite build shipped on the minimum
supported OS must be verified to support the WAL behaviour relied upon —
recorded here as a prerequisite so the decision is not made by accident later.

**Pinned exactly**, not `.upToNextMajor`. A persistence library that moves
underneath a migration engine is the one dependency where a silent minor bump is
unacceptable. CI proves the pin builds from clean.

**The pin, recorded 3 August 2026:**

| | |
|---|---|
| Package | `https://github.com/groue/GRDB.swift` |
| Rule | Exact Version |
| Version | **7.11.1** |
| Revision | `b83108d10f42680d78f23fe4d4d80fc88dab3212` |
| Linked product | `GRDB` (static), on the `Sub4` target only |

`GRDB-dynamic` is deliberately not linked. It is the same library built as a
dynamic framework; taking both would put two copies of SQLite's symbols in one
binary.

`Sub4CoreTests` does not link GRDB either — it reaches it through
`@testable import Sub4`. A test target with its own copy of a database library
is a way to test a different database from the one that ships.

Recorded because the resolved version is not obvious from anywhere a reader
would look: GRDB's GitHub releases page fetched as 7.10.0 dated February 2025
while Xcode's own package metadata offered 7.11.1, and Xcode's "Exact Version"
field pre-fills `1.0.0` — a 2017 tag whose manifest declares
`swift-tools-version: 3.1.0` and which Swift 6.3 refuses to read. Accepting the
pre-filled value fails resolution with an error that names the tools version and
not the cause.

---

## 3. Identity — the decision this ADR exists for

### 3.1 Strava IDs are never primary keys

Today `Activity.id` **is** the Strava activity id, and it is used as the dedup
key, the filename for details and streams, the key for weather rows, the key
for match overrides, and the key in `strava.rejectedByRule`.

That is DATA-04 and it is the single most expensive thing in the codebase to
undo, for three reasons:

1. **Strava is being retired** (ADR-0002). At Phase 4A the same run arrives from
   Apple Health with a different identifier and no relationship to the old one.
   Every note, correction and weather row keyed by a Strava id becomes an orphan.
2. **The same activity can arrive from two sources.** A run recorded on the
   watch appears in Health and in Strava. With an external id as identity they
   are two activities.
3. **An external id is not stable.** A recategorised or re-uploaded activity can
   change id at the source.

**Therefore:**

- Every activity has a **canonical id** minted by this app: a UUID, stored as
  text, generated at first import and never reused, never derived from anything
  external.
- Every arrival from a source is a **source record** — `(account, source,
  externalID)` — which references the canonical activity it was matched to.
- `(account, source, externalID)` carries the UNIQUE constraint. That is the
  idempotency key for ingestion (§3.6 of the plan) and the only place an external
  identifier appears.
- An **alias table** maps every historical external id to its canonical
  activity, so a note written against Strava id `19580875358` still resolves
  after Strava is gone.

The alias table is not optional and is not a convenience. It is the mechanism by
which thirteen months of notes, corrections and rejections survive Phase 4A.

### 3.2 Everything else the user authored gets a canonical id too

Notes, proposals, corrections and match decisions are keyed today by session uid
or by Strava id. They get their own UUIDs and reference canonical ids. The plan's
session `uid` remains as **provenance**, not as identity — see §5.

---

## 4. Dates and times

### 4.1 Four representations, not three

Three exist today. A fourth is added here, and the reason is a trip to Japan in
September 2026.

| Stored as | Meaning | Used for |
|---|---|---|
| `startUTC` — ISO 8601 with offset | the instant | ordering, cursors, overlap windows, anything compared across zones |
| `startLocal` — wall clock, no zone | what the clock said where the athlete was | display, and the day a session belongs to |
| `dayKey` — `yyyy-MM-dd` | the training day | grouping, plan matching, the load series |
| **`startOffsetSeconds` — Int, and `timeZoneIdentifier` — TEXT** | **which clock `startLocal` was read from** | **labelling a session that happened in another zone; detecting travel** |

**The rule: `startUTC` is authoritative for ordering; `dayKey` is authoritative
for belonging.** A run at 23:40 in Antwerp and one at 00:20 the next morning are
different training days even though they are forty minutes apart, and a run
during a trip belongs to the day it felt like, not the day it was in UTC.

Stored as: `startUTC` TEXT ISO 8601 with explicit offset, `dayKey` TEXT. No unix
epochs — a database whose dates cannot be read with `sqlite3` in a terminal is
harder to debug for no gain at this scale.

**Sync cursors are exact source timestamps**, never reconstructed from a local
day or minute (plan 3.6.3). This is already a recorded finding.

### 4.2 Sessions in another time zone: local, always, and say which

The question that produced this section: *runs in Japan in September. Do we show
local time and record where, or convert to Brussels?*

**Local at the place, always. Never converted to home.**

Converting is wrong twice over, and both failures are worse than they sound:

1. **The time becomes a lie about the session.** A 07:00 run in Tokyo converted
   to Brussels reads as 00:00. A morning run is presented as a midnight one, and
   every judgement built on that — was this an easy morning session, was it run
   fasted, does the heart rate make sense for the hour — is being made against
   the wrong fact.
2. **The training day moves.** `dayKey` derives from `startLocal`. Convert to
   Brussels and a Tuesday morning run in Tokyo lands on Monday, so it is matched
   against Monday's prescription, counted in Monday's volume, and Tuesday reads
   as missed. The plan is a schedule of days lived, not of UTC instants.

The existing behaviour is already correct on both counts: `startLocal` is
Strava's `start_date_local`, which is wall-clock at the activity's location, and
`dayKey` is its first ten characters. **Nothing about that changes.**

### 4.3 What is missing, and it is already written in the code

`StravaActivityDTO` carries this comment:

> `start_date_local` is the same instant with the offset already applied and the
> offset then thrown away.

Strava sends `timezone` — `"(GMT+09:00) Asia/Tokyo"` — and `utc_offset` —
`32400` — on every activity. Sub4 decodes neither. So the app knows a run
started at 07:00 and cannot say 07:00 *where*.

The practical consequence: after September, a 07:00 Tokyo run and a 07:00
Antwerp run are indistinguishable on screen. Both read `07:00`. That is
recoverable knowledge in September and lost knowledge by February, which is
exactly when a block gets reviewed.

**The display rule, decided here:**

> Show the local time always. Append the zone abbreviation ONLY when the
> activity's zone differs from the device's current zone.

At home: `07:00`. For the Japan runs: `07:00 JST` — and it keeps saying JST
forever, because the zone is a fact about the run rather than about where the
reader is standing. A zone marker on every row would be noise on the 650
activities that happened at home.

**Storage:** `startOffsetSeconds` as the authority (it is unambiguous and needs
no zone database), `timeZoneIdentifier` alongside it for the abbreviation and
for anything that needs real zone rules later. Both nullable — activities
imported from legacy JSON have neither, and NULL means unknown, per §6.

**The identifier is not always a place — found in the real data, 3 Aug 2026.**

Backfilling 661 activities returned `Africa/Blantyre` for 28 of them and
`Africa/Algiers` for 27. Those are the alphabetically first IANA zones at +2 and
+1, neither observes daylight saving, and all 55 have no coordinate: 43 pool
swims, six gym sessions, five workouts, one indoor ride. Strava substitutes a
representative zone for the offset when it has no position to geolocate.

Six no-GPS activities did come back `Europe/Brussels`, so the substitution is not
purely mechanical and a real identifier cannot be distinguished from a
substituted one at ingest. What can be checked is whether the activity has a
coordinate, and that is the rule: **the identifier is used for the abbreviation
only when the activity has a start position; otherwise the label is derived from
the offset.** Conservative in the right direction — a genuine pool swim in
Brussels loses `CEST` and gains `GMT+2`, which is less pretty and never wrong.

This vindicates making the offset the authority rather than the identifier, a
decision taken in this section before the case was known to exist. The offset
Strava sends is correct in every one of the 55 — it is what the uploading device
reported. Only the name attached to it is invented.

It also vindicates comparing offsets rather than identifiers in the display rule
(§4.3, above): identifier comparison would have labelled 55 sessions in Antwerp
as having taken place in Malawi and Algeria, at home, permanently.

### 4.4 THIS HAS A DEADLINE, and it is before Phase 3 finishes

Phase 3 is eight to twelve sessions. The Japan trip is in September. ADR-0002
retires Strava at Phase 4A.

Data not captured at ingest is data that depends on the source still being there
when you go back for it. Strava holds the zone today; the moment Strava access
ends, every activity that arrived without its zone has lost it permanently —
Apple Health does not carry Strava's `timezone` field.

**Therefore, before the September trip, and independently of Phase 3:**

1. Decode `timezone` and `utc_offset` in `StravaActivityDTO` and store both on
   `Activity` (nullable, added LAST in the memberwise initialiser — see the
   existing note in that file about argument order).
2. Backfill the existing ~660 activities from Strava while that is still
   possible. A one-off pass, gated like every other Strava read.
3. Add the zone suffix to the activity card under the §4.3 rule.
4. Bump the cache schema so rows written before the change are re-fetched rather
   than silently carrying NULL for activities Strava could still answer for.

Phase 3 then imports the field rather than inventing it, and the migration has
real data to carry instead of a column of NULLs.

### 4.5 A separate bug, found while investigating this: Health day bucketing drifts

`HealthStore` buckets steps and resting heart rate with `Calendar.current`, and
`DayKey.formatter` sets **no** `timeZone`, so it uses the device's zone *at the
moment of formatting* rather than the zone the sample was recorded in.

While the phone is in Japan, those days bucket by JST. On landing back in
Belgium, the same historical samples re-bucket by CEST — a nine-hour shift, so
readings move across day boundaries **retroactively**. Values already displayed
change after the fact, with nothing on screen to say why.

**Correction, 3 Aug 2026.** This section originally said the drift "changes
historical TRIMP", full stop. True, and overstated. `restByMonth` is a MONTHLY
average, so a single day crossing a month boundary moves it by roughly a
thirtieth of one reading — real, and nowhere near the impression that sentence
gives. The damage worth naming is the daily figures: steps and walk/run distance
for every day of the trip, which are what the reader actually looks at.

**RESOLVED — patch 198. The decision is: freeze at the zone it happened in.**

A day in Japan stays a Japanese day. 14 September keeps the step count it had
while the athlete was standing in it. The alternative — re-bucket by wherever
the phone is now — needs no extra state and costs history its meaning: every
past figure becomes provisional, and a block reviewed in February reads
different numbers from the ones it was lived with.

**Where the zone comes from, and why there is no new store.** §4.4 put an offset
on all 661 activities and those are persisted. An activity is direct evidence of
where its athlete was that morning, recorded at the time. So a day's clock is
the offset of the nearest activity on or before it, and a rest day inherits from
the last session — you did not fly home to sleep.

The accepted cost, stated rather than discovered later: a travel day with no
recording falls to the previous clock. Land on the 7th, first run on the 8th,
and the 7th reads as a home day. One day at each end of a trip, and the same
answer on every launch — which is what freezing means. A separate log of the
device's zone per day would fix that one day and introduce state that can
contradict the activities.

**Fixed offsets, not identifiers.** `TimeZone(secondsFromGMT:)` throughout. A
named zone is re-evaluated against whatever tzdata the device carries, and zone
rules are amended by governments several times a year. Freezing against a
mutable rule set is not freezing.

**One query became several.** `HKStatisticsCollectionQuery` takes a single
`anchorDate`, so every bucket it returns is cut on one clock — which is the bug.
A window spanning a trip is split into runs and each is asked for separately.
The runs must partition the window: each run starts at midnight in its own zone,
and Tokyo midnight on the 8th is seven hours before Brussels' own, so a run
ending at its own midnight would overlap the next and double-count every sample
between them. Each run therefore ends where the next begins. The travel day is
short — it ends when you cross — which is also the truer description of it. A
device that has never left home yields one run and pays nothing.

**And it says so.** The freeze alone is silent: the number is right and nothing
tells the reader which midnight it was counted from. `DayZones.marker(forDay:)`
returns the zone when the day's clock differs from the reader's, under the same
rule as §4.3 — compared at the day itself, and falling back to the offset form
when the identifier is one of Strava's substituted ones.

---

## 5. Units — SI at rest, formatted at the edge

Every stored measurement is SI, unrounded, and matches what the app already
holds so migration is a copy rather than a conversion:

| Quantity | Stored | Not |
|---|---|---|
| distance | metres, Double | kilometres |
| duration | seconds, Int | minutes |
| speed | metres/second | min/km |
| temperature | Celsius | Fahrenheit |
| mass | kilograms | — |
| elevation | metres | — |
| heart rate | bpm, Int | — |
| power | watts, Int | — |
| coordinates | WGS-84 decimal degrees, Double | — |

Conversion happens in the view, once, at the point of display. `Activity.km`
and `Activity.minutes` already work this way and stay.

**Rounding is never persisted.** A stored 5.1 km cannot become 5,092.8 m again.

---

## 6. Enums, optionality, and the difference between zero and unknown

- **Enums stored as TEXT**, their case names, not integers. An integer enum in a
  database is unreadable in a query and renumbers silently when a case is
  inserted. Storage cost is irrelevant here.
- **Every enum column has a CHECK constraint** listing its permitted values, so a
  typo in a migration fails at write rather than at decode.
- **NULL means unknown. It never means zero.** This is already load-bearing:
  `averageHeartrate` absent means no strap, not a heart rate of zero, and the
  training-load engine must skip the session rather than score it as easy. Any
  column where zero is a legitimate measurement is NOT NULL with an explicit
  default; any column where absence is possible is nullable and every reader
  handles it.
- **No sentinel values.** No `-1`, no `0` standing in for missing, no empty
  string for "not set".

---

## 7. Integrity, protection, and backup

- **Foreign keys ON for every connection**, set in the connection configuration
  rather than per-query. SQLite defaults them off, which is the single most
  common way a schema with declared relationships turns out never to have
  enforced them.
- **CHECK constraints on structural measurements**: distance ≥ 0, duration ≥ 0,
  latitude in −90…90, longitude in −180…180 — **and upper bounds, which this
  paragraph originally got wrong.**

  **Correction, 3 August 2026, made while writing the migration.** This section
  claimed the floors above are "exactly what these reject" for the 199 km /
  694,865 s "Afternoon Ride" artifact from August 2025. They are not. 694,865 is
  a positive number and passes `duration ≥ 0` without complaint, and 199 km is
  an ordinary long ride. A non-negativity check cannot catch that artifact and
  never could.

  What catches it is a ceiling, so `2026-08-03-initial` carries two:
  `Sub4Migrations.maximumPlausibleElapsedSeconds` = 604,800 (7 days) and
  `maximumPlausibleDistanceM` = 1,000,000. The artifact's 8.04 days trips the
  first. Both are judgements rather than laws, which is why they are named
  constants, asserted against the real artifact in `SchemaConstraintTests`, and
  written here rather than buried in a SQL string.

  A ceiling means an import can hard-fail on a malformed activity. That is the
  intended behaviour — reject at the boundary rather than three screens later —
  and 3.3's quarantine is what makes a rejection recoverable instead of fatal.
- **File protection** `completeUntilFirstUserAuthentication` on the database
  directory and every sidecar — `-wal`, `-shm`, and any backup. Patch 190
  established the class and the reasoning (background writes fail silently under
  `.complete`); the database inherits it rather than choosing again.
- **Excluded from iCloud backup?** No — see §9, open question 4.
- **Schema version** is GRDB's migration identifier, and migrations are named
  with a date prefix so their order is readable: `2026-08-03-initial`.

---

## 8. What the tables mean

A table maps to a domain concept, never to a transport shape. No table is named
after a Strava endpoint, and no column exists because an API returns it.

Ten groups, in dependency order:

1. **account, source** — who and where from. One account today; the column
   exists because the alternative is adding it during a migration later.
2. **plan, plan_version, plan_week, plan_session, plan_exercise** — the seed,
   versioned by content hash.
3. **activity** (canonical), **activity_source_record**, **activity_alias** — §3.
   `activity` carries `startUTC`, `startLocal`, `dayKey`, `startOffsetSeconds`
   and `timeZoneIdentifier` — see §4.1. The last two are nullable and mean
   unknown, not zero: an offset of 0 is Greenwich, not "no information".
4. **recording** — series data. Shape decided by benchmark, see §9 question 3.
5. **user_note, proposal, match_decision, correction, rejection** — authored.
6. **athlete_profile, hr_zone, gear, constants** — thresholds.
7. **review, review_evidence** — the audit trail.
8. **weather** — one row per activity, keyed canonically not by Strava id.
9. **sync_state, work_queue, content_revision** — operational.
10. **lifecycle_event** — deletion and export receipts.

### 8.1 Three amendments, made while building the schema — patch 202

Writing the tables found three places where the list above was wrong. Recorded
here rather than corrected silently, because the list is what a reader checks
the schema against.

**Group 6's `constants` table does not exist, and should not.** `AthleteConstants`
holds a maximum heart rate, a resting override, a sex coefficient, and a
dictionary of resting rates by month. That is a profile, three scalars and a
time series. A table called `constants` containing a bag of unrelated values is
a transport shape, and the first line of this section forbids exactly that. They
are stored as columns on `athlete_profile` and as a `resting_month` table.

**Group 5 lists `proposal` under "authored". It is not.** The athlete does not
author a proposal — a model produces one, inside a review, and the only reason
it is kept is the audit trail. `proposal` and `proposal_change` carry foreign
keys to `review` and belong to group 7.

**Group 10 cannot hold deletion receipts.** The database lives inside the folder
that "Delete local data" removes, so a delete receipt written here goes with the
thing it describes. That is also the correct outcome rather than a limitation:
patch 186 decided the delete receipt stays in memory precisely because a record
of the deletion surviving the deletion is a record nobody asked to keep.
`lifecycle_event.operation` is constrained to `export` and `disconnect`, and a
test asserts that `delete` is refused.

**One addition rather than a correction.** Evidence lineage is a join table,
`review_evidence_source`, not a column. ADR-0002's purge has to find every
stored piece of evidence carrying Strava lineage and remove it while leaving the
verdict standing — that is a query, and a data-deletion obligation whose
correctness rests on substring matching against a comma-separated column is not
one this project should sign.

---

## 9. Decisions

All six answered on 3 August 2026. Each records what was decided, and — more
usefully — what now follows from it.

### 9.1 Cloud sync is EXPLICITLY OUT OF SCOPE for v1

Not "not yet", not "we'll see". Out, and written down so it is a decision rather
than an omission.

**What this buys:** no tombstones, no per-row change tracking, no conflict
resolution, no last-writer-wins semantics, no vector clocks. Rows are created,
updated and deleted by one device and nothing reconciles.

**What it costs:** adding sync later is a migration touching most tables, and it
will be a real one. That is the accepted price.

**What it does NOT mean:** the database is still backed up (§9.4), so a new
phone restores. "No sync" means no live reconciliation between two installs, not
"your data only exists here".

### 9.2 The seed is `Sub4/plan.json` — the copy inside the target

37 weeks, 261 sessions, 20 exercises, and the `fuel` and `warmup` blocks the app
actually renders. **278,546 bytes, SHA-256 `4dfb8b1f2284d6721edba307a3fef662a32d16191ce1aa8ee7819c6250ad05ea`.**

**Amended 12 August 2026, patch 351.** Was 278,870 bytes and 261 sessions,
SHA-256 `7b0b485704a0815b…`. **260 sessions** — the Berlin rest day moved from
Sunday 30 August to Tuesday 1 September and the Sunday card was deleted rather
than duplicated (§12.96). First movement in this constant since 329a, and in
the other direction.

**Amended 12 August 2026, patch 350.** Same 278,870 bytes, was SHA-256
`1c10ba914dd05224…`. Every run pace from 14 Aug through 11 Oct moved +15 s/km
(§12.95) — 18 `detail` strings, every swap the same character count, so the
byte count held still while the content moved. A size check alone would have
called this file unchanged; the hash is why §9.2 records both.

**Amended 12 August 2026, patch 349.** Was 279,414 bytes, SHA-256
`0d41f78c1b55175c8…`. Weeks 4–6 were rebuilt around the changed travel — two
build-up weeks and a Berlin run block, §12.94 — which leaves the session count
at 261 while the discipline mix moves: run 105→107, bike 53→52, swim 26→25.
`PlanSeedTests.Frozen`, `PlanCoverageTests.Expected` and this paragraph were
updated in the same patch as the file.

**Amended 8 August 2026, patch 329a.** Was 260 sessions, 279,078 bytes, SHA-256
`a4087101cad4f61e…`. The plan was revised — week 2's long run moved from Saturday
8 August to Sunday 9 August and Saturday became a rest day, §12.74 — which added
one rest session. `PlanSeedTests` failed on all three constants the moment the
file changed, and this paragraph was updated in the same patch as the test. That
is the sequence §12.13.4 exists to enforce, and the three weeks it once did not.

**Amended 5 August 2026, patch 246.** This paragraph read "243,194 bytes,
SHA-256 beginning `e93bf5ea`" until today. The seed changed in commit `13782b8`
— patch 238 corrected 22 weeks whose stated volume implied 58-79 km/h on a
bicycle, and patch 242 rebuilt the weekly totals from `PlanStore.plannedVolume`
— and this record was not updated for three weeks. The figures above are now
asserted by `PlanSeedTests`, so the next divergence fails a build instead of
being found by an audit. See §12.13.2.

**Consequences:**

- The root copy `sub4/plan.json` (218,499 bytes, `7d83ee7d`, no `fuel`, no
  `warmup`, `meta.source` differing by one character) is **removed from the
  source tree**, not kept "just in case". Two files that look like the plan is
  how the wrong one gets loaded eventually. It was moved on 3 August 2026 to
  `sub4-backups/stale-root-duplicates-2026-08-03/`, where it still is —
  amended 5 August 2026, because this paragraph said "deleted" and a backup a
  document calls a deletion is the kind of small untruth that makes a reader
  distrust the parts that matter. `PlanSeedTests` records its digest so it is
  recognised on sight if it ever reappears in the bundle.
- `Sub4-complete/Sub4/plan.json` is byte-identical to the root copy and goes
  with it.
- 3.4 imports by content hash, so the seed's identity is its SHA-256 rather than
  its path. Re-importing the same hash creates no second version.
- The ADR records the hash so a future divergence is detectable rather than
  arguable.

### 9.3 Recordings are NORMALIZED rows — RESOLVED 4 August 2026, patch 212

One row per sample. ~300 samples per activity, ~660 activities today — about
200,000 rows, which SQLite does not consider interesting.

**The condition, stated so it can actually be checked:** 3.2 benchmarks at
10,000 activities — roughly 3 million rows. If storage, import time or the
representative recording read misses budget there, chunks are reconsidered
**then**, with numbers. Not before, and not on instinct.

Normalized is chosen because it is queryable in a terminal, diffable, and
partially recoverable: one corrupt row is one lost sample, where one corrupt
blob is a whole session's trace. That last property is worth real performance —
DATA-06 is precisely about corruption isolation.

#### 9.3.1 The benchmark ran. Normalized stays.

Measured on an iPhone 17 Pro Max, 4 August 2026, patch 212, Debug build.
10,000 activities × 300 samples = **3,000,000 rows**, built in a throwaway
database in temporary space. Two consecutive runs, no changes between them:

| | run 1 | run 2 |
|---|---|---|
| Build (10,000 activities) | 1.88 s | 1.88 s |
| `day` / `week` | 0.61 / 0.65 ms | 0.58 / 0.64 ms |
| `source` (join, 7,500 rows) | 61 ms | 61 ms |
| `sport` (1,667 rows) | 16 ms | 16 ms |
| `unmatched` (anti-join, 6,666 rows) | 54 ms | 81 ms |
| `detail` (single activity) | 0.49 ms | 0.63 ms |
| Normalized sample storage | 223.6 MB | 223.6 MB |
| Chunked sample storage | 102.6 MB | 102.6 MB |
| Normalized import | 40.31 s | 39.98 s |
| Chunked import | 1.07 s | 1.02 s |
| Normalized read, per recording | 0.313 ms | 0.282 ms |
| Chunked read, per recording | 0.142 ms | 0.061 ms |

Storage came back byte-identical across every run of the day (223,637,504),
which is the fixture determinism §9's condition assumed and nobody had checked.

**Against the budgets:**

| Budget | Allowed | Measured | Headroom |
|---|---|---|---|
| Read one activity's trace | < 5 ms | 0.28–0.31 ms | ~16× |
| Import one activity | < 50 ms | 4.0 ms | ~12× |
| Sample storage at 10,000 | < 500 MB | 223.6 MB | ~2.2× |

Normalized passes all three, twice. **Decision: `recording_sample` stays as one
row per sample. `recording_chunk` is not created by any migration and does not
exist outside the benchmark.**

At the real corpus — roughly 700 activities — this scales to about **16 MB and
2.5 s for a full backfill**. The 224 MB and the 40 seconds are artifacts of a
fixture fifteen times larger than the athlete's actual history, and quoting them
without that context would misrepresent the cost by an order of magnitude.

#### 9.3.2 The budgets are absolute, and that is a correction

The condition in §9.3 said "misses budget" without saying what the budget was.
Patch 206 filled that in as **ratios** — keep normalized unless it costs more
than 3× the storage or 3× the read of chunked. That rule was wrong, and the
phone proved it: five runs gave read ratios of ×5.04, ×4.73, ×2.73, ×2.21 and
×4.63, and the verdict flipped between *chunk it* and *keep normalized* on
consecutive runs of the same size on the same device.

The fault was comparing the shapes to each other rather than to what the app
needs. Chunked reads a trace two to five times faster than normalized; both are
under a third of a millisecond, against a 16 ms frame. A ratio between two
numbers that do not matter is still a number, and it was steering the decision.

Patch 212 replaced it with the three absolute budgets above. Ratios are still
reported — they are the right way to *describe* the difference — they no longer
decide. Import is in the rule now because it was the largest real difference
(×37 to ×39) and the ratio rule ignored it completely.

Evidence that the fix worked: between the two runs above, the read ratio moved
by more than a factor of two while every budget verdict stayed identical.

#### 9.3.3 What chunking would have cost, and is not on the screen

The benchmark measures storage, import and read. It does not measure the thing
that actually decides this, and the numbers should not be read as if it did:

- **A blob is not queryable.** With `recording_sample`, "every sample above 170
  bpm across the block" or "average pace in the final kilometre" is SQL. Chunked,
  every such question becomes application code that loads and unpacks whole
  series. Phase 5 onward is largely questions of that shape.
- **Corruption isolation** — DATA-06, and already argued in §9.3 above. One
  corrupt row is one lost sample; one corrupt blob is a session's whole trace.
- **A migration is history.** Shipping `recording_chunk` for the shape that might
  lose would have committed the schema to both. It exists only inside the
  benchmark's temporary database, and that was deliberate.

The ×2.18 storage and the ×37 import are what normalized costs. The three points
above are what it buys.

#### 9.3.4 What would reopen this

Not instinct, and not a slow screen without a measurement behind it. Specifically:

- any budget above failing on a real device at the size actually stored, or
- sample storage crossing 500 MB in the live database (visible on the Database
  health screen, which counts every table), or
- an import path that needs to insert more than about 50 activities' samples in
  one user-visible operation.

Re-running the benchmark from Settings → Sync & data → Database health is how
that gets checked. It never touches the real database — verified on device: after
writing three million rows, the live file was still 417,792 bytes with every
table at zero except the six seeded `source` rows.

#### 9.3.5 Two defects the device run found

Recorded because both were invisible to a green test suite, which is the pattern
this project keeps rediscovering:

1. **The chunked read measured nothing.** Patch 209 read both shapes with the
   normalized key `"R\(i)"`, but `recording_chunk` keys its rows `"C\(i)"`. The
   chunked side timed a lookup that matched no row and unpacked an empty blob.
   A read that returns nothing is the fastest read there is. Fixed in patch 211,
   which also added the read check — both shapes must hand back the same number
   of values, shown on screen, and the verdict is **withheld** rather than
   computed when they disagree.
2. **One measurement is not a measurement.** The read was a single
   sub-millisecond sample. Patch 211 made it twenty recordings spread across the
   fixture, so neither shape wins on a page that happened to stay hot.

### 9.4 The database IS included in device backup — and this exposes an existing problem

Included, because the alternative silently loses thirteen months on a phone
replacement, and a person restoring a new phone reasonably expects their
training history to be there.

**But writing this down surfaced something about the app as it stands today.**

Application Support is included in iCloud and encrypted local backups by
default. `activities.json`, `details/`, `streams/` and `weather.json` are in
Application Support. So **every route Sub4 holds already leaves the phone in a
backup**, and has since the first version.

That is not wrong — it is what a backup is for, and the alternative is worse.
What is wrong is that the privacy pane's summary line says:

> "Nothing leaves this phone while the transfers above are switched off."

Which is not true, and has never been true. A backup is not one of the
"transfers above", and a reader has no way to know the sentence excludes it.

**Actions falling out of this, to be done alongside 3.2 rather than deferred:**

1. `DataLifecycle` gains a `.deviceBackup` storage location, or an explicit
   `backedUp: Bool` per category, so the inventory states it.
2. The summary line is reworded. Something closer to: *"Nothing is sent to
   another company while the transfers above are off. Your device backup
   includes this data, as it does everything else the app stores."*
3. Record it as a gap now so it is disclosed before it is fixed — the pattern
   this project has used throughout.
4. **Credentials are NOT unaffected, and this was checked rather than assumed.**
   `Keychain.save` writes with `kSecAttrAccessibleAfterFirstUnlock` — without
   `ThisDeviceOnly`. Items at that accessibility ARE included in encrypted
   device backups and restore onto a new phone.

   The inventory currently tells the reader, in the credentials entry's own
   deletion rule:

   > "Never exported, and never included in a backup or a diagnostic."

   The first and last clauses are true. The middle one is false, and has been
   since the Keychain wrapper was written. Your Strava application keys, your
   sign-in tokens and your Anthropic API key are in every encrypted backup you
   have made.

   Whether that is the RIGHT behaviour is a separate question with a real
   argument on both sides — restoring a phone and still being signed in is
   convenient, and `ThisDeviceOnly` would mean re-entering the API keys after
   every device change, which patch 187's decision explicitly optimised against.
   But the sentence has to stop claiming otherwise either way.

   **Actions:** correct the deletion rule; record it as a gap; and decide
   deliberately whether the accessibility becomes
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for the Anthropic key
   specifically, which is the one item whose loss costs nothing and whose
   leakage costs money.

### 9.5 Minimum supported OS: iOS 26.5

Matches the current deployment target. Recorded so the `DatabasePool`
prerequisite in §2 can be evaluated later without re-deriving it: any future
pool adoption must verify the SQLite build shipped on iOS 26.5 supports the WAL
behaviour relied upon.

### 9.6 Account and source columns are included — for Phase 4A, NOT for multi-user

They exist because two sources are about to coexist during the Strava-to-Health
cutover, and because adding a column to every table during a migration is worse
than carrying it from the start.

**Stated plainly, so nobody reads the schema and infers a product:** Sub4 has
one athlete. There is no sign-up, no login, no account switching, and none is
planned. `account` exists so `(account, source, externalID)` is the uniqueness
key that survives Phase 4A, and so a future second source has somewhere to go.

Anyone reading `account_id` and concluding this app has users should read this
paragraph instead.

### 9.7 The legacy JSON stores are migrated ONCE, not dual-written — decided 4 August 2026

**SUPERSEDED BY D6b (patches 302–307).** This was the original cutover decision.
The project later chose bounded write-through plus parity during the shadow and
stabilisation window because real-device evidence was worth the temporary second
writer. The final state is still one SQLite authority; this subsection is
historical rationale, not the current migration procedure.

Nine stores hold the app's data in JSON under Application Support today:
`activities.json`, `details/`, `streams/`, `athlete.json`, `constants.json`,
`notes.json`, `proposals.json`, `weather.json`, plus preference keys. 3.3 moves
them into SQLite.

**Decision: a one-time cutover.** The migration reads each JSON file once,
writes the database, and from that point the database is the only source. The
JSON files stay on disk, untouched and unread, until a later patch retires them.

The alternative considered and rejected was dual-writing — stores writing both
JSON and SQLite for some patches while reads stay on JSON — which is safer
against a bad migration and worse in every other respect. It gives every store a
second write path, and any divergence between the two copies is a silent bug
class that only surfaces when the reads are flipped, which is exactly when
nobody is looking for it. One writer is the property worth having.

**What makes the cutover survivable:**

- The JSON files are kept. A bad migration is recoverable by deleting the
  database and the applied-migration row, not by reconstructing from a backup
  the athlete does not have.
- The import is **idempotent**. Re-running after a partial failure must reach
  the same state, not a doubled one. See §12 for how canonical ids make that
  true.
- Nothing is deleted in 3.3. Retiring `activities.json` is a separate, later
  patch, taken only once the database has been the sole source for long enough
  to trust.

**The consequence for `Sub4Launch.migrationFailureBlocksTheApp`**, which is
`false` today: it must become `true` in the same patch that makes the first
store read from the database. Before that, a failed migration costs nothing.
After it, carrying on means showing an empty training history that looks exactly
like a real one — the worst failure this app has available.

---

## 10. Acceptance criteria for 3.1

- [x] This ADR is approved or amended, with all six questions answered — 3 Aug 2026.
- [x] Every table in §8 maps to a domain concept, not a transport DTO — groups 1
      and 3 in patch 195, groups 2 and 4–10 in patch 202. The three places the
      §8 list itself failed that rule are amended in §8.1.
- [x] The identity rules here, `DataLifecycle`, and the schema diagram agree —
      the schema is the diagram, and `DatabaseInventoryTests` asserts the
      agreement with `DataLifecycle` rather than leaving it to a reading.
- [x] The GRDB version is pinned and builds in the clean CI baseline — 7.11.1,
      §2. CI green is what closes this one; see the run for patch 195.

## 11. What 3.2a actually shipped, and what it did not

Patch 195, 3 August 2026. 162 tests in 18 suites green.

**Shipped:** `Sub4Database` (connection, configuration, file protection on the
database directory, `quick_check` / `foreign_key_check` reporting),
`Sub4Migrations` with `2026-08-03-initial` creating `account`, `source`,
`activity`, `activity_source_record` and `activity_alias`, and the inventory
entry that makes the database deletable.

**Deliberately not shipped:** nothing in the app opens the database. There is no
caller for `Sub4Database.open()` and no health screen. Both arrive with 3.2b.
Recorded rather than implied, because a step that cannot be seen on hardware has
not been verified — six of the eleven defects found in Phase 2 were reachable
only on a device.

### 11.1 What 3.2b shipped

Patch 202, 4 August 2026. 229 tests in 26 suites green.

Migration `2026-08-04-domain`: twenty tables covering groups 2 and 4–10, in its
own file, because `2026-08-03-initial` has now run on a real device and the
surest way to keep a migration body frozen is to stop opening the file it lives
in. Nothing reads or writes any of it — 3.3 builds the importer, 3.4 moves the
app across.

The rules the schema now enforces rather than merely describes:

- `user_note.planSessionUID` is deliberately **not** a foreign key. A note is
  written against the plan that was current at the time, and plan versions are
  replaced wholesale by an app update. An FK to `plan_session` would delete
  thirteen months of writing the first time an update renumbered a week — the
  same failure `activity_alias` exists to prevent, one table over.
- Notes and match decisions use `ON DELETE SET NULL` against `activity`.
  Deleting a recording must not delete what you wrote about it.
- At most one active `plan_version`, as a partial unique index rather than a
  rule somebody remembers.
- Weather is keyed by the canonical activity and has no column that could hold a
  source's identifier — the Strava-lineage gap in `weather.json`, closed by
  construction.

Still open in 3.2: the health screen (3.2c) and the benchmarks (3.2d), including
the normalised-versus-chunked recording comparison §9 question 3 defers to.

### 11.2 What 3.2c and 3.2d shipped — patches 203–212

**3.2c, the Database health screen** (patches 203–205). Settings → Sync & data →
Database health, internal builds only. Opening it is what creates
`db/sub4.sqlite` for the first time. Verdict, file, every table's row count
including the zeros, and a redacted copy button. Two defects it caught on the way
in, both the same assertion failing twice for unrelated reasons: `grdb_migrations`
was being counted as a table (it has no `sqlite_` prefix), and the six seeded
`source` rows were counted as imported data.

**3.2d, the benchmark** (patches 206–212). Runs from the health screen at 500,
2,000 or 10,000 activities, on a detached task with ordered progress and working
cancellation. Answered §9 question 3 — see §9.3.1.

Four defects surfaced between the simulator and the phone, and only one of them
was found by a test:

| | Found by |
|---|---|
| Shared temp directory name → parallel tests deleted each other's open database | the test suite, as `vnode unlinked while in use` |
| Chunked read used the normalized key, so it timed a miss | reading a number on the phone that made no sense |
| Read measured once, sub-millisecond | the same |
| Ratio-based verdict flipped between identical runs | running it twice, which nothing forced |

The last three were invisible to 248 green tests. The benchmark had a test
asserting every query shape was measured, and none asserting the reads returned
anything — which is the same omission, in a new place, as every entry in §11's
list above.

Not done, and deliberately: the benchmark's fixtures write in batches of 250
activities per transaction, which is not how the 3.3 importer will necessarily
batch. The comparison is fair because both shapes use the same batch size, but
the absolute import figures are the benchmark's, not the importer's.

**Two things this step changed about the ADR itself**, both because writing the
code exposed them:

1. §7's CHECK-constraint claim was wrong — see the correction there.
2. Seeding `source` from `DataSource.allCases` was written, then removed. A
   migration body is history: one that reads a live Swift enum silently gives a
   fresh install a different database from an existing one the moment a case is
   added, under one migration identifier. The lists are frozen in the migration
   and coupled to the enums by test instead. Worth stating in the ADR because
   the same temptation will return at every later migration.

---

## 12. What the import writes — step 3.3

Written before the importer, for the same reason §8 was written before the
schema: the mapping is where the mistakes are, and a mapping argued in a diff is
a mapping nobody reviewed.

### 12.1 Canonical ids, and how the import stays idempotent

§3.1 says Strava ids are never primary keys. `Activity.id` in
`activities.json` **is** the Strava id, so the import cannot carry it across as
`activity.id`.

Nor can the canonical id be *derived* from it — that smuggles Strava identity
into the primary key by another route, and §3.1 exists to stop exactly that.

So: **look up, then mint.**

1. Look for an existing `activity_source_record` with
   `(sourceID = 'strava', externalID = <the JSON id>)`.
2. If found, reuse its `activityID`. The row is already imported; update it in
   place or skip it.
3. If not found, mint a fresh opaque id, write the `activity` row, and write the
   `activity_source_record` that links the two.

That is what makes a re-run after a partial failure converge rather than double.
A `UUID()` minted unconditionally would be idempotent-looking and wrong: every
re-run would produce a second copy of every activity, and nothing in the schema
forbids it, because the schema has no way to know two rows describe one session.
The uniqueness that saves us is `(accountID, sourceID, externalID)` on
`activity_source_record`, which the initial migration already declares.

### 12.2 Rows that the schema will refuse, and what happens to them

The domain migration's CHECK constraints are not advisory. `activities.json`
holds at least one row the database will reject: the August 2025 artifact at
199 km / 694,865 s, which fails the upper bounds added after the §7 correction.
There may be others nobody has looked for.

**A refused row must not abort the import.** It is recorded in `rejection` with
its source, external id and the constraint that refused it, and the import
continues. An importer that stops at the first bad row would leave the database
half-populated and the app showing a partial history, which is worse than the
one row being missing and far harder to notice.

The count of refusals belongs on the Database health screen. A silent rejection
is indistinguishable from a row that was never there.

### 12.3 Activities — the first store, and the shape for the rest

| `activities.json` | table.column | note |
|---|---|---|
| `id` | `activity_source_record.externalID` | with `sourceID = 'strava'` — never `activity.id` |
| — | `activity.id` | minted opaque, per §12.1 |
| `name` | `activity.name` | |
| `sportType` | `activity.sportLabel` | stored raw, unconstrained — "a sport label the app has never seen is stored rather than rejected". The column is `sportLabel`; an earlier draft of this table said `sportType` and was wrong. |
| `sportType` | `activity.discipline` | mapped through `Discipline`; anything unmapped becomes `other`, and the raw label above is what preserves the detail |
| `startLocal` | `activity.startLocal` | |
| `startLocal[0..<10]` | `activity.dayKey` | derived, not stored twice by accident — §4.5 |
| `startUTC` | `activity.startUTC` | |
| `timeZoneIdentifier` | `activity.timeZoneIdentifier` | §4.4 |
| `startOffsetSeconds` | `activity.startOffsetSeconds` | the frozen offset; outranks the identifier |
| `distance` | `activity.distanceM` | metres, SI at rest — §5 |
| `movingTime` / `elapsedTime` | `activity.movingSeconds` / `elapsedSeconds` | |
| `elevationGain`, `averageHeartrate`, `maxHeartrate`, `startLat`, `startLon` | `elevationGainM`, `averageHeartrate`, `maxHeartrate`, `startLatitude`, `startLongitude` | nullable throughout — §6, absent is not zero |
| `averageWatts` | `activity.averageWatts` | added by `2026-08-05-activity-inputs` — see §12.5 |
| `deviceWatts` | `activity.hasPowerMeter` | renamed: the schema is source-neutral, and `device_watts` is Strava's word |
| `isTrainer` | `activity.isIndoor` | likewise. Nullable — absent is not "outdoors", and `Weather` reads this |
| `maxSpeed` | `activity.maxSpeedMS` | SI, and no upper bound — §12.5 |
| `gearId` | `activity.gearID`, resolved through `gear` | the CANONICAL gear id, not Strava's. Gear imports first or every value lands null |

`account` gets exactly one row, minted at import. §9.6: the column exists for
Phase 4A, not because this app has users.

**Duplicates are preserved, not merged.** Strava holds the same ride twice from
21 April 2026, uploaded by two devices under two ids. Both import, as two
activities with two source records. Merging them is a matching decision, and
the importer is not the matcher — an importer that silently dropped one would be
making a judgement nobody could audit afterwards.

### 12.4 The remaining stores, named but not yet specified

`details/` and `streams/` → `recording` + `recording_sample` (§9.3.1 settled the
shape); `notes.json` → `user_note`; `proposals.json` → `proposal` +
`proposal_change`; `weather.json` → `weather`; `athlete.json` and
`constants.json` → `athlete_profile` + `hr_zone`; the bundled plan → `plan`,
`plan_version`, `plan_week`, `plan_session`, `plan_exercise`.

Each gets its own row in this section before its importer is written. The
activity mapping above is the pattern: what the JSON holds, which column it
becomes, and what happens to the rows that do not fit.


### 12.5 The five columns 3.2 did not build — migration `2026-08-05-activity-inputs`

Writing §12.3 found that `activities.json` holds five fields with no column
anywhere in the thirty-one tables 3.2 built: `gearId`, `averageWatts`,
`deviceWatts`, `isTrainer`, `maxSpeed`.

None is decorative:

| field | read by | cost of dropping it |
|---|---|---|
| `deviceWatts` | `PowerLoad`, **`TrainingLoad`** | changes CTL/ATL/TSB, silently |
| `isTrainer` | `PowerLoad`; `isOutdoor` → `Weather` | indoor sessions start requesting weather |
| `gearId` | `SessionDetailView`, `ActivityDetailExtras` | per-session shoe attribution disappears |
| `averageWatts` | `PowerLoad`, `ActivityDetail` | bike load loses its input |
| `maxSpeed` | `ActivityStore` | minor |

A cutover without them would have moved the load model onto data missing its
power inputs, and nothing would have looked broken — the curve would simply have
been different, for reasons nobody could trace weeks later. Every test passed
while the gap existed, because they all asked "does what is declared work" and
none asked "is what is declared enough".

**A separate migration, not an edit to `2026-08-04-domain`.** That one has run
on a real phone; a shipped migration is history, and editing it would give a
fresh install a different database from an existing one under the same
identifier — the trap already recorded in §11.

**Two naming decisions.** `device_watts` becomes `hasPowerMeter` and `trainer`
becomes `isIndoor`, because a column named after one provider's JSON key embeds
that provider in a schema §3 says is source-neutral. Both are nullable: absent
is a third answer, distinct from false, and `PowerLoad` and `Weather` both need
to tell them apart.

**Why these CHECKs are looser than §7's.** `distanceM` and `elapsedSeconds`
carry upper bounds because the August 2025 artifact was a session that was
wrong. `maxSpeedMS` and `averageWatts` get none: a GPS spike does not make the
run untrue, and refusing it would cost the whole activity — the insert fails,
the row lands in `rejection`, and a real session disappears over a field nobody
reads closely. An upper bound is worth having only where the suspect value IS
the session being wrong.

### 12.6 Gear that cannot be resolved — the first import's finding

The first real import ran on 4 August 2026: **662 activities seen, 661
imported, 1 refused** (the August 2025 artifact, at 694,865 s against the
604,800 s bound — exactly the row §7's correction predicted, and the only one in
thirteen months of data).

**404 of the 661 named gear the app does not hold.** Patch 221 made the report
name them rather than count them, which is what turned a guess into a finding:

| id | activities | what it is |
|---|---|---|
| `b6932581` | 284 | a bike |
| `b13458344` | 60 | a bike |
| `g15316986` | **51** | a **shoe**, and not one of the six |
| `b10348095` | 9 | a bike |

Two distinct causes, and neither is a bug in the import:

1. **`AthleteStore` decodes only the `shoes` array** from Strava's `/athlete`.
   Bike gear has never existed in this app, so 353 activities name something the
   app has no record of.
2. **`/athlete` returns only ACTIVE gear.** A retired pair — `g15316986`, 51
   runs — cannot be resolved from the profile at all, at any point in the
   future, without Strava's per-gear endpoint.

**The defect that mattered was in the database, not the profile.**
`activities.json` holds `gearId` for all 404; the first version of the importer
wrote NULL. A field present in the source and absent after the cutover is
exactly what §12 exists to prevent, and it had been caught for five other fields
one section earlier.

#### Where the reference lives, and why not on `activity`

The first fix (patch 222) added `activity.gearExternalID`, by analogy with
`sportLabel` keeping the raw sport beside the mapped discipline.
**`IdentityTests.noExternalIDOnTheActivity` refused it** — no column on
`activity` may contain "external", because §3.1 says an external identifier
lives in exactly one kind of place and the canonical activity is not it.

The guard was right. "It is only a reference to another entity" is the same
argument that would justify `stravaActivityID` on `activity`; §3.1 holds
precisely because every exception to it sounds reasonable, and a guard with an
allowlist is a guard that drifts.

So the reference lives in **`activity_gear_reference (activityID, sourceID,
externalID, notedUTC)`**, mirroring `activity_alias`. Unique on
`(activityID, sourceID)`; no foreign key to `gear`, which is the whole point.

It is written **whether or not the gear resolves** — this is the record of what
the source said, and it stays true once the gear is known, the same way
`activity_source_record` keeps Strava's activity id after the canonical id
exists. `activity.gearID` answers "which gear row is this";
`activity_gear_reference` answers "what did the source call it", and only the
second survives a source that has forgotten.

#### What was deliberately not done

**No `gear` rows were invented** for the unknown ids. `gear.name` is NOT NULL,
so a placeholder would have to be the id itself, and three bikes would then sit
in the gear table looking like shoes — with wear bars, once anything reads gear
from the database rather than from `AthleteStore`.

**Bikes are not fetched, and retired shoes are not resolved.** Both are
achievable: bikes from the same `/athlete` response the shoes come from, retired
gear from Strava's per-gear endpoint. Both are decisions about what the app
tracks rather than about the cutover, and neither is needed now that nothing is
being lost. If they are done, the references above resolve without any change to
the import.

### 12.7 Notes and proposals — the mapping, and a second schema gap

Written before the importer, per §12. The activity mapping found five missing
columns that way; this one finds four more, in a different table, for the same
reason.

#### 12.7.1 `notes.json` → `user_note` — clean

`NotesStore.Note` is `sessionUid`, `rpe`, `feel`, `text`, `created`, `edited`.
Every field has a column.

| `Note` | `user_note` | note |
|---|---|---|
| — | `id` | minted opaque, §3.2 |
| `sessionUid` | `planSessionUID` | NOT NULL. Provenance, not identity — §3.2 |
| `rpe` | `rpe` | CHECK 1…10; a stored 0 would be refused |
| `feel` | `feel` | CHECK against the frozen `domainFeels` |
| `text` | `text` | |
| `created` / `edited` | `createdUTC` / `editedUTC` | |

**`planVersionID` and `activityID` are left NULL, deliberately.** No
`plan_version` rows exist until the bundled plan is imported, and resolving a
note to the activity that satisfied its session is a MATCHING decision. The
importer is not the matcher — the same rule that stops it merging the 21 April
duplicate ride. Both are filled in later by the code that owns those questions,
and `ON DELETE SET NULL` on both means neither can orphan a note.

This is the property §8 built `user_note` around: a note survives the plan
version it was written against, because `planSessionUID` is not a foreign key.

#### 12.7.2 `proposals.json` → `review` + `review_evidence` + `proposal` + `proposal_change`

One `Record` becomes rows in four tables. Three of its fields have nowhere to go.

| `ProposalStore.Record` | destination |
|---|---|
| `ranAt` | `review.ranUTC` |
| `startDay` / `endDay` | `review.windowStartDayKey` / `windowEndDayKey` |
| `model` | `review.model` |
| `evidence` (one markdown blob) | one `review_evidence` row |
| `proposal.verdict` / `summary` / `reasoning` | `proposal.verdict` / `summary` / `reasoning` |
| **`appVersion`** | **no column** |
| **`windowLabel`** | **no column** |

And `ReviewProposal.Change` carries five fields into a table with two:

| `Change` | `proposal_change` |
|---|---|
| `newDetail` | `what` — but empty on a skip, and `what` is NOT NULL |
| `reason` | `why` |
| **`sessionUid`** | **no column** — and it is what the change APPLIES TO |
| **`skip`** | **no column** |
| **`evidence`** | **no column** |

**The diagnosis, stated plainly: `proposal` and `proposal_change` were designed
from §8's prose rather than from the type they have to hold.** `review` and
`review_evidence` came out closer because §8 described them in more detail. The
same risk applies to every table 3.2b built ahead of its importer — `weather`
and the plan tables are next, and both are to be checked against their types
before any importer is written, not after.

Two values the import would otherwise have to invent, and both are recorded here
rather than chosen in code:

- **`review.provider`** is NOT NULL and `Record` has no provider — only a model
  name. The importer writes the provider the app actually used, and the model
  name beside it. A provider guessed from a model string would be a fact
  invented by an import.
- **`review_evidence.wasSent`** is NOT NULL and `Record` does not record it. The
  evidence blob in `Record` IS what was sent to the model — that is what the
  field is — so it imports as `true`, and the reasoning is written down because
  a future reader will otherwise wonder where the value came from.

#### 12.7.3 What is proposed, and the one judgement call

A fifth migration, `2026-08-06-proposal-inputs`:

```
review.appVersion          TEXT     nullable
proposal_change.planSessionUID  TEXT NOT NULL   -- what the change applies to
proposal_change.newDetail  TEXT     nullable    -- empty/absent on a skip
proposal_change.isSkip     INTEGER  nullable    -- absent is not false, §6
proposal_change.evidence   TEXT     nullable    -- the computed line it rests on
```

`what` and `why` stay as they are: `why` takes `Change.reason`, and `what`
becomes a rendered human summary rather than the raw replacement text, which is
what the column name asks for.

**The judgement call: `windowLabel` is NOT carried.** It is a presentation
string derived from `startDay` and `endDay`, and §12's rule is about not losing
FACTS, not about preserving every formatting of them — the same reason `dayKey`
is derived from `startLocal` rather than stored twice from the source. If it
turns out to hold anything the two day keys cannot reproduce, this decision is
wrong and the column is owed.

### 12.8 Two things the first authored import taught, 4 August 2026

#### 12.8.1 The kept JSON files are not a fallback against a reinstall

§9.7 says the one-time cutover is survivable because "the JSON files stay on
disk, untouched and unread". That is true of a bad migration and false of the
event that actually happened.

`notes.json` and `proposals.json` live in Application Support. **Deleting the
app deletes them and the database together.** They do not fail independently —
they share a fate, so the fallback protects against exactly one of the two ways
this data can be lost, and not the more likely one.

On 4 August the app was reinstalled during Phase 3 work. Activities came back
within minutes because Strava still had them. Thirteen months of session notes
and every past review did not, because nothing else ever had them. Four notes
were re-entered by hand; their `createdUTC` now records when they were restored
rather than when they were written, and that column should not be read as
provenance for anything predating that date.

**What follows from it:**

- **Device backup (§9.4) is load-bearing, not incidental.** It is the only thing
  standing between the athlete and the permanent loss of authored content. §9.4
  argued for inclusion in backup on the grounds that the alternative "silently
  loses thirteen months on a phone" — this is that argument arriving in
  practice, one week after it was written.
- **The authored stores are the asymmetric ones.** Activities, recordings and
  weather are caches of something a server still holds. `user_note` and the
  review tables are originals. Any future operation that removes local data —
  a reinstall, a "Delete local data", a migration that erases on schema change —
  costs nothing for the first group and everything for the second. That
  asymmetry is why §12.7 imports them first and why
  `eraseDatabaseOnSchemaChange` stays off.
- **A pre-destructive export is worth building** before 3.4. `DataLifecycle`
  already knows how to export every category; nothing currently offers it at
  the moment it matters.

#### 12.8.2 The proposals import cannot be verified until 24 August 2026

`ReviewDue.state()` requires **four finished plan weeks** before a review can be
run. The block began Monday 27 July 2026, so week 4 ends Sunday 23 August and
the first review comes due **Monday 24 August**. Until then the review card is
hidden on Progress and Today by design, `proposals.json` stays empty, and
`review`, `review_evidence`, `proposal`, `proposal_change` and `proposal_watch`
hold zero rows however many times the import is run.

**So that half of §12.7 is written, tested and unproven**, and it is recorded
here rather than allowed to read as done. Everything it touches is covered by
`AuthoredImportTests` — every formerly-homeless field, the skip rendering, the
CASCADE, the convergence on re-import — and this project's own record is that a
green suite is not the same as a correct one. The chunked read in §9.3.5 had
tests too, and measured nothing for two patches.

**What to check on 24 August, when the first review has run:**

- `review` gains one row; `review_evidence` one; `proposal` one.
- `proposal_change` holds one row per change with a NON-NULL `planSessionUID`,
  and a skipped session's `what` is not the empty string.
- `proposal_watch` holds one row per `watchFor` item, in order.
- `review.appVersion` records the build that produced it — the field that
  existed in the JSON and had no column until patch 225.
- A second import refreshes rather than stacking: the counts above stay put.

#### 12.8.3 The rehearsal — patch 269

§12.8.2 called the proposals path "written, tested and unproven" and listed
what to check on 24 August. This makes the 24th a repeat rather than a
premiere.

**What it does.** Builds a REAL `Review` over however many plan weeks have
actually finished — walking the four-week requirement down rather than
bypassing it, so every figure in the window is the athlete's own — attaches a
synthetic proposal, and writes it through `ProposalStore.add`. That is the
whole untested path: writer → `proposals.json` → importer → `review`,
`review_evidence`, `proposal`, `proposal_change`, `proposal_watch`.

**What it deliberately does not do: call the model.** The Claude request is
exercised every time the review button is pressed and has its own tests, its
own error handling and its own screen. Spending a real API call here would test
the one link in the chain that is not in question — and it would make the
rehearsal non-deterministic, because a real answer might come back with zero
changes (the expected verdict most months) and a rehearsal that exercised
`proposal_change` only sometimes is worth very little.

**The proposal is shaped to the checklist rather than to plausibility.** Two
changes, both naming real session uids from the athlete's own plan, the second
of them a SKIP — which is the case where `newDetail` is empty and `what` has to
come from somewhere else, and the one assertion in §12.8.2 that a proposal with
only edits would never reach. Two watch items, distinguishable, so
`proposal_watch`'s ordinal can be checked rather than assumed.

**Marked in the database, not just on screen.** `model` is `"rehearsal"`, and
`model` is a column on `review`. The 24 August record will be distinguishable
from this one by something more reliable than its date.

**It must be deleted before the first real review.** `ReviewDue` reads the
newest record's `ranAt` and adds 28 days, so a rehearsal left in place would
push the first real review into September. `ProposalStore.remove(_:)` already
exists and Progress already offers it. Recorded here because it is the kind of
consequence a rehearsal is supposed to surface, and this one surfaced while the
rehearsal was being written rather than on the day.

**Internal builds only, checked twice.** `ReleaseGates.isInternalBuild` is
`#if DEBUG`, so neither the button nor `run()` is in a release binary. `run()`
throws on that same value anyway: a gate enforced only by its caller is a gate
that moves the first time somebody adds a second caller.

#### 12.8.4 A review can be deleted — patch 270

`ProposalStore.remove(_:)` was written in patch 225 and **never had a caller**.
Nothing in the app could delete a review record, which nobody noticed because
nobody had ever wanted to — until 269 wrote a rehearsal record that MUST be
removed before 24 August, or `ReviewDue` reads its date, adds 28 days, and
pushes the first real review into September.

**A method written in anticipation is not a feature.** It compiled, it was
correct, and it did nothing — and the gap only became visible when something
depended on it. Worth recording beside the several controls this project has
found that reported work they did not do: this is the same shape from the other
side, a control that would have done the work and was never asked.

**On the record, not on the list.** A swipe-to-delete in
`ReviewView.historyCard` would put an irreversible action one careless gesture
away from a row you were trying to open. The button sits at the bottom of the
record itself, below the evidence and the export — which is the order the
decision actually wants: read it, keep a copy, then decide.

**The confirmation offers the export.** §12.8.1's lesson is that authored
content has nowhere to come back from, and the moment somebody realises they
wanted a copy is the moment they are asked to confirm. So *Export a copy first*
is one of the two actions, not something they have to back out and find.

**This one write waits for the disk.** §12.17.2 put `proposals.json` on the
journal route because it is written by the review runner with nobody present.
A delete button is the exception that argument names — there IS somebody
present — so `remove` follows §12.17 instead: memory follows disk, the record
goes back if the write throws, and the sheet dismisses only if it landed.
`save()` returns a `Bool` for that one caller; every other one discards it and
keeps the journal's behaviour.

### 12.9 `weather.json` → `weather` — clean, and it closes §8's Strava-key gap

Checked against `ActivityWeather` before the importer was written, the same way
§12.3 and §12.7 were. **Nothing was missing.** Every stored property has a
column; `WeatherSource`'s raw values are exactly the frozen
`domainWeatherProviders`; and the CHECK bounds — humidity 0…1, samples > 0,
non-negative wind and precipitation — restate rules `WeatherStore` already
enforces.

Recorded because a clean result is worth as much as the two findings. §12.3
found five missing columns and §12.7 five missing fields, both in tables 3.2b
designed from §8's prose. `weather` was designed the same way and came out
complete, which is what makes the checking a habit rather than a reaction to
being burned.

**This import closes a known gap rather than carrying it.** §8 records that
`weather.json` is keyed by Strava activity id — "the key itself carries Strava
lineage (ADR-0002 — re-key at 4A M4)". The schema keys `weather` by the
canonical activity, so the import resolves every key through `activity_alias`
and the row that lands carries no Strava identity at all. That is 4A M4 done
early, as a side effect of the cutover rather than as a migration of its own,
and it is the first thing to need the aliases that patch 218 wrote three patches
before anything read them.

**Weather for an activity that is not in the database is COUNTED, not refused.**
`weather.activityID` is NOT NULL with a foreign key, so a reading whose activity
never arrived cannot be stored — and that is the schema being right rather than
the import being wrong. Weather is *about* an activity; a reading attached to
nothing is not a fact anybody can use. A refusal means the schema rejected
something that should have fitted; this is a correct decline, and conflating the
two would make the screen report a defect where there is none.

The expected count is **zero since patch 257**. It was one for thirty-one
patches — the August 2025 artifact, which has weather and no activity — and
§12.12.7 records why that stopped being acceptable. Anything above zero now
means activities are missing that should not be, which is what the number was
always supposed to mean and could not while it had a permanent occupant.

## 12.9b `athlete.json` becomes readable — patch 259, contract item 4

Every legacy input has a type you can hand a `Data` to. `athlete.json` did not:
`AthleteStore.Cache` was `private`, so the file-level decoders, the semantic
verifier and `@testable import` alike were all locked out. Patch 246 recorded
that as a test — `athleteCannotBeDecodedFromOutsideItsStore` — thirteen patches
before anything needed it, which is why 259 began with a known obstacle instead
of discovering one halfway through.

**A mirror rather than a promotion.** Dropping `private` from `Cache` is the
obvious fix and is half of what 259 does. The other half is `AthleteFile`, a
`nonisolated` mirror of the shape, so `athlete.json` can be decoded by anything
— including the parts of the migration that do not run on the main actor.

> **Corrected by patch 260.** This section originally justified the mirror by
> saying the reader would run `nonisolated` inside a database write. It does
> not. Every other legacy type — `Activity`, `NotesStore.Note`,
> `ProposalStore.Record`, `ActivityWeather`, `ActivityDetail` — is main-actor
> isolated, so a nonisolated reader would have needed nine more mirrors, which
> is a far worse trade than the one made here for one private type.
> `LegacyClassifier`'s typed pass is `@MainActor`; only its structural pass is
> not. The mirror is still right — `Cache` being private was the actual
> obstacle, and `AthleteFile` is what the verifier will use — but the reason
> given for it was a guess about code that had not been written yet, stated as
> though it were a constraint. Worth leaving visible rather than editing away:
> **a justification written ahead of the thing it justifies is a prediction,
> and should be marked as one.**

So `AthleteFile` mirrors the shape with its own `nonisolated` `Zone` and `Shoe`,
carrying the stored properties and nothing else. `label`, `range` and `contains`
stay on the store's types: a mirror that copied them would be a second
implementation of the same rules, which is worse than the duplication it saved.

**Two declarations of one shape is the obvious objection, and it is answered by
a test rather than by discipline.** `AthleteFileAgreementTests` encodes a real
`AthleteStore.Cache` and decodes it as an `AthleteFile`, field by field, and
separately compares the key sets each one writes — so a property added to either
is a failure rather than a key silently ignored. Making `Cache` internal is what
lets that test exist; a mirror nothing can compare against is a second guess.

**And the date strategy is part of the shape.** `AthleteStore.save()` has always
used a bare `JSONEncoder()`, so `fetched` is a `Double` counting seconds from
2001. Read with the app's own `JSONDecoder.sub4` it does not produce a wrong
date — it throws, and a decoder that throws is one that can be corrected. That
is the entire point of contract item 4: the alternative is a decoder that
succeeds and is wrong, and nothing downstream can tell.

## 12.9c Damage that says which damage — patch 260, contract items 2 and 4

`LegacyFixtureTests.todayEverythingBrokenLooksTheSame` asserted since patch 246
that an empty file, a whitespace file, a truncated file, a corrupt file and a
captive portal's HTML body all fail in exactly one way: `try decode` throws, and
nothing anywhere can tell them apart. It was written to be replaced.

**It was not replaced by failing.** The test still passes — all five still
throw, and they should. What stopped being true was its *name*. That is worth
recording on its own: a test can keep passing long after it has stopped
describing the system, and a green run says nothing about the gap. It has been
renamed to what it actually asserts — that the store decoders stay strict, so
the classifier's extra information is never bought by letting something through.

**Why the distinctions earn their code.** Because the athlete does different
things about them:

| Condition | What happened | What to do |
|---|---|---|
| `absent` | no file — a fresh install | **nothing. Not a fault** |
| `empty` | a write that never started | nothing was in it to lose |
| `whitespace` | the same, one buffer later | as above |
| `truncated` | a write interrupted part way | **restore a backup** |
| `corrupt` | full length, broken structure | not a length problem |
| `notJSON` | a captive portal's sign-in page | this is not our file |
| `wrongContainer` | an array where an object belongs | a file from elsewhere |
| `undecodable` | parses, and the store's decoder refuses | the wrong decoder |

`absent` is the most important line in the table. A migration that reports
"notes.json is missing" on a phone that has never had notes cries wolf on day
one, and contract item 2 exists to stop it.

**Truncated versus corrupt is decided by a bracket-balance scan, not by the
error message and not by the last byte.** Foundation's wording is not a
contract, and a 60% prefix of a JSON file can end on `}` — every nested object
closes somewhere. A classifier reading only the final character would call that
corrupt and tell the athlete *not* to restore the backup that would fix it. The
scan tracks strings and escapes, because session notes are free prose and
proposal evidence is Markdown: braces inside strings are not hypothetical.

**`readable` is only ever returned by the store's own decoder succeeding.**
Nothing infers success from the absence of a structural failure. That is what
puts the wrong date strategy into `undecodable` rather than letting it pass —
contract item 4 becoming visible instead of becoming a silent 1970.

**What 260 deliberately does not do.** A key mismatch still reads clean: the
outer key wins and the embedded id is never consulted. That is contract item 5,
it needs a `quarantine` table and a migration, and folding a schema change into
a classifier would make one patch out of two. It is recorded as a passing
assertion — `aKeyMismatchIsStillInvisible` — which 261 inverts, the same way
patch 246 recorded the `athlete.json` obstacle thirteen patches before 259
needed it.

## 12.9d Neither name wins — patch 261, contract item 5

Five of the eleven legacy inputs are dictionaries keyed by an id that is *also*
written inside each record. The file states the same fact twice, and nothing has
ever checked that the two agree. Two more are arrays where the id lives inside
the record only, so the failure is not disagreement but repetition. Two more are
directories of `<id>.json`, where the file NAME carries the id and the record
carries it too — the same double statement, one level up, and equally unchecked.

**The decision is that neither name wins.**

The tempting fix is to prefer one. The outer key, because it is what the store
looks the record up by. Or the embedded id, because it travelled with the
record. Both are guesses about which half of a contradiction is the true one,
made by code that has no way to know. A note filed under `w99-sun` saying it
belongs to `w03-tue` is either *a note attached to the wrong session* or *a
session renamed with the write half-finished* — and those want opposite repairs.

So the record is held back and both names are reported, and a person decides.
That costs one entry in a list. Picking wrong costs a note on the wrong day for
as long as the app lives, silently, and the athlete would have no way to find it
because nothing ever said anything was odd.

**These two faults are a different kind from the eight in §12.9c.** Everything
there is a file that will not read. These READ. The bytes are fine, the types
are fine, and the file is wrong anyway — which is why `LegacyCondition.decoded`
exists beside `isFault`, and why the quarantine holds records back rather than
rejecting files. **A fault that fails loudly gets fixed. A fault that decodes
cleanly gets imported.**

**Three things the check deliberately does not do.**

A record that does not carry the id field *at all* is not a mismatch. It is a
shape the store held before the field existed, and calling that a contradiction
would quarantine thirteen months of history for being old — when surviving those
thirteen months is the entire point of the migration.

The field is named per store rather than sniffed for. `notes.json` keys on
`sessionUid` and everything else on `activityId`; a heuristic clever enough to
find both would also find `AthleteFile.shoes[].id`, which names a shoe and not a
record. `athlete.json` and `constants.json` are declared `.singleObject` — they
hold the athlete's own figures and have no identity to disagree with.

And `named:` is optional, so a caller that does not know the file name skips the
check rather than passing it. There being no claim to test is a different thing
from a claim that holds, and defaulting the second to the first is how a control
comes to report work it did not do — which this project has now found six times.

**The check runs on the raw JSON, not the decoded values**, because decoding has
already destroyed the evidence. `[String: Note]` keeps both names, but
`[Activity]` cannot tell you two rows collided without going back to look, and a
dictionary decode of a file with a repeated key silently keeps the last one. The
bytes still have all of it.

**What 261 does not include: the `quarantine` table.** Detection is complete and
nothing writes a row yet, because nothing walks the disk yet — §12.9c's
classifier takes bytes, and the reader that fetches them is patch 262. Shipping
a migration for a table with no writer, plus a screen listing nothing, would be
one patch pretending to be two.

## 12.9e The survey — patch 262

260 built a classifier that takes bytes and 261 taught it about identity. Both
were exercised entirely against the fixture corpus: eleven strings somebody
wrote down, and a guess about what real damage looks like. This is where they
meet thirteen months of actual files, and the honest position before running it
is that nobody knows what they will say.

**Reading only. Nothing is held back.** A record that fails the identity check
is reported and still imported, because the `quarantine` table is patch 263.
That ordering is on purpose: **a table designed before anybody has seen the data
it holds is a table designed from the fixtures.** It also means this patch
cannot break an import — it reads files the app already reads, with the same
decoders, and writes nothing.

**The directories are where `named:` finally has an argument.** `details/` and
`streams/` are one file per activity, named by the Strava id that is also inside
the file. 261 built that comparison and had nothing to feed it: every test
passed `named: nil`, which *skips* the check. Here the file name is real, and if
667 details each state their id twice, this is the first time anything has
compared the two.

**One row per store, and the per-file detail underneath.** A directory of 667
files is not one condition, it is 667 conditions, and the useful summary is "660
readable, 7 at fault" with the seven named. "details: mismatch" tells nobody
which activity to open.

**Behind a button, not on open.** Everything else on the health screen loads
when the sheet appears. This reads every file the app has ever written and
decodes all of them; doing that silently would make opening the screen the
expensive thing.

**The identity faults are on the screen and NOT in the diagnostic.** Both
disputed names are the athlete's own identifiers, and §12.7 promises the
redacted paste carries none. So the paste gets a count per fault kind and the
screen gets the names — which is also the right split for what each is for: the
paste is for asking somebody a question, and the names are for the person who
has to answer it.

## 12.16 The semantic verifier — patch 263, plan step 3.5

`migration_run` has had a `verified` state since patch 255 and nothing has ever
been able to reach it. Every successful import stops at `pending`, which the
ledger's own header called "the honest answer: the verifier is the next patch".
It was eight patches away.

**Why an import report is not evidence.** It says what the importer believes it
did, counted by the importer, from inside the transaction that did it. D7
switches the app's reads to the database on the strength of that migration
having been faithful, and "the code that wrote it says it went fine" is not a
claim about faithfulness — it is the same claim, restated.

**Four layers, cheapest first, and it never stops early.**

1. **Counts** — activities, gear, notes, weather, traces, details, zones. Each
   names its table, which is the acceptance criterion: delete a row by hand and
   exactly one of these fails and says where.
2. **Identities** — not 667 = 667, but *the same 667*. Two sets of equal size
   can disagree completely and the count layer passes on both. This is what
   catches an activity imported twice under two ids while another was dropped.
3. **Fields** — seven per activity, fingerprinted. A row that exists with the
   wrong distance passes both layers above.
4. **Domain outputs** — volume by discipline, one activity's splits, one weather
   reading. Counts, ids and fields can all agree while a figure the app *shows*
   comes out different, and those figures are the reason any of this exists.

A verifier that quits on the first mismatch answers one question when you have
several, and turns "what is wrong with this migration" into a sequence of runs.

**The expectations are derived from the stores, never from the exclusion
rules.** A weather reading, a trace or a detail is expected in the database only
if its activity is *in the store* — full stop, with no "unless
`DataCorrections` excludes it". Excluded activities never reach `ActivityStore`
(§12.12.6), so deriving the expectation from the store's own contents gets the
exclusions right without this file knowing the policy exists. **A verifier that
imported the policy would agree with the importer about anything the policy got
wrong**, which is the single class of error a verifier is for.

**`record` is the one function that must never be made convenient.** It moves a
run to `verified` and it refuses on any report that did not pass. D7 acts on
that state, and a run marked verified by something that verified nothing is the
defect this project has now found six times.

**What is deliberately absent: CTL.** The plan names "CTL on a chosen day"
among the representative domain outputs. `PMC.build` takes `[DailyLoad]`, and
the code producing those reads `Activity` values — so comparing CTL both ways
means writing a second `DailyLoad` builder against SQL, and a disagreement
between two builders is ambiguous in exactly the wrong direction: nobody could
tell whether the data diverged or the second builder is wrong. The right place
is D6 shadow parity, where the app grows a database-backed activity reader and
the *same* `PMC` runs over both sides. Recorded here rather than quietly
skipped, because a domain check the plan asked for and did not get is the kind
of gap that closes itself in a summary.

## 12.17 A save that can fail — D4 step 1, patch 264

Every store in this app has written the same way since it was built:

```swift
guard let data = try? JSONEncoder.sub4.encode(notes) else { return }
try? data.write(to: fileURL, options: FileProtection.options)
```

Two `try?`s and a `return`. A full disk, a device locked in a way that blocks
writing, a container that moved — all of them land there and do nothing at all,
and `NoteEditorView.commit()` then called `dismiss()` on the next line
regardless.

**The failure mode is not "the note was not saved".** It is worse than that. The
note *was* in memory, so the sheet closed, the list showed it, and the note
survived until the next launch read the old file back. **A note that appears and
then disappears overnight is worse than one that was refused**, because the
athlete has no reason to write it again — and no way to know they should.

**Notes first, and the reason is the same one that ordered the whole D-series.**
Every other store holds something fetchable: activities, weather, traces,
details and the profile all come back on the next sync. `notes.json` holds what
the athlete wrote. Nothing anywhere can reproduce it, and it was the least
protected file in the app.

**Memory follows disk.** `save` and `remove` roll back the in-memory change when
the write throws, so the two never disagree. That is what turns a silent loss
into a visible refusal.

**The two stages are separate because the advice is.** An encoding failure is a
defect in this app and retrying runs the same code over the same value; a write
failure is the phone, and is worth another attempt. `StoreWriteError.Stage`
carries the difference, and the alert offers **Try again** only for the second.
Offering it for the first would be a button that lies.

**And there is no "discard".** The failure alert has three actions — *Copy the
text*, *Try again*, *Keep editing* — and none of them throws the text away.
This sheet may hold the only copy of something the athlete wrote, and a single
tap that destroys it is not a button, it is a trap. *Copy the text* is
deliberately first: somewhere it can be pasted beats anything this app can
promise about its own disk.

**The shared coders went nonisolated in 264a**, which is §12.12.7 for the
second time in two days. `JSONEncoder.sub4` is a computed property building a
fresh encoder per call — nothing shared, no race to prevent — and it was
isolated only because it is declared in `NotesStore.swift`, which the build
setting isolates. `StoreWrite` takes it as a default argument, and a default
argument is evaluated at the call site, so one declaration produced three
warnings. The pattern is now familiar enough to name: **anything that is data
rather than state should say `nonisolated` when it is written, not after a
build says so.**

**What is not done yet.** Six other stores still write with `try?` —
`ActivityStore`, `AthleteStore`, `AthleteConstants`, `CommuteStore`,
`DetailStore`, `WeatherStore`, `ProposalStore`. They hold re-fetchable data, so
a lost write there costs a sync rather than a memory, and they follow in the
rest of D4. `StoreWrite.encode` is the shared piece so that each one is a small
patch rather than a rewrite.

## 12.17.1 A toggle that fails snaps back — D4 step 2, patch 265

`commutes.json` is the second store the athlete *decides* rather than receives.
§12.12.3 gave it a toggle so the commute call stopped being Strava's; 265 makes
that toggle honest about whether the call was recorded.

**The rollback is the visual revert, and that is the whole design.**
`Activity.isCommuteRide` reads `CommuteStore`, so putting the old answer back
when the write throws *is* the bicycle icon returning to its previous state.
Nothing in the view undoes anything. The alternative — a view that catches the
error and reverses its own state — would be a second opinion about what
happened, and the two would disagree the first time one of them changed.

**`clear` matters more than it looks.** Forgetting an answer returns a ride to
the distance rule, so a clear that silently did not happen leaves the athlete
believing the 10 km threshold governs a ride that still carries an override —
and the ride would look right, because the override and the rule agree most of
the time. It only shows up at the edges, which is where the toggle exists for.

**The alert is a modifier now, and `NoteEditorView` keeps its own.** A note is
text that may exist nowhere else, so its first action is *Copy the text* — an
escape hatch that only makes sense for prose. A commute decision is one bit the
athlete can set again by tapping; a threshold is a number he can retype. Those
share two sentences — what did not happen, and is it worth another go — and
writing them six times would guarantee six wordings. `storeWriteFailure` also
owns the rule that *Try again* appears only for a write failure, so no caller
can offer a retry for an encoding fault.

**265a, the callers that were missed.** `set` and `clear` became throwing and
`CommuteTests` had eighteen call sites — the app target was swept for callers
and the test target was not. Same sweep error as §12.9c, one layer over:
enumerate from the MECHANISM (every caller of a function whose signature
changed) rather than from the places you happened to be looking. The compiler
caught it, which is the good case; it is worth recording because the same miss
against a *warning* would not have been caught at all.

The teardown helper keeps its swallow, deliberately. Every call site is inside
`defer`, which cannot throw, and a failure to clean up decisions a test made is
not the thing under test — so it is `try?` in one reviewable place rather than
at twelve `defer` sites.

**A retry repeats the intent, not the inverse of the current state.** By the
time the alert is on screen the toggle shows the OLD value again, so
`!isCommuteRide` would ask for the opposite of what was wanted. The pending
value is held rather than recomputed. Small, and exactly the kind of thing that
would have worked in every test and been wrong on the phone.

## 12.17.2 The stores that write while nobody is watching — patch 266

`notes.json` and `commutes.json` are written while the athlete watches. A failed
write gets an alert, and the store rolls its memory back so the screen tells the
truth — §12.17, §12.17.1.

The other six write during a sync. Nobody is watching, there is no sheet to keep
open, and **there is nothing to roll back to**: the data came off the network a
moment ago, and discarding it would throw away a completed sync to buy a
consistency nobody asked for.

**So the rule inverts, and the inversion is the decision.** Memory keeps what
was fetched, and the disagreement with the disk is *recorded* —
`StoreWriteJournal`, one entry per store, surfaced as a red row in Settings and
a badge on the tab.

**What makes that safe rather than the defect §12.17 removed.** 264 existed
because a note could appear on screen and be gone at the next launch with
nothing anywhere saying so. The difference here is the last clause: an unsaved
store is a fact the journal holds, Settings shows and the diagnostic carries, so
"the app is showing you more than it has saved" is a sentence somebody can read
rather than a surprise at relaunch. It is also recoverable in a way a note is
not — all six hold something Strava or Open-Meteo will hand over again.

**`attempt` is non-throwing on purpose, and that is why this patch touched six
files and no callers.** These stores save from inside syncs, backfills and
detached tasks. Making `save()` throw would have pushed one decision out to
forty call sites that all want the same answer, and forty places to get it
wrong. The decision is made once: keep the memory, record the fact.

**One entry per store, and one for the whole detail batch.** A backfill writes
hundreds of files; a per-file entry would turn "is anything unsaved" into a list
nobody reads, which is the §12.12.6 failure exactly.

**`proposals.json` is the odd one, and it is here on purpose.** A monthly review
costs a model call and cannot be reproduced by asking Strava again — by that
measure it belongs with the notes. But it is written by the review runner, not
by an editor the athlete is sitting in front of: there is no sheet to hold open
and no text to copy. So it takes the journal's route, and the record stays in
memory where the export can still reach it. First real run is 24 August 2026,
and if a write fails there the unsaved row is the difference between noticing
that day and noticing next month.

**Two encoders are left bare deliberately.** `athlete.json` and `weather.json`
have always been written with a plain `JSONEncoder`, so their dates are seconds
from 2001 — `LegacyStore.dates` declares it and `AthleteFile.decoder` depends on
it. Switching them to `JSONEncoder.sub4` while sweeping would have rewritten
thirteen months of files into a shape two other files disagree with.

## 12.18 The bikes — patch 267

The import screen has reported **`Naming unknown gear: 407`** since patch 218,
against four ids: `b6932581` (287 activities), `b13458344` (60), `g15316986`
(51) and `b10348095` (9).

**Three of them are bikes, and the app has never read them.** Strava's
DetailedAthlete carries `bikes` beside `shoes`; `AthleteStore.Athlete` decoded
one of the two. Thirteen months, 356 activities, and the field was in every
response.

**No data was lost, which is why this went unnoticed.**
`activity_gear_reference` records the raw external id for every activity
whether or not it resolves — that table exists precisely so a name the source
used survives not matching anything here. What was missing was a `gear` row, so
the id had no name and no distance to aggregate against.

**A separate array rather than a `kind` on `Shoe`.** `Shoe.wear` says 600 km is
"start thinking about it" and 800 km is "past the range the literature gives".
Neither means anything for a bike. A shared type with a flag would leave a
meaningless threshold one `if` away from every caller; two arrays make the
wrong question unaskable. `allGear` exists for the callers that genuinely only
need a name for an id — the importer, the verifier, and `gear(id:)`. `shoe(id:)`
is deliberately left alone, because its callers want a shoe and would be wrong
to be handed a bike.

**`Cache.bikes` is optional, and that is not tidiness.** A synthesised
`init(from:)` does not use Swift default values, so a non-optional `bikes` would
make every `athlete.json` written before today fail to decode *entirely* —
taking the zones, the FTP and the shoe history with it. `LegacyFixtures` records
that same hazard against `constants.json`, whose `restByMonth`, `sexCoefficient`
and `version` are three properties carrying exactly this trap.

**What is left: 51.** `g15316986` is a shoe Strava no longer returns, which is
what "retired" means at the API. Fixing it needs `GET /gear/{id}` — an endpoint
this app does not have — so it is patch 268 rather than a network call bolted
onto a persisted-model change. Those 51 runs are the only ones whose distance
still counts against no shoe, and shoe wear is the one thing gear is actually
for.

## 12.18.1 The retired shoe — patch 268

§12.18 left 51 activities naming `g15316986`, a shoe in neither list Strava
returns. **That is what retired means at the API**: the athlete endpoint carries
what you own now, and a shoe you retired is gone from it along with every
reference to the runs you did in it.

`GET /gear/{id}` still returns it, and this app had never called it.

**The lookup is driven from the activities, because there is no other
evidence.** Strava will not tell you what you used to own. The only trace a
retired shoe leaves is that 51 activities name it — which is exactly what
`activity_gear_reference` was built to keep (§12.18), and this is the first
thing to read that evidence back rather than merely preserve it.

**Capped at ten per run, and the cap is not politeness.** An id that 404s —
gear deleted at Strava rather than retired — stays missing and would be asked
for on every subsequent refresh. Ten bounds that to ten wasted calls rather
than one per unknown id for ever. In practice the list is empty after the
first successful run, because the results are persisted.

**A `Shoe`, not a third kind.** A retired shoe is a shoe; its wear is the most
meaningful wear in the app, since it is the number that made it retired. What
it is not is *active*: `retired` is excluded from `activeShoes`, so it belongs
to the history and not to the rack.

**Reported apart from the two lists.** `lastOutcome` says "5 zones, 10 gear, 1
retired" rather than folding the retired count in, because it comes from a
different call. Adding it to the gear total would let a profile fetch that
returned nothing look like one that returned something — the same "one half
concealing the other" defect §12.18 and the comment above `refreshProblems`
both already carry.

**Expected after this lands:** `Naming unknown gear` reaches **0** for the
first time since the importer was written, and every one of 666 activities
that names gear resolves to a row.

## 12.19 The match decision — D4's database half, 1 of 3, patch 272

`match_decision`, `correction` and `rejection` have existed since the schema
was written and nothing has ever written to them. This is the first.

### 12.19.1 The store did not hold what the table needs

`Matcher.overrides` was `[session uid: activity id]` in UserDefaults, with `""`
for "explicitly nothing". `match_decision.decidedUTC` is NOT NULL, and the
store had no timestamp anywhere — so this is not an import that was waiting to
be written, it is a store that had to learn a fact first.

`CommuteStore` reached the same conclusion in patch 251 and its header says so
in as many words: *"A decision carries its date. Not decoration: the
`correction` table in ADR-0003 §8 wants provenance for exactly this kind of
row, and a decision with no timestamp cannot be reconciled against a later
one."* This is that argument applied to the older of the two stores.

**`""` becomes a real absence.** The empty string existed because a
`[String: String]` in UserDefaults has nowhere to put one.
`match_decision.activityID` is nullable, so both sides can now say it properly.

### 12.19.2 It stays in UserDefaults, and that is the decision

The obvious move is to follow `commutes.json` into Application Support. It is
the wrong move here, and the reason is the ladder: D5 takes what is left in
UserDefaults into typed rows, D7 makes the database authoritative, D8 removes
the JSON writers. **A new JSON store two rungs before the JSON stores are
retired is building something already scheduled for demolition** — and it would
cost the whole legacy-fixture sweep (`LegacyStore`, `LegacyInput`, the
classifier, the reader, the snapshot inventory) to carry a file for three
patches.

**The honest cost, stated rather than skipped.** A `UserDefaults.set` has no
failure to report, so this is the one authored store with no failable-save
path. §12.17's rule is that a write with somebody watching must not report
success it did not have; there is no API to ask UserDefaults whether it
succeeded, so the rule cannot be applied here and is not pretended at. It
becomes applicable at D5, in a transaction. `DataLifecycle`'s gap list now says
this rather than the older, vaguer version.

### 12.19.3 The migration invents a date and admits it

Decisions already on the phone have no timestamp anywhere. The migration stamps
them with the instant it ran and sets `dateIsKnown` to false.

The alternative was to use the planned session's date, which is *plausible* and
is a different fact wearing this one's clothes — the session happened on the
12th; the athlete may have corrected the match in March. This project has
refused that trade twice before (§12.10.3's provenance column, §12.12.5's
apportionment) and refuses it again.

`match_decision` has no column for the distinction, so it lives in the store
and in the import's counters rather than in the table. **That is the right
place for it**: the table records what was decided, and `dateIsKnown` is a fact
about our knowledge of the record, not about the decision.

### 12.19.4 Three outcomes, and one of them writes nothing

| What the store holds | What the table gets |
|---|---|
| an activity id that resolves | the row, with the canonical id |
| explicitly nothing | the row, with NULL |
| an activity id that does not resolve | **no row**, and `matchDecisionsUnresolved` |
| an activity `DataCorrections` excludes | no row, and `matchDecisionsIgnored` |

The third line is the one worth arguing. Writing it with a NULL is easy and the
column allows it — but NULL already means *the athlete said nothing satisfied
this session*, so reusing it would make the database state something he never
said. A held-back row leaves the database silent and a counter loud, which is
the trade §12.9d made when neither name could win.

The fourth is patch 257's rule applied to a third store: an override of an
excluded recording is the exclusion working, and it is never counted as *seen*,
because "seen" means work attempted.

**The verifier had to learn the same rule.** `expectedDecisions` filters by
`storeIDs` exactly as weather does — otherwise a device carrying one stale
override would report a permanent disagreement it could do nothing about, and a
verifier with a known-benign failure is a verifier nobody reads.

## 12.20 A store that could not be read must not look empty — patch 273

### 12.20.1 What the device showed, and what it proved

Patch 272 landed clean: 15 comparisons, all agreed, `match_decision` correctly
empty. Then the table counts were read, and `review` still held **1**, with
`review_evidence` 1, `proposal` 1, `proposal_change` 2, `proposal_watch` 2 —
the rehearsal record from patch 269, **deleted from `proposals.json` on 5
August and still in the database**.

The cause is general and was found by grep rather than by guess. Every `DELETE`
in the six importer files is a *replace-the-children-of-this-parent* delete:
zones, a review's evidence and proposal, a trace, a detail, an activity's gear
references. **Nothing anywhere reconciles a record that has disappeared from a
store.** So:

| the athlete does this | what the database does |
|---|---|
| *Back to automatic* on a match | keeps the `match_decision` row. Verifier: expected 0, found 1, **permanently** |
| deletes a note | keeps the `user_note` row. Same |
| deletes a review (patch 270) | keeps all five rows, and the verifier does not check reviews at all |

`ReviewDue` reads `ProposalStore` and not the database, so the 24 August date
is unaffected. What is left is a ghost that will sit beside the first real
review and look like a second one.

**Patch 270's delete button is the fourth control this project has found
reporting work it did not do.** It dismisses the sheet, says the review is
gone, and leaves half the record behind.

### 12.20.2 Why the obvious fix could not be built

The reconciliation pass is four `DELETE … WHERE key NOT IN (…)` statements. It
was not built, because of what the stores look like when they fail:

```swift
guard let data = try? Data(contentsOf: fileURL) else { return }
notes = (try? JSONDecoder.sub4.decode([String: Note].self, from: data)) ?? [:]
```

Two `try?`s, and **neither can tell "there is no file yet" from "the file is
there and will not decode"**. Both produce an empty store, with no error, no
row and no log. A reconciliation pass reading that state would delete every
note, every review and every match decision from the one copy that was still
intact — turning a corrupt file into permanent data loss, in the patch whose
purpose is to make the database trustworthy.

§12.9c already built a classifier that tells those conditions apart. It runs
from a button on the Database screen and **has never been in the launch path**.

### 12.20.3 Three outcomes, and only one of them is a refusal

`StoreLoad` is `.loaded`, `.absent` or `.unreadable`. `isTrustworthy` is true
for the first two.

**Absent is not a failure, and saying so is the point.** Every fresh install
has no `notes.json`; §12.9e found `proposals.json` legitimately missing on the
real device because no review had ever run. A journal that shouted about those
would be one the athlete learns to ignore, which is how the entry that mattered
would be missed.

**A zero-byte file is unreadable, not absent.** That is what an interrupted
write leaves behind — §12.9c's `truncated` condition at its limit — and calling
it "you have nothing" is the same mistake in miniature.

### 12.20.4 The gate fails closed

`StoreReadJournal.canReconcile(_:)` requires every named store to have
*reported* something believable. A store that never recorded an outcome is not
trustworthy.

That default is the whole design. Treating silence as success would make
forgetting to wire a store into the journal look exactly like wiring it in
correctly — and the failure would appear as rows quietly disappearing, months
later, with the control that did it reporting a clean run.

### 12.20.5 The read journal is not the write journal's mirror

`StoreWriteJournal` says *the app has more than it saved*. Everything it lists
is re-fetchable, so it is a warning, and a successful write clears it.

This one says *the app has LESS than it holds* — which is the worse of the two
and previously had no way to be said at all. Nothing clears it during a
session, because each store reads once at launch; the entry stands until the
next launch reads the file again.

Only the four AUTHORED stores are instrumented: `notes.json`,
`proposals.json`, `commutes.json`, `match.decisions`. The fetched stores are
deliberately left out — they can be asked for again, and 274 reconciles only
tables the athlete can delete from.

### 12.20.6 A comment that was true for one patch

`Matcher.load` carried *"there is nowhere to report it from here — see the
header on why this store has no journal"*. Written in 272, false in 273.
Corrected in place rather than deleted, because the distinction it was reaching
for survives: this store still has no WRITE journal, since `UserDefaults.set`
has no failure to report. A read that found something it could not use is a
different fact, and it has somewhere to go now.

## 12.21 What the athlete deleted — D4's database half, 3 of 3, patch 274

§12.20.1 recorded the finding: the importer is additive-only, and the rehearsal
record deleted from `proposals.json` was still in the database. This is the
pass that removes it, and 273 is the reason it can be trusted to.

### 12.21.1 Three tables, and the list is short on purpose

`user_note` and `match_decision` by `planSessionUID`; `review` by `ranUTC`,
which takes `review_evidence`, `proposal`, `proposal_change` and
`proposal_watch` with it through foreign keys that already said
`ON DELETE CASCADE`.

**Nothing fetched is reconciled.** Activities, gear, weather, traces, details,
the plan and the profile are left alone, because for those an empty store means
a sync that has not run rather than a decision to remove something — and the
athlete cannot delete them one at a time in the first place. A pass that read
"Strava is unreachable" as "the athlete deleted 668 activities" would be the
worst defect this project has shipped.

### 12.21.2 The gate carries a reason, not a Bool

`Reconciliation` is `.run` or `.skipped(String)`. The health screen prints the
reason.

A Bool would have made **"a store could not be read"** and **"the caller did
not ask for it"** the same word — and those are opposite facts. The first is
the gate working. The second is a bug in the call site, and it would have been
invisible behind a screen reading *Reconciled: no* for months.

The default is `.skipped("the caller did not ask")`. **A forgotten argument
leaves rows behind**, which is the status quo, visible on the health screen and
now caught by the verifier. A default that deleted would delete in the one call
site nobody thought about.

The gate is computed by the caller: `Sub4Import` is `nonisolated` end to end
and `StoreReadJournal` is on the main actor. That constraint turns out to be
the right shape anyway — the decision to delete belongs to the screen that
knows what was read, not to the code doing the deleting.

### 12.21.3 A held-back decision is not a deletion

The pass keeps by the STORE's uids, not by what the import managed to write.
A match decision naming an activity that is not here is held back by §12.19.4
and writes no row — and its uid is still in the store, so the pass leaves the
existing row alone. Reading "no row was written" as "he deleted it" would let a
temporarily missing activity silently destroy a correction.

### 12.21.4 Row by row, which is not the obvious SQL

`DELETE … WHERE key NOT IN (…)` is one statement and shorter. It also cannot
express an empty keep-set without special-casing into `DELETE FROM …` — the
most dangerous statement in the file, written as a fallthrough — it binds one
parameter per record against a limit that is a build setting of SQLite rather
than a promise, and it cannot count what it removed. Fetching the keys and
deleting by id costs one extra read on tables holding single digits.

### 12.21.5 The verifier should have compared reviews since 263

It has compared notes since the day it was written. It has never compared
reviews. So on 5 August the rehearsal was deleted from the store, stayed in the
database, and the next run reported **fourteen comparisons, all agreed,
verified** — with the one store in this app that cannot be re-fetched being the
one nothing was checking.

It counts the parent only. The four children are reachable from it and cascade
with it; counting `proposal_change` would assert the shape of somebody's review
rather than that the review is there.

**This is the fifth control this project has found reporting work it did not
do**, and the second in two days: patch 270's delete button dismissed the sheet
and left half the record behind, and the verifier said everything agreed while
looking away from the table that disagreed.

## 12.22 Where the sync has got to — D5 slice 1, patch 275

`strava.cursor` and `strava.lastSync` are two preference keys holding the
position of a sync that has run 668 activities through it. `sync_state` has had
a row waiting for them since the schema was written.

**Nothing moves.** The keys stay where they are and stay authoritative — D7 is
where the database starts being read. This copies, exactly as every other
importer does.

### 12.22.1 The column is opaque, so the epoch goes in verbatim

§8's own comment settles it: *"Strava's cursor is an epoch and Health's is an
anchor; a column typed to one of them would be a transport shape."*

So the `Double` is rendered by Swift's shortest round-tripping description and
stored as that string. Reformatting it to ISO-8601 would be more readable and
would be this app inventing a representation for a value it does not own — plan
step 3.6.3 asks for *"an exact source timestamp rather than something
reconstructed"*. `theCursorSurvivesTheRoundTripExactly` is the test that keeps
it honest.

### 12.22.2 The app's cursor stopped being a cursor in patch 249

Recorded here, where the value is copied, rather than only where it is
computed.

`ActivityStore.cursor` used to be the query bound: `after=` filtered by START
date, so any activity uploaded late was skipped **for ever**. 249 made the read
unconditional. The variable survives as a **high-water mark** — the instrument
for detecting the very problem it used to cause — so what lands in this column
is *the latest start we have seen*, not *where the next request begins*.

**The column name predates that change.** It is not renamed, because a
migration is history; it is explained instead. Anything reading `sync_state` at
D7 needs to know which of the two it is holding.

### 12.22.3 `lastResult` holds a problem, and NULL means there wasn't one

Writing `"ok"` on success would be inventing a word the app never said in order
to fill a column. *Whether a sync ran* is `lastSyncUTC`'s job — a non-null
timestamp with a null result is a clean sync, and both facts stay separable.

**`lastGateNotice` is deliberately excluded.** §179 separated a deliberate
refusal from an outage because a closed gate is not a broken connection, and a
closed gate means the sync did not run — which `lastSyncUTC` already says by not
moving. Folding the two into one column would put the distinction back where
179 took it out of.

### 12.22.4 The verifier compares the cursor, not the row count

`sync_state` holds exactly one row per source, so a count check would compare 1
against 1 and agree while the cursor inside it was a week out. **A cursor a week
out is what D7 would resume from**, and the activities in between would be
skipped — the 249 defect, arriving a second time through a different door.

So this check is its own layer: it reads the string back and compares it to the
string the store rendered. `theVerifierCatchesADriftedCursor` proves it can
fail, which is what makes it agreeing worth anything.

### 12.22.5 What D5 still has

`work_queue` (`detail.failed`, `detail.noStreams`, `weather.unavailable`),
`content_revision` (the store schema versions and the four backfill flags),
`rejection` (`strava.rejectedByRule` — prose where the table wants columns, so
`ActivityStore` needs reshaping exactly as `Matcher` did in §12.19),
`lifecycle_event` / `lifecycle_line` (export and disconnect receipts, which are
not in UserDefaults at all and currently persist nowhere), and
`review_evidence_source`.

**Four preference keys are staying.** `appearance.selected`,
`discipline.selected`, `volume.unit` and `zones.window` are display settings,
not data — they describe the reader, not the training. D5 is not "empty
UserDefaults"; it is "get the DATA out of UserDefaults".

## 12.23 What the app has stopped asking for — D5 slice 2, patch 276

### 12.23.1 Neither set is a retry queue, and that changed the patch

`detail.failed` and `detail.noStreams` look like a retry queue from their names
and from the table they were headed for. `DetailStore` says otherwise:

- **`failed`** — ids Strava answered **404** for, deleted or private. The
  declaration's own words: *"Never retried automatically — otherwise a single
  dead id burns a queue slot on every launch, forever."*
- **`noStreams`** — 200 with nothing usable, or a 404 on the streams call. A
  manual entry, or an indoor session with no distance track.

**Both are terminal verdicts, not work waiting to happen.** A transient
failure — a timeout, a 429, a closed gate — is never persisted at all: it
returns `.transient` or `.stop` and the id goes back into an in-memory queue
rebuilt from scratch every launch.

So there is no attempt count to carry and no backoff to preserve. **A note
earlier in this session said `DetailStore` would need reshaping first, the way
`Matcher` did in §12.19, and that it would take two patches. It was wrong** —
written from the key names and the column names before the store was read. One
patch, no reshape.

### 12.23.2 `noStreams` is `done`, not `failed`

| store | kind | state |
|---|---|---|
| `detail.failed` | `detail` | `failed` — the fetch did not produce what it went for |
| `detail.noStreams` | `stream` | `done` — the fetch SUCCEEDED and there was nothing there |

Filing `noStreams` as a failure would report a fault where the source simply
had nothing to give. `done` means the queue is finished with the item, which is
true of both, and the difference between them survives in `state`.

*(This paragraph originally predicted 23 rows. See §12.23.7 — the device wrote
two.)*

### 12.23.3 `attempts` is 1, and 1 is a floor

An id reaches either set by being asked for at least once — that is the only
way in. The app has never counted, so 1 is the minimum known to be true rather
than a number invented to fill a column. Recorded because a reader would
otherwise take it for a measurement.

### 12.23.4 `createdUTC` is when the database learned, not when the fetch happened

Neither set records a time and nothing else in the app remembers. §12.19.3
refused to invent a date for a match decision; **this is the case where the
same trade goes the other way**, and §8's own group 9 header is the licence:
*"Bookkeeping, not history. Everything here can be thrown away and rebuilt by
re-syncing."* The column says when the ROW was created, which is exactly what
is being recorded, and losing the real time costs a re-fetch rather than a
fact.

### 12.23.5 This importer prunes, and §12.21 refused to

It owns `detail` and `stream` entirely and receives the complete set every run,
so an id no longer present has genuinely been forgotten — by `resetCache`, or
by a schema bump clearing the cache. Those rows are deleted.

Safe here for two reasons that did **not** hold for notes:

1. The source is a `UserDefaults` string array with **no decode step**, so
   "empty" cannot mean "unreadable" the way a corrupt `notes.json` can. The
   failure mode §12.20 was built to catch does not exist on this path.
2. The whole table is rebuildable by re-syncing, so the worst case is a
   re-fetch rather than a loss.

A row with a NULL subject is left alone: this importer claims only rows it
could have written.

### 12.23.6 A key the inventory claimed and the app deletes

`weather.unavailable` was listed in `DataLifecycle` as preference storage under
the weather category, and asserted in `everyPreferenceKeyIsCovered` as a key
the app writes.

**The app has deleted it on every launch since patch 130**, which stopped
persisting the weather failure set — `WeatherStore.init` removes the key so a
phone that ran 128 or 129 is not still carrying its verdicts.

Both are corrected. Worth its own subsection because of where it was: the data
inventory is the one document in this project whose entire job is to be true
about where data lives, and it named a key this app exists to remove.

### 12.23.7 The device said 2, and the difference is a third state — patch 276a

668 activities, 668 details, **645 traces**. Twenty-three have no trace, and
§12.23.2 said filing them as failures would report a fault against all
twenty-three. The first import wrote **two rows**.

**The other 21 were never asked.** `DetailStore.needsStreams` opens with
`a.distance >= minStreamDistance`, and `minStreamDistance` is 500 m. A strength
session is 0 m; so is a manually logged swim. Those activities are not in
`failed` and not in `noStreams` because nothing ever went and looked.

So there are three states and the table holds two:

| | in `work_queue` |
|---|---|
| asked, refused (404) | `detail` / `failed` |
| asked, nothing there | `stream` / `done` |
| **never asked — under 500 m** | **no row** |

`work_queue`'s states were frozen by migration 2 and cannot be added to. Of the
four, `done` would claim work happened and `pending` would claim work is
coming; neither is true. **No row is the honest answer** — but it leaves a gap
that is real and currently invisible: twenty-one activities have no trace, no
verdict, and nothing anywhere saying why.

That is a violation of the standard set on 5 August — *"every counter on the
health screen reads zero or has a decision beside it, so the next entry in any
of them is news."* `recording: 645` against `activity: 668` is a counter with
no decision beside it.

**And the number that would explain it has no caller.**
`DetailStore.backfillRemaining` is `pending.count`, written for a screen that
was never built. It is the second method found this week that compiled, was
correct, and did nothing — §12.8.4 recorded the first. Until something shows
it, "never asked" and "queued and not yet reached" are indistinguishable from
outside.

**The wider lesson, and it is the same one as §12.23.1.** That section already
records getting this patch's shape wrong by reading key names instead of the
store. The correction was written from `DetailStore` — and then a number was
predicted from arithmetic on two other counters rather than from the code that
produces it. Reading further would have found the 500 m line: it is nine lines
below the one that settled the earlier question.

### 12.23.8 The 23 get a decision beside them — patch 277

§12.23.7 recorded a counter with no decision beside it: `activity: 668` and
`recording: 645`, four lines apart, difference unaccounted for. Finding out
what the difference was took reading `DetailStore` — which is not a thing a
number on a screen should require.

**It is an account, not five numbers.** Every activity lands in exactly one
bucket, in a fixed order, and the buckets sum to the total:

| bucket | why |
|---|---|
| has a trace | it is here |
| the source refused it | 404, `DetailStore.failed` |
| asked, nothing there | `DetailStore.noStreams` |
| under 500 m, never asked | `needsStreams` requires `minStreamDistance` |
| queued, not yet reached | in `pending` |
| **unexplained** | none of the above |

**The order is the definition.** A trace that arrived outranks every reason it
might once have been absent — those reasons are stale the moment the data
lands. A refusal outranks an empty answer, because a 404 stops the detail fetch
before the stream fetch is reached. The distance rule outranks the queue,
because an activity under the threshold is never queued at all.

**`unexplained` is the only line worth watching**, and it is why this is an
account rather than a list. Five counters can each be correct while the set of
them is missing a case; a residual that has to make the total add up cannot
hide one. It is zero today. The day it is not is the day an activity has no
trace for a reason nothing in this app has a name for.

**`pending` gets its first reader.** `backfillRemaining` has been
`pending.count` since it was written and nothing ever showed it — the second
method-written-in-anticipation found this week, after §12.8.4's. Until now
"never asked" and "queued and not yet reached" were indistinguishable from
outside `DetailStore`, which is exactly the ambiguity that made §12.23.7's
prediction wrong.

**Pure, so it can be tested.** `DetailStore` is a singleton over the real disk;
a classifier that read it directly could only be exercised by arranging the
athlete's actual files. `TraceCoverageReport.classify` takes its inputs, the
store supplies them in one line, and `theDeviceShapeAddsUp` reproduces the 5
August device — 645 traces, 2 answered empty, 21 under the threshold — as a
fixture, so the arithmetic §12.23.7 corrected is checked rather than asserted
in prose.

## 12.24 What a rule threw away — D5 slice 3, patch 278

`ActivityStore.rejected`'s declaration already said why this table matters: *"A
rejected activity is not written to activities.json and the cursor moves past
it, so after one launch there is nothing left in the app that remembers it
existed. A rule that silently deletes data is worse than the data it deleted —
this is the receipt, and Settings prints it."*

It was stored as a rendered sentence:

```
2025-04-12 Evening Ride — 41.3 km in 22:14 = 111 km/h avg, max 19
```

Every column `rejection` wants is in there, and **none of it is a field**.

### 12.24.1 The store learns the shape; parsing was the wrong answer

Reading the four values back out of that sentence would be inventing structure
out of prose — and it would work, until a name contained an em dash. So this is
§12.19's shape again: the STORE gains a record, and the import becomes the easy
half.

`RejectionReceipt` carries the rule, the instant, the name, the day, the
distance, the elapsed seconds, and the rendered line kept verbatim.

**`ActivityStore.rejected` is now computed and every reader is unchanged.**
`SettingsView` prints the same lines it always did; what changed is that the app
knows what is inside them.

**The receipt is made at the only moment it can be.** `recordRejections` has
the `Activity` in hand — and that is the last time anything will, because the
next save writes it out of `activities.json` for good.

### 12.24.2 A migrated receipt says what it does not know

The retired shape stored no timestamp and no fields, so a receipt built from one
carries `dateIsKnown == false` and NULL for name, day, distance and duration.
Those four columns are nullable. The two that are not can both be supplied
honestly:

- **`rule`** — there has only ever been one, `selfContradictoryDistance`, so
  naming it is a fact rather than a guess. `oneRuleOnly` pins that: a second
  rule would make this migration wrong, and it cannot be re-run.
- **`noticedUTC`** — the migration instant, disclosed by `dateIsKnown`.

§12.19.3 refused to invent a plausible date; §12.23.4 accepted one. **This is
the first case, not the second** — §8 groups `rejection` with the authored
tables, and it outlives the activity it describes, so it is history rather than
bookkeeping.

### 12.24.3 It references no activity, and the verifier must not either

`rejection` has foreign keys to `account` and `source` and **none to
`activity`**, deliberately: the row is about a recording the database refuses to
hold.

That makes its count check different from weather's and the traces'. Those
filter by `storeIDs`, because a reading about an absent activity is the schema
correctly declining. Filtering here would expect **none of them**.

### 12.24.4 Nothing prunes this table, and that was checked rather than assumed

`resetCache()` clears activities, the cursor and the last sync — and not the
receipts. `dropInMemory()` clears them in memory without writing. Only
`DataLifecycleCoordinator.deleteEverything` removes the key, and that removes
the database in the same breath.

So a receipt never disappears from the store while its row survives, and
§12.21's reconciliation problem does not arise. Recorded because the opposite
was assumed while this patch was being designed, and reading `resetCache` is
what settled it — the third time in two patches that a claim was corrected by
reading the code that produces it.

### 12.24.5 Two lines the sweep missed — patch 278a

Patch 278 did not build. Both failures are rules this document already states,
and both are worth recording at the point they were broken rather than only at
the point they were written down.

**1. The sweep pattern was narrower than the sweep.** `rejected` went from a
stored property to a computed one, so every WRITE to it had to move. The search
used was `\.rejected\b` — which requires a dot, and `dropInMemory()`'s
`rejected = []` has none. The rule says *"enumerate every USE of every value
whose type changed"*; a member-access pattern finds reads and misses
assignments. **Grep for the bare identifier, then filter.**

Worse: `dropInMemory` had already been read aloud in the same session, while
establishing that nothing prunes this table. It was looked at for one question
and not remembered for the other.

**2. `a.km` is main-actor and `a.distance` is not.** `Activity` is a plain
`struct`, so the type is main-actor by default; its stored properties are
implicitly nonisolated and its computed ones inherit the isolation unless they
say otherwise. `dayKey` says `nonisolated` — two lines above `km`, which does
not.

`rejectionLabel` was a `private static func` on a main-actor class and could
read `km` freely. Moving it onto a `nonisolated struct` changed that, and
nothing in the move signalled it. This is §12.17's isolation lesson for the
fourth time, and the shape is always the same: **code that moves from an
isolated home to a nonisolated one inherits nothing and must be re-read line by
line, not just re-indented.**

### 12.24.6 A migration may lose the old shape; it may not lose the data — patch 278c

Both key migrations written in this session — `match.overrides` →
`match.decisions` in 272, `strava.rejectedByRule` → `strava.rejections` in 278 —
were written this way:

```swift
receipts = RejectionReceipt.migrate(legacy)
persistRejections()                            // silently returns on failure
UserDefaults.standard.removeObject(legacyKey)  // ...and the old copy is gone
```

An encode that fails leaves the records in memory for that launch and gone at
the next, with the only other copy already deleted.

**The reasoning that produced it is the reasoning to distrust.** Both `persist`
functions carried a comment saying encoding four scalars has no realistic
failure and there is nowhere to report one to. Both halves are true. Neither is
a reason to delete the fallback: the cost of keeping a retired key one launch
longer is a dead preference; the cost of the write not landing is authored data
with nowhere to come back from — §12.8.1, again.

`persist()` now returns a `Bool` and the migration is guarded on it. Exactly
one caller reads the value; every other discards it, which is §12.17.2's
position unchanged.

**Caught before the second one ran.** The match-decision migration had already
executed on the device with zero entries, so nothing was at risk. The rejection
migration had not — it was found while writing the instructions to install the
build that would have run it.

## 12.25 Two answers to one question — patch 279

`ContentView.settingsBadge` and `SettingsView.needsAttention` both answer "is
something wrong that the athlete can act on". **Patch 273 added
`StoreReadJournal.hasUnreadable` to the second and not the first.**

So a store the app could not read lit the row **inside** Settings and not the
badge whose entire job is to send somebody there. The badge's own comment
argues against that: *"if the token expires and nothing says so, every session
quietly renders as not-done and it reads as missed training rather than as a
broken sync. It is an alarm, not a status display, and it sits on the tab that
can fix it."* A store showing LESS than it holds is exactly that alarm, wired
to the quieter of the two places.

**A test would not have caught it.** Both expressions were correct in
isolation; what was wrong was that there were two. So the fix is a shape rather
than an assertion: one function, two callers, and a fifth condition can no
longer be added to one and forgotten in the other.

**It takes its inputs rather than reading the singletons.** Two reasons, and
the first is not stylistic: each caller observes its own `StravaAuth` and
`ActivityStore`, so reaching for `.shared` inside `AppHealth` would bypass
SwiftUI's observation and stop the badge updating when the state changed. The
second is that four `Bool` parameters are testable, and the two `private var`s
on two `View`s it replaces were not — `AppHealthTests` is the first coverage
this rule has ever had.

**Found from the device, again, and not from the code.** A red `1` appeared on
the Settings tab between two imports and cleared on its own — almost certainly
`activities.lastError` from a sync that failed and then succeeded, which is a
value held only in memory and recorded nowhere. Looking up what the badge
actually reads is what surfaced the divergence. The transient itself remains
untraceable by design; that is a separate gap and is not closed here.

## 12.26 Which rides are commutes — D5 slice 4, patch 280

### 12.26.1 The only source that needed no reshape

`match_decision` needed a date the store did not have (§12.19). `rejection`
needed six fields hidden inside a rendered sentence (§12.24). `commutes.json`
needed nothing, and patch 251's header says why:

> *"A DECISION CARRIES ITS DATE. Not decoration: the `correction` table in
> ADR-0003 §8 wants provenance for exactly this kind of row, and a decision
> with no timestamp cannot be reconciled against a later one."*

That was written seven weeks before this importer existed. **It is the only
place in this project where a store was built for a table that had not been
filled yet and turned out to fit on the first try** — and the reason it fit is
that somebody read §8 before designing the store rather than after.

### 12.26.2 `reason` is provenance here, not an argument

§8 makes the column NOT NULL because *"every correction in the app today
carries a written reason — 'chip time, official results' — and one that does
not is indistinguishable from a mistake."* Every correction *at that time* was
a `DataCorrections` entry, where the reason is the case for overriding a
recorded number.

A commute decision has no such case and needs none. §12.5's position is that
the commute **is** the athlete's decision — *"not Strava's and not a
threshold's"* — so the answer is not evidence for the correction, it is the
correction. `"The athlete's own answer, given on the ride."` states where it
came from, which is the only thing there is to say and is true of every row.

**What was deliberately not written there.** The richer version — *"the athlete
said commute; the distance rule said otherwise"* — is computable from
`Activity.commuteByDistance`, and would bake today's `MatchRules.minRideKm`
into a stored sentence. Change the threshold next year and every historic
reason becomes a claim about a rule that no longer exists.
`CommuteStore.overrides(in:)` computes that comparison live, which is where a
moving rule belongs.

### 12.26.3 The prune claims one field, and waits for a full accounting

`CommuteStore.clear(_:)` is reachable — *"I have no opinion"* is a real answer,
distinct from `false` — so rows go stale and this importer prunes.

Two limits, both load-bearing:

1. **It claims only `field = 'isCommute'`.** `DataCorrections` will land in
   this same table later and those rows are not ours to delete.
2. **It runs only when `correctionsUnresolved` and `correctionsIgnored` are
   both zero.** The keep-set is built from the ids that RESOLVED, so a decision
   the database cannot place cannot protect its own row. One unaccounted ride
   holds the whole prune back — including rows the resolved set would have
   spared. That is §12.20's hazard wearing different clothes, and the guard is
   the same answer: **do not delete on the strength of an incomplete reading.**

### 12.26.4 Filtered by `storeIDs`, and the line above it is not

The verifier's correction check filters by the activities the store holds. The
`rejection` check, one line above it, deliberately does not.

They look alike and mean opposite things: **a correction is about an activity
the database holds; a rejection is about one it refuses.** Filtering the second
would expect none of them; not filtering the first would expect corrections for
rides that are not there.

### 12.26.5 The row is named for what it holds today

`Commute decisions`, not `Corrections`. When `DataCorrections` reaches this
table the row will be counting two different things, and a label that already
said "Corrections" would quietly start being wrong instead of visibly needing a
change.

## 12.27 The inventory said it was empty — patch 281

### 12.27.1 What was actually declared

`DataLifecycle.swift`'s `.database` entry, at patch 280, on a phone holding 51
tables and roughly 212,297 rows:

- `whatItIs`: *"Today it holds no training data at all — only an empty schema."*
- `lineage: [.device]`
- `onStravaDisconnect: .keep(why: "it is empty…")`

Three statements, all false, and the third one load-bearing: the entry exempted
itself from a disconnect **on the strength of the first two**.

The entry predicted its own correction. Its gap read *"When step 3.4 moves the
stores into it, this entry's lineage, export rule and disconnect rule must all
be rewritten."* Step 3.4 ran across patches 265–280. Nothing rewrote it, because
nothing was watching.

### 12.27.2 The failure is a class, not an incident

`DataLifecycle.swift`'s header states the rule it broke: *"It describes what the
app does, not what it should do."* The file is scrupulous about this — several
categories are handled worse than their stated policy and each says so.

What it had no defence against was the opposite drift: a statement that was true
when written and became false while nobody was reading it. Recording a gap makes
a known shortfall visible; it does not make the arrival of the fix detectable.
**A prediction is not a trigger.**

This is the same shape as §12.25's two-answers-to-one-question: correct code,
correct at the time, with no mechanism to notice a change elsewhere. The answer
is the same in kind — couple the claim to the thing that would falsify it.

### 12.27.3 The entry was not unguarded. It was guarded by the wrong kind of test.

This is the part worth keeping. **Two tests already existed for exactly this
entry, written for exactly this eventuality, and both passed the whole way
through 3.4.**

`DatabaseTests.emptinessIsDisclosed` asserted `entry.lineage == [.device]` and
that a gap named "3.4", under a comment saying it was *"what makes somebody
rewrite the entry rather than leave the old sentence in place"*.

`DataLifecycleCoordinatorTests.theDatabaseExemptionExpiresWhenItHoldsSomething`
guarded on `lineage != [.device]` and was titled *"THE TRAP THAT MAKES THE
EXEMPTION ABOVE SAFE"*, closing with *"a sentence in ADR-0003 §9.4 relies on
somebody rereading ADR-0003 §9.4."*

Both were pinned to **the declared value**, not to reality. So the only way
either could fire was if somebody had *already* corrected the entry — at which
point the test's job was done by the person it was supposed to prompt. A test
that pins a description keeps the description; it does not keep it true.

The distinction is not subtle once stated, and it is easy to write the wrong
one while believing you have written the right one — both of these read, in
their own comments, as though they were traps. **The test for a trap is: name
the event that should spring it, and check that the assertion reads something
that changes when that event happens.** `lineage == [.device]` does not change
when the importer runs. `migrationFailureBlocksTheApp` does change when a store
starts reading from the database, and it changes *by a person's deliberate
act*, which is the second property a trap wants: it fires in front of somebody
who is already thinking about the thing.

Both tests are replaced in this patch rather than deleted, and both are
re-aimed at that flag.

**A footnote on the export one.** Left as written it would have failed under
this patch — for the wrong reason. The export writes JSON out of the stores,
and the stores are still the originals; the database holds a copy, and omitting
a copy omits nothing. Its premise — *"an export that omits the database omits
everything"* — becomes true when the database holds the ONLY rows, not when it
holds rows. A failing test whose premise is wrong is worse than no test, because
the fix it invites is to make the app satisfy it.

### 12.27.4 `.removeEverything` is right, and only while this is a copy

The softer fix was to reword the `.keep`. That leaves 212,297 Strava-derived
rows on the phone of somebody who has just read a receipt saying their Strava
data was removed. It is the same falsehood, better written.

While nothing reads the database, `.removeEverything` is correct on all three
axes that matter:

1. **Harmless.** No screen reads it. The migrator rebuilds an empty schema on
   the next launch in milliseconds.
2. **Honest.** Every row in there today is Strava-derived, weather, or authored
   *about* Strava data, and after a disconnect none of it should survive.
3. **It sweeps the snapshots.** `.snapshotDirectory("snapshots")` sits in the
   same entry and holds *"copies of everything above"* — legacy inputs captured
   before decode. It had survived every disconnect until now. Second retention
   hole, same entry, closed by the same edit.

It becomes **wrong** the day a kept category's data lives only in the database.
The entries above promise that session notes, corrections and review verdicts
survive a disconnect; a whole-folder delete would break all three.

### 12.27.5 The trigger, and why it is that flag

`Sub4Launch.migrationFailureBlocksTheApp` is already this project's declared
marker for the moment the database stops being a copy: *"IT MUST BECOME `true`
IN 3.3.3, the moment the first store reads its data from the database instead of
from JSON."* It is a stored constant specifically so that flipping it is a
deliberate act.

So the test reads it:

```swift
if Sub4Launch.migrationFailureBlocksTheApp {
    #expect(db.onStravaDisconnect != .removeEverything)
} else {
    #expect(db.onStravaDisconnect == .removeEverything)
}
```

**The act that makes the row-level disconnect necessary is the act that fails
the suite.** No calendar reminder, no item in a handoff that ages out — the
person activating the reads is the person told what they now owe, at the moment
they can least talk themselves out of it.

This is preferable to a date-based or patch-numbered check for the reason patch
272a established: a test that cites a patch number is policing bookkeeping. A
test that cites a behaviour is policing behaviour.

### 12.27.6 The lineage is held to a union

`lineage` has to stay a literal — an entry cannot read the array it lives in.
So `DataLifecycle.databaseContributors` lists the categories that write rows,
and `databaseLineageIsTheUnionOfItsInputs` holds the literal to the union of
their lineages plus `.device` for `migration_run`.

Two decisions inside that:

- **`.database` is not in its own contributor list.** It would make the
  assertion circular — the value under test would be one of its own inputs, and
  any superset would pass. `.device` is added explicitly instead.
- **`.trainingLoad` is not in it either**, because it stores no rows. The curve
  is computed; comparing it both ways is deferred to step 3.6 (§12.16).

The union at patch 281 is all six sources. That is not an artefact of being
generous — it is what "one database holds everything" means, and six sources on
the privacy pane is the correct disclosure rather than an embarrassing one.

### 12.27.7 The gap this patch opens rather than closes

A disconnect now removes the database folder while GRDB still holds the file
open. SQLite keeps working against the unlinked inode, so the rows survive until
the app is quit. Harmless while nothing reads them, and dishonest the moment
something does — so it is recorded as a gap against step 3.7 rather than fixed
here. Closing it means a real `close()` on `Sub4Launch.database`, which is a
change to a `private(set)` lifecycle and does not belong in a patch about prose.

## 12.28 Does Health hold the history — 4A M0, patch 282

### 12.28.1 The question nobody had asked

ADR-0002 retired Strava and made Apple Health canonical in one decision, and
its third follow-up says: *"Measure Apple Health coverage back to 1 July 2025
**before** any purge."* Its consequences say why — *"the watch may not have
been worn, or workouts may have been written by Strava rather than to it"* —
and name the bulk-export bridge as the contingency if the answer is thin.

**Nothing has ever measured it.** Every plan written since, including the
cutover plan and the peer review folded into it, assumes the answer and
sequences Health ingestion as phase six of ten. It belongs first, because a
thin answer changes what the database currently holds from *a copy* into *the
only copy*, and that changes the priority of everything below it.

### 12.28.2 The risk is thinness, not disappearance

"Workouts written by Strava rather than to it" reads as though those sessions
would vanish on a disconnect. **They will not.** An `HKWorkout` belongs to
Apple the moment it is written; revoking an API token does not reach into the
Health store, and deleting the Strava app does not either.

The real exposure is that a session which exists in Health only because Strava
pushed a summary back carries a start, an end, a duration and often nothing
else — no route, no heart-rate samples, sometimes no distance. It counts as
present in every census and is not a training record.

So the report counts what is there **and what state it is in**, and reports the
writers by name. `HealthWorkout.sources` has carried
`w.sourceRevision.source.name` since the reconcile screen was built; every
session has known who wrote it all along and nothing had ever aggregated it.

### 12.28.3 It has to be able to say "I do not know"

`HealthStore.workouts(from:to:)` returns `[]` on a denial, a timeout and a
genuinely empty store alike, and its own comment says so: *"the caller cannot
tell a denial from an empty store anyway."* For every other caller that is the
right trade — a diagnostic that crashes is worse than one that says nothing
came back.

For this one it is fatal. A report that answers *"Health has nothing"* when the
truth is *"the query never ran"* would retire Strava on the strength of a
permissions bug, and the zeros would look exactly like an answer.

`HealthCoverage.Reading` is therefore the first field of the report, with five
cases — read, unavailable, neverAsked, noUsageDescription, failed — and
`isTrustworthy` is true for exactly one of them. **This is `StoreLoad` from
§12.15 wearing different clothes**, and deliberately so: same failure, same
shape of answer, and the two should be recognisable as the same idea.

`anUntrustworthyReadingNeverReadsAsAnEmptyStore` is the test with teeth. It
builds a report holding a stored activity and no Health workout — the exact
shape of a real shortfall — and asserts that the headline is the reading and
that `text()` stops before the table, so nobody can screenshot an empty grid
and call it a measurement.

### 12.28.4 Days, not sessions, and the second matcher that was not written

`HealthReconcile.build` already joins the two sides. It is filtered, on both
sides, to the sessions this app reasons about — and its comments explain a
real defect that came from filtering only one of them: 156 commute rides
landed in a bucket meaning *"Strava never received this"* when Strava had
received all of them.

Coverage is a different question and needs the commutes and the walks. Writing
a second matcher to answer it would put two joins in this codebase that
disagree, which is exactly what §12.16 refused for CTL.

**So this compares DAYS.** A day carries a `dayKey` on both sides, needs no
tolerance rule, no candidate selection and no `used` set, and cannot drift from
`build` because it is not doing what `build` does. The limit is stated on the
screen and in the paste rather than left to be discovered: a day present on
both sides counts as covered even if the two sessions on it are different
sessions. Where a day disagrees, *Compare with Strava* is the screen that
inspects it.

### 12.28.5 What is deliberately not measured

**Routes.** `HKWorkoutRoute` is one query per workout, and over thirteen months
that is several hundred round trips for a diagnostic. Thinness is measured here
by distance and heart rate, which arrive with the workout and cost nothing. A
route census is worth doing before the purge and is not this — recorded here
rather than skipped in silence, because a check the plan implied and did not
get is the kind of gap that closes itself in a summary.

### 12.28.6 One query per month

`workoutTimeout` is twelve seconds and the window is thirteen months. A single
query for the lot is one timeout away from `[]`, which is the false negative
this whole design exists to prevent. A month at a time is bounded, and the
months are the buckets the report wants anyway.

The trade is stated: dedupe runs per call, so a session starting on the last
night of a month is deduped within its own month only. Sessions do not span
months in practice, and the bucket is chosen by start date, so it cannot
double-count.

`enrichSwims: false` is this patch's one change to `workouts(from:to:)`. The
parameter is defaulted, so every existing caller is untouched.

### 12.28.7 It states the finding and stops

`headline` is not a verdict. ADR-0002 requires the shortfall — if there is one
— to be **accepted in writing** rather than discovered at the receipt, so the
report says how many training days the app holds that Health does not, and how
many sessions Strava alone wrote, and goes no further. Whether that is
acceptable is a decision, and decisions are not computed here.

## 12.29 What M0 measured, and the two blind spots in its own report — patch 283

### 12.29.1 The measurement

Run on the device at patch 282, over 2025-07-01 to 2026-08-06:

| | |
|---|---|
| Health sessions | **710** across **322** training days |
| by discipline | 113 run · 404 ride · 54 swim · 8 strength · 131 other |
| carrying a distance | 557 (78%) |
| carrying a heart rate | 619 (87%) |
| the app holds | **668** across **322** days |
| days in both | **319** |
| days only in Health | 3 |
| **days only in the app** | **3** — two in 2026-05, one in 2026-06 |
| sessions naming Strava as a writer | 102 |
| **sessions Strava alone wrote** | **53** (7.5%) |

**ADR-0002's central worry does not hold.** July 2025 — the first month of the
window, and the one the follow-up named — shows Health with 63 sessions across
28 days against the app's 52 across the same 28. Health has *more*, from the
start. **The bulk-export bridge comes off the critical path.**

The shortfall is three days, all of them recent. Recorded here as the finding;
ADR-0002 requires it to be accepted in writing rather than met at the receipt,
and that acceptance belongs in the cutover plan, not in this file.

### 12.29.2 Blind spot one: the two sides were not counted the same way

The report counted Health by discipline and the app only in total, so the two
columns could not be compared at all. The fix is one field per discipline on
the stored side.

**What the comparison shows, once it exists.** From the 283 run, same window:

| discipline | Health | the app | |
|---|---|---|---|
| run | 113 | 110 | Health +3 |
| ride | 405 | 373 | Health +32 |
| swim | 54 | 52 | Health +2 |
| **strength** | **8** | **16** | **the app +8** |
| other | 131 | 118 | Health +13 |
| tracked (run/ride/swim/strength) | **580** | **551** | Health +29 |

**The ride surplus is almost certainly not loss.** 153 of 711 sessions carry no
distance at all, and `HealthReconcile.isRelevant(_ w:)` already documents the
cause in its own comment: the watch's "looks like you are cycling" prompt
accepted and then abandoned — records of 1:35, 2:59 and 11:27 with nothing
attached. Health knowing about fragments Strava never received is not a
shortfall.

**Strength is the finding.** The app has sixteen and Health has eight. That
fits `HealthWorkouts.swift`'s own note about a strength session logged through
Hevy reaching Strava with reps, sets and calories and no heart rate.

And it is the one that matters, because **those eight are not among the three
at-risk days.** They sit on days that also carry a run or a ride, so the day
counts as covered while the session would be destroyed. §12.28.4's day-level
limit, producing its first concrete casualty: the shortfall is not "three
days", it is three days plus an unknown number of sessions on covered days, of
which eight are visible right now.

### 12.29.2.1 How the wrong number got into this file

The paragraph this replaces read: *"Take those out and Health holds 579 of the
tracked disciplines against the app's 668 — the app holds more, by tens of
sessions"*, and built a commute hypothesis on top of it. It compared Health's
TRACKED count against the app's TOTAL, which carries 118 sessions of its own
`other`. Health holds more of the tracked disciplines, not fewer.

Worth recording rather than quietly fixing, because it is the same failure as
§12.27: **a conclusion written into this file from a measurement that did not
exist yet.** Patch 283 was built precisely because that comparison was
impossible, and the conclusion was filed anyway, in the document whose whole
job is to be true. A number in here should be one the reader could have got
off the screen.

### 12.29.2.2 Two mappings that are allowed to disagree

 The switch is **written out rather than shared** with the
Health side: `Activity.discipline` and `HealthWorkout.sport` are both
`Discipline?` today, but they are computed from a Strava `sportType` string and
an `HKWorkoutActivityType` respectively, and a shared helper would couple two
mappings that are allowed to disagree. Strength is the case that proves it —
the two sides already disagree about eight sessions, and they are entitled to.

### 12.29.3 Blind spot two: a number nobody could act on

*"3 training days are in the app and not in Health"* is a finding whose only
possible next step is opening those three days in the app. The report gave a
count. **A count sends the reader looking; a date sends them to the session.**

So `Month` carries `datesStoredOnly` and `datesHealthOnly`, and the counts are
computed from them. That direction matters: the previous version summed
`daysStoredOnly` in `total` and set it in `build`, which is two places holding
one fact and one edit away from disagreeing — §12.25's defect in miniature.

**Uncapped in the paste.** A report that says "3 days" and lists two of them
reads as complete. If it ever runs to hundreds of lines, that is the finding
rather than a formatting problem. The on-screen list is capped at twenty
because a list is not a view, and the remainder is stated rather than dropped.

### 12.29.4 What this does not answer, and what does

Session-level agreement. Day coverage at 99% is consistent with dozens of
sessions differing, and §12.29.2 shows that they do — Health is ahead by 29
tracked sessions overall while the app is ahead by 8 on strength, and none of
those 8 appear in the three at-risk days.

That is **D6c shadow parity's** question, and the tool for it already exists:
`HealthReconcile.build` matches sessions. It is filtered on both sides to the
ones the app reasons about, and that filter is why it cannot answer this today
— `isRelevant(_ a:)` admits strength only when the session is plan-eligible,
and rides only when they are, so the two categories where the sides actually
differ are the two it declines to look at.

Making that filter a parameter is not a second matcher; it is the same matcher
with the filter as an argument, so §12.28.4's objection does not apply to it.
That is the next piece of work, and it belongs before D6c rather than during.

**And the 53.** Whether a session Strava alone wrote carries a route or heart-
rate samples is still unmeasured. The set is bounded, so the census §12.28.5
deferred is now 53 queries rather than several hundred. It blocks a purge and
nothing else.

*Measured at 286b — 5 routes, 0 with heart-rate samples, 9 with nothing at
all. See §12.33.*

## 12.30 The fix-ups were invisible — patch 284

### 12.30.1 What went wrong, which is not what it looks like

283a was installed. The phone read **Source patch 283**.

Nothing was broken and no number was stale. The rule until now was that a
letter fix-up ships no `AppVersion.swift`, on the reasoning that a fix-up is
not a new patch and the number should not move. The reasoning is coherent and
the result is a screen that cannot answer the question it exists for: **is the
source on this device the source I think it is?** A device with 283a and a
device without it read identically.

That is the same false negative as a stale number — the case this file's own
header describes at length, from patches 39 through 44 — with one difference
that makes it worse: **a stale number looks stale.** This did not look like
anything.

### 12.30.2 Why `revision` is a second constant

`patch` is an `Int`, and it is compared. `>= 280` is a legitimate question
somewhere in this project's future and `"283a" >= "280"` is not the same
question. Folding a letter into it would change what every comparison means in
order to fix a display problem.

So the letter lives beside the number, `patchLabel` joins them, and everything
that prints a version reads the label. `AppVersionTests` walks all four printed
forms, because the way this returns is a fifth caller reading `patch`
directly.

### 12.30.3 The rule, in full

- a **numbered** patch ships `AppVersion.swift` with `patch` bumped and
  `revision` nil
- a **letter fix-up** ships `AppVersion.swift` with `patch` unchanged and
  `revision` set to its letter
- **every** patch of either kind ships the file, without exception

### 12.30.4 It stamps provenance, not just a screen

`AppVersion.patch` was written into four durable places: the snapshot
manifest, `migration_run.appVersion`, the plan-volume export and the notes CSV
filename. All four now carry the label.

That is the part worth the patch. A snapshot taken under 283a recorded itself
as taken under 283 — and a snapshot exists to be the thing you trust when
something has gone wrong, at which point "which source took this" stops being
cosmetic.

### 12.30.5 It had no tests, which is why nothing objected

`AppVersion` is the one value on the screen whose entire job is to say which
source is running, and nothing had ever asserted anything about it — not its
format, not that the display forms agree, not that a caller cannot drift.
`AppVersionTests` is the first coverage it has had, and the reason it exists
here rather than in a later cleanup is that this defect was invisible for
exactly as long as that was true.

## 12.31 Are the 53 thin? — patch 285

### 12.31.1 The question left over from M0

53 of 711 Health sessions were written by Strava and by nothing else. §12.28.2
argued that the exposure is thinness rather than disappearance — an `HKWorkout`
is Apple's once written — and §12.28.5 then declined to measure it, because a
route census over all 711 sessions is several hundred queries for a diagnostic.

Over 53 it is 54. The set being bounded is what makes the census affordable,
and the set is only bounded because the writer breakdown existed first.

### 12.31.2 One of the two measures was already paid for

`make(_:)` was reading `w.statistics(for: .heartRate)?.averageQuantity()`.
The same object carries `minimumQuantity()` and `maximumQuantity()`, and **a
summary pushed back by Strava holds one heart-rate value, so its band is
flat.** A session a watch recorded holds samples, and its band is not.

`averageHeartRate` cannot tell those apart, because both produce a number —
which is why 282's report showed 87% "with a heart rate" and that figure said
less than it appeared to. The band costs nothing: same statistics object, two
more reads.

Routes are the measure that costs. One query per session, and `HKWorkoutRoute`
carries no reference to its own workout, so `predicateForObjects(from:)` is the
only correct join. Matching routes to sessions by time would be a second
matcher against the clock, which is the thing §12.28.4 already refused once.

### 12.31.3 `nil` means nobody asked

`HealthWorkout.hasRoute` is `Bool?`. `false` is a finding; `nil` is the absence
of one. `Thinness.routesRead` carries the same distinction up to the report,
and the paste says *"Routes were NOT measured on this run"* rather than
printing a bare zero.

This is `Reading` from §12.28.3 at field level, and `routes(for:)` returns
`Set<String>?` for the same reason: handing back `[]` on a denial would let a
permissions failure read as *"all 53 are shells"* — which is precisely the
conclusion this census exists to reach honestly or not at all.

### 12.31.4 One definition of the set

`stravaAlone` lives on `HealthWorkout`. The census queries that set and the
report counts that set, and a copy of the predicate in each place is how the
two would come to disagree about which sessions they were talking about —
while both kept reporting confidently.

It is `nonisolated`, and that is a claim rather than tidiness: `HealthCoverage`
is nonisolated end to end, this target defaults to `MainActor`, and a computed
property on a plain struct belongs to the main actor unless it says otherwise.

### 12.31.5 A cap that announces itself

`maxRouteCensus` is 250 against a real set of 53. A cap is a promise that a
diagnostic cannot become a stampede — and one that silently returns a short
answer is worse than no cap, because the report would read as complete. If it
ever bites, the count it reports is the count it measured, and the two are
different numbers on the screen.

### 12.31.6 The scope correction

The eight strength sessions the app holds and Health does not **cannot be
censused here.** There is no Health record to look at. That was stated as part
of this patch's job when it was proposed, and it is a session-matching question
— it belongs to the unfiltered reconcile, alongside the rest of §12.29.4.

Recorded rather than quietly dropped, because a stated scope that shrinks
without comment is how a plan comes to believe it covered something.

## 12.32 HK-02, a second time — patch 286

### 12.32.1 What happened

Patch 285 added a route census and queried `HKSeriesType.workoutRoute()`. The
type was not in `HealthStore.typesRead`, so the app had never asked permission
to read it. **HealthKit answers an unrequested read with an empty result and no
error**, which is indistinguishable from a phone that has no routes.

This is HK-02 — `distanceCycling` read in one file and absent from the request
in another — and `HealthTypeTests`' own header describes it in exactly these
words, two screens above the query that repeated it.

### 12.32.2 The design held, which is the only reason it was noticed

The census returned nothing and the report said **"Routes were NOT measured on
this run"** rather than "0 of 53 have a route".

That is `hasRoute: Bool?` and `Thinness.routesRead` doing what §12.31.3 built
them for, on their first live run. With the obvious `[]` in place of the
optional, this defect would have produced a plausible, quotable, entirely
fabricated finding — *"none of the 53 has a route"* — and it would have gone
into the plan as evidence.

**The measurement that did work is the one that mattered anyway.** 0 of 53 have
a heart-rate band wider than a single value: every session Strava alone wrote
holds one reading, not samples. 42 carry a distance, 11 carry nothing at all.
The thinness question is answered whichever way the route census comes back.

### 12.32.3 The guard: refuse to query what was never requested

`typesRead` gains the type, `typesReadDescribed` gains "Workout routes",
`authVersion` goes to 6 so an install that has already granted the other seven
is prompted once more, and `HealthTypeTests` pins all three.

But the pin only fires when somebody adds a *type*. It cannot fire when
somebody adds a *query* — which is what happened here, and what happened in
HK-02. So `routes(for:)` now asks `typesRead` before it queries and returns
`.notRequested` when the type is absent.

**That check has to be before the query, not after**, because after the query
there is nothing to see: an empty result is what success and this failure both
look like.

### 12.32.4 `Set<String>?` was half an answer

285 returned an optional to distinguish "no finding" from "no routes", which
was right and insufficient: when it happened, the screen could not say which of
four causes it was. `RouteCensus` names them — unavailable, never asked, no
usage description, not requested, failed — and the report carries the sentence
through to the paste.

The pattern is now three deep and should be recognisable as one thing:
`StoreLoad` (§12.15) for a file, `Reading` (§12.28.3) for the whole query,
`RouteCensus` here for one measure inside it. **A diagnostic that cannot say
why it has no answer will eventually be read as having one.**

### 12.32.5 And then the query itself was the wrong kind — patch 286a

With the type requested and the prompt updated, the census ran and said:
**"Routes not measured — a route query returned an error."**

`HKWorkoutRoute` is an `HKSeriesType`, and `HKSampleQuery` rejects series
types; Apple's documented way to read a route is `HKAnchoredObjectQuery`. The
workout fetch above it is a plain sample query, is correct, and worked — which
is why only the second of the two failure messages ever appeared.

**The named outcomes are what made this a five-minute diagnosis.** In 285 the
same defect produced a silent `nil` and an evening of not knowing whether it
was permissions, the type, the query or the store. In 286 it produced a
sentence that ruled out three of the four in one reading.

**What it did not produce was HealthKit's own words**, because
`samples(of:matching:)` returns `[HKSample]?` and discards the error. 286a's
`series(of:matching:)` returns a `Result` and carries the reason through to the
screen. The rule from §12.32.4 applies one level further down than it was
written: a diagnostic that has been handed a reason should not throw it away.

**And it paid immediately.** 286a did not compile — `Result`'s failure type
must conform to `Error` and `String` does not — so 286b named the error type.
The run after that reported *"the route query failed — Authorization not
determined"*: HealthKit's own words, and a third distinct cause, arrived at in
one reading rather than a night of guessing. With the route permission granted
the census completed. **The numbers are in §12.33.**

### 12.32.6 The prompt string is a build setting, and stays one

`usageDescriptionNamesEveryTypeRead` reads
`INFOPLIST_KEY_NSHealthShareUsageDescription` out of the built product and
holds it to `typesRead`. It lives in the target's build settings, which no
patch reaches, so this patch ships red until the string names routes.

That is the intended behaviour rather than an inconvenience: PRIV-02 was a
prompt describing one type while seven were requested, and the only reason it
cannot recur is that the test refuses to pass until a human changes the string.

## 12.33 M0, concluded — patch 287

§12.28 built the census, §12.29 named its blind spots, §12.31 measured
thinness and §12.32 fixed the two defects that stopped the route half working.
This is the single place the finished numbers live, so that a reader does not
have to reconstruct them from five sections and two corrections.

### 12.33.1 The measurement

Device, 6 August 2026, window 2025-07-01 → 2026-08-06, patch 286b:

| | Health | the app |
|---|---|---|
| sessions | **711** | **669** |
| training days | **323** | **323** |
| run / ride / swim / strength / other | 113 / 405 / 54 / 8 / 131 | 110 / 373 / 52 / 16 / 118 |
| with a distance | 558 | — |
| with a heart rate | 620 | — |

Days in both **320**. Days only in Health **3** — not a shortfall. Days only in
the app **3**: 2026-05-23, 2026-05-29, 2026-06-07.

Sessions naming Strava as a writer **102**; **53** written by Strava alone.

### 12.33.2 The thinness of the 53

| | |
|---|---|
| with a route | **5** |
| with heart-rate samples rather than one value | **0** |
| with a distance | 42 |
| with none of the three | **9** |

**Not one of the 53 carries heart-rate samples.** 48 carry no route. 9 carry
no route, no distance and a single heart-rate value.

§12.28.2 argued that the exposure is thinness rather than disappearance, and
guessed that a pushed summary *"usually carries no route and no heart-rate
samples"*. The guess was right and is now a count — which is the difference
between a plausible sentence and something a decision can rest on.

### 12.33.3 What ADR-0002 asked, answered

*"If Apple Health turns out not to hold the history back to July 2025 … then
some of the record cannot be carried across by the API-free route."*

**It holds it.** July 2025 shows Health ahead of the app — 63 sessions across
28 days against 52 across the same 28 — from the first week of the window. The
bulk-export bridge stays recorded as a contingency and comes off the critical
path.

The shortfall to accept in writing is three days and 53 degraded sessions; it
is written into `PLAN-cutover-v2.md` §3 rather than here, because a plan is
where a decision belongs and an ADR is where the reasoning does.

### 12.33.4 What this cost, and the pattern in it

Five patches and two letter fix-ups, of which **three were defects in the
measuring instrument rather than findings**: an unrequested type (§12.32.1), a
sample query against a series type (§12.32.5), and a `Result` whose failure
type did not conform to `Error`.

Every one of them was caught by something built for the purpose:

- the unrequested type by `Bool?` refusing to report absence as zero
- the wrong query kind by `RouteCensus` naming its own failure
- the type error by running the suite before ⌘R

**The instrument was wrong three times and never lied once.** That is the
whole argument for the named-outcome pattern — `StoreLoad`, `Reading`,
`RouteCensus` — stated as cheaply as it will ever be stateable: with `[]` in
place of the optional, the first run would have produced *"none of the 53 has
a route"*, which is quotable, plausible, and false by five.

### 12.33.5 One thing still not established

`authVersion` went 5 → 6 to force a re-request for the route type, and the
permission was subsequently granted — but **by what path is not recorded.** If
the app re-requested on its own, the marker has an actuator. If it did not,
`authVersion` bumps a number that nothing acts on, and the next type added
will hit the same wall with the same symptom.

Recorded as open rather than assumed either way. It costs one reading of the
`requestAuthorization()` call sites to settle, and it should be settled before
a ninth type is ever added.

## 12.34 The banner named the wrong types — patch 288

### 12.34.1 §12.33.5, answered

`authVersion` does have an actuator, and it is a person. Settings shows a
banner with an *"Ask for the new Health types"* button whenever the stored
version is behind the current one, and that is how workout routes were granted
after 286 bumped it to 6.

Nothing re-requests automatically. That is a defensible choice — prompting at
launch is intrusive — but it means a newly added type stays unread until
somebody opens Settings and taps. **For a type the app merely diagnoses with,
that is fine. For one it depends on, it is HK-02's shape again**, and what
catches it is §12.32.3's before-the-query guard rather than this banner.

### 12.34.2 The defect the reading turned up

The banner said:

> *"Health access needs asking again — the app now also reads **workouts and
> swim distance**…"*

True at `authVersion` 3. Stale by three additions: heart rate at 4, cycling
distance at 5, workout routes at 6. **Somebody tapping that button was told
the wrong reason for tapping it**, in the sentence whose only job is to give
them a reason.

And the property gating it was still `needsRestingHRGrant`, named when the
only new type was resting heart rate, with a doc comment describing that one
case while it gated a general "the request has grown" prompt.

Neither was load-bearing. Both are the same failure as §12.27: **a statement
that was true when written and became false while nobody was reading it.**
This one had less protection than most, because it is prose inside a `View`,
seen once every few months by a person who is not checking it against a list.

### 12.34.3 The fix is a shape

`HealthStore.newTypesMessage` renders `typesReadDescribed` — the list the
authorisation request is built from, already held to `typesRead` by
`descriptionMatchesTheRequest`. The same answer as `DataLifecycle.summary`:
*"computed rather than written, so it cannot fall out of step with the table
underneath it."*

The test pins the absence of a hand-written list rather than the presence of
the right one. "Workouts and swim distance" was accurate once; what makes it
wrong is that it is a fixed list at all, and a test approving a different fixed
list would guard the wrong thing.

### 12.34.4 It cannot be verified on the device today

The banner shows only while the stored version is behind the current one, and
version 6 was granted an hour before this patch — so it is correctly hidden,
and there is nothing to look at. **The test is the verification.** The banner
is next seen when a ninth type is added, which is precisely the moment nobody
will re-read it.

Recorded rather than glossed, because "verified on device" has meant something
specific in this project for eighty patches, and this is a patch where it
cannot mean it.

## 12.35 The first reader — D6a, patch 289

### 12.35.1 Read-only, and called by nothing

`ActivityRepository` reads and does not write. Writes are D6b's. It is wired
into no screen, and that is deliberate — a reader on a screen before parity
has run is D7 arriving by accident, and §12.27's test would not catch it
because the flag would still be false.

What it buys immediately is the question D6c exists to ask, asked six weeks
early and in a test: **can the database give back what the store holds?**

### 12.35.2 Four renames and a trap

The `activity` table round-trips a full `Activity`, but five of the names
differ:

| `Activity` | column |
|---|---|
| `id` | `activity_source_record.externalID` — `activity.id` is a minted UUID |
| `sportType` | `sportLabel` — nullable |
| `isTrainer` | `isIndoor` |
| `deviceWatts` | `hasPowerMeter` |
| `maxSpeed` | `maxSpeedMS` |
| `gearId` | **not `activity.gearID`** — see below |

**The trap.** `activity.gearID` holds the CANONICAL gear id, which is §3.1's
whole purpose; `Activity.gearId` holds Strava's, because that is what
`AthleteStore.shoes` is keyed by. Reading the column straight through hands
every one of the 479 gear-bearing activities an id that matches nothing, and
shadow parity reports it as a data divergence rather than as a join this
reader got wrong.

**And the column is not always set.** When the importer cannot resolve the
gear — a retired shoe, a bike added after the last athlete fetch — `gearID`
stays null and the name Strava gave is recorded in `activity_gear_reference`.
A reader looking only at the column loses gear on precisely those rows. Hence
the second `LEFT JOIN` and the `COALESCE`, and
`unresolvedGearStillComesBack` is what holds it.

### 12.35.3 The fifth instance of one idea

`ActivityLoad` distinguishes a read that ran from one that could not:
`StoreLoad` for a file (§12.15), `Reading` for a Health query (§12.28.3),
`RouteCensus` for one measure inside it (§12.32.4), `hasRoute: Bool?` for one
field (§12.31.3), and now this for a table.

`activities` returns `[Activity]?` and not `[]`, so a caller cannot reach the
happy path without deciding what an untrustworthy read means. **An empty
training history is a legitimate answer on a fresh install**, which is exactly
why it must not be reachable by the same path as a failure.

### 12.35.4 `skipped` — honest about its own coverage

A row with no `sportLabel` cannot become an `Activity`, because `sportType` is
not optional. Mapping null to `""` would produce an activity whose
`discipline` is nil — an activity of no sport, which is worse than an absent
one.

So such rows are **counted**, not dropped. A reader that quietly returns fewer
rows than the table holds is what shadow parity would report as missing data,
and the count is the difference between a reader that is wrong and one that
says where it stopped.

### 12.35.5 A query built rather than concatenated

The first version appended `AND r.externalID = ?` to a statement ending in
`ORDER BY a.startUTC DESC`, which is not SQL. Caught while writing, and
recorded because the shape is the lesson: **text added to the end of a query
only works while nothing is at the end.** `statement(and:)` composes the
clauses instead.

Ordering is by `startUTC`, which §4.1 makes authoritative for order —
`startLocal` is authoritative for BELONGING. Ordering by the wrong one is
invisible until two sessions fall either side of midnight.

## 12.36 The reader meets the real 669 — patch 290

§12.35 proved the round trip on one synthetic activity. That is worth exactly
as much as one synthetic activity: it says the column names are right, and
nothing about 669 real ones with retired shoes, missing sport labels and eight
months of whatever Strava happened to send.

`ActivityRoundTrip` runs the comparison on the phone, and it is **D6c's first
real measurement** — deliberately one table, no derived metrics, no CTL.

### 12.36.1 It names fields, not rows

*"12 activities differ"* sends somebody through twelve activities. *"12
differ, all on `maxSpeed`"* is one fix, and usually a units mistake.

That is §12.16's warning one level down: equal counts can hide changed values,
and a bare count of differences hides which value. `fieldTally` is the line to
read first, and the screen puts it above the ids.

### 12.36.2 The field list is written out, not derived

`differingFields` names all nineteen comparable properties by hand. There is
no reflection in Swift that would enumerate them without also silently
skipping something, and a comparison that quietly stops covering a field is
worse than one that does not cover it — the first reports agreement.

`everyFieldIsCompared` holds the count. Add a property to `Activity` and that
test fails, which is the only moment anybody would think to update this.

### 12.36.3 Why this is not D7 arriving by accident

A reader wired into a screen that SHOWS TRAINING would be. This sits beside
`SemanticVerifier`, which has read the database for diagnostic purposes since
3.2. The Database screen is where the app looks at itself, and looking is not
depending.

`Sub4Launch.migrationFailureBlocksTheApp` stays false, and §12.27's test still
holds the disconnect rule to it.

## 12.37 The detail reader — D6a, patch 291

Four tables and three nested arrays, against `Activity`'s one table and twenty
scalars. Designed in `D6A-DETAIL-GROUNDWORK.md` and settled in
`D6A-DETAIL-DECISIONS.md` **before any code existed**, which is why it is one
patch — 289's `gearID` trap was found the same way and cost one fix-up rather
than a week of parity noise.

### 12.37.1 The ordinal is not one thing

All three child tables carry `ordinal`, NOT NULL, `>= 0`, unique per parent.
Read from `Sub4Import+Recording.swift`:

| table | `ordinal` is |
|---|---|
| `activity_split` | `split.index` — a domain value, 1-based |
| `activity_lap` | `lap.index` — a domain value |
| `activity_best_effort` | `i` — the array position, 0-based |

So `Split` and `Lap` take their `index` **from** the ordinal; `BestEffort` has
no index property at all — its identity is `name` — and its ordinal is ordered
by and then discarded.

Getting this backwards gives splits numbered from zero, or best efforts in
whatever order SQLite chose. **Neither fails a count comparison**, which is
§12.16's warning arriving in a place nobody would look for it.

### 12.37.2 Matched by identity, so ordering stopped being a question

The groundwork asked whether the store's arrays are in the order the importer
enumerated. The answer is not to find out: splits and laps match on `index`,
best efforts on `name`, and then neither side's order matters.

Three things fell out of that, all improvements. Failure messages name a
kilometre — `splits[index: 7].movingTime` — rather than an array slot.
**Missing** and **surplus** separate from **differing**, so a count mismatch is
not reported as nineteen field disagreements. And the ordering claim shrinks to
one small thing a single test pins.

### 12.37.3 The date, to the second

`fetched` is the only type change in the mapping. `Sub4Import.iso8601` is
`.withInternetDateTime` with no fractional seconds, and the store's value was
itself decoded from a second-precision string — so it round-trips.

`sameSecond` rounds both sides anyway. Not defensive clutter: **the column
cannot hold a fraction**, so a comparison demanding exactness asks the database
for something it was never designed to store. The case it protects is a
`fetched` set from `Date()` in memory and compared before any save.

### 12.37.4 What the read-back found, on the first run

**`fetched`, 320 of 668 — and the comparison was the defect.**

`sameSecond` rounded. `ISO8601DateFormatter` truncates. A store timestamp of
x.6 was written as x and compared as x+1, so it disagreed with itself; 47.9%
of timestamps carry a fraction of 0.5 or more, and 320/668 is 47.9%.

**The number was the diagnosis.** Not "some dates differ" — a proportion that
could only come from one cause. That is the argument for reporting by field
with counts rather than by row: `fetched 320` is a hypothesis, and it was the
right one on sight.

Corrected in 291a. The rule it earns: **a comparison has to model what the
writer did, not what would be tidy.** Truncation is not an approximation of
rounding, and the two disagree on exactly half the data.

**`laps[*].averageHR`, spread thinly across many lap indices** — the
`positiveOrNil` normalisation, predicted in §12.37.5 and confirmed. Intended,
and left alone.

**Four details in the store and not in the database** — the activities synced
since the last import, the same staleness the activity read-back measures.

### 12.37.5 The loss it reports rather than hides

The importer writes `positiveOrNil(...)` for **both** `split.averageHR` and
`lap.averageHR` — the groundwork said laps only, which was wrong and is
corrected here. A stored zero becomes NULL and comes back `nil`.

That is the importer's deliberate normalisation, and this reader **reports it**.
A reader that invented a zero to make the comparison green would be lying to
turn a screen a different colour, and the whole value of a read-back is that it
is believable when it says nothing differs.

## 12.38 The recording reader — D6a, patch 292

The last of the three. Split from its comparison the way §12.35 was from
§12.36 — 645 recordings and 192,954 samples is enough for one patch.

### 12.38.1 A third meaning for `ordinal`

Across four child tables the project now has three conventions:

| table | `ordinal` is |
|---|---|
| `activity_split` | `split.index` — a domain value, 1-based |
| `activity_lap` | `lap.index` — a domain value |
| `activity_best_effort` | the array position |
| `recording_sample` | the array position |

`recording_sample` behaves like best efforts: ordered by, then discarded.
`ActivityStreams` has no per-sample identity at all, so there is nowhere to put
it and nothing to match on.

`recording_sample` is also the only child table with a **composite primary key**
— `(recordingID, ordinal)` — and no `id` column.

### 12.38.2 Four renames, and `power` is the one

`speed → speedMS`, `altitude → altitudeM`, `grade → gradePercent`, and
**`power → watts`**. The last has its own named test because it is the one that
would be typed straight through and produce a reader that silently drops every
power trace.

### 12.38.3 One at a time, not all at once

`ids(_:)` then `streams(_:storeID:)`. All 645 recordings materialised together
is roughly 12 MB of `Double` — survivable and pointless, since the comparison
builds one, checks it and discards it.

`all(_:)` exists for the tests and says in its own comment that the comparison
should not use it. `ActivityDetailRepository.all` materialises everything
because 668 details is nothing; copying that shape here would have been the
easy wrong answer.

### 12.38.4 The lossy step, named rather than discovered

The importer writes `at(series, i)`:

```swift
guard let series, i < series.count else { return nil }
```

`nil` for an absent array **and** `nil` past its end — no padding, no default.
Two consequences, both irreversible:

1. **A stream shorter than `distanceM`** was stored with trailing NULLs and
   cannot be told apart on the way back from a full-length stream missing its
   tail. The reader reconstructs at `distanceM.count` and does not guess at
   trimming.
2. **A NULL inside a present stream** becomes `0`. `[Double]?` cannot hold a
   per-element nil, and zero is already what `ActivityStreams.has(_:)` reads as
   nothing there — it tests `contains { $0 > 0 }`.

`aShortStreamIsPadded` asserts the loss rather than hiding it, so it is a
decision somebody made and can find, not a surprise the comparison springs.

### 12.38.5 Absent and all-zero are one bit apart

`series(_:_:)` returns `nil` only when **every** sample is NULL. That single
rule decides whether `has(.power)` is true, and `has` decides whether a chart
is drawn at all — so "this ride had no power meter" and "this ride had power
that read zero" are one bit apart in the database and a whole feature apart in
the app. `theAbsentStreamStaysAbsent` is the test with teeth for that reason.

## 12.39 The recording round trip — D6a's last comparison, patch 294

Patch 292 built the reader and proved it against fixtures. This runs it against
645 real recordings and 192,954 real samples, and it is the last of the three
read-backs D6a set out to build.

Three comparisons, three shapes, and the differences between them are the
interesting part:

| | compares | matched by | reports |
|---|---|---|---|
| 290 activities | 19 scalar fields | store id | field, per activity |
| 291 details | 8 scalars + 3 arrays | `index` and `name` | field, per element |
| 294 recordings | 8 parallel arrays | array position | **stream, and a band** |

### 12.39.1 Three numbers, not two

Every other comparison in this project has two sides. This one has three:

    the store's array length          ActivityStreams.distanceM.count
    what the importer said it wrote   recording.sampleCount
    what the table actually holds     rows in recording_sample

The middle one exists because the importer already wrote it — `INSERT INTO
recording (…, sampleCount, …) VALUES (…, s.count, …)` — and reading it costs one
row per recording and no samples at all.

It earns its place by separating two failures that are otherwise identical. An
array that arrived from Strava shorter than the distance axis, and rows that
went missing from `recording_sample` after they were written, are both "the
lengths disagree" with two numbers. With three they are `sampleCount` and
`sampleCount vs rows`, and one of them is a data question while the other is a
database question.

This is the same argument as §12.35.4's `skipped`: a diagnostic that cannot say
which of two things happened will eventually be read as having said one.

### 12.39.2 A field name that carries a count is not a field name

The whole value of the previous two read-backs was the **tally**. `fetched 320
of 668` was a diagnosis on sight — 47.9% is the fraction of timestamps with a
fractional second of 0.5 or more, and the proportion named the bug (§12.37.4).
A list of 320 activity ids would have named nothing.

A tally groups by field name. So the name has to be the *same string* on every
recording that has the problem. The obvious field name here —
`heartRate[3 of 1204]` — is unique per recording, which turns the tally back
into a list with extra steps.

So the counts were moved out of the name and into two other places:

- **`fields`** carries stable names: `heartRate`, `sampleCount`,
  `power missing from the database`, `heartRate length`.
- **`detail`** carries the same finding with its numbers, printed for the
  handful of ids the screen shows.
- **`sampleTally`** adds the bands up across the whole run, per stream.

Which gives the screen two tallies rather than one, and they answer different
questions. `fieldTally` says how WIDE — *twelve recordings differ on heart
rate*. `sampleTally` says how DEEP — *ninety-one samples out of 186,204*.
Twelve recordings each off by one sample and twelve recordings off by three
hundred are the same number in the first tally and nothing alike in the second.

`theFieldNameIsStableAcrossRecordings` is the test with teeth, and it is a test
about a string.

### 12.39.3 The gate before the walk

If the two lengths disagree, the per-sample walk is **skipped** for that
recording.

One sample missing near the start shifts every later sample by one position,
and a positional walk would report roughly three hundred differences on a single
defect — enough for one bad recording to bury everything else the run found.
The groundwork decided this before any of it was written (`D6A-RECORDING-
GROUNDWORK.md` §4), which is the point of writing groundwork.

The date is checked *before* the gate rather than behind it: a timestamp is
comparable whatever the lengths do, and losing it to an unrelated length
mismatch would be a second silent gap of exactly the kind §12.35.4 exists to
prevent.

### 12.39.4 Off the main actor, and why only this one

The activity and detail read-backs run their comparison inside a `Task` on the
main actor, which is fine: 668 structs against one query each.

This one is 645 read transactions and roughly 1.5 million `Double` comparisons.
On the main actor that is a screen frozen for as long as it takes, and **a
diagnostic that looks like a hang is a diagnostic nobody presses twice.** So
`compareOffMain` hands the whole run to `Task.detached`.

It is safe rather than lucky: `Sub4Database` is `Sendable` and holds a GRDB
`DatabaseQueue`, which serialises its own access, and `ActivityStreams` is a
`nonisolated` value type whose stored properties are all `Sendable`. The type
work that patches 219, 230, 237 and 245 did is what makes this a one-line
change instead of a refactor.

### 12.39.5 What it is expected to find, stated as a prediction

Written before the device run, and labelled as a prediction on purpose —
§12.29.2.1 records what happens when a conclusion gets written into this file
from a measurement that did not exist yet.

The expectation is **`heartRate length` on some number of recordings**: a stream
that Strava returned shorter than the distance axis is written with trailing
NULLs, read back as zeros at full length, and its original length is not
recoverable (§12.38.4). `aShortStreamIsPadded` has pinned that loss since 292;
what is not known is how many recordings carry it, and that number is the whole
reason to run this.

Anything else — a `sampleCount vs rows`, a differing `distanceM` — is not
expected and would be a real finding.

The measurement is below, and it did not go the way this section said it would.

### 12.39.6 What it found, and the prediction was wrong

Run on 7 August, patch 295 on the device:

    The read                    645 recordings in the database.
    Compared                    645
    Agreed on every sample      644
    Samples walked          1,403,819
    In the store, not in db       5
      fetched                     1
        17463863070 — fetched differs

**No `heartRate length`. Not one.** No `sampleCount`, no `sampleCount vs rows`,
no differing `distanceM`. 1.4 million sample comparisons across 645 recordings,
and the only disagreement in the whole set is a single timestamp.

§12.39.5 predicted the short-stream padding loss would appear on some number of
recordings and said the number was the reason to run this. The number is zero.

**Possible and unobserved is not the same as impossible**, and the distinction
is the finding. The schema genuinely cannot recover the length of a stream
shorter than `distanceM` — §12.38.4 is right and `aShortStreamIsPadded` proves
the mechanism. What this says is that Strava's payloads, after the resampler has
had them, never contain one. The loss is a latent hazard rather than active
damage, and it stays pinned by test because "does not happen today" is a
property of the data and not of the code.

#### 12.39.6.1 `samplesWalked` is the number that makes the rest believable

A comparison reporting near-total agreement is the one to distrust, and this
report was built with that in mind: `walked` accumulates **only** in the
equal-length branch of the walk. If the length gate had been quietly swallowing
recordings — the exact failure a gate invites — `samplesWalked` would have
collapsed toward zero while `agreed` stayed at 645 and looked like success.

It didn't, and the arithmetic is checkable from the screen:

    1,403,819 ÷ 645          = 2,176 comparisons per recording
      192,954 ÷ 645          =   299.2 samples each      ← targetSamples = 300
    1,403,819 ÷ 192,954      =     7.28 streams per sample position, of 8

Five streams are effectively always present (`distanceM`, `heartRate`, `speed`,
`altitude`, `grade`); the remaining 2.28 comes from `latitude`/`longitude` on
outdoor sessions and `power` on the few rides that carry a meter. The ratio is
not a claim about power coverage — indoor sessions have no GPS and the two
effects are not separable from this number alone — it is a cross-check that the
walk did the work it says it did.

**A diagnostic that can only report agreement has not been tested.** This one
carries its own denominator, which is what lets a green result be read as a
result rather than as an absence.

#### 12.39.6.2 The one that differs

`17463863070` differs on `fetched`, and the detail read-back shows exactly one
`fetched` too. Almost certainly a re-fetch after the last import moved the
store's timestamp — not a comparison defect, and 291a taking that column from
320 of 668 down to 1 is the evidence for the distinction.

Recorded rather than chased. One in 645 that resolves on the next import is not
worth a patch; it is worth knowing it is one and not three hundred.

#### 12.39.6.3 D6a is answered

| | compared | agreed | residue |
|---|---|---|---|
| activities (290) | 668 | 668 | — |
| details (291) | 668 | 655 | 13 — `positiveOrNil`, intended, + 1 `fetched` |
| recordings (294) | 645 | 644 | 1 `fetched` |

Every table, every level, against the real corpus rather than fixtures. The
question D6a set out to ask — *does the database hold what the app holds* — is
answered yes.

Two things it does **not** answer, stated so nobody reads the table for more
than it says. It compares the database to `ActivityStore` and `DetailStore`, not
to Strava; that is D6c's job and always was. And the store-only counts — 4
activities, 5 details, 5 recordings — are not a defect in any reader. They are
the last import going stale, they grow every day, and they are D6b's.



## 12.40 The tally that could not be read — patch 295

Patch 294 landed and the two older read-backs re-ran on the device. The detail
report looked like this:

    The read                              668 details.
    Compared                              668
    Agreed on every field                 655
    In the store, not in the database       5
      laps[index: 12].averageHR             3
      laps[index: 2].averageHR              3
      laps[index: 20].averageHR             2
      laps[index: 28].averageHR             2
      laps[index: 42].averageHR             2
      fetched                               1
      laps[index: 10].averageHR             1
      laps[index: 14].averageHR             1
      laps[index: 16].averageHR             1
      laps[index: 18].averageHR             1
      laps[index: 1].averageHR              1
      laps[index: 22].averageHR             1
      + 13 more fields

Thirteen details differ. One cause. **Twenty-five tally rows**, twelve of them
shown and the rest behind a cut-off.

Also on that run, and worth recording separately: **`fetched` is 1, not 320.**
291a's truncation fix is confirmed against the real 668. And the activity
read-back is still 668 compared, 668 agreed, with four in the store and not in
the database — five at the detail level, which means one activity reached the
database while its detail row did not. That gap is D6b's, not this patch's.

### 12.40.1 Every key was correct

Nothing in that list is wrong. `laps[index: 12].averageHR` differs on three
details, and saying so is accurate.

The report is still useless. A reader sees twenty-five findings and an unknown
number more, when what happened is one known normalisation — the importer's
`positiveOrNil` on a zero heart rate, §12.37.5 — touching about thirty laps
across thirteen details. The screen cannot say that, and the shape of the list
actively argues against it: twenty-five differently-named rows read as
twenty-five different problems.

**A correct summary that cannot be read is worse than a missing one.** A missing
summary sends somebody to the data. This one sends them to the wrong conclusion
and gives them twelve rows of evidence for it.

### 12.40.2 The same defect, four patches apart, found in the wrong order

§12.39.2 designed the recording report around exactly this: a field name
carrying an element identity is unique per record, and a tally of unique keys is
a list with extra steps. That was written for 294 **while 291's report already
had the disease**, and I did not look.

The reason is worth naming: 291's tally was *tested*, and every test passed. The
tests asserted that `differingFields` names the right element — which it does,
and should. Nothing tested what a hundred of those names look like stacked in a
list, because that is not a property of one comparison. It only appears at real
scale, on a screen, which is the argument §12.36 makes for running these against
the actual 668 rather than fixtures.

### 12.40.3 Collapse for grouping, keep for opening

`tallyKey` rewrites the element identity to `*` **for grouping only**:

    laps[index: 12].averageHR   →  laps[*].averageHR
    bestEfforts[1k].seconds     →  bestEfforts[*].seconds
    splits missing 12           →  splits missing

`Difference.fields` is untouched. §12.37.2 chose identity over position so a
reader could open the lap, and that has to survive a fix to the layer above it —
so the section now prints the first five ids with their precise field names
underneath the tally. Collapsing a summary that leads nowhere is a dead end
dressed as a tidy one.

### 12.40.4 Wide and deep, again

Each row now carries two numbers: `details` (how many details carry this field
at all) and `elements` (how many splits, laps or efforts inside them do).

Thirteen details each with one bad lap, and thirteen details with forty bad laps
between them, are the same first number and nothing alike in the second. This is
the same split §12.39.2 built into the recording report as `fieldTally` and
`sampleTally`; here both fit in one row because the denominators are small.

The list above becomes one line:

    laps[*].averageHR      13 · ~30 elements
    fetched                 1

### 12.40.5 The comment was right before the code was

The view already said it:

    // The tally first — "all on splits[*].averageHR" is one known
    // cause; a list of ids is an afternoon.

Written at 291, describing the output as though `[*]` were what the tally
produced. It never was. §12.34 records that prose in a `View` goes stale
silently; this is the sharper version — prose that was **never true**, sitting
directly above the code that failed to make it true, and reading as
documentation of working behaviour for four patches.

The comment is kept and amended rather than deleted, because the record of
having believed it is the useful part.

### 12.40.6 What the collapse produced

Same run, 7 August. Twenty-five rows and a cut-off became three rows and no
cut-off:

    laps[*].averageHR      11 · 30 elements
    fetched                 1
    splits[*].averageHR     1

    19592747211 — laps[index: 2].averageHR, laps[index: 4].averageHR,
                  laps[index: 6].averageHR, laps[index: 8].averageHR + 13
    17014853339 — laps[index: 1].averageHR
    17749640513 — laps[index: 20].averageHR
    18056328970 — laps[index: 50].averageHR
    18660794652 — laps[index: 28].averageHR
    + 8 more

11 + 1 + 1 = 13, and 668 − 655 = 13. Every differing detail carries exactly one
kind of field; if any carried two the tally would sum above the difference
count, which is a cheap consistency check worth knowing is available.

**`splits[*].averageHR` existed and could not be seen.** One detail, one field,
sitting behind "+ 13 more fields" since 291. The collapse did not find a new
defect — it made a four-patch-old one visible. That is the concrete cost of a
tally that fragments: not wrong rows, but true rows pushed off the bottom by
duplicates of a single cause.

**The distribution is the other thing one number could not say.** `19592747211`
alone accounts for 17 of the 30 laps; the other ten details share the remaining
13. Eleven details each with one bad lap and eleven with thirty between them
have identical `details` counts and describe different situations, and the
`elements` column is the whole reason that is legible here.

Neither of those is a new bug. Both were true before 295 and unreadable, which
is §12.40.1's point measured rather than argued.

## 12.41 D6b groundwork, and a number that was computed and thrown away — patch 297

The design work for write-through, done before the code, the way §12.38 was done
before §12.39. It lives in `docs/D6B-WRITE-THROUGH-GROUNDWORK.md`; this section
records the two findings that changed the shape of it.

### 12.41.1 The import is already the write-through

`Sub4Import.run` reads as a migration tool and is not one. Its call site hands
it **every store's entire contents** — activities, gear, notes, proposals, match
decisions, sync state, work items, rejections, commutes, weather, constants,
FTP, zones, plan, streams, details — and it writes them in one `db.queue.write`,
upserting rather than inserting, with a `migration_run` opened and closed around
it.

Its footer has always said *"Running it twice imports nothing twice"*, and as of
294–296 that is measured rather than claimed: 668 activities, 668 details, 645
recordings and 1,403,819 samples compared after a run, every disagreement named.

So D6b is **not** "write seventeen tables". It is "when does the thing that
already writes them run, and what happens when it fails" — a question about
triggering and failure, not about SQL.

That matters because the alternative has a measured cost. §12.35.2 found four
column renames in `activity` alone and a `gearId` that is not `activity.gearID`;
§12.38.2 found four more in `recording_sample`. Each was a chance to be wrong in
a way that looks like missing data, and each was caught because a comparison
existed and was run against the real corpus. Seventeen hand-written incremental
writers is seventeen fresh chances to take that risk, in code that runs
unattended and is checked by a button somebody presses when they remember.

### 12.41.2 `Report.seconds` has been computed and discarded for forty patches

`Sub4Import.Report.seconds` is set from a `ContinuousClock` measured around the
write. Nothing displays it. Nothing stores it — `migration_run` holds
`startedUTC` and `finishedUTC`, which gives second granularity for an operation
that may take one.

The whole of D6b's central choice turns on that number. Under two seconds and
the import can simply run after every sync; over ten and it needs a changed-set
before it can. The measurement has existed in memory on every import since the
importer was written, and has been thrown away every time.

This is a quieter cousin of §12.34 and §12.40.5. Those were prose that went
stale or was never true. This is a **measurement that was taken and not
surfaced** — which is harder to notice, because nothing is wrong on screen.
There is simply no row, and an absent row asks no questions.

Patch 297 adds it. One line of code, and it is the only code in the patch,
because the thresholds it will be read against are written down in the
groundwork **before** the reading — the same discipline as §12.39.5, which was
written to be falsifiable and duly got falsified in §12.39.6.

## 12.42 Two things the report could not say — patch 298

Both found by running 297's measurement, neither of them what 297 was looking
for. Both are the same rule the sixth and seventh time: **a diagnostic that
cannot say why it has no answer will eventually be read as having one** —
§12.15, §12.28.3, §12.31.3, §12.32.4, §12.35.

### 12.42.1 A date comparison that does not print the dates

On 7 August the recording read-back reported:

    fetched                     1
      17463863070 — fetched differs

An import thirty seconds later reported **`Traces: 4 new, 0 replaced, 645
unchanged`**. The importer's rule for a trace is string equality on the
timestamp — `iso8601(store.fetched) == recording.fetchedUTC`, one row read, no
samples — and it found that row unchanged. A second read-back after the import
still reported the difference.

So the importer and the reader compared the same column on the same row and
disagreed, and **neither said enough to decide which was wrong.** "fetched
differs" is a true sentence that supports no next step.

This is §12.40's lesson one field down. There the tally fragmented and buried
the cause; here it collapsed to a single word and dropped it. Both are summaries
that cost the reader the thing they needed, and both were written by somebody
who already knew the answer at the time.

The detail line now carries both values:

    fetched: store 2026-08-05T09:12:33Z, database 2026-08-05T09:12:34Z

The **field name stays `fetched`** — §12.39.2's rule holds, the values go in the
detail where they are already unique per record.

#### 12.42.1.1 And a sentinel that was hiding a third case

`RecordingRepository.build` ended in `?? .distantPast`, written inline at 292.

A `fetchedUTC` the reader cannot parse therefore became a date in the year 1,
which the comparison reported as `fetched` — *the database disagrees about when
this was fetched* — when what happened was *the reader could not read the
column.* A reader defect wearing a data difference's clothes, and one of the two
live candidates for the row above.

It is now `RecordingRepository.unreadableDate`, named, and the comparison tests
for it **before** comparing values and reports `fetched unreadable`. A sentinel
rather than an optional because `ActivityStreams.fetched` is not optional and
should not become so to serve a reader; the model belongs to the app, and this
is the reader's problem to name.

Which of the two the 7 August row actually is will be on screen at the next run.
Recorded here as an open question rather than a conclusion — §12.29.2.1.

### 12.42.2 A shortfall that was a decision

The same run reported **1 recording and 1 detail "in the store, not in the
database"**, in red, immediately after an import that had just written
everything it was willing to write.

`DataCorrections.ignoredActivities` refuses two sessions — a swim recording 400
m across 45 minutes, and a Romanian ride with 8.04 days of elapsed time.
`Sub4Import` declines their traces and details at the door (§256). `DetailStore`
keys by Strava id and never sees an `Activity`, so it keeps them.

The store therefore holds records the database will **never** hold, by design,
for ever. Counting them as missing produces a red row that is permanently
correct — which is a row that stops being read, and takes the real ones with it
when they arrive.

`missing` and `excluded` are now separate, and `excluded` is dim rather than
red, because it is a decision and not a shortfall.

#### 12.42.2.1 It also made D6b's exit gate unmeetable

`D6B-WRITE-THROUGH-GROUNDWORK.md` §5.5 proposed the gate as *the three
read-backs report 0 / 0 / 0 store-only records after a sync nobody triggered by
hand.* Written the same morning, and unreachable: two of those numbers can never
be zero while the exclusions exist.

A gate that cannot be met is worse than no gate, because it gets quietly dropped
rather than argued with. Amended in the same patch that made the distinction
visible — the gate is now **`missing` at zero**, with `excluded` shown beside it
and free to be non-zero.

### 12.42.3 What 297 actually measured, since it is worth writing down

**0.361 s**, and the reading needs care: it is the STEADY-STATE cost.

`Sub4Import+Recording` skips a trace whose stored `fetchedUTC` matches the
store's, so the run wrote 1,200 sample rows rather than 193,000 — `4 new, 0
replaced, 645 unchanged`. The expensive tables already have a changed-set, keyed
on the timestamp. The cheap ones (668 activities, 580 weather readings, 15
resting months) are re-upserted every time and cost nothing.

That settles §4.3's first row: **fire the import after every sync.** It also
retires most of §4.3's third row — the changed-set that would have been needed
already exists where it matters.

**The cold path is not measured.** After `resetCache()` or on a fresh install,
645 traces are all new and that is ~193,000 inserts, plausibly two orders of
magnitude slower. It does not change the decision, because `resetCache` is
deliberate and rare, but it is written down as unmeasured rather than assumed.

## 12.43 Do not reimplement the writer. Call it. — patch 299

Four lines of code, three versions, three patches, and the third one is the
lesson.

### 12.43.1 What 298 put on the screen

    17463863070 — fetched: store    2026-08-04T17:58:58Z,
                           database 2026-08-04T17:58:58Z

**The two dates render identically and the comparison called them different.**

That is a proof, and it does not depend on knowing why. `Sub4Import.iso8601` is
the function that wrote `fetchedUTC`. If two instants produce the same output
from it, the database cannot tell them apart, and a comparison that does is
disagreeing with the writer rather than reporting on the data.

It also explains the contradiction §12.42.1 recorded: the importer said `0
replaced` about this row, because the importer's rule for an unchanged trace is
`iso8601(store.fetched) == recording.fetchedUTC` — string equality on the
writer's own output. **The importer was right. It had been right all along.**

### 12.43.2 The three versions

| patch | rule | `fetched` differing |
|---|---|---|
| 291 | `.rounded()` | **320 of 668** |
| 291a | `floor()` | **1 of 668**, and 1 of 645 recordings |
| 299 | `Sub4Import.iso8601(a) == Sub4Import.iso8601(b)` | expected 0 — see §12.43.5 |

291's note, written at the fix, said:

> **A comparison has to model what the writer did, not what would be tidy.**
> Truncation is not an approximation of rounding.

Correct, and one word short. **Flooring is still a model of the writer.** It was
a much better model — 320 down to 1 — and a better model is still a second
implementation of something that already exists, which means it can differ from
the original, which means eventually it will.

The general form, and it cost three patches:

> **When a comparison and a writer must agree, do not reimplement the writer.
> Call it.**

### 12.43.3 What is proven and what is inferred

Kept apart on purpose — §12.29.2.1 is in this file because a conclusion was once
written from a measurement that did not exist.

**Proven.** `floor` on a `TimeInterval` and `ISO8601DateFormatter` do not agree
on every instant. The screen is the evidence: two dates, one rendering, one
disagreement.

**Inferred, and not needed for the fix.** The likely mechanism is an instant a
hair below a second boundary, where Foundation's calendar arithmetic and a
`Double` floor land on different sides. The store holds this trace's `fetched`
as a decoded JSON number, which is exactly where such a value comes from.

The fix does not rest on the inference. Calling the writer is correct whatever
the mechanism, and if the count does not go to zero the inference was wrong and
the finding is still real.

### 12.43.4 Why the tests did not catch it, twice

Every test of `sameSecond` from 291 onward checked **chosen pairs of dates
against a chosen rule**: a fraction of 0.6 compares equal, two seconds apart do
not. Each version passed its own tests and disagreed with the writer on real
data.

The property was never the pairs. It is:

> **A date must agree with what the database holds for it.** For every date.

`aDateAlwaysAgreesWithItsStoredForm` asserts exactly that — round-trip a date
through the writer and the parser and require agreement — across a spread of
fractions including boundary-adjacent ones. It would have failed at 291 and at
291a. `itAgreesWithTheImporter` pins the other half by spelling out the
importer's rule and requiring the two to reach the same verdict.

This is §12.16's warning in a new place. Equal counts hide changed values; here,
passing cases hid a wrong rule. **A test that checks the examples you thought of
cannot check the rule.**

### 12.43.5 The prediction

Stated so it can be falsified, the way §12.39.5 was:

**The next recording read-back reports `fetched 0`, and the next detail
read-back reports 12 differing rather than 13** — the `fetched` row leaving the
detail tally with the eleven `laps[*].averageHR` and one `splits[*].averageHR`
still there, because those are the importer's intended `positiveOrNil`
normalisation and nothing in this patch touches them.

If either number is different, the inference in §12.43.3 was wrong and there is
a second cause. The measurement goes in §12.43.6, after the run.

### 12.43.6 The measurement: it held

Run on 7 August at 12:02, patch 299 on the device:

| | before 299 | after |
|---|---|---|
| recordings | 648 of 649, `fetched 1` | **649 of 649** |
| details | 659 of 672, 13 differing | **660 of 672, 12 differing** |
| activities | 672 of 672 | 672 of 672 |

`fetched` is gone from both tallies. The detail tally is exactly
`laps[*].averageHR 11 · 30 elements` and `splits[*].averageHR 1` — eleven plus
one is twelve — and every one of those is the importer's `positiveOrNil`
normalisation, which is intended and documented at §12.37.5. **1,412,819 samples
compared, no disagreement.**

§12.43.5 predicted `fetched 0` and twelve differing details with those two rows
untouched. It held, to the number.

Worth writing down beside §12.39.6, where the other prediction was falsified:
**both outcomes were useful and neither was embarrassing.** The point of writing
a prediction down is not to be right. It is that a measurement taken against a
written prediction cannot be quietly reinterpreted to fit whatever it turns out
to be, which is the failure §12.29.2.1 exists to record.

The inference in §12.43.3 stands: `floor` and `ISO8601DateFormatter` disagree
somewhere, and the only comparison that cannot disagree with a writer is the one
that calls it.

## 12.44 D6a, closed

Ten patches, 289 through 299. Three readers, three comparisons, and four defects
found in the comparisons themselves rather than in the data.

### 12.44.1 The final state

| | in the database | compared | agreed | store-only |
|---|---|---|---|---|
| activities | 672 | 672 | **672** | 0 |
| details | 672 | 672 | **660** | 0 + 1 excluded |
| recordings | 649 | 649 | **649** | 0 + 1 excluded |

1,412,819 samples walked. The only residue in the entire corpus is twelve
details carrying the importer's deliberate `positiveOrNil` normalisation on a
zero heart rate, and two records the app refuses on purpose.

**The database holds what the app holds.** That is what D6a set out to
establish, and it is now a measurement rather than a belief.

### 12.44.2 Three numbers that took the whole rung to reach zero

    fetched differing      320  →  1  →  0        291, 291a, 299
    detail tally rows       25  →  3  →  2        295, 298
    store-only records   4/5/5  →  0/0/0          one import

None of the three was a defect in the data. All three were defects in what the
diagnostic could say about the data, and all three were invisible until the
comparison ran against the real corpus rather than fixtures — §12.36's argument,
now with four more instances behind it.

### 12.44.3 What it does not say

It compares the database to `ActivityStore` and `DetailStore`. It does not
compare either to Strava. That is D6c, it always was, and nothing in this rung
should be read as evidence about it.

### 12.44.4 What D6b inherits

Three read-back rows that now report zero. Their job changes from discovery to
regression: after write-through lands they should read zero for ever without
anybody pressing anything, and any other number is news.

The pattern they establish is the one D6b should extend rather than reinvent:

- an outcome type that cannot return `[]` for a failed read — six instances now
- stable field names, so a tally groups (§12.39.2, §12.40)
- a denominator on the screen, so a green result reads as a result rather than
  as an absence (`samplesWalked`, §12.39.6.1)
- absent-on-purpose kept apart from absent (§12.42.2)
- and, when a comparison must agree with a writer, **call the writer** (§12.43)



## 12.45 Everything the app holds, as one value — D6b step 1, patch 301

The first patch of the write-through rung, and it writes nothing. It exists
because of what was found when the trigger was designed.

### 12.45.1 Eighteen defaulted parameters and two hand-written call sites

`Sub4Import.run` takes twenty parameters; eighteen have defaults.
`SemanticVerifier.attempt` takes fourteen; thirteen have defaults, and thirteen
of the expressions feeding it are the same ones the import gets. Both lists were
assembled by hand inside `DatabaseHealthView`, forty lines apart:

    ActivityStore.shared.activities          AthleteStore.shared.allGear
    Array(NotesStore.shared.notes.values)    ProposalStore.shared.records
    ActivityStore.shared.syncState           DetailStore.shared.workItems
    ActivityStore.shared.receipts            Array(CommuteStore.shared.decisions.values)
    Array(Matcher.shared.decisions.values)   Array(WeatherStore.shared.byActivity.values)
    AthleteStore.shared.hrZones              Array(DetailStore.shared.streams.values)
    Array(DetailStore.shared.details.values)

**D6b's trigger would have been the third copy**, in code that runs unattended.

The hazard is not the duplication. It is the defaults: a forgotten argument is
not a compile error, it is **a table that quietly stops being imported**, and
nothing on any screen says so. A read-back would report those rows as missing
from the database — which reads as a data problem rather than as a forgotten
line, and is exactly the confusion §12.35.4 keeps naming.

This is §12.41.1's argument arriving from a direction it did not anticipate.
That section said not to hand-write seventeen incremental writers because each
is a chance to be wrong. The single writer that already exists has seventeen
chances to be **called** wrong, and two of them were live.

### 12.45.2 What it is, and what it deliberately is not

`AppStores` is a `Sendable` value with one field per store and a
`@MainActor current()` that reads them all. `Sub4Import.run(into:stores:)` and
`SemanticVerifier.attempt(_:stores:)` are **overloads** that forward field by
field; both granular signatures are untouched, so every existing import test
still calls what it called.

It changes no behaviour. That is the point: the proof is that the three
read-backs are unmoved at 672 / 672 / 649, and if the extraction dropped a table
they say which.

`Sendable` is not decoration. D6b hands this to a detached task after a sync,
and whether the app's own data can cross an isolation boundary is better found
out in a patch that changes nothing than in the one that adds a trigger.

**Not "snapshot".** `LegacySnapshot` and `SnapshotManifest` already mean *a
protected copy of the input files taken before anything decodes them* —
contract item 3. A third meaning for that word in the same subsystem costs a
reader more than the name is worth.

### 12.45.3 The gate moved, because a missing name there deletes

Patch 274's reconcile permission was computed in the view from a hand-written
list of store names, and `canReconcile` fails **closed** on any store that never
reported.

Read the failure direction carefully. A name that is **present** and untrusted
refuses — that is the gate working. A name that is **missing from the list
entirely** is never checked, so `canReconcile` is more likely to return true,
so reconciliation runs, so rows are deleted. **A forgotten name there is a
delete hazard, not a skip hazard**, and it lived in a view forty lines from the
argument list it governed.

`AppStores.reconcileRequires` holds it now, verbatim, beside the fields it is
about, pinned by a test.

Making the list **derive** from the fields is the right end state and is a
separate patch. Mixing a permissions change into a mechanical extraction would
make both harder to check, and this one is checked by a read-back that has to
come out identical.

### 12.45.4 A count is not a proof, and the comment says so

`AppStores.fieldCount` is pinned at seventeen and `theFieldCountIsPinned`
asserts `Mirror` agrees. That does not prove the forwarding — it makes adding a
field something somebody has to acknowledge, which is the half that is cheap.

Three fields are proved to land end-to-end, and `reconcile` gets its own test
because it is the one that deletes: a forwarding that dropped it would default
to skipping, which is safe, and one that inverted it would not — and only one of
those is visible without looking.

Stated at its real strength rather than dressed up. The same honesty §12.39.6.1
applies to `samplesWalked`: a check that can only report success has not been
tested.

## 12.46 Write-through, and the seam that was not there — D6b step 2, patch 302

The groundwork was wrong about the most important thing in it, and reading the
source is what said so.

### 12.46.1 Three write paths, not one

`D6B-WRITE-THROUGH-GROUNDWORK.md` §5.1 proposed raising a dirty flag in
`StoreWriteJournal.attempt`, *"which every store already passes through and
which already knows the store's name"*.

It does not. There are three:

| | path | stores |
|---|---|---|
| 1 | `StoreWriteJournal.attempt` | activities.json, constants.json, athlete.json, details/ and streams/, proposals.json, weather.json |
| 2 | `StoreWrite.encode`, thrown | notes.json, commutes.json — the WATCHED writes that roll back, §12.17 |
| 3 | `UserDefaults.set` | match decisions, rejection receipts, the detail store's skip lists, the sync cursor |

A flag raised in (1) covers six and misses **notes and match decisions** — the
two things in this app that cannot be re-fetched from anywhere. That is the
worst possible half to miss.

The claim was made from memory of a comment rather than from the call sites.
Patch 266's header says *"every store's `save()` goes through here"*, and it
meant every store 266 touched. Recorded because it is the same failure as
§12.40.5 — **prose describing a scope it never had, believed later by the person
who wrote it.**

### 12.46.2 So there is no dirty flag at all

Not "the flag moved somewhere better". There is none.

**The failure modes are not comparable.** A dirty flag fails SILENTLY: a store
that forgets to mark never reaches the database, and nothing says so — the
read-back would report its rows as missing data, which is §12.35.4's confusion
again. A whole-world run fails by being LATE: a missed trigger is picked up by
the next one, because the run does not depend on knowing what changed.

And the flag buys almost nothing. §12.42.3 measured a full run at **0.325 s**,
because the importer already skips a trace whose stored `fetchedUTC` matches.

> **A dirty flag is an optimisation with a silent failure mode, bought against a
> third of a second.**

That is the whole design decision, and it is why 302 has no `markDirty`, no
coalescing window and no timer. Coalescing is one boolean: a trigger arriving
mid-run makes the current run repeat once when it finishes.

#### 12.46.2.1 One trigger, on purpose

Backgrounding, in `ContentView`'s existing `onChange(of: scenePhase)` — beside
`BackgroundRefresh.schedule()`, which is already there for the same reason.

One is enough to start **because a missed trigger is late rather than lost.** If
the app is suspended before the task finishes, the ledger records a `running`
row and already reports it as "Interrupted runs", and the next backgrounding
does the work again. The design degrades into the state it was built to report.

More triggers — after a sync, on foreground after a long gap — are a later
patch, and each is one line. Adding them now would be adding untested paths to
the patch that first fires this unattended.

### 12.46.3 Automatic runs do not delete, and what that costs

`AppStores.current()` sets `reconcile` to `.run` whenever the four gated stores
read trustworthily, and reconciliation **deletes** rows the app no longer has.

Doing that by hand with the report on screen is one thing. Doing it unattended,
several times a day, is a different blast radius, and 302 is the patch that
makes it unattended. So `writeThrough` overrides it to `.skipped`, **inside the
function rather than at the call site**, so a future trigger cannot forget.

**The cost, owned rather than buried:** a note or a match decision deleted in the
app stays in the database until somebody presses Import. The three read-backs
would not notice — they report what the store has and the database does not,
never the reverse.

So this patch makes surplus rows in the database more likely, and nothing
currently detects them. That is D6c's question. It is written here so the next
person to find one knows it was a decision, not an accident, and the screen's
footer says it in plain words rather than leaving it to be discovered.

### 12.46.4 What is deliberately still open

- **The ledger.** Every automatic run opens and closes a `migration_run` row, so
  "the last import" now means "the last backgrounding" — which is arguably the
  right answer once write-through exists, and arguably makes manual and
  automatic runs indistinguishable in a list built to tell them apart.
  Groundwork §5.4, still open, deliberately not changed in the patch that first
  calls the import unattended.
- **The cold path.** Unmeasured since 297 and unchanged by this.
- **Deletions.** §12.46.3.

## 12.47 Two rows about one event — patch 303

302 was correct and looked broken. Both reasons are the same mistake in
different clothes: **a screen showing two answers to one question, one of them
wrong.**

### 12.47.1 The button that appeared to do nothing

Pressing "Write through now" twice left the Import ledger unmoved, and the
reasonable reading was that the button did nothing.

It did. `Last run` went 10:39:24 → 10:42:32 and `Runs since launch` went 3 → 4.
What did not move was the ledger row beside it, still showing 10:37:26 — the run
that was current the last time the screen was opened.

`runImport` has always ended with `await reloadLedger(db)`. The write-through
button did not, so two rows on one screen described the same event five minutes
apart. §12.34's shape: the older row was not wrong when it was written, and
nothing on screen said how old it was.

Three lines. The interesting part is that **the symptom pointed at the wrong
component.** A stale reader made a working writer look dead, and the first
instinct — mine included — was to doubt the trigger.

### 12.47.2 A red row that was correct and meant nothing

`ledgerSection` renders a missing `snapshotID` in **red**, which was right while
imports were rare and hand-pressed: a run with no protected copy of its inputs
is contract item 3 unmet, and worth shouting about.

302 passed `nil` for every automatic run. So from 302 onward the newest ledger
row would be red after every single backgrounding, permanently, for a condition
that is not a problem.

That is §12.42.2 again, one screen over — a red row that is correct by rule,
wrong in meaning, and frequent enough to train a reader out of believing the
colour. The last patch wrote §12.42.2 and the next one committed it.

**The fix is not to soften the colour.** An automatic run does not TAKE a
snapshot, but one exists, and it is genuinely the snapshot that preceded the
run. Recording `LegacySnapshot.latest()?.id` is accurate rather than convenient,
and it keeps contract item 11's link — *which snapshot of its inputs was taken
first* — true for automatic runs instead of quietly exempting them.

`nil` still means `nil`: on a device where no snapshot has ever been taken there
is nothing to record, and inventing one would be worse than the red row, because
it would claim a protected copy exists when none does. `noSnapshotStaysNone`
pins that.

### 12.47.3 What the in-memory figures can and cannot say

`Last run` and `Runs since launch` are held in memory on purpose — the question
they answer is *is this thing firing at all*, which is about now.

They cannot answer *did it fire while I was not looking*. After a relaunch the
section reads "Not run since this launch", which is true and is indistinguishable
from the trigger being broken.

The ledger already holds the durable answer, it is directly below, and after any
write-through it IS the newest row. So the footer now says which figure answers
which question rather than leaving a reader to work out that the two sections are
related. No second timestamp was added: two durable answers to one question is
the thing this section is about.

### 12.47.4 Still open, and now nameable

Manual and automatic runs are distinguishable in the ledger only by accident —
manual ones carry the snapshot the screen was holding, automatic ones carry the
latest on disk, and both are populated. `note` is already spent on the counts.

Telling them apart properly wants a `trigger` column on `migration_run`, which
is a migration and belongs in its own patch. Groundwork §5.4, still open, and
this is the second patch to decline it for the same reason: not in the one that
is fixing what the last one broke.

## 12.48 A time that is quietly wrong gets believed — patch 304

The write-through row printed `10:50:39` while the phone said `12:50`. Bruno
asked why, and the answer is that I had sliced the `Z` off an ISO-8601 UTC
string and printed what was left.

**A time that is obviously wrong gets questioned. A time that is quietly wrong
gets believed.** `10:50:39` is a plausible reading of a clock, so nothing about
it invites checking. The ledger row beside it at least kept the `Z` and was
therefore honest, if inconvenient.

### 12.48.1 Two kinds of timestamp, and only one moves

| | belongs to | rendered in |
|---|---|---|
| **machine** — an import ran, a snapshot was taken, a write failed | *now* | the phone's current zone |
| **activity** — when the athlete ran | *where the athlete was* | the activity's own zone |

The second category is already handled and must not be touched. Every `Activity`
carries `timeZoneIdentifier` and `startOffsetSeconds` for exactly this, and §4.1
says `startUTC` is authoritative for ORDER while `startLocal` is authoritative
for BELONGING. Rendering a run in Romania at Belgian time would be a new bug
wearing the fix's clothes.

`AppTime` formats the first category only, and its header says so.

### 12.48.2 What stays in UTC, and why that is not an exception

**The diagnostic paste.** `MigrationRun.line` and
`StoreWriteJournal.diagnosticLines` are text copied *out* of the app and read
somewhere else, possibly months later, by somebody who does not know where the
phone was. A local time in a paste is ambiguous unless it names its offset; the
ISO string carries its own `Z`.

**The snapshot id.** `2026-08-05-202320` is a **folder name**. It is a stamp
being used as an identifier, and localising it would break the correspondence
between the row on screen and the directory on disk — you could no longer find
what it names.

> **A timestamp that is a name is not a time.**

That line is the whole of the distinction, and it is why the fix is not "convert
every UTC string on screen".

### 12.48.3 The day boundary is local, which is the half that gets missed

`StoreWriteJournal`'s row said *"3 attempts since 2026-08-06"* by taking
`prefix(10)` of the ISO string. For anything that first failed after 22:00 in
Brussels that is the wrong day — the athlete's evening is already tomorrow in
UTC.

`theDayBoundaryIsLocal` pins it in both directions: 22:30 UTC on the 6th is
*today* in Brussels and *yesterday* in UTC, and both readings are correct for
their own zone.

### 12.48.4 A formatter that cannot parse must not invent

`AppTime.local` returns `String?`, and every call site falls back to printing
the raw value. Ugly and true.

The alternative was live for a while and cost a patch: `?? .distantPast` in
`RecordingRepository` turned an unparseable timestamp into a date in the year 1,
which the comparison then reported as a disagreement about *when* something was
fetched (§12.42.1.1). Sixth instance of §12.15's shape and the second time in
three patches that a date fallback was the thing that lied.

### 12.48.5 Two ways to get this wrong that are pinned rather than avoided

- **A hardcoded offset.** Brussels is UTC+1 in winter and UTC+2 in summer. A fix
  written in August with `+2` in it passes every test written in August and is
  an hour wrong for five months — small enough to read as a rounding problem
  rather than a bug. `theSameInstantMovesWithTheSeason` runs the same clock
  reading through both seasons.
- **`Locale.current` with a fixed pattern.** A phone set to 12-hour time can
  make `HH` render as 12-hour in some locales. `en_US_POSIX` is the fix and
  `alwaysTwentyFourHour` is the pin, because the symptom would be an
  off-by-twelve nobody could reproduce on their own device.

Every test names its zone and its `now` explicitly. A date-formatter test that
reads the machine's own settings passes on the machine that wrote it and proves
nothing.

## 12.49 Usually is not a mechanism — patch 305

302's trigger was:

```swift
if phase == .background {
    Task { await DatabaseWriteThrough.shared.run(reason: "…") }
}
```

It probably worked most of the time, and that is the problem with it.

### 12.49.1 What is actually wrong

An unstructured `Task` started at `.background` **suspends at its first `await`
and has no claim on the process.** iOS may suspend the app before it resumes.
The run itself is then handed to `Task.detached(priority: .utility)`, which is
precisely the class of work the system drops first when it is winding an app
down.

So the design was: *ask for a third of a second of work at the exact moment the
system has decided to stop giving us any, and hope the window is wide enough.*
Against a 0.33 s run it usually is.

**Usually is not a mechanism.** A trigger that works most of the time produces a
database that is usually current, and "usually current" is indistinguishable
from "current" until the day it matters — which is the same shape as every
diagnostic this file has had to correct.

Recorded plainly because it was mine, and because §12.46.2.1 argued the trigger
was sound on the grounds that a missed run is *late rather than lost*. That
argument is correct and it was doing work it could not do: it justifies having
**few** triggers, not having an **unreliable** one. Nothing in it says the app
will ever get around to the late run.

### 12.49.2 The fix is an ordering, not a bigger hammer

`beginBackgroundTask` is requested **synchronously in the scene-phase callback,
before any suspension point.** That ordering is the whole of it: an assertion
requested after the first `await` is an assertion requested from code that may
never run.

The expiration handler is UIKit's promise to warn before killing. If it fires,
the run is abandoned mid-write and leaves a `running` row that the ledger
already reports as an interrupted run — the honest outcome, and the reason
§12.46.2.1's "degrades into the state it was built to report" was the right
instinct even while the mechanism under it was not.

If iOS declines the assertion outright, nothing is attempted. That is not a
failed write and is not recorded as one.

### 12.49.3 And a second trigger, which is where the guarantee lives

**Returning to the foreground.** That is the moment the app definitely has time,
and it is what turns *late rather than lost* from an argument into a property.

Gated on `previous == .background`, because Control Centre and notification
banners produce `.inactive` — returning from a banner would otherwise fire a run
every time one appeared.

A background/foreground cycle therefore does **two** runs, and the redundancy is
deliberate rather than tolerated: the first is best-effort and the second is
certain, each costs 0.33 s, and the import has been idempotent since long before
anything depended on it. The observable signature is useful too —
`Runs since launch` rising by two per cycle is what a working pair looks like.

### 12.49.4 The gap this does not close, named rather than left

**`BackgroundRefresh.run()` mutates the stores and never writes through.**

It is a `BGAppRefreshTask`: it fetches activities from Strava, writes
`activities.json` and up to three details, and runs **without the scene being
built** — `Sub4App`'s own comment says so. So `Sub4Launch.shared.database` is
nil there, and a write-through from it would have to open its own connection,
which is the one thing `DatabaseHealthView` is careful not to do.

Today that is survivable: the next foreground `.active` catch-up picks up
whatever the background refresh wrote. It is the largest remaining staleness
window in D6b and it belongs to its own patch, alongside groundwork §5.4's
`trigger` column.

## 12.50 A transition that does not happen — patch 306

305 added a catch-up trigger gated like this:

```swift
if previous == .background, phase == .active { … }
```

**SwiftUI never delivers that transition.** Going out is
`.active → .inactive → .background`. Coming back is
`.background → .inactive → .active`. At the step where `phase` is `.active`,
`previous` is *always* `.inactive`.

So the condition could not be true, and the catch-up — the half of 305 that was
supposed to turn *late rather than lost* from an argument into a property —
never fired once.

### 12.50.1 What the device said, and what it took to read it

The test was: note `Runs since launch`, go to the home screen, come back. It
should have been **up by two**; it was up by one.

That reading was only possible because 305 wrote down what each number would
mean *before* the run — two is the pair working, one is the assertion declined,
zero is the wrong hook entirely. Without that, "1" is a number you can talk
yourself into.

It turned out to be a fourth case the list did not have: the backgrounding run
fired and the catch-up was unreachable. Worth noting that the written
predictions were still what made the result diagnosable — they narrowed it to
*one of the two did not run*, which is what sent me to the transition sequence
rather than to the assertion.

### 12.50.2 The fix is state, not a better predicate

`previous == .background` was trying to observe a fact — *we have been away* —
through a mechanism that cannot express it. The fact now lives where it is used:
`runOnBackgrounding` sets a flag, `runOnReturn` consumes it.

Set **before** the assertion is requested, and before the early return if one is
already held. A declined assertion is precisely the case the catch-up exists
for, so the flag must be set even when nothing is attempted on the way out.

`.inactive` stays a no-op in both directions. Firing on every `.active` would
mean a write-through after every notification banner, every Control Centre pull,
every glance at the app switcher — several a minute, for nothing.

### 12.50.3 The other reason this was hard to see

While the Database screen was open, an automatic run moved `Last run` and left
the Import ledger showing whatever was current when the screen opened.

303 fixed exactly this for the button and no further. An automatic run has no
call site to hang a reload on, so it kept the stale row — and the stale row is
what made a working trigger look dead, for the second time in four patches.

The screen now reloads the ledger whenever `runs` changes, whatever fired the
run. Keyed on the counter rather than on any particular trigger, so a trigger
added later inherits it.

**This is the third appearance of the same shape in this session** — §12.34,
§12.47.1, and now here. A screen holding two views of one event, where the
cheaper one updates and the expensive one does not, and the disagreement reads
as the system being broken rather than the screen being behind.

## 12.51 The path that wrote to the stores and not to the database — patch 307

D6b's last staleness window, and it was named in a code comment two hundred
patches before it mattered.

### 12.51.1 What `Sub4App` predicted

From patch 215's header, unchanged since:

> **NOTE FOR BACKGROUND REFRESH:** it does NOT go through `RootView`. A
> background wake runs `BackgroundRefresh.run()` without building the scene, so
> anything it eventually needs from the database has to open it itself. Nothing
> does today; 3.3.3 will have to.

This is that. A `BGAppRefreshTask` fetches new activities from Strava, writes
`activities.json` and up to three details — and until now left the database
untouched until somebody next opened and closed the app.

Everything else in D6b fires from the scene. This is the one path that changes
the stores with no scene to fire from, which is exactly why it was the last one
left and the easiest to forget.

### 12.51.2 `Sub4Launch.begin()`, not a second connection

The obvious move is `try Sub4Database.open()`. It is wrong: with the scene alive
that is a second `DatabaseQueue` on one SQLite file, and §12 already records
what that costs — *"the first symptom of that is a busy timeout on a screen
nobody suspects."*

`Sub4Launch.begin()` is idempotent, opens off the main actor, and runs the
migration. With the scene built it is a no-op that hands back the launch's own
connection; on a process woken for the task there is no other connection and
this creates the right one. **The gate that already exists is the answer, and
reaching for a new one would have introduced the defect the old one prevents.**

### 12.51.3 A race this patch creates, written down as created

`begin()` had exactly one caller until now, and one caller cannot race itself.
Its guard is followed by a suspension point:

```swift
guard case .opening = state else { return }
let outcome = await Task.detached { … }.value      // ← both callers get here
```

With a second caller, two could pass the guard and both open a queue on the same
file. `begin()` now holds the in-flight `Task`, so a second caller **awaits the
first and gets the same database** rather than starting its own — or returning
early to find `database` still nil, which would have been the lazy fix and would
have made the background write-through report `.noDatabase` for no reason.

Reachable rather than observed. It needs a scene construction and a background
wake in the same instant, which is unlikely and not impossible. Recorded as a
race **created by this patch**, because the alternative is a future reader
finding a defensive `Task` handle with no explanation and deciding it is
superstition.

### 12.51.4 What it does not do, on purpose

**It does not run when the task was cancelled.** A cancelled `BGAppRefreshTask`
means iOS is about to stop us; starting a third of a second of SQLite then buys
an interrupted `running` row rather than a write. The foreground catch-up takes
it, which is the whole point of §12.50's second trigger.

**It does not reconcile**, like every automatic run — §12.46.3.

**It costs about half a second** of a roughly thirty-second budget: the
migration check on an existing install is a few milliseconds, the import is
0.33 s, and constructing the stores that have not been touched yet in a woken
process is a handful of file reads. Repeated overruns make iOS schedule the app
less often, so this is worth stating as a measurement to take rather than an
assumption to keep: **the background refresh's own timing is not instrumented,
and this patch does not change that.**

### 12.51.5 No new tests, said rather than padded

`BGAppRefreshTask`, the scene lifecycle and `Sub4Database.open()`'s real file
are all outside the suite. Second patch in three with nothing to add, and the
honest note is better than a test that exercises something adjacent and reads
like coverage.

The verification is the ledger: a row whose reason came from a background
refresh, appearing without the app having been opened.

## 12.52 D6c groundwork, and a conclusion that changes what success looks like — patch 308

Documentation only. The design work for shadow parity, done before the code, and
it lives in `docs/D6C-SHADOW-PARITY-GROUNDWORK.md`. This section records the two
findings that shaped it.

### 12.52.1 The first comparison is expected to find nothing

D6a proved the two sides hold the same 672 activities with every field agreeing.
`ActivityStore`'s five derivation rules — `isKept`, `dedup`, the `startLocal`
sort, the day index, the zones — are **pure functions of `[Activity]`**.

Same input, same function, same output. So if both sides pass through the same
rules, the first parity comparison reports zero differences **by construction**,
and finds nothing because there is nothing left to find.

That is not a reason to skip it. It is a reason to be honest about what it is
for:

> D6c's value is not finding data differences — D6a ruled those out. It is
> building the mechanism that feeds the app from the database and proving it
> produces identical output, because that mechanism is what D7 switches onto.

Recorded because the alternative is running the rung, seeing green, and reading
it as evidence of something it never tested.

### 12.52.2 So the comparison has to be able to fail

A check whose answer is always "0 differences" is indistinguishable from a check
that is broken, and D7 gets flipped on the strength of it.

This project has the instrument already and it was built for exactly this
reason. The recording read-back reports 649 of 649 agreeing, and what makes that
readable as a **result** rather than an **absence** is the 1,412,819 comparisons
underneath it — §12.39.6.1.

So every D6c diagnostic carries a denominator, and — the harder half — a
**negative control**: some way to see the comparison report a difference known
to exist. Which control is open (groundwork §2.1) and is named there as the most
important unanswered question in the rung.

### 12.52.3 Extract the rules; do not reimplement them

The five rules are `private` to `ActivityStore`. A twin that reimplemented them
would be §12.43's mistake again — a second implementation of something that
already exists, which will eventually disagree with it.

There the disagreement was loud: 320 phantom `fetched` differences, visible on
the first run. **Here it would be silent** — two plausible activity lists
differing on one dedup survivor, with nothing able to say which is right.

`dedup` is the sharp edge. It sorts ascending by `startLocal`, then keeps
whichever of a near-duplicate pair has more moving time. Both halves are
order-dependent, so a reimplementation that got the sort direction wrong would
produce a *different survivor* from the same input — one activity, quietly
different, in a list of 672.

So the first patch of the rung is not a comparison at all. It extracts the rules
into one value both sides call, `ActivityStore` adopts it with no behaviour
change, and the existing 828 tests are the proof. Same move as 301, and for the
same reason: **before you can compare two things, one of them has to exist in a
comparable form.**

## 12.53 Both doors, the same rules — patch 309

Found by writing D6c's groundwork, which is what groundwork is for.

### 12.53.1 One rule was extended to both doors and two were not

`ActivityStore` has two ways in: `ingest`, from the network, and `load`, from
`activities.json`. They did different things.

    ingest:  activities = dedup(...).sorted { $0.startLocal > $1.startLocal }
    load:    activities = decoded.filter { Self.isKept($0) }

Patch 123 made `isKept` run at both, and its comment says exactly why:
`DataCorrections.ignoredActivities` changes, and a row already on disk *"would
have walked straight past a rule added after it was cached."*

**That argument applies to `dedup` and the sort with equal force, and was never
extended to them.** `duplicateWindowMinutes` and `duplicateDistanceTolerance`
are the same kind of tunable as the cutoff — and the cutoff has already moved
once, from 15 June to 1 January, as `MatchRules`' own comment records.

So the day either duplicate constant changes, cached pairs keep the old outcome
until the next sync, and nothing says so. Latent rather than live: nothing sets
those at runtime, and the file was written from an array that was already
deduped and sorted, so reading it back gives the same list.

### 12.53.2 It blocks D6c, which is why it is being fixed now rather than later

A shadow copy has to reproduce what the store holds. Until now **what the store
holds depended on which door it came through** — filtered after a launch,
filtered *and* deduped *and* sorted after a sync.

A twin cannot match a moving target. §4 of the D6c groundwork extracts these
rules into one value both sides call; that extraction is meaningless while the
rules are applied inconsistently on the side being copied.

### 12.53.3 Measured rather than assumed

"It should change nothing" was the prediction, and a prediction with no
instrument behind it is an assumption.

`loadCollapsedDuplicates` and `loadArrivedUnsorted` say what the load path
actually had to correct, and Settings prints them — **only when non-zero**,
because a permanent "0" row is a row that stops being read (§12.42.2).

They are separate numbers because they are separate faults: one says the cached
rows held a pair the current rule folds together, the other says something wrote
the file out of order. In memory rather than persisted, because they describe
this launch's file and the current file already answers the question.

§12.41.2 records what happens to a measurement nobody displays: `Report.seconds`
was computed and thrown away for forty patches, and it was the number D6b's
design turned on. `lateArrivals` in this same file is the next one — computed at
every ingest since patch 45 and displayed nowhere. Not this patch's job, named
here so it is not lost.

### 12.53.4 What the risk actually is

The change is one line of behaviour on a path that runs at every launch, on a
device with 672 activities and no backup of the in-memory list.

It is safe in the direction that matters: `dedup` and the sort are pure, they
cannot lose an activity the current rules would keep, and `activities.json` is
not rewritten by `load` — so a wrong outcome is corrected by the next launch
rather than persisted. The three read-backs are the check, and they compare
against the database, which the load path does not touch.

## 12.54 The rules as a value, and a rule I had just written down — patch 310

D6c step 2. It moves three private methods into one type and closes a hole 309
opened while fixing a different one.

### 12.54.1 Three rules decide what the list IS

`ActivityStore` holds activities; what is in that list is decided by three
rules — which are kept, which pairs are one session uploaded twice, and what
order they are in. They lived as `private` methods on the store, which is
exactly the arrangement that let the two entrances drift apart for two hundred
patches (§12.53).

309 made both doors agree by writing the rules out twice. 310 makes disagreement
**unavailable**: `ActivityRoster.settle` is one call and both entrances make it.

That matters beyond tidiness. D6c compares what the app *computes* from two
sources, so the database side has to produce the same list from the same rules —
and a second implementation of a rule that already exists is the mistake §12.43
cost three patches to learn. **When two things must agree, do not reimplement.
Call.**

`settlingTwiceChangesNothing` pins idempotence, which is what makes it safe to
call from both doors and from a twin that may be fed either side's output.

### 12.54.2 A rule this file already contained, broken four hours after it was quoted

309 shipped its two counters *hidden when zero*, reasoning from §12.42.2 that a
permanently-correct row trains a reader to ignore it.

Then the device showed neither row, and the honest reading was: **that means
zero, or it means nobody wired them in, and a screenshot cannot tell.**

§12.42.2 is about a permanent **alarm**. I applied it to a permanent **count**,
and they are not the same thing. The distinction was already written down twice
in this project, in the diagnostics paste:

> *Patch 266c.* A section that simply vanished when nothing was wrong would be
> indistinguishable from a check that never ran.
>
> *Patch 273.* A line that only appears when something is wrong cannot be
> distinguished from a line nobody wired in.

Both about the same screen. Both written before 309. **A count beside its
denominator is evidence; a bare zero is noise; a missing zero is nothing at
all** — which is precisely why `samplesWalked` exists (§12.39.6.1), four days
earlier, in a patch of the same week.

So the fix is not "show a red 0". It is one always-present row stating the
positive with its denominator:

    Activities loaded    672 · 0 collapsed · in order

Absent now means broken. Present with zeros means checked and clean.

#### 12.54.2.1 What still cannot be proved, and what was done instead

Nothing here proves the pixel drew. This project has no UI tests and adding a
framework for one row would be the wrong trade.

Three things are done instead, each with its honest limit:

| | proves | does not prove |
|---|---|---|
| `Result` carries the counts, tested | the number is produced | that anything displays it |
| the row is unconditional | absence is now a symptom | that it rendered |
| the counts join the redacted paste | the value exists even at zero | that the paste was read |

The realistic failure being designed against is not *wrong*, it is
**indistinguishable from fine** — the same shape as `?? .distantPast`
(§12.42.1.1), where a fallback made a reader defect wear a data difference's
clothes.

### 12.54.3 `Result.offered` is the denominator, and it is the point

`dropped`, `collapsed` and `arrivedOutOfOrder` are all differences. `offered` is
how many were looked at.

Without it, "0 collapsed" and "nothing was examined" read identically — which is
§12.39.6.1's argument arriving one layer up. `nothingToCorrectStillSpeaks` is
the test for the boring case, and it is the case that runs on the device every
single day.

### 12.54.4 `arrivedOutOfOrder` means nothing at one of the two doors

`ingest` settles a dictionary's values, and a dictionary has no order to be out
of. `load` reads a file something wrote deliberately, and there it is a real
fact about the writer.

Both doors call the same function; only one reads that field, and `Result`'s
own comment says which and why. The alternative — two entry points differing by
one returned value — is how §12.53 started.

## 12.55 Who started this run — patch 311

`migration_run: 45` in the diagnostics paste. Forty-five ledger rows after three
days of D6b, and no way to tell which were a person pressing a button and which
were the app writing through on its own.

### 12.55.1 The distinction existed, and it was never a column

Until patch 303 the two could be told apart **by accident**: an automatic run
passed no snapshot id, so a NULL in `snapshotID` meant "not a manual import".

303 fixed a real defect — an automatic run does have a snapshot preceding it, and
recording it is accurate rather than convenient (§12.47) — and in doing so
removed the only distinction the table had. Nothing was wrong with 303.

> **A side effect is not a record.** A fact you can only read by knowing which
> other fact happens to be absent is a fact you will lose the first time
> somebody fixes the absence.

That is the same shape as §12.42.1.1's `?? .distantPast` and §12.15's whole
family, arriving from a new direction: not a diagnostic that cannot say why it
has no answer, but an answer that was only ever a coincidence.

### 12.55.2 A table whose own comment stopped being true

`Sub4Migrations+MigrationRun.swift` says, in the body of the migration:

> The only query this table has: newest first. **Small forever — one row per
> import** — but the index costs nothing…

True for two hundred patches. False the day D6b landed: a background/foreground
cycle writes **two** rows on its own (§12.49.3), and `BackgroundRefresh` adds
more. Forty-five in three days, growing, with no upper bound anywhere.

So retention, and the argument is entirely about what it does **not** remove:

| kept forever | why |
|---|---|
| `manual` | the athlete did it on purpose |
| `failed` | the reason anybody opens this table |
| `running` | the only evidence the app was killed mid-write |
| `verified`, `activated` | D7 decides on the strength of these |
| trigger not recorded | the 45 cannot be identified as automatic |

Only *successful automatic* runs are trimmed, beyond the newest 200 — a few
weeks at two per app switch.

`prunableTriggers` is **written out rather than derived**. `allCases.filter { $0
!= .manual }` is the obvious expression and it fails in the wrong direction: a
trigger added later would be swept into the prune by default. Written out, a
forgotten trigger makes the table grow — visible in the census — and an included
one destroys evidence, which is visible nowhere. **Between a leak and a
shredder, pick the leak.** `prunableIsEveryAutomaticTrigger` asserts the two
agree today, so adding a case is a decision somebody makes rather than one that
gets made for them.

### 12.55.3 The defect found while reading, which is the point of reading

```swift
static func stale(_ db: Sub4Database) throws -> [MigrationRun] {
    try all(db, limit: 100).filter { $0.state == .running }
}
```

It asks for the newest hundred rows and then looks for interrupted ones among
them. At patch 255, when this table held one row per import, a hundred was the
whole table. At D6b it is **about a day** — so an interrupted run from two days
ago was already invisible, and the screen said `Interrupted runs: 0` with
complete confidence.

> **A count taken from a page is not a count of the table.**

Nothing about the old code looks wrong. It broke because a number that was a
generous over-estimate became a tight limit, without a line changing.
`anInterruptedRunIsFoundBeyondThePage` builds 151 rows over one interrupted run,
which is the size the old implementation fails at.

### 12.55.4 Two rows and a tally, all unconditional

§12.54.2 was written down four hours before this patch, and this screen had two
live instances of the thing it describes:

- **Interrupted runs** was `if staleRuns > 0`. Combined with §12.55.3, that row
  had two ways to be absent — nothing wrong, or something wrong two days down
  the table — and a screenshot could not tell them apart.
- **Started by** would have been the same the moment it was written as
  `if let t = r.triggeredBy`, because NULL is what the 45 existing rows hold.

Both are unconditional. A NULL prints `not recorded (before patch 311)`, which
is the truth about those rows and is why the column is nullable at all: a NOT
NULL with a default would have meant guessing a value for them, and a guessed
`backgrounded` is indistinguishable from a recorded one.

The paste gains a census that names **every** trigger every time, at zero, with
the row total as its denominator — §12.54.3's argument arriving one screen over.
`migration_run: 45` is what a number without a breakdown looks like.

### 12.55.5 Four values, not five, and the reason it is not tidiness

Three buttons produce a manual run: Import and Write through now on the Database
screen, and Run the task now in Settings. All three are `manual`.

`DatabaseWriteThrough.run` therefore takes **both** a `trigger` and a `reason`,
which looks redundant and is not. The trigger is a stored value from a frozen
vocabulary that a query groups by; the reason is a sentence a person reads in
the unsaved-stores list when a write fails, and it distinguishes things the
vocabulary deliberately does not. Collapsing them costs either the journal's
detail or a fifth enum case meaning "manual, but from the other button" —
§12.39.2, where a field name that carries detail stops being a field name.

### 12.55.6 `trigger` is required in exactly one place

The `AppStores` overload — the single door every production import comes through
(§12.45). The granular signature under it defaults to nil, so the several dozen
test call sites that have no answer are untouched, and the two call sites that
do have one cannot forget.

Which is §12.45's own argument about defaulted parameters, pointed at the
parameter that says who caused the run.

## 12.56 The twin, and the first comparison — patch 312

D6c slice 1. 309 and 310 built the half nobody could see: one implementation of
the three rules, called by both of the store's doors. This builds the other half
— the same list, derived from the database — and compares them.

### 12.56.1 A different question from the three above it

The read-backs ask *do both sides hold the same records?* Answered at D6a: 672
activities, 672 details, 649 recordings, 1,412,819 samples, every field compared
by name.

This asks *would the app produce the same list?* Between the rows and the list
stand five rules, and it is the derived list that every screen actually reads.
Equal records do not imply equal derivation.

So it compares only what D6a cannot see: identity as a **set after the rules**,
**order**, **day membership**, and the **zones**. It re-checks no fields. A
second comparison of the same nineteen fields would eventually disagree with the
first, and then neither could be believed.

### 12.56.2 Three patches to make one sentence true

> There is one implementation of every rule in this comparison.

- **309** made both store doors apply the same rules, by writing them out twice.
- **310** made disagreement unavailable: `ActivityRoster.settle`, one call.
- **312** moves `byDay` — one line from a `didSet` — and builds the twin.

`byDay` is the smallest of the three and the clearest illustration. It is
`Dictionary(grouping: activities, by: \.dayKey)`, and copying it into the twin
would have looked free. It is not free, because it carries a promise: encounter
order is preserved, and patch 168's comment says callers depend on that. **One
line copied twice is still two implementations**, and the second copy would have
agreed only while both sides happened to keep sorting the same way.

`DayZones.from` needed no move — it was already a `nonisolated` pure function
with an `Equatable` result, which is what a rule looks like when it was written
in the right place the first time.

### 12.56.3 A row the rules refuse is not a difference

The twin drops what the store would drop, so an activity the database is
carrying that the app no longer wants appears as `databaseDropped` — **not** as
`databaseOnly`.

That distinction matters more than it looks. §12.46.3 owned a cost when
write-through landed: automatic runs do not reconcile, so a record deleted in
the app stays in the database until somebody presses Import. Until now nothing
counted them. `databaseDropped` is the first instrument for that gap, and it is
deliberately **not red** — a number there is the known behaviour of an automatic
run, not a fault.

### 12.56.4 Making a zero believable

Groundwork §2.1: the first comparison will almost certainly report zero
differences, because D6a ruled out data differences and both sides now share the
rules. **A check whose answer is always "no differences" cannot be told from a
check that is broken**, and D7 would be flipped on the strength of it.

Three answers, each with its limit:

| | proves | does not prove |
|---|---|---|
| `ActivityParityTests` — seven planted differences | the comparison reports what it is given | that the device's data is right |
| `common` beside every count | a dead read cannot look like agreement | that the read was complete |
| both sides built from different places | they are not the same object | it, at runtime — this is read, not checked |

`nothingComparedIsNotAgreement` is the one with teeth. Zero compared against
zero agrees perfectly, `unexplained` is honestly 0, and `lookedAtSomething` is
what refuses to let that read as a pass. Without it the healthiest-looking
screen in the app would be the one where the read died.

Every planted difference is built through the real `Sub4Import` and read back
through the real `ActivityRepository`, then perturbed on the store side. There
is no runtime answer to "both sides are secretly the same object"; constructing
them from different places, and saying so, is the whole of it.

### 12.56.5 Order is compared over the common ids only

A single missing activity shifts every position after it. Comparing the raw
sequences would report one absence as four hundred order differences — the same
mistake §12.39 had to fix for sample lengths, where one short stream reported as
three hundred differing samples.

So identity is settled first, and order is compared over what both sides have.
`orderCompared` is printed beside `orderDiffered` for the reason every number on
this screen now is.

### 12.56.6 No approved-difference list, and that is a decision

Groundwork §5 defines one. Both its entries are about details and recordings;
for activities the expected count is zero.

An empty suppression list shipped now would be a gate nothing has passed
through, and the moment a list exists it starts attracting entries. It gets
built in the slice that has one. Until then the screen says so in as many words:
every number above zero is real.

## 12.57 The numbers derived from the list — patch 313

D6c slice 2. Slice 1 proved both sides derive the same list; this compares what
the app computes from it.

### 12.57.1 Three figures, and each sees something the others cannot

| | what it is | what only it can catch |
|---|---|---|
| `DayDistance.of` | one day's distance | a day that stops being a distance |
| `recordedByWeek` | training + commute, per week, per discipline, per unit | a week that moved between units |
| `VolumeSeries.mix` | the whole history in six bands | a ride that changed band |

The first is the interesting one. Patch 249 made `DayDistance` **refuse to add
kilometres across sports** — a day with a ride and a swim is reported in
minutes, because minutes add and kilometres do not. So the answer is not a
number, it is one of three shapes, and a day that changes shape is a difference
that **every field comparison in this project would call agreement**: every
field on every activity still matches.

That is the argument for comparing derivations rather than records, made
concrete. §12.16 warned that equal counts can hide changed values; this is one
layer further out — equal *values* hiding a changed answer.

### 12.57.2 The window was the problem, and the fix is the 312 move again

`VolumeSeries.weeks` bucketed only the 26 weeks it draws. Comparing what it
returns would have reported a clean half year and said nothing about the eight
months before it — a denominator of 26 where the honest one is 58, and no line
on screen saying which.

So the twelve lines that bucket recorded activities became
`VolumeSeries.recordedByWeek`: no clock in it, keyed by the Monday's day-key,
covering everything. `weeks()` reads its window out of that.

**This is the third time in four patches.** `byDay` at 312, `isKept` and `dedup`
at 310, this now. The pattern is the same each time: a rule written where its
only caller lived, and a second caller arriving that must not reimplement it.
Worth naming as a rule rather than three incidents:

> **A derivation with one caller looks like part of that caller. It stops being
> that the moment something else must agree with it.**

`theWeekBucketingIsUnmoved` is the test the extraction owes, because four charts
read `weeks()`. It asserts the drawn figures are what the shared function
produced, which is the half a refactor can get wrong silently.

`recordedByWeek` returns an **empty dictionary** for a discipline with nothing
recorded, not a row of zeros. Absent means "this sport does not appear in this
history"; a zero would mean "it appears and did nothing", and only one of those
is true of somebody who has never swum. §12.15's shape, in a dictionary.

### 12.57.3 A tolerance, and why it is on screen

Both sides sum the same doubles from lists `settle` put in the same order, so
exact equality should hold today.

**Should is not a mechanism** — §12.49 cost a patch to learn that sentence. One
reordering anywhere upstream and `==` starts reporting 1e-15 as a data
difference. The first time a gate cries wolf is the last time anybody reads it,
and this project has spent five patches on diagnostics that could not be
believed.

So: **one metre, one second.** Below that a difference is how two identical sums
ended in a different last bit; above it, it is data.

Two things about it are deliberate. It is **printed on screen beside the
verdict**, because a threshold nobody can see is a threshold nobody can argue
with — and a hidden `==` with a fudge factor is exactly the shape of the
diagnostics this file keeps having to correct. And it applies **only to
doubles**: `DayDistance.minutes` and `.none(minutes:)` are `Int`, the
discipline is compared exactly, and the *case* is compared exactly. A tolerance
on an integer would be an invitation.

`theToleranceIsNotAWildcard` pins both ends: half a millimetre passes, ten
metres does not. An untested tolerance is a hole nobody has measured.

### 12.57.4 One section, one button — groundwork §7, answered

§7 left the shape open until there was more than one comparison to lay out.
There are two, and they need the **same** 672-row read and the **same**
`settle`. Two buttons would do that work twice, and — the real argument —
somebody who pressed one and not the other would get an answer that looked
complete and was half.

So `ShadowParity` runs both and holds the result, and `ActivityParity` and
`VolumeParity` become pure comparisons: two `[Activity]` in, a `Report` out, no
database, no store, no clock. That is what lets their tests build the two sides
from genuinely different places, and slice 3 inherits it.

### 12.57.5 The result used to evaporate, and the paste said so

312 held the result in `@State` on the sheet. Pressing Done discarded it, so the
diagnostics paste — the thing read later by somebody who was not there — said
*"Not compared since this launch"* one minute after the comparison passed.

The line was **true of the `@State` and false about the world**. Not a wrong
number; a right number about the wrong subject, which is harder to spot and is
why it survived a screenshot and a paste in the same minute.

It lives on a singleton now, like `DatabaseWriteThrough` since 302, and survives
dismissal within a launch. **Not persisted** — the question is "does the
database agree with the app right now", and a stored answer from three launches
ago would be a second answer to a question the current data already settles
(§12.29).

Only parity moved. The three read-backs and the survey keep their `@State` and
the same trap; changing five things to fix one is how a slice patch stops being
checkable, which is patch 274's rule about not mixing a permissions change into
a mechanical extraction.

## 12.58 The day walk, extracted — patch 314

D6c slice 3, part one. No new comparison: one function moves and gets the first
tests it has ever had.

### 12.58.1 The note §12.16 left was aimed one layer too high

It said: *one `PMC` over two readers, not two builders*. Reading the source says
that was already true. `PMC.build` takes `[DailyLoad]`, returns `[PMCPoint]`,
touches no clock and no singleton, and has twelve tests.

The builder that needed splitting is underneath it. `LoadStore.recompute` walked
four hundred days over a four-rung scoring engine and, inside the walk, read
**eight** singletons: `ActivityStore`, `DetailStore`, `ConstantsStore`,
`AthleteStore`, `NotesStore`, `PlanStore`, `Matcher` and `HealthStore`.

That is the fourth instance of one rule in five patches — `isKept` and `dedup`
at 310, `byDay` at 312, `recordedByWeek` at 313:

> **A derivation with one caller looks like part of that caller. It stops being
> that the moment something else must agree with it.**

This is the largest of the four. Thirteen files read what it produces: Today's
load strip, the PMC card, monotony, the Week tab, the monthly review.

### 12.58.2 The split is not tidiness, it is what makes a twin possible

`LoadSeries.build` walks the days. `LoadStore` still decides what to feed it —
reads the stores, measures the power factor, maps sRPE through the plan and the
matcher, asks Apple Health for the heart rates Strava does not have.

Slice 3's method is to hold every input identical on both sides except the
activities and the traces, and vary those. **That is only possible if the walk
has no hidden inputs.** An argument list of eight is the honest shape of a
function that genuinely depends on eight things.

One input is a closure and stays one: `hrRest(dayKey)`. The rule behind it —
that month, then the nearest month within three, then the override — lives in
`ConstantsStore` and belongs there. Flattening it to a dictionary here would be
the exact mistake this section is about.

### 12.58.3 The slice order is wrong, and it is worth recording

The load series needs constants, FTP, notes and plan matching. The database
holds all of them in tables and has a repository for **none** of them — those
are slices 5 and 6. Slice 3 sits before its own inputs.

The groundwork's order was written before anybody had read `recompute`. It is
not corrected by reordering, because there is a reason to do slice 3 now:

> D6a accepted a known loss in the traces — *a stream shorter than the distance
> axis comes back padded with zeros and its original length is gone.* Nothing
> has ever asked whether that costs a number the athlete reads.

`LoadEngine` scores from the trace when it has one, so slice 3 is the first
thing that could say. A comparison with a real way to fail is worth more than
one that waits for its inputs — §2.1 of the groundwork.

One input can never come from a database: Apple Health's average heart rate,
which engine version 4 uses where Strava has none. It is a cache of somebody
else's store. Named in `Inputs`, held identical on both sides, and stated rather
than quietly ignored.

### 12.58.4 Seventeen tests where there were none

`recompute` has never had a unit test and could not have had one: a test would
have had to stand up eight singletons. That is why `PMC.build` has twelve and
the thing feeding it had zero — not neglect, a shape.

Two have teeth.

**`everyDayIsPresentIncludingTheEmptyOnes`.** An exponential moving average is
only defined over a series with no holes. Treating "no row" as "no load" is the
single most common way a home-rolled fitness curve goes wrong, and it shortens
the window silently.

**`nothingScoredIsAGap`.** A rest day and a gap both produce `load == 0`. The
**only** thing that distinguishes them is `DayState`, and a curve drawn across a
gap is wrong for six weeks afterwards. A refactor could flatten that distinction
without a single number moving — which is precisely the class of defect a green
suite over numbers would not see.

`aPartialDayCountsOnlyWhatScored` is the same argument at the day level: adding
an unscorable session must move the state and must not move the total.

### 12.58.5 What this patch deliberately does not do

It adds no comparison, no screen row and no repository. The only proof it offers
is that thirteen screens are unmoved — the suite, and Today, Week and Progress
on the device.

Splitting it that way is patch 274's rule: a mechanical extraction and a
behaviour change in one patch make both harder to check, and here a moved load
figure would have had two candidate causes on the most visible screens in the
app.

## 12.59 Fitness and load, compared — patch 315

D6c slice 3, part two. Both sides build a `[DailyLoad]` through the one
`LoadSeries.build` that 314 extracted, and the comparison walks every day, every
session inside it, and the curve on top.

### 12.59.1 What it isolates, and the list of what it does not

Constants, FTP, sRPE and Apple Health come from the **app on both sides**. Not
for convenience:

- the database holds constants, FTP, notes and the plan in tables and has a
  repository for **none** of them — slices 5 and 6 (§12.58.3);
- Apple Health's average heart rate is a cache of somebody else's store. No
  database this app writes will ever hold it.

So one variable is isolated: **what the database's activities and traces
produce.** `heldFromTheApp` is printed on screen and in the paste, because a
comparison that does not state what it held constant produces a number nobody
can interpret.

The inputs are **taken, not re-gathered**. `LoadStore` remembers what its last
rebuild used and the twin changes exactly one field of it. Re-reading the stores
in `ShadowParity` would have been a second implementation of twenty lines of
gathering, and the two would eventually have disagreed about an sRPE or a power
factor with nothing able to say which was right — §12.43 one layer up from where
it usually bites.

That carries a cost worth stating: sRPE and Health are keyed by activity id and
were gathered over the **app's** list, so an activity the database has and the
app does not would score without either. Slice 1 reports that case directly as
`In the database only`. It is visible — there, and not here.

### 12.59.2 The row this slice was built for

The Database screen has said this since D6a, in its own words:

> A stream that was shorter than the distance axis comes back padded with zeros
> and its original length is gone — that is a real loss and it is expected to
> show here.

An **accepted** loss. And nothing had ever asked whether it costs a number the
athlete reads.

`LoadEngine` scores from the trace when it can and falls back to the session
average when it cannot, and the two rungs do not produce the same figure — the
average under-scores intervals by about 8%, which is the whole reason the trace
rung exists. So a padded trace can move a session between rungs, which moves a
day, which moves the curve.

**`Sessions on a different rung` is that question asked.** It is also what makes
this a comparison with a real way to fail, which groundwork §2.1 demands of
every one of them — and slice 3 is the first where nobody could have checked by
eye. Two four-hundred-day fitness curves cannot be eyeballed.

### 12.59.3 A rung is the cause; a figure is the effect

When a session's source differs, its figure differs too — necessarily. Reporting
both would count one fault twice and send somebody to the arithmetic instead of
to the trace.

So the comparison reports the rung **or** the figure, never both, and the tests
pin it: `aPaddedTraceIsCaughtAsADifferentRung` asserts
`workoutsWithDifferentFigure` is *empty*. §12.39's rule — name the field, not
the row — with a second clause: name the cause, not the consequence.

### 12.59.4 Two denominators, because one of them can lie

`daysCompared` is not enough. A device with four hundred rest days in it would
report four hundred days compared and describe **no training at all** — every
day agreeing because every day is empty.

So `workoutsCompared` sits beside it and `lookedAtSomething` requires both. That
is `samplesWalked` (§12.39.6.1) arriving in a third place, and
`restDaysAloneAreNotAPass` is the test for exactly the case a day count alone
would wave through.

`DayState` is compared **exactly**, with no tolerance. A rest and a gap both
carry a load of zero and the state is the only thing between them (§12.58.4);
admitting a tolerance there would erase the distinction the whole load engine is
built around. Only the TRIMP figures get one, at 0.01 — four decimal places
below anything displayed — and it is printed beside the verdict for §12.57.3's
reason.

The curve is compared over **every point**, not just its last. A difference in
March that has decayed away by August would be invisible in the headline and is
still a difference.

### 12.59.5 A slice that could not run is not a slice that passed

`LoadParity.Report` is optional inside `ShadowParity.Outcome` — `lastInputs` is
nil on a device that has never built a load series.

A nil slice counts as **one difference**, not as zero, and the screen says *"the
app's load series was not built"* rather than showing nothing. Every version of
this screen that has treated a missing answer as a clean one has had to be
corrected: 309's hidden counters (§12.54.2), 311's hidden interrupted-runs row,
312's evaporating result (§12.57.5). Three times in six patches is a habit, and
`aMissingSliceIsNotAPass` is the test that breaks it.

### 12.59.6 The apply script is gone, and that is a fix

313's and 314's scripts both went unrun. Neither failure had a symptom: every
Swift file in both patches was a wholesale copy, so `cp` did all the work that
shows, and the script's only remaining job was this document. Green build, green
suite, correct device, missing section — twice.

314 added a check that the previous patch's section had landed. That was the
wrong fix: it makes the script better at reporting a failure that happens
because the script is skipped.

**The right fix is to remove the step.** The ADR now ships as a file in the patch
zip and arrives by the same `cp` that has never once failed. A step that can be
skipped without symptom is a step that will be, and adding a check to it only
moves the silence.

## 12.60 The shape under the number, and an argument that was wrong — patch 316

315 compared each session's rung and its TRIMP. It did not compare
`WorkoutLoad.hrSeconds`, the seconds-per-heart-rate histogram that is the whole
input to the Time-in-zone card. This adds it.

### 12.60.1 The reason given for adding it was false

The argument was: *TRIMP is a scalar integral, the histogram is the distribution
under it, and two different distributions can integrate to the same number —
§12.16's warning one level deeper.*

It reads well. It is wrong, and checking the arithmetic is what said so. Both
quantities come from **one walk over one set of bins**:

    TRIMP     = Σ (dt / 60) × f(bpm)
    histogram = Σ dt,  keyed by round(bpm)

Same bins, same skip rules, same guards. **The histogram determines the TRIMP.**
Move a minute from 140 bpm to 160 and the integral moves 2.3% — hundreds of
times the tolerance — because `f` is exponential in the heart-rate fraction.
Every case the first argument described was already caught by 315, and the test
written for it would have passed while proving nothing.

> **Do not reason by analogy about two numbers without checking whether one
> determines the other.**

That is §12.43's cousin. §12.43 says do not reimplement a rule; this says do not
inherit a rule's *justification* for a pair of quantities that do not have the
same relationship. The analogy to §12.16 was structurally identical and
factually empty.

Recorded here rather than quietly corrected, because the wrong version survived
being written down, read back, and half-implemented before anybody multiplied
anything out.

#### 12.60.1.1 And then the same mistake, one line lower — 316a

The zone roll-up was written as `ZoneTime.build`. `ZoneTime.swift` is the FILE;
the type inside it is `ZoneTotals`. The signature had been read out of the
source; the enclosing type was inferred from the filename.

Same failure as the paragraph above it, at a smaller scale: a fact taken from
something that *resembled* the source rather than from the source. Both mistakes
in this patch are the same mistake — one caught by multiplying two numbers out,
one caught by a type-checker in four seconds.

The cheap one is the one worth noticing. `ProgressTabView` calls
`ZoneTotals.build(days:zones:window:)` and has done for patches; one grep for
the existing caller would have settled it, and the caller is the thing this
patch is trying to agree with.

### 12.60.2 What is actually left, and it is one line wide

The integral uses the **exact** heart rate; the histogram **rounds** it to an
integer.

So a trace differing by two hundredths of a beat on one bin moves that bin into
the next bucket while moving the TRIMP by about 0.0015 — below the 0.01
tolerance §12.59 sets. If the bucket sits on a zone boundary, a minute of the
athlete's year crosses zones, the Time-in-zone card moves, and every figure 315
compares still agrees.

`aRoundingDifferenceMovesAZone` builds precisely that: one bin of sixty, 149.49
against 149.51, with Z2 ending at 149 and Z3 starting at 150. It asserts the
rung agrees, the load agrees, and the histogram does not — which is the whole
claim of this patch stated as a test rather than as a paragraph.

### 12.60.3 The larger reason, which survived the correction

Until now the Time-in-zone card was covered by **inference**: the TRIMP agrees,
therefore the histogram must.

That inference is sound today and only because both figures come from one walk.
It breaks the day the trace rung gains a second path, or the day
`streamHistogram`'s guards drift from `streamTrimp`'s — and it breaks
**silently**, because nothing anywhere asserts the two stay coupled.

Replacing an inference with a measurement is what this whole rung is for. A
comparison that never fires is cheap; an inference that stops holding without
saying so is what §12.15 has been about for fifty sections.

### 12.60.4 Two denominators that were nearly wrong

`hrBucketsCompared` counts one entry per distinct heart rate per session — the
deepest denominator in the project, and `samplesWalked` (§12.39.6.1) arriving a
fourth time.

It is deliberately **not** in `lookedAtSomething`. A history with no traces at
all is a phone with no chest strap, which is a legitimate state, and requiring
buckets would make this screen call it broken. The count is printed instead, so
a reader can see whether the distribution half looked at anything —
`noTracesIsNotAFailure` pins that a bucket count of zero is still a pass, and
`untracedSessionsAreCounted` pins that both sides agree about what the card had
to leave out.

The zone totals are compared **per zone**, not as a total. Two zones can move in
opposite directions and leave the sum untouched — which is, at last, an actual
instance of the shape §12.60.1 was wrongly claiming.

## 12.61 The one table group nothing ever read back — patch 317

D6a built three readers. Patch 289 read the activities back and compared
nineteen fields; 291 did the details, splits and laps; 294 walked roughly 1.5
million samples of every recording. `athlete_profile`, `resting_month` and
`hr_zone` got a row count from `SemanticVerifier` and nothing else.

So the least-checked rows in the database are the ones that scale every figure
in it. `sexCoefficient` is an exponent. The month's resting rate and HR max are
the two ends of the fraction it is applied to. A single wrong value there does
not corrupt one row and does not break one screen — it rescales thirteen months
of training load, quietly, in a direction nobody would question.

`AthleteRepository` reads them back and `AthleteRoundTrip` compares them field
by field. Six scalars, `ftpWatts`, the resting series month by month, and the
zones by ordinal.

### 12.61.1 A read-back, not a second input to the twin

The obvious alternative was to feed shadow parity's database-side twin the
database's own constants instead of the app's, which would have closed the same
gap inside the machinery that already exists.

It was rejected, and the reason is the one §12.59 was built on. Slice 3 holds
constants, zones, FTP, sRPE and Apple Health identical on both sides so that a
difference in the fitness rows has **exactly one cause**: what the database's
activities and traces produce. Swapping the constants would make a difference
mean *either* the trace *or* the constants, and the screen could not say which.

Verifying them separately keeps the single cause and closes the same gap. The
Shadow parity section now prints a second line under "Held from the app" —
`Of those, verified: constants, zones and FTP, by the athlete read-back` —
because *held from the app* and *held from the app and never checked* are
different sentences, and until this patch the screen could only say the second.

`LoadParity.verifiedByReadBack` is a separate string rather than an edit to
`heldFromTheApp`. What the comparison holds constant did not change; what is
known about those constants did. Collapsing the two would lose the distinction
between "not varied here" and "proven identical", and the second is a claim
that has to be earned by something on screen.

### 12.61.2 The approved-difference list gets its first entry

Groundwork §5 reserved a list for fields that are expected to differ, with the
reason recorded. It has been empty for twenty-eight patches. `version` is the
first entry.

`AthleteConstants.version` is bumped only when HR max changes and is read by
`LoadStore`'s input fingerprint to decide what needs recomputing. It describes
**the app's cache state, not the athlete**, and there is no sensible column for
it: a value written into the database on Monday and read back on Tuesday would
be a second, staler answer to a question the app already answers locally —
§12.29's problem, arriving through the back door.

The entry is a `struct`, not a string:

```swift
struct ApprovedDifference: Sendable {
    let field: String
    let reason: String
    let patch: String
}
```

An entry nobody can justify is a bug that has been given a hiding place. Making
the reason and the patch number required fields is the cheapest available way to
stop the list from growing by accident, and `versionIsApprovedNotIgnored`
asserts the count is still one — so the next entry costs a deliberate edit to a
test as well as a line in an array.

The field names are printed on the Database screen unconditionally, dim rather
than red. An approved difference that only appeared when it fired would be a
suppression list nobody ever reads.

### 12.61.3 The name that is reconstructed rather than approved away

`hrMaxObservedName` has no column either. The importer resolves the observing
session to a canonical id and stores that as a foreign key — §12.10's arithmetic
resolution, refusing to guess when the day, the rounded maximum and the name do
not pick out exactly one activity.

That made it a candidate for the approved list too. It is not on it. A
`LEFT JOIN activity` gives the name back, so the reader reconstructs it and the
comparison checks it.

Two reasons. *"The name is reconstructed and checked"* is a stronger sentence
than *"the name is expected to differ"*. And a list that starts at one entry
grows less easily than one that starts at two — the first precedent for what
belongs on it is set by whichever entries are there on day one.

When the importer genuinely could not resolve the provenance the key is null,
the name is gone, and that is reported as a real difference.
`anUnresolvedProvenanceIsADifference` pins it: the join must not swallow a loss
by returning nothing and calling it agreement.

### 12.61.4 The fourth read-back has no button, and that is the fix for §12.57

The three read-backs above it are behind a press because they cost 669 rows,
667 details and roughly 1.5 million sample comparisons. This one is one row,
thirteen months and five zones.

So it runs when the screen opens, and again on every write-through — the same
`writeThrough.runs` key patch 306 added to the ledger, for the same reason: a
write that happened while the screen was open would otherwise leave the
read-back describing the database as it was before it, which is the exact shape
of the bug that made the background trigger look dead.

This also **dissolves** the `@State` evaporation problem rather than working
around it. §12.57 found the parity result vanishing when the sheet was
dismissed, so the diagnostics paste said "not compared since this launch" a
minute after the comparison passed — true of the `@State` and false about the
world. The fix there was to move the result into an `@Observable` singleton. A
check that re-runs itself every time the screen appears needs none of that: the
paste and the run are the same visit, and there is no state to survive.

That is not a general licence to drop the singleton. It works here because the
work is free. The moment a read-back costs a press it needs somewhere to live
that outlasts the sheet.

### 12.61.5 The first read-back to reach the diagnostics paste

The other three cannot. Their differences are named by **activity id**, and
§12.7 promises this paste carries nothing that describes the athlete.

This one names fields — `sexCoefficient`, `restByMonth[2026-06]`, `zone 3` —
plus two figures, a heart-rate maximum and an FTP, which describe a body's
capacity rather than anything the athlete did or where they did it. Eleven
lines, unconditional, including every zero: §12.54.2, which this screen has now
learned twice.

### 12.61.6 The test that keeps the other sixteen honest

`compare` names its fields rather than reflecting over them, for §12.35's reason
— there is no reflection that would not also silently skip something. The cost
is that adding a property to `AthleteConstants` and not to `compare` makes every
other test in the file quietly weaker without failing any of them.

`noFieldIsSilentlySkipped` is the one that fails. It takes a `Mirror` of an
empty `AthleteConstants` and asserts the exact set of eight stored property
names: six compared as scalars, `restByMonth` compared month by month, `version`
on the approved list. Nothing else. A ninth field breaks it on the day it is
added, and the failure message prints the set it found.

Two more negative controls exist because the comparison could have been blind
in a way no positive test would notice. `aMonthOnlyOnOneSideIsCaught` deletes a
month from the database: comparing the shared months only would agree perfectly
about a month one side has never heard of, and a month missing from the database
is every session in it scored against nothing. `aMissingZoneIsCaught` does the
same for `hr_zone` — a zone set with a hole is not a smaller problem than no
zone set, because `zone(forHR:)` answers confidently from it.

### 12.61.7 Two `nonisolated` keywords, and why neither is a workaround

The reader runs inside a database transaction, off the main actor. Two types it
works with are main-actor isolated by the module default, and both needed a
keyword.

`AthleteConstants.hrMax` is a **computed** property. SE-0434's rule — that
`Sendable` *stored* properties of a global-actor-isolated value type are
implicitly `nonisolated` — is why `Sub4Import+Athlete` has read `hrMaxOverride`
off the main actor since patch 228 with no keyword at all. A computed property
is a method and gets no such treatment. The alternative was writing
`hrMaxOverride ?? hrMaxObserved` at the call site, which is §12.43's defect
exactly: one rule, two implementations, nothing keeping them in step. It is
marked `nonisolated`, as `Activity.dayKey` was at 207 and `Activity.discipline`
at 219.

`AthleteStore.HRZone` is nested in an `@Observable final class` and inherits the
main actor from it — the same obstacle `AthleteFile` was written to work around
at 259. This reader constructs one per row. A mirror type was rejected: a mirror
is right for the shape of a *file* whose store is its only writer, and wrong for
a three-field immutable value that **both sides of a comparison have to hold**.
Two declarations of it would be two things to keep in step for no gain, in a
patch whose entire purpose is catching things that have drifted apart.

Fourth and fifth times this project has paid this tax. The pattern is stable
enough to state: **a type that a database reader constructs or derives from is a
type that will need `nonisolated`, and finding out at the call site is the
normal way to find out.**

#### 12.61.7.1 And the keyword did not reach the extension — 317a

`nonisolated struct HRZone` compiled and produced one warning:

    AthleteStore.swift:118: main actor-isolated property 'name'
    can not be referenced from a nonisolated context

`HRZone.titled` is `"\(label) \(name)"`. `label` is written in the type's own
body and became nonisolated with it. `name` is written in
`extension AthleteStore.HRZone` in `Theme.swift`, which takes the module default
and stayed on the main actor. **The keyword applies to members written in the
type's body; it does not reach its extensions.**

That is the identical rule `Sub4Import+Athlete`'s header records for patch 228 —
`nonisolated enum Sub4Import` did not reach `extension Sub4Import`, and every
function in that file says the word for that reason. Fifth instance: 207, 219,
228, and now both ends of 317.

`titled` is marked `@MainActor` rather than `name` being marked `nonisolated`,
and the boundary is worth stating because it will come up again. The GEOMETRY of
a zone — `index`, `min`, `max`, `label`, `range`, `contains` — has to be
readable inside a database transaction, which is the whole reason 317 touched
this type. `name` and `color` are the EDITORIAL half: five words and five hues
that exist for surfaces to draw. Nothing off the main actor has ever wanted
either, and pulling them across to keep one composed string on the cheap side
would move the boundary for no reason.

**It was a warning, not an error, and that is the part worth noticing.** Patch
258's finding was three warnings that no test stopped for. This one appeared in
the same build output as forty errors from an unrelated cause and would have
been trivially easy to scroll past.

### 12.61.9 Third time: the app was grepped and the tests were not — 317b

317 added one line to `LoadParity.Report.diagnosticLines`. `LoadParityTests`
asserts that array's LENGTH — `lines.count == 22` — and it failed.

**The check worked exactly as designed.** A line added to the paste and not to
that number is a line nobody decided to add, and the assertion caught a real
change on the first run. There is nothing to fix in the test's shape; the number
moves to 23 and the new line gets an assertion of its own.

What is worth writing down is that this is the **third** instance of one habit:

| | change | grepped | missed |
|---|---|---|---|
| 315 | `Outcome.ran` gained a parameter | `app/*.swift` | `tests/` — six call sites |
| 316 | `ZoneTime` inferred from a filename | nothing | the type was `ZoneTotals` |
| 317 | `diagnosticLines` gained a line | `app/*.swift` | `tests/` — one count |

315 and 317 are literally the same omission, and 315's entry already says *"I
grepped `app/*.swift` but not `tests/`"*. Writing the rule down did not change
the behaviour. So it is restated as a mechanical step rather than an intention:

> **Changing a type's shape means grepping `Sub4CoreTests/` for its name before
> the zip is built — not after the build fails.** The three shapes that carry
> assertions elsewhere are: a function's arity, an array's length, and a
> printed string's content.

The consolation is the same one 315 had: **the failure is in a test, not on the
phone.** A `diagnosticLines` that silently grew a row would have been discovered
by nobody. This one cost a fix-up letter and stopped the build.

### 12.61.8 What this does not close

Slice 6 is not done. This reads the athlete tables; the plan, the notes, the
corrections and the sRPE values are still store-only, and sRPE remains held from
the app in slice 3 with nothing checking it. Apple Health's heart rate never
will be checked — it is a cache of somebody else's store, and no database this
app writes will ever hold it.

`updatedUTC` and `computedUTC` are written and not compared. They are import
stamps rather than facts about the athlete — §12.10 already records that
`computedUTC` currently answers "when did this row arrive" — and comparing a
stamp the store does not keep would be comparing the database against itself.

## 12.62 The memory base, and the state that shipped forty patches behind — patch 319

Patch 318 moved the project's knowledge base out of Cowork and into the repo: `CLAUDE.md`,
`docs/context/` (twelve files), `docs/SWITCHOVER.md`, `.claude/settings.json`, and
`scripts/test.sh` + `scripts/preflight.sh`. Eighteen files, 1,530 lines, and a good idea —
Cowork's memory store does not travel with the code, and every session that starts cold pays
for that.

It fixed the test counts and the repo-relative paths on the way in. It did not fix the state
sections.

`CLAUDE.md` §5 and `docs/context/sub4-database.md` both opened with **"as of 2026-08-05,
patch 278c"** and said *D0–D4 complete, D5 in progress, 3 of 5 slices done*. The commit that
installed them was made at patch 318.

### 12.62.1 Why this is a defect and not untidiness

A stale README costs a reader ten minutes. This is different, and the difference is
mechanical: **`CLAUDE.md` is the file every session reads first, and nothing else it reads
contradicts §5 early enough to matter.** A session that opens it comes away believing the
database work is mid-D5 — that `ActivityRepository` is the newest reader, that shadow parity
has not started, that seven migrations are still to come. It would then plan against that
picture, and the plan would be wrong in a way the code would only reveal after the work had
begun.

That is the same failure this project already has a name for at four different scales:

- **§12.15** — a diagnostic that cannot say why it has no answer will be read as having one.
- **§12.29** — two answers to one question is how the wrong one gets believed.
- **"A test that keeps passing can stop describing the system."**
- **§12.54.2** — a row that vanishes at zero cannot be told from a row nobody wired in.

Every one of them is the same shape: *a thing that used to be true, still being read as
true.* A memory base is that shape with the highest leverage available, because it is read
before anything that could correct it.

`docs/context/README.md`, in the same commit, states the rule it broke:

> *"These are working notes, not archives. When something here turns out to be wrong or is
> superseded, edit the file in the same commit as the code change. A file that stops
> describing the system is worse than no file."*

**Writing the rule down did not make it hold** — which is §12.61.9's finding arriving again,
one document up. Both are now restated as mechanical checks rather than intentions: the
context index carries a **date per file**, and the instruction is that a date far behind
`Sub4/AppVersion.swift` means read the code.

### 12.62.2 What was actually wrong

| stated | true at 319 |
|---|---|
| patch 278c, 2026-08-05 | 319, 2026-08-08 |
| D0–D4 complete, D5 in progress, 3 of 5 slices | D0–D5, D6a, D6b complete; D6c four slices of eight |
| **Ten** migrations | **Eleven** — `2026-08-12-run-trigger` at 311 |
| 51 tables, 212,295 rows | 51 tables, 213,698 rows |
| 668 activities, 645 traces, 192,954 samples | 673, 649, 194,154 |
| the verifier compares **19** things | see below — the number was removed, not corrected |
| read `HANDOFF-2026-08-05-late.md` for current state | `HANDOFF-2026-08-06.md` exists and is newer; all three are history |

`README.md` had gone further and was stating things that were false rather than merely old:
*"Dependencies: None yet. GRDB arrives with the database migration"* (GRDB 7.11.1 has been
pinned since 226), *"86 Swift files, ~31,500 lines"* (159 and ~56,000), and **"There is no
automated test target and no CI"** — against 68 test files, 931 tests and a workflow that
has existed since 4 August.

### 12.62.3 The number that was deleted rather than updated

The exported file said the semantic verifier *"compares 19 things across four layers"*.

The obvious repair is to count them and write the new number. That was rejected. The
verifier builds its list at run time — `countChecks` returns one per imported table,
`domainChecks` returns a variable set, and three more are appended individually — so the
total is a property of the data, not of the source. Any figure written here is a snapshot
that starts drifting the moment a table is added.

**The Database screen already prints it**, as `N comparisons, all agreed`. So the document
now describes the *shape* — counts, sync state, identity, an activity fingerprint, the
domain checks — and points at the screen for the number.

> **Where a screen already answers a question, a document should describe the question and
> not repeat the answer.**

That is §12.29's rule applied to prose. The one place it does not apply is a figure a reader
needs in order to know whether the document itself is current — which is exactly what the
patch number in a heading is for, and why it is the one number stated at the top of both
files.

### 12.62.4 What 319 does not touch, and why

**`Sub4/manual.html`**, last edited at patch 284. It has zero occurrences of "Database
health", "Shadow parity", "read-back", "write-through", "Import ledger", "GRDB" or
"migration". That is defensible for most of it — the manual is a *user* document and the
Database screen is a diagnostic surface — but its §11 is called *"Where the data lives"*,
and that section is describing an architecture the app is halfway through leaving.

Deferred deliberately: **D7 changes that answer.** Writing §11 now means writing it twice,
and the second version would be written against a system that had just moved. The staleness
is recorded in `CLAUDE.md` §5 so it is a known gap rather than a surprise.

**`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md`**, untouched since the 3 August
baseline, for the same reason: it is the ordered plan for the ladder currently being climbed,
and rewriting it mid-climb means rewriting it again at the top. `README.md` now says to read
it for the shape of the argument rather than for current state.

**No CHANGELOG was added**, and the README now says so in as many words. `git log` plus this
section carry that history in more detail than a changelog would, and a third place to write
the same thing is precisely the failure §12.29 describes.

### 12.62.5 The two surfaces, recorded because the docs disagreed about it

`docs/context/sub4-database.md` said the Cowork patch workflow was *"all gone"* and that
"Claude Code edits files in place and git is the undo".

Half true, and the half that is false is load-bearing. **Two surfaces work on this repo.**
Claude Code on the Mac does edit in place. **Cowork cannot write into the repo at all** — it
reads through the device bridge and delivers patch zips that Bruno unzips himself, which is
what 310 through 319 are. A session reading the old sentence would try to edit files it
cannot write and discover the constraint the slow way.

Retired for real: the `SUB4_ROOT` preflight, the anchor-uniqueness rules, and
`git --no-optional-locks status`. Retired at 315 for Cowork too: `apply-NNN.py` (§12.59.6).
Still true on both surfaces: run the suite before a device build, never run `xcodebuild test`
while Xcode is building, a new Swift file needs Xcode restarted, `AppVersion.swift` ships in
every patch, and **neither surface touches git — Bruno commits.**

### 12.62.6 The open item that has now survived a document rewrite

The match-picker defect — the picker offers activities `Matcher.resolve` will refuse, because
`Activity.isPlanEligible` returns `false` by `default:` and a walk is never eligible — was
recorded on 2026-08-05 with the instruction **"do this first, before any new work"** and the
note that the choice between the two fixes is Bruno's.

Forty-one patches have been built since. It is carried forward again rather than quietly
dropped, and the fact that it survived a rewrite of the document that holds it is the point:
**an item that is still open after a refresh is a decision that has not been made, not a note
that has gone stale.** The two fixes and their consequences are restated in full in both
files so that neither can be actioned without the argument attached.

## 12.63 What the detail screens derive — D6c slice 4, patch 320

291 and 295 compared every field of every detail: calories, the polyline, each
split's distance and moving time, each lap, each best effort. That question is
answered and stays answered.

This asks the other one. `ActivityDetail` carries a family of derived figures —
`overallPace`, `medianSplitPace`, `fastestSplit`, `closingPace(km:)`,
`openingPace(km:)`, `bestWindowPace(km:)` — and `PaceTarget.measured` switches
over four of them to produce the sentence on the activity screen: *"5:57 —
faster than asked"*. **Nothing had ever asked whether the database's copy
produces the same sentence.**

### 12.63.1 Why equal fields do not settle it

The obvious objection is that they do. If every field agrees, every function of
those fields agrees, and slice 4 is arithmetic that cannot fail.

That is true **if and only if** every field feeding a derivation is one of the
fields the read-back compares — which is a claim about coverage, not a theorem.
§12.16's warning is that equal counts can hide changed values; this is the same
warning one level up, where equal values are assumed to imply equal answers.

Two concrete ways the implication breaks, both live in this codebase:

- **A filter is a field nobody compares.** `displaySplits` drops a trailing
  fragment under 100 m. The read-back compares splits *by index*, so a fragment
  present on one side only shows as `splits missing 6` — one row in a tally of
  thousands, and nothing says the table on screen changed.
- **A derivation can read a field the read-back reports as an approved
  difference.** The twelve zero-heart-rate details are a known, permanent
  difference. Whether that difference reaches a number the athlete reads is a
  separate question, and until this patch nothing asked it.

It is the same argument slice 3 made for traces and got a real answer to:
D6a's accepted trace padding does not cost a load figure. This asks it of
details.

### 12.63.2 The answer, and the property it was wrongly said to turn on

**AMENDED AT 320a. The claim below was too narrow and the device disproved it
on the first run — see §12.63.8.** It is corrected here rather than only
contradicted later, because a section that still states the wrong reason is
what a future reader will find first.

The claim was: *`hasHRSplits` is the only derived property on `ActivityDetail`
that reads `averageHR`, and it asks `($0.averageHR ?? 0) > 0` — under which a
stored zero and a missing value are the same answer, so D6a's normalisation
cannot reach a pace, a split table or a lap reading.*

**True of `ActivityDetail`'s own properties. False of the derivation chain.**
`IntervalDetector.fromLaps` copies `lap.averageHR` into `RepSplit.avgHR`, and
the importer normalises laps as well as splits. The corrected statement is:

> **Nothing in this app DRAWS a heart rate without guarding `hr > 0`** —
> `SplitTables` line 194 for the kilometre table, line 336 for the lap table,
> and `hasHRSplits` one level up. So the normalisation reaches no figure the
> athlete reads, but it does reach a value the comparison carries, and the two
> are not the same sentence.

It is checked four ways rather than two: `aZeroHeartRateReadsLikeAMissingOne`
and `aZeroLapHeartRateIsNormalisedNotADifference` assert the drawn answers
match on splits and on laps; `aRealHeartRateIsSeen` and
`aRealLapHeartRateIsStillCompared` assert the comparison is not simply blind.
Without the second pair the first would pass on a comparison that never looked.

On screen the evidence is `Details with heart-rate splits: N vs N`, printed on
both sides, because a count beside its twin is evidence and a claim is not.

### 12.63.3 The denominator that would have lied

Every pace window returns `nil` when the detail has too few complete splits. A
strength session has none at all.

So a run over 673 details produces **8,076 pace comparisons**, and on a history
with no splits in it every one of them would be `nil == nil` — twelve agreements
per detail, describing nothing, reported as a clean slice.

`paceFiguresCompared` counts the pairs evaluated. **`paceFiguresAnswered` counts
the pairs where both sides produced a number, and that is what
`lookedAtSomething` tests.** Both are on screen; the second is the one that
means anything.

> **A figure that is missing on both sides agrees perfectly and proves nothing.**

That is §12.54.2 one level deeper than the row it was written for, and
`nilsOnBothSidesAreNotEvidence` is the test that pins it.

The window sizes — closing 1/2/4 km, opening 1/2 km, best 1/2/4/5 km — are the
ones `PaceTarget.Kind` actually carries from the plan ("last 4 km at MP",
"2×4 km @5:38–5:43"), plus 1 km, which any detail with a single complete split
can answer. Without the 1 km entries the denominator would be dominated by nils
on short sessions.

### 12.63.4 The plan is not consulted, and that is on screen

`IntervalDetector.fromLaps` takes an optional `IntervalPlan` which narrows the
work laps by the plan's cut pace. It is passed **nil**.

Getting a real plan means `Matcher.day()` → `Session` → `IntervalPlan.from`, and
`Matcher` is slice 5 — groundwork §8 names that dependency as the one thing it
had not investigated. Holding the app's plan on both sides was the alternative
and would have followed slice 3's pattern exactly; it was rejected because it
drags the whole matching path into a slice whose subject is laps.

What that leaves unexercised is the cut-pace filter, and only that. Everything
else in the detector runs on both sides: the 20-second and 50-metre work rule,
the uniform auto-lap rejection, the renumbering after filtering, and every rep's
seconds, metres, heart rate and derived pace.

`heldFromTheApp` says **"the plan — laps are read with no cut pace"** on screen
and in the paste, for §12.59's reason: a comparison that does not say what it
left out is a comparison whose result cannot be interpreted.

### 12.63.5 Nothing here is a second implementation

Every figure is read off `ActivityDetail`'s own properties and the lap reading
is `IntervalDetector.fromLaps` — the app's own function, called twice. §12.43,
sixth application after `isKept`/`dedup` (310), `byDay` (312), `recordedByWeek`
(313), `LoadSeries.build` (314) and the athlete round trip (317).

A parity file that re-derived a closing pace would eventually disagree with the
screen, and **no test could say which was right** — the failure §12.43 describes
as silent, and worse here than in 310 because a pace is a number somebody acts
on rather than a list somebody scrolls.

`DataCorrections.isIgnored(id:)` is called for the same reason. The two sessions
refused by name are `excluded`, not `missing`, and are not counted as
differences — §12.42.2, and 298's rule that a permanently correct red row is a
row that stops being read.

### 12.63.6 The test that proves the windows are distinct

`onlyTheClosingPaceMoves` changes the final kilometre and asserts that
`closing 1 km` differs while `opening 1 km` and `opening 2 km` do not.
`onlyTheOpeningPaceMoves` does the mirror.

Without that pair, a comparison that reported every window on every change would
be indistinguishable from one that compared each detail once and named twelve
figures. The counts would look right, the diagnostics would look thorough, and
the slice would be a single equality wearing twelve labels.

`aFragmentChangesTheSplitSet` is the sharpest of the negative controls and was
sharpened once during the patch. A 40 m fragment was the first fixture; the
arithmetic showed it moves `overallPace` by 0.13 s/km, which rounds away. At
90 m in 60 s it moves it from 333 to 339 — and the test now asserts **exactly
one** figure differs, `overall`, because every windowed pace filters on
`isPartial` and never sees the fragment while `overallPace` walks every split.

That asymmetry is deliberate in `ActivityDetail` and is stated there: overall
pace is *"the same arithmetic that produces the pace in the header, so the two
can never disagree."* A comparison that only checked the table would have missed
it.

### 12.63.7 One read, four slices

`ShadowParity.run` now reads details in the same pass as the activities and the
traces. **`Outcome.ran` gains a fourth associated value and a nil detail slice
counts as one difference**, on the same rule 315 established for the load slice:
a comparison that could not run is no answer, not zero differences.

Nil means the *read* failed. A device holding no details at all still produces a
report, and `lookedAtSomething` is what refuses to call that a pass — the two
states are different and the screen says which.

**The test target was grepped before the zip was built**, which is §12.61.9's
rule discharged rather than restated. `Outcome.ran` had two call sites in
`Sub4CoreTests/`, both found, both updated. Each was given a genuinely healthy
`DetailParity.Report` rather than `nil`: passing nil would have made those tests
pass with three failing slices instead of one, which is 315a's defect exactly —
a green assertion for the wrong reason.

### 12.63.8 The slice found the thing it was built to rule out — 320a

First device run of 320: everything green except **`Reps that differ: 16`** out
of 1,141, with **`Details with a different lap reading: 0`**. Same rep counts on
both sides, same detector verdict, sixteen individual reps differing inside
them.

The cause took one grep. `Sub4Import+Recording` line 218 writes
`positiveOrNil(split.averageHR)`; **line 229 writes `positiveOrNil(lap.averageHR)`
as well.** `IntervalDetector.fromLaps` copies `l.averageHR` straight into
`RepSplit.avgHR`. So a lap the store holds as `0` comes back as `nil`, and 320
compared `r.avgHR != t.avgHR` and called it a divergence.

§12.63.2 had argued this could not happen. It was wrong in the same shape as
§12.60.1: **a claim scoped to one type, used as if it covered the whole path.**
`hasHRSplits` really is the only property on `ActivityDetail` that reads
`averageHR` — and `ActivityDetail` is not where the derivation ends.

#### The approved list was the wrong answer, and that is the decision worth recording

The obvious repair was an entry: `laps[*].avgHR`, reason *the importer's
`positiveOrNil`*, patch 320a. Groundwork §5 already lists exactly this loss for
the read-back.

It was rejected. **The read-back and this slice are asking different questions,
and the same fact is an approved difference in one and a comparison defect in
the other.** The read-back compares records, so a field that genuinely differs
belongs on its list. This compares what the app derives — and the app derives
nothing different, because `SplitTables` guards `hr > 0` at the kilometre table
(line 194) and at the lap table (line 336). Both sides draw an empty cell.

Putting it on the approved list would have enshrined a wrong comparison as a
data decision, which is precisely what §12.61.2 warns the list must never
become: *an entry nobody can justify is a bug that has been given a hiding
place.* The entry would have been justifiable-sounding and still wrong.

> **Compare what the reader draws, not what the carrier holds — and when the
> two disagree, that is a fact about the comparison, not about the data.**

#### What 320a changes

`shownHR` states the readers' rule once — `guard let v, v > 0` — and both the
rep and the split comparison use it. Nothing is lost: 148 against nothing still
differs, 148 against 150 still differs. Only the importer's own normalisation
stops being reported as a divergence the athlete could see.

**The 16 do not vanish.** `reps whose zero heart rate was normalised` and
`splits whose zero heart rate was normalised` are new rows, dim, unconditional.
A count that disappeared the moment it was understood would be §12.54.2's defect
committed deliberately — and the day one of those sixteen becomes a real
148-versus-nothing is the day the two counters part company and the red one
moves.

#### And it exposed a gap it was not looking for

320 compared each split's derived `paceSecPerKm`, `isPartial` and `isFragment`
and **did not compare its heart rate at all**. The kilometre table draws that
column; it was uncompared. 320a adds it, under the same rule.

That is the second time this slice has paid for itself before shipping clean:
the fragment fixture at §12.63.6, and this. **A comparison that finds something
on its first real run is worth more than one that is green on its first real
run**, and the thing it found here was in the argument rather than in the data.

## 12.64 What satisfied which session — D6c slice 5, patch 321

Slices 1 to 4 compared lists, distances, loads and paces. This compares **which
activity satisfied which planned session**, and the figure that falls out of it
is *Sessions 4/4* on the Week screen — the one line that says whether the block
is being done.

Groundwork §8 named this as the open question it had not investigated:
*"whether a twin can satisfy `Matcher` without pulling the plan and the match
decisions in with it."* It can, and the answer is the same shape as slice 3's:
hold them, and let exactly one variable move.

### 12.64.1 The extraction, and why this was the worst one to skip

`MatchResolver` is `Matcher.resolve` and `Matcher.plannedKm`, moved unchanged.
`decisions` arrives as a parameter instead of being read off the instance; both
are `static`; `day` gains the eligibility filter and the extras sort that
`Matcher.day` used to hold. **No behaviour changed**, which is what makes the
existing suite the proof that the move was faithful — 310's argument and 314's.

Seventh application of §12.43, and the one where the alternative would have been
least detectable. `isKept`/`dedup` at 310 produced 320 phantom differences when
it was reimplemented: loud, immediate, obviously wrong. Here a second
implementation would produce **two plausible match lists differing on which
activity one session claimed**, with no test able to say which is right, and the
number underneath it is an adherence figure the athlete acts on.

The delegating `Matcher.resolve` wrapper was removed rather than kept. Nothing
but `day` ever called it, so a private forwarder would have been a method
written in anticipation of a caller — which this project has a rule about, and
`ProposalStore.remove` waiting 45 patches is why.

### 12.64.2 Matching is order-dependent, and nothing had ever said so

Step 3 of the resolution takes `candidates.first!` when a session states no
distance. **The order of the activity array decides what a vague session
claims.**

That is deliberate — the pool is newest-first and the first candidate is the
most recent — and it means this slice's answer rests on slice 1's. Slice 1
reports `0 order disagreements of 674`. If it ever did not, slice 5 would go red
too, and it would be right to.

`theOrderOfTheListDecidesAVagueMatch` asserts it directly: the same session,
the same two activities, presented in two orders, claims a different one each
time. The function was private and read its inputs from three singletons, so
nothing could reach that behaviour before this patch.

> **A comparison whose correctness depends on another comparison should say so,
> on screen and in its own tests.**

### 12.64.3 Three things held, and a reason for each

- **The plan.** `plan_session` and its children are in the database with no
  reader — slice 6b. Holding it means a difference here cannot be a plan
  difference.
- **The match decisions.** `match_decision` is in the database, has no reader,
  and **holds zero rows on this device**. Reading it would make a difference
  mean either the activities or the overrides, which is exactly the argument
  §12.61.1 made for the athlete constants.
- **The commute decisions.** `isPlanEligible` reads `CommuteStore` through
  `isCommuteRide`, and patch 251 decided not to thread a decision dictionary
  through fourteen call sites. It is the same store answering the same activity
  ids on both sides, so it *cannot* make them disagree — but it is held rather
  than compared, and saying so is the difference between a limit and a blind
  spot.

So exactly one variable moves: the activities.

### 12.64.4 The denominator that would have lied, again

Most planned sessions are rest days or sessions with no activity to find. They
resolve to `nil` on both sides and agree perfectly. A run over 37 weeks would
report hundreds of matched-nothings and look thorough.

`sessionsCompared` counts every session resolved on both sides.
**`matchesResolved` counts the ones that claimed an ACTIVITY on both sides**,
and that is what `lookedAtSomething` tests.

> **A session that matched nothing on both sides agrees perfectly and describes
> nothing.**

§12.54.2 one level up from the row it was written for, and the third slice in a
row to need its own version of it — volume had `daysCompared`, detail had
`paceFiguresAnswered`, this has `matchesResolved`. The pattern is stable enough
to state as a rule: **when a comparison's natural unit can be empty on both
sides, the count of non-empty agreements is the real denominator.**

### 12.64.5 Two failures that look alike and are not

`sessionsWithADifferentActivity` and `sessionsDoneOnOneSideOnly` are separate
rows on purpose. *"The session found something else"* and *"the session found
nothing"* have different causes — the first is an ordering or a distance, the
second is a missing activity — and the second is the exact shape the match
picker defect produces.

`sessionsWithADifferentSource` is a third: the same activity, chosen a different
way. The row on screen would look identical and the fact behind it would not.

### 12.64.6 The defect is named, asserted and not fixed

`resolve` step 1 honours an override only when the named activity is in the
pool, and the pool has already been filtered by `isPlanEligible` — under which a
walk is never eligible. The athlete names the walk, the override is stored, the
matcher cannot reach it, and the session falls through to the same branch as
"explicitly nothing". Week says *Not done* with nothing on screen saying why.

Open since 2026-08-05. **321 does not fix it**, and that is a decision rather
than an omission: both candidate fixes change behaviour, and the choice between
them is the athlete's — (a) the picker offers only what can win, (b) an explicit
override beats `isPlanEligible`, which is patch 251's own argument three lines
above the walk case and would put the walk's distance and load into that
session's adherence and effort figures.

Fixing it in the same patch as the extraction would also have cost the proof:
**the existing suite proves the move only because the move changed nothing.**

`anOverrideNamingAnIneligibleActivityIsLost` asserts today's behaviour with the
defect named in the doc comment, and `theSameOverrideOnAnEligibleActivityWins`
sits beside it so the first is a statement about eligibility rather than about
overrides. The day the fix lands, the first test inverts — which is the
difference between a known defect and a forgotten one.

### 12.64.7 Zero overrides is printed, because zero coverage is a fact

`match_decision` holds no rows on this device, so the override branch is never
entered on a real run. `overridesApplied` is on screen and in the paste for
exactly that reason: without it, "no differences" reads as coverage the run does
not have. The branch is covered by tests and by nothing else, and the screen
says which.

That is §12.15's shape applied to a comparison rather than to a diagnostic: **a
check that cannot say what it did not exercise will be read as having exercised
everything.**

### 12.64.8 What slice 5 unlocks, and what it does not

`LoadStore` builds `srpeByActivity` by resolving notes to activities through
the matcher — so slice 3's held sRPE depends on matching being right. Proving
the matching is the prerequisite for slice 3 stopping holding it, which is
322's job together with a reader for `user_note`.

Still held after 321, and still uncompared: the plan itself, the notes, the
corrections and Apple Health. The first three are slice 6b; the fourth never
will be.

## 12.65 The two tables the athlete writes — D6c slice 5b, patch 322

`user_note` holds seven rows and `correction` holds four. Between them they are
the smallest thing D6c has read back, and they close a loop 321 opened.

### 12.65.1 The chain into sRPE, and the one link that was missing

`LoadStore` builds the figure that scales a session's training load like this:

```swift
srpeByActivity[a.id] = Double(rpe)
    * Double(DataCorrections.scoringSeconds(a)) / 60
```

keyed by the activity `Matcher.day(dayKey)` picked, for the session the plan
dated. Four inputs. After 321, exactly one of them had never been checked:

| input | state before 322 |
|---|---|
| `note.rpe` | read out of `NotesStore`, **never read back** |
| `scoringSeconds` | `officialTiming` and `useElapsedTime` are **compile-time constants** keyed by activity id — they live in the binary, not in a table. The two sides cannot differ; there is nothing to read and nothing to compare, ever |
| the matcher | proven at 321, §12.64 |
| the plan | held identically on both sides, so it cannot differ. Held, not verified — slice 6b |

This reads `note.rpe` back. `LoadParity.verifiedByReadBack` therefore becomes
**"constants, zones, FTP and sRPE — sRPE given the plan"**, and the qualifier is
not decoration. It is the difference between a claim that is true and one that
sounds true.

> **A verification chain is only as long as its weakest unread link, and the
> honest way to state it is to name the link you did not read.**

### 12.65.2 `correction` is one of slice 5's own held inputs

`correction`'s four rows are the commute decisions — `subjectKind = 'activity'`,
`field = 'isCommute'`. §12.64.3 held them because `isPlanEligible` reads
`CommuteStore` through `isCommuteRide`, and patch 251 decided not to thread a
decision dictionary through fourteen call sites.

Holding is still right: the same store answering the same activity ids cannot
make the two sides disagree. But **held-and-checked is a different sentence from
held-and-assumed**, and `MatchParity.verifiedByReadBack` is what earns the
first. Third application of §12.61.1's argument.

The match decisions are not in it and cannot be until something reads
`match_decision` — which holds zero rows, so there would be nothing to check.

### 12.65.3 The canonical-id trap, for the third time

`correction.subjectID` is the CANONICAL activity id: the importer resolves it
through `Sub4Import.canonicalActivity` before writing.
`CommuteDecision.activityId` is Strava's.

A reader returning the column straight through would hand all four decisions an
id matching nothing in `CommuteStore`, and the comparison would report four
losses that are a join this reader got wrong rather than data that went missing.

Third instance: `gearId` at 289, the athlete's provenance at 317, this. The
pattern is stable enough to name:

> **Any column that references another table holds the canonical id, and every
> store keys by the source's. A reader that does not join is a reader that
> invents a difference.**

One detail matters and is easy to get wrong: the join goes back through
**`activity_alias`**, not `activity_source_record`. Both hold the same
canonical-to-Strava pairing; only one of them is the table the writer used.

### 12.65.4 Timestamps compare as strings, not as dates

The importer writes `Sub4Import.iso8601(note.created)`. This reads the column
and compares it to `Sub4Import.iso8601` of the store's own `Date` — **the
writer's own formatter, called on both sides**.

Parsing the column back into a `Date` and comparing with a tolerance was the
alternative and is worse twice over: it needs a second formatter that could
disagree with the first (§12.43), and a tolerance would forgive a drift the
string comparison catches exactly.

291 needed `sameSecond` for `fetched` because both sides held `Date`s. Here one
side holds text, and text is the honest thing to compare it as.
`theTimestampsCompareAsTheWriterWroteThem` pins both halves: four tenths of a
second is not a difference, two seconds is.

### 12.65.5 Two rows this reader declines rather than guesses at

An unrecognised `feel` raw value is a row this reader cannot reconstitute — it
is **skipped and counted**, not mapped to nil. Mapping it would turn a schema
drift into a silent data change, and the note would come back looking
answered-with-nothing rather than unreadable.

Same for a `correction.value` that is neither `"true"` nor `"false"`. A guess
there would silently flip whether a ride may satisfy a planned session.

`skipped` counts both, 289's rule, and **`aSkippedRowIsADifference` pins that it
fails the comparison** — without that, a reader declining every row would agree
with an empty store.

### 12.65.6 The approved list gains its second and third entries

`user_note.activityID` and `user_note.planVersionID` are left NULL by the
importer, on purpose, with the reason written at the line that does it:

> *Resolving a note to the activity that satisfied its session is a MATCHING
> decision. The importer is not the matcher — the same rule that stops it
> merging the 21 April duplicate ride.*

The list is now three entries across two patches, and every one of them carries
its reason and its patch number. `theApprovedListIsJustified` asserts the count
and the shape, so a fourth entry costs a deliberate edit to a test as well as a
line in an array — §12.61.2's gate, still holding.

### 12.65.7 One section for two tables

Groundwork §7 warned that a screen nobody scrolls to the bottom of is a screen
whose bottom rows are not read, and §12.40.1 measured that once already. The
Database screen already carries four read-backs and five parity slices.

Eleven records do not need two headings. **Read-back · authored** carries both,
with a denominator each, and the two tables are one heading because they share
a property nothing else on the screen has: **the athlete wrote them.** Every
other table is a cache of something fetched.

### 12.65.8 What the paste may not carry

A note's `text` is the athlete writing about their own training. It is
**compared and never printed** — not in a count, not truncated, not at all. What
reaches the paste is the session uid, which is the plan's own identifier, and
the names of the fields that differ.

`theDiagnosticLinesAreUnconditional` asserts the absence directly, by checking
that the fixture's own words do not appear in the output. §12.7's promise
enforced by a test rather than by care.

### 12.65.9 What is still held after 322

**The plan.** `plan_session` and its 780 rows, `plan_week`, and the fuel and
warm-up tables have no reader. That is slice 6b, and it is what stands between
"sRPE given the plan" and "sRPE".

**Apple Health.** A cache of somebody else's store. No database this app writes
will ever hold it, and no patch will ever verify it.

**Weather and gear.** `weather` holds 583 rows and is drawn on every activity
screen; gear is read through a join at 289 but never compared as a record. Both
are the rest of slice 6.

### 12.65.10 `== nil` is not a nil check — 322a

322 compiled and ran. `⌘R` produced four warnings, all the same one, at
`AuthoredRepository.swift` 294, 295, 328 and 331:

    Main actor-isolated conformance of 'NotesStore.Note' to 'Equatable'
    cannot be used in nonisolated context; this is an error in the Swift 6
    language mode

The four lines looked like this:

```swift
r.notesOnlyInApp      = mine.keys.filter  { theirs[$0] == nil }.sorted()
r.notesOnlyInDatabase = theirs.keys.filter { mine[$0]  == nil }.sorted()
```

**Nothing in that line mentions equality, and the line is a call to
`Optional.==`.** `theirs[$0]` is `NotesStore.Note?`; comparing an optional to
`nil` resolves to `static func == (lhs: Wrapped?, rhs: _OptionalNilComparisonType)`,
which is constrained `Wrapped: Equatable`. So the subscript's *value type* has to
be `Equatable` in order to ask a question about its *key*.

`NotesStore.Note` is nested in `@Observable final class NotesStore` and inherits
the main actor from it, so its synthesised `Equatable` conformance is
main-actor-isolated. `CommuteDecision` is top-level and unannotated and takes the
module default, which `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the same
thing. `AuthoredRepository` is a `nonisolated enum` running inside a database
transaction. Neither conformance is reachable from there.

**The fix is not a keyword.** The comparison never wanted note equality; it
wanted membership, and membership is a question about keys:

```swift
let mineKeys = Set(mine.keys)
let theirKeys = Set(theirs.keys)
r.notesOnlyInApp      = mineKeys.subtracting(theirKeys).sorted()
r.notesOnlyInDatabase = theirKeys.subtracting(mineKeys).sorted()

for uid in mineKeys.intersection(theirKeys).sorted() { … }
```

`String` is `Equatable` and `Hashable` with no actor anywhere in sight, and the
loop that follows gets its intersection for free instead of re-deriving it. The
same edit was made for `commutesOnlyInApp` / `commutesOnlyInDatabase`, where the
`DataCorrections.isIgnored` filter now applies to the difference rather than
inside the membership test.

**Marking the types `nonisolated` would have worked and would have been the
wrong trade.** Both are drawn by SwiftUI and mutated from the main actor; making
their conformances reachable from a transaction is a boundary move to satisfy a
line that did not need the boundary crossed. This is the same judgement
§12.61.7.1 made about `HRZone.name` from the other direction: move the member
that is on the wrong side, not the type.

**Sixth instance of the isolation family, and the first that is invisible in
review.** The five before it named the thing that was isolated — a computed
property (317), a type's extension (207, 219, 228, 317a). This one names
nothing. There is no `.` on the right-hand side, no member being reached, no
identifier belonging to the isolated type. A reader checking a `nonisolated`
function for main-actor reaches will not see `== nil` as one, because it is not
written as one. The rule has to be carried as a fact about the *operator*:

> **`optional == nil` requires `Wrapped: Equatable`.** In a `nonisolated`
> context, that means `Wrapped`'s conformance must be nonisolated too. For
> dictionary membership, ask the keys — `Set(a.keys).subtracting(Set(b.keys))` —
> which never touches the value type at all.

`dictionary[key] != nil` and `if let _ = dictionary[key]` are the two other
spellings; the first has the identical problem, the second does not, which is
why the shortest correct habit here is the one that stops asking about values.

**It was a warning again, not an error** — the third time (258, 317a, now this)
that the compiler said the thing and the build succeeded anyway. In Swift 6
language mode all four become errors. The reason this one reached `⌘R` rather
than the test run is that `./scripts/test.sh` builds the test target, whose
output scrolled past four warnings inside 931 passing tests.

### 12.65.11 The test could not build the row the schema forbids — 322b

322a's build was clean and the test run was not. Two tests failed, both on
their setup:

    SQLite error 19: CHECK constraint failed:
    feel IS NULL OR feel IN ('easier', 'expected', 'harder')
    - while executing `UPDATE user_note SET feel = 'elated'`

`anUnknownFeelIsSkippedNotNilled` and `aSkippedRowIsADifference` both need a
`user_note` row this binary cannot map. Both built it the obvious way, with an
UPDATE, and `2026-08-04-domain` refuses it. **Neither test reached its
assertion**, which is the part worth naming: a test that fails in its setup is
indistinguishable in a summary line from a test that fails on what it claims,
and the summary line is what gets read.

**The reader's branch is not dead, so the tests are not deleted.** The
constraint enumerates the values *this* schema knows. Migrations are
append-only, so widening `domainFeels` means a new dated migration — after
which a database holds a fourth value and any binary compiled against the old
`Feel` reads a row it cannot reconstitute. That is precisely the case the skip
branch exists for, and it is reachable by an app downgrade or by a database
restored from a newer install. What the constraint rules out is the state
arising *today*; it does not rule out the state.

So the row is forced:

```swift
try db.queue.writeWithoutTransaction { d in
    try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
    defer { try? d.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
    try d.execute(sql: "UPDATE user_note SET feel = ?", arguments: [raw])
}
```

`writeWithoutTransaction` because the pragma is a connection setting and does
not belong inside a transaction boundary, and it is turned off again before the
connection goes back so nothing downstream runs unchecked.

**The asymmetry between the two decline tests is the schema, not the reader.**
`anUnparseableValueIsSkipped` passed, and it does the same thing to
`correction.value` — because `correction.value` is a free-text column with no
CHECK. Two sibling tests, one refused and one not, and the difference is a
constraint written eighteen migrations ago. Nothing about the reader
distinguishes them.

**One test added, and one deliberately not.** `theSchemaRefusesAnUnknownFeel`
asserts the refusal that stopped the other two, because nothing did:
`DomainSchemaTests.feelsMatch` pins WHICH values the constraint lists against
`Feel.allCases`, and that is a different claim from the constraint being
enforced at all. What was **not** added is a second list-agreement assertion —
writing one in `AuthoredRepositoryTests` would have been §12.43's defect
committed inside a patch whose subject is a schema constraint. The existing
test was found by grepping the test target for `domainFeels` before writing
anything, which is §12.61.9's rule applied for once in the direction of not
adding code.

**Third time a test's SETUP has been the failure and not its subject** — 315
and 316 were diagnostic-line counts, 317b was the same, and each time the fix
was a mechanical step written down afterwards. This one has a different shape:
those were assertions elsewhere that a change invalidated; this is a state the
database will not let a test enter. The step that generalises is:

> **A test that constructs an invalid state through SQL is subject to the
> schema's own constraints.** If the state is one the schema forbids but the
> reader must still survive, force it — `PRAGMA ignore_check_constraints` —
> and assert the refusal separately, so the constraint and the tolerance of it
> are two claims rather than one accident.

## 12.66 The plan, read back — D6c slice 6b, patch 323

`PlanRepository` reassembles `Week`, `Session`, `SessionDetail` and `Block` from
six tables and compares every field against the bundled plan the app holds.
Sixth repository, and the largest: 260 sessions where the athlete's profile was
27 fields.

**AMENDED AT 338.** The comparison covers fields represented by the plan model,
not literal JSON identity. `meta.source` is dropped before import and the
top-level session/exercise arrays have no stored ordinal, so their source order
is not reproduced. §12.86.7 is the current coverage boundary.

### 12.66.1 A different claim from every read-back before it

`plan.json` ships in the bundle, is read-only at runtime and is replaced
wholesale on app update. The app therefore **cannot have drifted from the
database by writing**, which is the thing every previous read-back was built to
catch. What can have gone wrong is the import: one file decomposed across six
tables and reassembled here. A difference is a decomposition that does not
invert.

That makes this the first read-back whose failure mode is entirely in the
importer, and it is worth saying because it changes what a green result buys.
It does not buy "the plan has not been corrupted" — nothing corrupts it. It
buys "the plan can be served from the database", which is the precondition for
D7 retiring `plan.json` as a runtime input.

### 12.66.2 The canonical-id trap, fourth instance — and the most inviting

`Session.weekUid` is the plan's own week identifier, `"w14"`.
`plan_session.planWeekID` is a UUID minted by the importer. A reader returning
the column would compile, type-check, read plausibly, and report **all 260
sessions as differing on `weekUid`** while the data was perfectly intact.

Fourth instance: `gearId` at 289, athlete provenance at 317,
`correction.subjectID` at 322, this. The rule is unchanged — *any column
referencing another table holds that table's canonical id, and every store keys
by the source's* — but this one is the easiest of the four to walk into, because
the column is spelled `planWeekID` and the field is spelled `weekUid` and they
differ by one word. The SQL joins `plan_week` and returns `w.uid`, and
`theWeekUidIsThePlansOwnAndNotTheRowId` asserts both halves: that the column is
a 36-character UUID, and that the reader does not return it.

### 12.66.3 "At most one active" is per plan, and that was nearly a silent bug

The index is:

```sql
CREATE UNIQUE INDEX plan_version_one_active
ON plan_version(planID) WHERE activatedUTC IS NOT NULL
```

Read at speed that says one active version exists, and the first draft of this
reader used `fetchOne` on that basis. It says one active version exists **per
plan**. `Sub4Import.upsertPlan` keys the `plan` row on
`(week1Monday, raceDate)`, so moving the race date mints a *second plan*, and
`activate` clears the flag only `WHERE planID = ?`. Two active versions, both
legal.

Today the device holds one plan, so `fetchOne` would have been right — and would
have stayed right until the day the race date moved, at which point it would
have picked one of two silently and every count on the screen would have been a
coin toss nobody could see being flipped.

So the reader counts them and returns `.ambiguousActiveVersion` rather than
choosing. §12.15's eleventh instance and §12.60.1's rule arriving together: **do
not reason by analogy about two numbers without checking whether one determines
the other.** A unique index on a column is not a unique index on a table.

`twoActivePlansAreAmbiguous` builds the state and asserts the refusal, so the
day a race moves this is a named answer rather than a wrong one.

### 12.66.4 The denominator that needs a second row to be honest

`plan_session` holds 780 rows. The app holds 260 sessions. Both are correct:
three versions of the same plan are stored. Every plan table divides by three
exactly — 111 weeks, 552 stats, 780 sessions, 246 breakdowns, 1,902 blocks — and
`plan_session_block`'s own migration comment, written long before this patch,
says the extractor emits those four fields **634 times**, which is 1,902 ÷ 3
arriving from a completely different direction.

"260 compared" printed above a table holding 780 reads as data loss to anyone
who has not been told why. So the row beneath it says
`260 of 780 rows · 3 versions`, and the active version's label is beside it.
That is §12.15 applied to a denominator instead of to an error: a number that
cannot say why it is smaller than the table will be read as loss.

### 12.66.5 Two declarations of `ApprovedDifference`, and a third not written

`AthleteRoundTrip` (317) and `AuthoredRoundTrip` (322) each declare their own
`struct ApprovedDifference`. That is already §12.43's defect in miniature — one
idea, two implementations, nothing keeping them in step.

**This round trip has no approved differences at all.** Every field of `Meta`,
`Week`, `Session`, `SessionDetail` and `Block` has a column and every column is
written. So there is no list here, and deliberately not an empty one: a third
declaration holding nothing would be a type written in anticipation, which is
what 321 deleted a forwarder to avoid.

**338 qualification:** “every field” above means every field the decoded Swift
models retain. It excludes source-only `meta.source` and does not prove the
ordering of top-level collections whose tables have no ordinal.

The screen and the paste still print **"approved differences: none"**, because
the absence has to be visible — §12.54.2 again. A reader who sees no such line
cannot tell "nothing needed approving" from "nobody looked".

The two existing declarations should become one. That is a change to two shipped
files for no behavioural gain, so it is recorded here rather than done inside a
slice patch, and it is a decision rather than an oversight.

### 12.66.6 The property that held the breakdown is data

`Session.breakdown` is `swimDetail ?? strengthDetail`. A reader that put a
strength breakdown into `swimDetail` would compare **equal on every field of the
detail and every field of every block** — and the session would draw with a
swimmer's icon. `plan_session_detail.kind` exists in the schema for exactly this
and nothing had ever checked that a reader used it.

So `kind` is compared as a field of the session in its own right —
`"breakdown kind"` — and `aStrengthBreakdownDoesNotComeBackAsASwim` asserts the
property rather than the contents. The blocks are compared **by ordinal**, not
as a set: they are a sequence, and a set comparison would call a shuffled
session identical. `reorderedBlocksAreCaught` swaps two and asserts both are
reported.

### 12.66.7 The frozen vocabularies, and 322b's helper used a second time

`plan_session.discipline` and `.intensity` carry CHECK constraints over frozen
value lists, exactly as `user_note.feel` does. An unrecognised value is skipped
and counted rather than mapped.

**Not mapped to `.other`, and the contrast is the interesting part.**
`Discipline.init(from:)` maps an unknown raw value to `.other` on purpose — that
is what keeps a newly extracted `plan.json` loading rather than failing the app
to launch. The same behaviour in this reader would turn a schema drift into a
silent data change: a session would come back as "other" and nothing on any
screen would say a value had been lost. Same enum, two directions, opposite
correct answers.

As at §12.65.11 the constraint means the state cannot arise from this schema, so
`forceUnknownDiscipline` writes it with `PRAGMA ignore_check_constraints` and
`theSchemaRefusesAnUnknownDiscipline` asserts the refusal separately. Second use
of a helper written one patch earlier, which is the first evidence that 322b's
rule generalised rather than described one incident.

### 12.66.8 What two other screens stopped saying

**`LoadParity`** said `constants, zones, FTP and sRPE — sRPE given the plan`.
The caveat existed because `note.rpe` was verified at 322 and the plan it scales
was not. It now reads `constants, zones, FTP and sRPE`.

**`MatchParity`** said it verified `the commute decisions`. It now verifies
`the plan and the commute decisions`, which leaves the match decisions as the
only held input that screen cannot corroborate — and `match_decision` holding
zero rows as the reason.

Both strings are interpolated into their tests rather than duplicated there, so
the two assertions followed the change without editing. That is §12.61.9's rule
paying for itself in the direction of nothing breaking: **the test target was
grepped before the zip was built**, and it found two references that needed no
edit, which is the outcome the grep exists to establish rather than to fix.

### 12.66.9 What is still held after 323

**Apple Health.** A cache of somebody else's store. No database this app writes
will ever hold it, and no patch will ever verify it.

**The match decisions.** `match_decision` has no reader and zero rows. When the
match-picker defect is settled and overrides start being stored, it will need
one.

**Weather and gear.** `weather` holds 583 rows and is drawn on every activity
screen; gear is read through a join at 289 but never compared as a record. The
rest of slice 6.

**The plan's own trimmings.** `plan_exercise`, five fuel tables, four warm-up
tables — about 150 rows. Drawn on screens, feeding no derivation. Slice 6c.

## 12.67 Weather and gear, read back — D6c slice 6 closed, patch 324

`WeatherGearRepository` reads `weather`'s 583 rows and `gear`'s eleven back out
and compares them against `WeatherStore` and `AthleteStore`. Seventh repository.
Slice 6 has read "317 ✔ / rest open" since the athlete's zones were done; it
now reads done.

### 12.67.1 The canonical-id trap, fifth instance — and the one exception

`weather.activityID` is the canonical activity id; `ActivityWeather.activityId`
is Strava's. `Sub4Import+Weather` resolves through `activity_alias` on the way
in, with a comment saying the alias "is the one that survives Strava's
retirement", so this reverses the alias on the way out. Fifth instance: 289,
317, 322, 323, this.

**`gear` is the exception, and the exception is asserted.** `gear.externalID`
IS Strava's gear id and `Shoe.id` IS Strava's gear id, so the two key against
each other with nothing in between. `activity_alias` maps activities; a join
added here out of symmetry with the weather query would return zero rows and
report all eleven shoes missing from both sides at once.
`gearKeysDirectlyWithNoAlias` states it, because after four patches of "join the
alias" the dangerous move is no longer forgetting to — it is doing it
everywhere.

### 12.67.2 The eighth isolation instance, and the first that is a construction

`ActivityWeather` and `WeatherSource` were main-actor isolated by the module
default. Reading a stored property off the main actor already worked — SE-0434,
which is how `Sub4Import+Weather` has read `w.tempC` since 133. **Constructing
one did not**, and this reader constructs 583 of them inside a transaction.

Both are now `nonisolated`, as `Activity.dayKey` was at 207, `Discipline` at
219, `Sub4Import` at 228 and `AthleteStore.HRZone` at 317. The check §12.61.7.1
exists to force was made first and is recorded here so it is visible that it was
made: **there is no `extension ActivityWeather` and no `extension WeatherSource`
anywhere in the target**, so the keyword reaches every member. That check is the
one whose absence cost 317a.

`ActivityWeather.provider` keeps its now-redundant `nonisolated` keyword rather
than losing it. The comment above it is the record of why the stored/computed
distinction cost this project time, and a keyword deleted is a lesson deleted —
§9.2's argument about calling a move a deletion, applied to code.

### 12.67.3 `source` cannot round trip, and that is not an approved difference

`ActivityWeather.source` is `WeatherSource?`. `weather.provider` is NOT NULL and
the importer writes `w.provider`, which is `source ?? .openMeteo`. So a nil
source normalises to Open-Meteo on write and **cannot come back as nil**.

The obvious move is a sixth entry on the approved list. It is the wrong one, and
320a already made this exact call about a zero heart rate: an approved entry
would enshrine a wrong comparison as a data decision. What both sides genuinely
hold — and what every screen actually draws — is `provider`, the defaulted
value. So `provider` is compared and `source` is not.

The count of readings whose stored `source` is nil is printed as context. The
normalisation is then visible rather than hidden by the very thing that makes it
harmless, which is the difference between a comparison that is right and one
that merely passes.

### 12.67.4 One field with no column, one column with no field

The approved list gains its fourth and fifth entries, and its only two
STRUCTURAL ones — every entry before this was a value the writer left NULL.

**`Shoe.primary` has no column.** It is Strava's answer to "which pair is the
default": a preference held on their side and refetched with the athlete, not a
fact about the shoe. The database keeps what survives Strava's retirement, and
this is not that.

**`gear.retiredUTC` is a column nothing writes**, and this one is a finding
rather than a decision. Retirement is known at decode time and thrown away
twice:

  - `AthleteStore.swift:401` builds a retired shoe with the comment *"A retired
    shoe is nobody's primary, whatever the API says about the day it was"* and
    sets `primary: false`. The retirement is collapsed into a boolean about
    something else.
  - `Sub4Import`'s `INSERT INTO gear` names six columns and omits this one.

So the schema has a place for a fact the app learns and neither side keeps. It
is recorded here and NOT fixed in 324: filling the column is a change to the
importer, and mixing a reader patch with a writer change is how a later
difference becomes impossible to attribute — 321's argument for single-claim
slices.

`theApprovedDifferenceIsActuallyApproved` changes `primary` on one side and
asserts no difference is reported. **An approved entry that nothing exercises is
a suppression nobody has checked**, and this is the first patch to write that
test — 317's and 322's entries are still unexercised, which is worth fixing the
next time either file is open.

### 12.67.5 The absence that is the database being right

`weather.activityID` is a foreign key. A reading whose activity the roster
dropped **cannot be stored** — the importer counts those as `weatherUnmatched`
and moves on. Reported as "only in the app" they would paint the section red for
the database doing the only thing it can.

So `compare` takes the app's own activity roster as a `Set` and splits them out:
a reading missing from the database is `readingsForUnknownActivities` if the app
does not hold the activity either, and a real difference if it does. Both lines
are on screen; only the second is ever red.

That distinction is only possible because both sides are available at the call
site. Without the roster the honest answer would have been "some of these are
fine and this screen cannot tell you which", which is §12.15's shape — and it is
worth naming that the fix was **passing in more context**, not loosening the
comparison. `aGenuinelyMissingReadingFails` is the pair that keeps it honest:
same shape, activity present, must fail.

### 12.67.6 No tolerance, and why this differs from 314 and 320

Every weather figure is a `Double` written to a REAL column and read back, with
no formatting step in between. That is lossless. The tolerances elsewhere exist
because something in the path rounds — TRIMP is computed at 314, paces are
formatted to whole seconds at 320 — and there is nothing of the kind here.

A tolerance would forgive a difference that can only mean the value changed.
`doublesAreNotForgiven` writes 1/3 and asserts it returns bit for bit.

### 12.67.7 What is still held, after slice 6 closes

**Apple Health.** A cache of somebody else's store. No database this app writes
will ever hold it, and no patch will ever verify it.

**The match decisions.** `match_decision` has no reader and zero rows. It needs
one when the match-picker defect is settled and overrides start being stored.

**The plan's trimmings.** `plan_exercise`, five fuel tables, four warm-up
tables — about 150 rows, drawn on screens, feeding no derivation. Slice 6c, and
the only part of D6c's original eight still open before slices 7 and 8.

## 12.68 The gear writer — patch 325

324's read-back went red on its first device run and both causes were in the
same six lines of `Sub4Import.importGear`. Neither was a defect in the reader.

### 12.68.1 First seen is not last known, and there is a deadline

The function did `continue` on an existing row. Name and distance were written
once, at first import, and never again. The device showed one shoe of six
differing on `distanceM` five days after the database was built — which is
exactly one pair having been run in — and the count could only ever grow.

**A red row on a screen is the small half of this.** ADR-0002 retires Strava at
Phase 4A. When the import is switched off there is no second copy to reconcile
against: whatever sits in `gear.distanceM` on that day is the mileage for ever.
The table's own migration comment says gear "survives the source it came from —
shoes keep their mileage after Strava is gone", and a first-seen figure is not
that. The fix is the difference between freezing the right number and freezing
an old one, and it has a date on it.

Recorded because it generalises: **a cache that stops being refreshed is
harmless right up until it becomes the only copy.** Every table fed by an
importer that will one day be switched off is in this position, and `gear` is
simply the one a read-back happened to reach first.

### 12.68.2 The UPDATE is conditional, and the reason is the counter

`gearRefreshed` counts rows whose name or distance actually moved, not rows the
importer touched. An unconditional `UPDATE` would have been one line shorter and
would have made the counter mean "rows we wrote", at which point a week of zeros
is indistinguishable from a week of no running — and the state worth detecting
is a refresh that has silently stopped.

`gearAlreadyPresent` keeps its meaning: the row was there. `gearRefreshed` is a
subset of it, not a sibling. That shape is what let `ImportTests`' three existing
assertions pass untouched, which was established by grepping the test target
**before** the change was written rather than by running it afterwards —
§12.61.9 used the way it was meant to be.

"new / refreshed" is also already the vocabulary the import panel uses for notes,
reviews, corrections, weather and eight other rows. Gear was the odd one out
saying "new / known", and now reads like its siblings.

### 12.68.3 Gear the source stopped listing is not a difference

Five rows were red as "only in the database". They are shoes Strava's current
gear list no longer returns. `gear.sourceID` is nullable precisely so that a
shoe outlives its source, so keeping them is the schema doing its job.

They are now counted and named on their own line, excluded from `unexplained`,
and never red.

**AMENDED AT 325a — §12.68.6.** The five rows this section was written about were bikes and a retired shoe the app holds, reached through `AthleteStore.allGear`, which the comparison was not given. The category below is still correct and should now read zero; the evidence that motivated it was not.

**The cost is stated on the screen rather than left to be discovered.** The app
side of this comparison IS Strava's current list, so every database row absent
from it falls into this bucket — which means **a gear row that should never have
been written is now undetectable by this comparison.** Nothing records when a row
was last seen, so "retired" and "spurious" are the same observation.

The other direction stays red, and that asymmetry is the point: a shoe the source
lists that the database does not hold is an insert the importer failed to make.
`aShoeMissingFromTheDatabaseIsStillRed` is the pair that keeps the reclassification
from being a blanket forgiveness.

### 12.68.4 Retirement is not implemented, by decision

`gear.retiredUTC` stays unwritten. §12.67.4 called it a column with a place for a
fact the app learns and neither side keeps, and the obvious fix is to write it
the first time a known shoe stops appearing.

**The athlete's decision is not to.** The Strava import is being switched off
once the database holds everything; from Phase 4A the same data arrives from
Apple Health and Workout data, and "absent from Strava's gear list" stops being a
signal that exists. Building a retirement rule on a source that is going away
would be a rule with a shelf life shorter than the patch that writes it.

**AMENDED AT 338 — the sentence above described the destination, not current
capability.** HealthKit does not yet supply the same application package: no
production adapter, gear replacement or source-priority path exists. The
decision not to infer retirement from a disappearing Strava list still stands,
but it cannot be cited as evidence that Strava may already be disconnected.

So the column stays empty and stays on the approved list, and this section is why
— a decision with a reason, rather than an omission a later reader has to guess
at. If Apple Health offers an equivalent signal after 4A, that is the patch that
should fill it.

### 12.68.5 What this says about the read-backs generally

Seven repositories have now been built and this is the first to find a **writer**
defect rather than confirm a reader. The five earlier ones confirmed that what
was written could be read; 324 was the first to compare against a store the
importer refreshes from outside itself, and that is where the gap was.

D6b (302–307) wired every path that *writes a store*. Gear distance is not a
store write — it is a refresh from Strava's athlete endpoint — so it was never in
D6b's scope and no amount of care within that scope would have caught it. The
lesson is not "302–307 were incomplete"; it is that **the boundary of a
completeness claim is the thing to write down**, because everything outside it
looks finished from inside.

### 12.68.6 The five rows were my wiring, not the athlete's shoes — 325a

`reloadWeatherGear` passed `AthleteStore.shared.shoes`. `AthleteStore` holds
**three** collections — `shoes`, `bikes` (patch 267) and `retired` — and already
exposes `var allGear: [Shoe] { shoes + bikes + retired }` for exactly this
question. The comparison therefore saw six items against the database's eleven
and reported five as gear the source had dropped.

Four of those five ids begin with `b`. They are bikes.

**Everything §12.68.3 reasoned about was an artefact of that one argument.** The
reclassification was built on the premise that five rows were shoes Strava had
stopped listing; they were bikes and a retired shoe the app holds in properties
nobody handed to the comparison. The cost §12.68.3 carefully wrote down — that a
spurious gear row would now be indistinguishable from a retired one — was the
right thing to worry about and was paid to absorb a bug rather than a fact.

**The number that would have caught it was on the same screen the whole time.**
The import panel says `Gear: 0 new, 11 known, 3 refreshed`. `11 known` means the
importer's loop ran eleven times, so the *caller* has always passed all eleven.
Six against eleven with the importer plainly handling eleven should have been the
end of it. Instead 324's analysis called them retired shoes, and 325 built a
category on that reading.

That is §12.60.1 for the third time — **do not reason by analogy about two
numbers without checking whether one determines the other** — and this instance
is the worst of the three, because the check was not a grep into unfamiliar code.
It was reading two rows of one screen against each other.

**What is kept, and what changes.**

`gearKeptAfterTheSourceDropped` stays. The category is right and the argument for
not colouring it red is unchanged — `gear.sourceID` is nullable so that gear
outlives its source. What changes is that the line should now read **0**, which
makes it a signal rather than a place a mistake could hide. A non-zero value
after 325a means something real.

§12.68.4's decision is unaffected: Strava is going away, so no retirement rule
gets built. But its reasoning was incomplete and is corrected here — the APP does
track retirement, in `AthleteStore.retired`. It is the database that has no
record. `gear.retiredUTC` stays empty by decision, not because the fact is
unavailable.

**The honest limitation this exposes.** `reloadWeatherGear` is view-layer wiring:
which store property feeds a comparison is decided in a `View` and no test in
this target can reach it. Every test in `WeatherGearRepositoryTests` passes the
gear list explicitly and would have passed identically with the wrong list at the
call site. Seven read-backs in, that is a class of defect the whole apparatus is
blind to by construction — the repositories and the comparisons are tested, and
the sentence that connects them to the app is not.

Recorded rather than fixed. A fix means moving the store-to-comparison wiring out
of the view into something testable, which is a change to seven call sites for no
behavioural gain, and it belongs on its own rather than inside a letter fix-up.

## 12.69 The guard that reported nothing and read as a pass — patch 325b

`scripts/test.sh` arrived at 318 to solve a specific, expensive problem: `⌘R`
compiles the app target only, so test-target compile errors accumulate
invisibly, and patches 275, 276 and 277 all ran on the phone while the suite had
not compiled since 273.

It passed `-quiet` to `xcodebuild`. That flag suppresses swift-testing's summary
along with everything else, so the log held one line — `Testing started` — the
script's own summary grep matched nothing, and it then printed:

    sanity check: the run should report ~931 tests. Far fewer means the test
    target did not build, which is the exact failure this script exists to catch.

A script that ran, produced no errors, and gave advice about a number it had
never seen. **Every test count trusted between 318 and 325 came from typing
`xcodebuild test` by hand instead** — 931 at 317b, 1004 at 322, 1005 at 322b.
The script was in the install instructions of every patch in that range and was
reporting nothing in all of them.

### 12.69.1 Why this is worse than having no script

§12.15 says a diagnostic that cannot say why it has no answer will be read as
having one. Ten instances of that rule are in this document and all of them are
about Swift. This is the same rule in a shell script, and the failure mode is
sharper: an absent guard is visibly absent, and a guard that prints a cheerful
footer occupies the place where a real one would go. Nobody looks twice at a
step that just passed.

The tell was available and unread — the footer says "should report ~931 tests"
directly under a summary section containing nothing. Two lines, adjacent,
contradicting each other, in output shown after every patch for eight patches.
That is the same shape as §12.68.6's `6 vs 11` beside `11 known`: **the
contradiction was on screen and the screen was not read as a whole.** Twice in
one day, which is the argument for the checks below being mechanical rather than
attentive.

### 12.69.2 What the script does now

`-quiet` is gone; the full output goes to the log and only failures and the
summary reach the terminal, which is the trade the original wanted and the flag
took away.

**A run with no `Test run with N tests` line now exits 1.** It is not a pass. It
is the script having learned nothing, which is exactly the state it exists to
detect, and it now says so and fails.

**A run reporting fewer than 500 tests exits 1.** The suite has held four figures
since 322. A number in the tens means a fraction of the target built — the
original header described this check in prose and never implemented it.

The failing-run path is preserved deliberately: `xcodebuild`'s status is captured
rather than allowed to abort under `set -e`, so a genuine test failure prints its
`✘` lines and its summary before the script exits non-zero. The previous version
would have aborted mid-pipeline with the failures unprinted.

### 12.69.3 The rule this leaves behind

**A check that cannot fail has not been tested, and a check nobody has seen fail
is a check nobody has tested.** Neither the 500-test floor nor the missing-summary
exit had ever fired here, because the summary was never present to be absent
convincingly — the script only ever ran one way.

The cheap habit that would have caught it, and the one worth keeping: **the first
time a guard is installed, break something on purpose and watch it complain.**
Point `SUB4_SCHEME` at a scheme that does not exist, or delete a test file, and
confirm the output is not reassuring. Every guard in this project that has ever
mattered — the semantic verifier, the parity sections, the unconditional
diagnostic lines — has a test that makes it fail. This one had prose.

## 12.70 The plan's trimmings — D6c slice 6c, patch 326

`PlanExtrasRepository` reads the ten tables 323 left behind: the fuelling plan,
the race-day warm-up protocol and the exercise library. Eighth repository, and
the last of the plan.

### 12.70.1 A separate claim, deliberately

These feed no derivation. Nothing in `LoadParity` or `MatchParity` waits on
them; they are drawn on screens and that is all. So they get their own reader
and their own report rather than growing `PlanRoundTrip`.

**The reason is what a red row means.** A difference in `PlanRoundTrip` means a
training figure is wrong. A difference here means a screen draws wrong. One
report would have made those the same event, and the first question anyone asks
of a red number is which of the two it is — 321's argument for single-claim
slices, applied to a case where the two claims sit under one heading on screen
and in two files in the source.

The screen keeps them together for §12.65.7's reason: the Database screen now
carries eight read-backs, and a ninth heading for 150 rows nobody derives
anything from is the wrong trade. One heading, two sub-blocks, two reports.

### 12.70.2 One copy of "which version" — §12.43's ninth application

323 resolved the active version inside `PlanRepository.load`, with the
`ambiguousActiveVersion` guard §12.66.3 argued for. This reader needs the same
answer.

It is **extracted and called**, not written again:
`PlanRepository.activeVersion(_:)` now returns `.one / .none / .ambiguous /
.malformed` and both readers switch on it. Two copies would have been two places
to remember that `plan_version_one_active` is unique per PLAN and not per table,
and the second copy is exactly where that gets forgotten — the guard is four
lines and the reasoning behind it is a paragraph.

`theAmbiguityIsInheritedNotReimplemented` builds the two-plans state and asserts
this reader refuses it, so the inheritance is a fact rather than an intention.

### 12.70.3 The wrapper is never compared, only its fields — §12.63.8, third time

`Fuel.Caution` is stored as two columns on its parent, `cautionTag` and
`cautionText`. **There is no column saying whether a `Caution` existed.** Two
NULLs therefore mean either `caution == nil` or `caution == Caution(tag: nil,
text: nil)`, and no reader can tell them apart.

Reconstructing a `Caution` and comparing the object would report a difference
whenever the app held an empty one — a difference that says nothing about the
data and that writing something cannot fix. So the comparison walks `tag` and
`text` as scalars belonging to their parent and never touches the wrapper.

Third application of the rule 320a established with the zero heart rate and 324
reapplied to `weather.provider`: **compare what the reader draws, not the field
it was stored in.** `anEmptyCautionAndNoCautionAreNotDistinguished` asserts the
ambiguity rather than pretending it was resolved — the reader picks "absent",
the comparison never asks, and both facts are in a test.

The same argument covers `Fuel`, `Fuel.RaceDay` and `Warmup` themselves, all
optional on the type and all stored as a row that either exists or does not.
Whether each side has one is printed as context, not asserted as a field.

### 12.70.4 One type, three parents

`Fuel.caution`, `Fuel.RaceDay.caution` and `Warmup.caution` are the same type
reached from three places. Compared as a set of cautions, an importer that wrote
one parent's caution into another's columns would compare **equal** — and the
race-day screen would draw the warm-up's warning.

So each is walked separately and named by its parent: `fuel · caution tag`,
`raceDay · caution text`, `warmup · caution tag`.
`eachCautionIsNamedByItsParent` changes two of the three and asserts the third
is not implicated.

This is §12.66.6's breakdown-kind finding in a different costume. There the
question was which property held a `SessionDetail`; here it is which parent holds
a `Caution`. Both are cases where **the container is the data** and comparing
contents alone cannot see it.

### 12.70.5 Eight lists, one ordinal walk

Products, session targets, ladder steps, race-day lines, race-day steps, warm-up
steps, circuit movements and conditions are all sequences with a
`UNIQUE(parent, ordinal)` behind them. They are compared **by position**, never
as sets: a fuel ladder in the wrong order is a different instruction, and the
16 km row telling you to take three gels is a different instruction again.

One private `list(_:_:_:)` helper does the walk for all eight rather than eight
near-identical loops — §12.43 inside a single file. `aShuffledLadderIsADifference`
swaps two rows and asserts both positions are reported.

The exercise library is the exception and is compared as a dictionary keyed by
`uid`, because that is how the session blocks reference it. A library reordered
is the same library.

### 12.70.7 A function that writes part of what it reads — 326a

The ordinal walk was written as:

```swift
private static func list<T>(_ label: String, _ a: [T], _ b: [T],
                            count: inout Int, fields: inout Int,
                            into r: inout Report, walk: ...)
```

and every call site read:

```swift
list("product", a.products, b.products, count: &r.productsCompared,
     fields: &r.productFieldsCompared, into: &r) { ... }
```

`&r.productsCompared` and `&r` are two exclusive accesses to one variable.
Seven compile errors, one per call site, all saying the same sentence.

**The signature was the defect, not the call.** A function that takes a whole
and one of its parts is asking the caller to alias, and there is no spelling of
that call which does not. Swift's exclusivity rule refused it rather than
letting seven counters be written through two overlapping views of the same
storage.

The fix is not `withUnsafe…` and not copying to a local at each call site, which
is what the compiler's own suggestion would have produced seven times over. The
walk now **returns** a `ListResult` and the caller places the numbers through a
`mutating func absorb(_:count:fields:)` taking key paths — `self` is then the
only thing mutated and there is nothing to alias. One statement per call site,
same as before.

**The rule.** *When a helper needs both an aggregate and its fields, return the
values instead of writing them through.* `inout` on a part and `inout` on its
whole cannot coexist in one call, and a design that wants both is a design that
has not decided who owns the result.

**This is the first build failure `scripts/test.sh` has ever reported.** It
printed all seven errors, refused to print a summary, and exited 1 — the exact
service §12.69 restored one patch earlier, on the very next patch, against a
mistake it had no part in. Fifteen patches ran through it silently between 318
and 325b; this one took thirty seconds to name.

### 12.70.6 What is left after slice 6c

D6c has one slice remaining of its original eight — 7, the review payloads —
plus 8, the tab summaries. `review_evidence_source` stays unverifiable against
real data until the first real review on **24 August 2026**, which is the one
date in this project that no patch can bring forward.

The plan is now read back in full: 260 sessions, 37 weeks, 82 breakdowns, 634
blocks at 323, and 71 records of trimmings here.

## 12.71 The review trail — D6c slice 7, patch 327

Ninth repository, and the only slice in D6c whose subject may legitimately not
exist. `ReviewDue.state()` needs four finished plan weeks; the block began
Monday 27 July 2026, week 4 ends Sunday 23 August, and the first real review is
due **Monday 24 August 2026**. §12.8.3 built `ReviewRehearsal` so that day is a
repeat rather than a premiere. This is the other half of that preparation: the
read-back that will say, on the 24th, whether the review survived the trip.

Six tables: `review`, `review_evidence`, `review_evidence_source`, `proposal`,
`proposal_change`, `proposal_watch`.

### 12.71.1 A green zero, exactly once

Every previous read-back could assume its subject existed — 672 activities, 583
readings, 260 sessions. This one cannot, and that changes what the screen has to
say.

`ReviewLoad.loaded(reviews: [])` is a **successful** read of an empty trail, and
the line carries the date:

    No review is stored. The first is due 24 August 2026, so this is the
    expected state until then.

That is §12.15 in its purest form. "Nothing compared" is the same sentence
whether the review path is broken or whether it is three weeks early, and only
one of those is worth acting on. A row that sat red for three weeks would train
its reader to scroll past it — §12.40.1 measured that once already — and the row
that then went red for a real reason would be the one nobody looked at.

So `bothSidesAreEmpty` is the one condition under which this section is healthy
while comparing nothing. Any other zero is still a zero worth looking at:
`reviewsInApp`, `reviewsInDatabase` and `reviewsCompared` are three separate
numbers and the summary names which of four worlds the reader is in.

### 12.71.2 Prose is compared in full and reported in characters

322 established that a note's text is compared and never printed. This slice
carries strictly more of that kind of content: `review_evidence.body` is the
entire evidence pack — every figure the model was given about the athlete's
training — and `proposal.reasoning` is a model's prose about the athlete, at
length. `summary`, `newDetail`, `why` and every watch item are the same class.

The rule, therefore: **a difference is named by its field and measured in
characters.**

    review 2026-06-05T09:00:00Z · evidence body (app 4812 chars, database 4780)
    review 2026-06-05T09:00:00Z · summary (same length, 220 chars, different text)

Both forms are actionable — a length difference says truncation, an equal length
with a difference says substitution — and neither discloses a character.
`noDiagnosticLineCarriesReviewText` plants a sentinel in every prose field,
forces every comparator to fire, and greps every emitted line for it. That test
is the only thing standing between this section and a future edit that prints a
value, because every other test would still pass.

### 12.71.3 `review_evidence_source` is written by nothing

The finding, and it is not a zero.

The table exists because ADR-0002's purge has to find every stored piece of
evidence with Strava lineage and remove it while leaving the verdict standing.
The schema comment argues that at length and is right: lineage has to be
queryable, and a comma-separated column would make a data-deletion obligation
depend on substring matching.

Nothing writes it. Not `Sub4Import.importProposals`, not the review runner, not
the rehearsal. Its only `INSERT` in the whole project is inside
`DomainSchemaTests`. So it holds zero rows on every device, will hold zero rows
on 24 August, and **ADR-0002's lineage obligation is presently unmet by
construction rather than by accident.**

§12.54.2 is why the row is worded as a statement about the writer rather than a
count:

    Lineage rows        0 — nothing writes this table

A bare `0` cannot say which kind of zero it is. This one can.

Two smaller members of the same family, both printed unconditionally:

- **`proposal.decision` and `decidedUTC`** — two columns for accepting or
  rejecting a proposal. `ReviewProposal` has no such field and no screen offers
  the choice. Same shape as `gear.retiredUTC` at §12.68.4, and filed as an
  approved structural difference for the same reason.
- **The evidence decomposition** — the schema anticipates a pack of sections,
  each of which may be withheld, and argues carefully that the audit trail has
  to show what was NOT sent. The importer writes exactly one row per review,
  `sectionKey = 'pack'`, `wasSent = 1`, unconditionally. The withheld branch has
  never had a row. `sectionKeysSeen` and `evidenceWithheld` are on screen so the
  day that changes is visible.

### 12.71.4 Two contracts for `confidence`, and neither knows about the other

`ReviewProposal.confidence` documents itself in its own comment:

    /// 1–5. Low confidence on a `harder` verdict is a reason to wait.

`proposal.confidence` carries `CHECK (confidence IS NULL OR (confidence >= 0 AND
confidence <= 100))`.

`AuthoredImportTests` has been writing **70** since patch 225 and nothing has
ever objected, because 70 satisfies the column and no code enforces the comment.
So there are two live contracts, they disagree by a factor of twenty, and the
figure is one a human reads to decide whether to act on a proposal.

**Not resolved here, and deliberately.** Deciding whether 1–5 or 0–100 is right
is a product decision about a screen that does not exist yet, and a patch that
tightened the CHECK would refuse the rehearsal record already on the device.
What this patch does is make the disagreement *visible*: `confidenceRange` is on
screen and in the paste, so the first real review either lands inside 1–5 or
does not, and somebody can decide with a number in front of them.

Recorded because a contradiction nobody has written down is one that gets
rediscovered rather than fixed.

### 12.71.5 The sixth canonical-id instance, and the first that gets resolved

`proposal_change.planSessionUID` holds `ReviewProposal.Change.sessionUid`, which
is the plan session's **`uid`** — the column 323 compared — and not
`plan_session.id`. Sixth member of the family after `gearId` (289), athlete
provenance (317), `correction.subjectID` (322), `plan_session.planWeekID` (323)
and `weather.activityID` (324).

It is deliberately **not** a foreign key. The migration header says why: a
proposal has to survive a plan revision that renumbers the week it names.

Which means nothing checks it — and `ReviewProposal.rejections(plan:)` already
has a name for the failure: *"no session with that id — invented"*. That check
runs against the app's current plan at read time. Nothing has ever run it
against the database.

So this reader does, and it is the most valuable number in the slice:

    Naming a known session        3 of 3
      plan session uids in the database      260

Resolved against `SELECT DISTINCT uid FROM plan_session` across **all** stored
versions, not the active one. A proposal written against Rev 4.0 names uids that
Rev 4.1 may have dropped; counting that as unresolved would report history as
corruption. The uids are read inside the same transaction as the changes they
resolve, because a second read could see a plan that had been re-imported in
between and report resolutions that were never true together.

An unresolved uid feeds `unexplained` through the subtraction
`changesCompared - changesNamingAKnownSession`, so it is red exactly once rather
than twice.

### 12.71.6 §12.43, tenth application

`proposal_change.what` has no app-side field — the importer derives it, and the
derivation is two lines:

    c.skip ? "Skip this session" : c.newDetail

Two lines is exactly the size of copy that gets away with drifting, so the
comparison calls `Sub4Import.changeSummary(_:)` rather than restating it.
`Sub4Import.iso8601(_:)` and `Sub4Import.reviewProvider` are called for the same
reason: the pairing key and the provider constant both belong to the writer, and
a second copy of either is a second place to forget.

`review.provider` is the third approved difference for this reason. The app
holds a model and no provider; §12.7.2 refused to guess one from the model
string; so the comparison checks the column against the constant the importer
writes, which is what §12.63.8 means by comparing what the writer draws rather
than the field it came from. There is no field it came from.

### 12.71.7 One case the guard deliberately does not cover

`ReviewProposal.acceptedChanges(plan:)` and `rejections(plan:)` are guardrails
applied at READ time on the app side — locked weeks, empty evidence, invented
uids, duplicate sessions. They are not stored and must not be: the database
keeps what the model said, and the guardrails are a judgement made freshly
against whatever plan is current.

Comparing them here would be comparing a derivation against a record. That is
slice 8's job for the tab summaries and nobody's job in slice 7, and naming it
means it is not discovered as a gap later.

### 12.71.9 The type-checker failure left SwiftUI — 327a

`Report.diagnosticLines` was one array literal of thirty-eight elements, most
carrying string interpolation and two carrying `+` concatenation. The compiler
refused it:

    error: the compiler is unable to type-check this expression in reasonable
           time; try breaking up the expression into distinct sub-expressions

CLAUDE.md has carried this rule since the Phase 2 work, and every instance until
now was a SwiftUI `Form` or `body`. **It is not a SwiftUI problem.** It is a
problem with any single expression large enough that the constraint solver has
to consider the whole of it, and a big array literal of interpolated strings is
exactly that shape — SwiftUI just produces them more often.

`PlanExtrasRoundTrip.diagnosticLines` has thirty-four elements and compiles, so
the threshold sits somewhere between the two. Locating it precisely would be
worthless: it moves with the compiler version and with what else is on the line.
The fix is to stop writing the shape. One `lines.append(...)` per statement is
trivially checkable, reads the same, and cannot regress.

The same insurance was applied to `DatabaseHealthView.reviewReadBackSection`'s
footer — eleven concatenated string literals hoisted to
`private static let reviewFooter`. That one had not failed. It is in the largest
`body` in the project and would have been the next to.

**The rule this leaves behind:** a list of interpolated strings is an
expression, not a list. Build it with statements once it is longer than a
screenful, in a view or out of one.

### 12.71.10 Could not be checked is not the same as failed — 327b

The resolve in §12.71.5 shipped counting **every** unresolved `planSessionUID`
against the database, including on a database holding no plan at all.

`planSessionUIDsKnown == 0` does not mean the uid is wrong. It means the
question could not be asked. Counting it as a difference tells the reader the
model invented a session, on a device that has simply not imported the plan yet
— and "the model is fabricating sessions" is an accusation somebody would act
on.

This is §12.15 wearing a number instead of a sentence. A diagnostic that cannot
say why it has no answer will be read as having one, and a *count* that cannot
distinguish "no answer" from "the wrong answer" is the same failure with less
room to explain itself. It is also `StoreReadJournal.canReconcile`'s argument in
a second place: **do not act on the strength of an incomplete reading.** There
the act was a delete; here it is an accusation.

    changesUnresolvable  =  planSessionUIDsKnown == 0 ? changesCompared : 0
    changesResolvable    =  changesCompared - changesUnresolvable
    unexplained         +=  changesResolvable - changesNamingAKnownSession

Both figures print unconditionally, and the "could not be checked" row is not
red at any value.

**Two tests found it, and a third had asserted the defect.**
`aReviewRoundTripsWhole` and `nothingWritesEvidenceLineage` both imported a
review without a plan and both went red on a report whose every difference list
was empty — a `unexplained: 1` with nothing to point at, which is not a state a
correct report can be in. Meanwhile `noPlanMeansNoResolution` asserted the
behaviour as shipped, in so many words: *"a uid that cannot be checked is not a
uid that passed"*. That sentence is true and the conclusion drawn from it was
not: not-passed and failed are different, and the report only had one column for
them.

The test is now inverted and paired with `aPlanMakesTheQuestionAnswerable`, so
the two cases are pinned against each other rather than one of them being
assumed.

### 12.71.11 Two smaller corrections in the same run

**A printed string changed in a fix-up and the test target was not grepped.**
327a rebuilt `diagnosticLines` (§12.71.9) and reworded the lineage row from
*"nothing writes review_evidence_source"* to *"nothing in the app writes
review_evidence_source"*. `nothingWritesEvidenceLineage` greps for that text and
went red. §12.61.9 names three shapes that carry assertions elsewhere — a
function's arity, an array's length, **and a printed string's content** — and
the rule was followed when writing 327 and skipped when fixing it. *A fix-up is
a patch.*

**`what` is derived from `newDetail`, so they cannot differ independently.**
`aChangeMovedToAnotherSessionIsADifference` swaps two changes' replacement text
and expected two differences. It reports four:
`Sub4Import.changeSummary` returns `newDetail` for a non-skip, so each swapped
position differs on both fields. §12.60.1 in miniature — reasoning about two
numbers without checking whether one determines the other, for the fourth time.

The four is worth having rather than papering over: it is the observable
consequence of §12.71.6 calling the importer's own derivation instead of
restating it. If `what` ever stopped tracking `newDetail`, that count would
drop to two and the test would say so.

### 12.71.12 The device run, and the two identities it found — 8 August

Slice 7 was expected to have no device evidence before 24 August. It got some
the same evening, because the rehearsal button was pressed about eleven times
while its confirmation went unnoticed, and the import that followed reported
**Reviews: 5 new, 6 refreshed** — eleven records seen where one was expected.

The read-back said:

    The read      8 reviews, 8 proposals, 0 evidence-lineage rows.
    Compared      56 compared · 3 differences

    Reviews       11 vs 8 · 8 compared · 40 fields · 0 differ
      App records sharing a run time        3        ← the only red row
    Evidence      11 vs 8 · 8 compared · 32 fields · 0 differ
      Section keys seen                     pack
      Lineage rows            0 — nothing writes this table
    Proposals     11 vs 8 · 8 compared · 40 fields · 0 differ
      Confidence range seen                 3
      Carrying a decision     0 — no screen offers the choice
    Changes       22 vs 16 · 16 compared · 96 fields · 0 differ
      Naming a known session                16 of 16
      plan session uids in the database     260
    Watch items   22 vs 16 · 16 compared · 0 differ

**Every denominator is an exact product** — 8×5, 8×4, 8×5, 16×6, and
8+8+8+16+16 = 56 — and `unexplained` is exactly the three collisions. 224 field
comparisons across eight reviews with zero differences, and sixteen of sixteen
`planSessionUID` values resolving against the 260 uids the database holds. The
round trip is correct.

#### A review has two identities and they do not agree

The app's identity for a review is `ProposalStore.Record.id` — *"window
start→end, plus run count"*. The database's is `(accountID, ranUTC)`, and
`ranUTC` is `Sub4Import.iso8601`, which is `.withInternetDateTime`: **one-second
resolution.**

Two records written inside the same second are therefore one row. Eleven became
eight. The importer is doing exactly what it was written to do — idempotent by
lookup — and the lookup key cannot distinguish them.

Three things follow, and only the first is cosmetic:

1. `Record.id` is never stored, so the run count is not representable at all.
   It is on the approved list (§12.71) as *"no column, and none is wanted"* —
   which was written believing `ranUTC` was a sufficient key. It is sufficient
   for one review a month and not in general.
2. **`review` carries no unique constraint on `(accountID, ranUTC)`.** The
   convergence is a convention enforced by a `SELECT` in one importer, not a
   guarantee the schema makes. A second writer would not inherit it.
3. The three lost records are lost *silently* on the writing side. Nothing in
   the import panel says so — `5 new, 6 refreshed` sums to eleven and reads as
   complete. **The read-back is the only thing in the app that noticed**, and
   it noticed because `duplicateRunTimes` reports a key collision instead of
   letting `Dictionary(uniquingKeysWith:)` drop one silently. That line was
   written as a defensive formality and earned its place within an hour.

#### The decision is Bruno's

Real monthly reviews arrive one per month, so the collision needs two writes in
the same second and cannot happen in normal use. Three ways forward:

- **(a) Record it and move on.** The failure is reachable only through the
  rehearsal, which is an internal-build button. Cost: the schema keeps a key it
  cannot fully honour, and the read-back shows a red row on any device that has
  rehearsed.
- **(b) Carry `Record.id` onto `review` and key the importer on it.** Makes the
  two identities one, which is the canonical-id family's whole lesson (§12.71.5
  is the sixth instance). Cost: a migration, and `review.id` becoming a column
  with two meanings unless the new one is named separately.
- **(c) Sub-second `ranUTC`.** Smallest change, and the worst of the three: it
  makes the collision *less likely* rather than impossible, which is the kind of
  fix that removes the symptom and leaves the cause.

**Asked and answered on 8 August: (a) — record it, do not fix it.** The failure
is reachable only through an internal-build button, real reviews arrive one a
month, and D7 is the next rung. This section is the record. If a second writer
of `review` ever appears, or if the app gains a way to run two reviews in one
second, this becomes a defect rather than a note — and the unique constraint
`review` does not have is where it would be fixed.

#### The rehearsal records must go before 24 August

Eleven of them. `ReviewDue` counting any would push the first real review out by
28 days, from 24 August to 21 September. Delete on the Progress tab, then import
again — `Reconciled: yes` was already on during this run, so the `review` rows
cascade out with `review_evidence`, `proposal`, `proposal_change` and
`proposal_watch` behind them.

## 12.75 The tab summaries, compared — D6c slice 8, patch 330

**D6c is complete.** Eight slices, the last one built on 328's `SessionTally`
and 329's `TabSummary`.

### 12.75.1 The slice that stopped holding the plan

Slices 1–5 hold the plan from the app. `ShadowParity.matchReport` calls
`PlanStore.shared.sessions(on:)` for **both** sides, and the screen has always
said so — *"Held from the app: the plan, the match decisions and the commute
decisions"*, with *"Of those, verified: the plan … by their read-backs"*
underneath. It is a division of labour, not an oversight: `PlanRoundTrip` (323)
proves the plan is identical, `MatchParity` (321) proves the matching is
identical **given** a plan.

**AMENDED AT 338:** `PlanRoundTrip` proves mapped values pair by UID. It does not
prove source-only metadata or top-level array order; §12.86.7 records both gaps.

**Slice 8 reads the plan from `PlanRepository.load` instead.** Decided
8 August, after the holding pattern was discovered part-way through designing
the slice — which is worth recording, because the earlier decision to compare
"both halves" was taken while describing a twin that read the plan, and the
existing screen said otherwise.

The consequence is that slice 8 **holds only the match decisions**, which makes
it the closest thing on that screen to what D7 will actually do. The cost is
that the screen now carries two different answers to "where does the plan come
from", so each slice's `heldFromTheApp` line states its own rather than leaving
a reader to infer one from another.

### 12.75.2 What it compares, and what it deliberately does not

| compared | not compared, and why |
|---|---|
| the `WeekPoint` series — planned km, actual km, longest run, done-of-total, per begun week | day and week distances — slice 2 |
| the four volume rows, actual and planned | CTL, ATL, the HR histogram — slice 3 |
| the block tally, summed from the week points | the per-day matching itself — slice 5 |

Groundwork §1.1 lists the six slices whose results must not be re-proved.
Comparing them again would triple the run time and produce a second answer to a
settled question — §12.29's problem.

The block tally is **summed from the week points**, not counted a third way.
`Sessions 10/208` on the Progress card and `10 of 208` on the adherence line
are already two paths to that number; a third would be a third chance to drift.

### 12.75.3 The longest run is the one figure a total cannot hide

Every other figure in this slice is a sum, and a sum hides a swap: two weeks of
10 + 10 and 4 + 16 agree on 20 km and disagree on the longest run.
`longestRunKm` is also the figure the long-run progression is steered by, which
is the point of a marathon block.

`aLongerRunHidingBehindTheSameTotalIsCaught` is that case stated directly, and
it is the test most likely to ever fire.

### 12.75.4 The hole inside a closure

`TabSummary.weekPoints` takes `day: (String) -> MatchResolver.Day`. A closure
returning an **empty** day for a key the database has nothing for is
indistinguishable from a day that genuinely holds nothing — §12.15 inside a
lambda, where no `guard` can see it and no `nil` can be returned.

Every other figure in the slice is per WEEK, so a handful of missing DAYS would
barely move one of them. So both closures count what they were asked:
`daysAskedFor`, and how many of those each side had anything for. Three figures,
printed unconditionally, and the only place a day-shaped hole could show.

Named in the slice-8 addendum §2 **before the code existed**, which is the
second time on this rung that writing the trap down first is what stopped it.

### 12.75.5 A green tick that could never have been anything else

The four volume rows are compared unconditionally — even on a device holding
nothing. So `lookedAtSomething` cannot be `totalCompared > 0`: that test could
never be false, and the slice would report healthy having proved nothing.

It is `weeksCompared > 0`. Zero begun weeks is a real state — before 27 July
2026 it was the only state — and the honest reading of it is *"nothing
compared"*, not *"agreed"*. Caught while writing the report rather than by a
test, and `zeroWeeksIsNotHealthy` now pins it.

### 12.75.6 The clock, read once

`todayKey` is read **once** in `summaryReport` and handed to both sides.
`weekPoints` skips weeks that have not begun, so two reads of the clock — one
per side — is a race that surfaces only when the comparison straddles midnight,
which is exactly when nobody is looking. 329 made it a parameter so this could
be done; 330 is where it is done.

### 12.75.7 A sixth associated value, and the three call sites it broke

`ShadowParity.Outcome.ran` gained `summaries:`. Three test files construct that
case — `LoadParityTests` twice and `VolumeParityTests` once — and all three
were found **before** the edit, by grepping `\.ran(` across `Sub4/` and
`Sub4CoreTests/`.

§12.61.9 names "a function's arity" as one of the three shapes that carry
assertions elsewhere, and §12.72.7 is the record of what skipping that grep
cost two patches ago. Each call site gained a `summariesAgree()` helper for the
same reason `matchesAgree()` exists: an empty pair compares zero of zero, fails
`lookedAtSomething`, and would make those assertions pass with one more failing
slice than they mean to test — 315a's defect, now avoided for the fifth time.

### 12.75.9 Two the first run corrected — 330a

**A missing week is two differences, not one.** `aWeekOnOneSideOnly` expected
`unexplained == 1` and got 2. The report was right: a week the database does not
have changes the week set *and* the block tally, because the block is summed
from the week points (§12.75.2). Two claims about two numbers the athlete reads,
and an expectation that collapsed them would have hidden the second the day it
mattered. The test now asserts both, including the `6 of 8 vs 3 of 4` line.

**The paste said something the screen did not.** The day figures were two
diagnostic lines — *"days the app had anything for: 5"*, *"days the database had
anything for: 3"* — while the screen row beside them already read
`with anything in each side · 5 vs 3`. One line, `X vs Y`, now, matching the
screen and matching every other two-sided figure in the file.

That is worth a sentence beyond the fix: **a diagnostics paste exists to be read
by somebody who was not holding the phone.** If it states a figure differently
from the screen it was copied off, the reader has to translate before they can
compare, and the paste has quietly become a second account of the same run —
§12.29's problem in a smaller box.

### 12.75.10 The runtime face of a rule this file already carried — 330b

330 crashed on the device. `EXC_BAD_ACCESS (code=2)` inside
`___chkstk_darwin` — the stack probe — three frames under
`SwiftUI.List.body.getter`. **A stack overflow while SwiftUI evaluated the
Database screen's body.**

Not a logic fault, and the timing says so: slice 8's rows render nothing until
`parity.last.summaries` is non-nil, so the screen opened cleanly and died on the
**first press of Compare**, the moment 25 more rows and two `ForEach`es
appeared inside a `Section` that was already the largest view in the project.

#### This project had already written the rule down, in its other form

CLAUDE.md §2 and §12.71.9 carry the COMPILE-TIME version: *"unable to
type-check in reasonable time"*, whose remedy is *"split Sections into computed
properties; hoist long strings to constants"*. 327a hit it in a plain
`[String]` and the lesson recorded then was that it is **not a SwiftUI
failure** — it is any single expression large enough that the machinery has to
solve the whole of it.

**330b is the same sentence with "stack" where "type-checker" was.** The
compile-time face fails loudly on a laptop in seconds. The runtime face
compiles clean, passes 1136 tests, and only appears on a device that has enough
data to fill the rows. **The second is far more expensive, and it is the one
that had never been written down.**

#### The fix does two things, deliberately

- Slice 8 became a **`Section` of its own**, which cuts the parent's child
  count rather than adding to it.
- Its rows became **three `@ViewBuilder` functions**, which cuts the nesting
  depth inside that section.

Either alone might have sufficed. Neither alone is worth a second crash to find
out, and the split reads better anyway — §12.40.1 measured that a screen nobody
scrolls to the bottom of is a screen whose bottom rows are not read, and slice
8's figures were the bottom of the bottom.

#### What this says about the screen generally

`DatabaseHealthView` is now ~3,000 lines and holds eight read-backs, six parity
slices, an import panel, a verifier, a survey, a benchmark and a write-through.
**It has reached the size where adding to it is a structural change, not an
edit.** The read-back roll-up already on the pre-D7 list is no longer only about
`@State` evaporation; it is also about this. Recorded so the next patch that
wants "just a few more rows" reads it first.

### 12.75.8 What D6c proved, and what it did not

Eight slices, nine read-backs, and every one green on the device.

**It proves the mapped database paths can feed the covered calculations.** The
covered derivations produce the same answer from either side, and the mechanism
D7 switches onto exists and is exercised. It does not prove literal record
round-trip; §12.86.7 records unmapped fields and ordering.

**It does not prove the app is right.** §12.72 is the standing evidence: seven
copies of "done of total" disagreed for 230 patches, on two screens, and no
shadow-parity slice could have found it, because every slice compares the app
against the database and that was the app disagreeing with itself.

Both sentences belong in the D7 decision.

## 12.76 The fix that made it worse, and what that proved — patch 330c

330b was wrong, and the way it was wrong is the useful part.

§12.75.10 diagnosed the 330 crash as **volume**: 25 rows and two `ForEach`es
appearing inside the largest `Section` in the project. The remedy followed from
the diagnosis — give slice 8 its own `Section`, split its rows into three
functions.

**The crash got worse.** It moved from the first press of Compare to **opening
the tab**, before any comparison has run and while slice 8 renders nothing at
all. Same signature: `EXC_BAD_ACCESS (code=2)` at a stack address, inside
`___chkstk_darwin`. Frame 82 was `start`, so eighty-one frames sat under it.

### 12.76.1 A screen that draws nothing cannot crash from what it draws

That is the whole argument. On open, `parity.last` is `.never`; every
`if let` in the parity sections takes its empty branch; slice 8's section
builds nothing. If the fault were the number of rows, 330b could not have
crashed earlier than 330 did.

So the thing 330b changed on open was not what the screen **draws**. It was the
**shape of the type**. `DatabaseHealthView.body` held twenty-one sections side
by side in one `@ViewBuilder` block, and a `@ViewBuilder` block is not a flat
list — it is a left-leaning chain built pairwise, so twenty-one children are
twenty nested `TupleView`s. SwiftUI walks that chain recursively before it
draws a single row, and each level costs a frame. **330b added a child, which
added a level, whether or not that child ever draws anything.**

The two crashes then have one explanation instead of two: the screen was
sitting on the stack limit, and 330 tipped it over at runtime depth while 330b
tipped it over at structural depth.

### 12.76.2 Depth is the budget, and there are two ways to spend it

- **Balance the chain.** Twenty-one children in a row is depth twenty. Six
  groups of three to five is depth nine. `body` now calls six `@ViewBuilder`
  group functions — `stateSections`, `inputSections`, `ledgerSections`,
  `activityReadBackSections`, `recordReadBackSections`, `toolSections` — plus
  one child view. The sections, and their order, are untouched.
- **End the chain.** A separate `View` struct is a boundary: the parent's body
  type contains `ShadowParitySections`, one `Sub4Database` wide, and none of
  what is below it. Seven hundred lines of view code left
  `DatabaseHealthView`'s type entirely.

Inside the new file the same budget is spent again: the five parity slices had
branches of up to thirty-two consecutive rows, and each is now two or three
`@ViewBuilder` functions. Deepest path in the parity section went from roughly
thirty-six to roughly nineteen.

### 12.76.3 Why parity was the right thing to extract, and the others were not

**Its dependency surface is one line long.** Every row in slices 1–5 and 8
reads `ShadowParity.shared` and the open database. Not one of them touches any
of `DatabaseHealthView`'s forty `@State` properties. That is what made the
extraction a move rather than a rewrite — no bindings, no plumbing, no
behaviour to re-verify beyond "the rows are the same rows".

The read-backs are the opposite: each owns two or three `@State` properties and
a reload function the screen's `onChange` calls. Extracting those means moving
state, and state that moves is state whose lifetime changed — which is exactly
the class of defect §12.57 was written about. They stay, grouped.

### 12.76.4 The rule, stated so the next one does not need three tries

**§12.76.4 — a SwiftUI body has a depth budget, and a child that draws nothing
still spends it.** The compile-time face of this is "unable to type-check in
reasonable time" (§12.71.9). The runtime face is `___chkstk_darwin`
(§12.75.10). Both are the same failure — a single expression the machinery has
to solve whole — and for both the remedy is *fewer children per block and
fewer levels per path*, not fewer rows on screen.

And the corollary, which is what cost two patches here: **when a size fix makes
the crash earlier rather than later, the size was not the size you thought it
was.** 330b treated §12.75.10's own closing sentence — *"it has reached the
size where adding to it is a structural change, not an edit"* — as advice about
the section being added. It was advice about the screen.

### 12.76.5 What this cost, honestly

Three consecutive fix-ups on one patch, two of them shipped on a wrong
diagnosis, and a device that could not open its own health screen for the
duration. The tests were green at 1136 through all three. **No test in this
project can see a stack overflow**, and none of the 1136 touches a view body;
the only instrument for this class of defect is the phone.

## 12.77 The number that existed and could not be read — patch 331

Not a new diagnostic. Every figure in patch 331's section was already computed;
none of it could be seen without pressing a button that then discarded the
answer.

`TraceCoverage` has classified all 674 activities into five buckets since patch
277. `DetailStore.backfillRemaining` has been `pending.count` since it was
written, and its own comment says so: *"nothing has ever shown it — §12.23.7."*
That comment was written as an aside. On 9 August it became the whole problem.

### 12.77.1 What made a readability point into a two-day blindfold

A reinstall emptied the phone (§12.78). 674 activities came back from Strava in
a single sync; their details and traces did not, because `DetailStore` drains
**30 activities per sync** and each costs up to two requests — about 60 of
Strava's **100 requests per 15 minutes**, against a **1,000-per-day** ceiling.
592 activities queued is roughly 1,184 requests. **It is a two-day backfill and
the app can do nothing about that**, because the constraint is Strava's daily
quota rather than any constant in this project. A larger batch would mean fewer
presses, not more activities per day.

For those two days the only two questions that matter are *how many are left*
and *am I rate-limited right now*. The app could answer neither, and the athlete
found out he had hit the limit by noticing a batch delivered 22 of 30.

### 12.77.2 Where the answer was hiding

Inside `if let r = importReport`. `importReport` is `@State`, nil until the
Import button is pressed, discarded when the sheet is dismissed.

**This is §12.57 on a second screen.** 313 moved the parity result off `@State`
onto the runner, because pressing Done discarded it and the diagnostics paste
then said "Not compared since this launch" a minute after a comparison passed —
true of the `@State`, false about the world. The trace account had the identical
shape and nobody looked, because at the time it was a curiosity rather than a
thing anybody needed hourly.

The lesson is not "move state to the runner". It is that **a figure worth
printing is worth printing without a precondition**, and the precondition is
usually invisible to the person who wrote it because they had just pressed the
button.

### 12.77.3 Gated on `missing > 0`, which is the other half of the same fault

The block also drew only when something was missing, so a finished backfill and
a section nobody wired in were the same screen. **§12.54.2, fourth instance on
this one view.** The whole purpose of a backlog row is to be read on the day it
reaches zero; the version that disappears at zero is the version that cannot
answer the question it exists for.

331 draws all five bucket rows and all three headline rows unconditionally.

### 12.77.4 Two counters, deliberately not merged

`Still to fetch` is `pending.count` — activities missing a **detail or** a
trace. `queued, not yet reached` is the subset missing a **trace**. They differ
by the activities whose detail landed and whose trace did not, which during a
drain is most of a batch.

Merging them would have been tidier and wrong: the first says how much work is
left, the second is one term in an account that must sum to 674. The footer
states the difference rather than leaving a reader to discover that two numbers
labelled like synonyms are not equal.

### 12.77.5 What it cost, and the rule

The section is thirty rows of view code and no new computation. It should have
existed at 277, when the counters did.

**§12.77.5 — a computed diagnostic behind a `@State` precondition is not a
diagnostic.** It is a diagnostic for whoever pressed the button, in the launch
they pressed it, and for nobody afterwards. When adding a counter, the question
is not "is it correct" but "who can read it, and when" — and the answers must
be *anybody* and *whenever the screen is open*.

## 12.78 The phone was wiped, and what came back — 9 August 2026

Not a patch. An operational event with three lessons, recorded because the
project's own contract has been warning about this since D0 and this is the
third time it has happened.

**The app was deleted by hand** during 330b's crash loop — a reasonable thing to
do to an app that will not open its own screen. Deleting an iOS app removes its
container, so it took every JSON store with it.

### 12.78.1 The ledger of what survived

| | |
|---|---|
| **Recovered from Strava** | 674 activities, 586 weather readings, 11 gear, 15 resting months, 5 HR zones |
| **Survived as source code** | `DataCorrections` — the elapsed-time overrides, the official race splits, the 2 ignored recordings and the 3 speed-contradiction rejections |
| **Gone for good** | 7 session notes and their sRPEs (`notes.json`), 4 commute decisions (`commutes.json`) |
| **Gone and welcome** | the 11 review rehearsal records, which §12.71.13 required be deleted before 24 August |
| **Gone, and it was the safety net** | the protected snapshot — it lived in the same container |

**`correction` reading 0 while `rejection` reads 3 is correct**, and the pair is
worth keeping because it looks like a defect. `rejection` is fed by
`DataCorrections`, which is Swift source and shipped in the binary.
`correction` is fed by `commutes.json` — see `Sub4Import+Correction`'s header,
which is explicit that the commute IS the athlete's decision. Source survived a
container delete; the athlete's four decisions did not.

### 12.78.2 The snapshot existed and was empty, which is the whole argument

D0's contract item 3 — *"copy every legacy input unchanged into a dated
protected snapshot before decoding"* — has been open since patch 246. §12.13.6
called it *"the most important missing piece in the project"* and recorded that
two reinstalls had already destroyed `notes.json` and `weather.json` while it
was outstanding.

It was still outstanding. **The first protected snapshot in this project's
history was taken at 08:39 UTC on 9 August 2026** — `2026-08-09-083914`, 67 of
67 files, 1.4 MB, zero failures, taken by patch 330c. Five declared files read
NOT PRESENT, which on a phone four hours into a rebuild is the correct answer
and is drawn dim for that reason.

**A snapshot button that has never been pressed is not a backup.** The feature
shipped at 247; the protection began on the day after the loss it was built to
prevent. Nothing about the code was wrong.

### 12.78.3 The recovery is bounded by Strava, not by anything here

`DetailStore` drains **30 activities per sync**, each costing up to two
requests — about 60 of Strava's **100 requests per 15 minutes**, leaving room
for the activity-list call. The daily ceiling is **1,000 requests**, windows
resetting at :00/:15/:30/:45 and the day at midnight UTC.

674 details plus their traces is roughly 1,350 requests. **It is a two-day
backfill and no constant in this project shortens it.** A larger batch would
mean fewer button presses for the same ~490 activities per day. Recorded so the
next person to look at `batchSize = 30` and think it is conservative does not
spend a patch finding out.

**Consequence for anything read during those two days:** every parity slice
touching details or recordings will report large gaps that are the drain, not
data loss. The Database screen says so on its face since 331.

## 12.79 Getting the diagnostic off the phone — patch 332

The diagnostics paste has existed since 203 and has exactly one exit: the
clipboard. Getting it to a Mac meant pasting it into Notes and waiting for
iCloud, every time, and during the 9 August rebuild that was several times an
hour.

332 adds a second button beside Copy. It writes the same text to
`sub4-diagnostics-<day>-p<patch>.txt` in the temporary directory and hands the
URL to `ShareSheet` — so AirDrop, Save to Files, Mail and Messages all appear.

### 12.79.1 `ShareSheet`, and the reason it exists at all

`ShareSheet.swift` already wraps `UIActivityViewController`, and its header
records why the obvious thing does not work:

> *"SwiftUI's `ShareLink` would do this in one line, but it needs its item at
> view construction time. The notes CSV does not exist until the button is
> pressed — writing it on every redraw of the settings screen would be absurd —
> so the file is produced first and the sheet is presented with it afterwards."*

And `DataControlsView` records the cost of learning it: *"the ShareLink shipped
in 183 rendered and did nothing at all when tapped."*

**332 is the second caller and wrote no new plumbing.** That is the whole point
of the note: the wrapper, the `ShareItem` identity wrapper, and the temporary-
file convention were all built for the notes CSV and all fitted unchanged.
§12.43's rule — *do not reimplement a rule, call it* — usually applies to
derivations. It applies to transports too.

### 12.79.2 The filename is the part that will still matter next year

`sub4-diagnostics-2026-08-09-p332.txt`. The day and the patch, in the name.

Every capture in this project's history so far has been a wall of text in a
chat log whose build has to be inferred from whatever the paste's first line
happened to say. A file that names its own build is a file that can be filed,
diffed against the next one, and read in six months without archaeology. The
transport was the request; the name is the thing worth having.

### 12.79.3 Temporary, and a failure that says so

The file goes to `NSTemporaryDirectory()` with `FileProtection.options`, the
same class as the stores it describes. Every number in it derives from data
still on the phone, so nothing is lost when iOS reclaims it — and a diagnostic
that accumulated dated copies inside the container would be a store nobody
declared, which is a thing this project has now been bitten by from the other
direction (§12.78).

The write can fail, and a button that silently does nothing is indistinguishable
from a button nobody wired up. One row appears on failure, naming the fallback
that still works. §12.15, and small enough that it would have been easy to skip.

## 12.80 Nine buttons are not a gate — patch 333

The last item on the pre-D7 list that is not a slice, and CLAUDE.md has stated
it in the same words since D6c closed: *"nine buttons that must each be pressed
is not a gate anybody can lean on."*

### 12.80.1 It was §12.57, nine times, and nobody had counted

313 moved shadow parity's result off `@State` onto its runner because pressing
Done discarded it, and the diagnostics paste then said *"Not compared since this
launch"* a minute after a comparison passed — true of the `@State` and false
about the world.

**Every one of the nine read-backs had the identical defect and none was
fixed.** `athleteTrip`, `authoredTrip`, `planTrip`, `planExtrasTrip`,
`weatherGearTrip`, `reviewTrip`, `roundTrip`, `detailTrip`, `recordingTrip` —
nine `@State` properties on `DatabaseHealthView`, nine results that existed only
while the sheet that produced them was open, and not one of them reachable from
the paste with a durable answer.

It stayed comfortable because the six cheap ones re-run on open, so the screen
always looked current. The three expensive ones are the evidence that matters —
674 activities, 674 details, ~1.5 million sample comparisons — and those needed
three presses and a memory.

**9 August removed the comfort.** A wipe destroyed every read-back result this
project had produced, and the rebuild means proving all nine again on new data.

### 12.80.2 What was built

- **`ReadBacks`** — the nine reads, moved out of the view unchanged. They now
  have two callers: the write-through's `onChange`, one at a time, and the
  roll-up, all nine at once. Two callers is what turns a private helper into a
  rule, and §12.43 says the rule gets one home.
- **`ReadBackRollUp`** — an `@Observable` singleton shaped exactly like
  `ShadowParity`: `.never / .ran([Line]) / .noDatabase / .readFailed`, a `runs`
  counter, `diagnosticLines`. The result outlives the sheet. The spinner does
  not, and stays in the view — a spinner that outlives its screen is a lie of a
  different kind.
- **One Section**, above the nine it summarises, for `verdictSection`'s reason:
  a verdict assembled by the reader from nine sections further down is a verdict
  that gets skimmed.

### 12.80.3 Three states, and the third is the point

`Line.couldNotLook` is a **sentence, not a bool**, and it is counted apart from
a line that looked and disagreed. The summary reads `1 of 3 agree · 1 differ ·
1 could not look` rather than `1 of 3`.

**"Eight of nine agree" said over a read that failed is the single most
expensive sentence this screen could produce**, because it is exactly what
somebody would quote as the reason it was safe to press D7. §12.15, and the
first instance where the sentence being wrong would license an irreversible
step rather than a wrong number.

The tests are aimed there rather than at the happy path:
`aLineThatCouldNotLookIsNotHealthyEvenWithNoDifferences`,
`anEmptyRunIsNotHealthy`, `oneBlindLineIsEnoughToFailTheWhole`.

### 12.80.4 The one exception, and why it is not a hole

`emptyIsCorrect` exists for a single read-back: the review trail holds nothing
on either side until 24 August 2026, and `ReviewRoundTrip`'s own
`lookedAtSomething` already says `totalCompared > 0 || bothSidesAreEmpty`. The
roll-up does not decide this — it reads the report's opinion and carries it. A
red row every day until the first real review is a row that stops being read,
which is §12.54.2 pointing the other way for once.

### 12.80.5 Three reports that predate the convention

`ActivityRoundTrip` (289), `DetailRoundTrip` (291) and `RecordingRoundTrip`
(294) carry `compared`, `missing`, `differences` and `excluded`; the six written
later carry `totalCompared`, `unexplained`, `lookedAtSomething` and
`isHealthy`. The extensions that give the older three the newer shape state what
their own sections have drawn red since the day they shipped — differences and
unexplained absences count, deliberate exclusions do not, and a failed read is
not a passed comparison.

**They are in `ReadBackRollUp.swift` rather than on the types, and that is a
compromise, recorded as one.** Putting them where they belong meant touching
three repository files to add four computed properties each, on a screen that
had cost three fix-ups in two days. They move the next time those files are
opened for a reason of their own.

### 12.80.6 And the control that was on the wrong screen

331 made the trace backlog readable and left the only thing that moves it in
Settings → Strava → Check now. Within the hour the athlete pressed **Import**
instead — which copies the app's stores INTO the database and never speaks to
Strava — and got `0 new` of everything, `Took 0.254 s`, and a queue that had not
moved in thirty minutes.

Nothing was broken. `enqueueAndDrain()` has exactly one caller,
`ActivityStore.sync()`, so the queue advances on a sync and on nothing else, and
no sync had run since the last relaunch.

**A number with no control beside it invites the nearest button.** 333 puts
*Fetch now* in the section that shows the backlog, calling the drain directly —
which also saves the activity-list request a full sync spends out of the same
hundred per fifteen minutes.

## 12.81 Two counters that could not say why they were zero — patch 333a

333 shipped in the morning and the device found both defects within the hour.
They are the same defect twice, in a patch whose stated purpose was to prevent
it, which is the part worth keeping.

### 12.81.1 `Still to fetch: 0` while 475 were still waiting

The paste at 12:10 read:

```
Traces still to fetch: 0
  queued, not yet reached: 0
  activities with no trace: 497 of 677
    unexplained: 475
```

`DetailStore.pending` is **not persisted**. It is rebuilt only by
`refreshQueue()`, which runs only from `enqueueAndDrain()`, which runs only at
the end of a sync. The app had been relaunched for the 333 build and no sync had
run since — so `pending` was empty because *nothing had asked*, and
`backfillRemaining` (which had been `pending.count` since the day it was
written) reported that as a finished backfill.

**Zero because it is done and zero because nobody has asked yet are the same
number.** §12.15, in the row 331 built to prevent exactly that, and restated in
333's own footer as *"it reaches zero when the backfill is done"*. The rule was
written down three times and applied to the wrong quantity each time.

#### What found it

`unexplained`, and nothing else could have. Five counters can each be right
while the set is missing a case; a residual cannot hide one. It went from 0 to
475 the moment the case appeared, and it is the only reason the wrong zero was
not read as good news. **An account beats a list**, on the first day it
mattered.

#### The fix

`backfillRemaining` and `traceCoverage`'s `queued` set are now **derived from
the predicate**, not from the array:

- `needsAnything(_:)` is the single definition of "still to fetch";
  `refreshQueue` builds the work list from it and `backfillRemaining` counts it.
  Two readers, one rule — §12.43.
- `traceCoverage` passes `Set(activities.filter(needsStreams).map(\.id))` rather
  than `Set(pending)`.

`unexplained` is now zero **by construction** rather than by luck: every
activity without a trace is refused, answered empty, under the threshold, or
waiting. It keeps its job in a narrower form — a non-zero residual from here on
means `needsStreams` and `TraceCoverageReport.classify` have drifted apart,
which is still worth one line.

It also un-breaks the button: `Fetch now` was `.disabled(backfillRemaining == 0)`
and therefore greyed out on a fresh launch with 475 outstanding.

### 12.81.2 "Could not look" said over a database that had been read perfectly

The same run reported:

```
Notes and commutes: 0 notes, 0 commute decisions.
```

in red, counted under *could not look*. That sentence is `AuthoredLoad.line` —
the load's own description of a database it read successfully and found empty.

333's adapter passed the report's `lookedAtSomething` where it needed the
load's `isTrustworthy`. **Those answer different questions.**
`lookedAtSomething` answers *did this compare anything*; `isTrustworthy` answers
*did the read happen*. Collapsing them turns every empty comparison into a
failed one.

Every load type carries `isTrustworthy` — all eight, plus
`RecordingRoundTrip.Report` — so the honest input was available the whole time
and the adapter simply reached for the wrong property.

#### And the same run overstated the other way

`Review trail: nothing on either side` was counted **inside** the eight that
agreed. Zero compared to zero agrees perfectly and proves nothing; folding it
into the agreement count is the mirror image of the first mistake.

### 12.81.3 Four states, not three

- **agreed** — compared something, no differences.
- **differed** — compared something, found differences.
- **could not look** — the read did not happen. Not zero differences; no answer.
- **nothing to compare** — the read happened, both sides were empty.

The summary prints all four terms **always**, including at zero, because a term
that disappears cannot be told from a term nobody wired in — and because "8 of
9 agree" hid two different facts on the first device run.

Only the middle two turn a line red. An empty comparison is dim: it is an
absence of evidence rather than evidence of a fault, and a permanently red row
is a row that stops being read.

**Two properties on the outcome, deliberately.** `isHealthy` is false on a
difference or a blind read. `provesSomething` additionally requires that every
read-back looked at something — and **that is the one D7's gate needs.** Today
the roll-up is healthy and proves nothing about notes, commutes or reviews,
because the wipe left all three empty on both sides.

### 12.81.4 The rule

**§12.81.4 — a count derived from a cache answers a question about the cache.**
`pending.count` answers "how long is the queue", not "how much is left".
`lookedAtSomething` answers "did this compare anything", not "did the read
happen". Both were correct properties, read for the wrong question, on a screen
whose entire purpose is to distinguish those two things.

The tests written at 333 all passed while both defects shipped, because they
tested the type and the defects were in the callers. 333a's additions state the
distinctions directly — `aReadThatSucceededAndFoundNothingIsNotBlind`,
`anEmptyComparisonIsNotAFaultAndIsNotProof` — but the device found them first,
and on this project it usually does.

## 12.82 One column, one contract — patch 334

`proposal.confidence` has had two contracts since patch 225. 334 ends that, and
the decision was Bruno's: **1–5 wins, the column narrows.**

### 12.82.1 What the three places said

| where | contract |
|---|---|
| `2026-08-06-proposal-inputs` | `CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 100))` |
| `ProposalView:121` | `i <= proposal.confidence` over `1...5` — five pips |
| `ReviewRehearsalTests:107` | `#expect(p.confidence >= 1 && p.confidence <= 5)` |
| `AuthoredImportTests`, `ReconcileTests`, `ReviewRepositoryTests` | wrote **70** |

Two of the four already believed 1–5. The column admitted everything, and a
CHECK that never refuses anything never complains — which is why this stood for
109 patches.

§12.71.4 recorded it at 327 and explicitly declined to decide, on the grounds
that it was not that patch's job. That was the right call and it is why there
was a test to invert today rather than a surprise.

### 12.82.2 Why 1–5

Nothing anywhere reads a percentage. Nothing draws one. The model is asked for
a level and the athlete is shown five pips. The 0–100 range was a column
written wider than its subject — the easy direction to get wrong, because the
cost of a too-wide constraint is invisible until something writes into the gap.

### 12.82.3 The rebuild, and the two things it does not do

SQLite cannot alter a CHECK, so `proposal` is rebuilt — create, copy, drop,
rename. Two deliberate choices:

**It copies rather than drops.** `Sub4Migrations+ZoneFloorZero` dropped
`hr_zone` outright because it held zero rows on the only device with that
schema, verified rather than assumed. `proposal`, `proposal_change` and
`proposal_watch` all read zero on this device today — the 9 August wipe took
the eleven rehearsal records — and this migration still copies, because a
migration runs on whatever database reaches it and *"it was empty on the
machine I wrote it on"* is a fact about that machine.

**`foreignKeyChecks: .deferred` is load-bearing.** `proposal_change` and
`proposal_watch` reference `proposal` with `onDelete: .cascade`. With foreign
keys enforced, `DROP TABLE proposal` performs an implicit delete and takes
every child row with it. Deferred checks disable enforcement for the body and
re-verify at the end, which is the whole reason GRDB offers the parameter.

### 12.82.4 An out-of-range value becomes NULL

70 out of 100 is not 4 out of 5. It is a value written under a contract that
has been retired, and the honest translation of *"I no longer know what this
meant"* is NULL — which the column has always permitted and which
`ReviewRoundTrip` already prints as `confidence range seen: —`.

Nulling silently would be worse than refusing, so it is stated in the
migration's header, here, and visibly: a proposal whose confidence went from 70
to nothing shows on the next read-back as a field difference, not as agreement.

### 12.82.5 The test grep is what made this a patch instead of a fix-up

§12.61.9 says grep `Sub4CoreTests/` before the zip when a type's shape changes.
A CHECK is a shape. The grep found **five write sites of `confidence: 70`
across three files**, every one of which would have refused at the door — and
one test, `theConfidenceRangeIsReported`, that **asserted the contradiction on
purpose**.

That test now inverts rather than breaking: it used to prove 70 round-trips and
that the disagreement was between the type and the column; it now proves the
column refuses 70. **That is what recording a contradiction in a test buys** —
the day somebody decides, a test changes and says so, instead of the change
going unnoticed. Fourth instance of the shape after 315, 317b and 327a, and the
first where the grep found the sites before the build rather than after.

### 12.82.6 What this does not settle

`content_revision` stays empty. The occupant CLAUDE.md guessed at — the plan's
content hash — **already exists**: `plan_version.contentHash`, written by
`Sub4Import+Plan.contentHash(of:)` and checked on every seed. Filling
`content_revision` with it would be two answers to one question.

The table's own comment names its real subject: per-**activity** hashes, so a
re-sync can skip an activity whose content is identical instead of rewriting it
and every row hanging off it. That is an optimisation, and the last full import
of 677 activities took **0.254 s**. Recorded as reserved and unoccupied;
revisit when the import is slow enough to be worth a cache.

## 12.83 The lineage, written at last — patch 335

`review_evidence_source` has held zero rows on every device since
`2026-08-03-initial`. Nothing wrote it: not the importer, not the review
runner, not the rehearsal. Its only INSERT in the entire project lived in
`DomainSchemaTests`.

ADR-0002 requires that every stored piece of review evidence with Strava
lineage can be found and removed while the verdict stands. **That is a query,
so lineage has to be queryable** — and it was not, which made the obligation
unmet by construction rather than by accident. §12.71.3 recorded it at 327 and
declined to fix it. 335 fixes it: one row per source in `ReviewLineage`, per
pack, written beside the evidence row it belongs to.

### 12.83.1 A property of the builder, not of the pack

This is the decision worth keeping, because the obvious alternative is wrong.

The obvious version derives the set per review: mark `authored` only if that
month actually had notes, `strava` only if an activity matched. It reads as
more precise and it **under-reports the exact case the purge exists for**.

*A pack that consulted Strava and found nothing is still derived from Strava.*
"You recorded no runs in this window" is a claim built out of Strava's data,
and deleting that data invalidates it exactly as surely as it invalidates a
distance. **Lineage is about what was CONSULTED, not what was found.**

It also kept the patch out of `ProposalStore.Record`. A per-instance set would
have to survive `proposals.json` — a persisted `Codable` whose synthesised
`init(from:)` does not use Swift default values, so a new non-optional field is
a decode failure on every existing record. The correct design and the safe one
turned out to be the same design, which is not always how it goes.

### 12.83.2 Frozen literals, and the second reason for them

`ReviewLineage.sourceIDs` is `["authored", "bundled", "strava"]` — string
literals, not `DataSource` cases.

`Sub4Migrations` already argues the first reason in its own header: *"deriving
them from the enums looked like the drift-proof choice and is the opposite"*,
with the agreement asserted by test instead. The second reason is isolation.
`DataSource` takes the module's MainActor default; `Sub4Import` is
`nonisolated` end to end. Reaching `rawValue` across that boundary is the trap
CLAUDE.md has recorded five times, and there was no reason to make it a sixth.

`ReviewLineageVocabularyTests` is the guard: every id names a real
`DataSource`, the list is sorted and distinct, and it claims no source the
builder does not read.

**Not `ReviewLineageTests` — that name was taken**, by the suite in
`DomainSchemaTests` that exercises ADR-0002's purge as the query it will
actually be: delete the evidence with Strava lineage, leave the verdict
standing. The pair is the whole obligation — that one proves the purge works on
rows, this one proves the rows the importer writes are the right ones.

The collision cost a fix-up and it is §12.61.9 half-applied. 335 grepped
`Sub4CoreTests/` for the strings and the fields it was changing, and not for
the type name it was about to declare. **A fourth shape belongs on that list:
a function's arity, an array's length, a printed string's content — and a
type's name.**

### 12.83.3 What it deliberately does not claim

Not `appleHealth`. Not `weatherProvider`. Not `device`. `ReviewBuilder.build`
binds four stores — `PlanStore`, `Matcher`, `DetailStore`, `NotesStore` — and
reads no Health, weather or device data.

**A lineage that over-reports is worse than one that is absent**, because
absence is visible and a wrong claim is not: it would make the purge delete
evidence it has no business touching. The list grows when the builder does, and
only then.

Nothing can enforce that mechanically — no test can watch what a function
reads. What `ReviewLineageTests` can do is make the omission cost a red test
rather than a lineage row that is quietly too small, and the Database screen
prints the ids rather than a count so a reader can tell three-because-three-
sources from three-by-luck.

### 12.83.4 The third inverted test in one day

`nothingWritesEvidenceLineage` asserted the absence **on purpose** — zero rows,
plus the exact diagnostic wording, so that a bare 0 could not be mistaken for
agreement. It is now `theEvidenceLineageIsWritten`.

That is the third today, after 327b's `noPlanMeansNoResolution` and 334's
`theConfidenceRangeIsReported`. All three were written by the patch that found
the problem and declined to solve it, and all three changed on the day somebody
decided — which is the entire argument for recording a finding as a test rather
than as a comment. A comment would have been read and nodded at.

`aMissingLineageRowIsADifference` is the negative control the write needed: the
rows are deleted behind the reader's back and the report has to notice. A
comparison that cannot fail is not a comparison.

### 12.83.5 It rolls into the total

`evidenceSourcesCompared` is added to `totalCompared`. A denominator that does
not move when a comparison is added is a place for that comparison to hide —
the lineage rows contribute differences to `unexplained`, so they contribute to
the count those differences are measured against. `ReviewRepositoryTests`'
exact-sum assertion went from `1 + 1 + 1 + 3 + 2` to `+ 3` in the same edit.

### 12.83.6 And the screen still said the old thing — 335b

335 wrote the writer and left the sentence describing its absence. The Database
screen's review section read:

```
Lineage rows    0 — nothing writes this table
```

True when it was written, false the moment 335 shipped. So did the section's
footer: *"one finding that is not approved: review_evidence_source is written
by nothing"*.

**§12.15 pointing the other way.** The rule is usually that a zero must say why
it is zero; this is a zero whose explanation was confident and wrong, which is
worse than a bare one — a bare zero invites a question, and a wrong sentence
closes it.

**Three zeros, and only the middle one is a fault:**

| state | reads | colour |
|---|---|---|
| no review stored | `0 — no review stored yet` | dim — correct until 24 August |
| reviews stored, no lineage | `0 — but N reviews are stored` | **red** — the writer did not run |
| lineage present | `N — one per source in ReviewLineage` | dim |

It was found while writing the manual test campaign, by asking where on the
screen the number appears. **A campaign that names the row it expects is a
campaign that reads the row**, which is the second time this week that writing
down what a screen should say has found what it does say.

### 12.83.7 What is still not proved

The writer has never run against a real review and cannot before **24 August
2026**. Until then the only evidence is the rehearsal path and these tests.
What 335 changes is that when the first real review lands, the lineage lands
with it — instead of the sixth review table being empty for a second month and
the purge staying inoperable into Phase 4A.

## 12.84 Two zeros the paste could not show — patch 336

Both found while validating 335b, both the same rule, and both in the artefact
that gets read later by somebody who cannot see the screen.

### 12.84.1 The paste hid every empty table

`DatabaseHealthView`'s diagnostics said:

```
Tables: 51, imported rows: 99760, total: 99766
  account: 1
  activity: 677
  … 36 more
```

Thirty-eight lines under a header claiming fifty-one, because the loop read
`for row in counts where row.rows > 0`.

**The thirteen it hid are the tables this project has spent a week arguing
about.** `review_evidence_source`, `content_revision`, `match_decision`,
`user_note`, `correction`, `proposal`, `review` — every one of them a table
whose emptiness is the finding. A paste discussing whether the lineage is
written, taken on a device where the lineage table is empty, did not mention
that the table exists.

§12.54.2, in the place it costs most. The screen has always drawn all 51; the
paste now agrees with it. `tableCounts()` was never the problem — it returns
every table and always has.

### 12.84.2 The snapshot's absences had a floor nobody could see

```
Declared but not present    5
```

On 9 August that was three stores the wipe took — `notes.json`,
`commutes.json`, `proposals.json` — and **two file formats retired several
hundred patches ago**. `details.json` and `streams.json` are the pre-split
monoliths, replaced by the `details/` and `streams/` directories, and
`AppSupportItem` has a `.legacyFile` case for exactly this reason.

**They cannot exist on an install that never held the pre-split format.** So
the row has a floor of two: a perfectly healthy phone reports them absent for
ever, and "5 not present" reads as five losses when it is three.

Split into two sub-rows, both unconditional:

```
Declared but not present        5
  retired formats               2
  stores not written            3
```

`missingCount` is unchanged — `LegacySnapshotTests` asserts it and the paste
header prints it, and the total was never wrong. What was missing is the
breakdown that makes it readable. §12.54.3: a count beside its own denominator
is evidence; a count with no account under it is a number somebody has to come
and ask about.

### 12.84.3 Derived from the vocabulary, not stored on the row

`SnapshotEntry` is `Codable` and written to `manifest.json`. A new field would
be absent from every manifest already on disk — including `2026-08-09-083914`,
which is the only protected copy this project has ever taken.

`retiredFormatNames` is instead a pure function of `LegacyStore`: the declared
names whose `item` is `.legacyFile`. It reads correctly on a manifest written
before this patch existed, and it follows the vocabulary if a third format is
ever retired. §12.43, applied to a fact rather than a rule.

### 12.84.4 Why this is the patch before D7 rather than after it

Neither defect changes a number. Both change what a number **means to a reader
who was not there**, and D7 is the rung where somebody reads a paste and
decides whether to flip `migrationFailureBlocksTheApp` to `true`.

A paste that omits the empty tables and a snapshot row that overstates its
losses are both survivable while the person reading them is the person who
generated them. They stop being survivable the moment the paste is the evidence.

## 12.102 The authored hydration machinery — patch 357, D7 slice B2

### 12.102.1 Machinery and flip, separated on purpose for the second time

344 built B1's bootstrap and planner. 346 flipped it and found four failures —
a pinned gap name, an invariant 346 deliberately ended, and `PlanStore.shared`
changing meaning under sixteen call sites in seven files. **They were
attributable because the two were separate patches.**

357 is 344's half for B2. `DatabaseBootstrap` learns two families, the three
authored stores learn `hydrate(from:)` and `servedFrom`, and the planner learns
to carry the payloads. Nothing hydrates. 358 is the flip.

For that to be expressible at all, "which slice is under test" and "which
stores are fed from the database" had to stop being the same value. They were
identical while there was one slice; `PersistenceMode.hydratedFamilies` is the
second one, and **it is the only line 358 changes.**

### 12.102.2 Two families, not one and not three

`AuthoredLoad` (notes and commutes) and `MatchDecisionLoad` are two reads that
can fail separately, which is `fieldCount`'s rule — the plan and its trimmings
are two entries for exactly that reason. They feed three stores, which is a
different question: `hydratableAuthored` hands over notes and commutes together
for `hydratablePlan`'s reason, because they come out of one read and half of
them would leave one screen showing database values beside another showing file
values with nothing saying which.

Both loads gained `wasReadCleanly` and `holdsContent`. §12.92 is the record of
why `isTrustworthy` alone could not carry it.

### 12.102.3 An empty authored family is not hydrated — the decision, 14 August 2026

`canHydrate` means *the database has been imported into*. The plan, its
trimmings and the athlete always hold content after an import, so their
emptiness is diagnostic. **Zero notes is not.** A device where the athlete has
written nothing reads cleanly and holds nothing for ever, and letting that block
the plan's hydration would make a legitimate state look like a fresh install.
So the two authored families are excluded from `canHydrate`.

They are also not hydrated when empty, and that is the sharper half. A database
holding no notes while `notes.json` holds one does not prove the athlete wrote
none — it can equally mean the write-through has not caught up. Hydrating there
would blank the only copy, and §12.8.1 already priced that: the 4 August
reinstall took every past review and there was nowhere to get them back from.

**The cost is named rather than hidden.** With zero match decisions on this
device, that family will not hydrate at all, and 358 will prove nothing about it
until one is recorded. `emptyAuthoredFamilies` is a separate line from
`firstEmpty` because they answer separate questions — one is "has this been
imported into", where empty is a finding; the other is "which stores keep their
files this launch", where empty is ordinary and permanent.

### 12.102.4 Nil twice, for two reasons, and the paste tells them apart

`Instruction.hydrate` carries the authored payloads as optionals. That is not a
weakening of §12.90's all-or-nothing rule — the plan and the athlete are still
whole or absent. The optionals are nil for two distinct legitimate reasons:

- the build does not hydrate that family yet, or
- the family read cleanly and holds nothing.

The planner asks those separately rather than as one combined condition,
because a single nil would collapse "not yet" and "nothing stored" — and §12.15
is the record of what happens when a diagnostic cannot say why it has no
answer.

`HydrationOutcome.hydrated` now grows its sentence with what actually moved
rather than describing what the code is capable of. Today it still says "the
plan, its trimmings, the athlete and the constants", unchanged, which is how
the device proves 357 flipped nothing.

### 12.102.5 Hydration does not write, and the script refuses it

`PlanStore.hydrate`'s comment applies to all three new ones word for word:
under a slice under test the file is the legacy side's ONLY copy, and saving
database-derived values over it would destroy the independent second opinion
356 spent a patch giving the read-back. `apply-357.py` walks each `hydrate`
body and fails on `save()`, `StoreWrite` or `defaults.set`.

### 12.102.6 What 358 does

Adds `.authored` and `.decisions` to `hydratedFamilies`, adds the
`HydratedStores` entries for whichever families actually hydrate — `notes` and
`corrections` in the verifier, taking 19 independent to 17 — and moves
`sliceUnderTest` to B2. Nothing else.

## 12.101 The authored read-back keeps its own read — patch 356, D7 slice B2

### 12.101.1 343, again, on three sources instead of one

`ReadBacks.authored` compared the database against `NotesStore.shared`,
`CommuteStore.shared` and `Matcher.shared`. B2 hydrates all three FROM the
database, and at that moment the comparison is the database against itself:
three counts guaranteed to agree, on the read-back that sits inside D7's entry
gate. §12.69, at the worst possible moment.

§12.91.2 settled the rule on 10 August — **the store serves the database; the
read-back keeps its own legacy read** — and §12.91.1 named this exact slice:
*"B2 does it to `AuthoredRoundTrip`."* 343 did it for the plan by decoding the
bundle. This does it for two JSON files and a `UserDefaults` blob.

**Today it changes no number, and that is what makes it checkable.** The stores
ARE those sources until 357 hydrates them, so every count must come back
unchanged. A patch that moved a number here would be a patch that got the
independent read wrong.

### 12.101.2 Each store's own loader, not a second decoder

`NotesStore(directory:)`, `CommuteStore(directory:)` and `Matcher(defaults:)`
already exist and already run each store's own `load`. `ReadBacks.authoredSources`
constructs one of each. §12.43 — call the rule rather than reimplement it — and
here the consequence is concrete: a second decoder would be a second opinion
about what `notes.json` contains, and the two would drift the first time either
changed. `StoreRead.decode` appearing in `ReadBacks` is a guard failure.

All three initialisers were written for tests and said so in their docs. They
have a production caller now and the docs say that instead. **All three still
skip `StoreReadJournal`, and 273's reason has quietly become a second reason:**
it kept a test store from leaking into the journal; the same line now keeps the
READ-BACK's own read out of a journal whose job is to describe the APP's stores.
`NotesStore(directory:)` still skips `migrateIfNeeded` too — the read-back wants
the file as it is on disk, not as a migration would leave it.

The container comes from `DataLifecycle.container`. There are already nine
copies of the `applicationSupportDirectory` incantation in this project and a
tenth was not written.

### 12.101.3 Unreachable is not empty

`directoryFound` exists because Application Support being unreachable and three
stores holding nothing produce identical counts. §12.15: one says the athlete
has written nothing, the other says the app cannot tell. `.absent` is a clean
read — a fresh install has no `notes.json` — and `.unreadable` is not, which is
`StoreLoad`'s own rule applied to the aggregate.

### 12.101.4 The report says where its own side came from

`Report.appSideCameFrom` defaults to `"the app's stores"` **on purpose**. Any
caller not updated announces itself in the paste rather than hiding, and after
357 that string on this line IS the defect. It prints first, under the heading,
because it is what every count below it means — pinned by test so a later edit
cannot bury it.

### 12.101.5 What is guarded rather than tested

The defect this patch removes is a negative: the read-back must not ask the
three singletons. No assertion can see that today, because the singletons and
the files hold the same values — which is the same sentence as §12.101.1's
"changes no number". So `apply-356.py` names all three and fails the patch if
any reappears.

**All three, not one, and 346a is why.** Its sweep for the literal
`PlanStore.shared` converted six occurrences and missed five sitting inside a
default argument; the tests passed for four patches because two plans happened
to agree. A guard that named only `NotesStore.shared` would be that mistake
with fewer letters.

### 12.101.6 What 356 deliberately does not do

No store is hydrated. `sliceUnderTest` stays at B1, `HydratedStores` stays at
one entry, and both are checked. 357 hydrates `NotesStore`, `CommuteStore` and
`Matcher`, adds their entries — taking the verifier's independent count from 19
to 17 — and flips the slice.

## 12.100 The table that had no reader — patch 355, D7 slice B2

### 12.100.1 What B2's groundwork put in bold

`D7-ACTIVATION-GROUNDWORK.md` §7 names B2's new work: **`match_decision` and
`rejection` have no reader**. `Sub4Import+Authored` has written
`match_decision` since 274 and the only thing that has ever read it back is the
importer's own dedup `SELECT`.

The verifier's `match decisions: expected 0, found 0` is the whole of the
coverage, and it agrees because **both sides are empty** — the shape 354 spent
a patch making visible one level up. Zero compared to zero agrees perfectly.

### 12.100.2 The left join, and why an inner one loses data silently

`match_decision.activityID` is nullable, and nil is not an absence: it is the
athlete saying *nothing satisfied this session*. The old `[String: String]` in
`UserDefaults` had to spell that `""`; patch 272 gave it a real nil, and
`MatchDecision.activityId`'s own doc says the nullable column exists for it.

`AuthoredRepository.commuteSQL` joins `activity_alias` INNER, correctly — a
commute correction always names an activity. Copying that shape here would drop
every explicitly-nothing decision, and the comparison would then report them as
`decisionsOnlyInApp`, which reads as missing data rather than as a reader that
cannot see half its table. The join is LEFT, the apply script checks it, and
`theExplicitlyNothingDecisionSurvivesTheRead` is the test that would catch it.

A non-null `activityID` that resolves through no alias is a different thing and
is counted as `skipped` — §12.89's rule, and here it has a real case.

### 12.100.3 One family, one read-back row

Match decisions join the authored read-back rather than becoming a tenth entry
in the roll-up. The roll-up's nine rows are load-bearing in D7's entry gate and
"9 of 9" is written down in several places; a tenth would change what that
sentence means in all of them. They are authored data, on the same screen,
refreshed by the same write-through.

`compare` is left alone and `compareDecisions` fills the same `Report` through
`inout`. Two more arguments on `compare` would have rewritten seven existing
test call sites and changed nothing they assert — and B2's hydration patch has
to touch that signature anyway, which is where the two fold into one.

`decisionsWereRead` exists because §12.15 applies here exactly: a report nobody
gave the decisions to prints the same zeros as one where both sides were empty.
The paste says `NO — nothing was compared` in capitals for the first.

### 12.100.4 `dateIsKnown` has no column, and that is a decision

The flag says whether `decided` is when the athlete decided or when a dateless
legacy record was migrated. It was a concern of patch 272's migration rather
than a property of the decision, and the schema never carried it. The reader
returns `true` — every row in the table was written from a record with a real
date — and the comparison does not walk the field.

It is recorded in `approvedForDecisions`, a SECOND list rather than a third
entry in `approved`. That list is about `user_note`, its count is printed by
name in the paste and pinned by test; growing it would have moved a number that
means something else.

### 12.100.5 Rejections are B8, and the groundwork is amended

That document contradicted itself. §1's call-site ledger:

> rejection receipts | `ActivityStore.receipts` | `UserDefaults` data blob |
> `RejectionRepository` — does not exist | **B8**

§7's slice table said B2 covers "notes, commutes, match decisions,
**rejections**".

§1 is the more considered entry — it names the actual reader, the actual
storage and the missing type — and rejection receipts are the same family as
the sync cursor and the work queue, which are already B8. They are read by
`ActivityStore`, not by anything authored. §7 is corrected in place and the
amendment is dated and signed to the patch, rather than the work being moved to
match the looser sentence.

### 12.100.6 What 355 deliberately does not do

No store is hydrated. `PersistenceMode.sliceUnderTest` stays at B1 and
`HydratedStores` stays at one entry — both are checked by the apply script,
because a patch that moved either would be doing B2's hydration by accident.

This is B1's order repeated: 343 gave the read-back an independent side, 344
built the machinery, 346 flipped it. The comparison has to exist and pass
before anything depends on it.

## 12.99 A check that reads a store the database feeds — patch 354

### 12.99.1 The erosion, and why it was silent

`SemanticVerifier` compares the database against the app's stores. Twenty
comparisons, and `verified` is the state D7's activation reads — §12.16 wrote
it, §12.88 made it survive the sheet closing.

Every B-slice moves one more store onto the database. The moment it does, the
comparison that reads that store stops being evidence and becomes the database
agreeing with itself. §12.69: **a check that cannot fail has not been tested.**

It has already happened once. B1 hydrated `AthleteStore.hrZones` from
`hr_zone`, so `heart-rate zones [hr_zone]: expected 5, found 5` has been the
database against itself since 346. Nineteen of twenty are still real. Nothing
anywhere said so, in the report, on the screen, or in the ledger note — and
"20 comparisons, all agreed" is a sentence that gets more misleading with every
slice while staying literally true.

At B9 the number reaches **zero**: every store fed by the database, twenty
green rows, nothing that could have failed. On the one control the activation
turns on. That is the state this patch makes unreachable.

### 12.99.2 The list is the slice's, not the verifier's

`HydratedStores.all` names the comparison, the store field and the slice that
moved it. It lives beside `PersistenceMode.sliceUnderTest` because that is the
constant a slice already edits — the same hand, on the same file, in the same
patch.

**The forgotten-entry direction cannot be caught.** A slice that hydrates a
store and does not add a line here leaves a comparison looking independent when
it is not, and no amount of code can notice. The list is a declaration, and a
declaration is only as good as the discipline behind it.

**The other direction is caught loudly.** The list joins to the checks BY NAME,
so a rename on one side produces an entry matching nothing —
`unmatchedHydratedEntries` — and that WITHHOLDS the whole report rather than
quietly moving a self-referential check back into the evidence column. §12.15:
a diagnostic that cannot say why it has no answer will be read as having one.

### 12.99.3 What `verified` may be granted on

`SemanticVerifier.record` gated on `report.passed`. It now gates on
`isTrustworthyEvidence`, which is three ANDed facts with three distinct
failures:

- every comparison agreed,
- **at least one of them was capable of disagreeing**,
- and the list that decides which is which still lines up with the checks.

The middle one is the patch. It is the sixth time this project has had to make
a check able to fail before believing it, and the first time the erosion was
gradual rather than present on day one — which is what made it hard to see.

`VerificationResult.Ledger` gains a sixth case, `noIndependentEvidence`, rather
than reusing `reportDidNotPass`. The report DID pass; every comparison agreed.
Telling somebody it failed would send them looking for a fault in their data
instead of at the verifier.

### 12.99.4 On the screen, two rows swapped and none added

§12.76 — this screen's budget is depth, and a `@ViewBuilder` block is built
pairwise, so swapping a row is free and adding one is not. `Compared` reads
`20 · 19 independent` and turns red at zero; a self-referential check's label
says so. Both were rows that already existed.

The paste prints the counts, the verdict and the reason unconditionally, above
the checks, because it is what the twenty numbers below it mean.

### 12.99.5 What is tested, and what is guarded instead

`record`'s guard is not tested. The positive case needs a ledger row; the
negative case would pass whether the guard existed or not, because
`verifyPending` returns false for a run id that is not there. §12.69 one level
up — so the line is held by `apply-354.py`, which fails the patch if it is
relaxed back to `passed`.

`everyDeclaredEntryNamesARealComparison` runs the real verifier over an empty
database and requires every declared entry to match a check that exists. That
is the test that fires at B5 if the new entry has a typo in it.

## 12.98 A rehearsal is not a review — patch 353

### 12.98.1 The defect, and the date it was going to land on

`ReviewDue.state()` decided whether the monthly-review banner appears, and it
read the newest stored record with no filter:

```swift
guard let last = ProposalStore.shared.newestFirst.first?.ranAt else {
    return .due("Four plan weeks are finished and no review has been run.")
}
```

Six rehearsal records, written on 9 August 2026 by `ReviewRehearsal` (§12.8.3),
are still on the device. Today this is invisible: two of the four plan weeks
the gate needs have finished, so it returns `.tooEarly` and never reaches the
guard. **On Monday 24 August the fourth week finishes**, the guard finds
`ranAt: 2026-08-09`, and returns `.recent(nextDue: 6 September)`.

The banner does not appear. Nothing says why. The first real review — the one
this whole slice exists for, the one §12.8.2 wrote a checklist for — is pushed
out twenty-eight days by a record that announces in its own `reasoning` field
that it would do exactly this.

That field also names the fix: *delete the record before the first real review
runs*. Which is a fix for the symptom. **A gate that is only correct while
somebody remembers to clean up is not a gate**, and the cleanup was already
eleven days from its deadline and had been outstanding since 9 August.

### 12.98.2 The marker was a literal nothing read

`ProposalStore.add(model:)`'s doc, written at 269, already made the right
argument:

> A PARAMETER RATHER THAN A FLAG ON `Record`. `model` is already a column on
> `review`, so a rehearsal announces itself in the database as well as on
> screen, and the first real record will be distinguishable from it by
> something more reliable than its date.

Every word of that is true and nothing acted on it. `model: "rehearsal"` was
written in one place and read in none, which made it documentation rather than
a marker. From 353 it is `ReviewRehearsal.modelName`, the writer and the reader
share it, and `ProposalStore.Record.isRehearsal` is the one place the string is
interpreted — no caller spells the word.

The constant is **pinned by test to the value already in `proposals.json`**
rather than chosen. Six records on disk carry that exact string; changing the
constant would make them stop being rehearsals to the gate, to the banner and
to the paste, while remaining rehearsals in fact. `apply-353.py` refuses a
second literal anywhere in the Swift sources, comments excepted.

### 12.98.3 The rule is a pure function, and 350a is why

`state()` reads two main-actor singletons — `PlanStore.shared` for the
finished-week count and `ProposalStore.shared` for the last run. Neither is
injectable and both are real in the test host: the plan store is hydrated from
the simulator's database (§12.57, and 346a paid to learn it), the proposal
store is a file in the host's container. A test driving `state()` would assert
about whatever those happened to hold, and a test that WROTE a record to fix
that would leave a row every other suite's `state()` then counts.

So the rule moved into `newestReal(in:)`, `rehearsals(in:)`,
`rehearsalWarning(in:today:)` and `rehearsalLine(in:)`, which take their
records as an argument. **With no default.** §12.95.4 is fresh enough to quote:
a default argument is a call site carrying a value the caller never writes, so
no search for that value finds it — `WorkoutParser.coverage(_ store: PlanStore
= .shared)` cost patch 350a exactly that way. `records:` here would have been
the same shape on the same kind of singleton. The apply script fails if one
appears.

### 12.98.4 The negative control, and what it is for

`theUnfilteredReadIsWhatTheDefectWas` asserts that the OLD expression — the
plain newest record — returns the rehearsal on the same array the new one
resolves correctly. Without it every other test in the file would pass against
a `newestReal` that filtered nothing, because six of the seven cases would
still come out right.

§12.69, and the fifth negative control in this project written after the
absence of one cost a patch.

### 12.98.5 Conditional on a screen, unconditional in the paste

The Today banner appears only while records are stored. That is a deliberate
exception to §12.54.2, and `ReviewDue`'s own header is the argument: the review
card used to be a permanent row on Progress reading "Available once the first
plan week has ended", and *a row that is present, tappable and inert trains you
to scroll past the place where the real thing will eventually appear*. A card
reading "0 rehearsals stored" every morning for thirty-four weeks would be that
row again.

The diagnostics line is unconditional, because there "0 stored" is the sentence
that proves they went — and it is the number that decides whether `review: 6`
in the table census is six reviews or six rehearsals. Action items are
conditional; evidence is not.

### 12.98.6 What is still owed

The six records themselves. `ReviewDue` no longer counts them, so the banner is
right either way — but `review`, `review_evidence`, `proposal`,
`proposal_change` and `proposal_watch` still hold their rows, the read-back
still compares six of them, and a person reading the history six months from
now still sees six windows that look like months of work. They are deleted from
Progress, one at a time, behind the confirmation that says a review cannot be
produced again. **Before Monday 24 August 2026.**

## 12.97 Four versions, three plans, one duplicate — patch 352

### 12.97.1 The question, and why the arithmetic was not an answer

13 August, the athlete, reading a diagnostics paste: *"we made some changes but
it seems that we have exact the double of workouts."*

`plan_session: 1043`, against a plan of 260. `plan_week: 148`, `plan_week_stat:
736`, `plan_session_block: 2536`, `plan_exercise: 80` — every one of those an
exact 4x, which is what makes the reading "four copies" so easy to reach.

It is not four copies, and two numbers say so before anything is read: 1043 is
not divisible by four, and `plan_session_detail: 326` is 82 + 82 + 81 + 81. The
sum that closes is **261 + 261 + 261 + 260**, and against this document each
term has a name:

| version | sessions | breakdowns | what it is |
|---|---|---|---|
| 1 | 261 | 82 | the bundle as 329a left it |
| 2 | 261 | 82 | 346's ordering artefact — §12.93.3 |
| 3 | 261 | 81 | patch 349, the calendar revision — §12.94 |
| 4 | 260 | 81 | patch 351, active — §12.95 and §12.96 |

The uid superset checks too. The device reports 271 session uids known to the
database against 260 in the active plan; the working tree's `plan.json` diff
against the last commit removes ten uids, and §12.96.3's Tuesday rename
accounts for an eleventh that only version 3 ever held.

**So the answer was already in this file, and that is precisely the problem.**
Every step above is a reconstruction. Nothing in the app had read a
non-active version since they started being written, and the first time
anything did was going to be a DELETE. A count that divides by four is not
evidence that four things are the same, and a count that does not divide by
four says nothing about WHICH of them differ. §12.15's argument, applied one
level up: a diagnostic that cannot say why it has no answer will be read as
having one — and a document that can only be checked by the person who wrote it
is the same failure wearing better prose.

### 12.97.2 `contentHash` is the wrong instrument, and §12.93.3 is why

`plan_version.contentHash` is SHA-256 over the decoded `Plan` re-encoded with
sorted keys — §12.11.3. `.sortedKeys` sorts object KEYS and does not sort
ARRAYS. §12.93.3 is the patch where that mattered: the store was hydrated from
rows read `ORDER BY uid`, `plan.json` is in the plan's own order, and the same
261 sessions hashed differently and minted version 2.

That hash answers *"have these bytes arrived in this order before"*, which is
the right question for an importer and the wrong one for a prune. Two versions
with different hashes can hold identical training — the device holds exactly
that pair — and no amount of comparing hashes will show it.

`PlanVersionCensus.fingerprint` is taken over the STORED ROWS instead: every
column that is not a row identity, foreign keys replaced by the uid they point
at, **the lines sorted before hashing**. Sorted is the whole of it. A
fingerprint with §12.93.3's weakness would call four twins four different plans
— confidently wrong in the direction of not deleting, which is the safe
direction and therefore the one nobody would notice. `apply-352.py` guards the
`.sorted()`.

### 12.97.3 What the fingerprint covers, said out loud

Weeks, week stats, sessions, breakdowns, blocks and exercises. Not the ten
fuelling and warm-up tables.

That is a real hole and it is small: three products, seven targets, a five-step
ladder, a race-day schema and a nine-step warm-up, none of which any plan
revision in this project has touched, all of which the extras read-back
compares for the active version on every launch. It is stated in the paste
itself — `fingerprint covers:` is a printed line, not a comment — because a
verdict whose scope the reader has to guess is a verdict they will
over-trust. §12.15 again.

### 12.97.4 The rule a delete follows

**A version may be deleted only when another stored version holds identical
training.** Not "is inactive", not "is old", not "looks unused".

That rule makes the dangerous case impossible rather than unlikely. §12.7
refuses to make `user_note.planSessionUID` and `proposal_change.planSessionUID`
foreign keys — deliberately, so that a plan revision cannot delete thirteen
months of writing — and the price of that decision is that nothing in the
schema would stop this from orphaning a reference either. If every uid the
doomed version holds survives in its twin, there is nothing to orphan. That is
why the census prints, per version, *session uids no other version holds* and
*of those, named by a proposal_change*: the two numbers a delete is decided on,
and both are zero for a twin by construction.

`user_note.planVersionID` is `ON DELETE SET NULL`, so a note written against
the removed version keeps its text and loses only its pointer. The content
tables cascade from `plan_version`, which is §12.11's decision and the reason
the delete is one statement.

Three refusals stand between the button and the rows — no twins, the active
version selected, a uid that would be lost — and the third cannot fire while
the fingerprint covers `plan_session`. It stays, and is exercised directly on
hand-built values, because what it protects against is not a bug in the rule
but a NARROWING OF THE FINGERPRINT: the day somebody drops sessions from the
covered set to make the census cheaper, two versions with different training
become twins and that line is what refuses to delete one of them. §12.69, and
the honest way to satisfy it — a pure function tested on values a database
cannot produce, rather than a test theatre-ing a state that cannot exist.

### 12.97.5 The census checks itself against the reader

`PlanVersionCensus` writes its own reads of tables `PlanRepository` also reads.
Not its own SQL — §12.43, the five queries stopped being `private` and are
called — but its own traversal, its own re-keying, its own counting. Two pieces
of code, one set of tables.

So the paste's second line is `the census and the read-back agree`, and it
carries the two numbers when they do not. If this file is wrong about what a
version contains, its verdict is worthless and the delete it licenses is
dangerous; the disagreement is a printed line and a test rather than an
assumption. §12.92's lesson in a different shape — the thing to distrust is the
part of a system that has never been contradicted by anything.

### 12.97.6 Not in the roll-up, on purpose

`ReadBackRollUp` carries nine rows and each is a comparison against a store.
The census compares versions against each other; there is no independent side
and its "unexplained differences" could only ever be zero. A tenth green row
that cannot go red is §12.69 in the one place on this screen where a person
looks for reassurance. It is its own section, with its own heading.

### 12.97.7 What moved together

`PlanVersionCensus.swift` and its tests (new), `PlanRepository`'s five query
constants and `blockSQL`'s session uid, `ReadBacks.planVersions`,
`DatabaseHealthView` — two state properties, two fills, one section, one paste
block. AppVersion 352.

**Nine patches were uncommitted while this was written.** A zero-byte
`.git/index.lock`, left by something that died on 10 August, had been failing
every `git add` and `git commit` since 344 while `git status` and `git log`
kept answering normally. Seven commits reported as done had errored. Recorded
here because it is the same shape as everything else in this section: a
read-only path that works is not evidence that the write path does.

## 12.96 A rest card that argued with the session beside it — patch 351

### 12.96.1 What was asked, and the thing it fixed on the way

*"Delete the rest on 30/8 and add a rest on 1/9, so it cuts into the large run
block."*

Sunday 30 August held **two** cards: `Walk / rest` and `Strength B · core`. Both
had been correct in isolation since 349 and they contradicted each other on the
screen — a rest day carrying a training session. Deleting the rest card leaves
the bodyweight circuit as the day's whole content, which is what the day
actually is.

Tuesday 1 September's steady run becomes the rest. The Berlin run days were
Mon–Tue–Wed–Thu, four straight; they are now **Mon | Wed–Thu**, which is what
"cut into the run block" asks for.

### 12.96.2 The count moves down, and that is the first time

`plan.json` is **278,546 bytes, 260 sessions**, SHA-256 `4dfb8b1f…`. One session
is deleted outright (the Sunday rest) and one changes discipline in place
(Tuesday: run → rest), so the total falls by one. Every previous plan revision
in this project added or held: 329a took it 260 → 261, 349 held it at 261 while
moving fourteen sessions. **`PlanSeedTests.Frozen.sessions` has never decreased
before**, and a reader who assumes that constant only grows will misread the
diff.

Run sessions fall 105 → 104 and parsed 94 → 93, `refused` untouched at 11 — the
eleven are the by-feel pointers and the field test, and the session that left
was a fully parsed one.

### 12.96.3 A uid changed without its session changing — and `seq` is why

`wk-05-sun-strength-b-core-1` is now `wk-05-sun-strength-b-core`.

Nothing about that session moved. Its uid carries the `seq` the extractor
assigns from position within the day, and the `-1` suffix existed only because
a rest card sat above it. Delete the neighbour and the survivor becomes `seq`
0, and `extract_plan.py` appends the suffix only when `seq` is non-zero.

**So a session's identity here depends on its SIBLINGS, not only on itself.**
That is worth writing down because §12.7 already refuses to make
`user_note.planSessionUID` a foreign key, and this is a second, quieter way the
reference can dangle: not a renumbered week, but a deleted card two lines
above. No note, decision or review names it today — the week is in the future —
and the prior `plan_version` still holds the old uid, which is the mechanism
§12.11 exists for. `STRENGTH_DATA` is keyed `"Day|Title"` and is unaffected.

### 12.96.4 What moved together

`PlanSeedTests.Frozen` (bytes, sha, sessions), `PlanCoverageTests.Expected`
(104 / 93 / 11) with the control's comment re-stated at 104 versus the
database's 103, §9.2 above, the HTML week cards and the section-05 phase strip,
`tools/README.md` and `docs/context/marathon-plan.md`. AppVersion 351 —
a numbered patch, so `revision` returns to nil.

## 12.95 Fifteen seconds, bought back — patch 350

### 12.95.1 The instruction, and its window

12 August, the athlete: the set paces sometimes run the heart rate too high —
add 15 s/km to all times so the running is comfortable, from now until two
weeks after Japan. The plan is pace + RPE driven with HR as a ceiling
(ADR-0001; the plan document's own §04); this is the ceiling winning an
argument with the pace column, which is exactly the precedence the plan
promises.

The window resolves to **Fri 14 Aug → Sun 11 Oct**: wk-03's two remaining
runs (nothing already run is rewritten — the 24 Aug review compares against
the plan as it was trained), then every run through wk-11, the second week
after the 29 Sep return. wk-12 (from 12 Oct) resumes plan paces.

### 12.95.2 What moved — 18 detail strings, nothing else

Easy 5:45–6:00 → 6:00–6:15 · recovery 6:00–6:15 → 6:15–6:30 · steady blocks
5:25–5:40 → 5:40–5:55 · long runs 5:35–5:55 → 5:50–6:10 (wk-06's 5:30 floor
→ 5:45) · wk-10's re-ramp pair likewise · wk-11 tempo 4:55–5:10 → 5:10–5:25
and the MP finish 5:38–5:43 → 5:53–5:58 — slower than goal MP on purpose;
real MP returns wk-12.

Untouched, deliberately: the Japan weeks (by-feel pointers carry no numbers),
swim rep times and bike sessions (the complaint is running HR), strides (feel,
not pace), week stat lines (km unchanged; the ~ absorbs a few minutes),
titles — so **every uid is stable this time** — fuel lines, and the section-04
pace legend, which keeps describing the plan's real bands; a note there, on
the build-up phase card and on WK 10–19 names the window instead.

### 12.95.3 What moved together, and what did not need to

`PlanSeedTests.Frozen.sha256` and §9.2 — with the byte count standing still,
see the §9.2 amendment. `PlanCoverageTests` needed nothing: no run session
was added or removed and every changed line keeps a shape the parser already
handles, so 105/94/11 stand. Shipped as a patch zip (the App-builder
convention), not as bridge writes: HTML, plan.json, this file, PlanSeedTests,
AppVersion 350, tools/README.md, marathon-plan.md.

### 12.95.4 A call site no grep for the value can show you — patch 350a

349 and 350 were installed together and `PlanCoverageTests` failed twice:
`c.total → 103` against `Expected.runSessions → 105`, and `parsed → 92`
against `94`. The constants were right. **The measurement was reading the
database.**

`WorkoutParser.coverage(_ store: PlanStore = .shared)`. Patch 346a converted
this file to `PlanStore()` for exactly §12.57's reason — since 346 the
singleton is whatever the app is serving, and in the test host that is the
simulator's database. It swept for the literal `PlanStore.shared` and
converted six occurrences. **Five more were sitting in the same tests, inside
that default argument, and the sweep could not see them**: each test decoded
the bundle in its `#require` guard and then measured the singleton on the very
next line.

It passed for four patches because both plans held 103 run sessions. 349 put
105 in the bundle, the simulator's database still held the plan imported
before it, and the difference finally had a number.

**The shape, and it is a sixth one for CLAUDE.md's list:** a type's name, a
function's arity, an array's length, a printed string's content and a value a
fixture derives were already recorded there. Add **a default argument** — it
is a call site that carries a value the caller never writes, so no search for
that value will find it. The check is to grep the FUNCTION's name as well as
the value's, and to read each hit's signature.

**Every measurement now takes the store its own guard proved**, and
`coverageAnswersAboutTheStoreItIsGiven` counts the run sessions of that store
by hand and requires `coverage` to agree. That control fails today if the
argument is ever dropped again — the two plans differ by two sessions right
now — and it is deliberately a second derivation, because a control that
called `coverage` to check `coverage` could not fail. §12.43's exception, and
the fourth negative control written after the absence of one cost a patch.

**What it says about the device, which is the part worth keeping.** §12.93.2
states that after B1 a revised `plan.json` reaches the app only through an
import. This is that sentence with a reproduction: the simulator served a plan
two sessions out of date, silently, to code that asked the singleton. Nothing
was wrong with the bundle and nothing was wrong with the database — the
question simply named neither.

## 12.94 The plan bends around the calendar, not the other way — patch 349

### 12.94.1 What changed, and why the calendar decided it

Three facts arrived on 12 August: the athlete wants two build-up weeks before
anything hard (the strength habit is still bedding in), the second Berlin stay
now runs Sat 29 Aug – **Fri 4 Sep** (SN2588 — the plan believed Tue 1 Sep,
SN2590), and Japan is 6–29 Sep with running and bodyweight work only.

Japan already sits at weeks 7–9 and the race is unmoved, so nothing is
inserted and nothing renumbers: **weeks 4–6 change content in place.**

- **wk-04, wk-05 — build-up.** The two August quality sessions ("Light tempo
  (ease in)", "Tempo intro") become steady blocks — 2k easy + 5 km / 6 km
  @5:25–5:40 + 2k easy. Long runs are capped at 12 km on the athlete's
  instruction (was 14/12), so the first run past 12 km is now week 10's.
  Strength placement is untouched: A1/A2 Tuesday, B where it already was.
  The first threshold work is now week 11's, where the plan re-introduces
  quality after the trip anyway.
- **wk-06 — Berlin run block.** Berlin Mon–Fri with no bike and no barbell:
  five runs instead of three (easy 7 · steady 10 · recovery 5 · easy 8 with
  strides · long 12 at home Saturday), one bodyweight hotel circuit
  Wednesday, travel Friday (SN2588), Japan departure Sunday. The Wednesday
  bike, the Friday pool session and the barbell A1 are gone from the week;
  the last pool session before Japan is now wk-05 Monday and says so.

Every session keeps the fuel model's own line: easy/recovery runs and swims
water-only, steady runs ~30 g/hr (½–1 Leppin bottle), long runs ~65 g/hr off
the 12–14 km ladder rung (750 ml Leppin + 1 ULTRA gel), the remaining rides
~65 g/hr (bottle + chew per hour).

### 12.94.2 What moved together, per §12.13

`plan.json` is 278,870 bytes, SHA-256 `1c10ba91…`; sessions stay 261 and the
run mix moves 105→107 (bike 53→52, swim 26→25). Updated in the same patch:
`PlanSeedTests.Frozen`, `PlanCoverageTests.Expected` (run sessions 103→105,
parsed 92→94 — every new detail line reuses a shape the parser already
handles, so refused stays 11), §9.2 above, the HTML source and its
`tools/README.md` inventory line, and `docs/context/marathon-plan.md`.

The HTML week cards, the section-05 phase strip, `SWIM_DATA` (the "06" entry
is gone with the pool session; "05" carries the last-swim-before-Japan note)
and `STRENGTH_DATA` ("06" now holds the Wednesday hotel circuit) were edited
together with the JSON, so the extractor still reproduces the bundled
sessions verbatim; the weekly stat lines remain the only extractor output the
JSON corrects (§12.11.5), and for the three rebuilt weeks card and JSON now
state the same corrected figures (~86 / ~87 / ~42 km).

### 12.94.3 The uids churn, and §12.7 is why that is fine

Rewritten sessions mint new uids (`wk-04-tue-steady` where
`wk-04-tue-light-tempo-ease-in` was). No note, match decision or review
references them yet — the weeks are in the future — and anything that later
cites the OLD uids resolves against the stored prior `plan_version`, which is
the exact case that table exists for. On the device this version arrives the
way §12.93.4 restored: the importer hashes the bundle, finds a new hash,
mints and activates the version; the prior versions stay.

## 12.93 The write direction reads the stores — patch 347, D7 slice B1

### 12.93.1 What B1 did to a value that had been safe for forty patches

`AppStores.current()` gathers what the app holds into one value, so the importer
does not take twenty parameters and silently stop writing a table when somebody
forgets one. §12.45 is the record of what it prevents, and `fieldCount == 17` is
the test that keeps it honest.

Every field it reads was, until patch 346, a store fed from a file.

346 fed four of them from the database:

```swift
s.constants = ConstantsStore.shared.c
s.ftpWatts  = AthleteStore.shared.ftp
s.zones     = AthleteStore.shared.hrZones
s.plan      = PlanStore.shared.plan
```

**So the importer began taking four of its seventeen inputs out of the thing it
writes into.** Nothing on any screen shows that, no read-back reports it, and
the roll-up stayed at nine of nine — because every one of those comparisons is
between a store and the database, and a store fed by the database agrees with
it by construction. §12.15's shape, in the one direction D7's evidence does not
look.

### 12.93.2 The certain consequence: the seed path closed

**A revised `plan.json` can no longer reach the database.** The store hydrates
from rows, `AppStores` reads the store, the importer writes the rows back. The
bundle is unreachable — and the bundle is the only way a plan revision enters
this app.

That is not a hypothetical for this project. The plan is authored, revised, and
re-extracted; `plan_version` exists precisely so a second version can arrive and
notes written against the first can still be resolved.

### 12.93.3 The duplicate version, and what it actually proved

The first import after the flip wrote a second `plan_version`, doubling every
plan table: 261 sessions → 522, 634 blocks → 1268, 37 weeks → 74.

`contentHash` is `SHA256` of `JSONEncoder(.sortedKeys)` over the whole `Plan`.
`.sortedKeys` sorts object KEYS. It does not sort arrays. And the repository
reads `ORDER BY uid` for weeks, sessions and exercises, while `plan.json` is in
the plan's own order — within a week, `fri` sorts before `mon`. Same 261
sessions, different array order, different hash.

**The read-back agreed with that reading and is how the diagnosis was made
without a debugger:** 298 comparisons, every scalar field of every week,
session, breakdown and block, `approved differences: none`,
`unexplained differences: 0`. The two versions are content-identical. The hash
disagrees about order; the comparison does not look at order.

Verified stable at two versions across a second import — the second hydration
reads the version that was itself written in uid order, so the hash now matches
and no third appears. The store's array order is not visible anywhere:
`WeekView` reads `byDate`, which `rebuildIndexes` sorts by `seq`; `planWeeks`
sorts by `weekNo`; every `sessions(inWeek:)` caller aggregates.

**This was caught for free, by a check nobody wrote for it.** `importPlan` has
hashed its input and skipped the write since the plan tables existed. It is a
better round-trip proof than anything written for B1 — 261 sessions and 634
blocks compared by code that knows nothing about D7 — and it caught the defect
on the first import after the flip.

### 12.93.4 The fix, and it repairs a third thing

`AppStores.current()` takes the plan from `PlanStore.decodeBundle()`.

§12.91.3 forbids reaching for the bundle when a database READ fails. It has
never forbidden seeding a WRITE from it — `decodeBundle`'s own comment calls the
bundle the seed, and seeding is the only role it has ever had. The guard in the
apply script moves from two permitted call sites to three, deliberately, so a
fourth is still a decision somebody makes on purpose.

The third repair is provenance. `Sub4Import.run` stamps every version it writes
`sourceLabel: "bundled"`. Between 346 and 347 that was false of every version
written: the plan came out of SQL and was recorded as having come from the app
bundle. A provenance field that lies is worse than one that is missing, because
it is the field somebody checks when two versions appear and they want to know
where the second came from.

After the fix the importer hashes the bundle, finds version 1, and reactivates
it; the store hydrates from the original file-ordered rows; the next import
hashes the bundle again and matches. Version 2 is left inactive and orphaned —
389 KB, no behaviour, and removing it is a maintenance action rather than part
of this patch.

**The cost, owned rather than hidden:** `AppStores.current()` is `@MainActor` and
runs on backgrounding and on return, so it decodes 261 sessions of JSON on the
main actor a handful of times a day. A cached bundled plan in production scope
was the alternative and was rejected for the reason 346a rejected
`PlanStore.bundled`: a ready-made bundle sitting in reach is the fallback
somebody writes the day a database read fails.

### 12.93.5 The debt this does not pay, named so it is not rediscovered

The other three fields have no bundle to seed from. `ConstantsStore` and
`AthleteStore` are hydrated at launch and then read by the importer, and the
authored half of that has a window:

- an edit writes `constants.json` synchronously
- `DatabaseWriteThrough` runs on backgrounding and on return — **not per write**
- hydration overwrites the store from rows at the next launch, before
  `runOnReturn` fires

So: edit, then a termination that does not background the app, then a relaunch —
and the edit is discarded silently, with the newer value sitting in a file
nothing reads any more.

**Not fixed at 347, and the reason is the size of the window's contents rather
than the size of the window.** The only fields in `ConstantsStore` that cannot
be recomputed are `hrMaxOverride` and `restOverride`, both typed by the athlete,
and both absent from `constants.json` on the only install that exists.
Everything else is derived — `restByMonth` and `hrMaxObserved` from Health via
`refreshObserved`, zones and FTP from Strava daily — and a lost value is
recomputed on the next refresh.

**It closes with the authored-write path, which B9 requires anyway:** after
activation there is no file to fall back on, so every authored mutator must
reach the rows directly or the edit is not merely reverted but never stored at
all. Bolting a file-versus-rows comparison onto hydration would solve the narrow
case and would have to be removed at B9.

Recorded here rather than in a comment on `hydrate`, because it is a property of
the write direction as a whole and not of any one store.

## 12.92 One word, three meanings — patch 344, D7 slice B1

### 12.92.1 The finding, and a test produced it

343 gave `DatabaseBootstrap` a single verdict:

```swift
var isTrustworthy: Bool {
    plan.isTrustworthy && extras.isTrustworthy && athlete.isTrustworthy
}
```

Its own test failed on a freshly migrated in-memory database, and the failure
was not a typo. **The three sibling loads do not agree about what the word
means.**

| load | on an empty, migrated database | `isTrustworthy` |
|---|---|---|
| `AthleteLoad` | `.missing` | **true** |
| `PlanLoad` | `.noActiveVersion(versionsPresent: 0)` | **false** |
| `PlanExtrasLoad` | `.noActiveVersion(versionsPresent: 0)` | **false** |

Same database. Opposite answers. `AthleteLoad`'s own comment states its choice —
*"No profile row. A fresh database, not a fault."* — and `PlanLoad` never made
that call because nothing had ever asked it to.

Neither is wrong where it sits. `ReadBacks` asks each load exactly one question,
*is there something here to compare*, and for that question a clean read of an
empty database and a failed read genuinely do share an answer: no. Twelve files
read `.isTrustworthy` that way.

What cannot survive is `&&`-ing three of them. **A launch has a different
question and it has two halves with opposite consequences:**

- *the plan could not be READ* → a hydration must not happen
- *there is no plan YET* → a fresh install, and hydration must not happen either,
  but nothing is wrong and nothing should stop

A boolean that conflates those is a boolean a launch cannot act on. The file's
own header claimed to keep them apart while the code collapsed them, which is
§12.15 written by the person who wrote §12.15.

### 12.92.2 The resolution, and what was deliberately not changed

343c **removed** the verdicts rather than ship them meaning neither thing. There
was no caller — `DatabaseBootstrap` had none outside its own tests until 345 —
and §12.69 makes shipping an unreachable verdict the worse option: a guard that
cannot fail has not been tested, and one that cannot be *called* is worse still.

344 brings them back as two properties with two names, on all three loads and on
the value that carries them:

```
wasReadCleanly    did the read succeed        false stops a hydration
holdsContent      is there data here          false is a fresh install
```

`isTrustworthy` is **untouched on all three types.** Changing `PlanLoad`'s
reading would silently alter what the nine-of-nine roll-up means, and the
roll-up is the evidence D7's entry gate was passed on. `theSiblingLoadsDisagree`
pins all three implementations so that resolving the older ambiguity has to be a
visible decision rather than a quiet edit.

`.noActiveVersion(versionsPresent: 3)` is **not** a clean read. Three versions
stored and none active is a state somebody has to resolve, which is why the case
carries the count instead of being a bare `.empty` — §12.15's eleventh instance
paying for itself two patches later.

### 12.92.3 The approved list is the hydration-exclusion list

**An approved difference is a field the database cannot reproduce.** That is a
statement about the schema, and it has a second consequence nobody needed until
a store started taking rows: hydrating would overwrite the app's value with
whatever the absent column's default happens to be.

`AthleteRoundTrip.approved` holds one entry and the loss is not hypothetical:

- `constants.json` holds `version: 2`
- `AthleteRepository.load` omits the field, so `AthleteConstants()` supplies its
  default of **1**
- `LoadStore.currentSignature` interpolates `"v\(c.version)"`
- every mutator on `ConstantsStore` calls `save()`, so one later edit writes the
  rolled-back value into the file that is the legacy side's **only** copy

So `preservedOnHydrate` is declared beside `approved` and held equal to it by
test. One list, two consumers — §12.43, twelfth application. Adding an approved
difference in B2 through B8 now fails a test until somebody decides what
hydration does with it, and those lists are longer:
`user_note.activityID`, `user_note.planVersionID`, `Shoe.primary`,
`gear.retiredUTC`, `review.provider`, `proposal.decision`.

A named assignment rather than reflection, for the reason
`AthleteRepository.load`'s memberwise initialiser already gives: reflection
would also silently skip something.

### 12.92.4 Two loads, one store

`PlanRepository` reads the meta, weeks and sessions. `PlanExtrasRepository`
reads the fuelling, the warm-up and the exercises. They are two families in
`fieldCount` because they are two reads that can fail separately — and they feed
**one** `PlanStore`.

Hydrating with half of them would blank the Fuelling & race-day screen while
every other figure on every other tab stayed correct. That is worse than not
hydrating at all, because it looks fine.

`DatabaseBootstrap.hydratablePlan` is therefore all-or-nothing, in one place,
and a caller cannot assemble half a plan without writing the `Plan` constructor
itself. The coupling is structural rather than a comment somebody has to read.

### 12.92.5 Four things move together, or the store is worse than either half

`PlanStore` holds three things derived from `plan` — `byDate`, `weeksByUid` and
`focusCache` — and **none of them knows it is derived.** A hydration that moved
`plan` without rebuilding all three leaves a store whose index describes a plan
it no longer holds: internally consistent on both sides, describing nothing, and
invisible to any test that only checked `plan`.

`rebuildIndexes` is one function with two callers, and it **clears before it
fills**. Hydration can REMOVE a day; a merge would leave old sessions on dates
the stored plan does not have, and every one of those answers would look like
real plan data.

Three comments were corrected rather than left to be believed, all three having
stopped being true in this patch: `PlanStore`'s header (*"plan data never
changes at runtime"*), `focusCache`'s (*"the answer cannot change"*), and
`PlanFocus`'s (*"`PlanStore.init` is private, so there is exactly one store"*).
The conclusion each of them supported survives; the reason given for it did not.

`PlanStore` is still not `@Observable`, for a stronger reason than the one it
used to give: hydration completes inside `Sub4Launch.begin()`, before `RootView`
constructs `ContentView`, so no view exists to be told. **The ordering is the
guarantee and it lives in the launch** — which is why the next patch has to fix
the ordering.

### 12.92.6 Why the slice is two patches, and the defect 345 must fix

344 is the machinery: the loads, the bootstrap, three `hydrate` methods, and a
`StoreSource` that makes "this store was never hydrated" distinguishable from
"this store was". Nothing calls any of it. `sliceUnderTest` is still nil, the
launch is untouched, and the acceptance criterion is that every figure on the
device is unchanged — the same criterion 342 and 343 had.

345 is the wiring, and it is small enough to reason about because 344 is not in
it.

**One defect found while reading, and it is 345's to fix.** `Sub4Launch.begin()`
sets `state = .ready` **before** it derives `persistence`:

```
self.database = db
self.state = .ready          ← RootView may construct ContentView from here
let activated = …
self.persistence = …
```

It is correct today only by accident: the remaining statements run to completion
on the main actor before the run loop turns, so SwiftUI never gets a chance to
build the view in between. Add the bootstrap's reads — which suspend, because
they belong off the main actor — and `ContentView` is constructed with
un-hydrated stores. Under `.databaseAuthoritative` after B9 that is the legacy
plan served for a frame and then replaced, which is exactly the class of failure
`Sub4Launch`'s own header calls the worst this app has available.

The hydration must complete before `.ready`, not after. `PlanStore` not being
`@Observable` depends on it.

## 12.91 A read-back that stops being evidence — patch 343, D7 slice B1a

### 12.91.1 The finding, and it is about all eight slices

`ReadBacks.plan` compared `PlanStore.shared.plan` against `PlanRepository`.
298 comparisons, 0 unexplained, on every device run since the wipe — and one of
the nine lines that passed D7's entry gate on 10 August.

**The moment B1 hydrates that store from the database, the comparison is the
database against itself.** 298 checks, guaranteed to agree, proving nothing.
§12.69's rule at the worst possible moment: a guard that cannot fail has not
been tested.

And it is not one slice. B2 does it to `AuthoredRoundTrip`, B3 to
`ActivityRoundTrip`, B4, B5 and B7 to theirs. **The nine-of-nine roll-up would
go tautological one slice at a time**, each slice reporting a clean pass while
proving less than the one before it, and the entry-gate evidence eroding as D7
proceeded. Nothing in the master plan names this consequence; it says "freeze
the legacy result and the repository result using the existing round-trip
type", which only works if BOTH reads still happen.

### 12.91.2 The decision, 10 August 2026

**The store serves the database; the read-back keeps its own legacy read.**

The screens show database-backed values — which is the thing D6c cannot prove
and D7 exists to establish — and the comparison gets its other half from the
original source rather than from the store. For the plan that source is the
bundle; for later slices it is the JSON file each store used to read.

The cost is owned: the legacy read still runs on every roll-up during the
shadow window, and one more reader of `plan.json` exists until D8. That is the
price of the read-back continuing to mean something, and it is worth paying —
the alternative options were to prove only what D6c already proved, or to
retire the read-backs one by one and watch the gate evidence decay.

### 12.91.3 The bundle is a seed and never a fallback

The sharpest hazard in B1, and `PlanStore.decodeBundle` carries it in its own
header.

If `PlanRepository.load` returns `.failed`, nothing may read the bundle
instead. It looks harmless — the same file the importer seeded from — and it is
not: **the database may hold a different plan VERSION**, and every note, match
decision and review change is written against `plan_session.uid` values from
the stored version. A silent fall back would resolve those uids against a plan
nobody chose, and the screens would look entirely normal while doing it.

Under `.legacyAuthoritative` the bundle IS the source and that is correct.
Under `shadow(B1)` or `databaseAuthoritative`, a failed plan read is a failed
launch.

### 12.91.4 Why this is its own patch

343 changes what the read-back compares and nothing else. Today the store IS
the decoded bundle, so **298 and 71 must come back unchanged** — the acceptance
criterion is that no number moves, which makes the half checkable on its own.

344 then hydrates the stores. By then the read-back is already independent, so
a figure that moves is a finding rather than an ambiguity. Doing both at once
would mean changing the measurement and the thing measured in one step, and
this project has a §12.34-shaped history with exactly that.

### 12.91.5 `DatabaseBootstrap`, and `PersistenceMode` becomes readable

`DatabaseBootstrap` is `AppStores` in the read direction, with the same
argument: §12.45's twenty defaulted parameters, where a forgotten one was not a
compile error but a table that quietly stopped being imported. A forgotten one
here is a store that hydrates from nothing. Three families at B1, `fieldCount`
pinned by test, growing by slice.

It decides nothing — it reads and hands over the loads intact. Whether a
`.failed` load is survivable is `PersistenceMode`'s question and the store's. A
bootstrap that substituted an empty value for a failed read would be the defect
the whole stage exists to prevent.

`PersistenceMode` also gains its line in the paste. At 342 printing it nowhere
was defensible, because nothing consumed the value and the state was provable
by construction. From B1 it decides what three stores read.

## 12.90 Where the app reads from, decided once — patch 342, D7 slice B0

### 12.90.1 The decision this implements

A3 §2.2, settled 10 August 2026: every D7 slice keeps a selectable legacy path,
the flag flips at B9, and the choice is made by an explicit persistence mode
derived from the ledger — **never by a repository returning empty**.

That last clause is the whole of the risk. After activation an empty database
IS the answer and must be shown as one. A fallback triggered by emptiness would
serve an empty training history as though it were real, which `Sub4Launch`'s
own header names as the worst failure this app has available.

`PersistenceAuthority.derive` is therefore a pure function of three facts, and
not one of them is a repository result.

### 12.90.2 The hole the plan left, and the shape of the patch

The plan says one activation authority: the newest verified `migration_run`
becomes `activated` in a checked transaction, and no preference may
independently claim activation. Correct, and incomplete.

**A database that will not open cannot tell you whether it was activated.** The
ledger is inside the thing that failed. So at the one moment the distinction
matters most — an activated install with a corrupt database — `.blocked` and
`.legacyAuthoritative` are indistinguishable from the ledger alone.

`PersistenceAuthority.everActivated` is a `UserDefaults` mirror written only
AFTER the ledger transaction commits. It is not a second authority, and the
property that makes that true is asserted by test: **it can only ever make the
outcome more conservative.** It can turn a failed open into `.blocked`. It can
never produce `.databaseAuthoritative` — that branch requires `databaseOpened`
and the ledger row.

The direction is the argument. A mirror that could grant permission would be
the second authority the plan forbids. One that can only withhold it fails
towards refusing to serve data, which is the harmless side — the same reasoning
`MigrationLedger.prunableTriggers` uses about a leak and a shredder.

The key is namespaced and asserted, because `DataLifecycle` must remove it with
everything else: a flag surviving "Delete local data" would block a reinstalled
app over a database that no longer exists.

### 12.90.3 Four states, eight inputs, one table

Two of the four states have never occurred on any device and one of them never
should, which is exactly why `derive` is pure — every combination is driven
from a test. `everyCombinationIsCovered` states all eight answers, so a branch
added later without a decision appears as a mismatch rather than as a state
nobody named. An account beats a list.

### 12.90.4 What B0 deliberately does not do

Nothing reads the value. No store changes, no screen changes, no behaviour
change of any kind — `b0DoesNotFlipTheFlag` asserts the flag is still false.
A value nothing consumes can be wrong without consequence, and that is what
makes this slice checkable on its own.

`Sub4Launch`'s header was corrected in the same patch. It has said since it was
written that the flag flips at the first slice; that is not the design being
built, and a comment that is confidently wrong about the next rung is worse
than no comment. §12.34, on the file that owns the launch.

### 12.90.5 What B1 needs that does not exist yet

Recorded here so the next session does not rediscover it:

- **`RootView` has no failure branch.** Sixty-nine lines, one condition, and
  `isFinished` is `state != .opening` — so `.failed` reaches `ContentView()`
  today. That is correct while the database is a shadow. B9 does not extend a
  recovery screen; it has to design one.
- **`match_decision` and `rejection` have a table and no reader.** B2 writes
  both.
- **`ActivityRoster.settle` has exactly two production call sites**, both in
  `ActivityStore`. B3 repoints those two and must not create a third.

## 12.89 The last three things behind the glass — patch 341

### 12.89.1 The adapter that had already been wrong once

`ReadBackRollUpTests.swift` carries this in its own header, written at 333a:

> *"333 shipped three states and collapsed two of them in the adapter. These
> tests did not catch it, because they tested the type and the defect was in
> the caller: every test below passed while the device reported 'could not
> look' over a database it had read perfectly."*

It documented the untested seam and left it untested, because the caller was a
`private static func` on `DatabaseHealthView` and no test can reach a SwiftUI
view's private members. The function that turns nine reports into nine verdicts
— the one that decides whether an empty comparison is a blind read — had
fifteen sibling tests and zero of its own.

341 moves it to `ReadBackRollUp.line`, body identical, and
`RollUpAdapterTests` states the three transitions. The one with teeth is
`aTrustworthyReadOfAnEmptyDatabaseIsNotBlind`: a read that succeeded over an
empty database must be `.nothingToCompare`, never `.couldNotLook`. That is
precisely what 333 got wrong and only the device could tell.

**Stage A2 item 7 asked for "a negative-control fixture whose mismatch makes
the roll-up fail". This is it, and it could not be written before the move.**

### 12.89.2 The import report was the last block trapped behind the screen

313 moved shadow parity's result off `@State`. 333 did it for the nine
read-backs. 340 did it for the verifier. The import report was still there:
`@State private var importReport`, drawn in the Import section, referenced
**nowhere** in `diagnosticsText`.

So the counts a person most wants to send — *Notes: 1 new*, *Gear: 0 new, 11
known, 1 refreshed* — were reachable only by screenshot. They were
screenshotted twice on 10 August, which is how the gap was found. Fifth
instance of §12.57 and, on this screen, the last one.

`LastImport.shared` holds it. **It is deliberately not folded into
`DatabaseWriteThrough.last`**, which holds a report too: that one answers *is
the automatic trigger firing and did it fail*, is fed only by backgrounding,
returning and the background refresh, and the Import button never touches it.
Collapsing them would make the write-through's health line move when a person
pressed a button — §12.39.2's confusion, in the other direction.

`Report.diagnosticLines` is counts only. `Refusal.externalID` is a Strava
activity id and §12.7 promises the paste carries none, so refusals reach it as
a number and their detail stays on screen — the same rule the verifier's
`detail` field follows.

### 12.89.3 The authored export, and why a snapshot was never a backup

Stage A1 item 5, in the athlete's own words in the plan: *"A snapshot inside
the app container is recovery input, not an off-device backup."*

On 9 August the app was deleted by hand during a crash loop. It took
`notes.json` — thirteen months of what the athlete thought after each session —
and `commutes.json`, the only source the `correction` table has. Both were
inside the protected snapshot, and the snapshot was inside the container the
delete removed. **The protection worked exactly as designed and protected
nothing, because everything it protected lived in the same place as the thing
it was protecting against.** Strava sent the activities back. It cannot send
these.

`AuthoredExport` writes one JSON document holding five stores verbatim, each
with its byte count and SHA-256, plus the app version and the moment. Five and
not all of them: `activities.json`, `weather.json`, `details/` and `streams/`
are 19 MB of things a source can send again, and including them makes an export
nobody presses. The complete artefact remains the database, taken off by
container download, which is a different operation with a different cost and is
written down in the A1 campaign rather than hidden behind a button.

**One document rather than an archive**, because there is no zip in the SDK
worth three hundred lines for twelve kilobytes — and because a document can
carry what an archive cannot: which build wrote it, when, and a hash per file,
so a copy that has rotted can be told from one that has not. The same argument
`SnapshotManifest` makes.

**The contents go in as text, not re-encoded.** Decoding and re-encoding would
put this file's opinion of the shape between the athlete and his own data, and
the hash beside each entry would then describe the copy rather than the
original.

An absent store and an unreadable one stay different: a device with no commute
decisions has no `commutes.json` and that is an answer, while a file that
exists and will not read is a loss. `AuthoredExportEntry.error` is nil for the
first and a sentence for the second — §12.15, and the distinction 9 August was
about.

## 12.88 A verified run nobody could find — patch 340

### 12.88.1 The gate's own sentence had no reader

D7's entry criterion is *"a verified run exists over the current data"*. On
10 August 2026, reading the source for steps 3, 4 and 5 of the entry gate, that
sentence turned out to be unreadable on this device by any means.

`LedgerCensus` counted five things — the total, the four triggers, the
unrecorded rows, the runs open now and the interrupted ones — and `verified` was
not among them. `MigrationRun` carries the state, but the Import ledger card
draws only the NEWEST run, and every import, every backgrounding and every
return to the app opens a newer one. So the fact survived in the table and had
no path to a screen or a paste.

The verifier's own report was worse. `verification` and `verifyLedgerNote` were
`@State` on `DatabaseHealthView`, so the whole verification block left the
diagnostics paste the moment the sheet was dismissed. **That is §12.57 for the
fourth time** — 313 fixed it for shadow parity, 333 for the nine read-backs,
and the one control the entire ladder turns on was never moved.

The practical shape of the defect: press Verify, get a clean report, press
Done — and there is now no artefact anywhere stating that it happened.

### 12.88.2 Two halves, and neither can replace the other

`LedgerCensus.everVerified` and `LedgerCensus.newestVerified` are the DURABLE
half. They survive every launch, they are printed unconditionally, and they
answer *has the verifier ever succeeded on this database*.

`VerificationResult.shared` is the CURRENT half, shaped exactly like
`ShadowParity.shared` and `ReadBackRollUp.shared`. It survives the sheet, dies
with the launch, and answers *what did the last press find*. It is deliberately
not persisted, for §12.29's reason: a stored verdict from three launches ago is
a second answer to a question the current data already settles.

### 12.88.3 `activated` is counted as verified, and that is not a conflation

`activateVerified` refuses every source state but `verified`, so an activated
run is a verified run that went one rung further. A census counting only
`verified` would print **"never"** over a database that had just passed the
gate — §12.54.2 arriving on schedule rather than by surprise, and arriving
during the one patch where somebody is reading that line to make the D7
decision.

### 12.88.4 The row, not the note column

`verifyPending` accepts a nil note, so a verified run that recorded nothing and
no verified run at all both produce nil from `String.fetchOne(note)`. Two
opposite facts wearing one appearance — §12.87's shape, which cost patch 339 —
so the census fetches the whole row and the paste says `no note recorded` for
the first case and `never` for the second.

### 12.88.5 `runs opened since it` is the honest currentness figure, and it is
only half the question

A verified row proves nothing about today unless nothing has happened since.
The census now says how many runs have been opened after the newest verified
one, computed as `MAX(sequence) - sequence` rather than as a count of rows —
`sequence` is `AUTOINCREMENT`, so the figure survives the retention prune that
deletes the rows it would otherwise be counting.

**What it does not say, stated here so nobody reads it as more than it is.**
Zero runs since means the LEDGER has not moved. It does not mean the stores
have not: Import and Verify each read `AppStores.current()` live, and nothing
binds a run to a fingerprint of the dataset it checked. That work is §5 step 5
of `CLAUDE.md` and it is still open. This patch closes the gap between *the
ledger knows* and *a person can read it*, and closes nothing else.

### 12.88.6 What else the step 3–5 reading found

Three things worth recording, none of which needed code:

**The Compare button runs SIX slices, not eight.** `ShadowParity.Outcome.ran`
carries `activities, volume, load, details, matches, summaries`. Slices 5b, 6,
6b, 6c and 7 in §12's D6c table are READ-BACKS, run by the roll-up. A gate
document written from the table told the athlete to look for two sections that
do not exist.

**The note and the commute controls are not where the gate document said.**
`ActivityDetailVerdict.noteCard` draws only when the activity is matched to a
plan session — `NoteEditorView(session:)` is keyed by session uid, so an
unmatched extra has nowhere to hang a note. `ActivityDetailView.commuteSection`
draws only for `discipline == .bike`, as a row labelled *Commute* with an ⓘ and
a bicycle, not as a header glyph.

**A commute decision recorded by one tap moves training data.**
`setCommute(!activity.isCommuteRide)` inverts whatever the distance rule
currently says, which changes that ride's training volume and its plan
eligibility. Two taps on a short ride leave an explicit `correction` row that
AGREES with the rule — one row for the read-back, and no figure moved. The
gate needs a decision to exist; it does not need the decision to be a change.

## 12.87 Verification is a guarded transition, not a historical count — patch 338

The captured database has 53 `pending`, three `running`, and zero `verified`
rows. That says no run in this database has ever passed through the verifier;
it does not define the final gate. A historical verified row cannot prove that
the current source package is the one it checked.

`SemanticVerifier.record` may now move only the newest ledger row, only from
`pending`, and only when that row already has an import finish time. The update
is conditional in SQL, so a new write-through opened between comparison and
recording makes the transition return false. `finishedUTC` is not rewritten:
it remains the import finish time rather than becoming a misleading duration
that ends at verification.

`MigrationLedger.finish` accepts only the two outcomes of executing an import:
`pending` and `failed`. It cannot write `verified` or `activated`; those states
have separate one-rung transitions. Running, interrupted, failed, already
verified, activated, unknown, and superseded rows are refused.

The current code still does **not** bind that row to snapshot bytes.
`snapshotID` is an association passed beside a fresh `AppStores.current()`;
Verify gathers the live stores again, and automatic writers can run between the
two. The operational gate therefore owes a dataset/manifest fingerprint (or an
import directly from the protected snapshot), a quiescent final window, and a
requirement that import and verification observe the same fingerprint. Only
then can the newest verified row prove currentness. A historical census alone
is audit evidence, not that proof.

## 12.86 What the container said that the screen could not — patch 338

On 9 August the app's own container was pulled off the phone and the JSON
stores were compared against `sub4.sqlite` by code that shares nothing with the
app. Every explicitly mapped field compared equal after the importer's stated
normalisations: 678 activities; 586 weather records; 483 details with 5,941
splits, 1,771 laps and 599 efforts; 470 traces with 140,790 samples; six
rehearsal review rows; and the bundled plan. This validates the covered
read-backs. It does **not** mean the database is a literal or complete copy;
§12.86.7 records the source fields and ordering that the mapping does not retain.
This was a one-off external audit of the downloaded container; its executable
and field-coverage report are not yet committed repository artefacts, so making
the result reproducible is a gate item rather than an established tool.

### 12.86.1 A read from outside is a different instrument

Every check this project has is the app checking itself. That is not a weakness
of any one of them — it is the shape of all of them at once, and it means a
question nobody thought to ask has no way to surface.

Five did. The first four are facts about housekeeping; the fifth is a backup
boundary. Each was invisible from the screen by construction:

1. `migration_run` had **never once** reached `verified`, on this database, ever;
2. three rows sat in `running`, one of them genuinely live;
3. the snapshots folder was the largest thing in the container and nothing
   pruned it;
4. `SnapshotManifest.createdUTC` held the folder name, not a timestamp.
5. all four protected snapshots omitted the UserDefaults-backed migration
   inputs, including the rejection payload and sync/backfill state.

**The general rule: a system that only checks itself cannot find the questions
it does not ask.** Reading the artefact with a different tool is cheap and is
now worth doing at each rung of the ladder rather than once.

### 12.86.2 `running` was two facts wearing one word

`MigrationLedger`'s header is right that a ledger which forgets a crash is worse
than one that records it, and `stale()`'s comment was right to refuse to rewrite
a crashed run to `failed` — `failed` means the write threw, and a process the OS
killed threw nothing.

But keeping the fact by keeping the ambiguity is not keeping the fact. `running`
meant *open right now* and *was open when the process died*, and no column could
separate them: the container held three, one opened forty-six seconds before
capture and genuinely live. The screen said `Interrupted runs: 2` and that
number was neither right nor wrong, because it was answering two questions.

`2026-08-15-interrupted-run` adds a sixth state. It is terminal, and the
rebuilt schema gives it `finishedUTC = NULL` plus a separate non-null
`recoveredUTC`. The exact finish time stays unknowable; the later launch time is
not presented as import duration. Recovery time is not ordered against start
time because a wall-clock correction between processes is possible and must
not prevent recovery.

**The ambiguity resolves at launch and only at launch.** No run from a previous
process can still be open, so every row in `running` at that instant was
interrupted — with no timeout, no clock comparison and no heuristic.
`Sub4Launch` closes them immediately after the database opens and before any run
is opened; the health-screen fallback performs the same boundary operation.
Recovery failure is non-fatal while the database is a shadow source, but is
stored and printed rather than swallowed.

The census now prints two numbers where it printed one — `open right now` and
`interrupted, recovered at a later launch`. Automatic interruption rows retain
the newest 20; manual and pre-trigger rows remain durable. §12.54.2 again, and
this is the second time in three patches that one number standing for two
questions is what let a problem hide.

### 12.86.3 A rebuild rather than a looser CHECK

SQLite cannot alter a CHECK and `migration_run.state` carries three. Same
twelve-step rebuild as `2026-08-13-confidence-scale`, and cheap for the same
reason: the table holds tens of rows because `MigrationLedger` prunes it on
every insert.

Dropping the CHECK instead would have traded one rebuild for a column that can
hold a typo for ever, which is the opposite of what every frozen vocabulary in
this schema is for. `triggeredBy`'s constraint — added by a *later* migration
than the table — is copied into the rebuild verbatim; a rebuild that silently
dropped a constraint added after the original body is a schema nobody could read
from the source.

The rebuild also adds an autoincrement `sequence`. `startedUTC` has one-second
precision and the captured table already contains same-second runs; UUID text
is not a chronological tie-break. All newest-run, verification and retention
queries order by insertion sequence. A populated predecessor-table upgrade
test carries every old state and field across in row order.

**The rows already stuck open are NOT converted in the migration.** A migration
runs inside the launch that is about to open its own run and cannot tell from
SQL which open row belongs to the process it is running in. One line, and it
would have been a guess.

### 12.86.4 A `try?` in front of the one write D7 acts on

`DatabaseHealthView.runVerify` read:

    _ = try? SemanticVerifier.record(report, for: runID, in: db)

If that write threw, the screen showed a passing verification and the ledger
stayed `pending`, with nothing anywhere saying the two disagreed — and
`verified` is the state D7 decides on. §12.15 with a `try?` in front of it.

The verdict row now has a `Ledger` row beside it saying which of three things
happened: the run is marked verified, the report did not pass so the run stays
where it was, or the write threw and here is what it said. **Two writes, two
answers.**

The transition itself is now conditional: only the newest completed `pending`
row may become `verified`. A running, interrupted, failed, activated, unknown or
superseded row is refused, and the import's `finishedUTC` is preserved. The
general import-finishing API accepts only `pending` or `failed`, so it cannot
bypass this gate.

Separately: `verified` has never been reached on this database, and the reason
is not the ongoing import. Nothing but the Verify button can write it —
`SemanticVerifier.record` is the only writer and the ledger deliberately stops
at `pending` — so `0 verified ever` means the button has not been pressed since
the wipe. CLAUDE.md §5's claim that "`migration_run` reaches `verified`"
described the pre-wipe database and had been stale for a day.

### 12.86.5 Snapshots had no retention and became the largest thing on disk

    snapshots   40.58 MB   (4 copies, 2 of them byte-identical)
    database    27.13 MB
    live stores 14.21 MB

Two of the four were taken fifty-eight seconds apart — 958 files each, every
file hash-identical. `LegacySnapshot` had no prune, no keep-newest, nothing. At
~14 MB now and ~25 MB once the trace backfill lands, a habit of pressing the
button fills the phone, and the screen would say nothing was wrong.

**The obvious policy is wrong and the reason is sequence, not size.** Deleting
the previous snapshot as the new one is written destroys the only good copy at
the moment the new one is unproven; a phone that runs out of disk halfway
through 958 files would be left with a half-written snapshot and nothing behind
it. This project has already lost every store once.

So: prune only after `isComplete` *and* an independent payload re-hash — every
file that existed was copied and still hashes equal — and keep two full copies.
The capture that triggered retention is always protected even if the phone
clock moved backwards. Incomplete, unreadable, empty-manifest, unsafe-path and
tampered folders never authorise deletion and are left for inspection.

**The manifest details survive the payload.** Before an older full folder is
removed, `snapshots/receipt-<id>.json` is atomically written and read back. It
embeds the complete manifest (every path, size and SHA-256), the digest of the
exact original manifest bytes, totals, capture time, prune time and app builds.
It is audit metadata, explicitly not a restorable backup. Existing receipt ids
cannot be overwritten or reused. Twenty verified receipts are retained; corrupt
or unknown receipts are never deleted automatically.

The four captures in the audited container protect only Application Support
files. They omit UserDefaults-backed inputs such as rejection/match payloads,
sync cursors and backfill state; the in-app text export also rendered Data
values only as byte counts. Patch 338 adds a filtered binary `preferences.plist`
containing every key declared by `DataLifecycle`. It is a logical, lossless API
export rather than a copy of the process-owned physical plist, and it excludes
Keychain. A new post-338 snapshot is required before the gate.

### 12.86.6 `createdUTC` was not a UTC time

`SnapshotManifest(id: stamp, createdUTC: stamp, ...)` — both fields held
`"2026-08-09-143235"` in all four manifests. §12.48 records "a timestamp that is
a name is not a time"; this is the same error arriving from the other side, a
field whose name promises ISO-8601 and whose value is a folder.

**The key is not renamed.** Four manifests on disk carry it, one of them the
only copy of stores already lost once, and `SnapshotManifest` is `Codable` with
a non-optional field — a rename makes every existing manifest undecodable. The
value becomes a real timestamp and `createdDate` returns nil for the old shape
rather than parsing the id into a date that was never recorded. A reader asking
what the manifest recorded gets the honest answer.

Retention receipts make a separate, explicit derivation for old snapshots:
their `capturedUTC` is parsed from the UTC folder id so an audit record can sort
and display it. That does not change the old manifest's `createdDate`, which
remains nil; the receipt's manifest digest preserves the original value.

### 12.86.7 What the comparison could not prove, and said so

Zero differences applies to fields the importer explicitly maps, with its date
normalisation. It is not information identity. The audit found these source
facts with no lossless database representation or round-trip check:

- gear is flattened across bike, active-shoe and retired-shoe collections;
  `primary`, retirement membership and athlete fetch time are not retained;
- rejection receipts lose their verbatim `label` and `dateIsKnown`; match
  decisions likewise lose `dateIsKnown`;
- `plan.json`'s `meta.source` is dropped, and top-level session/exercise array
  order is not stored because those tables have no ordinal (225 of 261 session
  positions and all 20 exercise positions differ when read `ORDER BY uid`);
- fractional seconds in detail, stream, weather and sync fetch timestamps are
  normalised to whole-second ISO-8601.
- `AthleteConstants.version` is intentionally excluded as cache invalidation
  state rather than an athlete fact.

The database also contains useful information the JSON does not: canonical
identities, source records and aliases, relationship/provenance rows, plan
version/hash/activation metadata, and the migration ledger. The right model is
a normalised semantic copy plus provenance, not a byte mirror. Every lossy item
must either be modelled or explicitly accepted with consumer evidence before
D7; the current verifier mostly checks counts and cannot approve that decision.

Patch 337's claim that the overwritten sixth review "came back" is true at row
level and thinner than it looked:

    distinct recordKeys:      6
    distinct evidence bodies: 1
    distinct summaries:       1

All six rehearsal reviews carry identical content, and the two that collided
share a window. So the 9 August overwrite destroyed a row, not any unique text,
and the recovery restored a row whose contents were already present five times
over. The fix and its reasoning are unchanged — with a real review the packs
differ and the loss is permanent — but the device evidence for it is weaker than
the counts suggested, and the counts were what got reported first.

**A denominator of one is not a denominator.** Six identical fixtures compare
equal for a reason that has nothing to do with the code under test.

### 12.86.8 Database cutover and Strava exit are separate gates

The database is still a shadow copy. Production stores and screens load JSON,
`Sub4Launch` still fails open because those reads do not yet depend on GRDB, and
disconnect currently treats the database directory as disposable local data.
D7 must repoint reads, fail safely, export the authoritative database, replace
folder deletion with lineage-aware row removal, close/reopen the database around
destructive lifecycle actions, and prove rollback for a release window.

Even after D7/D8, disconnecting Strava does not make new activities arrive from
HealthKit. There is no production workout adapter yet; current activity ingest
calls Strava and all 678 captured activity source records are Strava. Phase 4A
still owes source priority/deduplication, moving-time, route/history, gear and
local-zone replacements plus an on-device fresh-workout ingestion/export test.
Until those pass, revoking Strava would stop new activity ingestion.

## 12.85 The run time was never the key — patch 337

`review.recordKey`, and the deletion of an approved difference that had been
wrong since the day it was written.

### 12.85.1 What happened, and how close it came to being invisible

On 9 August 2026 the rehearsal button wrote six review records into
`ProposalStore`. Two of them carry the same `ranAt`, to the second.

`Sub4Import+Authored.importProposals` looked a review up like this:

    SELECT id FROM review WHERE accountID = ? AND ranUTC = ?

So the sixth record found the fifth's row, took the UPDATE branch, and — because
the children are replaced wholesale — **deleted that review's evidence row, its
lineage rows, its proposal, its changes and its watch items, and wrote its own
in their place.** No error, no refusal, no ledger entry. The diagnostics paste
read `review: 5`, and five is a perfectly reasonable number.

The only thing in the app that noticed was `ReviewRoundTrip.duplicateRunTimes`,
written at patch 327 for exactly this and never fired in ten patches. It put one
line in the paste — `two app records ran at 2026-08-09T12:29:35Z` — and that
line is the entire reason this is a section rather than a loss.

**That is the argument for reporting a collision rather than resolving it.** The
alternative shape, `Dictionary(uniquingKeysWith:)`, was available and would have
kept one silently; §12.71.12 chose to report, and the report is what survived.

### 12.85.2 The approved difference was the bug

`ReviewRoundTrip.approved` carried this entry from 327:

> **Record.id** — the app keys a review by window label and run count; the
> database mints a UUID and keys on (accountID, ranUTC). No column, and none is
> wanted — patch 327.

An approved difference is a claim that a gap is **deliberate and harmless**. The
first half was true; the second was a guess, and it was checked against the
wrong thing — against whether the two ids could be made to agree, rather than
against whether `(accountID, ranUTC)` could identify a review.

It cannot. `ranUTC` has one-second resolution and no unique constraint behind
it. A key with a resolution limit is a key with a collision rate, and the only
question is how often the writer is fast enough to find it. The rehearsal
writes a batch in a loop; the answer turned out to be "the first time anybody
ran it after the wipe".

**The entry was deleted rather than reworded.** When the harm arrives, an
approved difference does not get a caveat — it gets a column. The comment left
in its place says so, because an entry that vanishes between two builds with no
trace is indistinguishable from one nobody ever wrote, which is §12.54.2 applied
to a decision record instead of a screen row.

### 12.85.3 The app had already solved this, in 2026, and was not asked

`ProposalStore.Record.id` reads `"{startDay}_{endDay}_{n}-{six hex}"`, and its
own comment from patch 269 explains the suffix:

> UUID suffix, not a running count: deleting record 1 would make the next add
> produce id 2 again and collide in the list.

So the app identified this exact failure mode for its own in-memory list, fixed
it, and the database was never told. Nothing is invented by `2026-08-14-review-
record-key`: a value that is already unique, already `Codable`, and already
present in every `proposals.json` on disk simply gets a column and an index.

**The general form is worth naming.** When two layers hold the same thing under
different identities, ask which layer has already had to solve identity for
itself. That layer's answer is usually the one to carry, and carrying it costs a
column; minting a second identity costs a class of bug that only appears under
load.

### 12.85.4 Nullable, and the importer adopts

The five rows on the device were written before this migration and their keys
live in `proposals.json`, which SQL cannot read. A migration cannot backfill
them, so the column is nullable and the **importer** adopts:

1. look up the row carrying this record's key — the steady state;
2. failing that, a row with **no key at all** whose `ranUTC` matches. It takes
   this record's key here and can never be claimed again, because step 1 finds
   it next time and `recordKey IS NULL` excludes it from step 2.

The `IS NULL` is what stops two records sharing a run time from both adopting
one row: the first writes the key, the second finds nothing and inserts. **Which
is how the sixth review comes back** — `proposals.json` still holds all six, so
the next import after 337 restores the one that was overwritten, rather than
merely stopping it happening again.

The unique index is partial — `WHERE recordKey IS NOT NULL`. SQLite treats NULLs
as distinct in a unique index and would have permitted the unkeyed rows without
the clause; it is written because a reader should not have to know that rule to
know the index is not claiming the unkeyed rows are unique.

### 12.85.5 Two pairing counts, not one

`ReviewRoundTrip` now prints `reviews paired by record key`, `reviews paired by
run time, not yet keyed`, and `database rows awaiting a record key`. All three
unconditional.

One number would have been enough to pair correctly and useless for reading:
"5 paired" cannot tell a device that has adopted the new key from one that has
not, and the adoption window is precisely the state where a wrong answer is
plausible. `pairedByRunTime` reaching zero is what says the window closed.

`duplicateRunTimes` **left `unexplained` at this patch**. It was in that sum
because the run time was the key; it is not, so two records in one second is now
a fact about the clock rather than a difference between two sides. The row stays
on the screen, no longer red, because it is the counter that caught this.

Two new members replace it in the sum — `duplicateRecordKeys` and
`duplicateStoredKeys` — and neither can fire without a bug. Kept and tested
anyway: §12.69, and because the last thing this project assumed could not
collide is the subject of this section.

### 12.85.6 The fourth test inverted in three days

`twoAppRecordsAtTheSameRunTimeAreReported` asserted, since 327, that a run-time
collision is reported and counts against `unexplained`. It now asserts that both
records import, both compare, and the collision costs nothing.

That makes four: 327b's `noPlanMeansNoResolution`, 334's
`theConfidenceRangeIsReported`, 335's `nothingWritesEvidenceLineage`, and this.
**All four were written by the patch that found a problem and declined to solve
it, and all four changed on the day somebody decided.** A finding recorded as a
test is a finding that cannot be forgotten and cannot be fixed silently; a
finding recorded as a comment is neither.

### 12.85.7 The fixture change is the §12.61.9 instance

`ReviewRepositoryTests.record()` derived its `id` from the window days. Once the
id is the pairing key, `aChangedWindowIsADifference` — which changes `endDay` to
provoke a **field** difference — was changing the **key** instead, and would have
reported two unpaired reviews rather than one differing field. The test would
have failed, which is the good case; the bad case is a test like it that still
passes while measuring something else.

Grepping `Sub4CoreTests/` before the zip caught it. The shape this adds to the
list in CLAUDE.md: **a value a fixture derives rather than states**. Arity, array
length, a printed string, a type's name — and now a derived fixture field, which
is invisible to a grep for the field's name because the field's name does not
appear.

### 12.85.8 Why this is the last patch before D7 and not the first after it

D7 repoints each store's load path at its repository. After it, `proposals.json`
stops being the other side of a comparison that runs every launch, and
`duplicateRunTimes` stops having anything to compare.

A key that can absorb one review into another is survivable exactly as long as a
second copy exists and something checks it. That is true today and false after
D7. There was no version of this that could wait.

## 12.74 A plan revision, and the drift it uncovered — patch 329a

Week 2's long run moved from Saturday 8 August to Sunday 9 August; Saturday
became a rest day. The athlete's decision, taken 8 August, having first
declined the lighter option of simply running a day late and letting adherence
record the miss.

### 12.74.1 The finding, which is bigger than the change

`Sub4/plan.json` is a build output — `tools/extract_plan.py` generates it from
`tools/marathon_plan_sub_4hr.html`. So the correct way to revise the plan is to
edit the HTML and regenerate.

**Regenerating from the committed HTML does not reproduce the committed
plan.json.** Checked before touching anything:

    regenerated == committed : False
      sessions identical     : True
      weeks differing        : 33 of 37   (stats only — km and h)

The JSON's week headline figures are HIGHER than the HTML's on 33 weeks. That
is **patch 240's work**: `PlanFocus.volumeExport` exists to dump what the app
itself computes so the stated totals can be written back — *"after which the
stated totals and the derived line are the same arithmetic and cannot drift."*
The JSON received that correction. The HTML never did.

**So a naive regenerate would have silently reverted patch 240 across 33
weeks** — a correction to every week's headline volume, undone by doing the
thing the documentation says to do. `SWITCHOVER.md` §5 warned that two editable
copies is how the Rev 4.1 title-drift class of bug happens; this is that bug,
already present, pointing the other way.

The safe operation, and the one used: edit the HTML, regenerate, then take
**only `sessions`** from the regeneration and keep the committed `weeks`. The
result is provably what the extractor would produce for the half that changed,
and provably unchanged for the half that must not.

A second, smaller drift in the same file: the extractor writes `indent=1` and
the committed `plan.json` is `indent=2`, so a plain regenerate reformats all
8,700 lines and buries the real change in whole-file noise. The shipped file is
written back at `indent=2`, which makes the revision a **21-line diff** —
readable, and therefore reviewable. A build output that cannot be diffed is a
build output nobody checks.

**This leaves the HTML still stale on week stats.** It was stale before and is
stale now; 329a did not make it worse and did not fix it. Fixing it means
running `volumeExport` and pasting 37 rows back into the HTML, which is a job
of its own and is now on the open list.

### 12.74.2 Three uids changed, and one of them was not asked for

`extract_plan.py` derives a session uid from `{week}-{day}-{slug(title)}`, so a
session that moves days changes identity:

| before | after |
|---|---|
| `wk-02-sat-long-run` | gone |
| — | `wk-02-sat-rest-walk` |
| — | `wk-02-sun-long-run` |
| `wk-02-sun-zwift-walk-optional` | `wk-02-sun-zwift-walk-optional-1` |

The last one **was not part of the change**. Sunday now holds two sessions, so
the extractor appends the sequence number to disambiguate — and a session
nobody touched changed identity as a side effect of one being moved next to it.

That is worth naming because uids are the key `user_note`, `match_decision` and
`proposal_change.planSessionUID` all hang off. Nothing orphaned here: neither
session had happened yet, and `match_decision` holds zero rows on the device.
**A revision later in the block would not be so lucky**, and this is the
concrete demonstration that §12.71.5's "a proposal must survive a plan revision
that renumbers the week it names" is not hypothetical.

### 12.74.3 What does not change

- **Week 2's countable total stays 7.** The new Saturday session is rest, and
  rest is excluded (§12.72). Today reads 6/7; a run on Sunday finishes 7/7.
- **The block total stays 208**, same reason.
- **Weekly volume is unchanged** — same sessions, same distances, different
  days, and the week still ends on Sunday.
- **`peakLongRunKm` and the long-run ladder** are untouched; the run is the same
  10 km.

### 12.74.4 The database needs no work, and that is the design paying off

`plan_version` is keyed by a `contentHash` over the plan's bytes (§12.66). A
changed `plan.json` produces a new hash, so the import mints **plan version 4**,
activates it, and keeps the three old versions as history — which is exactly
what that table was built for: *"a note that changes one session's detail must"*
make a new version.

Nothing to migrate, nothing to delete, and every read-back reads the active
version only. The arithmetic that "divides by 3 exactly" at 326 becomes four —
expected, and not a regression.

Also worth stating plainly: **the plan is the prescription, not the record.**
Moving a session does not move any activity, any load figure or any CTL point.
It moves what the app expects, and therefore what adherence is measured
against.

## 12.73 The tab summaries, as functions of their inputs — patch 329

D6c slice 8's extraction. The comparison is 330.

### 12.73.1 The fourth extraction of one shape

| patch | what moved | why |
|---|---|---|
| 310 | `ActivityRoster` | the five rules that turn rows into the list |
| 321 | `MatchResolver` | one day's matching, from inputs not singletons |
| 328 | `SessionTally` | "done of total", once instead of seven times |
| 329 | `TabSummary` | what the Progress and Week tabs add up |

Every one existed for the same reason: **a twin cannot call a derivation that
lives inside a `View` and reads `.shared`.** §12.43, eleven applications, and it
keeps recurring because a derivation with one caller looks like part of that
caller right up until something else has to agree with it.

This is the last one D6c needs.

### 12.73.2 The planned side was already pure — which is why this is small

Read out of the source before any code (groundwork §2.1): `plannedVolume`,
`plannedRunKm(week:)`, `sessions(inWeek:)` and `accumulate` are pure functions
of `plan.sessions` and `weeksByUid`. Nothing touches the network, the disk or
the clock. They could not be **called** with anything else, and that was the
only thing standing between slice 8 and a twin.

So each gained a static form taking its inputs, and the instance method became
a one-line wrapper. No caller changed. `accumulate` became `static` — its body
already called only static members, so that is a keyword rather than a change —
and **one call site moved with it**, `PlanFocus.plannedVolume(week:)`. That
blast radius was established by grepping `Sub4/` **and** `Sub4CoreTests/` before
the edit, not after. §12.72.7 is the record of what assuming costs.

`thePlannedRunKmWrapperAgrees` and `thePlannedVolumeWrapperAgrees` ask the
wrapper and the static the same question over the real bundled plan. A wrapper
that stops agreeing with what it wraps is §12.43's failure with a shorter fuse.

### 12.73.3 The clock is a parameter, and that is the whole slice's hinge

`weekPoints` skips weeks that have not begun — `startKey <= todayKey`.
Groundwork §7 named this as **the single most likely way to get slice 8 wrong**
before any code existed, because a twin applying a different cutoff, or reading
a different clock a second later, compares 34 weeks against 2 and reports 32
phantom differences.

`todayKey` is therefore a parameter, and neither `TabSummary` nor its callers
may reach for `DayKey.key()`. A function that reads the clock cannot be asked
twice with the same answer guaranteed, and a comparison is by definition asking
twice. Same argument `Sub4Import` makes about `now`.

Two tests pin it: one that a future week is skipped, one that moving the
caller's day moves which weeks appear.

### 12.73.4 A closure for the days, not a dictionary

`day:` is `(String) -> MatchResolver.Day` rather than a prepared dictionary.
The view resolves lazily, one key at a time; building a dictionary of every day
of every begun week first would do work the view does not do today, which would
make this a **performance change as well as a move**. This patch is neither.

330 passes a closure backed by the database's days, and will want to know which
keys it was asked for and did not have. That belongs in the twin.

### 12.73.5 The one figure worth a test of its own

`longestRunKm` is a **maximum, not a sum**, which makes it the most sensitive
figure in the slice: a missing activity moves it only if that activity was the
longest. Two weeks of 10 + 10 and 4 + 16 have the same total and different
maxima, and no other figure in slice 8 would notice the difference.
`theLongestRunIsAMaximumNotASum` is that case, stated directly.

The counterpart is `weekActuals`, which counts **extras** — the commute, the
walks, everything the matcher left unmatched. No other comparison in the
project counts them, because every other comparison is about the plan and this
one is about movement. A move that quietly dropped them would leave every other
figure right.

### 12.73.6 Why this ships alone

Same split as 328/329 and the same argument: `ShadowParity`'s own header says
*changing five things to fix one is how a slice patch stops being checkable*.
329 is behaviour-neutral and its device check is one question — do the Progress
and Week tabs still read what they read at 328a. If a number moves, it is a bug
in the extraction, and that is worth knowing before a comparison is layered on
top of it.

## 12.72 "Done of total", once — patch 328

Found by reading the code before writing slice 8's twin, which is §12.44
restated: read the code that produces the number, not the numbers either side
of it.

### 12.72.1 Seven copies, and one of them had been fixed

Counting how many of a week's planned sessions were completed is the most
reproduced derivation in this app:

| where | excludes rest | excludes optional | fixed |
|---|---|---|---|
| `Matcher.adherence(for:)` | yes | **no** | 328 |
| `MatchResolver.adherence(_:)` — extracted at 321 | yes | **no** | 328 |
| `WeekView.totals` — the Week tab card | yes | **no** | 328 |
| `PlanView.PlanRow.progress` — each Plan week row | yes | **no** | 328 |
| `ProgressTabView.points` — the Progress chart | yes | **yes** | — |
| `MatchParity:272` — the Database screen's adherence | yes | **no** | **328a** |
| `Review.swift` `countable` — what the MODEL is told | yes | **no** | **328a** |

**328 said five and shipped five.** The last two are §12.72.7.

The one that excluded them carried the comment, and it named the patch:

> OPTIONAL SESSIONS EXCLUDED, as they are everywhere else. This filter was
> missing until patch 98: the tally counted the plan's 28 optional Zwift rides
> while every distance figure on the same card excluded them, and the info
> sheet said they were not counted.

***"as they are everywhere else"* was true of the file it was written in and
false of the app.** Patch 98 fixed the site it was looking at and left six.

So for any week containing an optional session, the **Week tab and the Progress
tab printed different denominators for the same week** — 230 patches, two
screens, one number the athlete reads as progress.

### 12.72.2 Why nothing caught it, and why no D6c slice would have

Each copy was internally consistent. Every screen agreed with itself. The
divergence was only visible by holding two tabs side by side, which is not a
thing any test does and not a thing a person does often.

And **no shadow-parity slice could have found it.** Every one of the seven
compares the app against the database. This is the app disagreeing with
*itself*, on two screens, about a derivation whose inputs are identical and
already proven green by slices 1, 2 and 5. Shadow parity's whole question —
*would the app produce the same numbers from the database?* — answers "yes" for
both tabs, because both would reproduce their own answer faithfully.

That is worth stating plainly because it bounds what D6c is evidence of:
**shadow parity proves the database can feed the app. It says nothing about
whether the app is right.**

### 12.72.3 One implementation, two entry points, and why not one

`SessionTally` holds the rule: a session counts unless it is **rest** or
**optional**. Optional is `PlanStore.isOptional`, a regex for `opt.` or
`optional` over title and detail joined — how the plan HTML marks the rides.

Two entry points, deliberately:

- `over(_ matches: [Match])` — the four match-shaped callers.
- `over(_ sessions: [Session], isComplete:)` — `Matcher.adherence(for:)`, which
  walks sessions and re-resolves each day per session. That shape is wasteful
  and 321 declined to change it; 328 declines too. What it must not do is
  *disagree*, so the filter is no longer written on its line.

Two shapes is how five copies started, so `bothEntryPointsApplyTheSameRule`
holds them to one answer on the same input. §12.43, eleventh application.

### 12.72.4 The exclusions are counted, not just applied

`restExcluded` and `optionalExcluded` ride on the result. §12.54.2: an exclusion
nobody can see is indistinguishable from an exclusion that stopped being
applied — and this one was half-applied for 230 patches without anybody
noticing, which is the strongest possible argument for making it visible.

`theOptionalMarkerIsRecognisedWhereverItAppears` pins both spellings in both
fields, because a plan revision that reworded the marker would otherwise put 28
sessions back into every denominator silently.

### 12.72.5 What moves on the device

**This is a behaviour change and it was Bruno's decision, taken on 8 August:**
exclude optional everywhere, matching patch 98's finding and the info sheet.

- **Week tab** — a week containing an optional ride shows a smaller
  denominator. `3 of 4` becomes `3 of 3`.
- **Plan tab** — the same, on each week row.
- **Progress tab** — unchanged. It was already correct.
- **`MatchParity`'s adherence line** — moves, and moves *equally on both sides*,
  because both sides call `MatchResolver.adherence`. The device figure was
  `10 of 236`; it should drop by the number of optional sessions in the block
  so far, on both sides, and stay green.

The alternative — making Progress count them too — was rejected: it contradicts
patch 98, the info sheet and every distance figure on the same card.

### 12.72.7 Two more copies, and how the device found them — 328a

328's device campaign made a falsifiable prediction: the Database screen's
adherence line should fall from `10 of 236` to about `10 of 206`, because 236
non-rest sessions minus 30 optional ones is 206.

Everything else landed. Week 2 read **6/7** on the Week tab, the Plan tab and
the Progress tab — three screens that had not agreed before — week 1 stayed
`4/4` because it has no optional session, and the block total read **10/208**,
which is 238 − 30 exactly.

**Adherence read `10 of 236 vs 10 of 236`. Unchanged.**

#### Why

`MatchParity` does not call `MatchResolver.adherence`. It has its own loop:

    // Rest days are excluded exactly as `Matcher.adherence` excludes them.
    if !m.session.isRest {
        counted += 1
        if m.isDone { appDone += 1 }
        if t.isDone { databaseDone += 1 }
    }

A sixth copy, whose comment *described* a delegation it did not perform.
Grepping afterwards for `isRest` rather than `isDone` turned up a seventh, in
`Review.swift` — `countable`, the per-week done-of-total the **model** is told
each month.

#### How the mistake was made, which is the part worth keeping

The copies were counted by grepping `isDone`. `MatchParity:274` appeared in
those results and was **assumed** to be a call site rather than read. That is
§12.44 — *read the code that produces the number, not the numbers either side
of it* — quoted in the same session it was being broken, and applied to
everything except the count of how many copies there were.

The generalisation, because this is now the second time a grep has been trusted
over a read: **a grep tells you where a symbol appears, not what the line does
with it.** Counting call sites from `grep` output is reading tea leaves. If the
number of copies matters, open each one.

#### Why it surfaced in an hour rather than at D7

Because the prediction named a number. *"Adherence should drop"* would have
been satisfied by a screen reading 236 — nothing drops by zero — and the two
survivors would have gone to D7 undetected, with the app's tabs and the app's
own review disagreeing about the plan.

**A device check that cannot be wrong is not a check.** Every campaign from
here states the arithmetic, not the direction.

#### `Review.swift` is the one that mattered

`MatchParity`'s copy is a diagnostic; the review's is not. Left as it was, the
monthly review would have reported **"6 of 8"** for a week the athlete's own
screens call **"6 of 7"**, and the proposal would have been reasoned out over a
plan the athlete does not see. That is worse than either convention on its own,
and it would have gone live on **24 August**.

Not a new decision: *"exclude optional everywhere"* was decided on 8 August,
and 328 under-delivered on it by miscounting the sites.

#### One site deliberately left

`ReviewProposal.swift:335` builds the list of sessions the model may rewrite,
`where !s.isRest`. It is not a denominator — it is a permission — and
forbidding the model to adjust an optional session is a different question with
a different answer. Named here so it is not mistaken for an eighth copy nobody
noticed.

#### And the fix nearly carried the defect

`counts(_:)` as a plain `Bool` predicate would have left `over(_:)` spelling
the two exclusions out underneath it, because `over` must say *which* exclusion
applied in order to count them. `Verdict` is the single statement both are
views of. Caught while writing 328a; recorded because a fix that reintroduces
the pattern it is fixing is the easiest kind to ship.

### 12.72.6 What this does not do

It does not touch `Matcher.adherence`'s wasteful shape, the distance and minute
walks in `WeekView.totals` (a different question, asked in one place), or
slice 8's twin. **The extraction ships alone**, because it changes what two
tabs print and mixing that with a new parity section would make the device
verification ambiguous — `ShadowParity`'s own header: *changing five things to
fix one is how a slice patch stops being checkable.*

Slice 8's comparison is patch 329, built on this.

### 12.71.8 What is left after slice 7

D6c has one slice remaining of its original eight — **8, the tab summaries**.

The record side is now complete: nine repositories, and every table the importer
writes has a reader that compares it against what the app holds.

Three things this slice leaves open, all named rather than closed:

1. **Nothing has been proved against real data.** Both sides of every test are
   built here. On the device today `ProposalStore` holds either nothing or the
   rehearsal record, and until 24 August the read-back's honest output is "no
   review stored yet". The tests are the only evidence this reader works, which
   is exactly the situation groundwork §2.1 said a comparison must not be left
   in — and is unavoidable for this one slice.
2. **`review_evidence_source` stays unmet.** §12.71.3. It is now visible on a
   screen and asserted by a test, which is the most a read-back can do about a
   writer that does not exist.
3. **The confidence contradiction stays unresolved.** §12.71.4.

The one date in this project no patch can bring forward is still 24 August 2026.

## 12.10 The athlete profile, the zones and the resting series

Patch 228. `AthleteConstants` + `AthleteStore` → `athlete_profile`, `hr_zone`,
`resting_month`.

Three scalars, five zone boundaries and a month-keyed series: a few hundred
bytes against 661 activities and 576 weather readings. It is also the
denominator of every training-load figure the app has ever produced. TRIMP
divides by the resting rate for the month, scales by the reserve between rest
and maximum, and raises the result to `sexCoefficient`. Lose this and the 661
activities are all still there and every CTL, ATL and TSB computed from them is
wrong — with no error, no gap, and nothing visibly broken on any chart.

### 12.10.1 One row from two stores

`athlete_profile` is assembled from both stores, which is invisible from either
side alone:

| Column | Source | Field |
|---|---|---|
| `hrMaxOverride` | `AthleteConstants` | `hrMaxOverride` |
| `hrMaxObserved` | `AthleteConstants` | `hrMaxObserved` |
| `hrMaxObservedOnDayKey` | `AthleteConstants` | `hrMaxObservedOn` |
| `hrMaxObservedActivityID` | — | **no field** — see 12.10.3 |
| `restOverride` | `AthleteConstants` | `restOverride` |
| `sexCoefficient` | `AthleteConstants` | `sexCoefficient` |
| `ftpWatts` | `AthleteStore` | `ftp` |
| `updatedUTC` | — | import time |

`AthleteConstants` is computed on this phone from recorded activities;
`AthleteStore` is fetched from Strava. Different lifetimes, different
provenance, and one row — the profile is the athlete, not the source.

`AthleteConstants.version` has no column and needs none: it versions the JSON
encoding, and the database has migrations for that job.

### 12.10.2 The defect: the top zone has no ceiling

`hr_zone.maxBpm` was built NOT NULL. `AthleteStore.HRZone.max` is `Int?`, and
its comment says why:

    let max: Int?           // nil = open-ended top zone

Strava returns the top zone as `min: 168, max: -1`, and the app models that
absence honestly. The schema could not hold it. Z1–Z4 would have imported and
Z5 would have been refused by a NOT NULL constraint — the one zone every hard
session finishes in, and the one `topZoneFloor` reads to sanity-check the
observed maximum. Reported as four successes and one refusal in a list nobody
reads twice.

Migration `2026-08-07-open-top-zone` drops and rebuilds `hr_zone` with `maxBpm`
nullable and the CHECK rewritten as `maxBpm IS NULL OR maxBpm >= minBpm`.
Dropping is safe for the same reason it was for `proposal_change` in §12.7:
nothing in the app has ever written this table, so there is nothing to copy.

**A sentinel was rejected.** 220, or 250, or any number meaning "no ceiling"
would satisfy the column and put a lie in it — every later query asking which
zone contains 205 bpm would get a defensible answer from a value nobody
measured, with no way afterwards to tell a real ceiling from the placeholder.

`ordinal` is Strava's 1-based zone number, not an array index, because every
label in the app reads `Z\(index)`.

This is the fourth mapping written before its importer and the fourth to find
missing or wrong schema: §12.5 (five activity columns), §12.6 (gear
references), §12.7 (five proposal fields), and this. The schema was written
from §8's prose. The prose said "zone boundaries"; the type says one of them is
absent on purpose.

### 12.10.3 A provenance column with no field behind it

`athlete_profile.hrMaxObservedActivityID` references `activity`.
`AthleteConstants` holds `hrMaxObservedName` — a String, because that is what
the Settings row prints. `refreshFromSources` carries `(bpm, day, name)` and
drops the id it had in hand.

Rather than leave the column permanently NULL, the activity is resolved
arithmetically: the one activity on that dayKey whose recorded maximum, rounded
the same way `hrMaxObserved` was rounded, IS the observed maximum. The name
narrows further but cannot decide alone — an activity renamed on Strava since
the maximum was recorded still matches on the two facts that cannot be edited.

If exactly one activity satisfies all three, the column is filled with the
canonical id, resolved through `activity_alias` like weather. If none or
several do, it stays NULL and `profileProvenanceUnresolved` counts it. This is
**not** a refusal: the profile imports either way. The figure is the fact; the
activity is the provenance, and losing the second is not a reason to lose the
first.

Refusing to guess is the point. A provenance column holding a plausible wrong
activity is worse than an empty one, because the empty one is visibly empty.

The honest fix is upstream — `AthleteConstants` should keep the id it already
had. That is a change to a store the training-load path reads, so it is not
made here. `refreshFromSources` recomputes the field, so the day it starts
keeping the id, one refresh repopulates it and this resolution becomes a
fallback for old data.

### 12.10.4 Zones are replaced whole; the resting series is not

Opposite calls, deliberately.

**Zones.** A zone set is one object. If the boundaries move from five zones to
three, upserting by ordinal leaves Z4 and Z5 behind as rows nobody wrote and
nothing deletes, and `zone(forHR:)` answers from a set that never existed.
Deleted and rewritten every run; five rows cost nothing. An import carrying no
zones at all deletes nothing — "not fetched yet" is not "no zones".

**The resting series.** `restByMonth` is recomputed from a rolling window of
Health data, so a month that has aged out of that window is absent from the
store and is still the only figure the app has ever had for it — and every
activity in that month is scored against it. Delete-and-rewrite would silently
rescore the whole history. Upsert by month, never delete.

`resting_month.computedUTC` is set to the import time. The store keeps no such
stamp, so this column currently answers "when did this row arrive" rather than
"when was this figure computed". Recorded here rather than dressed up; it
answers its real question the day the store starts keeping one.

### 12.10.5 Ordering

The profile is imported **last**, after the activities, for the same reason
weather is: `hrMaxObservedActivityID` resolves through `activity_alias`, which
the activity loop writes. A profile imported first would lose its provenance on
every run and give no sign of it — the column would simply be NULL.

### 12.10.6 The bottom zone also starts at zero — amendment to 12.10.2, patch 229

There were **two** defects in `hr_zone`, one at each end of the zone set. The
second was found by the first one's test failing.

`minBpm` was built `NOT NULL CHECK (minBpm > 0)`. The bottom zone starts at
zero. `AthleteStore.HRZone.range` says so in its own comment — *"The bottom
zone starts at zero, and '0–115 bpm' is a range whose lower bound describes
being dead"* — and Strava returns Z1 as `min: 0`.

So the schema would have taken three of five zones: Z1 refused for starting at
zero, Z5 refused for having no ceiling, Z2–Z4 imported. A zone set missing both
ends, which `zone(forHR:)` would then answer from without complaint for every
heart rate below 116 or above 172 — the easy end and the hard end of every
session in the history.

In practice the whole set was refused rather than three-fifths landing, because
`importHRZones` writes inside one savepoint: *"The whole set or none of it.
Half a zone set is not a smaller problem than no zone set — it is a zone set
with a hole, and `zone(forHR:)` would answer confidently from it."* That was a
guess when it was written and is now measured — the test asserting five zones
reported **zero**, not three.

The migration relaxes the constraint to `minBpm >= 0`, not to a nullable
column. A nil ceiling means "no upper bound" and is a distinction `HRZone`
makes; a zero floor is a real number the app holds and prints, and `min` is not
optional there. Symmetry would have been prettier and would have invented a
distinction the type does not have.

**What this says about the method.** Writing the mapping first found the
missing ceiling. It did not find the floor — that took running the test, on
data shaped the way Strava actually sends it. Four rounds of "the mapping
caught it" and this one is the correction: the mapping catches fields that have
nowhere to go, and only real values catch constraints that are wrong about
values that do fit.

### 12.10.7 A migration body was edited after it had run

Patch 236, correcting patch 229.

`2026-08-07-open-top-zone` built `hr_zone` with `minBpm > 0`. Patch 229 changed
that line **in place** to `>= 0`, and §12.10.6 as first written justified it
like this:

> `2026-08-07-open-top-zone`'s body was edited rather than a second migration
> added. The rule is that a migration which has run against a persistent
> database is never touched again — this one had not. […] Checked before
> editing rather than assumed.

The last sentence is false. Nothing was checked. It was **inferred** from the
fact that only the test suite had been run — and the inference was wrong: the
app had already been launched on the device from Xcode while patch 228 was
installed. GRDB recorded the identifier at that launch, so the edited body
never ran again on that phone, or anywhere.

**What that looked like from the outside.** Eight tests asserting the bottom
zone stores a floor of zero, green on every run, for seven consecutive patches.
And on the device, all five zones refused with `CHECK constraint failed:
minBpm > 0`, `hr_zone` at 0 rows, and the import reporting
`Heart-rate zones: 0 of 5`.

**Why the suite could not see it.** Every test builds a fresh in-memory
database from the current source, so it measures the schema the source
*describes*. A device holds the schema its migration history *built*. Those are
the same object only if no migration body has ever been edited after running —
which is exactly what the never-edit rule guarantees, and exactly what had been
given up.

Three corrections:

1. `2026-08-07-open-top-zone` is restored to `minBpm > 0`, the text that
   actually ran, with a comment saying it is wrong on purpose. A body that
   differs from what ran gives two devices two schemas under one identifier.
2. `2026-08-08-zone-floor-zero` drops and recreates `hr_zone` with
   `minBpm >= 0`. Still safe to drop: 0 rows, verified on the health screen
   after the refusal, not assumed.
3. `AthleteImportTests.theStoredSchemaAdmitsAZeroFloor` reads `sqlite_master`
   after the full history has run and asserts the **stored** schema contains
   `minBpm >= 0`. It is the only test in the file that can tell an edited body
   from an honest one, and it exists because nothing else could.

**The rule, restated.** "Has this migration run on a persistent database?" is
not answerable by reasoning about what was run. The device is the only witness.
When the answer matters, the honest move is a new migration — it costs one file
and settles the question, where being wrong costs a silently divergent schema
that a green suite will keep hiding.

## 12.11 The bundled plan — step 3.3, patch 237

`Plan` → `plan`, `plan_version`, `plan_week`, `plan_session`, `plan_exercise`,
plus thirteen tables added by migration `2026-08-09-plan-content`.

### 12.11.1 Why the plan is in the database at all

It ships in the app bundle and is replaced wholesale on update, so storing it
looks redundant. The answer is `plan_version`. A note written in March was
written against the plan as it stood in March; a proposal's reasoning refers to
sessions a later build may renumber, retitle or drop. §12.7 records that
`user_note.planSessionUID` is deliberately NOT a foreign key for exactly this
reason — an FK would delete the reasoning behind every past note the first time
a week was renumbered. Storing each version, hashed and dated, is what turns
that dangling reference into something answerable later.

### 12.11.2 Four things §8's prose had no home for

Read against `Models.swift`, `Fuel.swift` and `Warmup.swift`:

| | |
|---|---|
| `Week.stats` | 37 weeks × 5 figures — the document's own weekly totals |
| `Session.swimDetail` / `strengthDetail` | 82 sessions, **634 blocks** |
| `Plan.fuel` | 3 products, 7 targets, a 5-step ladder, caution, race day |
| `Plan.warmup` | 9 timeline steps, 7 movements, 4 conditions, caution |

The breakdowns are the serious one: without them `plan_session` holds a
one-line summary of a session whose actual prescription lives only in the
bundle.

**Week stats are stored as key/value**, because the set of keys belongs to the
source document rather than to this app. That decision paid immediately — see
§12.11.5.

**Fuel and warm-up get named columns, not a blob.** Both are ordered lists of
short labelled strings, and the lazy shape is one generic table with columns
`c1…c4`. That stores the data and destroys the meaning: a column named `c2`
cannot be read six months later without the code that wrote it.

**Ordinals everywhere**, because order is content. A warm-up timeline out of
order is a different warm-up; a fuelling ladder out of order is wrong advice.
None of these lists carry a key of their own — `Fuel.Product.id` is its name, a
display convenience — so position is the only thing that preserves them.

### 12.11.3 Identity is a content hash

SHA-256 over the plan re-encoded with sorted keys, UNIQUE in the schema.

Not the file bytes: the bundle's whitespace is whatever the extractor emitted,
so a formatting change would mint a version with identical content. Sorted keys
because dictionary order is not stable across encodes, and a hash that changed
on its own would mint a new version on every launch.

Activation **clears before it sets**. `plan_version_one_active` is a unique
partial index on `planID WHERE activatedUTC IS NOT NULL`, so writing the new
timestamp first violates it mid-transaction.

A version's content is replaced, never merged: merging would need an identity
for a fuelling ladder step, and it has none — it is the third row in a list.

### 12.11.4 What the device measured

37 weeks, 260 sessions, 82 breakdowns, 634 blocks, 184 week statistics, 20
exercises, 29 fuel rows, 20 warm-up rows. Three versions now exist — the
original numbers, the corrected ones from patch 238, and the rebuilt ones from
242 — each retained and deactivated, exactly as the design intends.

### 12.11.5 The weekly totals were wrong, and the key/value table is what showed it

22 of 37 weeks stated volume requiring an average cycling speed of **58–79
km/h**. One factor of two applied to one contiguous block reconciled all of
them. Week 20 claimed 190 km against zero rides and 32 km of running.

Eleven weeks write different statistic key names — `rides`, `swims`, `easy`,
`shakeouts` — so anything reading `stats["runs"]` sees nothing for all three
vacation weeks and race week. A column-per-statistic schema would have dropped
every one of those on the floor with nothing to show for it.

The totals were rebuilt twice. First from a regex outside the app, which was
then caught counting "18 km, last 5 km @MP" as 23 km and including optional
rides the app excludes. Then from `PlanStore.plannedVolume` itself, via a
`Copy plan volumes` diagnostic, so the stated figures and the derived line under
them are now the same arithmetic. Implied cycling speed across every week
carrying a ride is 29.3–29.8 km/h.

The logged prologue weeks were left alone: they describe what happened in July,
and a planned-volume function correctly returns nothing for them.

Still true, and named rather than smoothed over: ten weeks carry
`runExact = 0`, meaning a run is written as a duration and the total is a lower
bound. And `extract_plan.py` regenerates `plan.json`, so the correction is
overwritten the next time it runs — the factor of two lives in the source
document.

### 12.11.6 PlanFocus — the header asks the plan what it is

Patch 239. The week header printed "125 km all sports", which adds running
kilometres to cycling kilometres to swimming kilometres; those are three
quantities and their sum is not one.

`PlanFocus` derives the answer from the plan's own content: share of committed
endurance sessions per discipline, ≥30% leads. Sub-4 is 60/20/20 and running
leads alone; an even triathlon block is 33/33/33 and all three lead; a cycling
block leads in hours rather than kilometres. Derived rather than declared, so
nothing in `plan.json` or the extractor changes and nothing goes stale.

Session counts rather than time, because converting run kilometres, ride hours
and swim metres to a common unit needs three assumed rates — the exact mixing
this exists to stop. The 30% line is a judgement, named as one, and tested at
both edges.

## 12.12 Traces and details — step 3.3, patches 243–245

`ActivityStreams` → `recording` + `recording_sample`. `ActivityDetail` →
`activity_detail`, `activity_split`, `activity_lap`, `activity_best_effort`,
added by migration `2026-08-10-activity-detail`.

§12.4 said "`details/` and `streams/` → `recording` + `recording_sample`". That
was wrong: `recording` holds the trace and nothing else. `ActivityDetail` — the
splits, the laps, the best efforts, the device name, the route polyline, the
calories — had no table anywhere in the schema. The splits matter most:
`closingPace(km:)` reads them to answer the question the plan actually asks,
"last 4 km at marathon pace", and there was nowhere to put one.

Sixth mapping written before its importer, sixth to find missing schema.

### 12.12.1 What the first real run measured

| | |
|---|---|
| Traces | 387, rising to 415 as the backfill continued |
| Samples | 115,923, then 124,323 |
| Samples per trace | 299.5 — `ActivityStreams.targetSamples` is 300 |
| Details | 378 → 420 |
| Splits / laps / efforts | 5,428 / 1,483 / 537 |
| Database | 1.6 MB → 23.8 MB |

**This settles §9 question 3.** The benchmark measured the normalised
one-row-per-sample shape at ×2.09 the storage of chunked, projected against a
10,000-activity design target — three million rows. The real history is 661
activities, of which 387 carry a trace; even if every activity eventually gets
one, that is roughly 200,000 samples and about 35 MB. Chunked would save some
ten megabytes. The provisional shape stands, and now on measurement rather than
on projection.

The estimate that preceded this was wrong by six-fold — "about sixty traces"
came from reading Load diagnostics' `Trace / avg / power = 60 / 183 / 22`, which
counts sessions *scored* from a trace, not traces held.

### 12.12.2 Idempotency, proven on 115,923 rows

A trace is replaced whole or skipped whole: an existing recording whose
`fetchedUTC` matches is left alone, and one that differs is deleted and
rewritten with `ON DELETE CASCADE` clearing its samples. Merging sample by
sample would need an identity for a sample, and it has none — it is the four
hundredth reading in a list.

The second import proved it without needing the report: `recording` rose by 28
and `recording_sample` by exactly 8,400. 8,400 ÷ 28 = 300. Not one of the 387
existing traces was rewritten.

### 12.12.3 The rule the schema cannot state

`recording_sample.distanceM >= 0` is a column CHECK. "Never decreasing" is not
expressible as one, so it lives in the importer, is checked before anything is
written, and refuses the recording whole with the offending ordinal named. A
trace whose x axis doubles back draws a chart that lies, and every pace read
between those two points is nonsense.

### 12.12.4 Zero bpm is an absent reading — patch 244

Strava sends `average_heartrate: 0` for a lap it has no reading for.
`StravaDetailDTO` passed it through unchanged, the schema refused it — correctly;
zero bpm is a strap that was not worn — and because a detail is written inside
one savepoint, **twelve details rolled back entire, splits and all, over one lap
each**.

The savepoint isolation worked exactly as designed. It isolated the wrong-sized
thing, because the value should never have reached the column.

Converted at both boundaries, and the duplication is deliberate:
`StravaDetailDTO` stops new zeros arriving and fixes the display, where those
laps had been rendering as 0 bpm; the importer stops the 378 details **already
cached in `details.json`** from failing, since they are not re-fetched.

A test that asserted the old behaviour — a zero heart rate being refused — had
to be repointed at a negative distance, which no boundary coerces. Worth
recording: a test written against a defect passes until the defect is fixed, and
then reads as a regression.

### 12.12.5 The one refusal that stays — a decision, not an outstanding defect

Activity `18883849470` is refused on every import by
`elapsedSeconds <= 604800`, and this is expected. It is not a bug and it is not
waiting to be fixed.

August 2025, Romania. 199.2 km, 2,403 m of climbing, **694,865 seconds elapsed —
8.04 days** — against 70,153 seconds moving. No heart rate. 62.5 W average,
estimated rather than measured. Maximum speed 30.6 m/s, which is 110 km/h.

The segment efforts are what settle it. Thirty-five matched around the
Transfăgărășan and Poiana Mărului at sustained 55–66 km/h over tens of
kilometres — 29.6 km at 63 km/h, 20.8 km at 57 km/h, a "fastest 10k" at
85 km/h. Those are car speeds. The recording contains some real riding, some
road transfer, and eight days of a holiday with the device never stopped.

It survived this long because nothing else looks at elapsed time. The
speed-contradiction rule catches impossibly *fast* averages — 322, 620 and
199 km/h on three November rides — and this one averages 1.03 km/h across its
elapsed span, far too slow to trip it. `ignoredActivities` holds only the
18 December swim. The database is the first thing that ever asked the question.

**The athlete's decision, 4 August 2026: leave it refused.** The consequence was
stated rather than hidden — the app keeps counting 199 km and 2,403 m into its
own volume totals while the database declines the row, so the two disagree
permanently on that one activity. It contributes no training load either way:
no heart rate, and the estimated power is refused by `PowerLoad`.

So `Refused: 1` on the import screen is the expected steady state. A second
entry appearing there is news; this one is not.

### 12.12.6 That decision was reversed a day later — patch 256

**Not because it was wrong, but because "leave it refused" turned out to mean
more than it said.** Living with it for one day showed the consequence had three
heads rather than one:

- Every import printed a raw SQLite CHECK failure on the health screen — twelve
  lines of red SQL on the one screen whose job is to show faults.
- A refused activity gets no `activity_alias`, so its trace and its detail could
  not resolve either. Both reported "with no activity". One decision, three
  lines, all reading as gaps.
- And the paragraph above only works if a person reads that list closely on
  every run. A list that always has one item in it is a list nobody reads, which
  is the opposite of what "a second entry appearing there is news" needs.

**The deciding argument was the semantic verifier**, whose whole job is that the
database and the stores agree. A permanent, known disagreement would have meant
an exception list on the day it was born.

So the activity is now excluded in BOTH places: it is the second entry in
`DataCorrections.ignoredActivities`, with the evidence beside it, which drops it
from `ActivityStore` and means the importer never offers it. Its trace and its
detail are skipped by id and counted as `recordingsIgnored` / `detailsIgnored`
— named on screen as "for an excluded recording", because a recording the app
throws away without saying so is indistinguishable from one it failed to fetch.

**What it costs:** 199.2 km and 2,403 m leave the app's August 2025 volume. That
figure was never real. **What it buys:** `Refused` returns to zero, so the next
entry there is news; the two "with no activity" counts return to zero, so those
are news too; and the verifier is born without an exception.

Worth recording as a shape rather than an incident: **a decision to tolerate
something is a decision about what it will look like every day, and that part is
easy to leave unmade.** The 4 August entry decided the data question and left
the presentation to whatever happened to fall out. What fell out was three
false alarms.

### 12.12.7 There were four — patch 257

The section above counts three consequences and 256 fixed three. The count was
wrong. The same recording also has a **weather reading**, and weather resolves
through `activity_alias` exactly as the trace and the detail do, so it went on
landing in `weatherUnmatched` — one grey line still reporting "with no
activity" about a recording the app had already ruled on.

**That state is worse than the one 256 started from.** Four lines all saying
the same thing is at least consistent; three at zero and one at one teaches the
reader that some of these numbers are furniture, and a screen whose numbers are
furniture is not a health screen. The whole argument of §12.12.6 — "the next
entry there is news" — needs every one of them at zero, not most.

So `weatherIgnored` joins `recordingsIgnored` and `detailsIgnored`, counted
before the reading is counted as seen, and shown as "weather for an excluded
recording". `weatherUnmatched` now means what its name says.

**The miss is worth more than the fix.** It was not a reasoning error — the
reasoning in §12.12.6 was right and applied unchanged here. It was a *sweep*
error: the two consequences that had just been on screen got fixed, and the
third sharing the identical mechanism was never looked for. The mechanism is
"resolves through the alias", and it is greppable. The general form:

> When a decision has consequences, enumerate them from the MECHANISM, not from
> the symptoms you happen to have seen. Symptoms are whichever ones were
> visible on the day; the mechanism is all of them.

The same rule would also have caught this at 226, where the header of
`Sub4Import+Weather.swift` wrote "the expected count is one" and froze a known
defect into a documented constant. **A number a comment excuses is a number
nobody will ever question again** — the excuse is what makes it permanent.

**Patch 258, the isolation the same three lines needed.** `DataCorrections` is
main-actor isolated because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` isolates
everything that does not say otherwise, and all three `isIgnored(id:)` calls sit
in `nonisolated` importers. Three warnings, and 472 then 474 tests passed over
the top of them — because a warning is not a test failure, and this project's
build is loud enough that three more lines scroll past.

The table is a compile-time `[String: String]` that nothing mutates. There was
never a race for an actor to prevent; the isolation was inherited from a build
setting, not chosen. So both the table and the by-id lookup are `nonisolated`
now, and `ExcludedRecordingNonisolationTests` — a suite that is deliberately NOT
`@MainActor` — calls it. That test does not assert a value: it asserts that the
file still compiles from a nonisolated context, which is the only thing a
warning-only defect can be held to.

Which is the general shape: **a defect the compiler reports as a warning needs a
test, because nothing else in the pipeline will ever stop for it.**

---

## 12.13 D0 closed — freeze and capture, patch 246

D0 is the first stage of the database rollout and the only one still open when
the rest of the ladder had reached D5. This section closes it, and it opens with
a correction.

### 12.13.1 The handoff was wrong about what was outstanding

`HANDOFF-2026-08-05.md` stated that D0 was "not done — the duplicate `plan.json`
question was never resolved". Both halves are wrong.

§9 of this document answers all six of 3.1's open questions and is dated 3
August. §9.1 puts cloud synchronisation explicitly out of scope for v1 — item 6.
§9.2 designates `Sub4/plan.json` as the only versioned seed — item 7. §10 ticks
off 3.1's four acceptance criteria with the patches that satisfied each. D0's
decisions were made, recorded, and then forgotten by the person who wrote them
down.

The lesson is not "read the ADR first", which is too easy to say and impossible
to act on across an 86,000-byte document. It is that a rollout stage needs a
status that lives somewhere a reader can see it without reconstructing it, and
that reconstructing a stage's status from prose is how a session ends up
proposing work that was finished a week earlier.

What was genuinely open is smaller and more interesting than what was claimed.

### 12.13.2 The frozen hash had drifted, and nothing noticed

§9.2 records the seed as 243,194 bytes, SHA-256 beginning `e93bf5ea`, and states
the reason for recording it: "so a future divergence is detectable rather than
arguable."

The seed on disk is **279,078 bytes, `a4087101cad4f61e…`**. It has been since
commit `13782b8` — patches 237 through 242 — and the ADR went on stating the old
figures for three weeks.

The cause is not a mistake, it is two deliberate corrections: patch 238 fixed 22
weeks whose stated volume implied 58–79 km/h on a bicycle, and patch 242 rebuilt
the weekly totals from `PlanStore.plannedVolume` so the stated and derived
figures are the same arithmetic. Both were right. Neither updated §9.2.

**A recorded hash that nothing checks is a comment.** `PlanSeedTests` now asserts
the bundle's bytes and digest against the recorded values, so the next
divergence fails a build instead of surviving an audit. §9.2 is amended to the
current figures, and the superseded `7d83ee7d` digest is recorded in the test as
well — if the pre-August root copy ever finds its way back into the bundle it
should be recognised, not investigated from scratch.

This is the fifth instance of the same pattern in two weeks: **a control that
reports work it did not do is worse than one that fails.** A hash written into
prose is such a control.

### 12.13.3 The seed had no provenance on any machine

§12.11.5 states that "`extract_plan.py` regenerates `plan.json`, so the
correction is overwritten the next time it runs."

Neither `extract_plan.py` nor `marathon_plan_sub_4hr.html` existed anywhere
under `~/Documents/Developer`. The claim was unfalsifiable on the athlete's own
hardware: there was nothing to run, and nothing to inspect. The seed that the
entire plan tab, the workout parser, the fuelling screen and the warm-up screen
are built on had an origin nobody could reach.

Both are now committed under `tools/` at the repository root — outside `Sub4/`,
because the project uses file-system-synchronized groups and a `.py` or `.html`
inside the target folder would be copied into the app bundle.

**The athlete's decision, 5 August 2026: archive, do not maintain.** `plan.json`
is authoritative and hand-corrected; the extractor is history. `tools/README.md`
states in its second paragraph that running it reverts patches 238 and 242,
because the alternative — correcting 22 weeks of totals inside the training
document itself — is a separate job on a document that is read outside this app.

The rejected alternatives are worth naming. Fixing the HTML would make the
pipeline reproducible end to end and is the better long-term answer; it was not
chosen today because it blocks D0 on a document edit. Not versioning the
extractor at all would have left §12.11.5 asserting something no one could
check.

### 12.13.4 There were no fixtures — none, of any kind

D0's exit gate names fixtures. D3's exit gate is entirely about them: "Every
known empty/corrupt/partial/duplicate/interrupted fixture produces the expected
result."

There were zero fixture files in the repository. Every test in this project
builds its data in Swift and hands it to the importer as values. That tests the
importer and says nothing about the bytes on disk — and the bytes on disk are
the whole subject of a migration.

`LegacyFixtures.swift` captures ten legacy inputs — `notes.json`,
`proposals.json`, `activities.json`, `athlete.json`, `weather.json`,
`constants.json`, `details/<id>.json`, `streams/<id>.json`, and the two
monolithic files the per-activity split replaced, `details.json` and
`streams.json` — each as the smallest file its store's decoder accepts.

**It captured seven on the first run, and the coverage test found the other
three.** `theCorpusCoversTheInventory` walks `DataLifecycle.entries` and fails
on any declared path without a fixture; the first time it ran it named
`constants.json`, `details.json` and `streams.json`. That is worth recording for
what it says about the method rather than about the miss: the corpus was
assembled by reading the stores, and reading found seven of ten. The inventory
knew about all ten because `DataLifecycle` is maintained as a product surface —
the delete-my-data screen is built from it — and a test that asks the inventory
rather than the author is the only reason the gap closed in one build instead of
being discovered by patch 249.

The two monoliths are the more serious omission of the three. `DetailStore.load()`
still reads them, they exist on every device that upgraded through the split,
and `AppSupportItem.legacyFile` exists in the inventory specifically because
nothing has ever deleted them. A migration that skipped them would leave four
app versions of detail history behind. Required fields only, deliberately: a fixture with every
optional filled in cannot tell you whether the decoder still treats the
optionals as optional, which is the shape most likely to break when a property
loses its `?`.

Ten damage classes are named and generated: `valid`, `absent`, `empty`,
`whitespace`, `truncated`, `corrupt`, `notJSON`, `wrongDateEncoding`,
`keyMismatch`, `duplicate`. `truncated` is a prefix of the whole file, so it is
recognisably the right file and still undecodable; `corrupt` keeps its length,
so a classifier cannot tell the two apart by size alone — which would make the
test easier than the problem.

They are Swift literals, not files. The synchronized groups would decide for
themselves whether a `.json` in `Sub4CoreTests/` is a resource, and a fixture
that silently fails to copy reads as a fixture that passes.

**Two tests assert today's defect on purpose,** with the reason in the file
header. Empty, truncated, corrupt, not-JSON and wrongly-dated all fail
identically through the same `try?` into the same empty store; a key mismatch
and a duplicate decode cleanly and are invisible. When patch 248 lands those
tests fail, and the diff between what they say now and what they say then is the
honest measure of what 248 bought. §12.12.4 already cost this project one
repointed test written against a defect nobody remembered; this time the note is
in the file.

### 12.13.5 Two findings the corpus produced before the importer was written

**`athlete.json` has no decodable type outside its own store.**
`AthleteStore.Cache` is `private`, so `@testable import` does not reach it and
neither will a file-level decoder. This is why `Sub4Import+Athlete` reads the
live store rather than the file, and it is a concrete obstacle to migration
contract item 3: patch 248 needs a non-private mirror of that shape before it
can read `athlete.json` as bytes at all. Recorded as a test so it is discovered
here rather than halfway through writing 248.

**`activities.json` has no date strategy to get wrong.** Contract item 4 splits
the stores by date encoding — ISO-8601 for notes and proposals, the default
numeric encoding for the rest. `Activity` stores its instants as strings
(`startLocal`, `startUTC`) and holds no `Date` at all, so it belongs to neither
group. The corpus says so explicitly rather than filing it under "numeric" and
leaving a future reader to discover the exception.

Seventh mapping written before its importer; seventh to find something.

### 12.13.6 What D0 does not cover, and where it goes

The protected snapshot — contract item 3, "copy every legacy input unchanged
into a dated protected snapshot, record path, byte count and SHA-256 before
decoding" — is **not** part of D0 and remains the most important missing piece
in the project. It is patch 246 in the D3 plan and is now patch 247. Two
reinstalls destroyed `notes.json`, `weather.json`, the UserDefaults gates and
HealthKit authorisation while this was outstanding.

D0's exit gate reads "Clean baseline, manifest, fixtures, decisions approved".
The baseline is clean — the working tree has no uncommitted changes and the
stale duplicates were moved out of the source tree on 3 August into
`sub4-backups/stale-root-duplicates-2026-08-03/`. §9.2 says that copy was
"deleted"; it was moved, and the wording is amended, because a backup that the
document calls a deletion is exactly the kind of small untruth that makes a
later reader distrust the parts that matter. The manifest is
`sub4-manifest-2026-08-03.txt` beside the pre-migration archive. The fixtures
are this patch. The decisions are §9, §12.13.3 and this section.
