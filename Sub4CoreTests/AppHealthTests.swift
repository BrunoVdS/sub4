//
//  AppHealthTests.swift
//  Sub4CoreTests
//
//  One definition of "needs attention" — patch 279, ADR-0003 §12.25.
//
//  THESE TESTS DID NOT EXIST AND COULD NOT HAVE. The rule lived twice, as a
//  `private var` on two different `View`s, and neither was reachable. The bug
//  they now cover was not a wrong expression — both were correct — it was that
//  there were two of them, and 273 updated one.
//
//  So the assertion that matters is `everyConditionRaisesTheAlarm`: it walks
//  all four one at a time, and it fails the day a fifth is added to the
//  function and forgotten in the parameter list.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct AppHealthTests {

    private func health(connected: Bool = true,
                        error: String? = nil,
                        unsaved: Bool = false,
                        unreadable: Bool = false) -> Bool {
        AppHealth.needsAttention(isConnected: connected,
                                 syncError: error,
                                 hasUnsavedStore: unsaved,
                                 hasUnreadableStore: unreadable)
    }

    @Test("A healthy app raises nothing")
    func healthyIsSilent() {
        #expect(health() == false)
    }

    /// THE ONE THAT MATTERS. Each condition, alone.
    @Test("Every condition raises the alarm on its own")
    func everyConditionRaisesTheAlarm() {
        #expect(health(connected: false), "a broken connection")
        #expect(health(error: "Strava timed out."), "a failed sync")
        #expect(health(unsaved: true), "a store the app could not save")
        // THE ONE 273 ADDED TO ONLY ONE OF THE TWO PLACES. The app showing
        // LESS than it holds is the worse of the two journals and was the
        // quieter of the two signals.
        #expect(health(unreadable: true), "a store the app could not read")
    }

    @Test("An empty error string is still an error")
    func anEmptyErrorIsStillAnError() {
        // `syncError` is optional and NOT checked for emptiness on purpose:
        // "something was reported" is the fact, and a provider that hands back
        // an empty message has still failed.
        #expect(health(error: ""))
    }

    @Test("Several at once is still one alarm")
    func severalAtOnceIsOneAlarm() {
        // The badge is an alarm, not a count — `settingsBadge` returns 1 or 0
        // and never 3. Recorded here because the obvious "improvement" is to
        // count them, and a reader who has three problems does not need a
        // number, they need the tab.
        #expect(health(connected: false, error: "x", unsaved: true, unreadable: true))
    }
}
