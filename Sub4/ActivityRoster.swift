//
//  ActivityRoster.swift
//  Sub4
//
//  The rules that decide what the activity list IS — D6c step 2, patch 310.
//  ADR-0003 §12.54.
//
//  WHY THIS IS A TYPE RATHER THAN THREE PRIVATE METHODS
//  -----------------------------------------------------
//  `ActivityStore` holds a list, and what is in that list is decided by three
//  rules: which activities are kept, which pairs are one session uploaded
//  twice, and what order they are in. Until 309 those rules lived as `private`
//  methods and were applied differently at the store's two entrances — which
//  is exactly the drift that private-and-untestable invites.
//
//  D6c has to compare what the app COMPUTES from two sources, not just what it
//  stores. That means the database side needs to produce the same list from the
//  same rules. Two implementations of one rule is the mistake §12.43 cost three
//  patches to learn: **when two things must agree, do not reimplement — call.**
//
//  `@MainActor`, because `isKept` reads `MatchRules` and `DataCorrections` and
//  both are MainActor-isolated like everything else in this target. See the
//  note in `isKept` about spelling the predicate as a closure literal.
//
//  IT COUNTS WHAT IT DID
//  ---------------------
//  `Result` carries how many were offered, dropped, collapsed and whether they
//  arrived in order. Not decoration: a rule that silently removes rows needs a
//  number beside it, and 309 shipped those numbers hidden behind "only when
//  non-zero" — which made a working counter and an unwired one look identical.
//  §12.54.2.
//

import Foundation

@MainActor
enum ActivityRoster {

    /// What settling a list of activities produced, and what it cost.
    struct Result: Equatable {

        /// Kept, de-duplicated, newest first by LOCAL start.
        let activities: [Activity]

        /// How many came in, before any rule ran. The denominator — without it
        /// "0 collapsed" and "nothing was looked at" read the same.
        let offered: Int

        /// Removed by `isKept`: before the cutoff, an excluded recording, a
        /// speed contradiction.
        let dropped: Int

        /// Removed by `dedup` — the same session uploaded from two devices.
        let collapsed: Int

        /// Whether the input was already newest-first once filtered.
        ///
        /// MEANINGFUL ONLY FOR AN ORDERED SOURCE. `ingest` settles a
        /// dictionary's values, whose order is arbitrary, so this says nothing
        /// there and the store ignores it. `load` reads a file that something
        /// wrote deliberately, and there it is a real fact.
        let arrivedOutOfOrder: Bool

        /// One row's worth. Always says all three, including the zeros —
        /// see the header.
        var summary: String {
            "\(activities.count) · \(collapsed) collapsed · "
            + (arrivedOutOfOrder ? "re-ordered" : "in order")
        }

        /// For the redacted paste. Counts only — no names, no dates, nothing
        /// from the athlete's history.
        ///
        /// UNCONDITIONAL, like `StoreWriteJournal`'s and `StoreReadJournal`'s.
        /// 266c wrote the reason and 273 repeated it: *a line that only appears
        /// when something is wrong cannot be distinguished from a line nobody
        /// wired in.*
        var diagnosticLines: [String] {
            ["Activity roster: \(activities.count) kept of \(offered) offered",
             "  dropped by the rules: \(dropped)",
             "  collapsed as duplicates: \(collapsed)",
             "  arrived out of order: \(arrivedOutOfOrder ? "yes" : "no")"]
        }
    }

    // MARK: The whole thing, in one call

    /// Filter, de-duplicate, order. **Both of `ActivityStore`'s entrances call
    /// this**, which is the property 309 established and this makes structural
    /// rather than remembered.
    static func settle(_ input: [Activity]) -> Result {
        let kept = input.filter { isKept($0) }

        // Measured on the FILTERED list, not the raw one. A row the rules drop
        // is not evidence about whether the file was written in order.
        let ordered = kept.sorted { $0.startLocal > $1.startLocal }
        let outOfOrder = ordered.map(\.id) != kept.map(\.id)

        let settled = dedup(kept).sorted { $0.startLocal > $1.startLocal }

        return Result(activities: settled,
                      offered: input.count,
                      dropped: input.count - kept.count,
                      collapsed: kept.count - settled.count,
                      arrivedOutOfOrder: outOfOrder)
    }

    // MARK: The day index

    /// THE DAY BUCKETS — patch 168, moved here at 312.
    ///
    /// It was one line in `ActivityStore`'s `didSet`, which was the right place
    /// while there was one caller. D6c's twin needs the same buckets built from
    /// the database, and **one line copied twice is still two implementations**
    /// — §12.43, the same argument that moved `isKept` and `dedup` here at 310.
    ///
    /// `Dictionary(grouping:)` PRESERVES ENCOUNTER ORDER, so each day's bucket
    /// inherits the newest-first order of the list it is given. Patch 168's
    /// comment says callers depend on that, which means the property is part of
    /// what this function promises rather than an accident of the standard
    /// library — and it is why the parity comparison checks each day's SEQUENCE
    /// rather than each day's set.
    ///
    /// Takes a list rather than a `Result`, because the store's `didSet` also
    /// fires on `activities = []`, where no `Result` exists.
    static func byDay(_ activities: [Activity]) -> [String: [Activity]] {
        Dictionary(grouping: activities, by: \.dayKey)
    }

    // MARK: The three rules

    /// THE ONE GATE, APPLIED WHEREVER AN ACTIVITY ARRIVES — patch 123, moved
    /// here at 310.
    ///
    /// Two doors lead into `activities`: the network, through `ingest`, and
    /// activities.json, through `load`. The filter used to live in `ingest`
    /// only, which was fine while it was made of constants that never changed
    /// after a row was written — but `DataCorrections.ignoredActivities` does
    /// change, and a row already on disk would have walked straight past a rule
    /// added after it was cached.
    ///
    /// Everything after the cutoff is kept — walks, commutes, the kayak. Only
    /// *matching* is filtered (`Activity.isPlanEligible`), so total movement
    /// volume stays honest.
    ///
    /// Four rules, and each is reported somewhere: the cutoff in Settings, the
    /// minimum duration nowhere yet, the named exclusions in "Ignored
    /// recordings", the speed contradictions in "Rejected — speed
    /// contradiction". `Result.dropped` is the first number that covers all
    /// four at once.
    ///
    /// SPELL THE PREDICATE AS A CLOSURE LITERAL at call sites —
    /// `{ isKept($0) }`, not `isKept`. This reads `MatchRules` and
    /// `DataCorrections`, which are MainActor-isolated, and handing it to
    /// `filter` as a function VALUE strips that isolation.
    static func isKept(_ a: Activity) -> Bool {
        guard a.dayKey >= MatchRules.cutoffDayKey else { return false }
        guard a.movingTime >= MatchRules.minAnyActivitySeconds else { return false }
        // Named, with the reason, in DataCorrections — and reported in
        // Settings, because a recording the app throws away without saying so
        // is indistinguishable from one it failed to fetch.
        guard !DataCorrections.isIgnored(a) else { return false }
        // The rule, not a list. See `Activity.selfContradictoryDistance` for the
        // three rides that produced it and why the threshold is 1.5×.
        guard !a.selfContradictoryDistance else { return false }
        return true
    }

    /// ORDER-INDEPENDENT BY CONSTRUCTION. It sorts ascending before it walks,
    /// so the survivor of a near-duplicate pair does not depend on the order
    /// the caller happened to hand them over in. That is the property
    /// `bothDoorsAgree` pins, and the one a reimplementation would break
    /// silently.
    static func dedup(_ input: [Activity]) -> [Activity] {
        var kept: [Activity] = []
        for a in input.sorted(by: { $0.startLocal < $1.startLocal }) {
            if let i = kept.firstIndex(where: { isDuplicate($0, a) }) {
                if a.movingTime > kept[i].movingTime { kept[i] = a }
            } else {
                kept.append(a)
            }
        }
        return kept
    }

    /// Two activities of the same sport starting within
    /// `MatchRules.duplicateWindowMinutes` of each other, with similar
    /// distance, are the same session uploaded twice. Real case: 21 Apr 2026,
    /// two rides at an identical start time, 61.7 km and 60.4 km, two devices.
    static func isDuplicate(_ a: Activity, _ b: Activity) -> Bool {

        guard a.sportType == b.sportType, a.dayKey == b.dayKey else { return false }
        guard abs(a.startMinuteOfDay - b.startMinuteOfDay)
                <= MatchRules.duplicateWindowMinutes else { return false }
        let bigger = max(a.distance, b.distance)
        guard bigger > 0 else { return true }
        return abs(a.distance - b.distance) / bigger <= MatchRules.duplicateDistanceTolerance
    }
}
