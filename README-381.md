# Patch 381 — the activity parity keeps its own read

D7 slice B3. ADR-0003 §12.125. Sits on 380. **This is not the flip** — 382 is.

## Install

```sh
cd ~/Documents/Developer/sub4/Sub4 \
  && unzip -o ~/Downloads/sub4-patch-381.zip \
  && python3 scripts/apply-381.py \
  && ./scripts/test.sh
```

## Commit

```sh
mv sub4-commit-381.txt README-381.md ~/Downloads/ \
  && git add -A \
  && git commit -F ~/Downloads/sub4-commit-381.txt
```

## Why this came before the flip

`ShadowParity.run` took the app side of slices 1 and 2 from
`ActivityStore.shared.activities`. 382 hydrates that store from the database —
so both sides would have been the same rows, agreeing perfectly and proving
nothing, and no test could have seen it, because two sides agreeing is what a
pass looks like.

343 solved this for the plan by decoding the bundle; 356 solved it for the
authored families by reading their files directly. `activities.json` is still
written and still complete, so 381 does the same: `ActivitySource.read()` goes
through `ActivityStore(directory:)` — the seam 378 added — which is one
decoder, one `settle`, two roots.

## What is in it

| file | what |
|---|---|
| `Sub4/ActivityParity.swift` | `ActivitySource` (three states: read cleanly / no file / could not look); `Report.appSideCameFrom` + `appSideWasReadCleanly`, printed, and folded into `isHealthy` |
| `Sub4/ShadowParity.swift` | the app side comes from the file; the store is a named, non-silent fallback |
| `Sub4/ActivityStore.swift` | a store rooted elsewhere records no rejection — §12.125.5 |
| `Sub4CoreTests/ActivityIndependenceTests.swift` | new — 8 tests |
| `Sub4/AppVersion.swift` | 381 |
| `docs/ADR-0003-database-contract.md` | §12.125 |

**Nothing is flipped.** `hydratedFamilies` still names six and
`HydratedStores.all` still holds five; a guard fails the patch otherwise.

## The defect the enumeration found

`ActivityStore.load()` calls `recordRejections`, which writes the shared
`strava.rejections` key. A store rooted elsewhere starts with `receipts` empty,
so one self-contradictory row in the file it read would have written a blob
holding that row alone — replacing the three receipts this device has kept
since 278, which describe recordings that exist in no file and cannot be
re-fetched. Unreachable today (a refused activity is never written to
`activities.json`); fixed anyway, because 381 is the patch that gave that file a
second reader.

## What 382 still owes

`hydratedFamilies` += `.activities`, the `sliceUnderTest` label, and **three**
`HydratedStores` entries, not one: `activities`, `activity identities` and
`volume by discipline` all take their expectation from the store the database
will feed. Slices 3, 5 and 8 (`LoadParity`, `MatchParity`, `SummaryParity`)
cannot be rescued the same way and lose their independence at the flip —
§12.125.4 records why.

## On the phone, after installing

1. **Settings → Database → Compare** (the shadow-parity button), then **Share
   diagnostics**.
2. In the pasted text, the activity parity block now opens with three lines:

| line | must read |
|---|---|
| `Activity parity: N compared of N in the app` | the same numbers as your 380 run |
| `  the app side came from:` | `activities.json, read directly` |
| `  the app side was read cleanly:` | `yes` |

3. Everything below those lines — offered, skipped, kept, dropped, in the app
   only, in the database only, order, days, zones — **identical to the 380
   run**. This patch changes where the app side is read, not what it holds.
4. `Activity store reads:` still `the app's own files`, `Activities hydrated:`
   still `no`. If either moved, 382 arrived early.

A number that moves in step 3 is a finding: it would mean the store and its own
file had drifted while nothing was hydrating anything.
