//
//  SettingsView.swift
//  Sub4
//
//  Strava connection, Health status, thresholds, and the match override picker.
//
//  NOTE: each Form section is its own computed property. One giant Form body
//  overwhelms the SwiftUI type checker ("unable to type-check this expression
//  in reasonable time"). Small pieces compile fast and stay readable.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    /// True when hosted as a tab rather than presented as a sheet.
    ///
    /// The only difference is the Done button. A sheet needs a way out; a tab
    /// does not, and putting one there would offer to dismiss a screen that
    /// cannot be dismissed. Defaulted to false so the one remaining sheet
    /// presentation — none today, but the type is still constructible — keeps
    /// its behaviour without being told.
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var auth = StravaAuth.shared
    @State private var activities = ActivityStore.shared
    @State private var health = HealthStore.shared
    @State private var athlete = AthleteStore.shared

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var editingKeys = false
    @State private var keysSaved = false

    // BackgroundRefresh keeps its counters in UserDefaults, which nothing
    // observes — mirrored into state so the section actually updates.
    @State private var bgNext: Date?
    @State private var bgLastRun: Date?
    @State private var bgRuns = 0
    @State private var bgResult: String?
    @State private var bgError: String?
    @State private var bgRunning = false
    @State private var showManual = false

    @State private var notes = NotesStore.shared
    @State private var notesCSV: ShareItem?
    @State private var confirmingDisconnect = false
    @State private var exportFailed = false
    @State private var copiedVersion = false

    @State private var claudeKey = ""
    @State private var editingClaudeKey = false

    @State private var constants = ConstantsStore.shared
    @State private var hrMaxField = ""
    @State private var hrRestField = ""
    @State private var load = LoadStore.shared
    @State private var showLoadDiagnostics = false
    @State private var showDatabaseHealth = false
    @State private var showHealthReconcile = false
    @State private var thresholds = LoadThresholds.shared
    @State private var weather = WeatherStore.shared

    @AppStorage(AppearanceKey.selected) private var appearanceRaw = Appearance.system.rawValue

    /// One of the eleven places Settings can be.
    ///
    /// This exists only for the split layout — the stacked one still uses
    /// disclosure groups, which are their own selection model. Keeping both is
    /// the deliberate cost of the split view: see the note on `body`.
    enum Pane: String, CaseIterable, Identifiable {
        // `privacy` sits FIRST after appearance, not in the collapsed group
        // with the API keys — patch 178. It is the one pane that decides what
        // leaves the phone, and burying it among the provider-configuration
        // rows would make the most consequential screen the hardest to find.
        case appearance, privacy, strava, apiKeys, claudeKey, health
        case trainingLoad, sync, workouts, matching, notes, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance:   "Appearance"
            case .privacy:      "Data & privacy"
            case .strava:       "Strava"
            case .apiKeys:      "Strava API keys"
            case .claudeKey:    "Claude API key"
            case .health:       "Apple Health"
            case .trainingLoad: "Training load"
            case .sync:         "Sync & data"
            case .workouts:     "Structured workouts"
            case .matching:     "Matching rules"
            case .notes:        "Session notes"
            case .about:        "Manual & version"
            }
        }

        var symbol: String {
            switch self {
            case .appearance:   "circle.lefthalf.filled"
            case .privacy:      "hand.raised"
            case .strava:       "bolt.horizontal.circle"
            case .apiKeys:      "key"
            case .claudeKey:    "sparkles"
            case .health:       "heart"
            case .trainingLoad: "waveform.path.ecg"
            case .sync:         "arrow.triangle.2.circlepath"
            case .workouts:     "figure.run.square.stack"
            case .matching:     "arrow.triangle.merge"
            case .notes:        "note.text"
            case .about:        "book"
            }
        }
    }

    /// Optional because that is what `List(selection:)` binds to. It is never
    /// meaningfully nil — `pane` below folds a nil back to Appearance rather
    /// than leaving the detail pane blank, which is what a split view does by
    /// default and what nobody wants on a screen with eleven destinations.
    @State private var section: Pane? = .appearance

    private var pane: Pane { section ?? .appearance }

    /// TWO LAYOUTS, CHOSEN BY SIZE CLASS
    /// ---------------------------------
    /// Compact — every iPhone in portrait, and the smaller ones in landscape —
    /// keeps the single Form with disclosure groups. Regular, which on a phone
    /// means a Max or Plus turned sideways, gets a sidebar and a detail pane.
    ///
    /// The size class rather than a width breakpoint: it is the signal the
    /// system already computes for exactly this question, and a constant of my
    /// own choosing would need defending every time a device size changed.
    ///
    /// WHAT THIS COSTS, STATED PLAINLY
    /// -------------------------------
    /// Two navigation models for one screen. In compact, "open Sync & data"
    /// expands a group in place and everything else stays visible; in regular it
    /// replaces the detail pane and everything else disappears. The sidebar also
    /// spends about a quarter of the width restating names you can already read.
    ///
    /// The trade bought for that: the detail pane is ~700 pt wide, which is what
    /// the long content in here actually needs — the rejection list, the ignored
    /// recordings, the manual's footnotes. In compact those wrap to three lines
    /// inside a disclosure group. This was a deliberate choice between "see more
    /// at once" and "read one thing properly", and it went to the second.
    ///
    /// Every row property below is shared by both layouts. Only the container
    /// differs, so a change to a setting cannot land in one layout and not the
    /// other.
    var body: some View {
        Group {
            if hSize == .regular { splitLayout } else { stackedLayout }
        }
        .onAppear {
            if let c = StravaConfig.credentials {
                clientID = c.clientID
                clientSecret = c.clientSecret
            }
            editingKeys = !StravaConfig.isConfigured
        }
        .task { await reloadBackground() }
        // Nothing else guarantees the series exists here: sync is throttled
        // to 15 minutes and returns early with no token, so Settings could
        // otherwise show "0 of 0" and hide the gap row, which reads as
        // "no gaps" rather than "not computed". Fingerprint-guarded.
        .task { load.recomputeIfNeeded() }
        // Attached to the container, not to either layout. A sheet declared
        // inside a branch is torn down when the branch is — rotate the phone
        // with the diagnostics open and it would vanish.
        .sheet(isPresented: $showManual) { ManualView() }
        .sheet(isPresented: $showLoadDiagnostics) { LoadDiagnosticView() }
        .sheet(isPresented: $showDatabaseHealth) { DatabaseHealthView() }
        .sheet(isPresented: $showHealthReconcile) { HealthReconcileView() }
        .sheet(item: $notesCSV) { ShareSheet(items: [$0.url]) }
        // The button is disabled at zero notes, so the only way to reach
        // this is a failed write. Saying "you have no notes" here would be
        // wrong in the one case it can appear.
        .alert("Export failed", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The file could not be written. Free some space and try again.")
        }
        .tint(.accent4)
    }

    /// Built from `onStravaDisconnect`, not written by hand — patch 187.
    ///
    /// The point of declaring the rules in the inventory is that this sentence
    /// and the code that runs are the same source. A hand-written warning here
    /// would be one more disclosure free to drift from what actually happens.
    private var disconnectMessage: String {
        let goes = DataLifecycle.entries
            .filter { $0.onStravaDisconnect.removesAnything }
            .map(\.title)
        let stays = DataLifecycle.entries
            .filter { if case .keep = $0.onStravaDisconnect { return true }; return false }
            .map(\.title)
        return "Removed: " + goes.joined(separator: ", ") + ".\n\n"
             + "Kept: " + stays.joined(separator: ", ") + ".\n\n"
             + "Your Strava account is untouched. Reconnecting re-downloads "
             + "everything, but anything you deleted at Strava's end is gone."
    }

    // MARK: Compact — one column, disclosure groups

    private var stackedLayout: some View {
        NavigationStack {
            Form {
                appearanceSection
                // Uncollapsed, above Strava — patch 178. These switches decide
                // what leaves the phone, and while any of them is shut they also
                // explain why the app is behaving differently from yesterday.
                // Hidden inside a disclosure group that would be a riddle.
                ReleaseGatesView()
                DataControlsView()
                DataLifecycleView()
                // Strava stays open — connection state is the one thing here
                // you'd actually come looking for. Everything else is either
                // set once or only interesting when something is wrong.
                stravaSection
                Section {
                    DisclosureGroup("Strava API keys")     { credentialRows }
                    DisclosureGroup("Claude API key")      { claudeRows }
                    DisclosureGroup("Apple Health")        { healthGroupRows }
                    DisclosureGroup("Training load")       { constantsRows }
                    DisclosureGroup("Sync & data")         { syncRows }
                    DisclosureGroup("Structured workouts") { workoutRows }
                    DisclosureGroup("Matching rules")      { filterRows }
                    DisclosureGroup("Session notes")       { notesRows }
                } footer: {
                    Text(collapsedFooter)
                }

                manualSection
                versionSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: Regular — sidebar and detail

    private var splitLayout: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in
                NavigationLink(value: s) {
                    Label {
                        HStack {
                            Text(s.title)
                            if s == .strava, needsAttention {
                                Spacer()
                                // The same fact the tab badge carries, at the
                                // one row that can act on it. Nothing else in
                                // this list ever changes appearance, so a dot
                                // here can only mean one thing.
                                Circle().fill(Color.accent4)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    } icon: {
                        Image(systemName: s.symbol)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        } detail: {
            NavigationStack {
                Form { detailRows }
                    .navigationTitle(pane.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // Both panes visible whenever there is room for them. The default
        // would collapse to the detail alone at some widths and leave no way
        // back to the list without a swipe nobody is told about.
        .navigationSplitViewStyle(.balanced)
    }

    private var needsAttention: Bool {
        !auth.isConnected || activities.lastError != nil
    }

    @ViewBuilder
    private var detailRows: some View {
        switch pane {
        case .appearance:   appearanceSection
        // Switches first, inventory second — patch 180. The controls are what
        // a reader came to act on; the inventory is what they read to decide.
        // Switches, then the two things a reader can DO, then the
        // inventory they read to decide — patch 183.
        case .privacy:      ReleaseGatesView(); DataControlsView(); DataLifecycleView()
        case .strava:       stravaSection
        case .apiKeys:      Section { credentialRows }
        case .claudeKey:    Section { claudeRows }
        case .health:       Section { healthGroupRows }
        case .trainingLoad: Section { constantsRows }
        case .sync:         Section { syncRows }
        case .workouts:     Section { workoutRows }
        case .matching:     Section { filterRows }
        case .notes:        Section { notesRows }
        case .about:        manualSection; versionSection
        }
    }

    private var manualSection: some View {
        Section {
            Button { showManual = true } label: {
                Label("Manual", systemImage: "book")
            }
        } footer: {
            Text("Everything the app does and why, including the rules "
                 + "behind matching and the structured-workout parser.")
        }
    }

    // MARK: Strava

    // MARK: Appearance
    //
    // TOP OF THE LIST, ABOVE STRAVA. Everything else in Settings is set once and
    // then forgotten; this is the one row anyone might come back to on a whim,
    // and burying a whim three disclosure groups down is how it never gets
    // found. It is also the cheapest thing here to change your mind about.
    //
    // A segmented picker rather than a disclosure group: three mutually
    // exclusive values that fit on one row, where the current state is the
    // answer to the question you opened Settings to ask.
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { a in
                    Label(a.label, systemImage: a.symbol).tag(a.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Automatic follows the phone. The light scheme is its own "
                 + "palette rather than an inversion — three of the dark "
                 + "theme's colour decisions do not survive a white surface, "
                 + "and the heart-rate zones in particular are drawn as one "
                 + "blue ramp on light because five hues cannot be told apart "
                 + "there. Every zone is named on both.")
        }
    }

    private var stravaSection: some View {
        Section("Strava") {
            LabeledContent("Status") {
                Text(auth.isConnected ? "Connected" : "Not connected")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(auth.isConnected ? Color.accent4 : Color.secondary)
            }

            if auth.isConnected {
                LabeledContent("Token") {
                    Text(tokenLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(auth.isExpired ? Color.orange : Color.secondary)
                }
                LabeledContent("Activities held", value: "\(activities.count)")
                LabeledContent("Last check", value: lastCheckLabel)

                Button("Refresh sign-in") { Task { await auth.refresh() } }

                Button(action: { Task { await activities.sync() } }) {
                    HStack {
                        Text("Check now")
                        if activities.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(activities.isSyncing)

                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                    // On the button, not the container — patch 185's lesson.
                    .alert("Disconnect Strava?", isPresented: $confirmingDisconnect) {
                        Button("Cancel", role: .cancel) { }
                        Button("Disconnect", role: .destructive) { auth.disconnect() }
                    } message: {
                        Text(disconnectMessage)
                    }
            } else {
                Button("Connect Strava") { Task { await auth.connect() } }
                    .font(.body.weight(.semibold))
            }

            if let e = auth.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            // The gate notice, in the dim ink rather than in red — patch 179.
            // Red is the app's word for "something is wrong"; this is the app
            // doing exactly what it was told. The row exists at all because the
            // alternative is a sync that silently stops and an athlete with no
            // way to find out why.
            if let n = activities.lastGateNotice {
                Label {
                    Text(n + " Data & privacy, above.")
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.caption)
                .foregroundStyle(Color.dim)
            }
        }
    }

    /// "valid for 5h 12m" / "expired 3h ago" — makes auth state legible instead
    /// of something you infer from a 401.
    private var tokenLabel: String {
        guard let e = auth.expiry else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let when = f.localizedString(for: e, relativeTo: Date())
        return auth.isExpired ? "expired \(when)" : "valid \(when)"
    }

    private var lastCheckLabel: String {
        guard let d = activities.lastSync else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: Claude API key
    //
    // Keychain, exactly like the Strava secret, and for the same reason: a key
    // in source is a key in every patch zip and in any git history the project
    // ever acquires. Entered once, survives every code update.

    @ViewBuilder
    private var claudeRows: some View {
        if ClaudeConfig.isConfigured && !editingClaudeKey {
            LabeledContent("Key", value: "••••••••")
            LabeledContent("Model", value: ClaudeConfig.model)
            Button("Change key") { editingClaudeKey = true }
            Button("Remove key", role: .destructive) {
                ClaudeConfig.apiKey = nil
                claudeKey = ""
            }
        } else {
            SecureField("sk-ant-…", text: $claudeKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key") {
                ClaudeConfig.apiKey = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
                editingClaudeKey = false
            }
            .disabled(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Text(claudeFooter)
            .font(.caption).foregroundStyle(.secondary)
    }

    private let claudeFooter =
        "Used only by the monthly review, and only when you press the button. "
        + "It sends the computed figures — adherence, volume, mean RPE — never "
        + "your raw activity data. Get a key at console.anthropic.com; this is "
        + "the Claude API, billed separately from a Claude subscription, at "
        + "roughly ten cents a review."

    // MARK: Version
    //
    // Last section, no disclosure group, always visible. This is the answer to
    // "which build am I looking at?" and it needs to be readable from a
    // screenshot without anybody tapping anything — that is the entire point.
    //
    // Tap to copy the full stamp, because the moment you actually need this is
    // when you are describing a problem to someone else.

    @ViewBuilder
    private var versionSection: some View {
        // header:/footer: view builders, not Section("Version") { } footer: { }.
        // There is no Section initialiser taking a string title AND a footer —
        // the title-string form is `init(_:content:)` with Footer == EmptyView.
        Section {
            LabeledContent("App", value: "\(AppVersion.marketing) (\(AppVersion.build))")
            LabeledContent("Source patch", value: "\(AppVersion.patch)")
            LabeledContent("Built", value: AppVersion.builtLabel)
            LabeledContent("Configuration", value: AppVersion.configuration)

            Button {
                UIPasteboard.general.string = AppVersion.full
                copiedVersion = true
                // Reverts, so the button goes back to saying what it does. A
                // permanent "Copied" is a label that has stopped being a verb.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedVersion = false
                }
            } label: {
                Label(copiedVersion ? "Copied" : "Copy version details",
                      systemImage: copiedVersion ? "checkmark" : "doc.on.doc")
            }
        } header: {
            Text("Version")
        } footer: {
            Text(versionFooter)
        }
    }

    private let versionFooter =
        "App is Xcode's Version and Build. Source patch is bumped by every code "
        + "patch — if it reads lower than the patch you just installed, the "
        + "files did not reach the project folder. Built is read off the binary, "
        + "so nobody has to remember it."

    // MARK: Training-load constants
    //
    // These are shown before any load figure exists, deliberately. TRIMP is an
    // exponential function of (HR − rest) / (max − rest), so both numbers sit
    // under an exponent — and a maximum that is 15 bpm wrong does not shift the
    // answer, it bends the curve. Nothing computed downstream is worth reading
    // until the two figures on this screen are ones you recognise.

    @ViewBuilder
    private var constantsRows: some View {
        hrMaxRows
        Divider()
        hrRestRows
        Divider()
        LabeledContent("Constants version", value: "\(constants.version)")

        // The raw layer, one tap away. Every figure the engine will draw comes
        // from this list, and each will look equally plausible right or wrong.
        LabeledContent("Days scored") {
            Text("\(load.count(.measured) + load.partialCount) of \(load.days.count)")
        }
        if load.gapCount > 0 {
            LabeledContent("Gaps") {
                Text("\(load.gapCount)").foregroundStyle(.orange)
            }
        }
        Button("Load diagnostics") { showLoadDiagnostics = true }

        // The only thresholds in the app you can move without a patch, and the
        // reasoning is in LoadThresholds.swift: each one is a population figure
        // being applied to one athlete.
        DisclosureGroup("Review thresholds") { thresholdRows }

        // The work is in HealthStore.recomputeEverything — including the
        // workout cache, which the old inline version never touched despite the
        // label saying "and Health". The spinner and the summary line below are
        // the point: a button that re-derives figures which usually come out
        // identical needs to say it ran, or it reads as dead.
        Button {
            Task { await health.recomputeEverything() }
        } label: {
            HStack {
                Text("Recompute from Strava and Health")
                if health.isRefreshing { Spacer(); ProgressView() }
            }
        }
        .disabled(health.isRefreshing)

        if let s = health.lastRefreshSummary {
            Text(s).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(constantsFooter).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var thresholdRows: some View {
        stepper("Ramp — warn", $thresholds.rampWarn, 1, 3...15,
                "CTL gained in seven days above which the review flags it.")
        stepper("Ramp — note", $thresholds.rampNote, 1, 1...12,
                "The quieter level: mentioned, not warned about.")
        stepper("Deep freshness", $thresholds.tsbDeep, 5, (-60)...(-5),
                "TSB at or below this counts as deep.")
        Stepper(value: $thresholds.tsbDeepDays, in: 2...21) {
            LabeledContent("Deep days in a row",
                           value: "\(thresholds.tsbDeepDays)")
        }
        stepper("Monotony", $thresholds.monotonyHigh, 0.1, 1.2...4.0,
                "Foster's figure is 2.0.")
        if !thresholds.isDefault {
            Button("Reset to defaults") { thresholds.reset() }
        }
        Text("These three are editable because each is a population figure "
             + "applied to one athlete — the 5-per-week ramp ceiling is a "
             + "cycling number at steady volume, and race-day TSB targets are "
             + "folklore the source literature disowns. Everything else the "
             + "review fires on is fixed in source, because moving it would "
             + "change what the review means rather than what it looks at.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func stepper(_ title: String, _ value: Binding<Double>,
                         _ step: Double, _ range: ClosedRange<Double>,
                         _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: value, in: range, step: step) {
                LabeledContent(title,
                               value: String(format: step < 1 ? "%.1f" : "%.0f",
                                             value.wrappedValue))
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hrMaxRows: some View {
        LabeledContent("Max heart rate") {
            Text(constants.hrMax.map { "\($0) bpm" } ?? "unknown")
                .font(.callout.weight(.semibold))
                .foregroundStyle(constants.hrMax == nil ? Color.red : Color.secondary)
        }
        LabeledContent("Source", value: constants.hrMaxSource)

        if let day = constants.hrMaxObservedOn {
            LabeledContent("Highest seen") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(constants.hrMaxObserved ?? 0) bpm · \(day)")
                    if let n = constants.hrMaxObservedName {
                        Text(n).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        if constants.hrMaxContradictsZones {
            Text("This is at or below the floor of your own Z5, so it cannot be "
                 + "a true maximum — the hardest efforts on record were not "
                 + "maximal, or the wrist under-read. Every load figure is "
                 + "inflated by the gap until this is corrected. The December "
                 + "field test is the session likely to settle it.")
                .font(.caption).foregroundStyle(.orange)
        }

        // A rise is not an error, but it does mean every load computed under
        // the old figure was computed under a number now known to be wrong.
        if let from = constants.hrMaxRoseFrom {
            Text("A harder effort raised the observed maximum from \(from) bpm. "
                 + "Anything already computed used the old figure and will be "
                 + "recomputed.")
                .font(.caption).foregroundStyle(.orange)
            Button("Got it") { constants.acknowledgeHRMaxRise() }
        }

        HStack {
            TextField("Your own value", text: $hrMaxField)
                .keyboardType(.numberPad)
            Button("Set") {
                constants.setHRMaxOverride(Int(hrMaxField))
                hrMaxField = ""
            }
            .disabled(Int(hrMaxField).map { !ConstantsStore.hrMaxPlausible.contains($0) } ?? true)
        }
        if constants.hasHRMaxOverride {
            Button("Use the highest recorded instead", role: .destructive) {
                constants.setHRMaxOverride(nil)
            }
        }
    }

    @ViewBuilder
    private var hrRestRows: some View {
        LabeledContent("Resting HR, this month") {
            Text(constants.hrRest(on: DayKey.key()).map { "\($0) bpm" } ?? "unknown")
                .font(.callout.weight(.semibold))
        }
        LabeledContent("Months covered", value: "\(constants.monthsCovered)")
        LabeledContent("Span", value: constants.restSpanLabel)

        let missing = constants.missingMonths(since: MatchRules.cutoffDayKey)
        if !missing.isEmpty {
            LabeledContent("No Health data", value: missing.joined(separator: ", "))
                .font(.caption)
        }
        if health.needsRestingHRGrant {
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
        }

        HStack {
            TextField("Fallback value", text: $hrRestField)
                .keyboardType(.numberPad)
            Button("Set") {
                constants.setRestOverride(Int(hrRestField))
                hrRestField = ""
            }
            .disabled(Int(hrRestField).map { !ConstantsStore.hrRestPlausible.contains($0) } ?? true)
        }
    }

    private let constantsFooter =
        "Max heart rate is the highest recorded in the last 12 months, which is "
        + "only correct if a genuinely maximal effort is in that window — check "
        + "it after the December test. Resting heart rate is the tenth "
        + "percentile of each month's daily readings from Apple Health, so a "
        + "January session is scored against January. Changing either changes "
        + "every load figure, which is what the version number tracks."

    private let collapsedFooter =
        "Heart-rate zones and shoe wear moved to the Progress tab — they're "
        + "things you read, not things you set."

    // MARK: Session notes
    //
    // The export is the whole point of the notes feature. The monthly review —
    // is the block too hard, too easy, does it need rewriting — happens by
    // reading the data somewhere it can be sorted and charted, not by scrolling
    // sessions in the app. So this section is one honest count and one button.
    //
    // Nothing here deletes. Notes are the only data in this app that Strava
    // cannot send again, so a "clear notes" button in a settings screen is a
    // one-tap way to lose the entire point of the feature. Deleting happens one
    // note at a time, in the editor, behind a confirmation.

    @ViewBuilder
    private var notesRows: some View {
        LabeledContent("Notes written", value: "\(notes.count)")

        let orphans = notes.orphans(in: PlanStore.shared).count
        if orphans > 0 {
            LabeledContent("Orphaned") {
                Text("\(orphans)").foregroundStyle(.orange)
            }
        }

        Button {
            if notes.count > 0,
               let url = NotesStore.shared.writeCSV(plan: PlanStore.shared) {
                notesCSV = ShareItem(url: url)
            } else {
                exportFailed = true
            }
        } label: {
            Label("Export notes as CSV", systemImage: "square.and.arrow.up")
        }
        .disabled(notes.count == 0)

        Text(notesFooter)
            .font(.caption).foregroundStyle(.secondary)

        if orphans > 0 {
            Text(orphanFooter)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // Hoisted, like every other footer in this file — see the header comment.
    // Five concatenated literals inline is exactly the shape that trips the
    // type checker in a Form body.
    private let notesFooter =
        "Each row carries the note and the session it was written about — "
        + "date, week, discipline, what the plan asked for, RPE, how it felt "
        + "and the text. That join is what makes a monthly review possible; "
        + "RPE on its own says nothing without the prescription beside it."

    private let orphanFooter =
        "Orphaned notes belong to sessions that are no longer in the plan, "
        + "which happens if the plan is rebuilt with different identifiers. "
        + "They are still on disk and still in the export, they just no "
        + "longer attach to a session."

    // MARK: API keys

    @ViewBuilder
    private var credentialRows: some View {
        Group {
            if StravaConfig.isConfigured && !editingKeys {
                LabeledContent("Client ID", value: StravaConfig.clientID)
                LabeledContent("Secret", value: "••••••••")
                Button("Change keys") { editingKeys = true }
            } else {
                TextField("Client ID", text: $clientID)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                SecureField("Client Secret", text: $clientSecret)
                Button("Save keys") { saveKeys() }
                    .font(.body.weight(.semibold))
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)
            }
            if keysSaved {
                Text("Saved to Keychain.").font(.caption).foregroundStyle(Color.accent4)
            }
        }
        Text(keysFooter).font(.caption).foregroundStyle(.secondary)
    }

    private let keysFooter =
        "From strava.com/settings/api. Stored in the iOS Keychain rather than in "
        + "the app's source, so code updates can't overwrite them and the secret "
        + "never reaches the git repository."

    private func saveKeys() {
        StravaConfig.save(.init(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)))
        editingKeys = false
        keysSaved = true
    }

    // MARK: Sync & data
    //
    // The ingest window, the cache rebuild and the background-refresh counters
    // were three separate sections asking the same question — is the data
    // arriving. They read better as one.

    @ViewBuilder
    private var syncRows: some View {
        LabeledContent("Ingest from", value: MatchRules.cutoffDayKey)

        // INTERNAL ONLY, per plan step 3.2.5. Here rather than beside "Load
        // diagnostics" because that screen is about training load and this one
        // is about storage — and the group a diagnostic sits in is the first
        // hint anybody gets about what it will tell them.
        //
        // Nothing in the app reads the database yet. This is the screen that
        // lets somebody confirm it was created, migrated and protected on a
        // real phone rather than only in a test runner, and opening it is what
        // puts the file on disk for the first time.
        if ReleaseGates.isInternalBuild {
            Button("Database health") { showDatabaseHealth = true }
        }

        // Two windows since patch 117, so one row can no longer answer "how far
        // back does this app see". The charts get the full history; the Week
        // tab starts at the block, because it grades against a plan that does
        // not exist before then.
        LabeledContent("Week grid from", value: MatchRules.weekGridDayKey)

        // A recording the app throws away without saying so is indistinguishable
        // from one it failed to fetch, and the second is a bug. This row is what
        // makes the difference visible.
        if !DataCorrections.ignoredActivities.isEmpty {
            LabeledContent("Ignored recordings",
                           value: "\(DataCorrections.ignoredActivities.count)")
            ForEach(DataCorrections.ignoredReasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }

        // The rule's receipt. A named exception in DataCorrections is auditable
        // by reading the file; a rule that fires on its own is only auditable if
        // it says what it fired on.
        // Weather is fetched on demand and cached for ever, so these two
        // counters are the only way to tell "not looked at yet" from "looked at
        // and refused" — which is the difference between an indoor session and a
        // missing WeatherKit capability.
        LabeledContent("Weather cached", value: "\(weather.storedCount)")
        // Which provider actually answered last. The whole point of a fallback
        // is that you cannot tell from the card alone whether the primary is
        // working — this row is where that becomes visible.
        if let src = weather.lastSource {
            LabeledContent("Weather source", value: src.label)
        }

        if weather.backfillRunning {
            LabeledContent("Fetching weather",
                           value: "\(weather.backfillDone) of \(weather.backfillTotal)")
        } else {
            let pending = weather.pending(activities.activities)
            if pending > 0 {
                Button("Fetch weather for \(pending) activities") {
                    Task { await weather.backfill(activities.activities) }
                }
                Text("Every outdoor activity that does not have conditions yet, "
                     + "oldest first, about six a second. Nothing is fetched "
                     + "automatically — opening an activity fetches that one, "
                     + "and this button fetches the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if weather.failedCount > 0 {
            LabeledContent("Weather failed this session",
                           value: "\(weather.failedCount)")
            Button("Retry weather") { weather.retryAll() }
            Text("Activities both providers refused. Apple Weather is tried "
                 + "first and needs an active paid membership; Open-Meteo needs "
                 + "nothing and picks up whatever Apple will not answer, so a "
                 + "number here usually means no network rather than no "
                 + "entitlement. Cleared on relaunch; the button also re-arms "
                 + "Apple, for the day the capability goes live.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !activities.rejected.isEmpty {
            LabeledContent("Rejected — speed contradiction",
                           value: "\(activities.rejected.count)")
            ForEach(activities.rejected, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }

        LabeledContent("Next window") {
            Text(bgNextLabel).foregroundStyle(bgNext == nil ? Color.orange : Color.secondary)
        }
        LabeledContent("Woken by iOS", value: "\(bgRuns)×")
        LabeledContent("Last run", value: bgLastRunLabel)
        if let r = bgResult {
            LabeledContent("Result") {
                Text(r).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        if let e = bgError { Text(e).font(.caption).foregroundStyle(.red) }
        manualRunButton

        Button("Refresh zones & gear") { Task { await athlete.refresh() } }
        if let e = athlete.lastError {
            Text(e).font(.caption).foregroundStyle(.orange)
        }

        Button("Rebuild activity cache", role: .destructive) {
            activities.resetCache()
            Task { await activities.sync() }
        }

        Text(backgroundFooter).font(.caption).foregroundStyle(.secondary)
        Text(dataFooter).font(.caption).foregroundStyle(.secondary)
    }

    private let dataFooter =
        "Only activities from the plan start date are ingested. Rebuilding clears "
        + "the local copy and re-pulls from Strava — your Strava data is never modified."

    // MARK: Structured workouts

    @ViewBuilder
    private var workoutRows: some View {
        NavigationLink {
            WorkoutAuditView()
        } label: {
            LabeledContent("Workout parsing", value: "check all sessions")
        }
        Text(workoutFooter).font(.caption).foregroundStyle(.secondary)
    }

    private let workoutFooter =
        "Every run session is read into warm-up, interval blocks and cool-down "
        + "with pace bands, ready for the Watch. Check the parsing before any of "
        + "it is sent — a workout that quietly turned into the wrong thing would "
        + "cost you the session."

    // MARK: Background refresh
    //
    // These counters exist because BGAppRefreshTask is otherwise completely
    // opaque: there is no way to tell a background refresh that iOS simply
    // hasn't scheduled yet from one that was never registered properly. If
    // "Times run" is still 0 after a couple of days, it isn't working.

    private var manualRunButton: some View {
        Button {
            Task {
                bgRunning = true
                await BackgroundRefresh.run(manual: true)
                await reloadBackground()
                bgRunning = false
            }
        } label: {
            HStack {
                Text("Run the task now")
                Spacer()
                if bgRunning { ProgressView().controlSize(.small) }
            }
        }
        .disabled(bgRunning)
    }

    /// nil means NOTHING is queued — the counters would sit at zero forever and
    /// look identical to "iOS hasn't got round to it".
    private var bgNextLabel: String {
        guard let d = bgNext else { return "none pending" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
        return "after \(f.string(from: d))"
    }

    private var bgLastRunLabel: String {
        guard let d = bgLastRun else { return "never" }
        // RelativeDateTimeFormatter renders a zero interval as "in 0 seconds",
        // which reads as a bug the moment you tap "Run the task now".
        let age = Date().timeIntervalSince(d)
        if age < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    @MainActor
    private func reloadBackground() async {
        bgNext    = await BackgroundRefresh.nextScheduled()
        bgLastRun = BackgroundRefresh.lastRun
        bgRuns    = BackgroundRefresh.runCount
        bgResult  = BackgroundRefresh.lastResult
        bgError   = BackgroundRefresh.scheduleError
    }

    private let backgroundFooter =
        "\"Next window\" is the earliest iOS will consider a wake-up, not an "
        + "appointment — it decides the actual moment, learning from when you "
        + "open the app. Nothing fires while the app is force-quit from the app "
        + "switcher, or in Low Power Mode. \"Run the task now\" proves the work "
        + "completes; only \"Woken by iOS\" climbing on its own proves the "
        + "scheduling does."

    // MARK: Apple Health

    @ViewBuilder
    private var healthGroupRows: some View {
        healthRows
        if let e = health.lastError {
            Text(e).font(.caption).foregroundStyle(.red)
        }
        Text(healthFooter).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var healthRows: some View {
        if !health.isAvailable {
            Text("Not available on this device").foregroundStyle(.secondary)
        } else {
            LabeledContent("Privacy string") {
                Text(health.hasUsageDescription ? "present" : "MISSING")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(health.hasUsageDescription ? Color.secondary : Color.red)
            }
            // "PROMPT SHOWN", NOT "ACCESS GRANTED" — patch 213.
            //
            // This row read `granted / not granted` off
            // `hasRequestedAuthorization`, which is a UserDefaults bool set when
            // the PROMPT WAS SHOWN. It says nothing about what was allowed, and
            // HealthKit will not say either — the comment immediately below and
            // the footer at the bottom of this section both state that
            // outright, so the screen contradicted itself twice.
            //
            // The cost of the lie is specific: steps come back empty while this
            // row says "granted", and the reader goes looking at the query
            // instead of at iOS Settings. The three series rows below are what
            // actually describe the reads, and they are the answer to
            // "did it work".
            LabeledContent("Health prompt",
                           value: health.hasRequestedAuthorization ? "shown" : "never shown")

            // `Days with steps` stood here, showing `stepsByDay.count` — the
            // same number the Steps row below carries, one row apart and
            // phrased differently. It predates the series rows; they say it
            // better, with a status a bare count cannot express.

            // THE THREE STATUSES, FINALLY ON A SCREEN — patch 203.
            //
            // `SeriesStatus` was added in 2.2.6 for a specific reason:
            // HealthKit refuses to say whether a read was denied, so "granted"
            // is a claim this app cannot make. Five states are what it CAN
            // distinguish, and each implies something different about whether
            // to retry, re-prompt, or leave the reader alone.
            //
            // They have been computed on every refresh since, asserted by
            // `HealthTypeTests`, and displayed nowhere — so the distinction the
            // type exists to draw has never reached the person who needs it.
            // Found while writing installation instructions for a screen that
            // turned out not to exist.
            healthSeriesRow("Steps", health.stepsStatus)
            healthSeriesRow("Walking and running distance", health.walkRunStatus)
            healthSeriesRow("Resting heart rate", health.restingHRStatus)

            // NOT "step access" — patch 213. `requestAuthorization` asks for
            // `typesRead`: steps, walking and running distance, resting heart
            // rate, workouts, and the swim distance inside them. A button
            // naming only steps gives the reader whose heart-rate row is empty
            // no reason to press it.
            Button("Allow Health access") {
                Task { await health.requestAuthorization() }
            }
            .disabled(!health.hasUsageDescription)

            Button("Refresh") { Task { await health.refresh() } }
                .disabled(!health.hasRequestedAuthorization)

            // A diagnostic, not a feature. Strava is still the sole source of
            // truth for every figure in the app; this only reports where the
            // two disagree, so the scope of any move onto Health is decided by
            // this athlete's data rather than by what the APIs could do.
            Button("Compare with Strava") { showHealthReconcile = true }
                .disabled(!health.hasRequestedAuthorization)
        }
    }

    /// `noData` is shown plainly rather than in red: a device with no swims is
    /// not broken, and colouring an honest absence as a fault teaches the
    /// reader to ignore the colour.
    @ViewBuilder
    private func healthSeriesRow(_ title: String,
                                 _ status: HealthStore.SeriesStatus) -> some View {
        LabeledContent(title) {
            Text(status.label)
                .font(.callout)
                .foregroundStyle(status.isProblem ? Color.red : Color.secondary)
        }
        .font(.caption)
    }

    /// THE WINDOWS ARE STATED — patch 213.
    ///
    /// The day counts above are days WITH DATA INSIDE A WINDOW, and the window
    /// is not the same for all three: `HealthStore.refresh` reads 120 days of
    /// steps and distance against 420 of resting heart rate, deliberately,
    /// because a January session has to be scored against January's resting
    /// rate rather than this month's.
    ///
    /// Today those windows are full, so "121 days" and "421 days" happen to
    /// describe both the window and the data. The day Health holds less, a row
    /// reading "40 days" cannot be told apart from "we only asked for 40" — and
    /// the reader has no way to know which, unless it says so here.
    private let healthFooter =
        "Read only — this app never writes to Health. Steps and walking "
        + "distance are read over the last 120 days, resting heart rate over "
        + "420, so a session in January is scored against January's resting "
        + "rate. The day counts are days with data inside those windows.\n\n"
        + "iOS will not reveal whether read access was granted, which is why "
        + "the row above says only whether the prompt was shown. If a series "
        + "stays empty, check Settings → Privacy & Security → Health → Sub4."

    // MARK: Noise filter

    @ViewBuilder
    private var filterRows: some View {
        LabeledContent("Minimum ride", value: "\(Int(MatchRules.minRideKm)) km")
        LabeledContent("Minimum run", value: "\(MatchRules.minRunKm) km")
        LabeledContent("Minimum swim", value: "\(Int(MatchRules.minSwimMetres)) m")
        Text(filterFooter).font(.caption).foregroundStyle(.secondary)
    }

    private let filterFooter =
        "Your bike commute is consistently 3–4 km and every real training ride is "
        + "over 20 km, so rides under 10 km are ignored rather than matched against "
        + "a planned session. They still appear under Extra movement."
}

// MARK: - Manual match override

struct MatchPickerView: View {
    let session: Session
    let dayKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var matcher = Matcher.shared
    @State private var activities = ActivityStore.shared

    var body: some View {
        NavigationStack {
            List {
                headerSection
                choiceSection
                resetSection
            }
            .navigationTitle("Fix match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.accent4)
    }

    private var headerSection: some View {
        Section {
            Text(session.title ?? "—").font(.headline)
            if let d = session.detail {
                Text(d).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var choiceSection: some View {
        Section("Choose the activity") {
            Button {
                matcher.setOverride(session: session, activity: nil)
                dismiss()
            } label: {
                Label("Not done", systemImage: "circle")
            }

            ForEach(activities.activities(on: dayKey)) { a in
                Button {
                    matcher.setOverride(session: session, activity: a)
                    dismiss()
                } label: {
                    activityRow(a)
                }
            }
        }
    }

    private func activityRow(_ a: Activity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a.name)
            Text(subtitle(a)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ a: Activity) -> String {
        let km = String(format: "%.2f km", a.km)
        return "\(a.sportType) · \(km) · \(a.minutes) min"
    }

    private var resetSection: some View {
        Section {
            Button("Back to automatic", role: .destructive) {
                matcher.clearOverride(session: session)
                dismiss()
            }
        } footer: {
            Text("Overrides are remembered. Use this when the automatic match picks "
                 + "the wrong activity — for example two runs on one day.")
        }
    }
}
