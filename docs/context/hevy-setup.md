# Hevy — account structure, routine drift, API quirks

*Origin: Cowork project memory `hevy-setup.md`, state 2026-08-02. Exported 2026-08-07.
Read before anything touching Hevy routines or its API.*

Bruno tracks strength in **Hevy Pro**, synced to Strava (Settings → Integrations).

**The API key is generated in the WEB app only** — `hevy.com/settings?developer` — not in the
iOS app; the Developer section only shows while Pro is active. **Do not store the key.** Ask
for a fresh one when needed and tell him to revoke it after.

## Account state (2026-08-02) — folder id 3300503, "Sub-4 Strength"

8 routines, one per distinct session in the plan's section 08b, verified 56/56 consistent
with the plan file:

- **A1 · Squat day** (6 ex, Wk 12 only) · **A1 · Squat + Jumps** (8 ex) ·
  **A1 · Light / Deload** (6 ex, 9 weeks — the most-used barbell session)
- **A2 · Hinge day** (7 ex) · **A2 · Hinge + Jumps** (9 ex) ·
  **A2 · Light / Deload** (7 ex, Wk 3+5)
- **B · Full circuit** (10 ex) and **B · Core only** (7 ex) — bodyweight, one superset circuit

**Light routines differ in REPS, not just set count** (squat 3×8 vs 3×5, deadlift 2×8 vs
3×5) — "drop a set" is NOT a substitute. That was an early wrong assumption.

Every exercise note carries the plan's cue + YouTube link; the first exercise's note carries
the session brief + rules.

**5 custom exercise templates** (absent from Hevy's library): Pogo Hops, Copenhagen Plank,
Split Squat (Bodyweight), Single Leg RDL (Bodyweight), KB Press-Out (Anti-Rotation) —
id `e2120faf-9935-44ae-9309-37bfa06564cc`.

## Routine drift — the recurring gotcha

Hevy writes rep/weight changes from a logged workout **straight back into the routine,
silently**; the "Update Routine vs Keep Original" prompt only fires for *structural* changes
(add/remove/reorder). Caught on 2026-07-29: a logged B · Full circuit rewrote SL RDL 8→10
reps and side plank 30→34 s.

Fix is the "Update Routine Values" toggle on the save-workout screen — **Bruno's to set, not
API-reachable.**

Why it matters: re-audit routines against the plan periodically, and never assume Hevy still
matches what was built. Duration sets log as 0 s unless the in-app timer is actually started.

## Hevy API quirks (v1, `api.hevyapp.com`, header `api-key`)

- `POST /v1/exercise_templates` wants `exercise_type`, `muscle_group`,
  `equipment_category` — NOT the response-schema names (`type`, `primary_muscle_group`,
  `equipment`). Returns the new id as **plain text, not JSON**.
- Routine-level `notes` is accepted but **silently dropped**. Put session briefs in the FIRST
  exercise's note.
- `superset_id: 0` is treated as null; superset ids must start at 1.
- `pageSize` max is 10 on `/v1/routines` and `/v1/routine_folders`, 100 on
  `/v1/exercise_templates`.
- **NO delete endpoints** for routines, folders or exercise templates — anything created must
  be deleted by hand in the app. Create carefully; make re-runs idempotent (match by title,
  PUT not POST).
- Useful reads: `/v1/workouts` and `/v1/workouts/count` for logged sessions — good for
  comparing actual vs prescribed once training is under way.
