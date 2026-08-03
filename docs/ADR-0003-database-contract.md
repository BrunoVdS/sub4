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
actually renders. 243,194 bytes, SHA-256 beginning `e93bf5ea`.

**Consequences:**

- The root copy `sub4/plan.json` (218,499 bytes, `7d83ee7d`, no `fuel`, no
  `warmup`, `meta.source` differing by one character) is **deleted**, not kept
  "just in case". Two files that look like the plan is how the wrong one gets
  loaded eventually.
- `Sub4-complete/Sub4/plan.json` is byte-identical to the root copy and goes
  with it.
- 3.4 imports by content hash, so the seed's identity is its SHA-256 rather than
  its path. Re-importing the same hash creates no second version.
- The ADR records the hash so a future divergence is detectable rather than
  arguable.

### 9.3 Recordings are NORMALIZED rows, pending benchmark

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

---

## 10. Acceptance criteria for 3.1

- [x] This ADR is approved or amended, with all six questions answered — 3 Aug 2026.
- [x] Every table in §8 maps to a domain concept, not a transport DTO — for the
      five tables of groups 1 and 3, shipped in patch 195. Groups 2 and 4–10 are
      3.2b and this box reopens for them.
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

**Two things this step changed about the ADR itself**, both because writing the
code exposed them:

1. §7's CHECK-constraint claim was wrong — see the correction there.
2. Seeding `source` from `DataSource.allCases` was written, then removed. A
   migration body is history: one that reads a live Swift enum silently gives a
   fresh install a different database from an existing one the moment a case is
   added, under one migration identifier. The lists are frozen in the migration
   and coupled to the enums by test instead. Worth stating in the ADR because
   the same temptation will return at every later migration.
