# Moving a session, and saying you skipped one

Groundwork for patches 359–364. Written 14 August 2026, against patch 358a.
No code in this document is committed; it is the record of what was decided
before any of it was written, so that a patch which turns out wrong can be
argued with rather than guessed at.

---

## 1. What was asked

> When we do activities on a different day than planned we need to be able to
> couple the 2 and change the date of the planned activity to the day we did
> the workout. Should be for every type of workout in the plan.
>
> When we skip a workout, the day after a toggle should appear where we can
> switch on skipped.

Two features. One writes a new fact about a planned session (it happened on a
different day); the other writes a fact that **already exists in this app under
another name**.

---

## 2. Is it possible

Yes, and it is cheaper than it looks, for two reasons.

### 2.1 There is one choke point

`Session.date` is read in about ten places — `PlanStore.rebuildIndexes`
(which builds `byDate`, and therefore every day-oriented screen),
`LoadStore`, `Matcher`, `PlanFocus`, `PlanStore.nextSession`,
`NoteEditorView`, `ProposalView`, and the plan read-back's own counts.

Every one of them reads the same field on the same struct. So a move does not
need ten readers taught about corrections: it needs the override applied
**once, where a `Plan` is built**, and all ten are correct without knowing
anything about it. §12.43.

That is the whole feasibility argument. If the date had been derived
independently in three of those places, this would be a different document.

### 2.2 The table already exists, and was built for exactly this

`correction` was created in the domain migration on 4 August:

```
subjectKind   TEXT NOT NULL  CHECK (subjectKind IN ('activity', 'planSession'))
subjectID     TEXT NOT NULL
field         TEXT NOT NULL
value         TEXT
reason        TEXT NOT NULL
authoredUTC   TEXT NOT NULL
UNIQUE (accountID, subjectKind, subjectID, field)
```

`'planSession'` is in that CHECK constraint and **has never been used**. One
row per session per field is exactly the shape a moved date needs:

```
('planSession', 'wk-03-sun-long', 'date', '2026-08-17', <provenance>)
```

**So feature A needs no migration at all.** The seventeen migrations this app
has are append-only forever; not adding an eighteenth is worth something.

---

## 3. The four decisions

Taken 14 August. Each of them changes what gets built.

### 3.1 A move changes the date and not the week

`Session` carries `weekUid` separately from `date`. Moving Sunday's long run to
Monday puts it in the next calendar week.

**Decided: the date moves, the week membership does not.** The session shows on
the day it was done; the Week view and the week's planned-km statistic keep it
where the plan put it.

The reasoning is that the plan said that week, and what moved is *when you did
it*. The alternative — re-homing `weekUid` — means the app starts overriding
`plan_week_stat`, which is imported plan data, and the plan read-back's
week-stat comparison stops being a straight comparison. That is a much larger
change for a distinction nobody is asking about.

**The cost, stated plainly:** a session can appear in one week's list and on a
day inside the next one. That is not a bug and the UI should not hide it — see
§7.3.

### 3.2 "Skipped" is the fact this app already stores

The match picker's **Not done** already writes

```swift
Matcher.setOverride(session: session, activity: nil)
→ MatchDecision(sessionUid:, activityId: nil, decided:, dateIsKnown: true)
```

which the schema and the repository both document as *"explicitly nothing
satisfied this session"* — a row with a NULL in it, distinct from no row at
all. `Matcher.isComplete` already returns false for it. `MatchDecisionLoad`
already round-trips it, and as of 358 it hydrates from `match_decision`.

**Decided: the toggle writes that, and nothing new is invented.**

A second `correction('planSession', uid, 'skipped', 'true')` would cover nearly
the same ground and give two places that can disagree about whether a session
is done. §12.43 — do not reimplement a rule, call it.

The consequence worth naming: the toggle and the picker's **Not done** become
two doors into one state, and turning the toggle off is
`Matcher.clearOverride(sessionUid:)` — which is also what the picker's **Back
to automatic** does. Three controls, one fact. They must agree on screen, which
is why 359 comes first.

### 3.3 The move starts from the activity

**Decided: in the Fix match flow.** You are looking at today's run, you say
"this was Wednesday's Easy", and one gesture records the match *and* moves that
session to today. That is literally "couple the 2 and change the date".

This is where the existing UI stops being enough — see §6.

### 3.4 The toggle appears on past sessions with nothing matched

**Decided.** From the day after, any session in the past with no activity
against it carries the toggle. A matched session does not need one; today's
sessions are not overdue yet.

---

## 4. What exists today

| Piece | State |
|---|---|
| `correction` table, `subjectKind = 'planSession'` | in the schema since 4 Aug, **0 rows, never written** |
| `correction` writer (`Sub4Import+Correction`) | writes `('activity', id, 'isCommute', …)`; prunes **only** its own field |
| `MatchDecision` / `match_decision` | 3 rows, round-trips, hydrates from the database as of 358 |
| `MatchPickerView` ("Fix match") | opens **from a session**, lists activities **on that day** |
| "Change match" on an activity | only rendered `if let s = session` — an unmatched activity has no way in |
| `Session.date` | `let`, decoded from `plan.json` / `plan_session`; no override anywhere |
| `PlanStore.byDate` | rebuilt from `session.date` in `rebuildIndexes()` — the choke point |

## 5. What does not exist

1. **An authored store for plan-session corrections.** Notes, commutes, match
   decisions, the athlete cache and the constants each have a file, a
   write-through and a read-back. A move needs the same: `moves.json`.
2. **A sheet that picks a session for an activity.** Today's picker runs the
   other way round.
3. **Any application of a `planSession` correction.** Nothing reads that half
   of the table.
4. **A qualified `corrections` comparison** — see §8.1. This one is blocking.

---

## 6. Feature A — moving a session

### 6.1 The record

```swift
struct PlanMove: Codable, Hashable, Identifiable {
    var sessionUid: String     // plan_session.uid
    var movedTo: String        // "yyyy-MM-dd"
    var decided: Date
    var id: String { sessionUid }
}
```

`PlanMoveStore` follows `CommuteStore` exactly: a dictionary keyed by
`sessionUid`, `moves.json` in Application Support, memory-follows-disk on
save, and `DatabaseWriteThrough.noteAuthoredChange` fired **after** a
successful write and never before (§12.94 — the rule 348 established and B2
made load-bearing).

`clear(_:)` exists, because "I moved it back" is a real answer distinct from
"I never moved it".

### 6.2 The mapping

```
subjectKind   "planSession"
subjectID     PlanMove.sessionUid          — the plan's own uid, not remapped
field         "date"
value         PlanMove.movedTo              — "yyyy-MM-dd"
authoredUTC   PlanMove.decided
reason        provenance, one sentence, true of every row without exception
```

`subjectID` is **not** resolved through an alias table, unlike the commute
decisions. A plan session uid is the plan's own identifier and there is nothing
to remap it through. §8.2 covers what happens when the plan reissues one.

The prune claims `subjectKind = 'planSession' AND field = 'date'` and nothing
else, on the same `Reconciliation` gate as notes, reviews, match decisions and
commutes. `Sub4Import+Correction` already prunes only `field = 'isCommute'`,
so the file's existing structure anticipated a second claimant.

### 6.3 Applying it — the choke point

One function, called from both sides of the read-back:

```swift
PlanCorrections.apply(_ plan: Plan, moves: [PlanMove]) -> Plan
```

It rewrites `Session.date` for every session named by a move and returns the
plan. Called:

- in `PlanStore` wherever `plan` is set — the bundle decode **and**
  `hydrate(from:)`
- in `PlanRepository.load` when assembling sessions from `plan_session` rows

**Both sides, deliberately.** If only the store applied it, the plan read-back
would report every moved session as a field that differs, and the honest fix
would be an "approved difference" that grows without bound. Applying it on both
sides means the two agree and the comparison stays a comparison. §12.99 is the
record of what happens when a check stops being able to fail; this is the
opposite mistake and it is just as bad.

**One applier, two callers.** A second implementation is a second opinion about
where a session is (§12.43, and it is the twelfth application of that rule in
this project).

### 6.4 The UI

Two changes to the activity detail sheet:

1. **"Change match" renders unconditionally.** Today it is inside
   `if let s = session`, so an activity that matched nothing — which is exactly
   the case where you want to say "this was Wednesday's session" — has no way
   in.
2. **A new sheet, running the other way round.** It lists *sessions* for an
   activity, from a window around the activity's day, with the ones that have
   nothing matched first, plus "Nothing planned — this was extra".

Choosing a session on another day performs **two writes, in this order**:

```swift
Matcher.setOverride(sessionUid: s.uid, activityId: activity.id)
PlanMoveStore.shared.move(sessionUid: s.uid, to: activity.dayKey)
```

Match first, because a move whose match did not land leaves a session sitting
on a day with nothing against it — which the §3.4 toggle would then offer to
mark skipped. The reverse failure is harmless: a match without a move is
today's behaviour.

Choosing a session on the *same* day writes only the match. There is nothing to
move, and a `correction` row saying `date = <the date it already has>` is a row
that means nothing and would have to be pruned by hand later.

---

## 7. Feature B — the skipped toggle

### 7.1 What it writes

```
on   →  Matcher.setOverride(sessionUid: s.uid, activityId: nil)
off  →  Matcher.clearOverride(sessionUid: s.uid)
```

No new store, no new field, no migration. Both already fire the write-through
and both already round-trip.

### 7.2 Where it appears

On a session card and in the session detail, when **all** of:

- the session's effective date (after §6.3) is strictly before today
- nothing is matched against it
- it is not a rest day

The "day after" in the request is the first of those three: a session dated
yesterday qualifies from midnight.

### 7.3 What it looks like

From the 14 August observation, and it applies to the picker too:

- **Skipped is a negative state and should read as one** — a filled red
  control with an X glyph, not a row styled like the others.
- **The current state must be visible.** Today the picker shows no indication
  of which choice is recorded, so a tap that wrote a decision and a tap that
  did nothing look identical. This is why 359 is first: the toggle would
  inherit the same defect.
- A session showing on a day inside a week it does not belong to (§3.1) should
  say so on the card — one line, "moved from Sunday" — rather than being
  silently in the wrong place. §12.54.2: a row that only appears when something
  is wrong cannot be told from one nobody wired in, so the line prints whenever
  a move exists, not only when it looks odd.

---

## 8. Three things that will bite

### 8.1 The `corrections` comparison is unqualified — BLOCKING

```swift
.compare("corrections", table: "correction",
         expected: commutes.filter { storeIDs.contains($0.activityId) }.count,
         found: try count(d, "correction")),
```

`expected` counts commute decisions. `found` counts **every row in the table**.
They agree today only because commute decisions are the only rows there.

**The first `planSession` correction ever written makes the verifier fail**, and
it will fail with `corrections [correction]: expected 1, found 2` — a sentence
that sends somebody to look at the commute decisions.

This was parked as a latent defect on 13 August. It is now on the critical
path and must be fixed **before** anything writes a plan-session correction.
Patch 360, and it is provable today: the numbers do not change, but the check
becomes able to fail for the right reason. §12.69.

### 8.2 A move is keyed on a uid the plan can reissue

`plan_session.uid` carries the session's `seq` — its position within its day
(§12.96.3). A new plan version that changes what is on a day reissues uids, and
a move naming an old one is orphaned.

**This is the exposure the notes already have** and it has been accepted since
274: a note is keyed the same way. `PlanVersionCensus.uidsHeldOnlyBy` already
surfaces uids that only one version holds, and the paste already lists them.

An orphaned move is harmless in a way an orphaned note is not: the session
simply shows on its planned day. Nothing is lost and nothing is wrong; the
correction row is dead weight the reconciliation prune removes. Worth stating
because the opposite assumption — that a move is durable across plan
versions — would be wrong.

### 8.3 `AppStores.fieldCount` moves, and a pinned test with it

A new store is an eighteenth field on `AppStores`, whose count is pinned at 17
by `ImporterSeedTests`. That pin exists precisely so adding a table is a thing
somebody acknowledges rather than forgets, and the patch that adds `moves`
moves it to 18 deliberately.

---

## 9. The patch plan

Six patches. The order is not arbitrary: each one is provable on its own, and
nothing writes a plan-session correction until the verifier can survive it.

| # | What | Why here |
|---|---|---|
| **359** | The picker shows the recorded choice; "Not done" reads as destructive; the three missing `… store reads:` lines in the paste | The toggle inherits this UI. Fixing it after building on it means fixing it twice. No data model. |
| **360** | `corrections` qualified by `subjectKind` and `field` | Blocking (§8.1). Provable today — the counts do not move and the check becomes able to fail. |
| **361** | `PlanMoveStore`, `moves.json`, `AppStores` → 18, the importer's second claim, the read-back's coverage of it | Machinery only. Nothing applies a move yet, and a test says so. |
| **362** | `PlanCorrections.apply`, called from `PlanStore` and `PlanRepository` | The flip. This is the patch where a stored move changes what the app shows. |
| **363** | "Change match" unconditional; the reverse picker; the two writes | The gesture Bruno asked for. |
| **364** | The skipped toggle | Last, because it is the smallest and it depends on 359's styling. |

361 and 362 are deliberately separate for the reason B1 and B2 both proved:
a flip whose diff contains nothing else is a flip whose failures are
attributable. That has now paid twice — four failures at 346, and at 358 the
one line that mattered was visible in a diff of one line.

## 10. What this deliberately does not do

- **It does not move an activity.** Activities are Strava's record of what
  happened and the app does not edit them. A move changes the *plan's* idea of
  when a session was due.
- **It does not recompute week statistics** (§3.1).
- **It does not offer a move without a match.** Q3 settled the trigger as the
  activity, so a session is always being moved *to* something. Moving a session
  you have not done yet — rescheduling forward — is a different feature and is
  not in these six patches.
- **It does not touch the review flow.** `proposal_change` already names
  session uids and is empty; whether a review may propose a move is a question
  for B7, not for this.
