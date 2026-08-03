# ADR-0002 — Retire Strava; make Apple Health canonical

| | |
|---|---|
| **Status** | Accepted, 3 August 2026 |
| **Decider** | Bruno (product owner and sole athlete) |
| **Supersedes** | Nothing. This is the first record of the source decision. |
| **Evidence** | `STRAVA-DATA-FLOW-INVENTORY.md` |
| **Plan steps** | 0.1.2, 0.1.3, 0.1.4 |

**This is an engineering risk assessment, not legal advice.** It reads the published policy against the code as written. Where the reading is genuinely uncertain that is marked, and step 0.1.5 — written guidance from Strava Developer Support — applies to those items.

---

## Context

Sub4 has used the Strava API as its sole activity source since it was built. The remediation plan flagged this as `STR-02`: long-term Strava storage, combined analytics and Claude use "appear incompatible" with the API Policy effective 1 June 2026.

That policy was retrieved and read in full on 3 August 2026. It is now in force — it has been for nine weeks. The wording is not ambiguous in the way "appear incompatible" suggests.

### The four clauses that decide this

> **§6.2 Cache and Retention** — "You may not retain Strava Data in your cache for longer than seven (7) days."

> **§5.5 No Persistent Indexes** — "You may not store Strava Data, or any data derived from Strava Data, in any Persistent Index." The prohibited forms named include archives, search indexes, knowledge graphs and retrieval-augmented data stores.

> **§5.4 No Aggregation or Combined Processing** — "You may not combine Strava Data with other customer data for these or any other purposes." And: "You may not process or disclose Strava Data … for the purposes of analytics, analyses, customer insight generation, or product or service improvements."

> **§5.3 AI/ML Prohibition** — "You may not use the Strava API Materials or Strava Data, directly or indirectly, in connection with the development, training, evaluation, or operation of any AI Application."

Also relevant: §5.10 forbids making Strava Data available to third parties "including … AI Application providers, or model developers"; §7.4 requires permanent deletion of "all Strava Data and all Personal Data derived from Strava Data" within thirty days of termination, certified in writing on request; §3.3 places apps of up to ten users in a Standard Tier that now requires a Strava subscription, but grants that tier no exemption from §5 or §6.

---

## The finding

**Sub4 cannot be made compliant. Its central feature is the violation.**

A seven-day cache limit and a thirty-four-week training-load history are not reconcilable by any amount of engineering. CTL is a 42-day exponential average; the fitness curve on the Progress tab reaches back to 1 July 2025. The app currently holds 677 activities spanning thirteen months, and it holds them permanently — nothing in `activities.json`, `details/`, `streams/` or `athlete.json` expires by age, and `athlete.json` and `strava.rejectedByRule` have no deletion path at all.

That is not a bug to be fixed. Removing it removes the app.

Four separate structural conflicts, each independently sufficient:

1. **Retention.** Thirteen months of activity summaries, route polylines, GPS streams and device names, against a seven-day limit (§6.2). The per-activity JSON stores are also an archive of data derived from Strava Data (§5.5).
2. **Analytics.** TRIMP, CTL/ATL/TSB, monotony, time-in-zone, power load, volume, pace trends and adherence are analyses of Strava Data (§5.4). They are the product.
3. **Combination.** Strava heart rate is combined with Apple Health resting heart rate to define the TRIMP span; Health heart rate substitutes for missing Strava heart rate; Health duration replaces Strava swim duration (§5.4, with a caveat below).
4. **AI.** The monthly review sends CTL ramp figures, deep-TSB day counts, monotony week counts, matched-session shares, recorded kilometres and measured paces to Anthropic (§5.3, §5.10). This is the sharpest item: it is a live outbound transfer, it happens today whenever the review is run, and the evidence text is then archived in `proposals.json`.

### Where the reading is genuinely uncertain

- **§5.4 "other customer data".** This may mean data belonging to *other customers* — other athletes — rather than other data about the same athlete. Sub4 combines one athlete's Strava data with the same athlete's Health data. Under the narrower reading, points 3 above is not a violation. Under the broader reading it is. This is an escalation item for 0.1.5.
- **Derived versus raw.** §5.5 names derived data explicitly; §5.3 and §5.10 speak of "Strava Data" without a derived carve-out. The AI payload contains no raw Strava fields — no ids, names, coordinates or streams — only computed aggregates. Whether "indirectly … in connection with the operation of any AI Application" reaches a computed aggregate is the question. **This ADR assumes it does**, because the alternative reading requires §5.3's "indirectly" to mean nothing.
- **The user's own bulk export.** Data an athlete downloads from Strava as the account holder, through the account export rather than the API, is arguably not "data you access or collect from the Strava API Materials" and so arguably not Strava Data under the Agreement's definition. If that holds, a one-time personal export is a lawful bridge for preserving history that the API cannot lawfully supply. **It is not relied on in this decision** and must be confirmed before it is used.

---

## Decision

**Apple Health becomes the canonical source. Strava is retired.**

This was already the plan's Phase 4A. The finding above changes its *status*, not its content: it is not a policy-hygiene task to be done before an App Store submission, it is the only path on which the app can continue to exist. The ordering consequence is recorded in `ADR-0001`.

Three things follow immediately, ahead of any migration work.

### 1. The AI review is disabled now

Not "before external testing" — now. It is the one violation that transmits data off the device, and every run adds an archived copy of the evidence to `proposals.json`. It stays off until either the payload is rebuilt from sources with no Strava lineage, or written permission covering this exact use is obtained and archived.

### 2. Backfill stops; existing data is frozen, not extended

New long-term retention is not added while the position is what it is. The sync, detail and stream fetches, and the two-hourly background task, come under a kill switch (step 0.3). Existing stored data is preserved read-only for the duration of the Health reconciliation — this is a deliberate choice, made with the retention conflict fully in view, because deleting it before Health is verified to hold the same history would destroy the athlete's training record with no way back. The window is bounded by the M4 reconciliation gate, not left open.

### 3. Every stored record gains lineage

Source, retention class and an `aiShareable` decision, so that "is this Strava-derived?" is answerable by code rather than by memory. This is the mechanism that makes the classification below enforceable, and it is a prerequisite for the database work in Phase 3.

---

## Classification of every stored value

Per step 0.1.4. **Purge** means delete at M8. **Reconciliation** means keep read-only until Health is verified to carry the same history, then purge. **Retain** means it is not Strava Data and survives.

| Store | Contents | Class | Note |
|---|---|---|---|
| `activities.json` | 18 summary fields incl. GPS start coordinate | **Reconciliation → purge** | The join key for everything; needed to match Health workouts to existing notes and matches |
| `details/*.json` | Polyline, description, device name, splits, laps, best efforts | **Reconciliation → purge** | Splits and best efforts are re-derivable from Health recordings; the polyline is replaced by `HKWorkoutRoute` |
| `streams/*.json` | HR, speed, altitude, grade, power, GPS track | **Reconciliation → purge** | Replaced by native-timestamp Health samples, which are higher resolution than the 300-bin cache |
| `athlete.json` | Strava HR zones, FTP, shoes | **Purge** | The *values* are re-established as Bruno's own configuration — a number he types is not Strava Data |
| `weather.json` | Keyed by Strava activity id, fetched from Strava coordinates | **Reconciliation → re-key** | The observations are Open-Meteo/Apple data; the key and the coordinate provenance are Strava. Re-key to canonical activity ids, then the rows survive |
| `constants.json` → `hrMaxObservedName` | A Strava activity name | **Purge** | The numeric HR max is re-established from Health |
| `constants.json` → `restByMonth` | HealthKit resting HR | **Retain** | Never Strava-sourced |
| `proposals.json` | Full evidence text incl. CTL/monotony figures | **Purge the evidence; retain the verdict** | The athlete's own review history is his; the embedded Strava-derived figures are not |
| `notes.json` | RPE, feel, free text | **Retain** | Authored by the athlete, keyed to plan sessions, never Strava-sourced |
| `plan.json` | The bundled plan | **Retain** | Not Strava-sourced |
| `match.overrides` | `sessionUid → Strava activityId` | **Reconciliation → remap** | The *decision* is the athlete's and survives; the Strava id must be remapped to a canonical id |
| `strava.rejectedByRule` | Date, name, distance, duration, speeds per rejected activity | **Purge** | Permanent by design today; that design does not survive this decision |
| `strava.cursor`, `.lastSync`, `.cutoffUsed`, `.*Backfill` | Sync state | **Purge** | Meaningless without the source |
| `detail.failed`, `detail.noStreams` | Strava activity ids | **Purge** | |
| `bg.lastResult` | Embeds new-activity counts and Strava error text | **Purge** | |
| Keychain `strava.tokens` | Access and refresh tokens | **Purge after remote revocation** | Revoke first, then delete with a checked status |
| Keychain `strava.credentials` | Client id and secret | **Purge** | Has no deletion path today; one must be written |
| Keychain `claude.apiKey` | Anthropic key | **Retain** | Not Strava-related |

---

## Consequences

**Accepted.**

- The Health migration moves from "Phase 4A, after the database" to the critical path. Its dependency on the database is unchanged — Health data still needs a durable, source-neutral target — so the *order* holds while the *priority* rises.
- The monthly review is unavailable until it is rebuilt on Health-derived figures. The local, non-AI review path in step 2.3.11 becomes the near-term answer rather than a fallback.
- If Apple Health turns out not to hold the history back to July 2025 — the watch may not have been worn, or workouts may have been written by Strava rather than to it — then some of the record cannot be carried across by the API-free route. **This must be measured before anything is purged**, and it is now the first task of M0. The bulk-export bridge above is the contingency, subject to confirming it.
- The 7-day and analytics clauses mean the interim state is not compliant either. It is a bounded, documented, non-transmitting hold with a defined exit, chosen over an immediate purge that would destroy the athlete's training history. That is a judgement, it is recorded here as one, and the bound is the M4 gate.

**Rejected alternatives.**

| Option | Why not |
|---|---|
| Comply on Strava — 7-day cache, no analytics | Deletes the product. There is no fitness curve, no adherence history, no trend. |
| Keep Strava, drop only the AI review | Addresses one of four conflicts. Retention, persistent index and analytics remain. |
| Apply for Extended Access tier | The tier grants higher limits and partner APIs. It does not exempt anyone from §5 or §6. |
| Do nothing until Strava objects | An unbounded liability on someone else's timetable, and the review keeps transmitting meanwhile. |

---

## Follow-ups

| | Action | Step |
|---|---|---|
| 1 | Kill switches: Strava connect, sync, detail/stream fetch, background refresh, AI review, coordinate weather — fail closed | 0.3 |
| 2 | Ask Strava Developer Support, in writing, about §5.4 "other customer data", derived-aggregate scope under §5.3, and the status of a personal bulk export. Archive the reply. | 0.1.5 |
| 3 | Measure Apple Health coverage back to 1 July 2025 **before** any purge | 4A M0 |
| 4 | Lineage, retention class and `aiShareable` on every record | 3.2 |
| 5 | Remote OAuth revocation, checked Keychain deletion, deletion receipts | 4A M8 |
| 6 | Automated invariant: no Strava-lineage value can enter an AI payload, an export, or a log | 2.3, 9.1 |
| 7 | Confirm the Standard Tier subscription requirement that took effect 30 June 2026 | 0.1 |

---

## Sources

- [Strava API Policy (2026)](https://www.strava.com/legal/api_policy) — effective 1 June 2026
- [Strava API Agreement (2026)](https://www.strava.com/legal/api)
- [An Update To Our Developer Program](https://communityhub.strava.com/insider-journal-9/an-update-to-our-developer-program-13428) — Strava Community Hub
