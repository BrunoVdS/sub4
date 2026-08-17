//
//  ReleaseGates.swift
//  Sub4
//
//  The switches that decide whether a piece of data may leave this device.
//  Patch 178 — remediation plan step 0.3.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The Strava API Policy effective 1 June 2026 has been in force since before
//  this was written. Read against the app as built, four of its clauses conflict
//  structurally rather than incidentally: a seven-day cache limit against a
//  thirteen-month history (§6.2), a bar on persistent archives of Strava Data
//  and of anything derived from it (§5.5), a bar on analytics over it (§5.4),
//  and a bar on using it in connection with the operation of any AI application
//  (§5.3). The reasoning and the classification are in ADR-0002; this file is
//  the mechanism.
//
//  THE ONE DESIGN DECISION THAT MATTERS
//  ------------------------------------
//  Gates are checked WHERE THE REQUEST IS BUILT, not where the button is.
//
//  A gate in the UI is a suggestion. It stops the path the author remembered
//  and leaves every other one: the background task, the queue drain that starts
//  itself after a sync, the diagnostic screen written six months later by
//  someone who never read this file. Step 0.3.5 requires that no diagnostic and
//  no deep link can bypass a switch, and the only way to actually get that is to
//  put the check on the far side of every caller — in the function that owns the
//  URLSession call. There is then no path to the network that does not pass a
//  gate, because the gate is the last thing before the wire.
//
//  FAIL CLOSED, AND WHAT THAT COSTS
//  --------------------------------
//  `isOpen` answers false unless the build permits the gate AND it has been
//  explicitly opened. Absent configuration, unreadable state, an unknown gate:
//  all closed. Step 0.3.4.
//
//  Closed gates THROW rather than returning empty. A silent no-op is
//  indistinguishable from "there were no new activities", and an app whose
//  stated promise is that it never presents an absence as a measurement cannot
//  have its compliance layer be the one thing that does.
//
//  WHO MAY OPEN WHAT — step 0.3.7
//  ------------------------------
//  Internal builds (DEBUG): the athlete, from Settings → Data and privacy. Each
//  switch states what it transmits and to whom before it can be moved.
//
//  External builds (RELEASE — TestFlight, App Store): nobody. `permitted`
//  returns false for every unresolved transfer and no stored preference is
//  consulted, so a value written while running internally cannot travel to an
//  external build in a backup and open a gate there.
//
//  To make a gate openable in an external build, three things must be true and
//  are checked at release review (step 9.3): the underlying conflict is resolved
//  in code, or written permission covering the exact use is archived; the
//  consent flow for it exists; and this file is edited in the same pull request
//  as the evidence.
//

import Foundation

// MARK: - The gates

enum ReleaseGate: String, CaseIterable, Identifiable {

    /// The OAuth flow. Distinct from `stravaSync` so an existing connection can
    /// be kept for revocation while all data fetching is off — you cannot
    /// revoke a token you have already thrown away.
    case stravaConnect

    /// Every read of activity data: the activity list, per-activity detail,
    /// streams, athlete zones, FTP and gear. One switch rather than five,
    /// because they are one decision.
    case stravaSync

    /// The two-hourly `be.sub4.refresh` task. Separate from `stravaSync`
    /// because unattended fetching is a different question from fetching: this
    /// one runs with nobody looking at the screen.
    case stravaBackground

    /// The monthly review — the outbound request to Anthropic.
    case aiReview

    /// Weather lookups, which send an activity's GPS start coordinate to four
    /// decimal places (~11 m) and its timestamp to a weather provider.
    case coordinateWeather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stravaConnect:     "Connect to Strava"
        case .stravaSync:        "Read activities from Strava"
        case .stravaBackground:  "Background refresh"
        case .aiReview:          "AI monthly review"
        case .coordinateWeather: "Weather for activities"
        }
    }

    /// What crosses the boundary, in the plainest words available. This is the
    /// text shown beside the switch: a control whose consequence is not stated
    /// is not a consent.
    var transmits: String {
        switch self {
        case .stravaConnect:
            "Opens strava.com to authorise Sub4. No activity data moves."
        case .stravaSync:
            "Downloads activity summaries, routes, GPS traces, heart rate and "
            + "power from Strava and stores them on this phone indefinitely."
        case .stravaBackground:
            "Does the same roughly every two hours while the app is closed."
        case .aiReview:
            "Sends training-load figures, weekly volume, measured paces and "
            + "your own session notes to Anthropic."
        case .coordinateWeather:
            "Sends where an activity started, to about 11 metres, and when, to "
            + "Apple Weather or Open-Meteo."
        }
    }

    /// Why it is shut. Not decoration — a switch that is off for a reason the
    /// reader cannot see reads as a bug and gets flipped back.
    var reasonClosed: String {
        switch self {
        case .stravaConnect, .stravaSync, .stravaBackground:
            "Strava's API Policy of 1 June 2026 limits caching to seven days "
            + "and bars analytics over its data. Sub4 keeps thirteen months and "
            + "is built on the analysis. See ADR-0002 — Apple Health replaces it."
        case .aiReview:
            "The review sends figures derived from Strava data to an AI "
            + "provider, which §5.3 and §5.10 of that policy prohibit. It stays "
            + "off until the review is rebuilt on Health-derived figures."
        case .coordinateWeather:
            // HALF OF THIS SENTENCE STOPPED BEING TRUE IN 193, and it took a
            // screenshot to notice. The consent screen now exists; the reader
            // sees it before this gate can open. What remains true is the
            // provenance: the coordinate is the start of a STRAVA activity, so
            // sending it is sending a Strava-derived value to a third party
            // until 4A rebuilds the source. A disclosure that keeps citing a
            // fixed problem trains people to disbelieve the ones still standing.
            "The coordinate is the start of a Strava activity, so switching this "
            + "on sends a Strava-derived value to a weather provider. Sub4 asks "
            + "before the first one leaves. Resolved at 4A, when activities come "
            + "from Apple Health instead."
        }
    }

    /// Whether this build is allowed to open the gate at all.
    ///
    /// Every gate is currently unresolved, so this is uniformly "internal only".
    /// It is written per-case rather than as one constant because they will not
    /// resolve together: `coordinateWeather` clears the moment Phase 2 ships its
    /// consent screen and the coordinate stops being Strava-sourced, while the
    /// Strava gates never clear — they are removed with the code at M8.
    var permitted: Bool { permitted(in: .current()) }

    /// The same question with the provenance handed in — patch 396, §12.140.
    ///
    /// **THIS PARAMETER IS THE WHOLE POINT OF 396.** While `permitted` was
    /// `#if DEBUG`, the Release branch did not exist in a test build, so
    /// nothing could assert what a distributed build does. `ReleaseGateTests`
    /// said `permittedIsFalseInRelease` covered it and **that test has never
    /// existed**; `PrivacyManifestTests` stated in two places that this exact
    /// property was invisible from a test and guarded only "by the comment in
    /// `ReleaseGates` and by review". Both are true statements about a gate
    /// nobody could check. Now they can.
    ///
    /// NO DEFAULT ARGUMENT. §12.95.4 — a default is a call site carrying a
    /// value the caller never writes, and this is the last value in the app
    /// that should be supplied by something nobody typed.
    func permitted(in provenance: BuildProvenance) -> Bool { provenance.isOwn }

    /// The shipped default, applied when nothing has been stored.
    ///
    /// All false. `stravaSync` in particular: ADR-0002 decided that backfill
    /// stops and existing data is frozen rather than extended. Shipping it open
    /// would make the decision a comment.
    var defaultOpen: Bool { false }

    /// Whether opening this gate needs a consent screen before the first
    /// transfer — PRIV-04, patch 193.
    ///
    /// A property of the GATE rather than a check in the view, so the answer
    /// travels with the thing it describes and a new transmitting gate has to
    /// decide. The test `everyGateThatSendsALocationAsksFirst` fails the build
    /// if a gate says it sends a coordinate and does not ask.
    var needsLocationConsent: Bool {
        switch self {
        case .coordinateWeather: true
        // The Strava gates send an authorisation request and fetch the
        // athlete's own recordings; nothing about where they are goes out that
        // they have not already given Strava. The AI review sends figures, and
        // its own consent problem is PRIV-03, handled by the payload preflight.
        case .stravaConnect, .stravaSync, .stravaBackground, .aiReview: false
        }
    }
}


// MARK: - Which build this is

/// **WHOSE BUILD IS THIS — patch 396, ADR-0003 §12.140 and ADR-0002.**
///
/// Until 396 the app answered this with `#if DEBUG`, which asks a different
/// question and gets the right answer only by coincidence. What the gates mean
/// is *did this build reach a stranger*, and the fact that settles that is how
/// it was SIGNED, not how it was optimised.
///
/// **THE TEST IS `embedded.mobileprovision`.** Development, ad-hoc and
/// enterprise builds carry one inside the bundle; App Store and TestFlight
/// builds have it stripped. So this is true for anything the athlete signed
/// himself in either configuration and false for anything distributed —
/// which is what the gate has always been for, and is if anything STRICTER
/// than the old rule, since a Debug build in somebody else's hands used to
/// open every switch.
///
/// A simulator is not signed at all, so it is named separately rather than
/// falling through to `.distributed`. A simulator build is by definition one
/// of the athlete's own, and the test suite runs there.
///
/// **PURE, AND THAT IS THE PATCH.** `of(hasEmbeddedProfile:isSimulator:)` takes
/// the two facts; `current()` is the one place that reads the real world. The
/// Release branch of this decision is now reachable from a test for the first
/// time — see `permitted(in:)`.
nonisolated enum BuildProvenance: Equatable, Sendable {
    /// Signed by the athlete, or a simulator. Diagnostics available, gates
    /// openable.
    case own
    /// No embedded profile: this build came through Apple. Every gate is shut
    /// and cannot be opened, whatever `UserDefaults` holds.
    case distributed

    var isOwn: Bool { self == .own }

    static func of(hasEmbeddedProfile: Bool, isSimulator: Bool) -> BuildProvenance {
        isSimulator || hasEmbeddedProfile ? .own : .distributed
    }

    /// The real world, read in exactly one place.
    ///
    /// `SIMULATOR_DEVICE_NAME` rather than `#if targetEnvironment(simulator)`:
    /// a compile-time branch here would put a second build-configuration
    /// decision back into this file, which is the defect 396 exists to remove.
    static func current() -> BuildProvenance {
        of(hasEmbeddedProfile: Bundle.main.url(forResource: "embedded",
                                               withExtension: "mobileprovision") != nil,
           isSimulator: ProcessInfo.processInfo
               .environment["SIMULATOR_DEVICE_NAME"] != nil)
    }
}

// MARK: - The check

enum ReleaseGates {

    /// Closed unless this build permits the gate and it has been explicitly
    /// opened. Both halves are required; neither is inferable from the other.
    static func isOpen(_ gate: ReleaseGate) -> Bool {
        isOpen(gate, in: .current())
    }

    /// The same answer with the provenance handed in — patch 396, §12.140.
    ///
    /// **THIS IS THE ONE ADR-0002 ACTUALLY RESTS ON**, and until 396 nothing
    /// asserted it: a distributed build must read every gate CLOSED even when
    /// `UserDefaults` holds `true` for it — a key restored from a backup taken
    /// on the athlete's own phone, which is not a hypothetical, because that is
    /// how these keys travel. `aDistributedBuildIgnoresAStoredOpenGate` is the
    /// test, and it could not have been written while this was `#if DEBUG`.
    static func isOpen(_ gate: ReleaseGate, in provenance: BuildProvenance) -> Bool {
        guard gate.permitted(in: provenance) else { return false }
        // Consent outranks the stored switch — patch 193. A `gate.` key
        // restored from a backup, or written before this check existed, cannot
        // open a transfer nobody agreed to. The consent key is in the same
        // backup, so the pair travels together or the gate stays shut.
        if gate.needsLocationConsent, !hasLocationConsent { return false }
        guard let stored = UserDefaults.standard.object(forKey: key(gate)) as? Bool
        else { return gate.defaultOpen }
        return stored
    }

    /// Throws unless the gate is open. The form every network boundary uses, so
    /// the refusal reaches the caller as an error rather than as an empty result.
    static func require(_ gate: ReleaseGate) throws {
        guard isOpen(gate) else { throw GateError(gate: gate) }
    }

    /// No-op in an external build, by design: `permitted` is consulted first, so
    /// a value cannot be written for a gate this build may not open, and a value
    /// restored from an internal build's backup cannot open one either.
    static func set(_ gate: ReleaseGate, open: Bool) {
        guard gate.permitted else { return }
        UserDefaults.standard.set(open, forKey: key(gate))
    }

    static func key(_ gate: ReleaseGate) -> String { "gate." + gate.rawValue }

    /// Whether the athlete has agreed to a coordinate leaving the phone.
    ///
    /// SEPARATE FROM THE GATE, deliberately. The gate is "is this feature on";
    /// this is "did somebody agree to the transfer". Switching weather off and
    /// on again should not re-ask — the answer has not changed — but a delete
    /// removes this key along with everything else in `appSettings`, so a fresh
    /// install or a wiped one asks again. That is the right behaviour: consent
    /// belongs to the person, and there is no longer a record of it.
    static let locationConsentKey = "consent.locationToWeather"

    static var hasLocationConsent: Bool {
        UserDefaults.standard.bool(forKey: locationConsentKey)
    }

    static func recordLocationConsent() {
        UserDefaults.standard.set(true, forKey: locationConsentKey)
    }

    /// For the Settings header and the support bundle.
    ///
    /// `{ isOpen($0) }` and not `isOpen` — patch 179, and the third time this
    /// project has paid for the same lesson (see the note in
    /// `ActivityStore.load`). This target's default isolation is MainActor, so
    /// `isOpen` is MainActor-isolated; handing it to `filter` as a function
    /// VALUE strips that isolation and earns "call to main actor-isolated
    /// static method in a synchronous nonisolated context". A closure literal
    /// inherits the isolation of the scope it is written in, so the identical
    /// call is fine spelled out.
    static var openGates: [ReleaseGate] { ReleaseGate.allCases.filter { isOpen($0) } }

    static var summary: String {
        let open = openGates
        if open.isEmpty { return "All external data transfers are off." }
        return open.map(\.title).joined(separator: ", ")
    }

    /// Whether this build is one of the athlete's own.
    ///
    /// **PATCH 203 NAMED THIS PREDICATE AND TWO OF ITS THREE COPIES KEPT
    /// THEIR OWN `#if DEBUG` ANYWAY.** The doc that used to sit here said a
    /// bare `#if DEBUG` repeated at each call site is how one of them ends up
    /// on the wrong side of a build configuration nobody was thinking about —
    /// and `permitted` and `distributionLabel` were exactly that, in the file
    /// that said it. §12.43, three copies, one of them in the sentence warning
    /// against copies.
    ///
    /// **AND THE PREDICATE WAS WRONG, not just duplicated — §12.140.** It
    /// answered *is this the Debug configuration*, which is not the question.
    /// The question is *is this one of the athlete's own builds*, and the
    /// consequence of the proxy was that every diagnostic screen in this app
    /// vanished in the only configuration that measures real performance. B4
    /// found it: 395's launch cost could not be read in Release because the
    /// button that reads it was gated on the optimiser.
    static var isInternalBuild: Bool { BuildProvenance.current().isOwn }

    /// DERIVED, NEVER ITS OWN BRANCH — patch 396. The third copy of the
    /// predicate lived here, and a label that can disagree with the behaviour
    /// it describes is worse than no label: a Release build on the athlete's
    /// own phone would have read "every external data transfer is off and
    /// cannot be switched on" while the switches were in fact available.
    /// §12.15, in the one sentence the app says about its own permissions.
    static var distributionLabel: String {
        isInternalBuild
            ? "Internal build — switches are available."
            : "External build — every external data transfer is off and cannot "
            + "be switched on. See ADR-0002."
    }
}

// MARK: - The refusal

/// Carries the gate, so a caller can explain the refusal rather than reporting
/// a generic failure. `LocalizedError` because these surface in Settings and in
/// the sync error line, which are read by someone deciding whether the app is
/// broken.
struct GateError: LocalizedError {
    let gate: ReleaseGate

    var errorDescription: String? { "\(gate.title) is switched off." }
    var failureReason: String? { gate.reasonClosed }
    var recoverySuggestion: String? {
        gate.permitted
            ? "Settings → Data and privacy, if you accept what it sends."
            : "This build cannot switch it on."
    }

    /// True when the refusal is the policy position rather than a fault, so a
    /// caller can stay quiet instead of raising an alarm about a deliberate
    /// state. A closed gate is not an outage.
    var isDeliberate: Bool { true }
}
