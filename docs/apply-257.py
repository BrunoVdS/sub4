#!/usr/bin/env python3
"""
Patch 257 — the fourth head.

Two Swift files and the ADR. `Sub4Import.swift` (582 lines) and
`DatabaseHealthView.swift` (898 lines) are edited in place rather than shipped
whole, because the bridge that would have copied them out truncated both
silently — 524 and 680 lines came back. A whole-file replacement built from a
truncated read would have deleted working code with no error anywhere.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
"""

import sys, pathlib

DOCS = pathlib.Path(__file__).resolve().parent
ROOT = DOCS.parent

EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


# ---------------------------------------------------------------- Sub4Import

edit(
    "Sub4/Sub4Import.swift",
    """        // Patch 226. `weatherUnmatched` is NOT a refusal: the schema is
        // correctly declining to hold a reading about an activity that is not
        // here. Expected to be 1 — the August 2025 artifact.
        var weatherSeen = 0
        var weatherImported = 0
        var weatherUpdated = 0
        var weatherUnmatched = 0""",
    """        // Patch 226. `weatherUnmatched` is NOT a refusal: the schema is
        // correctly declining to hold a reading about an activity that is not
        // here.
        //
        // EXPECTED TO BE 0 SINCE PATCH 257. It was 1 for thirty-one patches —
        // the August 2025 artifact, whose activity the schema refused, so its
        // weather had nothing to attach to. 256 excluded that recording and
        // gave its trace and its detail counters of their own; this one was
        // missed and stayed at 1 while the other three went to 0. A screen
        // where one number is known-noise is a screen nobody reads.
        var weatherSeen = 0
        var weatherImported = 0
        var weatherUpdated = 0
        var weatherUnmatched = 0
        /// A reading belonging to a recording `DataCorrections` excludes —
        /// patch 257. Split out of `weatherUnmatched`, which had carried it
        /// since 226 and reported it as a missing activity the whole time.
        /// Never counted as seen: the import declines it before it tries.
        var weatherIgnored = 0""",
    "Report gains weatherIgnored",
)

edit(
    "Sub4/Sub4Import.swift",
    '''                     "Weather seen: \\(weatherSeen) — imported \\(weatherImported), refreshed \\(weatherUpdated), no activity \\(weatherUnmatched)",''',
    '''                     "Weather seen: \\(weatherSeen) — imported \\(weatherImported), refreshed \\(weatherUpdated), no activity \\(weatherUnmatched), excluded \\(weatherIgnored)",''',
    "the diagnostic line carries it too",
)


# --------------------------------------------------------- DatabaseHealthView

edit(
    "Sub4/DatabaseHealthView.swift",
    """                if r.weatherUnmatched > 0 {
                    // Not red: the schema is correctly declining to hold a
                    // reading about an activity that is not here.
                    LabeledContent("Weather with no activity",
                                   value: "\\(r.weatherUnmatched)")
                        .font(.caption).foregroundStyle(Color.dim)
                }""",
    """                if r.weatherUnmatched > 0 {
                    // Not red: the schema is correctly declining to hold a
                    // reading about an activity that is not here.
                    //
                    // DEMOTED TO A SUB-ROW IN 257, to match the trace and the
                    // detail below. It is a fact ABOUT the Weather row, and
                    // rendering it at the same weight as its own parent made a
                    // known-benign count the loudest thing in the section.
                    LabeledContent("  weather with no activity",
                                   value: "\\(r.weatherUnmatched)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.weatherIgnored > 0 {
                    // Patch 257. Named for the decision rather than the
                    // symptom: this reading belongs to a recording the app
                    // excludes on purpose, which is not the same thing as an
                    // activity that went missing.
                    LabeledContent("  weather for an excluded recording",
                                   value: "\\(r.weatherIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }""",
    "the health screen row, in the trace/detail style",
)


# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    """The expected count is **one** — the August 2025 artifact, which has weather and
no activity. Anything larger means activities are missing that should not be,
and the number is on the health screen for that reason.""",
    """The expected count is **zero since patch 257**. It was one for thirty-one
patches — the August 2025 artifact, which has weather and no activity — and
§12.12.7 records why that stopped being acceptable. Anything above zero now
means activities are missing that should not be, which is what the number was
always supposed to mean and could not while it had a permanent occupant.""",
    "ADR §12.9 — the expected count",
)

edit(
    "docs/ADR-0003-database-contract.md",
    """easy to leave unmade.** The 4 August entry decided the data question and left
the presentation to whatever happened to fall out. What fell out was three
false alarms.""",
    """easy to leave unmade.** The 4 August entry decided the data question and left
the presentation to whatever happened to fall out. What fell out was three
false alarms.

### 12.12.7 There were four — patch 257

The section above counts three consequences and 256 fixed three. The count was
wrong. The same recording also has a **weather reading**, and weather resolves
through `activity_alias` exactly as the trace and the detail do, so it went on
landing in `weatherUnmatched` — one grey line still reporting "with no
activity" about a recording the app had already ruled on.

**That state is worse than the one 256 started from.** Four lines all saying
the same thing is at least consistent; three at zero and one at one teaches the
reader that some of these numbers are furniture, and a screen whose numbers are
furniture is not a health screen. The whole argument of §12.12.6 — "the next
entry there is news" — needs every one of them at zero, not most.

So `weatherIgnored` joins `recordingsIgnored` and `detailsIgnored`, counted
before the reading is counted as seen, and shown as "weather for an excluded
recording". `weatherUnmatched` now means what its name says.

**The miss is worth more than the fix.** It was not a reasoning error — the
reasoning in §12.12.6 was right and applied unchanged here. It was a *sweep*
error: the two consequences that had just been on screen got fixed, and the
third sharing the identical mechanism was never looked for. The mechanism is
"resolves through the alias", and it is greppable. The general form:

> When a decision has consequences, enumerate them from the MECHANISM, not from
> the symptoms you happen to have seen. Symptoms are whichever ones were
> visible on the day; the mechanism is all of them.

The same rule would also have caught this at 226, where the header of
`Sub4Import+Weather.swift` wrote "the expected count is one" and froze a known
defect into a documented constant. **A number a comment excuses is a number
nobody will ever question again** — the excuse is what makes it permanent.""",
    "ADR §12.12.7",
)


# --------------------------------------------------------------------- apply

def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


# Two of these files take two edits each, so the text is threaded through in
# memory and written once. Reading each file fresh per edit would mean the
# second write overwrote the first with a copy that only carried its own change.
#
# And everything is checked before anything is written, so a failed anchor
# halfway down cannot leave the repo half-patched.
buffers = {}
applied = []

for path, old, new, why in EDITS:
    if not path.exists():
        fail(f"missing: {path}")
    text = buffers.get(path, path.read_text())
    if new in text:
        fail(f"already applied? {path.name} — {why}")
    n = text.count(old)
    if n != 1:
        fail(f"{path.name} — {why}: expected one match, found {n}")
    buffers[path] = text.replace(old, new)
    applied.append((path, why))

if "--check" in sys.argv:
    print(f"All {len(applied)} anchors found. Nothing written (--check).")
    sys.exit(0)

for path, text in buffers.items():
    path.write_text(text)

for path, why in applied:
    print(f"  {path.relative_to(ROOT)} — {why}")
print(f"Done. {len(buffers)} files, {len(applied)} edits.")
