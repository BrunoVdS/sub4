#!/usr/bin/env python3
"""
Patch 312 — D6c slice 1: the twin, and the first comparison.

309 and 310 built half of slice 1: `ActivityRoster.settle` became the ONE
implementation of the three rules, and both of `ActivityStore`'s doors call it.
Nothing had ever built the same list from the database. This does.

  · THE TWIN REIMPLEMENTS NOTHING. `ActivityRepository.all(db)` produces
    `[Activity]`; `ActivityRoster.settle` turns that into the list. Both sides
    call the SAME settle, the SAME byDay, the SAME DayZones.from. There is one
    implementation of every rule in the comparison, which is the property the
    three patches were built in sequence to establish. §12.43.

  · `byDay` MOVES INTO THE ROSTER. It was one line in ActivityStore's didSet,
    and one line copied twice is still two implementations. Dictionary(grouping:)
    preserves encounter order and patch 168 says callers depend on that — so the
    comparison checks each day's SEQUENCE, not each day's set.

  · WHAT IT ASKS, AND WHAT IT DELIBERATELY DOES NOT. The three read-backs above
    it ask whether both sides hold the same RECORDS — nineteen named fields per
    activity. This asks whether both sides DERIVE the same list: identity as a
    set after the rules, order, day membership, and the zones. It re-checks no
    fields. Two comparisons of one thing is the mistake this project keeps
    paying for.

  · A ROW THE RULES REFUSE IS NOT A DIFFERENCE. The twin drops what the store
    would drop, so a refused row shows as `databaseDropped`. That number is the
    first instrument this project has for §12.46.3's known gap: automatic
    write-throughs do not reconcile, so a record deleted in the app stays in the
    database until somebody presses Import.

  · IT CAN BE SEEN FAILING. Groundwork §2.1 said a check whose answer is always
    "no differences" cannot be told from one that is broken.
    `ActivityParityTests` hands it one dropped activity, one extra, a swapped
    pair, one moved to another day, one on a different clock, one the rules
    refuse, and a store holding a list its own rules would change — every one
    built through the real importer and the real repository, perturbed on the
    store side. And `nothingComparedIsNotAgreement` pins the case that would
    otherwise be a green tick meaning nothing.

  · NO APPROVED-DIFFERENCE LIST. Groundwork §5's two entries are both about
    details and recordings. For activities the expected count is zero, so
    nothing is filtered out and any number above zero is real. Built in the
    slice that has entries.

TWO NEW FILES, so this needs a full quit and reopen:
  Sub4/ActivityParity.swift
  Sub4CoreTests/ActivityParityTests.swift

Files replaced wholesale (they are in the zip, copy them over)
  Sub4/ActivityRoster.swift            + byDay
  Sub4/AppVersion.swift                312

Files this script edits in place
  Sub4/ActivityStore.swift             the didSet calls the roster
  Sub4/DatabaseHealthView.swift        the parity section, and the paste
  docs/ADR-0003-database-contract.md   + §12.56

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


STORE = "Sub4/ActivityStore.swift"
HEALTH = "Sub4/DatabaseHealthView.swift"
ADR = "docs/ADR-0003-database-contract.md"

# -------------------------------------------------------------- ActivityStore

edit(STORE, r'''        didSet {
            byDay = Dictionary(grouping: activities, by: \.dayKey)
            dayZones = DayZones.from(activities: activities)
        }''',
     r'''        didSet {
            // MOVED TO `ActivityRoster` AT 312, and it is one line, and that is
            // the point. D6c's twin needs the same buckets built from the
            // database — **one line copied twice is still two implementations**
            // (§12.43), and this one carries a promise a copy would not:
            // `Dictionary(grouping:)` preserves encounter order, which patch
            // 168's comment below says callers depend on.
            byDay = ActivityRoster.byDay(activities)
            // `DayZones.from` was already a shared pure function, so the twin
            // calls this one. Nothing to move.
            dayZones = DayZones.from(activities: activities)
        }''',
     "the didSet calls the roster")

# --------------------------------------------------------- DatabaseHealthView

edit(HEALTH, r'''    @State private var verifying = false
    @State private var verification: VerificationReport?''',
     r'''    @State private var verifying = false
    @State private var verification: VerificationReport?

    /// D6c slice 1 — patch 312. `.never` until the button is pressed, and
    /// `.never` is not agreement.
    @State private var comparingParity = false
    @State private var parity: ActivityParity.Outcome = .never''',
     "the parity state")

edit(HEALTH, r'''                readBackSection(db)
                detailReadBackSection(db)
                recordingReadBackSection(db)''',
     r'''                readBackSection(db)
                detailReadBackSection(db)
                recordingReadBackSection(db)
                    // AFTER the three read-backs, because it asks the question
                    // they cannot: they compare RECORDS, this compares the list
                    // the app would DERIVE from them. The screen reads in the
                    // order the two questions relate — are the rows the same,
                    // and then would the screens be the same.
                    paritySection(db)''',
     "the parity section, in the body")

edit(HEALTH, r'''    /// The precise names, trimmed. `laps[*].averageHR` in the tally says WHAT;''',
     r'''    /// D6c SLICE 1 — patch 312, groundwork §6.1.
    ///
    /// The three sections above ask *do both sides hold the same records*. This
    /// asks *would the app derive the same list* — same activities, same order,
    /// same day buckets, same clocks. It re-checks no fields; `ActivityRoundTrip`
    /// does that and doing it twice is how two answers to one question start.
    ///
    /// EVERY ROW IS UNCONDITIONAL once a comparison has run. §12.54.2, and this
    /// screen has now learned it twice: a row that vanishes at zero cannot be
    /// told from a row nobody wired in.
    @ViewBuilder
    private func paritySection(_ db: Sub4Database) -> some View {
        Section {
            if comparingParity {
                HStack { ProgressView(); Text("Deriving…").font(.caption) }
            } else {
                Button("Compare the derived lists") { runParity(db) }
            }

            LabeledContent("Parity", value: parity.line)
                .font(.caption)
                .foregroundStyle(parity.isHealthy ? Color.dim : .red)

            if case .ran(let r) = parity {
                // THE THREE DENOMINATORS — groundwork §2.1 case 2. A dead read
                // stops them matching, and zero compared to zero agrees
                // perfectly while meaning nothing.
                LabeledContent("In the app", value: "\(r.storeCount)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("In the database",
                               value: "\(r.databaseKept) of \(r.databaseOffered) rows")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.common)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

                LabeledContent("In the app only", value: "\(r.storeOnly.count)")
                    .font(.caption)
                    .foregroundStyle(r.storeOnly.isEmpty ? Color.dim : .red)
                LabeledContent("In the database only", value: "\(r.databaseOnly.count)")
                    .font(.caption)
                    .foregroundStyle(r.databaseOnly.isEmpty ? Color.dim : .red)

                LabeledContent("Order disagreements",
                               value: "\(r.orderDiffered) of \(r.orderCompared)")
                    .font(.caption)
                    .foregroundStyle(r.orderDiffered == 0 ? Color.dim : .red)
                if let at = r.firstOrderDisagreement {
                    Text("  first at position \(at + 1)")
                        .font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Days compared", value: "\(r.daysCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Days that disagree",
                               value: "\(r.daysOnlyInStore.count + r.daysOnlyInDatabase.count + r.daysWithDifferentMembers.count)")
                    .font(.caption)
                    .foregroundStyle(r.daysOnlyInStore.isEmpty
                                     && r.daysOnlyInDatabase.isEmpty
                                     && r.daysWithDifferentMembers.isEmpty
                                     ? Color.dim : .red)
                ForEach(r.daysWithDifferentMembers.prefix(5), id: \.self) { day in
                    Text("  \(day)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Time-zone changes",
                               value: r.zonesAgree
                                   ? "\(r.zoneChangesCompared), agreed"
                                   : "\(r.zoneChangesCompared), disagreed")
                    .font(.caption)
                    .foregroundStyle(r.zonesAgree ? Color.dim : .red)

                // DIM WHEN ZERO, INK WHEN NOT — not red. These are not
                // disagreements; they are rows the database is still carrying
                // that the app's own rules refuse. §12.46.3 predicted them.
                LabeledContent("Rows the rules dropped", value: "\(r.databaseDropped)")
                    .font(.caption)
                    .foregroundStyle(r.databaseDropped == 0 ? Color.dim : Color.ink)
                LabeledContent("Rows collapsed as duplicates",
                               value: "\(r.databaseCollapsed)")
                    .font(.caption)
                    .foregroundStyle(r.databaseCollapsed == 0 ? Color.dim : Color.ink)
                LabeledContent("Rows the reader could not read",
                               value: "\(r.databaseSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.databaseSkipped == 0 ? Color.dim : .red)

                LabeledContent("The app's list is settled",
                               value: r.storeIsSettled ? "yes" : "no")
                    .font(.caption)
                    .foregroundStyle(r.storeIsSettled ? Color.dim : .red)
            }
        } header: {
            Text("Shadow parity · activities")
        } footer: {
            Text("Builds the activity list a second time, from the database "
                 + "instead of the files, and compares them. Both sides run "
                 + "through the same rules — one copy, called twice — so a "
                 + "difference here is a difference in the DATA, not in how it "
                 + "was derived.\n\n"
                 + "It does not re-check fields. The three read-backs above do "
                 + "that.\n\n"
                 + "Rows the rules dropped are not disagreements: the database "
                 + "is carrying something the app no longer wants, which is "
                 + "what automatic write-throughs not reconciling looks like. "
                 + "There is no approved-difference list for activities, so "
                 + "every other number above zero is real. See ADR-0003 §12.56.")
                .font(.caption2)
        }
    }

    private func runParity(_ db: Sub4Database) {
        comparingParity = true
        Task {
            // On the main actor, like `runReadBack` — the same 672-row query,
            // and `settle` is the same work the store does twice per launch.
            parity = ActivityParity.run(db)
            comparingParity = false
        }
    }

    /// The precise names, trimmed. `laps[*].averageHR` in the tally says WHAT;''',
     "the parity section")

edit(HEALTH, r'''        lines.append(contentsOf: ActivityStore.shared.loadDiagnosticLines)''',
     r'''        lines.append(contentsOf: ActivityStore.shared.loadDiagnosticLines)
        // PATCH 312. Only after a run — unlike the roster lines above, this one
        // costs a database read and a full derivation, so there is nothing to
        // print until somebody presses the button. The line says WHICH of those
        // two it is, rather than being absent.
        if case .ran(let p) = parity {
            lines.append("")
            lines.append(contentsOf: p.diagnosticLines)
        } else {
            lines.append("")
            lines.append("Activity parity: \(parity.line)")
        }''',
     "parity joins the paste")

# --------------------------------------------------------------------- ADR

ADR_SECTION = r'''## 12.56 The twin, and the first comparison — patch 312

D6c slice 1. 309 and 310 built the half nobody could see: one implementation of
the three rules, called by both of the store's doors. This builds the other half
— the same list, derived from the database — and compares them.

### 12.56.1 A different question from the three above it

The read-backs ask *do both sides hold the same records?* Answered at D6a: 672
activities, 672 details, 649 recordings, 1,412,819 samples, every field compared
by name.

This asks *would the app produce the same list?* Between the rows and the list
stand five rules, and it is the derived list that every screen actually reads.
Equal records do not imply equal derivation.

So it compares only what D6a cannot see: identity as a **set after the rules**,
**order**, **day membership**, and the **zones**. It re-checks no fields. A
second comparison of the same nineteen fields would eventually disagree with the
first, and then neither could be believed.

### 12.56.2 Three patches to make one sentence true

> There is one implementation of every rule in this comparison.

- **309** made both store doors apply the same rules, by writing them out twice.
- **310** made disagreement unavailable: `ActivityRoster.settle`, one call.
- **312** moves `byDay` — one line from a `didSet` — and builds the twin.

`byDay` is the smallest of the three and the clearest illustration. It is
`Dictionary(grouping: activities, by: \.dayKey)`, and copying it into the twin
would have looked free. It is not free, because it carries a promise: encounter
order is preserved, and patch 168's comment says callers depend on that. **One
line copied twice is still two implementations**, and the second copy would have
agreed only while both sides happened to keep sorting the same way.

`DayZones.from` needed no move — it was already a `nonisolated` pure function
with an `Equatable` result, which is what a rule looks like when it was written
in the right place the first time.

### 12.56.3 A row the rules refuse is not a difference

The twin drops what the store would drop, so an activity the database is
carrying that the app no longer wants appears as `databaseDropped` — **not** as
`databaseOnly`.

That distinction matters more than it looks. §12.46.3 owned a cost when
write-through landed: automatic runs do not reconcile, so a record deleted in
the app stays in the database until somebody presses Import. Until now nothing
counted them. `databaseDropped` is the first instrument for that gap, and it is
deliberately **not red** — a number there is the known behaviour of an automatic
run, not a fault.

### 12.56.4 Making a zero believable

Groundwork §2.1: the first comparison will almost certainly report zero
differences, because D6a ruled out data differences and both sides now share the
rules. **A check whose answer is always "no differences" cannot be told from a
check that is broken**, and D7 would be flipped on the strength of it.

Three answers, each with its limit:

| | proves | does not prove |
|---|---|---|
| `ActivityParityTests` — seven planted differences | the comparison reports what it is given | that the device's data is right |
| `common` beside every count | a dead read cannot look like agreement | that the read was complete |
| both sides built from different places | they are not the same object | it, at runtime — this is read, not checked |

`nothingComparedIsNotAgreement` is the one with teeth. Zero compared against
zero agrees perfectly, `unexplained` is honestly 0, and `lookedAtSomething` is
what refuses to let that read as a pass. Without it the healthiest-looking
screen in the app would be the one where the read died.

Every planted difference is built through the real `Sub4Import` and read back
through the real `ActivityRepository`, then perturbed on the store side. There
is no runtime answer to "both sides are secretly the same object"; constructing
them from different places, and saying so, is the whole of it.

### 12.56.5 Order is compared over the common ids only

A single missing activity shifts every position after it. Comparing the raw
sequences would report one absence as four hundred order differences — the same
mistake §12.39 had to fix for sample lengths, where one short stream reported as
three hundred differing samples.

So identity is settled first, and order is compared over what both sides have.
`orderCompared` is printed beside `orderDiffered` for the reason every number on
this screen now is.

### 12.56.6 No approved-difference list, and that is a decision

Groundwork §5 defines one. Both its entries are about details and recordings;
for activities the expected count is zero.

An empty suppression list shipped now would be a gate nothing has passed
through, and the moment a list exists it starts attracting entries. It gets
built in the slice that has one. Until then the screen says so in as many words:
every number above zero is real.

'''

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     ADR_SECTION + "## 12.10 The athlete profile, the zones and the resting series",
     "§12.56")


def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0
    writes = {}
    for path, old, new, why in EDITS:
        if not path.exists():
            print(f"MISSING  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        text = writes.get(path, path.read_text(encoding="utf-8"))
        if new in text and old not in text:
            print(f"already  {path.relative_to(ROOT)}  ({why})")
            continue
        n = text.count(old)
        if n != 1:
            print(f"ANCHOR x{n}  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        writes[path] = text.replace(old, new, 1)
        print(f"ok       {path.relative_to(ROOT)}  ({why})")

    copied = ["Sub4/ActivityParity.swift",
              "Sub4/ActivityRoster.swift",
              "Sub4/AppVersion.swift",
              "Sub4CoreTests/ActivityParityTests.swift"]
    for g in copied:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
        if not here:
            failures += 1

    marker = ROOT / "Sub4/ActivityRoster.swift"
    if marker.exists() and "static func byDay" not in marker.read_text(encoding="utf-8"):
        print("STALE    Sub4/ActivityRoster.swift  (still the 310 copy)")
        failures += 1

    if failures:
        print(f"\n{failures} item(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. TWO NEW FILES — quit Xcode entirely (⌘Q) and reopen")
    print("  2. run the suite")
    print("  3. ⌘R → Settings → Database health → 'Shadow parity · activities'")
    print("     Press 'Compare the derived lists'. Expected:")
    print("       In the app            672")
    print("       In the database       672 of 672 rows")
    print("       Compared              672")
    print("       everything else       0, and 'agreed' / 'yes'")
    print("  4. If 'Compared' reads 0 while 'In the app' reads 672, the read")
    print("     died — that is the case the row exists for.")
    print("  5. Copy diagnostics: seventeen 'Activity parity' lines.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
