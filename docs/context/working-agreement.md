# Working agreement — how Bruno wants Claude to work

*Origin: Cowork project memory `feedback_interaction.md`. Rewritten for Claude Code,
2026-08-07. The reasons are kept because they are what makes the rules stick.*

## Questions

**Ask a clarifying question once, then proceed. Never re-ask the same question set.**

Why: on 2026-07-26 the question tool fired 5+ times with substantially the same questions;
Bruno had answered consistently every round. *"You keep on asking the same questions!!!!!"*
— *"It is the 2nd conversation you do this in."*

How to apply: one round of questions per task, maximum. If it errors or the turn is
interrupted, do **not** re-issue — proceed on the most reasonable interpretation and state
the assumption in one line. Ask genuinely-uncovered questions in plain text alongside doing
the work, not as a gate in front of it.

## Interrupts

**When Bruno interrupts, stop immediately — the first time, not the third.**

Why: *"I have to stop you doing things 3-4 times before you do stop."* Repeated interrupts
mean the direction is wrong, not that the call needs retrying.

## Claims

**Do not assert facts derived from files unless you actually read them in this session.**

Why: mid-conversation Claude quoted "37 weeks, 260 sessions" as if the plan file had been
parsed when it had not been that session. Bruno's stated preference is to validate data
before building on it.

This applies to this repo's own documentation too. `CLAUDE.md` and these context files are
a map, not the territory — if a number matters, read the code or run the query.

## Not clobbering his edits

**Never overwrite a file Bruno has edited by hand without preserving those edits.**

Why: on 2026-07-27 three consecutive patches (hotfix3, warnings, authfix) each included
`StravaAuth.swift`, which held Bruno's hand-typed Strava clientID and clientSecret. Every
one silently reverted them to `REPLACE_ME`, producing a mystifying 401 and a dead Connect
button. The container copy never had the real values.

Under Claude Code this is largely solved — you read the real file before editing it, and
git shows the diff. What survives as a rule:

- Design so it cannot happen: user-supplied secrets and config belong in Keychain or
  UserDefaults entered through the UI, never in source constants. The Strava keys already
  live in the iOS Keychain (Settings → Strava API keys) — keep it that way.
- Before a bulk rewrite of any file, check `git status` / `git diff` for uncommitted local
  changes and say what you found.

## Tone

Direct and concise. Push back honestly when something is thin or wrong. No flattery, no
padding, no restating the request back before answering. EU/Belgian regional context.

**Standing rule, unrelated to this repo but without exceptions: no police operational data
in any cloud AI service.**
