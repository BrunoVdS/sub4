# Device campaign — patch 414, family-scoped reconciliation

| | |
|---|---|
| **Task** | Plan topic 1C — "make reconciliation family-scoped and every removal attributable" |
| **Patch under test** | **414** (the permission). 415 adds the removal ledger. |
| **Written at** | patch 414, 20 August 2026 |
| **ADR** | §12.159 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about eight minutes, no force-quits |
| **Run AFTER** | nothing. It deletes nothing of yours if §3 is followed. |

Required because family-scoped reconciliation is wired to **real controls** —
every authored store's save. The prompt's words.

---

## 1. Question and risk

**The question.** When the athlete saves in one family, does the run that
follows reconcile **only that family** — and does it say so?

**What changed, and why it mattered.** Until 414 one permission covered five
families, so a note save could delete a review row. The sharpest form: **nothing
in this app announces a proposal change**, so `review` could only ever be pruned
by somebody else's trigger. And `AthleteConstants` / `AthleteStore` announce
while owning no family at all — an athlete constant save asked for, and got,
permission to delete from all five.

**The risk now is the opposite one:** a family that no longer reconciles when it
should, leaving rows the athlete deleted. Row 5 is that check.

---

## 2. Where everything is

**Settings → Sync & data → Database health.** Tapping a title expands; **⬆︎**
exports either way.

| what | where | reads |
|---|---|---|
| **the decision** | **Import** → ⬆︎ | `reconciled: <families>` |
| the families' counts | **Read-back · authored** → ⬆︎ | four subheadings |
| the authority | **Rows — 51 tables** → ⬆︎ | `user_note`, `correction`, `match_decision`, `review` |
| the trigger | **Import ledger** → ⬆︎ | `Last import: … · authored · … · because …` |

**`reconciled:` is the line this patch is about.** Before 414 it read `yes` or
`skipped — …`. It now names the families that were permitted:

| reading | means |
|---|---|
| `notes` | a note save; only the notes family may lose rows |
| `commute decisions` | a commute toggle |
| `match decisions` / `moved sessions` | the picker |
| `skipped — the change belongs to no reconcilable family` | an athlete constant or the athlete cache — **new at 414**, and it used to be all five |
| `skipped — an automatic write-through does not delete` | backgrounding, foregrounding, background refresh |
| `<family>: the source could not be read` | the gate refusing that family on its own merits |
| `no family — every one asked for had an unreadable source` | a manual import where every family was refused |

**`Import` shows the LAST write-through run, whichever trigger fired it** —
`LastImport.record` is unconditional. So after a note save it describes the note
save.

---

## 3. Safety preconditions

- **Nothing here deletes anything of yours**, provided you do not delete a
  record first. Rows 1–4 are read-only observations of the permission.
- **Row 5 is the only step that removes a record**, and it uses a note you
  create for the purpose. **Never use a note you wrote about a real session.**
- **Do not press Import** during the run; a manual import requests every family
  and would mask the narrowing.
- **`review` must not be used as disposable data.** The first real review is
  24 August. Row 3 observes it and never touches it.
- Take the four "before" exports first.

---

## 4. Exact navigation

### Before

1. **Settings** → **Version** → **Source patch** must read **`414`**.
2. **Database health**, each with **⬆︎**: **Rows — 51 tables** (record
   `user_note`, `correction`, `match_decision`, `review`), **Read-back ·
   authored**, **Import**, **Import ledger**.

### The narrowing

3. **Today** → a completed session with no note → **Add a note** → RPE 5, text
   `414`, **Save**.
4. **Database health** → **Import** → **⬆︎**. Read `reconciled:`.
5. **Today** → a completed ride → the row headed **Commute** → tap the
   **bicycle glyph**.
6. **Database health** → **Import** → **⬆︎**. Read `reconciled:`.

### The family that owns nothing

7. **Settings** → change an athlete constant (anything under the athlete
   figures) and save it.
8. **Database health** → **Import** → **⬆︎**. Read `reconciled:`.

### The delete still works

9. **Today** → the session from step 3 → the **Note** card → **Delete** →
   confirm.
10. **Database health** → **Rows — 51 tables** → **⬆︎**, and **Read-back ·
    authored** → **⬆︎**.

---

## 5. Pass / fail

| # | after step | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 4 | **Import** → `reconciled:` | **`notes`** | `yes`, or several families | `yes` means 414 did not land. Several families means the trigger still widens — the defect. |
| 2 | 6 | **Import** → `reconciled:` | **`commute decisions`** | `notes`, or several | The family is taken from the trigger, so a stale one means the announcement is not carrying it. |
| 3 | 8 | **Import** → `reconciled:` | `skipped — the change belongs to no reconcilable family` | any family named | **The athlete stores own no family.** Before 414 this run held permission over all five. |
| 4 | 2→10 | **Rows — 51 tables** → `review` | **unchanged throughout** | any change | A review row moved during a run triggered by notes or commutes. This is topic 1C's stated failure, on the device. |
| 5 | 10 | `user_note`, and **Notes · In each side** | back to the step-2 figures | the note survives | **The narrowing went too far** — the family that DID change must still reconcile. A permission that deletes nothing is not safer, it is broken in the other direction. |
| 6 | 10 | **Read-back · authored** — commutes, match decisions, moved sessions | unchanged from step 2 | any moved | An unrelated family lost or gained rows during the note's delete. |
| 7 | throughout | **Import ledger** → `Last import: … · authored` | the trigger reads `authored` with its cause | — | Corroboration: the runs under test are the authored ones, not a background refresh that happened to overlap. |

**Rows 1, 3 and 4 are the campaign.** Row 5 is the counterweight and is easy to
forget: this patch removes permissions, so the thing to prove is not only that
it deletes less.

---

## 6. What this does not cover

- **The removal attributed to a family in the ledger.** `migration_run_removal`
  is **415**. Today `newest removal` still names the trigger, not the family
  (§5.5), so row 4 proves the review was not touched by observing the count —
  not by reading a ledger row that says which family removed what. The prompt
  asks for that capture and it is owed.
- **A family refused for its own unreadable source.** Making a store unreadable
  on a phone means damaging it. The suite covers it (`theGateStillRefuses`).
- **The manual all-families path.** Pressing Import requests every family, which
  is correct and is what §3 tells you not to do mid-run.
- **Reviews reconciling at all.** No control announces a proposal change, so
  `.reviews` is asked for only by a manual import. That is the pre-existing
  shape, unchanged by 414 and noted in §12.159.1.

---

## 7. Result

*Not yet run.* Fill in `DEVICE-CAMPAIGN-409.md` §10's shape.
