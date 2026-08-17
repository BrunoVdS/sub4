# D7 — patch 387 groundwork: delete the list, keep the derivation


> **EXECUTED AT 387.** Three claims here proved wrong against the tree — the
> byte-identical mark (8 of 9), the map size over an empty database (19, not
> 22) and the test count (1,622, not 1,620) — and it missed that RULE 5 parses
> `HydratedStores.all`. ADR §12.131 has all four. Read this for the plan, not
> for the numbers.

**Written at 386a, 17 August 2026, from a read of the working tree.**
Authority for the decision is `docs/ADR-0003-database-contract.md` §12.130;
`CLAUDE.md` §5.6 step 2 is the order. This file is the enumeration, so nobody
has to redo it.

> **THE PRECONDITION IS MET.** §12.130.5 says 387 does not start until the
> device has printed that the derivation and the declared list agree. It did,
> at 386a on 17 August 08:14, on a run marked verified:
>
> ```
> comparisons: 22 — 13 independent, 9 reading a store the database feeds
> derived from the stores: 9 of 22 read a field this build feeds — agrees with the declared list
> ```
>
> Two independent mechanisms reached the same nine. 387 removes the older one.

---

## 1. What 387 is

`HydratedStores` is a hand-kept list, in a different file from the comparisons it
classifies, joined to them by name. 385 proved it can be one entry short and
nothing notices (§12.129). 386 built the derivation beside it: every comparison
names the store field its expectation came from, and `ExpectationSources.live`
asks each store what it is serving.

**387 makes the derivation the operative answer and deletes the list.**

It is a refactor, not a behaviour change. The device's numbers must not move:
`22 comparisons — 13 independent, 9 self-referential`, same nine, same paste
text for each marked check.

---

## 2. Source changes — four files

### 2.1 `Sub4/SemanticVerifier.swift`

**`independentChecks` / `selfReferentialChecks`** — stop reading the list:

```swift
var independentChecks: [VerificationCheck] {
    checks.filter { !$0.isSelfReferential(given: sources) }
}
var selfReferentialChecks: [VerificationCheck] {
    checks.filter { $0.isSelfReferential(given: sources) }
}
```

`isSelfReferential(given:)` already exists — 386 put it on `VerificationCheck`.

**Delete `unmatchedHydratedEntries`** (the `HydratedStores.all` minus checks
property) **and `undeclaredSelfReferential`** (386's cross-check). Both name the
list; both guard failure modes that stop existing when the classification is
derived from the check itself rather than joined to it by name.

**Delete `derivedSelfReferential`** — it becomes `selfReferentialChecks`. Fold
its doc comment into the latter.

**`isTrustworthyEvidence` drops to two conditions:**

```swift
var isTrustworthyEvidence: Bool {
    passed && !independentChecks.isEmpty
}
```

> **THIS IS A GATE BEING RELAXED AND IT NEEDS ITS ARGUMENT ON THE LINE.**
> `apply-354.py` greps this expression by name and fails if it is reduced to
> `passed` — the spirit of that guard applies here. The two conditions being
> removed are `unmatchedHydratedEntries.isEmpty` and
> `undeclaredSelfReferential.isEmpty`, and both were about *a list drifting from
> the checks*. With no list there is nothing to drift. The condition that
> carries the actual meaning — **at least one comparison could have
> disagreed** — is untouched, and it is the one that fires at B9.
>
> Write that reasoning into the doc comment. Do not leave it looking like a
> simplification.

**`withheldReason`** — delete the two arms naming the removed properties. Keep
the `independentChecks.isEmpty` arm.

**`diagnosticLines`** — the mark is now derived, not looked up:

```swift
for c in checks {
    let mark = c.isSelfReferential(given: sources)
        ? " · self-referential: \(c.reads.storeDescription)"
          + (c.reads.field.slice.map { ", hydrated at \($0)" } ?? "")
        : ""
    ...
}
```

**This must produce byte-identical text to 386a's.** Check against the real
paste — e.g.
`· self-referential: ActivityStore.activities, seven fields each, hydrated at B3`.
`ExpectationOrigin.storeDescription` gives the first half, `field.slice` the
second.

**Replace 386's cross-check line rather than deleting it.** A row that vanishes
cannot be told from one nobody wired in (§12.54.2). The line
`derived from the stores: … agrees with the declared list` has nothing left to
agree with; put the derivation's own statement there instead:

```
  fields fed by the database: 6 of 14 — activities, commutes, matchDecisions, moves, notes, zones
```

Sorted, so two runs compare. 14 is `ExpectationField.allCases` minus
`.databaseAlone`. Delete the `COUNTED AS EVIDENCE AND COULD NOT DISAGREE:` and
`DECLARED HYDRATED AND NOT COMPARED:` loops.

### 2.2 `Sub4/PersistenceMode.swift`

**Delete lines 288 to end of file** — the `// MARK: - What the database now
feeds` banner and the whole `HydratedStores` enum. It is the file's tail; the
file then ends at the closing brace on line 287 (`derive`'s enclosing type).

Nothing else in `Sub4/` references the enum. Verified by grep at 386a.

### 2.3 `Sub4/DatabaseHealthView.swift` — line 1599

```swift
LabeledContent(HydratedStores.entry(for: check.name) == nil
               ? "  \(check.name)"
               : "  \(check.name) — self-referential",
```

becomes

```swift
LabeledContent(check.isSelfReferential(given: v.sources)
               ? "  \(check.name) — self-referential"
               : "  \(check.name)",
```

`v` is the report and is already in scope (`ForEach(v.checks)`). **This is a
label swap, not an added row** — the screen's depth must not move. §12.76.

### 2.4 Nothing else in `Sub4/`

`AppStores.swift` already passes `sources: .live` from `attempt(_:stores:)`,
which 386a made the single production door. No change.

---

## 3. The semantic shift that makes this big

**`selfReferentialChecks` becomes dependent on `sources`, which defaults to
`.allFromFiles`.**

Today the list makes it unconditional: `verify(db, activities: [])` in a test
process reports nine self-referential checks. After 387 the same call reports
**zero**, because nothing has been hydrated in a test process and that is the
honest answer.

**So every test asserting that a comparison IS self-referential must now pass
`sources:` explicitly.** This is the bulk of the patch. It is also the correct
outcome: those tests were relying on a compile-time constant to simulate a
runtime state.

---

## 4. Test changes — seven files

### 4.1 `Sub4CoreTests/VerificationIndependenceTests.swift` — rewrite

**The `covering()` fixture dies with the list.** 358a built it because
`unmatchedHydratedEntries` withheld any report that did not name every declared
entry, so every fixture in the file broke each time the list grew. With no list
there is nothing to satisfy, and the fixture has no reason to exist. Replace it
with a plain report taking a `fed:` set:

```swift
private func report(_ checks: [VerificationCheck],
                    fed: Set<ExpectationField> = []) -> VerificationReport {
    VerificationReport(checks: checks, seconds: 0.01,
                       sources: ExpectationSources(fedByTheDatabase: fed))
}
```

**Delete three tests**, each of which tests a failure mode that stops existing:

| test | why it goes |
|---|---|
| `everyDeclaredEntryNamesARealComparison` | there are no declared entries; `ExpectationProvenanceTests.everyFieldIsCompared` is the derived successor and already exists |
| `anEntryNamingNothingWithholdsIt` | an entry naming nothing cannot occur |
| `anUnmatchedEntryIsNamedInThePaste` | the paste line it asserts is gone |

**Keep and re-express** — pass `fed:` and give each synthetic check a real
`reads:`:

- `theListNamesTheZoneCheck` → rename; assert the zones comparison reads
  `.zones` and that `ExpectationField.zones.slice == "B1"`
- `theSplitIsWhereItShouldBe` → the split follows the sources and nothing else
- `nothingButSelfReferentialIsNotBelieved`
- `aFailureIsNotAWithholding`
- `theLedgerNoteCarriesTheCount` — the `HydratedStores.all.count + 2` arithmetic
  becomes a plain count of the fixture's own checks
- `thePasteSaysItUnconditionally`
- `aWithheldReportSaysSoInThePaste`
- `theSixthAnswerExists` — untouched, it is about `VerificationResult.Ledger`

### 4.2 `Sub4CoreTests/ExpectationProvenanceTests.swift`

- Header: it says 386 does *not* replace the list. Rewrite — 387 does.
- Delete `theUndeclaredOneIsCaught` (no cross-check left to catch anything).
- The `covering()` helper 386a added exists to satisfy `unmatchedHydratedEntries`
  — delete it; the three tests using it go back to `report(...)`.
- `theOppositeIsNotAFault` — keep, and it means something better now: with
  `fed: []` a previously self-referential comparison returns to the evidence
  column, which is what reverting a slice does.

**Add `theWholeMapIsPinned` — this is 387's replacement tripwire and it is the
reason the patch does not lose protection:**

```swift
@Test("Every comparison's field is pinned, so a new one forces a decision")
func theWholeMapIsPinned() throws {
    let db = try Sub4Database.inMemory()
    let r = try SemanticVerifier.verify(db, activities: [],
                                        syncState: <a cursor>,
                                        sources: ExpectationSources.allFromFiles)
    let map = Dictionary(uniqueKeysWithValues: r.checks.map { ($0.name, $0.reads.field) })
    #expect(map == [ /* all 22, written out */ ])
}
```

> **THE ASYMMETRY IS THE POINT.** The old list was a SUBSET — a comparison
> missing from it passed in silence, which is exactly what happened to
> `activity fields` for three patches. This map is COMPLETE: a comparison
> missing from it fails, and a comparison whose field changed fails. That is the
> protection `unmatchedHydratedEntries` and `undeclaredSelfReferential` were
> providing, in the one form that can actually fail.
>
> Pass a `syncState` — the cursor comparison is the verifier's one conditional
> check and is absent otherwise. `ExpectationProvenanceTests.everyFieldIsCompared`
> already documents that and shows the construction.

### 4.3 The five suites that read the list

Re-express each assertion against `reads.field` and `field.slice`, and pass
`sources:` where a comparison must be self-referential.

| file | what it asserts now | what it becomes |
|---|---|---|
| `B2ActivationTests` | `HydratedStores.all.filter { $0.slice == "B2" }.count == 4` | `r.checks.filter { $0.reads.field.slice == "B2" }` — **stronger**, it names the checks the verifier makes rather than a hand list |
| | `r.independentChecks.count == r.checks.count - HydratedStores.all.count` | derive from `sources` |
| `ActivitiesAreReadTests` | loop over four names, `entry(for:)?.slice == "B3"` | `$0.reads.field == .activities`, and `.activities.slice == "B3"` |
| | `HydratedStores.all.count == 9` | delete — the number was the list's |
| `ActivityHydrationTests` | `all.count == 9`, `entry(for: "activities")?.slice == "B3"` | drop the count; keep the slice via `ExpectationField.activities.slice` |
| `CorrectionFamilyTests` | `entry(for: "unclaimed corrections") == nil` | `reads.field == .databaseAlone` — **says more**: it is a residual, not merely undeclared |
| | `r.selfReferentialChecks.count == HydratedStores.all.count` | pass `fed:` and assert the six fields |
| `PlanMoveImportTests` | `#require(HydratedStores.entry(for: "session moves"))` | the check's `reads.field == .moves`, `.moves.slice == "B2"` |
| `MoveHydrationTests` | `HydratedStores.all.first { $0.check == "session moves" }` | same |

### 4.4 Test count

1,623 today. Four tests go (three in `VerificationIndependenceTests`, one in
`ExpectationProvenanceTests`), one arrives (`theWholeMapIsPinned`): **expect
1,620 in 149 suites.** The run prints the truth — if it differs, find out why
before updating `CLAUDE.md` §3 rather than after.

---

## 5. Documents to move with the commit

Bruno asks for these three every patch:

- **`CLAUDE.md`** — header and §5 heading to 387; §5.4's "The list is still the
  operative answer at 386, on purpose" paragraph rewritten to say the derivation
  *is* the answer and the list is gone; §5.6 step 2 replaced by **B4**; §3's test
  count; §6 gains the lesson if one is worth keeping. **§5 must stay under 220
  lines** — 384's ceiling, guarded by `apply-384.py` and by `apply-386.py`.
- **`README.md`** — `*Current at patch 387, …*` (RULE 6 reads this line).
- **`docs/PLAN-codebase-modernization-and-feature-delivery.md`** — the
  `**Progress against this plan, at 386.**` paragraph, added at 386, moves to 387
  and notes the verifier's accounting is now derived end to end. The banner above
  it also carries a patch number.
- **`docs/ADR-0003-database-contract.md`** — §12.131, appended **before** §12.130
  (the file runs newest-first).

`scripts/check-invariants.py` **RULE 6** will fail the build if `CLAUDE.md`'s
header, `CLAUDE.md` §5 or `README.md` names a patch more than twelve behind
`AppVersion.patch`, so the first three are enforced, not optional.

---

## 6. Checks before calling it done

1. `./scripts/test.sh` — invariants then the suite. RULE 5 compares every pinned
   count against its source; the three `HydratedStores.all.count` pins must be
   **gone**, not updated.
2. `grep -rn "HydratedStores\|unmatchedHydratedEntries\|undeclaredSelfReferential" Sub4/ Sub4CoreTests/`
   → nothing but prose in ADR-quoting comments.
3. `Sub4/AppVersion.swift` — `patch = 387`, `revision = nil`.
4. **On the phone**: Settings → Database health → **Import and verify** →
   **Verification**. The numbers must be **unchanged**: `22 · 13 independent`,
   the same nine rows marked `— self-referential` with the same text, ledger
   `verified · patch 387`. The new line reads
   `fields fed by the database: 6 of 14 — activities, commutes, matchDecisions, moves, notes, zones`.
   **A refactor that moves a number on this screen has not refactored.**

---

## 7. After 387

**B4 — details and traces**, per `CLAUDE.md` §5.6. B4 is the first slice to add
comparisons under the derived scheme: each new check must name its field at
construction, and flipping `.details`/`.traces` means answering for them in
`ExpectationSources.servesFromDatabase` rather than remembering to add anything
to a list. That is what 385–387 were for.
