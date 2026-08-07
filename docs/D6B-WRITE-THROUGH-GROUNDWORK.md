# D6b — write-through: groundwork

Written 7 August 2026 at patch 297, before any code. Everything below was read
out of the source today; nothing here needs re-deriving. The shape to copy is
`D6A-RECORDING-GROUNDWORK.md`, which is why 294 landed clean with no letter
fix-up.

**One thing is deliberately not settled**: the choice in §5 is gated on a
measurement that did not exist until this patch made it visible. Patch 297 adds
one row to the import section. Press Import, read the number, then decide.

---

## 1. What D6b is for, as a number

The three read-backs report, on 7 August:

| | in the store, not in the database |
|---|---|
| activities | 4 |
| details | 5 |
| recordings | 5 |

That is the last manual import going stale. It grows every day the app runs, and
the children outnumbering the parents means at least one activity reached the
database while its detail and recording rows did not.

Nothing may switch its reads to the database while this is true, because the app
would be reading a snapshot that is days behind with no way to catch up. **D6b
is the rung that makes the database keep up on its own.**

After D6b lands, the read-backs stop being a discovery tool and become a
regression test: they should read 0 / 0 / 0 for ever, and any other number is
news.

---

## 2. The write paths that exist today

### 2.1 The two that matter

| store | writes | fired by | shape |
|---|---|---|---|
| `ActivityStore` | `activities.json` | `ingest()` after a sync; `resetCache()` | the whole array, one file, synchronous |
| `DetailStore` | `details/<id>.json`, `streams/<id>.json` | `defer` in two fetch loops; the 169 migration | **a dirty set**, one file per record, on `Task.detached(priority: .utility)` |

`ActivityStore.save()` is `private` and has exactly two call sites (lines 503
and 622). `DetailStore.save(retiring:)` is `private` and has three (235, 348,
419). That is a small surface, and it is the reason a hook is cheap.

`DetailStore` already carries `dirtyDetails` and `dirtyStreams` — a real
changed-set, maintained, and cleared on write. `ActivityStore` has no equivalent
and writes the whole array every time.

### 2.2 The others

`NotesStore` and `CommuteStore` are written **while the athlete watches**, and
they roll their memory back on failure so the screen tells the truth
(§12.17, §12.17.1). The rest — athlete profile, weather, proposals, plan,
constants, sync state, work queue, rejections, match decisions — write during
syncs with nobody watching, and keep their memory on failure (§12.12.6).

That split already exists, is already reasoned, and D6b must not disturb it.

### 2.3 `StoreWriteJournal.attempt` is the seam, and it was built to be one

Every store's `save()` goes through:

```swift
StoreWriteJournal.shared.attempt("activities.json") {
    try StoreWrite.encode(activities, to: fileURL, store: "activities.json")
}
```

It is **non-throwing on purpose**, and patch 266's comment says why: making
`save()` throw would have pushed a decision out to forty call sites that all
want the same answer. The decision is made once, inside `attempt`.

That is the property D6b needs. There is one place where "a store just wrote"
is knowable for every store in the app, and it already exists.

---

## 3. The thing that changes the whole design

**`Sub4Import.run` is already the write-through.**

It is not a migration tool that happens to run twice. Read the call site in
`DatabaseHealthView.runImport`: it takes *every store's entire contents* as
arguments — activities, gear, notes, proposals, match decisions, sync state,
work items, rejections, commutes, weather, constants, FTP, zones, plan, streams,
details — writes them in one `db.queue.write`, upserts rather than inserts, and
opens and closes a `migration_run` around the whole thing.

Its own footer says it: *"Running it twice imports nothing twice."*

And as of 294–296 that claim is measured, not asserted: 668 activities, 668
details, 645 recordings and 1,403,819 samples compared after a run, with every
disagreement named and explained.

**So D6b's question is not "how do we write seventeen tables". It is "when does
the thing that already writes them run, and what happens when it fails".**

---

## 4. The two options

### 4.1 Option A — incremental write-through

Each store's `save()` also writes its own rows into the database. Small deltas,
low latency, no whole-world pass.

**The case against is evidence, not taste.** Patch 289 found four column renames
in the `activity` table alone — `sportType`→`sportLabel`, `isTrainer`→
`isIndoor`, `deviceWatts`→`hasPowerMeter`, `maxSpeed`→`maxSpeedMS` — plus
`gearId` not being `activity.gearID` at all. Patch 292 found four more in
`recording_sample`. Every one of those is a chance to be wrong in a way that
looks like missing data rather than like a bug.

Those were caught because a comparison existed and was run against the real
corpus. Seventeen new writers is seventeen new chances to take that risk, in
code that runs unattended, checked by a button somebody presses when they
remember.

### 4.2 Option B — fire the import that already exists

One code path. Already correct. Already covered by 794 tests. Already verified
against the whole corpus at three levels.

**The case against is cost.** A full run touches 668 activities, 668 details,
645 recordings and ~193,000 sample rows, and the app would do it after every
sync rather than when somebody presses a button.

### 4.3 Recommendation, and what it waits on

**B, gated on how long a full run takes on this phone.**

`Sub4Import.Report.seconds` has been computed since the import existed — line
491, from a `ContinuousClock` around the write — and **displayed nowhere.** The
number D6b's design turns on has been sitting in memory and thrown away on every
run for forty patches. Patch 297 puts it on screen. That is the whole of 297's
code.

Thresholds written down **before** the measurement, deliberately, because
§12.29.2.1 records what happens when a conclusion is written from a measurement
that does not exist yet, and §12.39.5/§12.39.6 is the working example of a
prediction stated so it could be falsified in public — which it was:

| measured | decision |
|---|---|
| under ~2 s | B unconditionally. Fire it after every sync, on a detached task. |
| 2–10 s | B on a detached task at `.utility`, coalesced so two syncs cannot queue two runs. |
| over ~10 s | B is still right, but it needs a changed-set. `DetailStore` already has one; `ActivityStore` would need one, and that is a real patch of its own. |

**MEASURED 7 August: 0.361 s. The first row.**

And the third row is largely retired, because the reading needs care. That
0.361 s is the STEADY-STATE cost, not a whole-world write:
`Sub4Import+Recording` skips a trace whose stored `fetchedUTC` matches the
store's, so the run wrote 1,200 sample rows rather than 193,000 — `4 new, 0
replaced, 645 unchanged` on the screen. The changed-set §4.3 said `ActivityStore`
might need already exists where it matters, and `ActivityStore`'s 668 rows are
the part that does not need one.

**Not measured: the cold path.** After `resetCache()` or on a fresh install all
645 traces are new, which is ~193,000 inserts and plausibly two orders of
magnitude slower. It does not change the decision — `resetCache` is deliberate
and rare — and it is written down as unmeasured rather than assumed. §12.42.3.

A is not chosen at any measured value. If B is too slow, the answer is to make B

incremental — not to hand-write seventeen writers whose correctness nothing
checks between read-backs.

---

## 5. The five questions to settle before code

### 5.1 What fires it

Not per-store. `ActivityStore.ingest()` is where a sync finishes, but
`DetailStore` finishes later and independently in two separate `defer`s, and
notes and commutes are written by a person at any moment.

So: a **coalescing trigger** — something marks the database dirty, and one run
is scheduled that absorbs every mark arriving before it starts. `StoreWriteJournal.attempt`
is the natural place to raise the flag, since every store already passes through
it and it already knows the store's name.

Open: whether the flag lives on the journal or beside it. The journal's stated
job is "which stores are behind their memory", and "the database is behind the
files" is a different sentence about a different thing.

### 5.2 What a failed database write does

Reuse `StoreWriteJournal` with a store named for the database. Its contract —
*memory keeps what was fetched, the disagreement is recorded, a successful write
clears it, Settings shows it* — is the same sentence for the database as for a
file, and it is already built, already tested, and already on screen.

Rolling anything back is wrong for the same reason 266 gives: the data came off
the network a moment ago, and discarding it to buy consistency nobody asked for
shows the athlete less than the app has.

### 5.3 Inside or beside the file write

**Beside, and after.** The JSON files are the source of truth until D7. A
database write must never be able to prevent or corrupt a file write, so the
order is: file first, journal it; database second, journal it separately.

This is a decision, not a discovery. "The file saved and the row did not" is
precisely the failure that would make the read-backs start disagreeing again —
and after this session it would read as a reader regression when it was nothing
of the kind.

### 5.4 What the ledger records

`Sub4Import.run` opens and closes a `migration_run` row per call. An automatic
run after every sync would put hundreds of rows into a ledger built to answer
"when was the last import, and did it work".

Open: a distinct state, a suppressed row, or a separate table. Contract item 11
wants every write accounted for; it does not require them all in one list, and a
ledger nobody can read fails item 11 in spirit — §12.40.1's lesson, one screen
over.

### 5.5 What D6b's exit gate is

**Amended at 298, the same morning it was written, because as first stated it
could never be met.**

It said *"the three read-backs report 0 / 0 / 0 store-only records"*. Two of
those numbers can never be zero. `DataCorrections` refuses two sessions and the
importer declines their traces and details at the door, while `DetailStore`
keeps them because it keys by Strava id and never sees an `Activity`. The store
permanently holds records the database will never hold, by design.

A gate that cannot be met is worse than no gate: it gets quietly dropped rather
than argued with. §12.42.2.1.

**The gate, corrected:**

- the three read-backs report **`missing` at zero** after a sync the athlete did
  not trigger by hand, with `excluded` shown beside it and free to be non-zero
- one deliberate failure — a locked device, say — leaves a journal entry that
  Settings shows

The first half proves it works. The second half proves it says so when it
doesn't, which is the half every rung of this ladder has needed.


---

## 6. Scope

**In:** the trigger, the coalescing, the failure record, the ledger decision,
tests, and whatever `ActivityStore` needs if §4.3's third row is the one that
comes true.

**Out:** switching any read to the database. That is D7, it is gated on D6c
shadow parity, and 281's `onStravaDisconnect: .removeEverything` is coupled by
test to `Sub4Launch.migrationFailureBlocksTheApp` precisely so the two cannot
drift apart.

**Out:** touching the watched-write stores' rollback behaviour. It is right, it
is reasoned, and D6b has no business in it.

---

## 7. What is still unknown

**Answered at 297: 0.361 s steady-state, so §4.3's first row.** See §4.3 for
what that number does and does not cover.

Still unknown, and neither blocks starting:

- **The cold path.** A first import, or one after `resetCache()`, writes all
  ~193,000 sample rows instead of skipping 645 traces. Unmeasured.
- **Which of two things `17463863070` is.** The read-back says its `fetched`
  differs; the importer says the same column is unchanged. 298 makes the report
  print both dates and name an unparseable timestamp separately, so the next run
  answers it. §12.42.1.
