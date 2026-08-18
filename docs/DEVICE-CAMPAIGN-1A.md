# Device campaign — topic 1A, the authored restore path

| | |
|---|---|
| **Task** | Plan topic 1A — "finish the existing authored-store restore implementation" |
| **Patches under test** | 400, 402, 404, 405, 407 (and 406's migration, ridden along) |
| **Written at** | patch 408, 18 August 2026 |
| **ADR** | §12.144, §12.146, §12.148, §12.149, §12.151 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |

1A's prompt requires this document in as many words — *"Manual campaign
required because restore changes real authored files. Build it before
completion."* It was not written when the patches landed; the checks were given
in chat and executed ad hoc, and the results recorded after the fact in
§12.148.4 and §12.149.5. **This is the campaign those results belong to**, and
it names what they did and did not cover.

---

## 1. Question and risk

**What automated tests cannot prove.** Every restore test drives
`init(directory:)` or `UserDefaults(suiteName:)` into a throwaway location —
deliberately, because the singletons point at the athlete's real `notes.json`,
`commutes.json`, `moves.json` and `match.decisions`. So `NotesStore.shared
.restore(...)` and its three siblings are **the code path that runs on the phone
and the one path nothing in the suite executes.**

**The failures this campaign is designed to reveal:**

| failure | what it would look like |
|---|---|
| The control writes to memory and not to disk | receipts look right, the repair is gone at the next launch |
| A restore reverts a record the athlete edited since the last import | a note's text silently changes back |
| A restore fires a reconciling import | authored runs climb, and a repair carries permission to delete (§12.149) |
| The section will not open | §12.76's runtime stack overflow, which compiles clean and passes every test |
| The receipts do not reach the paste | two exports either side of a press are identical (§12.146) |

---

## 2. Build and data identity

Record these before starting. **A campaign whose build is unknown is evidence
about nothing.**

| field | value |
|---|---|
| App patch | `408` — Settings → Version → Source patch |
| Build timestamp | Settings → Version → Built |
| Configuration | Settings → Version → Configuration (Debug or Release — record which) |
| Commit | `8c5dd26` or later; `git log --oneline -1` |
| Device | iPhone 17 Pro Max |
| iOS version | Settings → General → About → Software Version |
| Timezone | Europe/Brussels |
| Migrations expected | **18**, newest `2026-08-19-run-cause` |
| Protected snapshot | Database health → Protected snapshot → the id shown |
| Ledger baseline | Import ledger → `authored: N` and `Import ledger: N rows` |

---

## 3. Safety preconditions

**Take a fresh protected snapshot before step 1.** Database health → Protected
snapshot. The most recent is `2026-08-16-211009`, which predates every patch in
this block.

- **May be mutated:** nothing. Every step in this campaign is a read or an
  additive restore that is expected to add **zero** records.
- **Must not be deleted:** `notes.json`, `commutes.json`, `moves.json`, the
  `match.decisions` preference. These are the only copies of the athlete's own
  writing and ADR-0002 promises they survive everything.
- **Rollback:** none required if every receipt reads `added 0`. If any receipt
  reads `added > 0`, that is a finding, not a fault — the restore repaired
  something — and the snapshot from the precondition is the way back if the
  result is not what was expected.
- **The unreadable-source rows are NOT run here.** Corrupting the only copy of
  an authored file on this phone is exactly what the contract forbids. See §10.

---

## 4. Exact navigation

Labels are from the current SwiftUI source.

1. **Settings** tab → **Sync & data** → **Database health**
2. Scroll to **Import ledger** → tap the title to expand → tap **⬆︎** → export
3. Scroll to **Read-back · authored** → tap the title to expand
4. Read the rows, then tap **⬆︎** → export *(this is the "before")*
5. Press **Restore the authored stores from the database**
6. Tap **⬆︎** on **Read-back · authored** again → export *(the "after")*
7. Scroll to **Import ledger** → tap **⬆︎** → export
8. **Today** tab → navigate to **Sunday 16 August** → open the **Afternoon Run**
9. Force-quit, relaunch, repeat steps 3–4

---

## 5. Independent expected result

**The two sides must not be the same reader.** The receipts come from the
STORES; the expectations come from the REPOSITORIES, through the read-back's own
lines. `ReadBacks` builds a fresh `Matcher(defaults: .standard)` and reads
`notes.json` directly, so its "app side" is not the hydrated singleton either.

| value | expectation comes from |
|---|---|
| notes | `Authored read-back` → `notes in the database:` |
| commutes | `Authored read-back` → `commute decisions in the database:` |
| match decisions | `Authored read-back` → `match decisions in the database:` |
| moved sessions | `Authored read-back` → `moved sessions in the database:` |
| authored run count | `Import ledger` → `authored:` |
| the note on 16 August | the athlete's own memory of what he wrote — the only genuinely external source in this campaign |

---

## 6. App evidence source

Every observed value is read from an **exported diagnostic block**, not from a
screenshot of a row. Patch 402 exists so this is possible: before it, the
receipts were `@State` and two exports either side of a press were byte-identical.

- `Read-back · authored` export → the `Authored restore:` block
- `Import ledger` export → `authored:` and `Import ledger: N rows`
- Settings → Version → the identity fields in §2

---

## 7. Pass/fail table

| step | action | observed in app | expected from | pass condition | evidence |
|---|---|---|---|---|---|
| 1 | Expand **Read-back · authored** | the section draws | §12.76 — 402 and 407 each added one child via `authoredRestoreRows` | opens, rows visible, no crash | screenshot |
| 2 | Export it *(before)* | `Authored restore: not run since this launch.` | §12.146 — the line is unconditional | exactly that sentence | export file |
| 3 | Read `the app side came from:` | `notes.json, commutes.json, moves.json and the stored match decisions, read directly` | `ReadBacks` builds its own readers | says `read directly` | same export |
| 4 | Read the four `in the database:` counts | N notes, N commutes, N decisions, N moves | `AuthoredRepository`, `MatchDecisionRepository`, `PlanMoveRepository` | record them; these are step 6's expectations | same export |
| 5 | Export **Import ledger** *(before)* | `authored: N`, `Import ledger: N rows` | §12.149 — a restore must open no run | record both | export file |
| 6 | Press **Restore the authored stores from the database** | four receipt lines | step 4's counts | `notes.json`, `commutes.json`, `moves.json`, `match decisions` each `added 0`, `already held` equal to step 4 | export file |
| 7 | — | no `NOT RESTORED` line | §12.148.1 — every store is attempted and each reports | absent | same export |
| 8 | Export **Import ledger** *(after)* | `authored:` and `rows` | step 5 | **unchanged** — `diff` the two files | export file |
| 9 | Press Restore a second time | identical receipts | idempotence, `restoringTwiceIsANoOp` | same four lines | export file |
| 10 | Today → 16 Aug → Afternoon Run | the note reads `RPE 5 · As expected · Eerste lange loop terug.` | the athlete's memory | text unchanged | screenshot |
| 11 | Force-quit, relaunch, re-export the read-back | the four `in the app` counts | step 4 | unchanged — the repair, or the no-op, reached the disk | export file |
| 12 | Import ledger → `Last import:` | carries `because …` | §12.150 — 406's column | a cause is present on runs opened since 406 | export file |

**Tolerances:** none. Every figure here is a count and must match exactly.

**Legitimate-empty behaviour:** `moves.json` may legitimately hold few or no
records — no gesture wrote a move until 366. `added 0, already held 0` for that
store is a pass and means the database holds none either; it is NOT the same as
a missing line, which would be a failure.

**Every failure state:**

- `added > 0` — the restore repaired something. Not a fault: it means a file had
  lost records. Stop and report before pressing anything else.
- `NOT RESTORED — …` — that store was not reached or could not be written.
- `authored:` climbs — 405 did not take; a repair is carrying permission to
  delete.
- Identical before/after exports — 402 did not take; the receipt is screen-only.
- The section does not open — §12.76.

---

## 8. Evidence capture

Retain, named by patch and step:

- `sub4-read-back-authored-<date>-p408-before.txt`
- `sub4-read-back-authored-<date>-p408-after.txt`
- `sub4-import-ledger-<date>-p408-before.txt`
- `sub4-import-ledger-<date>-p408-after.txt`
- `sub4-read-back-authored-<date>-p408-relaunch.txt`
- Screenshots: the expanded section, the Version rows, the 16 August note

**Redaction.** The exports carry counts, store names and Strava ids, which §12.7
permits. **The screenshot at step 10 shows the note's text** — the athlete's own
words about a session. Keep it locally; do not attach it to anything shared, and
do not paste its content into a public repository. It is in this campaign because
its exact content is the subject of the step, which is the contract's stated
exception.

---

## 9. Cleanup and rollback

Nothing to clean up: no setting is changed and no file is moved. If the
configuration was switched to Release for §2, switch it back to Debug and
re-tick **Debug executable**.

Verify the app returns to its pre-campaign state: the four counts in step 11
equal step 4, and the ledger in step 8 equals step 5.

---

## 10. Uncovered cases

**A partial campaign is evidence for its rows only, never for the whole slice.**

1. **THE REPAIR PATH HAS NEVER REPAIRED ANYTHING ON THIS DEVICE.** Every run
   reads `added 0`, because the files and the database agree — which is the
   healthy state and exactly what should be true. So these rows prove the
   control is **safe, reaches the disk, is idempotent and announces nothing**.
   They do not prove it **restores**. That half is carried by
   `AuthoredRestoreTests` alone.

2. **The unreadable-source path is not run here, and cannot be.** It needs a
   corrupt `notes.json`, and the only copy on this phone is the athlete's real
   one. §3 forbids it and the contract forbids it. Covered by the suite —
   `anUnreadableFileIsMovedAside`, `theVerdictMovesWithTheBytes`,
   `undecodableBytesAreCopiedAside` — and the match decisions exercise it end to
   end, because a preference suite is disposable and a file is not.

3. **No route exists to make the file and the database disagree safely.**
   Deleting a note in the app removes it from both — the save announces, the
   `.authored` trigger enables reconciliation, and the row goes with it. So the
   state a restore exists for cannot be produced through the UI on purpose.
   Reaching it would need a device-level fixture the app does not offer, and
   that is worth building before B9 rather than improvised here.

4. **Only the counts are verified on Today.** Step 10 checks one note's text.
   The commute decision, the match decisions and the moved sessions are verified
   as COUNTS in the read-back and not opened on Week or the activity detail.

5. **Release-configuration behaviour is recorded but not compared.** §2 asks
   which configuration ran; this campaign does not require both.
