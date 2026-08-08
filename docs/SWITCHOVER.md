# Switching Sub4 from Cowork to Claude Code

Written 2026-08-07. Read once, then this is history.

---

## Part 1 — Installing this bundle (do this first)

The bundle unpacks at the **repo root**, `~/Documents/Developer/sub4`. It adds files and
overwrites nothing that exists there today.

```sh
cd ~/Documents/Developer/sub4
git status                                  # should be clean; commit or stash first if not
unzip -o ~/Downloads/sub4-bootstrap.zip -d /tmp/sub4-bootstrap
rsync -av /tmp/sub4-bootstrap/sub4-bootstrap/ ./
chmod +x scripts/*.sh
git add -A && git status                    # review what landed before committing
```

What lands:

```
CLAUDE.md                     ← read first, every session
docs/SWITCHOVER.md            ← this file
docs/context/                 ← 12 files + README, the old Cowork project memory
.claude/settings.json         ← permissions so routine commands do not prompt
scripts/test.sh               ← xcodebuild test on the simulator
scripts/preflight.sh          ← test + Release build, before anything destructive
```

`docs/ADR-0003-database-contract.md` and `docs/HANDOFF-2026-08-05-late.md` are already in the
repo and are untouched.

## Part 2 — Two things to verify before trusting the scripts

`scripts/test.sh` guesses the scheme name (`Sub4`) and picks the newest available iPhone
simulator. Confirm both once:

```sh
xcodebuild -list -project Sub4.xcodeproj           # confirm the scheme name
xcrun simctl list devices available | grep iPhone  # confirm a simulator exists
./scripts/test.sh                                   # expect 931 tests in 88 suites
```

If the scheme is not called `Sub4`, edit `SCHEME` at the top of `scripts/test.sh`.
**Do not accept a passing run that reports far fewer than 931 tests** — that means the test
target did not build, which is exactly the failure these scripts exist to prevent.

## Part 3 — Starting the session

Start Claude Code **in the repo root**, not in a parent directory:

```sh
cd ~/Documents/Developer/sub4 && claude
```

It reads `CLAUDE.md` automatically. Everything else it pulls in on demand.

## Part 4 — What changed, and what to stop doing

**The patch workflow is retired.** Under Cowork, nothing could write into this repo, so
changes arrived as zips of whole files plus an anchored `apply-NNN.py`, preflighted against a
byte-exact copy through `SUB4_ROOT`. All of that scaffolding is gone:

| Retired | Why |
|---|---|
| zips + `apply-NNN.py` | Code edits files in place; git is the undo |
| `SUB4_ROOT` preflight against a copy | there is no copy any more |
| anchor-uniqueness rules (the 23-vs-24-space trap) | no anchored edits |
| "put the apply commands in ONE message only" | no apply step to double-run |
| "always `rm -rf` the staged directory before re-staging" | no staging |
| `git --no-optional-locks status` | `.git/index.lock` was a bridge artefact |

**Keep the patch numbering.** The ADR and both handoffs cite patch numbers as history —
continue the sequence in commit subjects (`279 — …`) rather than restarting.

**What did not change:** ⌘R still only compiles the app target, the phone is still the only
place several classes of defect appear, the app still logs nothing, and CI is still not a
check until 2026-09-01. `scripts/test.sh` is the one new guard, and it closes the exact hole
that let 275, 276 and 277 ship onto the phone with an uncompiled test target.

## Part 5 — Two loose ends worth closing this week

**1. The plan tooling lives outside the repo.** `extract_plan.py`, the plan HTML, `plan.json`,
the iPad mockup and the Strava inventory are all in `~/Documents/Triathlon/`. The extractor
is build tooling for this app — moving it in makes the plan-revision workflow a single
command from the repo root:

```sh
mkdir -p tools/plan
cp ~/Documents/Triathlon/sub4-data/extract_plan.py tools/plan/
cp "~/Documents/Triathlon/marathon_plan sub_4hr.html" tools/plan/
```

The plan HTML is also a human-facing document Bruno opens in a browser, so either keep the
`Triathlon` copy as the one he edits and treat the repo copy as an input snapshot, or move it
in entirely and open it from the repo. Pick one — two editable copies is how the Rev 4.1
title-drift class of bug happens.

**2. Device install from the CLI is untested.** Everything else moves to the terminal, but
building onto the phone has always been ⌘R. This *may* work:

```sh
xcodebuild -project Sub4.xcodeproj -scheme Sub4 \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates
```

On a free Personal Team it is unverified. **Test it once when nothing is at stake.** If it
works, the 7-day provisioning refresh becomes one command instead of an Xcode session. If it
does not, nothing is lost — keep using ⌘R and note the result here.

## Part 6 — What Cowork was still better at

Be honest about this rather than discovering it mid-task:

- **Reading the phone.** Row counts, screenshots, "what does the Settings tab show" — that
  was always Bruno's eyes and still is.
- **The Strava and TrainingPeaks connectors.** Cowork could query them directly. From Code,
  data comes from the app or from a script Bruno runs.
- **The plan HTML as a rendered artefact.** Cowork previewed it inline. From Code, open it in
  a browser.

None of these block the database work, which is where the project is.
