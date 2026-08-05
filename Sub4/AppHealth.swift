//
//  AppHealth.swift
//  Sub4
//
//  One definition of "something needs your attention" — patch 279, §12.25.
//
//  WHY THIS EXISTS: THE TWO ANSWERS DISAGREED
//  ------------------------------------------
//  The same question was asked in two places and answered differently.
//
//    ContentView.settingsBadge   the red dot on the gear
//    SettingsView.needsAttention the highlight inside the pane
//
//  Patch 273 added `StoreReadJournal.hasUnreadable` to the second and not the
//  first. So a store the app could not read lit the row INSIDE Settings and
//  not the badge whose entire job is to send somebody there.
//
//  That is worse than it sounds, because of what the badge is for. Its own
//  comment: "This app derives COMPLETION from Strava: if the token expires and
//  nothing says so, every session quietly renders as not-done and it reads as
//  missed training rather than as a broken sync. It is an alarm, not a status
//  display, and it sits on the tab that can fix it." An unreadable store is
//  exactly that alarm — the app showing LESS than it holds — and it was wired
//  to the quieter of the two places.
//
//  A TEST WOULD NOT HAVE CAUGHT IT, AND THAT IS THE POINT
//  ------------------------------------------------------
//  Both expressions were correct in isolation. What was wrong was that there
//  were two of them. So the fix is not a test but a shape: one function, two
//  callers, and a fourth condition can no longer be added to one and forgotten
//  in the other.
//
//  It takes its inputs rather than reading the singletons, for two reasons.
//  The two callers observe their own `StravaAuth` and `ActivityStore`, so
//  reaching for `.shared` here would quietly bypass SwiftUI's observation and
//  stop the badge updating. And a function with four `Bool` parameters is
//  testable, which the two expressions it replaces were not — both were
//  `private var` on a `View`.
//

import Foundation

nonisolated enum AppHealth {

    /// True when something is wrong that the athlete can act on.
    ///
    /// THE ORDER IS SEVERITY, and it is worth reading as a sentence: the
    /// connection is broken, or the last sync failed, or the app holds more
    /// than it has saved, or the app is showing less than it holds.
    static func needsAttention(isConnected: Bool,
                               syncError: String?,
                               hasUnsavedStore: Bool,
                               hasUnreadableStore: Bool) -> Bool {
        !isConnected
            || syncError != nil
            || hasUnsavedStore
            || hasUnreadableStore
    }
}
