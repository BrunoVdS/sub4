# `RecordingRepository` — groundwork and decisions

Complete. Everything below was read out of the source on 6 August; nothing
here needs re-deriving. `ActivityDetailRepository` (§12.37) is the shape to
copy.

---

## 1. The types

`ActivityStreams` — `nonisolated struct`, ten stored properties. Parallel
arrays, all index-aligned to `distanceM`, which is the only non-optional one
and defines the length.

| `ActivityStreams` | `recording_sample` column |
|---|---|
| `activityId` | via `activity_source_record.externalID` |
| `distanceM: [Double]` | `distanceM` — NOT NULL, `>= 0` |
| `heartRate: [Double]?` | `heartRate` |
| `speed: [Double]?` | **`speedMS`** |
| `altitude: [Double]?` | **`altitudeM`** |
| `grade: [Double]?` | **`gradePercent`** |
| `power: [Double]?` | **`watts`** |
| `latitude: [Double]?` | `latitude` |
| `longitude: [Double]?` | `longitude` |
| `fetched: Date` | `recording.fetchedUTC` |

Four renames, same family as before. `power` → `watts` is the one most likely
to be typed straight through.

`recording` — `id`, `activityID`, `sourceID`, `fetchedUTC`, **`sampleCount`**,
unique on `(activityID, sourceID)`.

`recording_sample` — composite primary key `(recordingID, ordinal)`. No `id`
column, unlike every other child table.

Held by `DetailStore.shared.streams: [String: ActivityStreams]`, 645 recordings
and 192,954 samples on the device.

---

## 2. `ordinal` is the array position — a third meaning

From the importer: `for i in 0..<s.count { … arguments: [id, i, …] }`.

So across the four child tables the project now has three conventions:

```
activity_split         ordinal = split.index    domain value, 1-based
activity_lap           ordinal = lap.index      domain value
activity_best_effort   ordinal = i              array position, 0-based
recording_sample       ordinal = i              array position, 0-based
```

`recording_sample` behaves like best efforts: **order by it, then discard it.**
It never enters `ActivityStreams`, which has no per-sample identity at all.

---

## 3. The reconstruction rule, and the one thing it cannot recover

The importer writes every column for every sample, using `at(array, i)` —
which yields `nil` when the array is absent **or when `i` is past its end**.

So on the way back:

- **`distanceM`** — always present, ordered by `ordinal`, defines the length.
- **each optional stream** — if *every* sample is NULL, the array was `nil`;
  otherwise it is an array of the same length as `distanceM`.

**The ambiguity, stated rather than discovered.** A stream that was present but
SHORTER than `distanceM` is written with trailing NULLs, and on the way back
those NULLs are indistinguishable from a stream that ran the full length with
missing values at the end. The original length is not recoverable.

**Decided:** reconstruct optional streams at `distanceM.count`, and let the
round-trip report the difference if a shorter one exists. Do not guess at
trimming. If the read-back shows length differences, that is a real finding
about Strava's payloads and belongs in the ADR as a measurement, not as a
silently-applied heuristic.

A `[Double]?` cannot hold a per-element nil, so a NULL inside a present stream
has to become *something*. **Decided: `0`**, matching what `has(_:)` already
assumes — it tests `contains { $0 > 0 }`, so a zero is already the app's
representation of "nothing here". Recorded because it is a real lossy step and
the comparison will surface it.

---

## 4. The comparison: walk it, with `sampleCount` as the gate

**Decided: walk every sample.** Not a checksum.

A checksum tells you *that* something differs and nothing about *which sample
or which stream* — and the whole value of the last two read-backs was the field
tally: `fetched 320` was a diagnosis on sight, and it would have been a red
tick under a checksum.

The cost is acceptable because this is a diagnostic run on demand, not a hot
path, and it is one pass over 192,954 rows already in memory once loaded.

**`sampleCount` is the cheap gate.** `recording.sampleCount` is stored, so
compare it to `streams.count` first: a length mismatch is reported as a length
mismatch and the per-sample walk is skipped for that recording. Otherwise a
single missing sample reports as thousands of index differences and buries
everything else in the tally.

**Report by stream and by band, not by index.** `distanceM[47_812]` names
nothing a person can act on. Suggested field names:

```
sampleCount                     the lengths disagree
heartRate present / absent      one side has the stream and the other does not
heartRate[3 of 1204]            three samples differ, out of this many
```

That last form is the analogue of `splits[index: 7]` at a scale where naming
each one is useless — the count is the finding, the stream name is the cause.

---

## 5. Scale

645 recordings, 192,954 samples, ~300 per recording (`targetSamples = 300`).

Loading all of them as `ActivityStreams` at once is roughly 192,954 × 8 doubles
≈ 12 MB of `Double` plus array overhead. Acceptable, but **the read-back should
stream per recording rather than materialising all 645 first** — build one,
compare it, discard it, keep only the report. `ActivityDetailRepository.all`
materialises everything because 668 details is nothing; this one should not
copy that.

That means `RecordingRepository` wants a third entry point the other two did
not need: something like `forEach(_ db:) -> (each recording, in turn)`, or the
comparison taking a closure. Worth deciding while writing rather than
retrofitting.

---

## 6. Scope

**In:** `RecordingLoad` with the same five-case honesty, `.recording(_:storeID:)`,
a per-recording streaming read for the comparison, `RecordingRoundTrip` with
`sampleCount` gating and per-stream reporting, tests, a third read-back row.

**Out:** nothing else. This is the last of the three big readers.

**The `skipped` case:** a `recording` row whose activity has no source record
— same as detail. Skip and count.

---

## 7. Nothing is unknown

`at(_:_:)` was the last open item and it is confirmed:

```swift
private nonisolated static func at(_ series: [Double]?, _ i: Int) -> Double? {
    guard let series, i < series.count else { return nil }
    return series[i]
}
```

Exactly as §3 assumes: `nil` for an absent array and `nil` past the end, with
no padding and no default. The reconstruction rule stands as written, and the
short-stream ambiguity is real rather than hypothetical.

**This groundwork is complete.** Every column, every rename, both ordinal
conventions, the reconstruction rule, the lossy step, the comparison strategy
and the memory shape are settled. The next session writes the code.
