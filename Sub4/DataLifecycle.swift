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

/// Something this app owns under Application Support.
///
/// WHY THIS EXISTS RATHER THAN A STRING
/// ------------------------------------
/// Until patch 183 a location was `"streams/<activity>.json"` — fine for a
/// privacy pane to print, useless to anything that has to delete it. The
/// coordinator needed real URLs, and the alternative was a second list mapping
/// category to path, which is exactly the drift this whole file exists to stop.
/// So the inventory resolves itself, and the sentence shown to the reader and
/// the file that actually gets unlinked come from the same value.
enum AppSupportItem: Equatable, Hashable {
    /// One named file: `activities.json`.
    case file(String)
    /// A directory holding one file per activity: `streams`, `details`.
    case directory(String)
    /// Written by an older version of the app and no longer read.
    ///
    /// Listed because it is still on disk and still the user's. A delete flow
    /// that skips these is wrong in the direction that matters — `details.json`
    /// and `streams.json` hold the full history of every device that upgraded
    /// through the per-activity split, and nothing has ever removed them.
    case legacyFile(String)
    /// A directory holding a SQLite database and the journal files SQLite
    /// writes beside it.
    ///
    /// WHY A DIRECTORY AND NOT `.file("sub4.sqlite")` — patch 195. SQLite does
    /// not write one file. Depending on journal mode it also writes `-journal`,
    /// `-wal` and `-shm`, it creates them itself, and they hold the same rows
    /// as the database. Naming only the `.sqlite` would give this inventory a
    /// delete that leaves the user's data in a file the receipt never mentions
    /// — the same failure as `details.json`, which outlived four versions of
    /// this app because nothing listed it.
    ///
    /// A directory removes the whole set in one call and cannot leave a
    /// sidecar behind, and the protection class set on it is inherited by
    /// everything SQLite creates inside.
    case databaseDirectory(String)

    var displayName: String {
        switch self {
        case .file(let f):       f
        case .directory(let d):  "\(d)/<activity>.json"
        case .legacyFile(let f): "\(f) — written by an older version"
        case .databaseDirectory(let d): "\(d)/ — the database and its journal files"
        }
    }

    /// The name the store itself uses. `displayName` is prose; this is the
    /// thing on disk, and the two must not be confused when matching.
    var pathComponent: String {
        switch self {
        case .file(let f):       f
        case .directory(let d):  d
        case .legacyFile(let f): f
        case .databaseDirectory(let d): d
        }
    }

    var isDirectory: Bool {
        switch self {
        case .directory, .databaseDirectory: true
        case .file, .legacyFile:             false
        }
    }

    /// Application Support for this app, or nil if the system will not give it
    /// to us. Nil is a real answer — every caller must handle it rather than
    /// force-unwrapping and crashing a delete flow.
    nonisolated static var container: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false)
    }

    var url: URL? {
        guard let base = Self.container else { return nil }
        return base.appendingPathComponent(pathComponent, isDirectory: isDirectory)
    }
}

enum StorageLocation: Equatable {
    /// A file or directory under Application Support.
    case applicationSupport(AppSupportItem)
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
        case .applicationSupport(let i): "Application Support / \(i.displayName)"
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

// MARK: - What a disconnect does

/// What disconnecting Strava does to one category.
///
/// WHY THIS IS DECLARED AND NOT WRITTEN AS CODE
/// -------------------------------------------
/// Three entries below have said "Removed with the Strava disconnect" since
/// patch 180, while `StravaAuth.disconnect()` deleted the sign-in tokens and
/// nothing else. That is the same shape of finding as "Delete local data" was
/// before 183 — a sentence describing a feature rather than a behaviour.
///
/// The fix is not a function that deletes four files. Disconnect is not a
/// smaller delete: it has to remove what came from Strava and keep what you
/// wrote, and those two live in the same file in one case. Declaring the rule
/// beside the disclosure is what stops the two drifting, and lets the pane show
/// a person exactly what disconnecting will cost them BEFORE they tap it.
///
/// NAMED FOR STRAVA DELIBERATELY. Strava is the only source that can be
/// disconnected today; Health is revoked in Apple's own Settings and the plan
/// is part of the app. A general `disconnect(source:)` would be generality
/// nobody has asked for, and the day a second source arrives, renaming this is
/// a change the compiler walks you through rather than one that fails quietly.
enum DisconnectRule: Equatable {

    /// Every location this category names is removed.
    case removeEverything

    /// Untouched, and the reason is shown to the reader rather than assumed.
    case keep(why: String)

    /// Some of it goes.
    ///
    /// `clearsFields` names fields INSIDE a file that survives, which no generic
    /// walker can do — a handler in the coordinator does it, and a test pins
    /// every named field to a category that has one. The names are also what the
    /// pane shows, so the reader sees `hrMaxObserved` rather than "some data".
    case partial(keeps: String,
                 removesFiles: [AppSupportItem],
                 removesKeychain: [String],
                 clearsFields: [String])

    /// One line for the privacy pane.
    var label: String {
        switch self {
        case .removeEverything:
            "Removed when you disconnect Strava"
        case .keep(let why):
            "Kept — \(why)"
        case .partial(let keeps, _, _, let fields):
            fields.isEmpty
                ? "Partly removed. Kept: \(keeps)"
                : "Partly removed — \(fields.joined(separator: ", ")) cleared. Kept: \(keeps)"
        }
    }

    var removesAnything: Bool {
        switch self {
        case .removeEverything: true
        case .keep:             false
        case .partial(_, let f, let k, let c): !(f.isEmpty && k.isEmpty && c.isEmpty)
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
    /// Added in 195, when `Sub4Database` gave the app somewhere to put a
    /// SQLite file. Declared before it holds anything, on purpose: the
    /// alternative is a window in which the database exists on disk and
    /// "Delete local data" walks past it.
    case database
    case diagnostics
    /// Added in 183. Not a discovery of new data — a discovery that data
    /// already being written was undeclared. The inventory named seven
    /// preference keys; the app writes twenty-four, and the seventeen missing
    /// ones would have survived a delete-my-data flow written against it.
    case appSettings

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
    /// LAST, and it has to stay last. This struct is built through its
    /// memberwise initialiser at fourteen call sites, which pass arguments in
    /// declaration order; a new property inserted anywhere but the end silently
    /// shifts every one of them. That has cost this project three builds, and
    /// the diagnostic it produces reads "unable to type-check this expression
    /// in reasonable time", which points nowhere near the cause.
    let onStravaDisconnect: DisconnectRule

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
            storage: [.applicationSupport(.directory("streams")),
                      .applicationSupport(.directory("details")),
                      .applicationSupport(.file("activities.json"))],
            retention: .indefinite,
            sharedWith: ["Apple Weather and Open-Meteo receive the START coordinate "
                       + "and time of an activity — never the track"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["Retention is indefinite; the Strava API Policy permits seven "
                 + "days (ADR-0002, purge at 4A M8)."],
            onStravaDisconnect: .removeEverything),

        DataCategoryEntry(
            category: .sensorStreams,
            title: "Heart rate, pace and elevation traces",
            whatItIs: "About three hundred samples per session of heart rate, "
                    + "speed, altitude, gradient and — where a meter recorded "
                    + "it — power.",
            purpose: "The profile chart, time in heart-rate zone, interval "
                   + "detection, and the training-load figure for the session.",
            lineage: [.strava],
            storage: [.applicationSupport(.directory("streams")),
                      .applicationSupport(.legacyFile("streams.json")),
                      .preferences(["streams.schema"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["Retention is indefinite (ADR-0002)."],
            onStravaDisconnect: .removeEverything),

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
            storage: [.systemOwned("Apple Health"), .memoryOnly,
                      .preferences(["health.authVersion", "health.authorized"])],
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
            // The last one closed in 182. The purpose string named step count
            // alone while seven types were read, which is PRIV-02 in miniature:
            // a disclosure that did not match behaviour. It is a build setting
            // rather than source, so nothing in this file could have caught it
            // drifting again — `usageDescriptionNamesEveryTypeRead` in
            // HealthTypeTests reads the string back out of the built product and
            // holds it to `typesRead`. That test is what replaces this line.
            gaps: [],
            onStravaDisconnect: .keep(why: "it comes from Apple Health, which is a separate permission you revoke in the Health app")),

        DataCategoryEntry(
            category: .sessionNotes,
            title: "Your session notes",
            whatItIs: "What you wrote after a session: how hard it felt, how it "
                    + "compared to expectation, and anything you typed.",
            purpose: "Reading back what a week was actually like, rather than "
                   + "what the numbers say it was.",
            lineage: [.authored],
            storage: [.applicationSupport(.file("notes.json")),
                      .preferences(["notes.schema"])],
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
                 + "by opt-in (PRIV-03, step 2.3.5)."],
            onStravaDisconnect: .keep(why: "you wrote it")),

        DataCategoryEntry(
            category: .reviews,
            title: "Monthly reviews",
            whatItIs: "Each review you have run: the evidence it was given, the "
                    + "verdict it returned, and any changes it proposed.",
            purpose: "An audit trail — what the model was told, and what it said "
                   + "back, so a proposal can be judged later.",
            lineage: [.strava, .appleHealth, .authored],
            storage: [.applicationSupport(.file("proposals.json")),
                      .preferences(["proposals.schema"])],
            retention: .indefinite,
            sharedWith: ["Anthropic received the evidence text when the review ran"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "One record at a time from the review list, or all of it "
                        + "by Delete local data.",
            gaps: ["The stored evidence embeds Strava-derived figures, so these "
                 + "records carry a restriction the rest of your history does "
                 + "not (ADR-0002 — purge the evidence, keep the verdict).",
                   "A save can fail silently (DATA-01, step 3.4.6)."],
            onStravaDisconnect: .keep(why: "the verdicts are yours. The evidence quoted inside them is Strava-derived and is purged separately at 4A M6 — recorded as a gap above")),

        DataCategoryEntry(
            category: .activitySummaries,
            title: "Activity summaries",
            whatItIs: "One row per recorded session: name, sport, when it "
                    + "started, distance, duration, climb, average and maximum "
                    + "heart rate, gear, and the device that recorded it.",
            purpose: "Matching what you did against what the plan asked for, and "
                   + "every total, trend and chart built on top of that.",
            lineage: [.strava],
            storage: [.applicationSupport(.file("activities.json")),
                      .applicationSupport(.directory("details")),
                      .applicationSupport(.legacyFile("details.json")),
                      // The sync bookkeeping. `strava.rejectedByRule` is the
                      // one that matters: it keeps date, name, distance and
                      // duration of recordings the app declined, and outlives
                      // the activity it describes.
                      .preferences(["strava.cursor", "strava.lastSync",
                                    "strava.cutoffUsed", "strava.rejectedByRule",
                                    "strava.geoBackfill", "strava.powerBackfill",
                                    "strava.speedBackfill", "strava.zoneBackfill"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed with the Strava disconnect, and by Delete local data.",
            gaps: ["Retention is indefinite (ADR-0002).",
                   "Rejected recordings leave a permanent note behind — date, "
                 + "name, distance, duration — that survives deleting the "
                 + "activity itself (`strava.rejectedByRule`, ADR-0002)."],
            onStravaDisconnect: .removeEverything),

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
                 + "even though no file holds it (ADR-0002, step 2.1.11)."],
            onStravaDisconnect: .keep(why: "nothing is stored. It is recomputed from whatever activities remain, which after a disconnect is none")),

        DataCategoryEntry(
            category: .weather,
            title: "Weather for a session",
            whatItIs: "Temperature, apparent temperature, wind, humidity and "
                    + "rainfall for the hours a session covered.",
            purpose: "Reading a slow session correctly — 28° and a headwind is "
                   + "an explanation, not a decline in form.",
            lineage: [.weatherProvider, .strava],
            storage: [.applicationSupport(.file("weather.json")),
                      .preferences(["weather.unavailable"])],
            retention: .indefinite,
            sharedWith: ["Apple Weather, or Open-Meteo where Apple has no answer"],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["Rows are keyed by Strava activity id, so the key itself "
                 + "carries Strava lineage (ADR-0002 — re-key at 4A M4)."],
            onStravaDisconnect: .removeEverything),

        DataCategoryEntry(
            category: .athleteProfile,
            title: "Your profile and thresholds",
            whatItIs: "Heart-rate zones, functional threshold power, shoes and "
                    + "their mileage, maximum and resting heart rate.",
            purpose: "Every intensity judgement the app makes. Without these it "
                   + "can measure a session but not interpret it.",
            lineage: [.strava, .appleHealth, .authored],
            storage: [.applicationSupport(.file("athlete.json")),
                      .applicationSupport(.file("constants.json"))],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["`athlete.json` has no deletion path anywhere in the app — it "
                 + "is overwritten on refresh and never removed (step 2.1.5).",
                   "`constants.json` stores the NAME of the activity where your "
                 + "maximum heart rate was seen, which is Strava data with no "
                 + "deletion path (ADR-0002)."],
            onStravaDisconnect: .partial(
                keeps: "your typed maximum heart rate, resting override and sex "
                     + "coefficient, and the monthly resting figures from Health",
                removesFiles: [.file("athlete.json")],
                removesKeychain: [],
                // Read off Strava activity data, and `hrMaxObservedName` is the
                // NAME of the activity it was seen in. Cleared per ADR-0002.
                // The cost is stated rather than hidden: with no override typed,
                // the app has no maximum heart rate afterwards and cannot score
                // a session until Health supplies one.
                clearsFields: ["hrMaxObserved", "hrMaxObservedOn", "hrMaxObservedName"])),

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
                 + "(ADR-0002, step 4A M4)."],
            onStravaDisconnect: .keep(why: "you made these corrections. They reference Strava ids and are remapped rather than dropped — step 4A M4")),

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
            gaps: [],
            onStravaDisconnect: .keep(why: "it ships inside the app and has nothing to do with Strava")),

        DataCategoryEntry(
            category: .credentials,
            title: "Keys and tokens",
            whatItIs: "Your Strava application keys and sign-in tokens, and your "
                    + "Anthropic API key.",
            purpose: "Connecting to those services on your behalf.",
            // BOTH, and the second was missing until 187. You typed the
            // application keys, so `.authored` is right for them — but the
            // sign-in tokens were ISSUED BY Strava, and `onlyStravaLineageIsRemoved`
            // caught the omission: a disconnect removes the tokens, and a
            // category with no Strava lineage has no business being altered by
            // a Strava disconnect. The rule was correct; this line was not.
            lineage: [.authored, .strava],
            storage: [.keychain("strava.credentials"),
                      .keychain("strava.tokens"),
                      .keychain("claude.apiKey")],
            retention: .untilDisconnected(source: .strava),
            sharedWith: [],
            isExportable: false,
            aiShareable: false,
            // CORRECTED IN 195, and the correction is the finding. This read
            // "Never exported, and never included in a backup or a diagnostic."
            // The first and last clauses were true. The middle one was false and
            // had been since the Keychain wrapper was written: `Keychain.save`
            // uses `kSecAttrAccessibleAfterFirstUnlock` WITHOUT
            // `ThisDeviceOnly`, and items at that accessibility are included in
            // encrypted device backups and restore onto a new phone. Verified
            // from the source while writing ADR-0003 §9.4 rather than assumed.
            deletionRule: "Never exported, and never put in a diagnostic. "
                        + "Removed on disconnect. Your encrypted device backup "
                        + "does include these — see below.",
            gaps: ["These are in your encrypted device backup and restore onto a "
                 + "new phone. That is deliberate for the sign-in tokens — it is "
                 + "why reconnecting is one tap — and is worth a separate "
                 + "decision for the Anthropic API key, whose loss costs nothing "
                 + "and whose leakage costs money (ADR-0003 §9.4).",
                   "Disconnecting removes the tokens but not the application keys "
                 + "— there is no code path that deletes `strava.credentials` "
                 + "(step 4.2.9).",
                   "Keychain writes do not check their result, so a failure is "
                 + "reported to you as success (AUTH-03, step 4.2.10)."],
            onStravaDisconnect: .partial(
                keeps: "the Strava application keys, so reconnecting is one tap "
                     + "rather than a trip to the Strava developer page",
                removesFiles: [],
                removesKeychain: ["strava.tokens"],
                clearsFields: [])),

        DataCategoryEntry(
            category: .database,
            title: "The database",
            whatItIs: "A SQLite file and the journal files SQLite keeps beside "
                    + "it. Today it holds no training data at all — only an "
                    + "empty schema.",
            purpose: "Phase 3 replaces the folder of JSON files above with one "
                   + "database, so that a note you wrote against a session "
                   + "still finds it after the source it came from is gone.",
            // HONEST FOR TODAY, AND WRONG BY 3.4. The file is created by this
            // phone and contains nothing from anywhere else, so `.device` is
            // the only true answer right now. The moment 3.4 imports the
            // stores, this set becomes the union of every category's lineage
            // and the disconnect rule below stops being `.keep`. Recorded as a
            // gap rather than pre-declared, because an inventory that describes
            // next month's behaviour is the thing this file exists to prevent.
            lineage: [.device],
            storage: [.applicationSupport(.databaseDirectory("db"))],
            retention: .indefinite,
            sharedWith: [],
            isExportable: false,
            aiShareable: false,
            deletionRule: "Removed by Delete local data — the whole folder, so "
                        + "the database and its journal files go together.",
            gaps: ["Holds no training data yet. When step 3.4 moves the stores "
                 + "into it, this entry's lineage, export rule and disconnect "
                 + "rule must all be rewritten — a disconnect will have to "
                 + "delete Strava-derived ROWS rather than a file (ADR-0003 §8).",
                   "Not included in an export. The export writes JSON and a "
                 + "SQLite file is not JSON, so a readable dump has to exist "
                 + "before any category's data moves here (ADR-0003 §9.4).",
                   "Included in your device backup, like everything else under "
                 + "Application Support (ADR-0003 §9.4)."],
            onStravaDisconnect: .keep(why: "it is empty. When step 3.4 moves the training data into it, this rule has to change to one that deletes the Strava-derived rows")),

        DataCategoryEntry(
            category: .diagnostics,
            title: "Diagnostics",
            whatItIs: "When the last background refresh ran, whether it worked, "
                    + "and which activities a source refused to hand over.",
            purpose: "Working out why something did not update, without guessing.",
            // `.strava` added in 187. The gap below has said since 180 that
            // `bg.lastResult` embeds counts and error text from Strava and
            // "inherits that lineage" — and the lineage set did not say so.
            // A disclosure that describes itself correctly in prose and
            // incorrectly in the field the code reads is the same drift this
            // file exists to stop, one level down.
            lineage: [.device, .strava],
            storage: [.preferences(["bg.lastRun", "bg.runCount", "bg.lastResult",
                                    "bg.scheduleError", "detail.failed",
                                    "detail.noStreams"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data.",
            gaps: ["`bg.lastResult` embeds counts and error text from Strava, so "
                 + "it inherits that lineage (ADR-0002)."],
            onStravaDisconnect: .removeEverything),

        DataCategoryEntry(
            category: .appSettings,
            title: "Your settings",
            whatItIs: "How you have set the app up: light or dark, which sport a "
                    + "card shows, hours or kilometres, the zone window — and "
                    + "which transfers you have switched on.",
            purpose: "Keeping the app the way you left it, and remembering what "
                   + "you have permitted it to send.",
            lineage: [.authored],
            storage: [.preferences(["appearance.selected", "discipline.selected",
                                    "volume.unit", "zones.window",
                                    // The release gates. Recorded here rather
                                    // than under diagnostics because they are a
                                    // record of consent, not of behaviour: each
                                    // one is a transfer this person allowed.
                                    "gate.stravaConnect", "gate.stravaSync",
                                    "gate.stravaBackground", "gate.aiReview",
                                    "gate.coordinateWeather",
                                    // Separate from the gate: "is the feature
                                    // on" and "did somebody agree to the
                                    // transfer" are different facts, and only
                                    // the second is consent (PRIV-04).
                                    "consent.locationToWeather"])],
            retention: .indefinite,
            sharedWith: [],
            isExportable: true,
            aiShareable: false,
            deletionRule: "Removed by Delete local data, which returns the app to "
                        + "its defaults — including switching every transfer off.",
            gaps: [],
            onStravaDisconnect: .keep(why: "these are your settings, including the record of which transfers you permitted"))
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

    // MARK: The resolvable view of the inventory
    //
    // Everything below is the same list seen as things-on-disk rather than as
    // categories, DEDUPLICATED. `activities.json` belongs to two categories and
    // `details/` to two more; a delete that walked the categories naively would
    // try to remove them twice and report a phantom failure the second time.

    /// Every distinct Application Support file or directory the inventory names.
    static var appSupportItems: [AppSupportItem] {
        var seen: Set<AppSupportItem> = []
        var out: [AppSupportItem] = []
        for e in entries {
            for s in e.storage {
                if case .applicationSupport(let i) = s, seen.insert(i).inserted {
                    out.append(i)
                }
            }
        }
        return out
    }

    /// Every distinct UserDefaults key.
    static var preferenceKeys: [String] {
        var seen: Set<String> = []
        return entries.flatMap { e in
            e.storage.flatMap { s -> [String] in
                if case .preferences(let keys) = s { return keys }
                return []
            }
        }.filter { seen.insert($0).inserted }
    }

    /// Every distinct Keychain item.
    static var keychainItems: [String] {
        var seen: Set<String> = []
        return entries.flatMap { e in
            e.storage.compactMap { s -> String? in
                if case .keychain(let item) = s { return item }
                return nil
            }
        }.filter { seen.insert($0).inserted }
    }

    /// The categories a given Application Support item belongs to. Used by the
    /// receipt, so a line reads "activities.json — Activity summaries, Routes"
    /// rather than naming one category and quietly deleting another's data too.
    static func categories(holding item: AppSupportItem) -> [DataCategory] {
        entries.filter { e in
            e.storage.contains { s in
                if case .applicationSupport(let i) = s { return i == item }
                return false
            }
        }.map(\.category)
    }

    /// Every recorded difference between stated policy and actual behaviour.
    /// Non-empty today, and each line names the step that closes it.
    static var allGaps: [(DataCategory, String)] {
        entries.flatMap { e in e.gaps.map { (e.category, $0) } }
    }

    /// The single sentence the privacy pane opens with. Computed rather than
    /// written, so it cannot fall out of step with the table underneath it.
    ///
    /// THE SECOND SENTENCE WAS FALSE AND IS CORRECTED IN 195. It read "Nothing
    /// leaves this phone while the transfers above are switched off." Everything
    /// this app writes lives in Application Support, which iOS includes in
    /// iCloud and encrypted local backups by default. So every route Sub4 holds
    /// has left this phone in a backup, and has since the first version.
    ///
    /// That is not a bug — it is what a backup is for, and excluding a year of
    /// training from it so that a new phone starts empty would be the worse
    /// choice. What was wrong is that the sentence gave a reader no way to know
    /// it excluded backups from "leaves this phone". A disclosure that is
    /// technically about transfers and reads as being about everything is
    /// PRIV-01 in one line, written in the file that exists to stop PRIV-01.
    static var summary: String {
        let shared = entries.filter { !$0.sharedWith.isEmpty }.count
        return "\(entries.count) kinds of data, \(shared) of which can reach "
             + "another company. Nothing is sent to another company while the "
             + "transfers above are switched off. Your device backup does "
             + "include what is stored here, as it does everything else on "
             + "this phone."
    }
}
