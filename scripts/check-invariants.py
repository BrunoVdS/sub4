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
import subprocess
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

    # `HydratedStores.all` WAS READ HERE AND IS GONE — PATCH 387, §12.131.
    #
    # It was bracket-matched rather than brace-matched, because `all` is an
    # ARRAY literal and `braced` found the next declaration's brace instead;
    # the rule then compared every pin against zero while reporting a healthy
    # count of pins. That was §12.69's exact failure inside the rule written to
    # enforce §12.69, and it is recorded here because the shape outlives the
    # list: A RULE THAT CANNOT PARSE ITS SOURCE MUST FAIL, NEVER SUCCEED
    # QUIETLY. The four `truth` entries below each hard-fail if unreadable.
    #
    # The list itself stopped existing at 387: which comparisons are
    # self-referential is now computed from each check's own `reads` and what
    # the build is serving, so there is no hand-kept count for a test to pin.
    # `ExpectationProvenanceTests.theWholeMapIsPinned` is what guards it now,
    # and it is a complete map rather than a count — a shape this rule cannot
    # check and does not pretend to.

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
        # FOUR PATTERNS REMOVED AT 387, all reading `HydratedStores.all.count`:
        # the count itself, `selfReferentialChecks.count == N`, and the two
        # `checks.count - N` forms. The number they compared against no longer
        # exists anywhere in the app — see the note above.
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
    # 387 RETIRED FOUR PINS AND THE FLOOR STAYS AT EIGHT: fourteen remain, so
    # it is still well under, and lowering a floor that is not being reached is
    # how a floor stops meaning anything.
    counted(rule, pins, 8, "count pins compared against the source")
    # NOT THE SAME KIND OF FLOOR. The four above are a DECLARED arity, not a
    # discovered population: every one of them hard-fails this rule if it
    # cannot be parsed. It is here so the printed report says what the rule
    # was comparing against, which is the other half of §12.69.
    #
    # FIVE UNTIL 387, AND THIS IS THE DELIBERATE LOWERING `counted`'s own
    # docstring asks for. `HydratedStores.all.count` was the fifth and the list
    # was deleted; the classification it held is derived now, so there is no
    # count left to read. §12.131.
    counted(rule, len(truth), 4, "counts derived from the app")

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


# --------------------------------------------------------------------------
# RULE 7 — patch 393, §12.137
# --------------------------------------------------------------------------

def every_collapsible_section_matches_its_header():
    """**A KEY IS A JOIN BY NAME BETWEEN TWO PLACES NO TEST CAN REACH.**

    393 made the Database screen's twenty-two sections collapsible. A section's
    HEADER declares `key: "traces"` and its content and footer ask
    `isExpanded("traces")`, and both live inside SwiftUI view bodies — so no
    assertion in the suite can see either one. §12.136.6 already recorded that
    limitation for the export; this rule is what closes it for the collapse,
    because the failure is silent in a way the export's is not.

    THREE FAILURES, AND EACH LOOKS LIKE NOTHING ON THE DEVICE:

      · a content key with no header — the section can never be opened, and
        renders as a title that ignores taps
      · a header key nothing checks — the chevron turns and nothing happens
      · two headers sharing a key — two sections open and close together, which
        reads as a SwiftUI bug rather than a typo

    §12.118.8's bar is whether a permanent rule pays rent. This one does: the
    call sites are copy-pasted by construction, the keys are string literals,
    and the whole class is invisible to the compiler and to the suite.
    """
    rule = "collapsible sections match their headers"

    headers, content = {}, {}
    for f in app_sources():
        body = strip_comments(f.read_text())
        for m in re.finditer(r'DiagnosticSectionHeader\((?:.|\n)*?key:\s*"([^"]+)"',
                             body):
            headers.setdefault(m.group(1), []).append(f.name)
        for m in re.finditer(r'isExpanded\("([^"]+)"\)', body):
            content.setdefault(m.group(1), []).append(f.name)

    if not counted(rule, len(headers), 20, "sections with a collapse key"):
        return
    counted(rule, sum(len(v) for v in content.values()), 40,
            "content and footer blocks keyed")

    for key, files in sorted(headers.items()):
        if len(files) > 1:
            fail(rule, f'two headers share the key "{key}" ({", ".join(files)}). '
                       "They will open and close together, which reads as a "
                       "SwiftUI bug rather than a typo. §12.137")
        if key not in content:
            fail(rule, f'the header "{key}" is checked by nothing. Its chevron '
                       "turns and no rows appear or disappear. §12.137")
    for key in sorted(content):
        if key not in headers:
            fail(rule, f'"{key}" is checked by a section body and declared by no '
                       "header, so that section can never be opened — it draws "
                       "a title that ignores taps. §12.137")

# --------------------------------------------------------------------------
# RULE 8 — patch 394, §12.138
# --------------------------------------------------------------------------

# The verbs that put memory back on disk. A `hydrate` is the one function in
# this codebase that must not use any of them.
PERSISTENCE_VERBS = ["dirty", "save(", "write(to:", "removeItem", "set("]

# THE COUNT MAY GO UP AND MUST NOT GO DOWN SILENTLY. A tenth store arriving
# without this rule seeing it is exactly the gap this number closes.
#
#   394: 9.  `DetailStore.hydrate` existed and fed the store from the launch.
#   395: 8.  It was removed. B4's measurement said the two largest families do
#            not belong in the launch bootstrap at all, so the store reads for
#            itself at construction and there is nothing to hand it. A method
#            written in anticipation is not a feature — `ProposalStore.remove`
#            waited 45 patches for a caller. §12.139.
#
# THE RULE CAUGHT THIS REMOVAL, which is the half that is easy to get wrong: a
# floor that only checks "at least N" reads a deletion as a pass.
HYDRATING_STORES = 8


def no_hydration_writes():
    """**HYDRATION MUST NEVER WRITE, AND NOTHING IN THE SUITE CAN SEE IT.**

    Every slice of D7 is reversible for one reason: the JSON file is still
    written and still complete, so deleting a family from `hydratedFamilies`
    puts the app back. That holds only while hydration is read-only. The day a
    `hydrate` marks its ids dirty, the next drain writes the DATABASE's
    reconstruction over the file it was reconstructed from, and the rollback
    becomes a data loss with no symptom until somebody rolls back.

    **AND THAT IS SHARPEST AT B4, WHICH IS WHY THIS RULE ARRIVES HERE.**
    `RecordingRepository.series` reads a NULL as zero and rebuilds every
    optional stream at `distanceM.count` (§12.38.4). A `DetailStore.hydrate`
    that dirtied its ids would write those lossy traces over 668 real ones —
    17.2 MB with no restore path, the largest single thing this app holds.

    **WHY A SOURCE RULE AND NOT A TEST.** `dirtyDetails` is private, `save()`
    is private, and the only caller of `save()` is behind a network drain. The
    seam `DetailStore(directory:)` cannot write at all, so a test driving it
    proves `mayWrite`, not this. The property is real, load-bearing, and
    unreachable from an assertion — which is RULE 7's situation exactly.
    """
    rule = "hydration never writes"

    seen = 0
    for f in app_sources():
        body = strip_comments(f.read_text())
        for m in re.finditer(r"\n\s*(?:@\w+\s+)*(?:static\s+)?func hydrate\b", body):
            fn = braced(body, body[m.start():m.end()])
            if fn is None:
                continue
            seen += 1
            for verb in PERSISTENCE_VERBS:
                if verb in fn:
                    fail(rule, f"{f.name}'s hydrate contains `{verb}`. A "
                               "hydration that persists writes the database's "
                               "own reconstruction over the file it came from, "
                               "and the slice stops being reversible with no "
                               "symptom until somebody reverses it. §12.138")

    counted(rule, seen, HYDRATING_STORES, "hydrations read for a write")
    if seen > HYDRATING_STORES:
        fail(rule, f"{seen} hydrations exist and this rule expects "
                   f"{HYDRATING_STORES}. Raise HYDRATING_STORES — the number is "
                   "here so a store added without a slice's argument is a "
                   "failure rather than a silent extra.")

# --------------------------------------------------------------------------
# RULE 9 — patch 396, §12.140
# --------------------------------------------------------------------------

# The file that owns "may this data leave the device". It may not branch on the
# build configuration, because the build configuration is not that question.
GATE_FILE = "ReleaseGates.swift"


def the_gate_does_not_branch_on_the_build():
    """**THE PREDICATE HAS ONE DEFINITION AND IT IS NOT `#if DEBUG`.**

    Patch 203 named this predicate `isInternalBuild` precisely so a bare
    `#if DEBUG` would not be repeated at each call site — and then `permitted`
    and `distributionLabel` kept their own copies anyway, in the same file, a
    few lines from the comment warning against exactly that. Three copies of
    one decision, one of them inside the sentence forbidding copies. §12.43.

    **AND THE PROXY WAS WRONG.** `#if DEBUG` asks *is this optimised*; the gate
    means *did this build reach a stranger*. The cost of the confusion was that
    every diagnostic screen disappeared in the only configuration that measures
    real performance, so no number this project has ever taken off the device
    was a Release number. B4 found it the hard way — patch 395's launch cost
    could not be read, because the button that reads it was gated on the
    optimiser.

    A rule rather than a test, for RULE 7's and RULE 8's reason: what must be
    prevented is a FOURTH copy appearing, and no assertion can see the absence
    of a preprocessor branch in a build where that branch is the one compiled.
    """
    rule = "the gate does not branch on the build"

    hits = [f for f in app_sources() if f.name == GATE_FILE]
    if len(hits) != 1:
        fail(rule, f"expected exactly one {GATE_FILE}, found {len(hits)}. "
                   "This rule is reading the wrong thing, which means it has "
                   "been checking nothing.")
        return

    body = strip_comments(hits[0].read_text())
    branches = body.count("#if ")
    counted(rule, 1, 1, f"{GATE_FILE} read for build-configuration branches")
    if branches:
        fail(rule, f"{GATE_FILE} contains {branches} `#if` branch(es). The "
                   "predicate has one definition — `BuildProvenance` — and a "
                   "compile-time copy beside it is how one call site ends up "
                   "on the wrong side of a configuration nobody was thinking "
                   "about. That has already happened three times in this "
                   "file. §12.140")

# --------------------------------------------------------------------------
# RULE 10 — patch 401, §12.145
# --------------------------------------------------------------------------

# The two folders the Xcode project synchronizes. Everything the app or its
# tests compile lives under one of them; a tracked `.swift` anywhere else is
# compiled by nothing and edited by somebody.
SOURCE_ROOTS = ("Sub4/", "Sub4CoreTests/")


def every_tracked_source_is_compiled():
    """**A SECOND COPY OF A FILE IS A COIN-FLIP ABOUT WHICH ONE YOU EDIT.**

    `DetailStore.swift` existed at the repository root AND at
    `Sub4/DetailStore.swift` — both tracked, byte-identical, 962 lines each,
    and the root one carrying every change up to patch 398 because `git add -A`
    swept it up all session. It was compiled by nothing: `project.pbxproj`
    synchronizes exactly two folders, and a target building both would fail on
    `invalid redeclaration of DetailStore` — the failure CLAUDE.md already
    records from Xcode's "Add Files" producing `Models 2.swift`.

    So the danger was never a broken build. It was an edit landing in the copy
    nothing reads, passing every test, and being discovered later as work that
    silently did not happen.

    **THE RULE IS GENERAL, NOT A NAME.** It does not know about
    `DetailStore.swift`; it says every tracked Swift file lives where the
    project compiles from. That holds for all 280-odd sources today with
    exactly one exception, which is the file this rule was written to remove.
    A rule spelling out the one filename would have prevented this duplicate
    and no other.

    Cheap, too: one `git ls-files`, no parsing, and it cannot go stale the way
    a hand-kept exemption list does — §12.117's whole argument.
    """
    rule = "every tracked source is compiled"

    try:
        listed = subprocess.run(["git", "ls-files", "*.swift"],
                                capture_output=True, text=True, check=True,
                                cwd=ROOT).stdout.split()
    except (OSError, subprocess.CalledProcessError) as e:
        # NOT SILENT. A rule that cannot run is a rule that is not checking,
        # and the one thing it must never do is look like a pass. §12.15.
        fail(rule, f"`git ls-files` did not run ({e}), so nothing was checked")
        return

    if not counted(rule, len(listed), 200, "tracked Swift files"):
        return
    for path in sorted(listed):
        if not path.startswith(SOURCE_ROOTS):
            fail(rule, f"{path} is tracked and lives outside "
                       f"{' and '.join(SOURCE_ROOTS)}, so the project compiles "
                       "no copy of it. An edit landing there passes every test "
                       "and silently did not happen. §12.145")

# --------------------------------------------------------------------------
# RULE 11 — patch 402, §12.146
# --------------------------------------------------------------------------


def every_restore_receipt_reaches_a_paste():
    """**A FIGURE THAT EXISTS ONLY ON SCREEN IS READ BY WHOEVER HELD THE PHONE.**

    On 17 August two exports of the authored read-back — one of them taken
    after pressing Restore — came back BYTE-IDENTICAL. The receipt lived in
    `@State` and rendered as a row, so the paste could not tell a restore that
    ran from a button nobody pressed.

    **AND THE WEATHER RESTORE HAD THE SAME HOLE SINCE 374.** Patch 391 was
    written to close exactly this class (§12.135) and swept the three
    read-backs and the write-through; the restore receipts were not looked at,
    and no `diagnosticLines` in the app mentioned one for twenty-seven patches.
    A recurrence is the bar this project sets for turning a lesson into code.

    So: **every receipt a view holds must be handed to `StoreRestore.lines`.**
    Counted rather than named, so a third restore added without a paste line
    fails here instead of being discovered by a device export somebody thought
    to take twice.

    A rule and not a test, for RULE 7's reason: both halves are SwiftUI view
    state and a `lines:` closure, and no assertion in the suite reaches either.
    """
    rule = "every restore receipt reaches a paste"

    held = 0
    printed = 0
    for f in app_sources():
        body = strip_comments(f.read_text())
        held += len(re.findall(r"@State[^\n]*:\s*\[?StoreRestore\.Receipt", body))
        printed += body.count("StoreRestore.lines(")

    if not counted(rule, held, 2, "restore receipts held in view state"):
        return
    counted(rule, printed, 2, "handed to the paste")
    if printed < held:
        fail(rule, f"{held} restore receipts are held in view state and only "
                   f"{printed} reach a paste. The one that does not is readable "
                   "by whoever is holding the phone and by nobody else — two "
                   "exports either side of it are identical. §12.146")

# --------------------------------------------------------------------------
# RULE 12 — patch 405, §12.149
# --------------------------------------------------------------------------

# What a restore may not do. `save()` announces; `noteAuthoredChange` IS the
# announcement. A restore writes through `write()` and stays silent.
RESTORE_MUST_NOT = ["noteAuthoredChange", "try save()"]

# Five restores at 407: weather, notes, commutes, moves and the match
# decisions. The rule said the fifth "must arrive under this rule, not beside
# it" and it did — 407 failed here before it could be committed, which is the
# whole reason the number is written down rather than inferred.
RESTORING_STORES = 5


def no_restore_announces() -> None:
    """**A REPAIR MUST NOT ARRIVE CARRYING PERMISSION TO DELETE.**

    `DatabaseWriteThrough.noteAuthoredChange` fires a whole-world import with
    `trigger == .authored`, and `.authored` sets `reconcile` — so an authored
    run may DELETE. Patches 400 and 404 built restores that called `save()`,
    which announces, so **pressing Restore fired a reconciling import once per
    store.** §12.144's own text claimed the opposite in the same tree.

    Nothing was harmed on 17 August because the restore added zero and the
    stores were unchanged, so the import found the same data and pruned
    nothing. The general case is the one this rule exists for: you press
    Restore BECAUSE a file is damaged, the import reconciles ALL authored
    families against ALL current stores, and a different family that happens to
    be truncated gets pruned to match. **The recovery operation destroys
    something it was never pointed at.**

    A rule and not a test, for RULE 8's reason: the call is one line inside a
    method whose only caller is a SwiftUI button, and a test that drove it
    would fire a real import. Reading the source is what is available.
    """
    rule = "no restore announces"

    seen = 0
    for f in app_sources():
        body = strip_comments(f.read_text())
        for m in re.finditer(r"\n\s*(?:@discardableResult\s*)?func restore\b", body):
            fn = braced(body, body[m.start():m.end()])
            if fn is None:
                continue
            seen += 1
            for verb in RESTORE_MUST_NOT:
                if verb in fn:
                    fail(rule, f"{f.name}'s restore contains `{verb}`. That "
                               "announces an authored change, which fires a "
                               "reconciling import — so a repair arrives "
                               "carrying permission to delete a family it was "
                               "never pointed at. Write through `write()`. "
                               "§12.149")

    counted(rule, seen, RESTORING_STORES, "restores read for an announcement")

    # **AND THE OTHER DIRECTION, WHICH IS HOW THIS PATCH NEARLY SHIPPED
    # BACKWARDS.** 405's first attempt replaced the wrong `try save()` in each
    # store: the ordinary MUTATORS went silent and the restores kept
    # announcing. The whole suite passed — nothing asserts that saving a note
    # catches the database up.
    #
    # `write()` has exactly two callers per store: `save()`, which announces
    # after it, and `restore()`, which does not. A third is a mutation that
    # stopped telling the database anything, which is the 348 defect returning
    # by the back door.
    silent = 0
    for f in app_sources():
        body = strip_comments(f.read_text())
        if not re.search(r"private func write\(\)(?: throws)? ", body):
            continue
        silent += 1
        # `try write()` in the file stores, bare `write()` in `Matcher`, whose
        # write RETURNS FALSE and never throws because `UserDefaults.set` has
        # nothing to report (§12.19). Counting only the throwing shape would
        # have left the one store this rule most needed to cover uncounted.
        calls = len(re.findall(r"(?:try )?write\(\)", body)) - 1

        # **THE PREMISE HELD AT 409, AND THE ATTEMPT TO MOVE IT WAS THE
        # DEFECT — §12.153.**
        #
        # Two callers is right because `save()` announces and `restore()` does
        # not, so a third caller is a mutation that has stopped telling the
        # database anything. 409 made `NotesStore` database-first and this rule
        # fired at three, and my first response was to widen the premise: a
        # store that commits directly, I argued, has earned a mirror that does
        # not announce.
        #
        # The argument was sound and the code did not need it. 409's mirror
        # calls `save()`, so the announcement is unchanged, the count is two,
        # and the patch claims only what it changed — the ORDER of the commit.
        # **A guard edited to admit the code it guards has stopped being a
        # guard**, and this one had already caught a backwards patch at 405 that
        # a green suite of 1,700 tests did not. §12.69.
        if calls != 2:
            fail(rule, f"{f.name} calls `write()` {calls} times and should call "
                       "it twice — from `save()` and `restore()`. A third "
                       "caller is a mutation that does not announce, so the "
                       "database stops being caught up and nothing says so. "
                       "If a store becomes database-first, its mirror still "
                       "goes through `save()`. §12.149, §12.153")
    counted(rule, silent, 4, "stores with a silent write path")
    if seen > RESTORING_STORES:
        fail(rule, f"{seen} restores exist and this rule expects "
                   f"{RESTORING_STORES}. Raise RESTORING_STORES — the number is "
                   "here so a fifth store arrives UNDER this rule rather than "
                   "beside it.")


# --------------------------------------------------------------------------
# RULE 13 — patch 409, §12.153.1
# --------------------------------------------------------------------------

# The seam-bearing stores. A file declaring `init(directory:)` offers callers
# an instance rooted somewhere other than the app's own container — which is
# what the tests, and three read-backs, are built on.
#
# **THE POPULATION IS EIGHT AND AT 409-411 THIS RULE THOUGHT IT WAS NINE.**
# `ReadBacks.swift` and `StoreReadJournal.swift` only ever MENTIONED
# `init(directory:)` in prose, and `Matcher` — which declares `init(defaults:)`
# — was not in it at all. So the rule was examining two files that offer no
# seam and ignoring one that does, which is §12.72.7 with the count that
# mattered: a grep counts appearances, not declarations.
#
# Eight, verified by declaration at 412: ActivityStore, CommuteStore,
# DetailStore, Matcher, NotesStore, PlanMoveStore, ProposalStore, Weather.
# It goes UP as stores gain seams, and DOWN only on purpose.
SEAM_STORE_FLOOR = 8


def braced_span(text, header, start=0):
    """`braced`, but returning positions rather than the substring — this rule
    has to ask WHERE something is, not only what it says."""
    i = text.find(header, start)
    if i < 0:
        return None
    j = text.find("{", i)
    if j < 0:
        return None
    depth, k = 0, j
    while k < len(text):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return (i, k + 1)
        k += 1
    return None


def _members(text):
    """Every member declaration and its braced span, at any indent.

    Deliberately crude — it wants the ENCLOSING declaration of a line, and for
    that a slightly generous match is safer than a precise one that misses a
    modifier nobody thought of."""
    out = []
    for m in re.finditer(r"^[ \t]*(?:@\w+\s+)*"
                         r"(?:(?:private|fileprivate|internal|public|nonisolated"
                         r"|static|final|@discardableResult|override|mutating)\s+)*"
                         r"(func|var|init|subscript)\s+([A-Za-z_]\w*)?",
                         text, re.M):
        span = braced_span(text, text[m.start():m.end()], m.start())
        if span and span[0] == m.start():
            out.append((m.group(2) or "init", m.start(), span[1]))
    return out


def a_seam_never_reaches_the_launchs_database():
    """**A STORE WITH A SEAM MUST NOT READ `Sub4Launch.shared` FROM ANYTHING A
    SEAM CAN CALL — patch 409, §12.153.1.**

    `init(directory:)` exists so an instance can be rooted somewhere harmless.
    409 made `NotesStore` commit to SQLite and resolved the database as
    `Sub4Launch.shared.database` **at the write** — so a store pointed at a
    temporary folder reached straight past it and wrote the athlete's notes
    into the app's own database. `DatabaseBootstrapTests` and
    `ImporterSeedTests` call `Sub4Launch.shared.begin()`, which opens that
    database for every test that runs after them, so the seam was not merely
    able to leak: it was leaking on every run.

    Two existing rollback tests caught it, for a reason neither was written
    for. **That is luck, and this rule is what replaces it** — the same first
    draft is waiting in the commutes, the match decisions and the plan moves,
    each of which 1B and 1C convert next.

    WHAT COUNTS AS SAFE, AND WHY IT IS A REACHABILITY QUESTION
    ----------------------------------------------------------
    Not "does the file mention the singleton" — `DetailStore` does, legally.
    Its `fill()` reads `Sub4Launch.shared.database` and is called from exactly
    one place, `private init()`, which no seam ever runs. The reference is
    unreachable from an instance a test can build, and that is the whole
    property. So a mention is allowed when it sits in:

      · **`private init()`** — the singleton's own construction, by definition
        not something a seam executes;
      · **a member whose every call site is inside `private init()`** —
        `DetailStore.fill()`, and the rule verifies the call sites rather than
        taking the author's word for it;
      · **a nested type** — `NotesStore.NoteDatabase`, whose `.live` reads the
        singleton only for the case the INITIALISER chose. The seam picks
        `.none` or `.given`, so the branch is unreachable from it. A value the
        initialiser selects is the fix shape, and it is the one to copy.

    Anything else is a member an instance can be asked to run, and a seam is an
    instance.

    ITS LIMIT, STATED: the call-site check is one level deep. A private helper
    called only from another private helper called only from `private init()`
    would be reported. That is a false positive this tree does not currently
    have, and the answer when it appears is to nest the value — not to deepen
    this."""
    rule = "a seam never reaches the launch's database"
    seams, mediated = 0, 0
    for f in app_sources():
        # **THE POPULATION IS WHAT A FILE DECLARES, NOT WHAT IT MENTIONS —
        # widened and corrected at 412.**
        #
        # This read the RAW text, so a file that merely named `init(directory:)`
        # in a doc comment joined the population — and `AuthoredDatabase.swift`,
        # whose entire job is to be the ONE place that resolves the singleton,
        # was failed by its own explanation of why the stores may not. Stripping
        # first is the same correction 372 made to §12.115.6: search for the
        # shape of the RISK, which is a declared seam, not for a string.
        #
        # **AND `init(defaults:)` IS A SEAM TOO.** `Matcher` is backed by
        # `UserDefaults` rather than a file and offers exactly the same escape
        # hatch, so the rule could not see the fifth store — §12.131.4's lesson,
        # a tripwire over a subset having no opinion about what is missing from
        # it. 412 inverts `Matcher`, which is when it started to matter.
        text = strip_comments(f.read_text())
        if "init(directory:" not in text and "init(defaults:" not in text:
            continue
        seams += 1
        if "Sub4Launch.shared" not in text:
            continue

        singleton = braced_span(text, "private init()")
        members = _members(text)

        # The nested types, whose bodies are reached only through a value the
        # initialiser chose.
        nested = [braced_span(text, m.group(0), m.start())
                  for m in re.finditer(r"^[ \t]{4,}(?:private\s+)?(?:nonisolated\s+)?"
                                       r"(?:enum|struct)\s+\w+", text, re.M)]
        nested = [n for n in nested if n]

        for hit in re.finditer(r"Sub4Launch\.shared", text):
            at = hit.start()
            if singleton and singleton[0] <= at < singleton[1]:
                mediated += 1
                continue
            if any(a <= at < b for a, b in nested):
                mediated += 1
                continue

            # The enclosing member, then its call sites.
            owner = None
            for name, a, b in members:
                if a <= at < b and (owner is None or a > owner[1]):
                    owner = (name, a, b)
            if owner:
                name, a, b = owner
                calls = [c.start() for c in re.finditer(re.escape(name) + r"\s*\(", text)
                         if not (a <= c.start() < b)]
                if calls and singleton and all(singleton[0] <= c < singleton[1]
                                               for c in calls):
                    mediated += 1
                    continue
            where = owner[0] if owner else "the file body"
            fail(rule,
                 f"{f.name} reads `Sub4Launch.shared` from `{where}`, which a "
                 "store built by `init(directory:)` can run. A seam rooted at a "
                 "temporary folder would reach past it into the app's own "
                 "database — 409 did exactly that, and two rollback tests "
                 "caught it by accident. Put the database behind a value the "
                 "INITIALISER chooses (`NotesStore.NoteDatabase`), or call it "
                 "only from `private init()` (`DetailStore.fill`). §12.153.1")

    counted(rule, seams, SEAM_STORE_FLOOR, "stores offering a directory seam")
    REPORT.append(f"  {rule}: {mediated} launch references behind an "
                  "initialiser's choice")


RULES = [
    a_seam_never_reaches_the_launchs_database,
    every_store_that_records_a_read_refuses_a_write,
    every_removal_counter_is_in_the_total,
    no_expect_message_is_a_concatenation,
    minutes_are_never_accumulated,
    pinned_counts_match_the_source,
    the_state_documents_name_the_current_patch,
    every_collapsible_section_matches_its_header,
    no_hydration_writes,
    the_gate_does_not_branch_on_the_build,
    every_tracked_source_is_compiled,
    every_restore_receipt_reaches_a_paste,
    no_restore_announces,
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
