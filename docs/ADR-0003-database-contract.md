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

37 weeks, 260 sessions, 20 exercises, and the `fuel` and `warmup` blocks the app
actually renders. **279,078 bytes, SHA-256 `a4087101cad4f61e13755aa62dc1003ca09034b04072570dc198257a4809e502`.**

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
