//
//  DataLifecycle.swift
//  Sub4
//
//  Every category of data this app holds, as code — patch 180, plan step 2.1.
//
//  WHY THIS IS A TYPE AND NOT A DOCUMENT
//  ------------------------------------
//  A privacy policy in a text file drifts from the code the day after it is
//  written, and nothing fails when it does. `STRAVA-DATA-FLOW-INVENTORY.md` is
//  already the second inventory this project has produced by hand; the first
//  was the peer review's, and the two disagreed about `athlete.json` because
//  one of them was written a fortnight later.
//
//  Written as a type, the inventory can be asserted against. The tests beside
//  this file check that nothing carrying Strava lineage is marked shareable
//  with an AI provider, that every category names a deletion rule, and that
//  the categories cover every store the app actually writes. Those are the
//  claims the privacy pane makes, so those are the claims that should break a
//  build when they stop being true.
//
//  IT DESCRIBES WHAT THE APP DOES, NOT WHAT IT SHOULD DO
//  ----------------------------------------------------
//  This is the part that matters and the part that is tempting to get wrong.
//  Several categories below are handled worse than their stated policy — no
//  file protection is applied anywhere, `athlete.json` has no deletion path at
//  all, retention is indefinite where the Strava policy allows seven days.
//  Each of those is recorded in `gaps` rather than quietly omitted.
//
//  An inventory that listed the intended behaviour would be a more comfortable
//  document and a false one, and PRIV-01 is precisely the finding that the
//  app's disclosures do not match its behaviour. Writing the gap down is how
//  this file avoids becoming another instance of the thing it is fixing.
//

import Foundation

// MARK: - Where data comes from

/// Provenance. `lineage` is a SET because derived values inherit from every
/// input: the fitness curve is Strava-derived and Health-derived at once, and
/// the Strava restriction travels with it until it is rebuilt from a permitted
/// source alone. See ADR-0002 and plan step 2.1.11.
enum DataSource: String, CaseIterable, Codable, Hashable {
    case strava
    case appleHealth
    case authored          // the athlete typed it
    case bundled           // shipped inside the app
    case weatherProvider
    case device            // generated on this phone, e.g. diagnostics

    var label: String {
        switch self {
        case .strava:          "Strava"
        case .appleHealth:     "Apple Health"
        case .authored:        "You"
        case .bundled:         "Shipped with the app"
        case .weatherProvider: "Weather provider"
        case .device:          "This phone"
        }
    }
}

// MARK: - Where it rests

enum StorageLocation: Equatable {
    /// A file under Application Support, named.
    case applicationSupport(String)
    /// One or more UserDefaults keys.
    case preferences([String])
    /// A Keychain item, named.
    case keychain(String)
    /// Held only while the app runs; gone when it quits.
    case memoryOnly
    /// Inside the app bundle, read-only, replaced by an app update.
    case appBundle(String)
    /// Owned by the system, not by this app.
    case systemOwned(String)

    var label: String {
        switch self {
        case .applicationSupport(let f): "Application Support / \(f)"
        case .preferences(let keys):     "Preferences (\(keys.count) key\(keys.count == 1 ? "" : "s"))"
        case .keychain(let item):        "Keychain / \(item)"
        case .memoryOnly:                "Memory only"
        case .appBundle(let f):          "In the app / \(f)"
        case .systemOwned(let who):      "Held by \(who)"
        }
    }

    /// True where the app is the one that must delete it. The system-owned and
    /// bundled cases are not this app's to remove, and saying otherwise in a
    /// delete-my-data flow would be a promise it cannot keep.
    var isAppDeletable: Bool {
        switch self {
        case .applicationSupport, .preferences, .keychain: true
        case .memoryOnly, .appBundle, .systemOwned:        false
        }
    }
}

// MARK: - How long

enum Retention: Equatable {
    case indefinite
    case untilDisconnected(source: DataSource)
    case untilTheAppIsDeleted
    case forThisSessionOnly
    case days(Int)

    var label: String {
        switch self {
        case .indefinite:               "Kept until you delete it"
        case .untilDisconnected(let s): "Until you disconnect \(s.label)"
        case .untilTheAppIsDeleted:     "Until the app is removed"
        case .forThisSessionOnly:       "Discarded when the app quits"
        case .days(let n):              "\(n) days"
        }
    }
}

// MARK: - The categories

enum DataCategory: String, CaseIterable, Identifiable, Codable {
    case activitySummaries
    case routes
    case sensorStreams
    case healthMetrics
    case trainingLoad
    case sessionNotes
    case reviews
    case weather
    case athleteProfile
    case matchDecisions
    case trainingPlan
    case credentials
    case diagnostics

    var id: String { rawValue }
}

// MARK: - One category's whole story

struct DataCategoryEntry {
    let category: DataCategory
    let title: String
    /// Plain language, for a person deciding whether they are comfortable.
    let whatItIs: String
    let purpose: String
    let lineage: Set<DataSource>
    let storage: [StorageLocation]
    let retention: Retention
    /// Who else has seen it. Empty is the answer for most of these and is worth
    /// being able to state.
    let sharedWith: [String]
    /// Whether "Export my data" should include it. Secrets never are.
    let isExportable: Bool
    /// Whether this may be placed in a payload to an AI provider. Enforced by
    /// test: nothing with Strava lineage may set this true. See ADR-0002 §5.3.
    let aiShareable: Bool
    let deletionRule: String
    /// Where today's behaviour falls short of the policy above. Empty means the
    /// two agree. Every entry here should name the plan step that closes it.
    let gaps: [String]

    var isStravaDerived: Bool { lineage.contains(.strava) }
}

// MARK: - The inventory

enum DataLifecycle {

    /// Ordered by how much a reader would care, not alphabetically: the things
    /// a person would be uneasy about — where they were, their heart, what they
    /// wrote — come before configuration and diagnostics.
    static let entries: [DataCategoryEntry] = [

        DataCategoryEntry(
            category: .routes,
            title: "Routes",
            whatItIs: "The GPS track of every recorded outdoor session, and the "
                    + "coordinate each one started from, to about a metre.",
            purpose: "Drawing the map on an activity, playing a session back, "
                   + "and looking up the weather at the time and place it happened.",
            lineage: [.strava],
            storage: [.applicationSupport("streams/<activity>.json"),
                      .applicationSupport("details/<activity>.json"),
                      .applicationSupport("activities.json")],
            retention: .indefinite,
            sharedWith: ["Apple Weather and Open-Meteo receive the START coordinate "
                       + "and time of an activity — never the track"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["No file protection class is applied — the route history is "
                 + "readable on an unlocked-once device (DATA-05, step 2.1.9).",
                   "Retention is indefinite; the Strava API Policy permits seven "
                 + "days (ADR-0002, purge at 4A M8).",
                   "There is no consent screen before a coordinate reaches a "
                 + "weather provider; the release gate stands in for one "
                 + "(PRIV-04, step 2.4.5)."]),

        DataCategoryEntry(
            category: .sensorStreams,
            title: "Heart rate, pace and elevation traces",
            whatItIs: "About three hundred samples per session of heart rate, "
                    + "speed, altitude, gradient and — where a meter recorded "
                    + "it — power.",
            purpose: "The profile chart, time in heart-rate zone, interval "
                   + "detection, and the training-load figure for the session.",
            lineage: [.strava],
            storage: [.applicationSupport("streams/<activity>.json")],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["No file protection class is applied (DATA-05, step 2.1.9).",
                   "Retention is indefinite (ADR-0002)."]),

        DataCategoryEntry(
            category: .healthMetrics,
            title: "Apple Health readings",
            whatItIs: "Daily steps, walking and running distance, resting heart "
                    + "rate, workouts, swimming distance, heart rate — and "
                    + "cycling distance.",
            purpose: "Filling gaps Strava cannot: a session's heart rate when "
                   + "the recording has none, a swim's real duration, and the "
                   + "resting heart rate the training-load model needs.",
            lineage: [.appleHealth],
            storage: [.systemOwned("Apple Health"), .memoryOnly],
            retention: .forThisSessionOnly,
            sharedWith: [],
            isExportable: false,
            aiShareable: false,
            deletionRule: "Sub4 stores none of it. Revoke access in the Health app; "
                        + "nothing is left behind here to delete.",
            // Two of the three gaps recorded here in patch 180 were closed by
            // 181: cycling distance is now in the authorisation request, and a
            // failed query keeps the previous good series instead of replacing
            // it with an empty one. They are deleted rather than marked done —
            // this is an inventory of what is true now, and a list of fixed
            // things would grow forever and be read by nobody.
            //
            // The one that remains cannot be fixed from Swift: the purpose
            // string lives in the target's build settings, not in this project's
            // source, so it needs an edit in Xcode.
            gaps: ["The permission prompt describes step count alone, while seven "
                 + "types are read (PRIV-02, step 2.2.3). The text is in the "
                 + "target's build settings — INFOPLIST_KEY_NSHealthShareUsageDescription."]),

        DataCategoryEntry(
            category: .sessionNotes,
            title: "Your session notes",
            whatItIs: "What you wrote after a session: how hard it felt, how it "
                    + "compared to expectation, and anything you typed.",
            purpose: "Reading back what a week was actually like, rather than "
                   + "what the numbers say it was.",
            lineage: [.authored],
            storage: [.applicationSupport("notes.json")],
            retention: .indefinite,
            sharedWith: ["Anthropic, but only inside a review you run deliberately "
                       + "— and that path is switched off"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Yours. Survives disconnecting any source, and is removed "
                        + "only by Delete local data or by deleting the app.",
            gaps: ["A save can fail without saying so, and a decode failure reads "
                 + "as no notes at all (DATA-01, step 3.4.6).",
                   "Notes are included in the AI payload by default rather than "
                 + "by opt-in (PRIV-03, step 2.3.5)."]),

        DataCategoryEntry(
            category: .reviews,
            title: "Monthly reviews",
            whatItIs: "Each review you have run: the evidence it was given, the "
                    + "verdict it returned, and any changes it proposed.",
            purpose: "An audit trail — what the model was told, and what it said "
                   + "back, so a proposal can be judged later.",
            lineage: [.strava, .appleHealth, .authored],
            storage: [.applicationSupport("proposals.json")],
            retention: .indefinite,
            sharedWith: ["Anthropic received the evidence text when the review ran"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "One record at a time from the review list, or all of it "
                        + "by Delete local data.",
            gaps: ["The stored evidence embeds Strava-derived figures, so these "
                 + "records carry a restriction the rest of your history does "
                 + "not (ADR-0002 — purge the evidence, keep the verdict).",
                   "A save can fail silently (DATA-01, step 3.4.6)."]),

        DataCategoryEntry(
            category: .activitySummaries,
            title: "Activity summaries",
            whatItIs: "One row per recorded session: name, sport, when it "
                    + "started, distance, duration, climb, average and maximum "
                    + "heart rate, gear, and the device that recorded it.",
            purpose: "Matching what you did against what the plan asked for, and "
                   + "every total, trend and chart built on top of that.",
            lineage: [.strava],
            storage: [.applicationSupport("activities.json"),
                      .applicationSupport("details/<activity>.json")],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["No file protection class is applied (DATA-05, step 2.1.9).",
                   "Retention is indefinite (ADR-0002).",
                   "Rejected recordings leave a permanent note behind — date, "
                 + "name, distance, duration — that survives deleting the "
                 + "activity itself (`strava.rejectedByRule`, ADR-0002)."]),

        DataCategoryEntry(
            category: .trainingLoad,
            title: "Fitness, fatigue and freshness",
            whatItIs: "The training-load curve and everything read off it — CTL, "
                    + "ATL, TSB, monotony, time in zone.",
            purpose: "Answering whether you are building, holding or digging a "
                   + "hole, and whether tomorrow should be hard or easy.",
            lineage: [.strava, .appleHealth],
            storage: [.memoryOnly],
            retention: .forThisSessionOnly,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Nothing to delete — it is recomputed from the activities "
                        + "each time the app runs, and disappears with them.",
            gaps: ["Derived from Strava data, so the restriction travels with it "
                 + "even though no file holds it (ADR-0002, step 2.1.11)."]),

        DataCategoryEntry(
            category: .weather,
            title: "Weather for a session",
            whatItIs: "Temperature, apparent temperature, wind, humidity and "
                    + "rainfall for the hours a session covered.",
            purpose: "Reading a slow session correctly — 28° and a headwind is "
                   + "an explanation, not a decline in form.",
            lineage: [.weatherProvider, .strava],
            storage: [.applicationSupport("weather.json")],
            retention: .indefinite,
            sharedWith: ["Apple Weather, or Open-Meteo where Apple has no answer"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["No consent screen before the coordinate is sent (PRIV-04, "
                 + "step 2.4.5); the release gate stands in for one.",
                   "The store has a reset function with no caller, so this cache "
                 + "cannot be cleared from inside the app (step 2.1.6).",
                   "Rows are keyed by Strava activity id, so the key itself "
                 + "carries Strava lineage (ADR-0002 — re-key at 4A M4)."]),

        DataCategoryEntry(
            category: .athleteProfile,
            title: "Your profile and thresholds",
            whatItIs: "Heart-rate zones, functional threshold power, shoes and "
                    + "their mileage, maximum and resting heart rate.",
            purpose: "Every intensity judgement the app makes. Without these it "
                   + "can measure a session but not interpret it.",
            lineage: [.strava, .appleHealth, .authored],
            storage: [.applicationSupport("athlete.json"),
                      .applicationSupport("constants.json")],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["`athlete.json` has no deletion path anywhere in the app — it "
                 + "is overwritten on refresh and never removed (step 2.1.5).",
                   "`constants.json` stores the NAME of the activity where your "
                 + "maximum heart rate was seen, which is Strava data with no "
                 + "deletion path (ADR-0002)."]),

        DataCategoryEntry(
            category: .matchDecisions,
            title: "Your corrections",
            whatItIs: "Where you told the app that a particular recording was — "
                    + "or was not — the session the plan asked for.",
            purpose: "Overriding the matcher when it guesses wrong, and keeping "
                   + "that decision.",
            lineage: [.authored],
            storage: [.preferences(["match.overrides"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Yours. Survives disconnecting a source; the reference to "
                        + "the recording is remapped rather than dropped.",
            gaps: ["Stored against Strava activity ids, so the decisions must be "
                 + "remapped rather than lost when the source changes "
                 + "(ADR-0002, step 4A M4)."]),

        DataCategoryEntry(
            category: .trainingPlan,
            title: "The training plan",
            whatItIs: "The 34-week plan: weeks, sessions, prescriptions, fuelling "
                    + "and warm-ups.",
            purpose: "The thing everything else is measured against.",
            lineage: [.bundled],
            storage: [.appBundle("plan.json")],
            retention: .untilTheAppIsDeleted,
            sharedWith: ["Anthropic receives the plan's structure inside a review "
                       + "you run deliberately"],
            isExportable: true,
            aiShareable: true,
            deletionRule: "Part of the app. Replaced by an app update, removed by "
                        + "deleting the app.",
            gaps: []),

        DataCategoryEntry(
            category: .credentials,
            title: "Keys and tokens",
            whatItIs: "Your Strava application keys and sign-in tokens, and your "
                    + "Anthropic API key.",
            purpose: "Connecting to those services on your behalf.",
            lineage: [.authored],
            storage: [.keychain("strava.credentials"),
                      .keychain("strava.tokens"),
                      .keychain("claude.apiKey")],
            retention: .untilDisconnected(source: .strava),
            sharedWith: [],
            isExportable: false,
            aiShareable: false,
            deletionRule: "Never exported, and never included in a backup or a "
                        + "diagnostic. Removed on disconnect.",
            gaps: ["Disconnecting removes the tokens but not the application keys "
                 + "— there is no code path that deletes `strava.credentials` "
                 + "(step 4.2.9).",
                   "Keychain writes do not check their result, so a failure is "
                 + "reported to you as success (AUTH-03, step 4.2.10)."]),

        DataCategoryEntry(
            category: .diagnostics,
            title: "Diagnostics",
            whatItIs: "When the last background refresh ran, whether it worked, "
                    + "and which activities a source refused to hand over.",
            purpose: "Working out why something did not update, without guessing.",
            lineage: [.device],
            storage: [.preferences(["bg.lastRun", "bg.runCount", "bg.lastResult",
                                    "bg.scheduleError", "detail.failed",
                                    "detail.noStreams"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["`bg.lastResult` embeds counts and error text from Strava, so "
                 + "it inherits that lineage (ADR-0002)."])
    ]

    // MARK: Queries

    static func entry(_ c: DataCategory) -> DataCategoryEntry? {
        entries.first { $0.category == c }
    }

    /// Everything the Strava restriction travels with — raw and derived alike.
    /// This is the list ADR-0002's purge works from, and the reason `lineage`
    /// is a set rather than a single source.
    static var stravaDerived: [DataCategoryEntry] {
        entries.filter { $0.isStravaDerived }
    }

    /// What "Export my data" should contain.
    static var exportable: [DataCategoryEntry] {
        entries.filter(\.isExportable)
    }

    /// Everything this app is able to delete itself. Anything outside this list
    /// must be described to the reader as somebody else's to remove, rather
    /// than promised and quietly skipped.
    static var appDeletable: [DataCategoryEntry] {
        entries.filter { $0.storage.contains { $0.isAppDeletable } }
    }

    /// Every recorded difference between stated policy and actual behaviour.
    /// Non-empty today, and each line names the step that closes it.
    static var allGaps: [(DataCategory, String)] {
        entries.flatMap { e in e.gaps.map { (e.category, $0) } }
    }

    /// The single sentence the privacy pane opens with. Computed rather than
    /// written, so it cannot fall out of step with the table underneath it.
    static var summary: String {
        let shared = entries.filter { !$0.sharedWith.isEmpty }.count
        return "\(entries.count) kinds of data, \(shared) of which can reach "
             + "another company. Nothing leaves this phone while the transfers "
             + "above are switched off."
    }
}
