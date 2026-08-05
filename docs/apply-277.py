#!/usr/bin/env python3
"""
Patch 277 — the 23 get a decision beside them.

`activity: 668` and `recording: 645` sit four lines apart with nothing
accounting for the difference. This adds the account, and gives
`DetailStore.backfillRemaining`'s underlying queue its first caller.

`TraceCoverage.swift` ships whole in the zip; this wires it in.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


D = "Sub4/DetailStore.swift"
H = "Sub4/DatabaseHealthView.swift"

# ------------------------------------------------------------- DetailStore

edit(
    D,
    r'''    private func needsStreams(_ a: Activity) -> Bool {''',
    r'''    /// Why every activity does or does not have a trace — patch 277.
    ///
    /// ONE LINE, because the classifying is pure and lives in
    /// `TraceCoverageReport`. This supplies the four sets and the threshold;
    /// it decides nothing, which is what makes the decision testable without
    /// arranging the athlete's actual files on disk.
    ///
    /// `pending` gets its first reader here. `backfillRemaining` has been
    /// `pending.count` since it was written and nothing has ever shown it —
    /// §12.23.7 — so until now "never asked" and "queued and not yet reached"
    /// were indistinguishable from outside this file.
    @MainActor
    func traceCoverage() -> TraceCoverage {
        TraceCoverageReport.classify(
            activities: ActivityStore.shared.activities,
            hasTrace: { self.streams[$0] != nil },
            refused: failed,
            answeredEmpty: noStreams,
            queued: Set(pending),
            minDistance: minStreamDistance)
    }

    private func needsStreams(_ a: Activity) -> Bool {''',
    "the store's trace account",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                // PATCH 276. Named for what it MEANS rather than for its''',
    r'''                // PATCH 277. THE COUNTER THAT HAD NO DECISION BESIDE IT.
                //
                // `activity: 668` and `recording: 645` sit four lines apart in
                // the table list and nothing accounted for the difference —
                // finding out what it was took reading `DetailStore`, which is
                // not a thing a number on a screen should require.
                //
                // Every activity lands in exactly one bucket and the buckets
                // sum to the total, so `unexplained` is the only line worth
                // watching: it is zero today, and the day it is not is the day
                // an activity has no trace for a reason nothing here has a
                // name for.
                if coverage.missing > 0 {
                    LabeledContent("Activities with no trace",
                                   value: "\(coverage.missing) of \(coverage.total)")
                        .font(.caption)
                    if coverage.answeredEmpty > 0 {
                        LabeledContent("  asked, nothing there",
                                       value: "\(coverage.answeredEmpty)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.refused > 0 {
                        LabeledContent("  the source refused it",
                                       value: "\(coverage.refused)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.belowThreshold > 0 {
                        LabeledContent("  under 500 m, never asked",
                                       value: "\(coverage.belowThreshold)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.queued > 0 {
                        LabeledContent("  queued, not yet reached",
                                       value: "\(coverage.queued)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    // RED, AND SHOWN EVEN AT ZERO once anything is missing —
                    // the residual is the whole point of the account, and a
                    // line that only appears when it is non-zero cannot be
                    // told apart from a line nobody wired in.
                    LabeledContent("  unexplained", value: "\(coverage.unexplained)")
                        .font(.caption2)
                        .foregroundStyle(coverage.isFullyExplained ? Color.dim : Color.red)
                }

                // PATCH 276. Named for what it MEANS rather than for its''',
    "the trace account on screen",
)

edit(
    H,
    r'''    private func runImport(_ db: Sub4Database) {''',
    r'''    /// Patch 277. Recomputed on every render rather than stored: it is six
    /// counters over an array the screen already holds, and a cached copy
    /// would be the thing that goes stale after an import.
    private var coverage: TraceCoverage { DetailStore.shared.traceCoverage() }

    private func runImport(_ db: Sub4Database) {''',
    "the view's coverage",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''### 12.23.8 The 23 get a decision beside them — patch 277

§12.23.7 recorded a counter with no decision beside it: `activity: 668` and
`recording: 645`, four lines apart, difference unaccounted for. Finding out
what the difference was took reading `DetailStore` — which is not a thing a
number on a screen should require.

**It is an account, not five numbers.** Every activity lands in exactly one
bucket, in a fixed order, and the buckets sum to the total:

| bucket | why |
|---|---|
| has a trace | it is here |
| the source refused it | 404, `DetailStore.failed` |
| asked, nothing there | `DetailStore.noStreams` |
| under 500 m, never asked | `needsStreams` requires `minStreamDistance` |
| queued, not yet reached | in `pending` |
| **unexplained** | none of the above |

**The order is the definition.** A trace that arrived outranks every reason it
might once have been absent — those reasons are stale the moment the data
lands. A refusal outranks an empty answer, because a 404 stops the detail fetch
before the stream fetch is reached. The distance rule outranks the queue,
because an activity under the threshold is never queued at all.

**`unexplained` is the only line worth watching**, and it is why this is an
account rather than a list. Five counters can each be correct while the set of
them is missing a case; a residual that has to make the total add up cannot
hide one. It is zero today. The day it is not is the day an activity has no
trace for a reason nothing in this app has a name for.

**`pending` gets its first reader.** `backfillRemaining` has been
`pending.count` since it was written and nothing ever showed it — the second
method-written-in-anticipation found this week, after §12.8.4's. Until now
"never asked" and "queued and not yet reached" were indistinguishable from
outside `DetailStore`, which is exactly the ambiguity that made §12.23.7's
prediction wrong.

**Pure, so it can be tested.** `DetailStore` is a singleton over the real disk;
a classifier that read it directly could only be exercised by arranging the
athlete's actual files. `TraceCoverageReport.classify` takes its inputs, the
store supplies them in one line, and `theDeviceShapeAddsUp` reproduces the 5
August device — 645 traces, 2 answered empty, 21 under the threshold — as a
fixture, so the arithmetic §12.23.7 corrected is checked rather than asserted
in prose.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.23.8",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
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
