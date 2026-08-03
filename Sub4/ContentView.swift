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
    private var settingsBadge: Int {
        (auth.isConnected && activities.lastError == nil) ? 0 : 1
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
        .onChange(of: scenePhase) { _, phase in
            // Ask for the next background wake on the way out. Submitting again
            // replaces the pending request rather than stacking a second one,
            // so this is safe to call on every backgrounding.
            if phase == .background { BackgroundRefresh.schedule() }
        }
    }
}

#Preview {
    ContentView()
}
