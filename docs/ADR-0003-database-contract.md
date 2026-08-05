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
