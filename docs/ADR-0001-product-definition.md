# ADR-0001 — What Sub4 is

| | |
|---|---|
| **Status** | Accepted, 3 August 2026 |
| **Decider** | Bruno |
| **Plan step** | 0.2 |
| **Related** | `ADR-0002` (source decision), `STRAVA-DATA-FLOW-INVENTORY.md` |

---

## The brief

> **Sub4 is a transparent marathon-training companion.** It connects recorded activity to a training plan, explains the evidence behind every figure it prints, and refuses to state a number it cannot support.

**Primary customer:** an endurance athlete following a structured plan who wants to understand *why* the app says what it says.

**Primary goal:** answer "what was asked of me, what did I actually do, and what does that mean for what comes next" — with the reasoning visible.

**Release promise:** every figure is traceable to its evidence. Where evidence is missing, the app says so rather than estimating quietly. This is the differentiator and it is a constraint on every future feature, not a slogan.

**Supported sources at v1:** Apple Health as canonical, plus file import (FIT, TCX, GPX) and manual entry. Not Strava — see `ADR-0002`.

---

## Scope decision

**Public release.** Sub4 is being built for distribution, not as a personal tool.

That choice was made deliberately and with the cost stated: it brings the whole remediation programme into scope, including privacy policy and manifest, consent flows, onboarding, generalisation away from one athlete's plan and data corrections, accessibility, localisation, and the device matrix. The alternative — a personal app with engineering rigour — would have cut roughly sixty per cent of the work and was declined.

### What this forces

Four things stop being optional the moment there is a second user:

1. **The athlete cannot be hard-coded.** Plan dates, the ingest cutoff, HR and power constants, the commute distance rule, the sex coefficient in the TRIMP kernel, and the individual data corrections in `DataCorrections.swift` are all currently Bruno-specific. They become profile configuration. (`PROD-03`, plan step 7.3)
2. **Setup must exist.** There is no first-run experience; the app opens straight into content and shows a stranger a plan they never chose, with sessions already marked missed. (`PROD-01`, step 7.1)
3. **The promise must be legible.** Privacy policy, consent, purpose strings, privacy manifest and App Store declarations must describe what the code actually does — which today they do not. (`PRIV-01` to `PRIV-04`, Phase 2)
4. **Nothing may fail silently.** A note that does not save, a decode failure that reads as empty history, an estimate presented as a measurement — each is survivable when the only user wrote the code and knows where the bodies are. None is survivable in a shipped product, and each contradicts the release promise directly. (`DATA-01`, step 3.4)

### Deliberately deferred to later milestones

Named here so they are decisions rather than omissions: cloud sync, a watchOS companion, direct in-app recording, multiple concurrent goals, and a plan-authoring tool. Each waits until the canonical activity model and conflict rules are stable (step 7.5).

---

## Ordering

The plan's dependency order stands, with one change forced by `ADR-0002`.

```
Phase 1  repository baseline, tests, CI
Phase 0  decisions and kill switches            ← this ADR; running now
Phase 2  privacy, consent, lifecycle
Phase 3  canonical database + legacy migration  ← release-blocking foundation
Phase 4A Apple Health canonical; Strava retired ← now critical path, not policy hygiene
Phase 4  concurrency and integration ownership
Phase 5  domain and numerical correctness
Phase 6  Sub4Core extraction
Phase 7  onboarding, activity library, plan generalisation
Phase 8  accessibility, localisation, devices, docs
Phase 9  verification and release gates
```

The change is Phase 4A's *status*. It was scheduled as compliance work ahead of an App Store submission. It is now the only path on which the app can lawfully hold a training history at all, so it is the reason the database exists rather than a consumer of it. The sequence is unchanged — Health data still needs a durable, source-neutral target before it can land — but the database is no longer a general improvement that Health happens to need. It is the first half of a two-part source replacement, and nothing downstream should be allowed to overtake it.

Database activation and Health-primary activation remain separately flagged and independently reversible, exactly as the plan requires.

---

## Consequences

- Every planned feature must map to the brief above. A feature that cannot show its evidence does not belong in this product, whatever else recommends it.
- Marketing copy, onboarding, permission strings and store metadata all describe the same app — one sentence, checked at release (step 9.3).
- The bundled 37-week plan becomes an optional template rather than the product (step 7.3.8).
- The current build is internal-only until Phase 2 completes. Nothing goes to TestFlight with the privacy disclosures in their present state.
