# Leaving Strava for Apple Health

*Origin: Cowork project memory `strava-exit.md`, decision 2026-07-31. Exported 2026-08-07.
Read before any data-source work. **The migration has not started** — Phase 4A sits behind
D7's exit gate.*

Decision (2026-07-31): **Apple Health / HealthKit becomes the source of truth for completed
sessions; Strava is being removed.** Supersedes the old core rule "Strava is the sole source
of truth". The other half of that rule — nothing is ever logged manually — still holds.

## Policy reading — get this right, the popular summary is wrong

Strava API Policy dated 2026-06-01.

- **§5.3 is scope-based, not provenance-based.** It bars using Strava data "in connection
  with the development, training, evaluation, or operation of any AI Application", and every
  enumerated act is *data going into a model* — training, fine-tuning, grounding, embedding
  generation, RAG, "ingestion into a context window or working memory". It governs what the
  data is fed into, **not what tools wrote the code**. Sub4 has no model and does no
  inference, so *building it with AI assistance is not the prohibited act*. "AI Application"
  is never defined anywhere in the policy.
- The §5.3 trip-wire that does apply is the **workflow**, not the app: pasting activity data
  into a chat window. §3.5 explicitly exempts Strava's own MCP for subscribers using their
  own data.
- **§5.4 is the clause that actually bites, and has nothing to do with AI**: no processing
  "for the purposes of analytics, analyses, customer insight generation, or product or
  service improvements", and no combining Strava data with other customer data. Weekly
  volume/adherence/zones/pace trend is analytics, and the app merges it with Apple Health
  steps. Literal reading covers the app; contextual reading (drafted at commercial
  developers with customers) does not. Both defensible — Strava has published no
  clarification, and the one developer who asked on their community hub got no staff reply.
- Proportion: this is a contract, not law. Realistic downside of a wrong reading is a revoked
  API application, not liability. Not legal advice — Bruno's call.

**The migration stands without §5.3.** Durable non-ToS reasons: raw route + raw HR the API
never exposed, deletions propagate, serverless background refresh, data never leaves the
phone, one less dependency on a company that has changed its API terms twice heading into
an IPO.

## Inventory findings

Source documents: `strava-data-inventory.md` and `.html` (currently in
`~/Documents/Triathlon/`).

- 4 endpoints only: `/oauth/token`, `/athlete/activities`, `/athlete/zones`, `/athlete`.
- 21 fields consumed (12 activity, 5 zone, 4 gear); **only 8 are rendered anywhere**.
- **Dead fields — decoded, stored, never displayed**: `total_elevation_gain`,
  `max_heartrate`, `trainer`, `elapsed_time`. Also `HealthStore.walkRunKmByDay` and
  `totalSteps(from:to:)` are unused.
- `splits_metric` was never built, so nothing depends on Strava-side split maths.
- All derivation (dayKey, km, pace, discipline, isPlanEligible, dedup, Matcher, adherence,
  charts) is already ours and is source-agnostic.

## Migration shape

Split `Activity` from the Strava DTO: `StravaActivityDTO` and a new `HKWorkoutAdapter` both
produce it. `Matcher` / `ProgressTabView` / `CommuteView` untouched. That is structurally
the whole job.

Costs:

1. **Shoe mileage has no HealthKit equivalent** — build it, and seed the existing lifetime
   totals by hand or the 600 km warning fires years late.
2. **HR zones have no HealthKit equivalent** — move to local settings.
3. **Moving time becomes our algorithm.** `HKWorkout.duration` equals elapsed when
   auto-pause is off. Integrate route speeds instead; validate against a known Strava
   activity.
4. **Duplicates get worse** — Health does not dedup at write. Extend the existing
   time+distance rule with a `sourceRevision` source-priority (watch > phone app).
5. Distances are device-reported, so historical volume totals will step slightly at cutover.
6. **The PWA path dies** — HealthKit is native-only. Build-spec decision D1 inverts; the €99
   developer programme stops being optional.

## Must verify on device before coding

1. Which device records each discipline, and whether its companion app writes to Health.
2. Whether `HKWorkoutRoute` exists for rides and runs — no route means no splits, no
   self-computed moving time.
3. How far back Health's workout history goes (does the 2026-06-15 cutoff survive).
4. Whether Hevy writes strength to Apple Health — may be a better path than the
   never-proven Hevy→Strava one.
5. How many duplicate workouts already exist for one known day.
6. Whether `duration` differs from elapsed (is auto-pause on).

**First move: a throwaway read-only spike screen** printing uuid / type / source / start /
duration / elapsed / distance / HR / route-count for the last 30 days. Answers all six in
one pass.
