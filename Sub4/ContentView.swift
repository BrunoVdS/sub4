//
//  ContentView.swift
//  Sub4
//
//  Five tabs. Commute used to be one of them — it lives on Progress now,
//  because it answers the same question that tab already answers: how is the
//  volume going.
//
//  SETTINGS WAS A TOOLBAR GEAR UNTIL PATCH 126
//  -------------------------------------------
//  The old note here argued that Settings is a place you visit occasionally and
//  a tab slot is worth more than that. The counter-argument won: every other
//  destination in the app is reached from the bottom, and one that is reached
//  from the top-right corner instead is a second navigation model to remember.
//  The gear also had to be attached from inside four separate NavigationStacks,
//  and one of those four had to spell the button out by hand because the shared
//  modifier brought a `.sheet` the screen already had.
//
//  Two things improved beyond consistency. Settings is no longer presented, so
//  it keeps its scroll position and its open disclosure groups between visits
//  like every other tab. And the top-right corner of all four screens is free.
//
//  The cost, stated: a maintenance screen now sits at the same visual weight as
//  four screens used daily, and five labels on a phone tab bar are tighter than
//  four.
//

import SwiftUI

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @State private var auth = StravaAuth.shared
    @State private var activities = ActivityStore.shared

    /// WHY THE SELECTION IS HELD HERE AND NOT LEFT TO THE TAB VIEW
    /// -----------------------------------------------------------
    /// `TabView { … }` without a `selection:` binding keeps the selected tab in
    /// its own internal state, and that state belongs to the TabView's current
    /// configuration rather than to this view. Rotating a Max flips the
    /// horizontal size class from compact to regular, the tab bar reconfigures
    /// itself for the new class, and the selection goes with it — landing back
    /// on the first tab.
    ///
    /// It was invisible until Settings became a tab in patch 126. Before that
    /// the only way to reach Settings was a sheet, which is its own presentation
    /// and survives a rotation; and rotating on Today, Week or Plan put you back
    /// on the tab you were already looking at, so nothing appeared to happen.
    /// The bug is older than the report.
    ///
    /// `@State`, not `@SceneStorage`: this should survive a rotation, not a
    /// relaunch. The app opening on Today every morning is correct.
    private enum Tab: Hashable { case today, week, plan, progress, settings }
    @State private var tab: Tab = .today

    /// A dot on the gear when Strava cannot be read.
    ///
    /// THIS IS THE ONLY STRAVA INDICATOR LEFT IN THE APP OUTSIDE SETTINGS
    /// ------------------------------------------------------------------
    /// Today used to state the same fact three times at once — an icon in the
    /// toolbar, an orange "Connect Strava" card, and an error banner at the
    /// bottom — with Settings saying it a fourth time. All three are gone.
    ///
    /// Something had to survive, and a badge is the smallest thing that can.
    /// This app derives COMPLETION from Strava: if the token expires and nothing
    /// says so, every session quietly renders as not-done and it reads as missed
    /// training rather than as a broken sync. The badge is invisible while the
    /// connection is healthy, which is the whole point — it is an alarm, not a
    /// status display, and it sits on the tab that can fix it.
    /// PATCH 279 — THE CONDITIONS LIVE IN `AppHealth` NOW, and the reason is
    /// that this expression and `SettingsView.needsAttention` were two answers
    /// to one question. 273 added the read journal to that one and not to this
    /// one, so a store the app could not read lit the row INSIDE Settings and
    /// not the badge that sends somebody there.
    ///
    /// Both were correct in isolation. What was wrong was that there were two.
    ///
    /// ONE OR ZERO, NEVER A COUNT. It is an alarm, not a status display — a
    /// reader with three problems does not need the number three, they need
    /// this tab.
    private var settingsBadge: Int {
        AppHealth.needsAttention(
            isConnected: auth.isConnected,
            syncError: activities.lastError,
            hasUnsavedStore: StoreWriteJournal.shared.hasUnsaved,
            hasUnreadableStore: StoreReadJournal.shared.hasUnreadable) ? 1 : 0
    }

    var body: some View {
        TabView(selection: $tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "figure.run") }
                .tag(Tab.today)

            WeekView()
                .tabItem { Label("Week", systemImage: "calendar") }
                .tag(Tab.week)

            PlanView()
                .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
                .tag(Tab.plan)

            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                .tag(Tab.progress)

            SettingsView(embedded: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(settingsBadge)
                .tag(Tab.settings)
        }
        .tint(.accent4)
        // THE RECEIPT IS PRESENTED HERE, at the root, and not by the pane that
        // asked for the delete — patch 186.
        //
        // Deleting local data removes `appearance.selected`, `volume.unit` and
        // two more display keys, invalidating every `@AppStorage` binding in
        // Settings. The Form rebuilds — repeatedly, not once — and a sheet
        // attached anywhere inside it is dismissed mid-animation. Two attempts
        // to hold it there failed; the third stopped trying. Nothing in that
        // rebuild reaches the TabView, so the sheet stays up.
        .sheet(item: Binding(get: { LifecycleLog.shared.pending },
                             set: { LifecycleLog.shared.pending = $0 })) { p in
            ReceiptSheet(receipt: p.receipt)
        }
        // WAS `.preferredColorScheme(.dark)` — the app was hard-locked to dark
        // at the root, which is why every colour in Theme.swift could be a
        // single constant. Removing the lock is the whole patch; the palette
        // work only matters because this line no longer forces one answer.
        .appearanceScheme()
        // Applies the protection class to files written before patch 190 —
        // DATA-05. Detached because it walks Application Support, and the main
        // actor has no business doing that at launch. Idempotent, so it runs
        // every time rather than behind a flag that could lie.
        .task {
            let n = await Task.detached(priority: .utility) {
                FileProtection.applyToExistingFiles()
            }.value
            if n > 0, FileProtection.lastError != nil {
                // Nothing user-facing: the privacy pane reads `lastError`
                // itself. This exists so a failure is not invisible in a debug
                // session either.
                print("[FileProtection] \(n) items, last error: \(FileProtection.lastError ?? "")")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Ask for the next background wake on the way out. Submitting again
            // replaces the pending request rather than stacking a second one,
            // so this is safe to call on every backgrounding.
            if phase == .background {
                BackgroundRefresh.schedule()
                // PATCH 302 — D6b. The one automatic trigger, deliberately.
                //
                // A whole-world run costs 0.325 s and copies everything, so a
                // missed trigger is LATE rather than a gap — which is why one
                // trigger is enough to start with, and why no dirty flag is
                // tracked. §12.46.
                //
                // The task may not finish if iOS suspends us first. That is
                // survivable: an interrupted run leaves a `running` row the
                // ledger already reports as "Interrupted runs", and the next
                // background does the work again.
                Task {
                    await DatabaseWriteThrough.shared
                        .run(reason: "the app went to the background")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
