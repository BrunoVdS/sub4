# The monthly review — what it may reason from, and why it is blocked

*Origin: Cowork project memory `review-data-pool.md`, 2026-08-05. Exported 2026-08-07.
Read before any work on the review, the payload, or Phase 4A.*

**Bruno's standing item, 2026-08-05: build the data pool used to analyse progress and make
changes to the plan.** Recorded because the review cannot currently do its job, and the
reason is structural rather than a defect.

## What the review is built from today

`Review.payload()` produces nine sections, each declaring a `lineage`.
`PayloadInclusion.inclusion(for:)` blocks any section whose lineage contains `.strava` —
ADR-0002 §5.3 and §5.10. It is a LINEAGE test rather than a field test because adherence
contains no Strava field and is computed entirely from them.

| Section | Built from | Sendable |
|---|---|---|
| Which window, which build | plan + device | yes |
| Coverage | Strava + plan | **blocked** |
| Flags | Strava + notes + plan | **blocked** |
| Adherence | Strava + plan | **blocked** |
| Running volume by week | Strava + plan | **blocked** |
| Effort by session type (RPE, feel) | notes + plan | yes |
| Pace against the plan | Strava + plan | **blocked** |
| Session notes | notes | yes |
| Thresholds | plan | yes |

So the usable pool is three things: **the bundled plan, the session notes, and the RPE/feel
recorded against them.** Everything measured comes from Strava.

## The consequence, which is easy to miss

`ReviewPayload.isUsable` is `blocked.isEmpty`. `ReviewRequest.prompt` returns nil when it is
false, and `ProposalStore.run` throws. **So the review cannot be sent at all today** — on
2026-08-24 the button will produce the refusal, not a proposal.

That refusal is deliberate and the code says why: a review whose adherence, volume and pace
are all withheld is not a review, and judging a block from the effort table alone would
produce a confident answer built on a quarter of the evidence.

**Patch 269's rehearsal proves the WRITE path only** — writer → `proposals.json` → importer
→ the five review tables — because it bypasses the prompt. It does not prove the review will
run, because it cannot.

## What unblocks it

**Phase 4A**, where volume, adherence, pace and coverage are rebuilt on Apple Health figures
instead of Strava's. Five sections change lineage and the payload becomes usable. 4A sits
behind D7's exit gate, so the database has to be authoritative first.

## The pool Bruno wants built

Signals that are Apple Health or authored are not Strava-derived, so all of them are
sendable:

- **Sleep** — the one measurement Strava never gave. The natural counterweight to RPE, which
  is currently the only measured signal the model may see.
- **Fuel and liquid intake** — authored, so unblocked from day one. Already being recorded
  in free text: a note on 2026-08-01 reads *"Drank 750ml of water during the run"*, where
  nothing can count it.
- Anything else authored or from Health.

**The open question worth settling before 4A rather than during it:** is the review's job to
judge the plan against what was DONE, or against how it FELT and how recovery went? Today it
can only do the second. After 4A it could do both, and which one leads changes what the
evidence pack should carry.

## Rehearsal, patches 269–270 — done and verified

The rehearsal wrote all five review tables on the device (1, 1, 1, 2, 2) and §12.8.2's
checklist is satisfied. Patch 270 added the delete — `ProposalStore.remove(_:)` had been
written in 225 and had no caller for forty-five patches. The rehearsal record was deleted on
2026-08-05, so `ReviewDue` is clear for 2026-08-24.

**Open UI item, deferred by Bruno:** the review screens feel sluggish. To be revisited when
there is a real review to look at rather than a synthetic one.
