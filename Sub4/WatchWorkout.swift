//
//  WatchWorkout.swift
//  Sub4
//
//  The WorkoutKit bridge: PlanWorkout → CustomWorkout → the Watch.
//
//  ⚠️ THIS IS THE ONE FILE IN THE PROJECT WRITTEN WITHOUT VERIFICATION.
//
//  Everything else has been checked against real data. WorkoutKit can't be
//  compiled outside Xcode and Apple's documentation is JavaScript-rendered, so
//  the exact initialiser spellings below are from the framework's documented
//  shape rather than from a build. Expect to fix a name or two.
//
//  IT IS DELIBERATELY SELF-CONTAINED so that costs nothing: the mapping, the
//  scheduling and the button all live here. If it won't compile, delete this
//  file and remove the single `WatchWorkoutCard(...)` line from
//  WorkoutPreviewView. Nothing else references it and nothing else breaks.
//
//  THE RULE THIS MUST NOT BREAK
//  ----------------------------
//  n reps take n−1 floats. An IntervalBlock of [work, recovery] × n appends a
//  trailing recovery — an extra kilometre nobody asked for. That bug already
//  appeared once in the preview; the construction here splits the block in two
//  so it cannot come back.
//

import SwiftUI
import HealthKit
import WorkoutKit

// MARK: - Mapping

enum WatchWorkout {

    /// Name shown in the Watch's Upcoming list.
    ///
    /// `w.title` alone is useless there: week 1 is three sessions all titled
    /// "Easy", so the list reads Easy / Easy / Easy with no way to tell 5 km
    /// from 8 km. Day and distance make each one identifiable at a glance.
    static func displayName(for w: PlanWorkout, on dayKey: String?) -> String {
        var parts: [String] = []
        if let dayKey, let date = DayKey.date(dayKey) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "EEE"
            parts.append(f.string(from: date))
        }
        var name = w.title
        if let km = w.totalKm {
            name += String(format: " %g km", (km * 10).rounded() / 10)
        }
        parts.append(name)
        return parts.joined(separator: " · ")
    }

    /// Converts a parsed plan session into a WorkoutKit custom workout.
    static func custom(from w: PlanWorkout, named name: String? = nil) -> CustomWorkout {
        var blocks: [IntervalBlock] = []
        var warmup: WorkoutKit.WorkoutStep?
        var cooldown: WorkoutKit.WorkoutStep?

        for step in w.steps {
            switch step.kind {
            case .warmup:
                warmup = WorkoutKit.WorkoutStep(goal: goal(step.goal))
            case .cooldown:
                cooldown = WorkoutKit.WorkoutStep(goal: goal(step.goal))
            case .work:
                blocks.append(IntervalBlock(
                    steps: [IntervalStep(.work, goal: goal(step.goal),
                                         alert: alert(step.pace))],
                    iterations: 1))
            case .block:
                blocks.append(contentsOf: intervalBlocks(step))
            }
        }

        return CustomWorkout(activity: .running,
                             location: .outdoor,
                             displayName: name ?? w.title,
                             warmup: warmup,
                             blocks: blocks,
                             cooldown: cooldown)
    }

    /// n reps, n−1 floats. Expressed as [work, float] × (n−1) followed by a
    /// bare [work] × 1, because a single block repeated n times would end on a
    /// float.
    private static func intervalBlocks(_ step: PlanStep) -> [IntervalBlock] {
        let work = IntervalStep(.work, goal: goal(step.goal), alert: alert(step.pace))
        guard let recovery = step.recoveryGoal, step.iterations > 1 else {
            return [IntervalBlock(steps: [work], iterations: max(step.iterations, 1))]
        }
        let float = IntervalStep(.recovery, goal: goal(recovery),
                                 alert: alert(step.recoveryPace))
        return [
            IntervalBlock(steps: [work, float], iterations: step.iterations - 1),
            IntervalBlock(steps: [work], iterations: 1)
        ]
    }

    private static func goal(_ g: PlanStep.Goal) -> WorkoutGoal {
        switch g {
        case .distance(let km): return .distance(km, .kilometers)
        case .time(let secs):   return .time(Double(secs), .seconds)
        case .open:             return .open
        }
    }

    /// Pace band → speed range. WorkoutKit alerts on speed, so the FAST pace
    /// becomes the HIGH speed — inverting these would tell you to slow down
    /// when you're on target.
    private static func alert(_ pace: PlanStep.Pace?) -> (any WorkoutAlert)? {
        guard let pace, pace.fast > 0, pace.slow > 0 else { return nil }
        let fastMS = 1000.0 / Double(pace.fast)      // m/s at the quick end
        let slowMS = 1000.0 / Double(pace.slow)
        let lower = Measurement(value: min(fastMS, slowMS), unit: UnitSpeed.metersPerSecond)
        let upper = Measurement(value: max(fastMS, slowMS), unit: UnitSpeed.metersPerSecond)
        return SpeedRangeAlert(target: lower...upper, metric: .current)
    }
}

// MARK: - Scheduling

@Observable
final class WatchScheduler {

    static let shared = WatchScheduler()
    private init() {}

    private(set) var lastResult: String?
    private(set) var isWorking = false

    /// Apple syncs at most 15 scheduled workouts over a 7-day window.
    private let horizonDays = 7

    @MainActor
    func authorize() async -> Bool {
        let state = await WorkoutScheduler.shared.requestAuthorization()
        return state == .authorized
    }

    /// Pushes every parseable run session in the next seven days.
    @MainActor
    func syncUpcoming() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        guard await authorize() else {
            lastResult = "Not authorised. Watch app → Sub4 → allow scheduled workouts."
            return
        }

        let store = PlanStore.shared
        let today = DayKey.key()
        let end = DayKey.key(Calendar(identifier: .iso8601)
            .date(byAdding: .day, value: horizonDays, to: Date()) ?? Date())

        let planUids = Set(store.planWeeks.map(\.uid))
        let upcoming = store.plan.sessions
            .filter { s in
                s.discipline == .run && planUids.contains(s.weekUid)
                    && (s.date.map { $0 >= today && $0 <= end } ?? false)
            }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }

        // Replace rather than append — otherwise re-syncing stacks duplicates
        // of sessions that are already up there.
        await WorkoutScheduler.shared.removeAllWorkouts()

        var sent = 0, skipped = 0
        for session in upcoming {
            guard let parsed = WorkoutParser.parse(session).workout,
                  let day = session.date, let date = DayKey.date(day) else {
                skipped += 1
                continue
            }
            var when = Calendar.current.dateComponents([.year, .month, .day],
                                                       from: date)
            when.hour = 7                     // the Watch shows the day, not the hour
            when.minute = 0
            // schedule() doesn't throw — it either takes the workout or it
            // doesn't. The count is checked against the scheduler afterwards
            // rather than trusting this loop.
            let name = WatchWorkout.displayName(for: parsed, on: day)
            let plan = WorkoutPlan(.custom(WatchWorkout.custom(from: parsed, named: name)))
            await WorkoutScheduler.shared.schedule(plan, at: when)
            sent += 1
        }

        // Read back what the Watch actually holds rather than reporting what we
        // asked for. If Apple's 15-workout ceiling or a validation rejection
        // silently drops one, this is the only way to notice.
        let actual = await WorkoutScheduler.shared.scheduledWorkouts.count

        if sent == 0 {
            lastResult = "Nothing to send — no structured runs in the next \(horizonDays) days."
        } else if actual < sent {
            lastResult = "\(actual) of \(sent) accepted — the Watch refused \(sent - actual)."
        } else {
            lastResult = "\(actual) workout\(actual == 1 ? "" : "s") on the Watch"
                + (skipped > 0 ? " · \(skipped) left to feel" : "")
        }
    }
}

// MARK: - The one view that surfaces it
//
// Kept here so the whole feature is one deletable file.

struct WatchWorkoutCard: View {

    let workout: PlanWorkout?

    @State private var scheduler = WatchScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await scheduler.syncUpcoming() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch.and.arrow.forward")
                    Text("Send this week to the Watch")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if scheduler.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }
                .foregroundStyle(Color.accent4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(scheduler.isWorking)

            if let r = scheduler.lastResult {
                Text(r).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sends every structured run in the next 7 days. They appear "
                     + "in the Watch's own Workout app under Sub4.")
                    .font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
