//
//  ReviewDue.swift
//  Sub4
//
//  Whether the monthly review is worth opening right now.
//
//  WHY THIS EXISTS
//  ---------------
//  The review was a permanent card on the Progress tab, and for the first six
//  weeks of a 34-week block it said "Available once the first plan week has
//  ended". A row that is present, tappable, and inert is worse than absent: it
//  trains you to scroll past the place where the real thing will eventually
//  appear, and by the time it appears you have stopped reading it.
//
//  It is also the only thing on Progress you ACT on rather than read. Everything
//  else there is a trend you glance at. So it does not belong in the same
//  reading flow at all — it belongs where the app puts things that want doing,
//  which is the top of Today, and only on the days it wants doing.
//
//  THE RULE
//  --------
//  Due when four plan weeks have finished and either no review has ever been
//  run, or the last one was 28 or more days ago.
//
//  Four weeks because that is the window `ReviewBuilder` reads — a review over
//  two weeks is a review of noise. 28 days rather than a calendar month so the
//  cadence does not drift with the length of February, and because the plan
//  runs in weeks, not months.
//
//  NOT A NOTIFICATION
//  ------------------
//  No badge, no push, no red dot. A banner at the top of a screen you open every
//  morning is enough for something that is due within a fortnight-wide window,
//  and anything louder would be the app asking for attention it has not earned.
//
//  WHEN IT IS BLOCKED, IT SAYS WHY
//  -------------------------------
//  A review that cannot reach a conclusion still has to explain itself — the
//  athlete's question is "should I look at this", and "not yet, three of four
//  weeks" answers it. That is the state the old placeholder was trying to
//  express and got wrong by expressing it permanently.
//

import Foundation

enum ReviewDue {

    /// The window `ReviewBuilder` reads. Fewer finished weeks than this and
    /// there is nothing for it to average over.
    static let minWeeks = 4

    /// Days between reviews. Not a calendar month: the plan runs in weeks, and
    /// a monthly cadence drifts against them.
    static let intervalDays = 28

    enum State: Equatable {
        /// Not enough finished plan weeks yet.
        case tooEarly(finished: Int)
        /// Ready and never run, or run long enough ago.
        case due(String)
        /// Run recently. Carries the day the next one falls.
        case recent(ranAt: Date, nextDue: Date)

        var isDue: Bool { if case .due = self { return true }; return false }
    }

    /// Plan weeks whose last dated session is strictly before today — the same
    /// test `ReviewBuilder.build` applies, so the two can never disagree about
    /// whether there is anything to review.
    static func finishedWeeks(today: String = DayKey.key()) -> Int {
        let plan = PlanStore.shared
        return plan.planWeeks.filter { w in
            let days = plan.sessions(inWeek: w).compactMap(\.date)
            guard let last = days.max() else { return false }
            return last < today
        }.count
    }

    static func state(today: String = DayKey.key(), now: Date = Date()) -> State {
        let finished = finishedWeeks(today: today)
        guard finished >= minWeeks else { return .tooEarly(finished: finished) }

        guard let last = ProposalStore.shared.newestFirst.first?.ranAt else {
            return .due("Four plan weeks are finished and no review has been run.")
        }

        let next = Calendar(identifier: .iso8601)
            .date(byAdding: .day, value: intervalDays, to: last) ?? last
        if now >= next {
            let days = Int(now.timeIntervalSince(last) / 86_400)
            return .due("\(days) days since the last review.")
        }
        return .recent(ranAt: last, nextDue: next)
    }

    /// One line for a card subtitle, when the card is shown at all.
    static func subtitle(_ state: State) -> String {
        switch state {
        case .tooEarly(let finished):
            let need = minWeeks - finished
            return "Not yet — \(finished) of \(minWeeks) plan weeks finished, "
                 + "\(need) to go."
        case .due(let why):
            return why
        case .recent(let ranAt, let nextDue):
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return "Last run \(f.localizedString(for: ranAt, relativeTo: Date()))"
                 + " · next \(DayKey.short(nextDue))"
        }
    }
}
