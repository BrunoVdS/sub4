# Load model — evidence review

*Origin: Cowork project memory `load-model-research.md`. Full review (~50 papers, written
2026-08-02) is `load-model-research.md` in `~/Documents/Triathlon/`; the implementation plan
beside it is `load-model-implementation-plan.md`. Exported 2026-08-07. Read before touching
load calculation.*

## The four decisions

1. **Two curves (adaptation + burden), burden never steers anything.** High confidence.
   WHOOP Day Strain / Workout Strain is the only commercial precedent; Garmin, Polar and
   Apple all exclude non-recorded activity entirely.
2. **Per-HR-sample intensity floor on the adaptation curve, at 60% HRmax.** Moderate
   confidence. Two independent routes converge: Olympiatoppen elite zone-1 floor = 60% HRmax
   (Tønnessen 2024), and Swain & Franklin's 45% HRR threshold for fitter subjects. For
   HRmax ≈ 180–183 (implied by Bruno's Z5 boundary at 161) that is **≈108–110 bpm**. Genuine
   uncertainty ±5–8 bpm. Replaces `loadMinKmForExtras` — no distance test anywhere.
3. **"Don't change the formula" should be reconsidered.** Generic Banister TRIMP was the
   *worst*-performing HR metric in the only head-to-head dose-response study (Sanders 2017:
   bTRIMP r=0.52 vs iTRIMP r=0.81). Path: floor now, individualised exponent once LT1/LT2
   anchor HRs exist.
4. **Drop all ratio/difference-derived freshness bands (TSB, ATL:CTL).** Very high
   confidence — the most decisively refuted thing in the field. Impellizzeri 2021 replaced
   chronic load with *random numbers* and got near-identical injury associations.
   Replacement: acute and chronic as separate covariates, never a ratio.

## Four corrections to the original framing

- The 4.2:1 walk:run exchange rate is **not** "exact by construction" — Banister's constants
  live in a 1991 book chapter with no documented subjects, protocol or fitting range. Stagno
  (2007) is the only variant that states its range: 65–100% HRmax. At 32% HRR the exponential
  extrapolates a lactate curve fitted where lactate carries no signal.
- "Walking is right for fatigue, wrong for fitness" is half wrong. Stanley 2013: duration is
  not the main determinant of parasympathetic recovery. Plews 2014: time below LT1 was
  *positively* associated with HRV in elite rowers. Walking may be wrong for both.
- **The +3–5 CTL/week ramp guidance has no peer-reviewed basis at all.** Source is Joe
  Friel's blog (2015), the number is 5–8, and he says it is trial and error. Coggan says PMC
  tuning is "trial-and-error/experience, not science." So burden cannot invalidate guidance
  that was never valid.
- The comparability argument against changing the formula is self-defeating: a floor already
  rewrites the whole CTL history, because CTL is a sum.

## Key structural findings

- **The published fix splits the INPUT, not the output** (Kontro 2026 three-dimensional
  impulse-response, by energy system). No published FFM uses two different load metrics, one
  per component — Bruno's architecture is unprecedented, neither validated nor refuted.
- **The fatigue component may be statistically superfluous.** Marchal 2025: fitness/fatigue
  parameters non-identifiable (τ₁/τ₂ correlated 0.99 in Hellard 2006); adding fatigue
  parameters did not improve prediction (p > 0.40). Do not over-engineer the burden side.
- **No peer-reviewed validation of CTL, ATL or TSB exists.** Searched PubMed/PMC/Springer/
  HumanKinetics/Frontiers/PLOS/SportRxiv — every hit was a commercial blog.
- Day state needs a three-way `ScoreEligibility` distinction (planLinked / discretionary /
  incidental) or widening intake makes the chart *less* available by making it more complete.

## The even-handed case for walking

Matomäki 2023 is the strongest pro-volume finding: prolonged sub-threshold work improved
**durability** as much as HIT (g=0.49 vs 0.62, p=0.42) while **VO₂max improved only in HIT**
(g=1.51). Durability and VO₂max are trained by different stimuli. But that LIT was continuous
sub-LT cycling, not ambulation. Walking clearly does *not* help tendon (magnitude-driven,
Bohm 2015), capillarisation in trained subjects (Liu 2022), or bone (power law; walking peak
tibial stress <half of running, Meardon 2021 — summing walking and running steps is
indefensible).

## What the evidence does NOT support

12 items in the full file. Headline gaps: no minimum effective intensity has ever been
measured in a trained athlete; no study has tested walking as a training stimulus in trained
athletes; no study relates daily step count to next-day HRV in athletes; no published
position on whether steps belong in load monitoring.

## Still needed from Bruno

Measured HRmax and HRrest (not estimated — estimating HRmax adds 8.4 bpm error); LT1 HR
(unlocks the individualised exponent); floored-vs-unfloored CTL computed over full history
before shipping.
