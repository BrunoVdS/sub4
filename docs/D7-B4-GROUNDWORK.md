# D7 slice B4 — details and traces

| | |
|---|---|
| **Written against** | patch 387, commit `273f048`, 17 August 2026 |
| **Amended** | patch 389, against the device paste of 388 |
| **Authority for this stage** | `docs/ADR-0003-database-contract.md` §12 |
| **Current state** | `CLAUDE.md` §5 — this document is a plan, not state |
| **Status** | 388 and 389 committed; 390–392 described here. |

**THE LADDER GREW BY ONE AT 389 AND THE NUMBERS MOVED.** 389 was going to be
the seams; the 388 device run showed two roll-up rows that were already the
database against itself and no way for the screen to say so, so counting that
came first. The seams are 390, the machinery 391, the flip 392.

Every fact below was read out of the source at that commit. Where a number came
from a device paste rather than from code it says so.

---

## 0. Why this slice needs four patches

§12.125's rule: **the patch before a flip is the one that asks what the flip is
about to make vacuous.** B3 needed four patches for that reason and both extra
ones caught a defect a single patch would have shipped (§12.126.1).

The enumeration below found more to empty than B3 had:

| what the flip empties | rescuable | where |
|---|---|---|
| 5 verifier comparisons | no — they are what B4 is | §1 |
| Compare's slice 4, `DetailParity` | **yes**, 381's way | §3 |
| the `Details` read-back | **yes**, 381's way | §3.4 |
| the `Recordings` read-back | **yes**, 381's way | §3.4 |
| slice 3, `LoadParity` | no — §12.125.4 already said so for activities | §3 |

And one thing that was already vacuous before the flip and only becomes
material because of it — §2.

---

## 1. The five comparisons, named

Read from the construction sites in `SemanticVerifier.swift` and cross-checked
against `ExpectationProvenanceTests.theWholeMapIsPinned`, which holds all 22.

| comparison | table | reads |
|---|---|---|
| `traces` | `recording` | `.traces`, "the ones the store holds" |
| `trace samples` | `recording_sample` | `.traces`, "summed over the traces" |
| `details` | `activity_detail` | `.details`, "the ones the store holds" |
| `splits` | `activity_split` | `.details`, "summed over the details" |
| `splits of one activity` | `activity_split` | `.details`, "the richest one" |

**Independent falls 12 → 7** (13 → 8 before 388's recount; see §2). The seven
that survive: `gear`, `reviews`, `stopped asking`, `refused recordings`, `sync
position`, `weather readings`, `one weather reading`. B5 takes three of those,
B7 one, B8 three — so B5 leaves four and B8 leaves none.

Nothing has to be added to a list. Each of the five already names its field, and
flipping means answering for `.details` and `.traces` in
`ExpectationSources.servesFromDatabase`, which is an exhaustive switch. That is
what 385–387 bought.

---

## 2. Patch 388 — the residual stopped counting as evidence

**Committed.** Full argument in ADR §12.132; the short form is that
`unclaimed corrections` reads `.databaseAlone`, which can never be
self-referential by construction, so it sat in `independentChecks` under every
possible `sources` — making `independentChecks.isEmpty` unreachable and
`isTrustworthyEvidence` incapable of withholding anything, at B9 or ever.

It belongs before B4 rather than after it because the evidence column is about
to lose five of its members, and a gate that cannot fire is worth fixing while
there is still plenty in front of it.

The negative control was run rather than reasoned about: reverting
`independentChecks` to its 387 body failed six tests, one of them reporting
`isTrustworthyEvidence → true` over a report whose only survivor was the
residual. §12.69, sixth payment.

---

## 2a. Patch 389 — the roll-up says how much of its agreement is evidence

**Committed.** Full argument in ADR §12.133. The 388 device paste showed
`8 of 9 agree` over eight rows of which **two could not have disagreed** —
`Activities` since 382, `Athlete` since 346, 721 of 3,080 field comparisons —
and the screen had four verdicts with no way to express it.

Each row now carries its own provenance (`ReadBackRollUp.Line.reads`, no
default) and `ExpectationSources.live` resolves it, so the count is derived
rather than declared. **The unit is not the field**: `Notes and commutes` reads
four fed fields and is real evidence because 356 gave it its own read, so
`ReadBackSource` distinguishes *read the files myself* from *took it from the
stores*. The third mark — *from the stores, not fed yet* — is the tripwire for
`Review trail` at B7.

It lands before the seams because 390 moves that number, and a number that moves
before anybody has seen it hold still is a number nobody can check.

## 3. Patch 390 — Compare and the read-backs get their own reads

### 3.1 `DetailParity` is 381's situation exactly

`ShadowParity.detailReport` passes `Array(DetailStore.shared.details.values)` as
the app side. After the flip both sides are the database, slice 4 prints *no
differences* about a comparison that has stopped being one, and **nothing in the
suite can see it — both sides agreeing is what a pass looks like** (§12.125.2).

The fix is 381's: an independent read of the files, provenance printed
unconditionally, and `isHealthy` requiring `appSideWasReadCleanly` so that zero
differences over an app side that could not be read is not a pass.

### 3.2 The seam is NOT `ActivityStore`'s eleven lines

`ActivityStore.init(directory:)` is 378's seam and it is small because the store
is small. `DetailStore.init` does four things that must not happen on a second
root:

1. **the schema-version purge.** `UserDefaults.standard.integer(forKey:
   schemaKey) != schemaVersion` sets `streams = [:]` and then
   `removeItem(at: streamsDir)` — **it deletes the athlete's traces.** A seam
   that inherited this would be §12.125.5's shape with a directory removal
   instead of a blob write: a destructive path nobody can trigger until the day
   somebody adds a second reader, and 390 is that day.
2. reads `failed` and `noStreams` from shared `UserDefaults`.
3. `FileProtection.protect(directory:)` on both, and creates them if absent.
4. writes, through `save(retiring:)`, if the retired monoliths are present.

So the seam must not purge, must not touch `UserDefaults`, must not protect,
must not create, and must not write — and, like every other seam here, must not
record to `StoreReadJournal` (`canReconcile` reads that journal to decide
whether rows may be deleted).

### 3.3 Slice 3 gets worse and cannot be rescued

§12.125.4 recorded `LoadParity` as unrescuable when B3 flipped: its app side is
`LoadStore.shared.days`, the app's real series, and handing it a shadow list
would mean comparing something no screen shows. B4 deepens it —
`LoadStore.currentSignature` keys on `DetailStore.streamCount` and `recompute`
walks `streams(for:)` — so after the flip the app's own load series is computed
from reconstructed traces. Recorded here rather than discovered in a paste.

### 3.4 And two read-backs that are already wrong

Under the rule 381 made general and §12.126.3 restated — *a read-back gets its
own read in the slice that hydrates its own store* — `ReadBacks.details` and
`.recordings` are B4's. Both take their app side from `DetailStore.shared`.

**The enumeration also found two that no slice rescued**, and they are in
`CLAUDE.md` §5.5 because they are current defects rather than plans:

- `ReadBacks.athlete` — `ConstantsStore.shared.c`, `AthleteStore.shared.ftp`,
  `.hrZones`, all hydrated since 346
- `ReadBacks.activities` — `ActivityStore.shared.activities`, hydrated since 382

343 wrote the rule for the plan and B1 applied it to the plan and not to the
athlete beside it. The activities one is a one-line fix — `ActivitySource.read()`
already exists — and rides along in 389. **The athlete one does not:** it needs
`AthleteStore(directory:)` and `ConstantsStore(directory:)`, which are the two
stores counted by `UNPROTECTED_STORE_CEILING`, so it is its own patch and it
pairs with dropping that ceiling to zero.

---

## 4. Patch 391 — the machinery, switched off

380's pattern: build everything that would feed the family and switch none of it
on, so that the flip is one line somewhere else and any failure it produces is
attributable (§12.103).

- **Two bootstrap fields, not one.** `authored` proves one field can carry two
  payloads; `decisions` proves the rule is *one read that can fail on its own*.
  Details and traces are two reads, so `fieldCount` goes 7 → 9 and
  `diagnosticLineCount` (= `fieldCount + 6`) → 15.
- **RULE 5 will fail the build before a test runs.** It derives four counts from
  the source and compares them against **14 pins across seven test files** —
  `ActivitiesAreReadTests`, `ActivityHydrationTests`, `AuthoredHydrationTests`,
  `B2ActivationTests`, `DatabaseBootstrapTests`, `MoveHydrationTests`, plus the
  `"Database bootstrap: N families"` string. All four move in this patch.
- **`DetailLoad` and `RecordingLoad` need `wasReadCleanly` and `holdsContent`.**
  They have `isTrustworthy` and nothing else; the bootstrap's two verdicts are
  §12.92's and cannot be `&&`-ed out of one boolean.
- **Neither family belongs in `canHydrate`.** Same argument as `.activities`
  (§12.123): details and traces arrive from a rate-limited Strava backfill that
  may never have completed, so reading their absence as "nothing here to hydrate
  from" would refuse the plan over a backfill.
- **`hydratable*` withholds an empty payload**, for `hydratableActivities`'
  reason rather than the authored families': a clean read of an empty table is a
  device before its first backfill, and hydrating there would replace a store
  holding the whole history with nothing.
- **Two `servedFrom` properties on `DetailStore`, as CONSTANTS.** §12.130.1's
  distinction: `AthleteStore`'s halves are derived because B5 makes it whole;
  `ActivityStore`'s are constants because B8 moves the receipts while the
  activities stay. `DetailStore` is the second kind — B8 moves `workItems`.
- **`hydrate` must mark nothing dirty.** `save()` writes only `dirtyDetails` and
  `dirtyStreams`, which is what keeps `details/` and `streams/` — the legacy
  side's only copy — safe through a hydration. This is B4's form of *hydration
  must never write*, and it wants its own test.

### 4.1 The launch cost, which this patch exists to measure — CORRECTED AT 389

**THE FIRST DRAFT OF THIS SECTION WAS AN ORDER OF MAGNITUDE WRONG, AND THE
DEVICE IS WHAT SAID SO.** It carried "the 1.5-million-sample read", which is
CLAUDE.md §5.6's phrase and the original brief's. `ReadBacks.recordings`' own
doc says *"roughly 1.5 million **comparisons** across 649 recordings"* — eight
series over each sample — and the 388 paste puts the real figure at
**`recording_sample: 199,848` rows**. 199,848 × 8 ≈ 1.6 M. A comparison count
had been read as a row count for as long as the phrase has existed, in the
direction that makes this slice's one open question look worse than it is.
§12.72.7's family: the number was in the tree and nobody opened the line.

`DatabaseBootstrapReader.read` is awaited **before `.ready`** (§12.92.6, and the
ordering is a defect fix that must not be undone). Two costs land there:

- **the trace read** — 668 recordings over **199,848 sample rows**, ~299 samples
  each. `DatabaseBenchmark.Budget.readMillisecondsPerRecording` is 5.0, so
  668 × 5 ms = 3.3 s is the worst case **at budget**, and the budget is a
  ceiling asserted at the 10,000-activity design target rather than a prediction
  for this database. `RecordingRepository.all`'s own header says it materialises
  ~12 MB and that callers "should use `ids` and `streams` instead". **Measure
  it; do not carry my estimate.**
- **`DetailStore.shared`'s own `init`**, which decodes **1,362 files and 19.1 MB**
  of JSON on the main actor — `details` 694 files / 1.9 MB and `streams` 668
  files / 17.2 MB, from the 388 snapshot manifest — and is then hydrated over.
  B3 accepted the same waste for one 393 KB file.

**Per-activity lazy reads are ruled out**, and it is worth writing down why so
nobody re-proposes it: `LoadStore.currentSignature` includes
`DetailStore.streamCount` and `recompute` walks every trace for TRIMP, so the
load engine needs the whole set. A partially-populated dictionary would change
the PMC curve rather than defer work.

391 prints the measurement. If it is large, the options are to accept and print
it, to split the flip so details go first and traces wait for a shape change, or
to revisit the chunked-blob shape §12 rejected at 212 on 2026-06 hardware.

---

## 5. Patch 392 — the flip

Two `false`s become questions:

```swift
case .traces:  DetailStore.shared.tracesServedFrom == .database
case .details: DetailStore.shared.detailsServedFrom == .database
```

`.details` and `.traces` join `hydratedFamilies`. Nothing else. Reversible by
deleting them from that line — `details/` and `streams/` are still written and
still complete, which is what makes a slice a slice.

Expected on the device: `12 independent → 7`, five comparisons gaining a
`· self-referential:` mark naming `the detail store` / `the trace store` and
`hydrated at B4`, `fields fed by the database: 8 of 14`, and every figure on
every screen unchanged.

---

## 6. What the flip cannot damage, checked rather than assumed

Two hazards were enumerated and both come out safe. Recorded because "we checked
and it is fine" is a different fact from nobody having looked.

- **The JSON files.** `save()` writes only dirty keys, and the only reachable
  inserts are in `fetchOne`, carrying freshly-fetched values rather than
  hydrated ones. `load()`'s whole-store `formUnion(m.keys)` fires only on
  monolith migration, and `details.json`/`streams.json` cannot exist on this
  install — they are the permanent floor of the snapshot's `not present` row.
- **The database's own rows.** `AppStores.current()` will feed `Sub4Import` from
  a hydrated store after the flip, which is §12.126.5 one family over. Both
  importers skip on a matching `fetchedUTC` stamp, so the reconstruction is not
  written back. **The one exception is narrow and real:** a recording whose
  `fetchedUTC` will not parse comes back as `RecordingRepository.unreadableDate`,
  the stamps differ, and the import then `DELETE`s and re-`INSERT`s from the
  reconstruction — which is lossy, because `series()` reads NULL as 0 and
  rebuilds every optional stream at `rows.count`. Worth a guard.

---

## 7. What this document does not decide

- **Whether the launch cost is acceptable.** §4.1 measures it; the decision is
  Bruno's and it is the one open question in this slice.
- **When `ReadBacks.athlete` is fixed.** §3.4 — its own patch, and it pairs with
  `UNPROTECTED_STORE_CEILING`.
- **Whether `DetailStore` should be brought under RULE 1.** The rule cannot see
  it (its population regex is `let fileURL: URL`; this store keys on two
  directories). Not a defect today for the reason in §6, but the population was
  drawn from seven single-file stores and this is the eighth shape.
