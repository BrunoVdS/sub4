#!/usr/bin/env python3
"""
Patch 288 — the banner that asks you to re-grant named the wrong types.

§12.33.5 asked whether `authVersion` has an actuator. It does, and it is
manual: Settings shows a banner and an "Ask for the new Health types" button
when the stored version is behind. That is what got workout routes granted.

Reading it turned up the defect. The banner says:

    "the app now also reads workouts and swim distance"

True at `authVersion` 3. Stale by three additions — heart rate at 4, cycling
distance at 5, workout routes at 6. A person tapping that button was told the
wrong reason for tapping it, in the sentence whose only job is to give them a
reason.

And the property gating it is still called `needsRestingHRGrant`, from when it
was about resting heart rate alone.

THE FIX IS THE SHAPE, NOT THE WORDS. `newTypesMessage` renders
`typesReadDescribed` — the list the authorisation request is actually built
from, already pinned by `descriptionMatchesTheRequest`. Same answer as
`DataLifecycle.summary`: compute the sentence from the data so it cannot fall
out of step with it.

YOU CANNOT SEE THIS ON THE DEVICE RIGHT NOW, and that is worth knowing before
you look. The banner appears only while the stored version is behind the
current one, and you granted version 6 an hour ago — so it is correctly
hidden. The test is the verification; the banner is next seen when a ninth
type is added, which is exactly when nobody will re-read it.

No new files, so no ⌘Q.

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


H = "Sub4/HealthStore.swift"
S = "Sub4/SettingsView.swift"
T = "Sub4CoreTests/HealthTypeTests.swift"

# ---------------------------------------------- the property, renamed and true

edit(
    H,
    r'''    /// True while resting heart rate is not arriving — never asked for, asked
    /// and denied, or granted with no data in the window. HealthKit cannot tell
    /// the three apart. Steps keep working meanwhile; this only gates the
    /// prompt.
    var needsRestingHRGrant: Bool {
        hasRequestedAuthorization
            && UserDefaults.standard.integer(forKey: Self.authVersionKey) < Self.authVersion
    }''',
    r'''    /// True when this app reads more Health types than this install has ever
    /// been asked about — patch 288.
    ///
    /// RENAMED FROM `needsRestingHRGrant`, and the old name is the finding.
    /// It was written when the only new type was resting heart rate, and its
    /// comment described that one case; four type additions later it was
    /// gating a general "the request has grown" prompt under a name and a
    /// description that both said something else.
    ///
    /// THIS IS THE ONLY ACTUATOR `authVersion` HAS, and it is a person tapping
    /// a button. Nothing re-requests on its own — deliberately, because
    /// prompting at launch is intrusive — which means a newly added type is
    /// unread until somebody opens Settings and taps. For a diagnostic that is
    /// fine. For a type the app depends on it is HK-02's shape again, and
    /// §12.32.3's guard is what catches it rather than this.
    var needsNewTypeGrant: Bool {
        hasRequestedAuthorization
            && UserDefaults.standard.integer(forKey: Self.authVersionKey) < Self.authVersion
    }

    /// What the banner says, COMPUTED rather than written — patch 288.
    ///
    /// It used to read "the app now also reads workouts and swim distance",
    /// which was true at `authVersion` 3 and stale by three additions: heart
    /// rate at 4, cycling distance at 5, workout routes at 6. Somebody tapping
    /// the button was told the wrong reason for tapping it, in the sentence
    /// whose only job is to give them one.
    ///
    /// The fix is a shape rather than better words. This renders
    /// `typesReadDescribed`, which is the list the authorisation request is
    /// built from and is already held to it by `descriptionMatchesTheRequest`.
    /// Same answer as `DataLifecycle.summary`: a sentence computed from the
    /// data cannot fall out of step with the data.
    static var newTypesMessage: String {
        "Health access needs asking again. This app reads "
        + "\(typesReadDescribed.count) kinds of Health data — "
        + typesReadDescribed.joined(separator: ", ").lowercased()
        + " — and iOS only prompts for types it has never been asked about. It "
        + "never says whether a read was denied or simply never requested, so "
        + "try the button; if something stays empty, check Settings → Privacy "
        + "& Security → Health → Sub4. Steps are unaffected either way."
    }''',
    "the property is renamed and the message is computed",
)

# ------------------------------------------------------------ the banner

edit(
    S,
    r'''        if health.needsRestingHRGrant {
            Text("Health access needs asking again — the app now also reads "
                 + "workouts and swim distance, and iOS only prompts for types "
                 + "it has never asked about. It never says whether a read was "
                 + "denied or simply never requested, so try the button; if "
                 + "something stays empty, check Settings → Privacy & Security "
                 + "→ Health → Sub4. Steps are unaffected either way.")
                .font(.caption).foregroundStyle(.orange)
            Button("Ask for the new Health types") {
                Task { await health.requestAuthorization() }
            }
        }''',
    r'''        // PATCH 288. The sentence is `HealthStore.newTypesMessage` now, built
        // from `typesReadDescribed` rather than written here — the version
        // written here named two types and was three additions out of date.
        if health.needsNewTypeGrant {
            Text(HealthStore.newTypesMessage)
                .font(.caption).foregroundStyle(.orange)
            Button("Ask for the new Health types") {
                Task { await health.requestAuthorization() }
            }
        }''',
    "the banner reads the computed message",
)

# ---------------------------------------------------------------------- tests

edit(
    T,
    r'''    // MARK: The status model''',
    r'''    // MARK: The re-ask banner — 288

    /// THE STRUCTURAL PIN. The banner named two types while eight were
    /// requested, and nothing could have noticed: it is prose in a `View`,
    /// read by a person once every few months at the exact moment they are not
    /// checking it against a list.
    ///
    /// Asserting that every described type appears is trivially true while the
    /// message renders the list — which is the point. It stops being true the
    /// moment somebody replaces the rendering with a sentence, and that is the
    /// failure being prevented.
    @Test("The re-ask banner names every type the app reads")
    func theBannerNamesEveryTypeRead() {
        let message = HealthStore.newTypesMessage
        for described in HealthStore.typesReadDescribed {
            #expect(message.localizedCaseInsensitiveContains(described),
                    "the banner does not mention \(described), but it is requested")
        }
    }

    @Test("The banner counts what it lists")
    func theBannerCountsWhatItLists() {
        let n = HealthStore.typesReadDescribed.count
        #expect(HealthStore.newTypesMessage.contains("\(n) kinds"))
    }

    /// The old text is pinned as ABSENT rather than the new text as present.
    /// "workouts and swim distance" was accurate once; what makes it wrong is
    /// that it is a fixed list, and a test that allowed a different fixed list
    /// would be guarding the wrong thing.
    @Test("The banner does not carry a hand-written list of types")
    func theBannerDoesNotHardCodeTypes() {
        #expect(!HealthStore.newTypesMessage
                    .localizedCaseInsensitiveContains("now also reads"),
                "the banner is computed from typesReadDescribed — see ADR-0003 §12.34")
    }

    // MARK: The status model''',
    "the banner tests",
)

# ------------------------------------------------------------------------ ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.34 The banner named the wrong types — patch 288

### 12.34.1 §12.33.5, answered

`authVersion` does have an actuator, and it is a person. Settings shows a
banner with an *"Ask for the new Health types"* button whenever the stored
version is behind the current one, and that is how workout routes were granted
after 286 bumped it to 6.

Nothing re-requests automatically. That is a defensible choice — prompting at
launch is intrusive — but it means a newly added type stays unread until
somebody opens Settings and taps. **For a type the app merely diagnoses with,
that is fine. For one it depends on, it is HK-02's shape again**, and what
catches it is §12.32.3's before-the-query guard rather than this banner.

### 12.34.2 The defect the reading turned up

The banner said:

> *"Health access needs asking again — the app now also reads **workouts and
> swim distance**…"*

True at `authVersion` 3. Stale by three additions: heart rate at 4, cycling
distance at 5, workout routes at 6. **Somebody tapping that button was told
the wrong reason for tapping it**, in the sentence whose only job is to give
them a reason.

And the property gating it was still `needsRestingHRGrant`, named when the
only new type was resting heart rate, with a doc comment describing that one
case while it gated a general "the request has grown" prompt.

Neither was load-bearing. Both are the same failure as §12.27: **a statement
that was true when written and became false while nobody was reading it.**
This one had less protection than most, because it is prose inside a `View`,
seen once every few months by a person who is not checking it against a list.

### 12.34.3 The fix is a shape

`HealthStore.newTypesMessage` renders `typesReadDescribed` — the list the
authorisation request is built from, already held to `typesRead` by
`descriptionMatchesTheRequest`. The same answer as `DataLifecycle.summary`:
*"computed rather than written, so it cannot fall out of step with the table
underneath it."*

The test pins the absence of a hand-written list rather than the presence of
the right one. "Workouts and swim distance" was accurate once; what makes it
wrong is that it is a fixed list at all, and a test approving a different fixed
list would guard the wrong thing.

### 12.34.4 It cannot be verified on the device today

The banner shows only while the stored version is behind the current one, and
version 6 was granted an hour before this patch — so it is correctly hidden,
and there is nothing to look at. **The test is the verification.** The banner
is next seen when a ninth type is added, which is precisely the moment nobody
will re-read it.

Recorded rather than glossed, because "verified on device" has meant something
specific in this project for eighty patches, and this is a patch where it
cannot mean it.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.34",
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
