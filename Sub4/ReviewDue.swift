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

        // A REHEARSAL IS NOT A REVIEW — patch 353, ADR-0003 §12.98.
        //
        // This read `newestFirst.first` and counted the six rehearsal records
        // written on 9 August 2026. `.tooEarly` was hiding it: on 24 August
        // the fourth plan week finishes, this guard finds `ranAt: 2026-08-09`,
        // and returns `.recent(nextDue: 6 September)`. The banner never
        // appears and nothing says why — and "nothing says why" is the part
        // that makes it worse than a crash.
        //
        // THE STORE IS READ HERE; THE RULE IS APPLIED IN A PURE FUNCTION.
        // `state` cannot be tested without the two singletons it reads, and
        // `newestReal(in:)` can. It takes its records as an argument WITH NO
        // DEFAULT — 350a's lesson, where a defaulted `PlanStore = .shared` was
        // a call site carrying a value no caller wrote and no grep could find.
        guard let last = newestReal(in: ProposalStore.shared.newestFirst)?.ranAt
        else {
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

    // MARK: Rehearsals — patch 353, ADR-0003 §12.98

    /// The records this gate is allowed to count. Order is the caller's; this
    /// preserves whatever it is given.
    static func realReviews(in records: [ProposalStore.Record])
    -> [ProposalStore.Record] {
        records.filter { !$0.isRehearsal }
    }

    static func rehearsals(in records: [ProposalStore.Record])
    -> [ProposalStore.Record] {
        records.filter { $0.isRehearsal }
    }

    /// The newest record that is not a rehearsal, given a newest-first list.
    /// The one function `state` depends on, and the reason it is separate.
    static func newestReal(in records: [ProposalStore.Record])
    -> ProposalStore.Record? {
        records.first { !$0.isRehearsal }
    }

    /// Non-nil ONLY while rehearsal records are stored.
    ///
    /// CONDITIONAL, and deliberately unlike everything §12.54.2 governs. This
    /// is an ACTION ITEM on the athlete's morning screen: a card reading
    /// "0 rehearsals stored" every day for thirty-four weeks is precisely the
    /// permanent inert row this file's header was written to argue against.
    /// The unconditional form is `rehearsalLine`, which goes in the paste,
    /// where "0" is evidence rather than furniture.
    static func rehearsalWarning(in records: [ProposalStore.Record],
                                 today: String = DayKey.key()) -> String? {
        let n = rehearsals(in: records).count
        guard n > 0 else { return nil }
        let noun = n == 1 ? "record is" : "records are"
        if today < ReviewRehearsal.mustGoBefore {
            return "\(n) rehearsal \(noun) stored. Delete them on Progress "
                 + "before \(ReviewRehearsal.mustGoBeforeLabel) — until then "
                 + "everything that counts reviews is counting them."
        }
        return "\(n) rehearsal \(noun) still stored and the first real review "
             + "is already due. Delete them on Progress."
    }

    /// UNCONDITIONAL — §12.54.2. "0 stored" is the sentence that proves they
    /// went; a line that appeared only while some were left could not be told
    /// from a line nobody wired in. It is also the number that decides whether
    /// `review: 6` in the table census is six reviews or six rehearsals.
    static func rehearsalLine(in records: [ProposalStore.Record]) -> String {
        let n = rehearsals(in: records).count
        guard n > 0 else {
            return "Review rehearsals stored: 0 — none, and the gate no longer "
                 + "counts them"
        }
        return "Review rehearsals stored: \(n) — must be gone before "
             + "\(ReviewRehearsal.mustGoBeforeLabel)"
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
