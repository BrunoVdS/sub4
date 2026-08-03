//
//  BackgroundRefresh.swift
//  Sub4
//
//  Pulls new Strava activities while the app is closed.
//
//  WHAT THIS IS AND ISN'T
//  ----------------------
//  BGAppRefreshTask is OPPORTUNISTIC. `earliestBeginDate` is a floor, not a
//  schedule — iOS decides when to actually run it, learning from when you open
//  the app. In practice that's a handful of times a day, and it will NOT pick a
//  run up minutes after you finish it. It also never fires if the app has been
//  force-quit from the app switcher, and it's suppressed in Low Power Mode.
//
//  So this closes the gap from "only when I open the app" to "usually already
//  up to date when I open the app". Near-instant would need Strava webhooks
//  into a server endpoint and a silent push back to the phone, and silent push
//  needs a paid developer account.
//
//  THE 30-SECOND BUDGET
//  --------------------
//  A background refresh gets roughly half a minute before iOS kills it. The
//  foreground drain does up to 30 activities at 250 ms apart — minutes of work.
//  So the background path takes the activity list plus at most three detail
//  fetches, and leaves the rest of the queue for the next foreground launch.
//  Overrunning doesn't just fail; repeated overruns make iOS schedule the app
//  less often.
//
//  Every run records what it did, because otherwise there is no way to tell a
//  working background refresh from one that never fires — see Settings.
//

import Foundation
import BackgroundTasks

enum BackgroundRefresh {

    /// Must match the string in Info.plist under
    /// BGTaskSchedulerPermittedIdentifiers, exactly. A mismatch makes submit()
    /// throw, which is recorded and shown in Settings rather than swallowed.
    static let taskId = "be.sub4.refresh"

    /// Activities to fetch detail for per background run. Three is about eight
    /// seconds of network in the worst case, well inside budget.
    private static let backgroundDetailLimit = 3

    private static let lastRunKey    = "bg.lastRun"
    private static let runCountKey   = "bg.runCount"
    private static let lastResultKey = "bg.lastResult"
    private static let scheduleErrKey = "bg.scheduleError"

    // MARK: Diagnostics

    static var lastRun: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }
    static var runCount: Int {
        UserDefaults.standard.integer(forKey: runCountKey)
    }
    static var lastResult: String? {
        UserDefaults.standard.string(forKey: lastResultKey)
    }
    static var scheduleError: String? {
        UserDefaults.standard.string(forKey: scheduleErrKey)
    }

    // MARK: Scheduling

    /// Call when the app goes to the background. Submitting again replaces the
    /// pending request rather than queueing a second one.
    static func schedule(after seconds: TimeInterval = 2 * 3600) {
        // Patch 178, plan step 0.3. Nothing is scheduled while the gate is
        // closed, so the app does not sit in iOS's queue asking to be woken for
        // work it will then refuse to do. Any request already pending from
        // before the gate closed still fires — `run` below is the check that
        // catches it.
        guard ReleaseGates.isOpen(.stravaBackground) else { return }

        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.removeObject(forKey: scheduleErrKey)
        } catch {
            // Almost always one thing: the identifier isn't in Info.plist under
            // BGTaskSchedulerPermittedIdentifiers, or Background Modes →
            // Background fetch isn't enabled on the target.
            UserDefaults.standard.set(readable(error), forKey: scheduleErrKey)
        }
    }

    /// Domain and codes written out literally rather than via
    /// BGTaskScheduler.Error.Code. That type is an NS_ERROR_ENUM whose Swift
    /// spelling has moved around between SDKs; the domain string and the
    /// integers have not.
    /// Earliest time iOS will consider running the pending request, or nil if
    /// nothing is queued at all.
    ///
    /// This is the half the run counters can't tell you. A counter stuck at 0
    /// means either "iOS hasn't got round to it" or "there is nothing to get
    /// round to" — completely different problems. If this returns nil, the app
    /// has never been backgrounded since launch, or submit() failed.
    ///
    /// Uses the completion-handler API on purpose: the async spelling of this
    /// one has moved between SDK versions, the callback form hasn't.
    static func nextScheduled() async -> Date? {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                let date = requests
                    .first { $0.identifier == taskId }?
                    .earliestBeginDate
                continuation.resume(returning: date)
            }
        }
    }

    private static func readable(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == "BGTaskSchedulerErrorDomain" else {
            return ns.localizedDescription
        }
        switch ns.code {
        case 1:     // unavailable
            return "Background App Refresh is switched off — iOS Settings → "
                 + "General → Background App Refresh, and check Sub4's own "
                 + "entry in Settings."
        case 2:     // tooManyPendingTaskRequests
            return "Too many pending requests."
        case 3:     // notPermitted
            return "Not permitted — add \"\(taskId)\" to "
                 + "BGTaskSchedulerPermittedIdentifiers in Info.plist and turn "
                 + "on Background Modes → Background fetch on the target."
        default:
            return ns.localizedDescription
        }
    }

    // MARK: The run

    /// `manual` only changes the recorded label, so a hand-triggered run in
    /// Settings can never be mistaken for evidence that iOS scheduling works.
    @MainActor
    static func run(manual: Bool = false) async {
        // Reschedule FIRST. A task does not repeat itself, and if the work
        // below throws or gets killed, an unscheduled chain never restarts —
        // the feature would quietly stop working after one run. `schedule()` is
        // itself gated, so when the switch is off this is a no-op and the chain
        // is deliberately allowed to end.
        schedule()

        // A request submitted before the gate closed still wakes the app. Refuse
        // here as well, and record it, so the Settings diagnostics say "off"
        // rather than "0 new activities" — which is the same sentence the app
        // would print after a successful run that found nothing.
        guard ReleaseGates.isOpen(.stravaBackground) else {
            UserDefaults.standard.set("Off — \(ReleaseGate.stravaBackground.title) "
                                      + "is switched off.", forKey: lastResultKey)
            return
        }

        let before = ActivityStore.shared.count
        await ActivityStore.shared.sync()

        if !Task.isCancelled {
            await DetailStore.shared.drain(limit: backgroundDetailLimit,
                                           pause: .milliseconds(50))
        }

        let found = ActivityStore.shared.count - before
        record(found: found, cancelled: Task.isCancelled, manual: manual)
    }

    private static func record(found: Int, cancelled: Bool, manual: Bool) {
        let d = UserDefaults.standard
        d.set(Date(), forKey: lastRunKey)
        // Only real wake-ups count. A manual run proves the WORK is sound; it
        // proves nothing about whether iOS ever calls us, which is the thing
        // this counter exists to answer.
        if !manual {
            d.set(d.integer(forKey: runCountKey) + 1, forKey: runCountKey)
        }

        var text: String
        if let e = ActivityStore.shared.lastError {
            text = "failed — \(e)"
        } else if found > 0 {
            text = "\(found) new activit\(found == 1 ? "y" : "ies")"
        } else {
            text = "nothing new"
        }
        if cancelled { text += " (ran out of time)" }
        text += manual ? " · manual" : " · from iOS"
        d.set(text, forKey: lastResultKey)
    }
}
