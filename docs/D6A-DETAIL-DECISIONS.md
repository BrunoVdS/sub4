# `ActivityDetailRepository` — the three decisions

Settles §7 of `D6A-DETAIL-GROUNDWORK.md`. Decided 6 August 2026, at patch 290.
Read both before writing the reader; this one supersedes §7 and amends §5.

---

## 1. `fetched: Date` ↔ `fetchedUTC: String` — exact, with a rounding guard

`Sub4Import.iso8601` is `ISO8601DateFormatter` with `.withInternetDateTime`
and **no fractional seconds** — `2026-07-28T16:02:00Z`. `ActivityDetail.fetched`
was itself decoded from a second-precision string in the JSON, so there is no
sub-second component to lose. **It round-trips.**

**Decided:**

- the reader parses with the identical `ISO8601DateFormatter` configuration,
  written **beside** the writer in the same file so the two cannot drift apart
- the comparison rounds both sides to the second before comparing

The rounding is not defensive clutter. The database is second-precision *by
construction*, so a comparison demanding exactness asks it for something it
was never designed to hold. The case it protects is real: a `fetched` set from
`Date()` in memory and compared before any save round-trip carries sub-second
precision that no column can store.

---

## 2. Array ordering — the question is removed, not answered

**Match elements by identity, never by position.**

| array | matched on |
|---|---|
| `Split` | `index` |
| `Lap` | `index` |
| `BestEffort` | `name` — already its `id` |

Then the order of either side is irrelevant and §7's ordering question stops
existing. It still matters for the **reader** — `ORDER BY ordinal` is how the
array is rebuilt in the store's order — but that becomes one small claim a
single test pins, rather than an assumption the whole comparison rests on.

Two things fall out of this, both improvements:

**Better failure messages.** `splits[index: 7].movingTime` names a kilometre
that can be opened and looked at. `splits[6]` names an array slot.

**Missing and surplus are separated from differing.** A split in the store with
no match by index is *missing*; one in the database with no match in the store
is *surplus*; neither is a *difference*. That is 290's `compared` / `missing` /
`differences` split, one level down, and it is what stops a count mismatch
being reported as nineteen field disagreements.

---

## 3. The `skipped` case — skip and count

A detail row whose `activityID` has no `activity_source_record` for `strava` —
orphaned by a source change — cannot yield the store's id and therefore cannot
become an `ActivityDetail`.

**Decided: skip it and count it**, exactly as `ActivityRepository` does for a
row with no `sportLabel`. The reasoning is unchanged from §12.35.4: a reader
that quietly returns fewer rows than the table holds is what shadow parity
reports as missing data, and the count is the difference between a reader that
is wrong and one that says where it stopped.

Expected to be zero on this device. It is declared because discovering it on
the read-back would mean discovering it as a number nobody can explain.

---

## What this changes in the groundwork note

- **§5** — the round trip compares by identity, and reports four categories per
  detail: scalar differences, element differences, missing elements, surplus
  elements.
- **§7** — settled; both questions are answered above and neither blocks the
  patch.

Nothing else in the note changes. The `ordinal` trap in §3 is still the thing
most likely to be got wrong, and the `positiveOrNil(lap.averageHR)` loss in §4
is still expected to show up and still should be reported rather than papered
over.
