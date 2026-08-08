# CI budget, and the local-verification rule that follows

*Origin: Cowork project memory `ci-budget.md`. Exported 2026-08-07. Read before relying on
CI or suggesting a push to check something.*

**The GitHub account is free: 2,000 Actions minutes a month, and that is the whole budget.**

- The repo is private (`github.com/BrunoVdS/sub4`), so every CI minute is billed against
  that allowance.
- The allowance is spent. Exhaustion looks like an **instant (2–4 s) failure of every job**,
  with the annotation "The job was not started because recent account payments have failed
  or your spending limit needs to be increased." That is billing, not code — do not debug it
  as a build failure.
- **It resets 2026-09-01.** Bruno expects a large build at that point, since everything
  queued up since exhaustion runs then. CI has been unverified since the trigger change.

## The rule that follows

**Local verification is the source of truth until the new month.** Never say "once CI is
green" and never treat a push as a check.

- `./scripts/test.sh` (or ⌘U) for the test suite — the full suite runs in well under a
  second.
- `xcodebuild -configuration Release` locally when a Release-only problem is plausible —
  this is what stood in for CI on 2026-08-04 and passed. `./scripts/preflight.sh` does both.
- **Device verification on the phone for anything a simulator cannot answer.** Six of the
  eleven Phase 2 defects were hardware-only; the benchmark's read-key bug and its unstable
  verdict rule were both found by reading numbers on the phone, not by 248 green tests.

## Habit

CI going red is not automatically a signal. Check the annotation first: an instant failure
across every job is the allowance, and nothing local is wrong.
