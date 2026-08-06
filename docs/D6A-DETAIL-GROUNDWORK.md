# `ActivityDetailRepository` — groundwork

For the patch after 290. Everything below was read out of the source on
6 August; none of it needs re-deriving. `ActivityRepository` (§12.35) is the
shape to copy — same `Load` outcome, same round-trip test, same read-back row.

---

## 1. Why this one is bigger than `Activity`

`Activity` was one table and twenty scalar fields. `ActivityDetail` is **four
tables and three nested arrays**, and the arrays are where the traps are.

| store | table | rows on device |
|---|---|---|
| `ActivityDetail` | `activity_detail` | 668 |
| `.splits: [Split]` | `activity_split` | 7,990 |
| `.laps: [Lap]` | `activity_lap` | 2,344 |
| `.bestEfforts: [BestEffort]` | `activity_best_effort` | 755 |

Held by `DetailStore.shared.details: [String: ActivityDetail]`, keyed by the
Strava activity id.

---

## 2. The scalar mapping

`activity_detail` is nearly one-to-one, which is the easy half.

| `ActivityDetail` | column | note |
|---|---|---|
| `activityId` | — | **not a column.** The row keys on `activityID`, which is the CANONICAL id. Strava's comes back through `activity_source_record.externalID`, exactly as in `ActivityRepository` |
| `calories` | `calories` | |
| `descriptionText` | `descriptionText` | |
| `averageCadence` | `averageCadence` | |
| `averageWatts` | `averageWatts` | |
| `maxWatts` | `maxWatts` | |
| `deviceName` | `deviceName` | |
| `polyline` | `polyline` | |
| `fetched: Date` | `fetchedUTC: String` | **a type change.** Everything else round-trips as itself; this is `Date` ↔ ISO-8601 text, and the comparison has to decide what "equal" means to sub-second precision |

`activity_detail` also carries `sourceID` and a `uniqueKey(["activityID",
"sourceID"])`, so a detail is per-source. The query joins on
`sourceID = 'strava'` like the activity one does.

---

## 3. The three arrays, and the trap

All three tables carry `ordinal`, `NOT NULL`, `>= 0`, unique per parent. **It
does not mean the same thing in all three.**

```
activity_split      ordinal = split.index     ← a DOMAIN value, 1-based
activity_lap        ordinal = lap.index       ← a DOMAIN value
activity_best_effort ordinal = i              ← the ARRAY POSITION, 0-based
```

Read from `Sub4Import+Recording.swift`: splits and laps pass `split.index` and
`lap.index`; best efforts pass the enumeration index.

So reconstituting them differs:

- **`Split` and `Lap`** — `index` comes FROM `ordinal`. Order by it and put it
  in the struct.
- **`BestEffort`** — has no `index` property at all; its identity is `name`.
  `ordinal` exists only to preserve array order, so order by it and **do not
  put it anywhere**.

Getting this backwards produces splits numbered from zero, or best efforts in
whatever order SQLite felt like. Neither would fail a count comparison, which
is precisely §12.16's warning.

### Column names inside the arrays

| domain | `activity_split` | `activity_lap` |
|---|---|---|
| `distanceM` | `distanceM` | `distanceM` |
| `movingTime` | `movingSeconds` | `movingSeconds` |
| `elapsedTime` | `elapsedSeconds` | — *(Lap has no elapsedTime)* |
| `elevationDiff` | `elevationDiffM` | — |
| `averageHR` | `averageHeartrate` | `averageHeartrate` |

`activity_best_effort` is `name` and `seconds`, with `CHECK (seconds > 0)`.

---

## 4. The known lossy edge, and what to do about it

The importer writes `positiveOrNil(lap.averageHR)` — a non-positive heart rate
becomes `NULL`. So a lap the store holds with `averageHR == 0` comes back
`nil`.

**Report it, do not paper over it.** If the read-back shows differences on
`averageHR`, that is the importer's deliberate normalisation surfacing, and the
right response is to record it as an intended difference — not to teach the
reader to invent a zero. The same applies to any split with a zero heart rate.

`CHECK (seconds > 0)` on best efforts means an effort of zero seconds was never
stored at all; it would show as a **missing element**, not a differing one.

---

## 5. What the round trip has to compare

`ActivityRoundTrip` compared nineteen scalars. This needs three levels:

1. **the detail's own eight scalars** — same shape as before
2. **array lengths** — a missing split is not a differing split, exactly as
   `missing` is not `differences` in 290
3. **element by element, by ordinal** — and the field name reported has to say
   which array and which index: `splits[7].movingTime`, not `movingTime`

That last point is the whole value. "12 details differ" is useless;
"12 differ, all on `splits[*].averageHR`" is one known cause.

Suggested shape, mirroring 290:

```swift
struct Difference { let id: String; let fields: [String] }
// fields like "calories", "splits.count", "splits[3].elevationDiff"
```

---

## 6. Scope for the patch

**In:** `ActivityDetailRepository.all(_:)` and `.detail(_:storeID:)`,
`DetailLoad` with the same five-case honesty as `ActivityLoad`,
`ActivityDetailRoundTrip`, tests mirroring `ActivityRepositoryTests`, and a
second read-back row on the Database screen.

**Out:** recordings and samples. `recording_sample` is 192,954 rows and needs
its own decision about whether the comparison walks samples or compares
counts and a checksum. It is a separate patch and probably a separate
conversation.

**The `skipped` case:** what makes a detail row unreadable? Unlike `activity`,
every column it needs is either nullable in both places or NOT NULL in both.
The candidate is a detail whose `activityID` has no `activity_source_record`
for `strava` — orphaned by a source change. Worth an explicit decision rather
than discovering it: skip and count, same as before.

---

## 7. Two things to check first, before writing the reader

Neither was resolved on 6 August, and both change the code:

1. **Does `Date` ↔ `fetchedUTC` round-trip exactly?** `iso8601` in the
   importer and whatever the reader parses with have to agree to the same
   precision, or all 668 details differ on `fetched` and the read-back is
   noise. Check `Sub4Import.iso8601` and pick the matching parser.
2. **Are `splits`, `laps` and `bestEfforts` stored in the store's own order?**
   The tables preserve an ordinal, but if `DetailStore` holds them in an order
   that is not the one the importer enumerated, the comparison needs to sort
   both sides before comparing rather than assuming.
