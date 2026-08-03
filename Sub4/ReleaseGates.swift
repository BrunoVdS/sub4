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
            "The coordinate it sends comes from Strava, and there is no consent "
            + "screen for it yet. Both are fixed in Phase 2."
        }
    }

    /// Whether this build is allowed to open the gate at all.
    ///
    /// Every gate is currently unresolved, so this is uniformly "internal only".
    /// It is written per-case rather than as one constant because they will not
    /// resolve together: `coordinateWeather` clears the moment Phase 2 ships its
    /// consent screen and the coordinate stops being Strava-sourced, while the
    /// Strava gates never clear — they are removed with the code at M8.
    var permitted: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The shipped default, applied when nothing has been stored.
    ///
    /// All false. `stravaSync` in particular: ADR-0002 decided that backfill
    /// stops and existing data is frozen rather than extended. Shipping it open
    /// would make the decision a comment.
    var defaultOpen: Bool { false }
}

// MARK: - The check

enum ReleaseGates {

    /// Closed unless this build permits the gate and it has been explicitly
    /// opened. Both halves are required; neither is inferable from the other.
    static func isOpen(_ gate: ReleaseGate) -> Bool {
        guard gate.permitted else { return false }
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

    #if DEBUG
    static let distributionLabel = "Internal build — switches are available."
    #else
    static let distributionLabel =
        "External build — every external data transfer is off and cannot be "
        + "switched on. See ADR-0002."
    #endif
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
