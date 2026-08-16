#!/usr/bin/env python3
r"""
check-invariants.py — the rules that already caught something, kept running.

Run from the repository root, or let `scripts/test.sh` run it:

    python3 scripts/check-invariants.py

WHY THIS FILE EXISTS
--------------------
Twice in four patches, a hand-written list was missing an entry, and both
times a mechanical check found it:

  · 369a  `removedTotal` summed three of six counters. The check read the
          declarations instead of the list and found the third — the one I
          did not know about.
  · 372   §12.115.6 named four stores carrying an exposure. There were five.
          `Matcher` was missed because the list was built by searching for
          the shape of the FIX — `StoreRead.decode` — rather than the shape
          of the RISK, which is `lastLoad`.
  · 377d  Eighteen test assertions pinned a five-family bootstrap that had
          become six. The compiler found every constructor that gained an
          argument and had no opinion about `== 5`, which is a well-typed
          expression about a number that changed. Four apply rounds.

Both checks existed. Both ran once, inside an apply script, and died with the
patch. Nothing re-ran them, so the same class of miss was free to recur — and
did, four patches later, in the other direction.

**A guard that runs once is a guard that catches the defect it was written
for and nothing else.** This file is where a rule goes when it has earned the
right to keep running.

WHAT BELONGS IN HERE
--------------------
A rule earns its place by having caught a REAL defect, and by being decidable
from the source text alone. Rules that merely sound prudent do not go in: an
invariant nobody has violated is a guess about the future, and this file is
expensive exactly in proportion to how much of it is noise.

Nothing here duplicates the test suite. These are the facts the compiler and
the tests cannot see — a sum that must name every declared counter, a store
that must refuse before it writes — because no single expression in the app
ever states them.

EVERY RULE MUST FAIL WHEN IT FINDS NOTHING
------------------------------------------
§12.69, and it is the whole reason this file can be trusted. A regex that
silently matches zero declarations reports a clean run while checking nothing,
which is precisely what `test.sh` did between patches 318 and 325 and what its
header now exists to describe. So every rule below states how many things it
examined, prints that number, and FAILS if it drops below a floor.

A rule that cannot say what it checked has not checked anything.
"""

import re
import sys
from pathlib import Path

ROOT = Path.cwd()
APP = ROOT / "Sub4"
TESTS = ROOT / "Sub4CoreTests"

VIOLATIONS = []
REPORT = []


def fail(rule, message):
    VIOLATIONS.append((rule, message))


def counted(rule, n, floor, unit):
    """The §12.69 half. A rule reports its own coverage, and a rule that found
    less than it should have is a broken rule, not a clean tree.

    Floors sit well under the real figures, so ordinary churn does not reach
    them. One that fires means either the source moved or this rule stopped
    parsing it — and if something really was retired, LOWER THE FLOOR ON
    PURPOSE. Editing it is meant to take a decision."""
    REPORT.append(f"  {rule}: {n} {unit}")
    if n < floor:
        fail(rule, f"only {n} {unit} found, expected at least {floor}. Either "
                   "the declarations moved and this rule is now reading the "
                   "wrong thing — in which case it has been checking nothing — "
                   "or something was retired and the floor should be lowered "
                   "deliberately.")
        return False
    return True


def strip_comments(text):
    return "\n".join(l for l in text.split("\n")
                     if not l.strip().startswith("//"))


def app_sources():
    if not APP.is_dir():
        fail("setup", f"{APP} is not a directory — run from the repo root")
        return []
    return sorted(APP.rglob("*.swift"))


def braced(body, header):
    """Brace-matched, never a character window — a fixed-size slice reads
    whatever follows it and calls that the body."""
    i = body.find(header)
    if i < 0:
        return None
    j = body.find("{", i)
    if j < 0:
        return None
    depth, k = 0, j
    while k < len(body):
        if body[k] == "{":
            depth += 1
        elif body[k] == "}":
            depth -= 1
            if depth == 0:
                return body[j:k]
        k += 1
    return None


# --------------------------------------------------------------------------
# RULE 1 — patch 372, §12.116; widened at 378, §12.122
# --------------------------------------------------------------------------

# The stores that decode a file into memory and write that memory back, and
# have not yet been brought under §12.116. It may only ever go DOWN.
#
#   378: 3 → 2.  ActivityStore fixed. AthleteStore and AthleteConstants remain.
#
# A CEILING RATHER THAN A FAILURE, deliberately. Failing outright would block
# `test.sh` on a tree whose exposure predates this rule by two hundred patches,
# and the usual answer to that is an exemption list — a hand-kept list of names
# in a file away from the thing it names, which is the defect this project has
# now paid for four times. A number that may only be lowered is the smallest
# thing that keeps the debt visible in every run without stopping the build.
UNPROTECTED_STORE_CEILING = 2


def every_store_that_records_a_read_refuses_a_write():
    """**WIDENED AT 378, AND THE WIDENING IS THE FINDING.**

    This searched for `var lastLoad: StoreLoad` — "a store that has admitted
    its read can fail". Six stores declared it; all six guarded; the rule was
    green. `ActivityStore` decoded `activities.json` with `?? []`, never
    declared a `lastLoad`, and was therefore never in the population — one
    sync away from writing a window over 661 activities.

    That is 372's own finding one level up. 372 wrote that §12.115.6 missed
    `Matcher` because the list was built from the shape of the FIX rather than
    the shape of the RISK. Relative to a store that adopted NEITHER, `lastLoad`
    is itself a fix-shape.

    The risk is older and duller: a store that decodes a file into memory and
    writes that memory back. That is `let fileURL: URL` plus a write, and it
    finds eight.

    TWO CHECKS OVER TWO DIFFERENT POPULATIONS, AND KEEPING THEM SEPARATE IS
    THE WHOLE OF IT:

      · CHECK A, unchanged from 372 and over EVERY source: a store that HAS a
        `lastLoad` and does not ask it. Always a failure — it admitted the risk
        and then took it.
      · CHECK B, new: file-backed writers with NEITHER, held under a ceiling
        that only goes down.

    **CHECK A MUST NOT BE SCOPED TO THE FILE-BACKED POPULATION.** The first
    draft of this widening ran both checks over `let fileURL: URL` + a write,
    and that silently dropped `Matcher` — which keeps a `lastLoad`, guards it,
    and is backed by `UserDefaults` rather than a file. A store that stopped
    guarding would have gone unnoticed there. **Widening one population
    narrowed another**, which is this patch's own finding happening inside the
    fix for it, and it was caught by running the rule rather than reading it.
    """
    rule = "stores refuse after an unclean read"
    declarers, missing = [], []
    for f in app_sources():
        body = strip_comments(f.read_text())
        if not re.search(r"var lastLoad: StoreLoad", body):
            continue
        declarers.append(f.name)
        if "lastLoad.isTrustworthy" not in body:
            missing.append(f.name)

    if not counted(rule, len(declarers), 6, "stores declaring lastLoad"):
        return

    population, unprotected = [], []
    for f in app_sources():
        body = strip_comments(f.read_text())
        # THE DECLARATION, NOT THE WORD. `DatabaseHealthView` mentions a
        # `fileURL` local for a temp directory and is not a store; matching the
        # stored property is what tells a store from a mention of one.
        if not re.search(r"^\s*(private )?let fileURL: URL", body, re.M):
            continue
        if not ("StoreWrite.encode" in body
                or "StoreWriteJournal.shared.attempt" in body):
            continue
        population.append(f.name)
        if not re.search(r"var lastLoad: StoreLoad", body):
            unprotected.append(f.name)

    if not counted(rule, len(population), 7, "file-backed stores that write"):
        return

    for name in missing:
        fail(rule, f"{name} keeps a lastLoad and never asks it before writing. "
                   "An unreadable file will be read as an empty store and "
                   "saved back over the real one. §12.116")

    REPORT.append(f"  {rule}: {len(unprotected)} unprotected "
                  f"(ceiling {UNPROTECTED_STORE_CEILING})"
                  + (f" — {', '.join(sorted(unprotected))}" if unprotected
                     else ""))
    if len(unprotected) > UNPROTECTED_STORE_CEILING:
        fail(rule, f"{len(unprotected)} file-backed stores decode into memory "
                   "and write it back with no `lastLoad` and no guard: "
                   f"{', '.join(sorted(unprotected))}. The ceiling is "
                   f"{UNPROTECTED_STORE_CEILING}. Either bring one under "
                   "§12.116 or LOWER THE CEILING ON PURPOSE — it may not be "
                   "raised. §12.122")
    if len(unprotected) < UNPROTECTED_STORE_CEILING:
        fail(rule, f"only {len(unprotected)} unprotected stores remain and the "
                   f"ceiling still reads {UNPROTECTED_STORE_CEILING}. Lower it "
                   "in the same patch that fixed one, or the next regression "
                   "has room to hide. §12.122")


# --------------------------------------------------------------------------
# RULE 2 — patch 369a, §12.113.5
# --------------------------------------------------------------------------

def every_removal_counter_is_in_the_total():
    """Six counters and one sum, written by different patches at different
    times with nothing connecting them — so two were missing for as long as
    there were five, and 369 had already begun writing that figure into the
    ledger as durable evidence of what a run deleted.

    Reads the declarations, not the sum.
    """
    rule = "removal counters are all in the total"
    p = APP / "Sub4Import.swift"
    if not p.exists():
        fail(rule, "Sub4/Sub4Import.swift is missing")
        return
    body = strip_comments(p.read_text())
    total = braced(body, "        var removedTotal: Int {")
    if total is None:
        fail(rule, "removedTotal could not be located — it has moved, and this "
                   "rule cannot see what it is meant to be checking")
        return
    counters = sorted(set(re.findall(r"var (\w+Removed)\s*=\s*0", body)))
    if not counted(rule, len(counters), 6, "counters declared"):
        return
    for c in counters:
        if c not in total:
            fail(rule, f"{c} is declared and is not in removedTotal. The number "
                       "the import calls 'rows removed in total' would not be "
                       "the total, and 369 writes it into migration_run as the "
                       "record of what a run deleted. §12.113.5")


# --------------------------------------------------------------------------
# RULE 3 — patch 366b, §12.110.8
# --------------------------------------------------------------------------

def top_level_args(call):
    blanked = re.sub(r'"(?:[^"\\]|\\.)*"',
                     lambda m: '"' + "_" * (len(m.group(0)) - 2) + '"', call)
    args, depth, start = [], 0, 0
    for i, ch in enumerate(blanked):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(call[start:i])
            start = i + 1
    args.append(call[start:])
    return args


def calls_in(text, macro):
    out = []
    for m in re.finditer(re.escape(macro) + r"\(", text):
        i = m.end()
        depth, j, in_str, esc = 1, i, False, False
        while j < len(text) and depth:
            c = text[j]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            j += 1
        if depth == 0:
            out.append((text[:m.start()].count("\n") + 1, text[i:j - 1]))
    return out


def no_expect_message_is_a_concatenation():
    """A `+` in a swift-testing failure message makes the whole expression the
    message, and what prints on failure is not what was written.

    Found at 366b and carried by hand into every apply script since, which is
    six copies of a rule nobody was running between patches. This is the copy
    that runs.
    """
    rule = "expect messages are single literals"
    if not TESTS.is_dir():
        fail(rule, f"{TESTS} is not a directory")
        return
    checked, files = 0, 0
    for f in sorted(TESTS.rglob("*.swift")):
        files += 1
        text = strip_comments(f.read_text())
        for macro in ("#expect", "#require"):
            for line, call in calls_in(text, macro):
                args = top_level_args(call)
                if len(args) < 2:
                    continue
                last = args[-1].strip()
                if not last.startswith('"'):
                    continue
                checked += 1
                if "+" in re.sub(r'"(?:[^"\\]|\\.)*"', "", last):
                    fail(rule, f"{f.name} line ~{line}: the {macro} message is "
                               "a concatenation, so the text that prints on "
                               "failure is not the text written. §12.110.8")
    # 115 files and 1096 messages as of 375. Half of each: a rule that
    # parsed nothing, or a directory that moved, lands far below.
    counted(rule, files, 60, "test files read")
    counted(rule, checked, 500, "messages examined")


# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# RULE 4 — patch 375, §12.119
# --------------------------------------------------------------------------

def minutes_are_never_accumulated():
    """`Activity.minutes` is `movingTime / 60`. Adding those up loses up to a
    minute per activity, and seven places did it — the day total, the Extra
    movement header, `DayDistance`, the week's moving time and three in the
    commute view, one of which then divided the result by 60 again.

    `MergedActivity` had the correct shape since patch 177 and nothing said so,
    which is 369a's finding again: a total assembled from parts by hand.

    Seconds add. Minutes are derived at the end, once.
    """
    rule = "minutes are derived, never accumulated"
    seen = 0
    for f in app_sources():
        for n, raw in enumerate(strip_comments(f.read_text()).split("\n"), 1):
            if ".minutes" not in raw:
                continue
            seen += 1
            # An accumulation is a `reduce` over it or a `+=` into it. Reading
            # one activity's minutes to print is not, and is most of the hits.
            if re.search(r"reduce\(.*\.minutes|\+=\s*.*\.minutes", raw):
                fail(rule, f"{f.name} line {n}: `{raw.strip()[:56]}` adds up "
                           "values that were already truncated. Sum "
                           "`movingTime` and divide once — `totalMinutes`. "
                           "§12.119")
    counted(rule, seen, 10, "uses of .minutes examined")



# --------------------------------------------------------------------------
# RULE 5 — patch 377d, §12.121.8
# --------------------------------------------------------------------------

def pinned_counts_match_the_source():
    """Eighteen test assertions pinned the five-family world. 377 made it six
    and the compiler found none of them, because `== 5` is a well-typed
    expression about a number that changed.

    THE FOURTH TIME THIS SHAPE HAS COST A PATCH — 369a's three of six
    counters, 372's four of five stores, 377's five of six families, and now
    the tests' own copies of all three. A number kept by hand in a different
    file from the thing it counts.

    So this reads the counts FROM THE APP and compares them against every
    literal pin in the test target. It does not have a list of the right
    answers; it derives them.

    A pin is still worth having: `fieldCount == 6` is how adding a family
    becomes a decision somebody takes on purpose. This rule does not remove
    the decision, it removes the four rounds of discovering which pins exist.
    """
    rule = "pinned counts match the source"

    boot = APP / "DatabaseBootstrap.swift"
    mode = APP / "PersistenceMode.swift"
    for p in (boot, mode):
        if not p.exists():
            fail(rule, f"{p} is missing — this rule cannot read the truth")
            return
    bsrc = strip_comments(boot.read_text())
    msrc = strip_comments(mode.read_text())

    truth = {}

    m = re.search(r"static let fieldCount\s*=\s*(\d+)", bsrc)
    if not m:
        fail(rule, "DatabaseBootstrap.fieldCount could not be read")
        return
    truth["fieldCount"] = int(m.group(1))

    m = re.search(r"static let diagnosticLineCount\s*=\s*fieldCount\s*\+\s*(\d+)",
                  bsrc)
    if not m:
        fail(rule, "diagnosticLineCount is no longer `fieldCount + N` — this "
                   "rule was reading a shape that has changed")
        return
    truth["diagnosticLineCount"] = truth["fieldCount"] + int(m.group(1))

    fam = braced(msrc, "nonisolated enum Family: String, CaseIterable, Sendable")
    if fam is None:
        fail(rule, "PersistenceAuthority.Family could not be located")
        return
    cases = []
    for line in fam.split("\n"):
        s = line.strip()
        if s.startswith("case "):
            cases += [c.strip() for c in s[5:].split(",") if c.strip()]
    truth["Family.allCases.count"] = len(cases)

    m = re.search(r"static let hydratedFamilies: Set<Family> = \[(.*?)\]",
                  msrc, re.S)
    if not m:
        fail(rule, "hydratedFamilies could not be read")
        return
    truth["hydratedFamilies.count"] = len(re.findall(r"\.(\w+)", m.group(1)))

    # BRACKET-MATCHED, NOT BRACE-MATCHED. `braced` finds the next `{` after a
    # header; `all` is an ARRAY literal, so the nearest brace belongs to some
    # later declaration entirely and the entry count came back 0. The rule
    # reported a number of pins well above its floor while comparing them all
    # against nothing — §12.69's exact failure, in the rule written to enforce
    # §12.69. Caught by 377d's own guard, which parses this differently on
    # purpose.
    i = msrc.find("nonisolated static let all: [Entry] = [")
    if i < 0:
        fail(rule, "HydratedStores.all could not be located")
        return
    j = msrc.index("[", msrc.index("= [", i))
    depth, k = 0, j
    while k < len(msrc):
        if msrc[k] == "[":
            depth += 1
        elif msrc[k] == "]":
            depth -= 1
            if depth == 0:
                break
        k += 1
    else:
        fail(rule, "HydratedStores.all is not bracket-balanced")
        return
    truth["HydratedStores.all.count"] = msrc[j:k].count(".init(check:")
    if truth["HydratedStores.all.count"] == 0:
        fail(rule, "HydratedStores.all parsed to zero entries — this rule is "
                   "reading the wrong thing and every comparison below it is "
                   "meaningless. §12.69")
        return

    # EVERY FAMILY MUST BE HYDRATED IS *NOT* WHAT THIS ASSERTS. B3 will read a
    # family before it feeds it and the two counts will differ on purpose.
    # What it does assert is that a slice cannot feed a family that does not
    # exist, which would be a typo rather than a decision.
    if truth["hydratedFamilies.count"] > truth["Family.allCases.count"]:
        fail(rule, "hydratedFamilies names more families than Family declares")

    # ---- the pins, in the tests
    if not TESTS.is_dir():
        fail(rule, f"{TESTS} is not a directory")
        return

    # (regex, which truth it must equal). Each is anchored on the OWNING TYPE
    # where one exists: `AppStores.fieldCount` is a different number in the
    # write direction and pinning it to this one would be a false failure.
    PINS = [
        (r"DatabaseBootstrap\.fieldCount\s*==\s*(\d+)", "fieldCount"),
        (r"DatabaseBootstrap\.diagnosticLineCount\s*==\s*(\d+)",
         "diagnosticLineCount"),
        (r"PersistenceAuthority\.Family\.allCases\.count\s*==\s*(\d+)",
         "Family.allCases.count"),
        (r"PersistenceAuthority\.hydratedFamilies\.count\s*==\s*(\d+)",
         "hydratedFamilies.count"),
        (r"HydratedStores\.all\.count\s*==\s*(\d+)", "HydratedStores.all.count"),
        (r"selfReferentialChecks\.count\s*==\s*(\d+)",
         "HydratedStores.all.count"),
        (r"\.checks\.count\s*-\s*(\d+)", "HydratedStores.all.count"),
        (r"\.checks\.count\s*-\s*\S*\.independentChecks\.count\s*==\s*(\d+)",
         "HydratedStores.all.count"),
        (r'"Database bootstrap:\s*(\d+) families', "fieldCount"),
    ]

    pins = 0
    for f in sorted(TESTS.rglob("*.swift")):
        # BLANKED, NOT REMOVED. `strip_comments` drops lines, so every number
        # after the first comment is wrong — and a failure message that names
        # the wrong line sends a reader to the wrong assertion. §12.15.
        for n, raw in enumerate(f.read_text().split("\n"), 1):
            if raw.strip().startswith("//"):
                continue
            for pattern, key in PINS:
                for m in re.finditer(pattern, raw):
                    pins += 1
                    got, want = int(m.group(1)), truth[key]
                    if got != want:
                        fail(rule,
                             f"{f.name} line ~{n}: pinned {got}, the source "
                             f"says {key} is {want}. `{raw.strip()[:60]}`. "
                             "Adding a family is a decision and this pin is "
                             "how it is taken — but it is taken in the patch "
                             "that adds the family, not four rounds later. "
                             "§12.121.8")

    # THIRTEEN PINS ACROSS 119 TEST FILES as of 377d, so the floor is eight —
    # this file's usual "well under the real figure", not one below it. A
    # floor sitting on top of the count fires on the next patch that retires
    # an assertion, which teaches a reader to lower it without thinking.
    counted(rule, pins, 8, "count pins compared against the source")
    # NOT THE SAME KIND OF FLOOR. The five above are a DECLARED arity, not a
    # discovered population: every one of them hard-fails this rule if it
    # cannot be parsed. It is here so the printed report says what the rule
    # was comparing against, which is the other half of §12.69.
    counted(rule, len(truth), 5, "counts derived from the app")

    # WHAT THIS RULE DOES NOT COVER, said out loud. Ten of 377's eighteen
    # stale assertions are numbers and are above. The other eight are array
    # literals (`hydratedFamilies == [...]`, `emptyAuthoredFamilies`), a set of
    # check names, and two claims about what a comparison MEANS. None is a
    # count, so none can be derived this way. `apply-377d.py`'s guards cover
    # those, and a future family addition still has to read §12.121.8 rather
    # than trust a green run here.


# --------------------------------------------------------------------------
# RULE 6 — patch 384, §12.128
# --------------------------------------------------------------------------

# How far a state document may fall behind `AppVersion.patch` before this fails.
#
# TWELVE RATHER THAN ZERO, AND THE NUMBER IS THE WHOLE DESIGN. A slice is five
# to ten patches. A rule that demanded a documentation edit in every patch would
# be edited out inside a week, and a rule nobody keeps is worse than none — it
# reads as a check while checking nothing. Twelve lets a slice finish and fails
# before a second one starts.
#
# The drift is PRINTED on every run whether or not it fails, which is the half
# that matters: the ceiling stops the rot, the printout is how somebody sees it
# coming. Same shape as UNPROTECTED_STORE_CEILING above.
STATE_DOC_DRIFT_CEILING = 12

# (file, regex capturing the patch number, what to call it in the message).
#
# THE MASTER PLAN IS DELIBERATELY NOT HERE. Its baseline is legitimately
# historical — a plan written against a patch stays written against it. What it
# owes is a POINTER to the current state, and that is prose a regex should not
# be asked to police.
STATE_DOCS = [
    ("CLAUDE.md", r"\*\*Current at patch (\d+)", "CLAUDE.md's header"),
    ("CLAUDE.md", r"## 5\. State — patch (\d+)", "CLAUDE.md §5"),
    ("README.md", r"\*Current at patch (\d+)", "README.md"),
]


def the_state_documents_name_the_current_patch():
    """**FOUR DOCUMENTS, FOUR ANSWERS, ONE QUESTION.** At patch 383 this
    repository said 338, 343, 332 and 334 in four files a reader meets before
    any code. Every one had been true. §5's own header carried a warning telling
    the reader to distrust it, which is a document apologising for itself rather
    than a fix.

    This reads the truth out of `AppVersion.swift` — the number that is wrong
    only if a patch did not install — and compares it against what each state
    document claims.

    A document naming a patch AHEAD of the source is also a failure, and a
    different one: it describes a build nobody has installed."""
    rule = "state documents name the current patch"

    p = ROOT / "Sub4" / "AppVersion.swift"
    if not p.exists():
        fail(rule, "Sub4/AppVersion.swift is missing — this rule cannot read "
                   "the truth")
        return
    m = re.search(r"static let patch = (\d+)", p.read_text())
    if not m:
        fail(rule, "AppVersion.patch could not be read")
        return
    current = int(m.group(1))

    read = 0
    for name, pattern, label in STATE_DOCS:
        f = ROOT / name
        if not f.exists():
            fail(rule, f"{name} is missing")
            continue
        found = re.search(pattern, f.read_text())
        if not found:
            fail(rule, f"{label} does not state a patch number. The pattern "
                       f"{pattern!r} matched nothing, so this rule has checked "
                       "nothing there — restore the line or fix the rule. "
                       "§12.69")
            continue
        read += 1
        claimed = int(found.group(1))
        drift = current - claimed
        REPORT.append(f"  {rule}: {label} says {claimed}, source says "
                      f"{current} (drift {drift}, ceiling "
                      f"{STATE_DOC_DRIFT_CEILING})")
        if drift < 0:
            fail(rule, f"{label} names patch {claimed} and the source is at "
                       f"{current}. A document describing a build nobody has "
                       "installed is worse than one behind: it cannot be "
                       "checked against anything.")
        elif drift > STATE_DOC_DRIFT_CEILING:
            fail(rule, f"{label} is {drift} patches behind ({claimed} against "
                       f"{current}). Bring it up to date, or if the state has "
                       "genuinely not moved, say so there with today's number. "
                       "Four documents disagreeing about the present is what "
                       "this rule exists to stop. §12.128")

    counted(rule, read, 3, "state declarations read")


RULES = [
    every_store_that_records_a_read_refuses_a_write,
    every_removal_counter_is_in_the_total,
    no_expect_message_is_a_concatenation,
    minutes_are_never_accumulated,
    pinned_counts_match_the_source,
    the_state_documents_name_the_current_patch,
]

for r in RULES:
    r()

print(f"checked {len(RULES)} invariants:")
for line in REPORT:
    print(line)

if VIOLATIONS:
    print()
    for rule, message in VIOLATIONS:
        print(f"FAIL [{rule}] {message}")
    print()
    print("These are rules that each caught a real defect once. A failure here "
          "is not style.")
    sys.exit(1)

print()
print("all invariants hold")
