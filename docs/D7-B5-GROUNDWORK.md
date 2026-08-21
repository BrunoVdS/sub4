# D7 slice B5 — weather and gear: groundwork

| | |
|---|---|
| **Slice** | D7 B5 — weather and gear |
| **Written at** | patch 424, 21 August 2026 |
| **Task** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md` §5, "B5 groundwork, no flip" |
| **Pattern** | `D7-B4-GROUNDWORK.md` and `D6C-SHADOW-PARITY-GROUNDWORK.md` |
| **Status** | **Groundwork only. Nothing flips. §5 asks for decisions, and §6 is the list Bruno must approve before a line is written.** |

**B5 is two slices wearing one name, and they are not the same size.**

**Weather is nearly done.** Twelve columns, eleven compared per reading, a
tested restore path, a unique key on `activityID`, and 603 rows on the device.
Nothing about weather is lossy. It needs a hydration case, a store read and a
flip.

**Gear is not a database-backed presentation at all.** It is written, it round
-trips on two fields, and **three facts the athlete can see are not in the
database in any form.** That is what this document is about.

---

## 1. Question and risk

**The question B5 answers: when Strava is switched off, is what remains a
complete account of this athlete's gear?**

Not *does the app still work* — it does, from files. ADR-0002 retires Strava,
and §12.68 already recorded the consequence for one field: **whatever is in
`gear.distanceM` on that day is the mileage for ever, because there is no
second copy to reconcile against afterwards.** Patch 325 fixed distance for
exactly that reason.

**The same argument applies to three more facts and has not been made for
them.** Every one is knowable today and stored nowhere.

**The risk is not a wrong screen. It is a silent, permanent loss** on a day
nobody will be watching, of facts that cannot be recovered once the endpoint
is gone.

---

## 2. Inventory — every consumer

### 2.1 `WeatherStore` — 14 production files

`ActivityDetailView` · `AppStores` · `CommuteStore` · `DataControlsView` ·
`DataLifecycle` · `DataLifecycleCoordinator` · `DatabaseHealthView` ·
`NotesStore` · `PlanMoveStore` · `ReadBacks` · `SemanticVerifier` ·
`StoreRestore` · `Sub4Import+Weather` · `Weather`

Six test files besides. **One rendering surface**: the weather card on
`ActivityDetailView`. Everything else is import, restore, lifecycle or
diagnostics.

### 2.2 The gear surface on `AthleteStore`

| member | what it is |
|---|---|
| `shoes: [Shoe]` | what the athlete endpoint lists as shoes **now** |
| `bikes: [Shoe]` | what it lists as bikes now. **A separate array rather than a `kind` on `Shoe`** — and the reason is in the source: `Shoe.wear` uses 600/800 km, which are running-shoe numbers and wrong for a bike |
| `retired: [Shoe]` | **inferred, not reported** — see §2.4 |
| `allGear` | `shoes + bikes + retired`, flattened |
| `shoe(id:)` | looks in `shoes` only |
| `gear(id:)` | looks in `allGear` |
| `activeShoes` | `shoes`, sorted by distance |

### 2.3 Where gear is RENDERED, and it is one place

**`ProgressTabView`'s shoes section, and it reads `activeShoes`.** Bikes and
retired gear are held, written to the database, compared by the read-back —
**and drawn on no screen at all.**

That is the scoping fact for this slice: **B5's flip risk to the UI is one
section showing active shoes. B5's real risk is losslessness.**

### 2.4 Retirement is INFERRED, and this is the finding that shapes the slice

`resolveRetiredGear` — "there is no such list. The athlete endpoint returns
current gear only, so the only evidence a retired shoe ever existed is that 51
activities name it." It takes the gear ids named by activities, subtracts what
the two live arrays hold, and fetches each missing id (capped at ten a run).

**Two consequences.**

1. **Retirement is membership of `retired`, which is membership of neither
   other array.** It is a derived fact about an absence.
2. **`fetchGear` cannot say what the thing was.** Its `DetailedGear` decodes
   `id`, `name`, `distance`, `primary` — no type. **So a retired BIKE and a
   retired SHOE are indistinguishable**, and both land in `retired` where
   `Shoe.wear`'s running thresholds apply. Latent today only because nothing
   renders `retired`.

### 2.5 `knownActivityIDs`

`WeatherGearRepository.readingsOnlyInDatabase(knownActivityIDs:)` — the app's
own roster, passed in so a reading for an activity the app no longer holds is
not counted as a difference. **`ReadBacks` supplies it as
`Set(ActivityStore.shared.activities.map(\.id))`, and `ActivityStore` has been
database-fed since 381.** §5.5 already names this as the part of the weather
read-back that is not evidence. **B5 must give it a file-side roster** or say in
the paste that this one filter is self-referential.

---

## 3. Schema inventory

### 3.1 `gear` — patch 205, migration `2026-08-04-domain`

`id` (pk) · `accountID` → account · `sourceID` → source, nullable ·
`externalID`, nullable · `name` · `distanceM` ≥ 0 · **`retiredUTC`** ·
unique index on `(accountID, sourceID, externalID)` where `externalID IS NOT
NULL`.

### 3.2 `activity_gear_reference` — patch 216, `2026-08-05-gear-reference`

`id` (pk) · `activityID` → activity, CASCADE · `sourceID` → source, RESTRICT ·
`externalID` **notNull, and deliberately no foreign key to `gear`** ·
`notedUTC`. Unique on `(activityID, sourceID)`; index on
`(sourceID, externalID)`. **503 rows on the device.**

### 3.3 `weather` — `2026-08-04-domain`

`id` (pk) · `activityID` unique · `provider` · `tempC` · `feelsLikeC` ·
`humidity` · `windKmh` ≥ 0 · `windFromDegrees` · `precipitationMm` ·
`symbolName` · `conditionLabel` · `samples` > 0 · `fetchedUTC`.
**603 rows on the device.**

### 3.4 What `importGear` actually writes

**Six columns: `id, accountID, sourceID, externalID, name, distanceM`.**
`retiredUTC` is never written. A refresh updates **`name` and `distanceM` only**,
and only when one of them moved (patch 325, §12.68).

**And it is handed `s.gear = AthleteStore.shared.allGear`** — shoes, bikes and
retired, flattened into one `[Shoe]` before the importer sees them. **The
importer is not discarding the kind; it is never told.**

---

## 4. The field matrix

`preserve` — must survive Strava · `normalize` — deliberately reshaped ·
`derive` — recomputable from what is kept · `discard` — recorded as not worth
keeping.

| # | fact | held today | in the database | class | note |
|---|---|---|---|---|---|
| 1 | external gear id | `Shoe.id` | `gear.externalID` | **preserve** | done |
| 2 | canonical gear id | — | `gear.id` (UUID) | **preserve** | §3.1's rule: Strava ids are never primary keys |
| 3 | name | `Shoe.name` | `gear.name` | **preserve** | done; refreshed since 325 |
| 4 | lifetime distance | `Shoe.distanceM` | `gear.distanceM` | **preserve** | done; refreshed since 325. §12.68's frozen number |
| 5 | **bike vs shoe** | **array membership** | **nothing** | **preserve** | **§6 decision 1.** Not recoverable after Strava: the endpoint is the only thing that ever said which |
| 6 | **retired vs active** | **array membership** | `retiredUTC` exists, never written | **preserve** | **§6 decision 2.** Inferred today (§2.4); still inferable from `activity_gear_reference` afterwards, but only while the references survive |
| 7 | **retirement date** | **not held at all** | `retiredUTC` | **derive or discard** | **§6 decision 3.** Strava does not give one. The last activity naming the gear is the best available proxy |
| 8 | primary / default | `Shoe.primary` | nothing | **discard** | already an approved difference (patch 324): Strava's preference, not a fact about the shoe |
| 9 | provenance | — | `gear.sourceID` | **preserve** | done |
| 10 | unknown gear reference | — | `activity_gear_reference` | **preserve** | done, 503 rows, deliberately unconstrained |
| 11 | activity → gear | `Activity.gearId` | `activity.gearID` → `gear` | **preserve** | done |
| 12 | wear state | derived from #4 | — | **derive** | correctly absent. **But it is derived with SHOE thresholds** — see decision 1 |
| 13 | every weather field | `ActivityWeather` | eleven columns | **preserve** | done, compared, restorable |
| 14 | weather provider | `source ?? .openMeteo` | `provider` | **normalize** | the default is applied on read; the column is notNull |

**Rows 5, 6 and 7 are the slice.** Everything else is already right.

---

## 5. What the round trip proves today, and what it cannot

`WeatherGearRoundTrip` compares **eleven fields per weather reading** and
**two per gear item — the name and the distance.** Its `approved` list, written
at patch 324, already names both gaps and gives reasons:

- **`Shoe.primary`** — "no column… a preference held on their side… The
  database keeps what survives Strava's retirement." **Still the right call.**
- **`gear.retiredUTC`** — "a column the importer has never written, and there
  is no field to compare it against… retirement is known at decode time and
  thrown away twice."

**324 was right that it is thrown away and did not say what it costs.** This
document is that argument: after Strava, *thrown away* becomes *gone*.

**And there is no approved entry for bike-versus-shoe at all**, because with
`allGear` flattened before the comparison, neither side knows the kind — so
there is nothing to disagree about. **A difference that cannot be expressed is
not on any list.** §12.132's shape in a comparison rather than in a category.

---

## 6. THE DECISIONS BRUNO MUST APPROVE

**Nothing is built until these are answered. Each one changes the migration.**

### Decision 1 — does the database record bike versus shoe?

**What is lost if not:** after Strava, `gear` is a flat list of names and
distances. Nothing can tell a bike from a shoe, so nothing can ever show bike
mileage separately, and `Shoe.wear`'s 600/800 km thresholds — written for
running shoes and explicitly wrong for bikes — become the only interpretation
available. **The endpoint is the only thing that has ever said which**, so this
is not recoverable later.

**Recommendation: YES — add `kind` to `gear`.** It is one additive column, the
fact is free today, and the alternative is unrecoverable. **`Shoe` also needs to
carry it**, so `allGear` stops being lossy before the importer is reached.

### Decision 2 — does the database record retired versus active?

**What is lost if not:** the same flat list. Retirement can still be *inferred*
after Strava — gear named by activities but not in the current list — but only
while `activity_gear_reference` survives and only if something rebuilds the
inference. Today that inference is made by a function that calls Strava.

**Recommendation: YES — write `retiredUTC`,** using decision 3's rule, and treat
a non-null value as retired.

### Decision 3 — what date does a retired shoe get?

**Strava does not report one.** Three options:

| | rule | honest? |
|---|---|---|
| a | the date of the **last activity naming it** | **Yes — and it is a real fact**, derived from data the app owns. It is not "when the athlete retired it"; it is "when it was last used", which is what the mileage means anyway |
| b | the date the app first noticed it missing | Records when the app looked, not when anything happened. §12.15's shape as a timestamp |
| c | leave null and add a `retired` boolean | Honest but loses ordering — a shoe list with no dates cannot be sorted by when it stopped |

**Recommendation: (a), and name the column for what it holds.** `retiredUTC`
already exists and would be a lie under rule (a). **Prefer a new
`lastUsedUTC`** plus retirement as `kind`-independent membership, or accept
`retiredUTC` with a written definition. **This is the decision with the most
room to get wrong**, which is why it is asked rather than assumed.

### Decision 4 — is a retired BIKE representable?

Following from §2.4: `fetchGear` returns no type, so a retired bike arrives
untyped. Under decision 1 it would get `kind = unknown` rather than a guess.

**Recommendation: a three-valued kind — `shoe`, `bike`, `unknown`** — and
`unknown` renders with no wear bar at all rather than with shoe thresholds. **A
category defined as "not the other one" swallows something that is neither**
(§12.132); this is the third bucket, printed.

### Decision 5 — does B5 give `knownActivityIDs` a file-side roster?

Its only caller passes `ActivityStore.shared`, database-fed since 381. **Either
give it `activities.json` read directly through the existing seam, or print in
the paste that this filter is self-referential.**

**Recommendation: the seam.** 419 did exactly this for the athlete read-back
and the roll-up's self-referential count reached zero (§12.168). Leaving one
behind at B5 would undo that.

---

## 7. The additive migration, if §6 is approved as recommended

**A migration is history. This is a NEW dated file** — nothing already applied
is edited (§12.1).

`2026-08-21-gear-kind`:

- `ALTER TABLE gear ADD COLUMN kind TEXT NOT NULL DEFAULT 'unknown'`
  with `CHECK (kind IN ('shoe','bike','unknown'))`.
  **The default is `unknown`, not `shoe`** — every existing row was written
  without the fact, and `unknown` is what that is. Defaulting to `shoe` would
  invent 100% confidence in the past.
- `ALTER TABLE gear ADD COLUMN lastUsedUTC TEXT` if decision 3 takes rule (a)
  under a new name.
- **No change to `activity_gear_reference` or `weather`.** Both are complete.

**The vocabulary is frozen the moment it ships** and must be coupled to the
Swift enum by test, as `WorkQueueTests.theFrozenStatesStillMatchTheSchema` does
for `work_queue` (§12.1).

---

## 8. The comparison seam, and the flip

### 8.1 The seam

`WeatherStore` and `AthleteStore` both already offer `init(directory:)` —
RULE 13's population counts them. **The file side of B5's read-back can read
`weather.json` and `athlete.json` for itself**, exactly as 419's
`athleteSources()` does. `WeatherGearRoundTrip` gains kind and retirement as
compared fields, and both leave the `approved` list.

### 8.2 The flip is two patches and one line, as every slice before it

1. **Machinery**: add `case weather, gear` to `PersistenceMode.Family`, read
   both in the bootstrap, build the repository read, **and do not add them to
   `hydratedFamilies`.** Nine families read, seven fed — the gap is the slice.
2. **Flip**: add `.weather, .gear` to `hydratedFamilies`. **Nothing else in
   that patch**, so any failure is attributable — 346's four were, 382's three
   were, 398's zero were.

`AthleteStore.hydrate` currently sets
`.partial(fromDatabase: "zones and FTP", fromFiles: "gear, until slice B5")`.
**The flip makes that line whole**, and it is the one-line proof on the device.

---

## 9. Negative controls and focused tests

**Each fails before the change and passes after.** §12.69: write the failing
version first and watch it fail.

| # | control | proves |
|---|---|---|
| 1 | a bike imported and read back keeps `kind = bike` | decision 1 landed. **Fails today** — nothing carries the kind |
| 2 | a retired shoe round-trips as retired | decision 2 landed |
| 3 | gear written before this migration reads `kind = unknown`, **not `shoe`** | the default does not invent a fact |
| 4 | an unknown-kind item renders **no wear bar** | decision 4, and §12.132's third bucket |
| 5 | the schema's `kind` vocabulary equals the Swift enum's | the frozen-vocabulary coupling (§12.1) |
| 6 | a weather reading whose activity the app no longer holds is **not** a difference | `knownActivityIDs` still filters |
| 7 | the same, with the roster read from `activities.json` | decision 5 — and it must **fail** if the roster is taken from the store |
| 8 | hydrating gear **writes nothing** | RULE 8, and the rule cannot see a family it does not know |
| 9 | zero gear compared to zero gear does **not** pass as agreement | the denominator, §12.54.2 |
| 10 | `allGear` order does not change what is written | flattening is not the place a kind is decided |

---

## 10. Performance

**Expect no measurable change, and say so before measuring.** `gear` is tens of
rows and `weather` is 603 — four orders of magnitude below the 199,848 sample
rows that cost 0.32–0.40 s (§12.174).

**But B5 adds two families to the launch path**, which is precisely where
§12.174 set a threshold. **Record `Launch:` and `Detail store built` in Release
before and after the flip.** If the stall passes **1.0 s**, B6a is promoted to
the next patch.

---

## 11. Rollback

Two edits, as every slice since B1: **remove `.weather` and `.gear` from
`hydratedFamilies`**, or set `sliceUnderTest` to nil. `weather.json` and
`athlete.json` are still written and still complete — that is what makes a
slice a slice, and it is why hydration must not write.

**The migration is not rolled back and does not need to be.** An additive column
nothing reads is inert.

---

## 12. Acceptance evidence

- Read-back compares **kind and retirement**, and the `approved` list is down to
  `Shoe.primary` alone.
- Roll-up still reads **0 read a store the database feeds** (§12.168).
- `Athlete store reads: the database` — no `until slice B5`.
- The verifier's independent count is recorded before and after; **it will
  fall**, and that is what a slice landing looks like.
- The campaign below, run.

---

## 13. The B5 device campaign

*Written now, run after the flip.* All ten contract parts; **§6's decisions
change §13.4's rows, so this is a draft until they are answered.**

### 13.1 Question and risk

Whether gear renders correctly from SQLite, whether the three recovered facts
survive a round trip, and whether the files can be removed without the app
losing anything.

### 13.2 Build and data identity

Patch, **Configuration (Release for any timing row)**, device, iOS, 19+
migrations, 52+ tables, snapshot id, and **the gear inventory read independently
from `athlete.json`** — shoes, bikes, retired, and the count of each.

### 13.3 Safety preconditions

**§13.6 removes files, so this is the first B-slice campaign that is not
read-only.** A protected snapshot is **required** before step 1, and
**`athlete.json` is the only copy of the retired-gear inference** — never use
the only copy of authored data for a destructive test. Rehearse the removal on
a copy first.

### 13.4 Exact navigation

1. **Settings → Version** — identity, screenshot.
2. **Progress tab → the shoes section.** Every active shoe, its distance and
   its wear colour. **This is the only gear rendering in the app.**
3. **Database health → Read-back · weather and gear** → **⬆︎**.
4. **Rows** → `gear`, `activity_gear_reference` (503), `weather` (603).
5. **An activity with weather** → its weather card: temperature, feels-like,
   wind with its compass point, humidity.
6. **An activity with NO weather** — the card must be absent, not zeroed.
7. **An activity naming unknown gear** — from `gearUnresolved`.
8. **A bike activity** — gear named, and **no shoe wear bar**.
9. **A retired shoe** — reachable only through the read-back's own list.

### 13.5 Pass / fail — the rows that matter

| # | figure | passes | fails | meaning |
|---|---|---|---|---|
| 1 | `Athlete store reads` | `the database` | `…the app's own files for gear, until slice B5` | the flip did not land |
| 2 | gear compared | **every item, four fields** | two fields | decisions 1–2 did not reach the comparison |
| 3 | approved differences | **`Shoe.primary` only** | `gear.retiredUTC` still listed | decision 2 did not land |
| 4 | shoes section | identical to the pre-flip screenshot | any distance moved | the flip changed a number, which it must not |
| 5 | a bike | no wear bar | a wear bar | decision 4 — shoe thresholds on a bike |
| 6 | no-weather activity | the card is **absent** | `0 °C`, `0 km/h` | an absence drawn as a measurement |
| 7 | `Launch:` in Release | stall **under 1.0 s** | at or above | §12.174's threshold — B6a is promoted |

### 13.6 The removal rehearsal

**Last, and only after everything above passes.** Take a snapshot, move
`athlete.json` and `weather.json` aside (**move, not delete**), force-quit,
relaunch, and confirm the shoes section and the weather cards are unchanged.
**Then put them back** and confirm the read-back reads its own side again — a
read-back that cannot read its file says `COULD NOT READ ITS OWN SIDE`, and
seeing that state deliberately is the only way to know the red row works.

### 13.7 Uncovered

A retired **bike** — this athlete may have none, and if so decision 4 stays
untested on the device and says so. Gear with no activities. A second source.

---

## 14. What this groundwork does not do

- **No flip, no migration, no code.** §5's prompt says stop before
  implementation, and §6 is why: three of the field matrix's rows are decisions
  about what is worth keeping for ever, and they are the athlete's to make.
- **It does not touch B6 or B6a.** §12.174 put B6a on the ladder after B5.
- **It does not decide the post-Strava gear model.** Decisions 1–4 keep enough
  to build one; what the app does with bikes afterwards is a product question,
  not a migration question.
