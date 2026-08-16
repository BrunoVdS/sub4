//
//  ActivityParity.swift
//  Sub4
//
//  D6c slice 1 — the twin, and the first comparison. Patch 312,
//  `D6C-SHADOW-PARITY-GROUNDWORK.md` §2, §4, §6.1, ADR-0003 §12.56.
//
//  THE QUESTION, AND HOW IT DIFFERS FROM THE THREE ABOVE IT
//  -------------------------------------------------------
//  D6a's read-backs ask: *do both sides hold the same records?* Answered — 672
//  activities, 672 details, 649 recordings, 1,412,819 samples, every field
//  compared by name.
//
//  This asks: *if the app DERIVED its screens from the database instead of the
//  files, would it produce the same list?* Same activities, in the same order,
//  in the same day buckets, on the same clocks.
//
//  Those are different questions. Equal records do not imply equal derivation,
//  because five rules stand between the rows and the list — and it is the
//  DERIVED list that every screen in this app actually reads.
//
//  IT DOES NOT RE-CHECK FIELDS, AND THAT IS DELIBERATE
//  ---------------------------------------------------
//  `ActivityRoundTrip.differingFields` compares nineteen named fields, one
//  activity at a time, and it already runs on this screen. A second comparison
//  of the same thing would eventually disagree with the first, and then neither
//  could be believed. §12.43: **when two things must agree, do not reimplement
//  — call.**
//
//  So this compares only what D6a cannot see: identity as a SET after the
//  rules, ORDER, day MEMBERSHIP, and the zones.
//
//  THE TWIN REIMPLEMENTS NOTHING
//  -----------------------------
//  `ActivityRepository.all(db)` produces `[Activity]`; `ActivityRoster.settle`
//  turns a `[Activity]` into the list. Both sides call the SAME `settle`, the
//  SAME `byDay`, the SAME `DayZones.from`. There is one implementation of every
//  rule in this comparison, which is the property 309, 310 and this patch were
//  built in sequence to establish.
//
//  A row the rules refuse therefore appears as `databaseDropped`, NOT as a
//  difference — because the twin drops it exactly as the store would. That
//  number is the first instrument this project has for §12.46.3's known gap:
//  automatic write-throughs do not reconcile, so a record deleted in the app
//  stays in the database until somebody presses Import.
//
//  WHY THERE IS NO APPROVED-DIFFERENCE LIST HERE
//  ---------------------------------------------
//  Groundwork §5 defines one, and both of its entries are about details and
//  recordings. For activities the expected count is zero, so nothing is
//  filtered out and any number above zero is real. Building an empty
//  suppression list before there is anything to suppress would be a gate
//  nothing has passed through.
//
//  WHAT MAKES A ZERO BELIEVABLE — groundwork §2.1
//  ----------------------------------------------
//  A check whose answer is always "no differences" cannot be told from a check
//  that is broken, and D7 would be flipped on the strength of it. Three things
//  answer that, and each has its honest limit:
//
//    1. `ActivityParityTests` hands the comparison lists that differ by one
//       dropped activity, one swapped pair, one activity moved to another day
//       and one changed offset — built through the real importer and the real
//       repository, not hand-assembled. Runs on every build. This is the test
//       button.
//    2. `common` is on screen beside every count. Zero compared to zero agrees
//       perfectly and means nothing, and `lookedAtSomething` is what says so.
//    3. Both sides being secretly the same object is caught by constructing
//       them from different places and by reading the code. Named here so it
//       is not mistaken for covered.
//
//  A green tick that means nothing is worse than no tick.
//
//  IT NO LONGER RUNS ITSELF — patch 313
//  ------------------------------------
//  312 put `Outcome` and `run` here, because there was one slice. Slice 2 needs
//  the same database read and the same `settle`, so both moved to
//  `ShadowParity`: one read, one settle, every slice, and a result that
//  survives the sheet being dismissed. What is left is a pure comparison of two
//  `[Activity]` — which is what lets a test build its two sides from genuinely
//  different places.
//

import Foundation

// MARK: - The app's own side, read for itself — patch 381

/// `activities.json`, read WITHOUT asking `ActivityStore.shared` — D7 slice
/// B3, ADR-0003 §12.125.
///
/// **WHY.** 382 hydrates `ActivityStore` from the database. Every comparison
/// that takes its app side from that store would then hold the same rows on
/// both sides: agreeing perfectly, proving nothing, and saying so nowhere.
/// §12.101 is this exact patch for the authored families one slice ago, and
/// §12.91 is it for the plan two slices before that.
///
/// **IT IS NOT A SECOND DECODER**, which is 364's rule and the reason this is
/// eleven lines rather than a parser. `ActivityStore(directory:)` is the seam
/// patch 378 added: it reads `activities.json` with the bare `JSONDecoder`
/// that file is written with (§12.122.4), settles the result through
/// `ActivityRoster` exactly as the singleton does, and records nothing to the
/// shared read journal. One decoder, one set of rules, two roots.
///
/// **IT ANSWERS IN THREE STATES, NOT TWO.** A container the app cannot reach
/// and a device that has never synced both produce an empty array, and §12.15
/// is that those are opposite facts. `directoryFound` and `load` keep them
/// apart, and `line` says which out loud.
///
/// LIVES IN THIS FILE rather than its own, deliberately: a new Swift file is
/// invisible to the app target until Xcode is quit and reopened (CLAUDE.md §3),
/// and this is eleven lines that only `ShadowParity` calls.
@MainActor
enum ActivitySource {

    struct Read {
        /// Settled by the store's own `load`, so this is the list the app
        /// would show — not the file's raw contents.
        let activities: [Activity]
        /// What that load kept and dropped. Nil when there was no file.
        let roster: ActivityRoster.Result?
        /// `.absent` is a clean read of nothing; `.unreadable` is not.
        let load: StoreLoad
        /// Nil container. Distinct from `.absent`: one says the file is not
        /// there, the other says the app cannot look. §12.15.
        let directoryFound: Bool

        var isTrustworthy: Bool { directoryFound && load.isTrustworthy }

        /// Printed unconditionally, and it is the sentence every count under
        /// it means. A comparison that does not say where its own side came
        /// from cannot be checked by anybody who was not holding the phone.
        var line: String {
            guard directoryFound else {
                return "Application Support is unreachable, so the app side "
                     + "was not read at all"
            }
            guard load.isTrustworthy else {
                return "activities.json could not be read, so the app's own "
                     + "store was compared instead"
            }
            return "activities.json, read directly"
        }
    }

    /// `AppSupportItem.container` and not a tenth copy of the
    /// `applicationSupportDirectory` incantation — 356a's correction, and its
    /// own doc's reason: *nil is a real answer*.
    static func read() -> Read {
        guard let dir = AppSupportItem.container else {
            return Read(activities: [], roster: nil, load: .absent,
                        directoryFound: false)
        }
        let store = ActivityStore(directory: dir)
        return Read(activities: store.activities, roster: store.loadRoster,
                    load: store.lastLoad, directoryFound: true)
    }
}

@MainActor
enum ActivityParity {

    // MARK: The report

    struct Report: Equatable {

        // The denominators — groundwork §2.1 case 2. Without these, "no
        // differences" and "nothing was examined" read identically.

        /// What the app currently holds.
        let storeCount: Int
        /// Rows `ActivityRepository` returned, before any rule ran.
        let databaseOffered: Int
        /// Rows in the table the reader could not turn into an `Activity`.
        /// Zero on a healthy database; see `ActivityRepository`'s header.
        let databaseSkipped: Int
        /// What the SAME rules make of those rows.
        let databaseKept: Int
        /// Refused by `isKept`. NOT a difference — the twin drops what the
        /// store would drop. A number here is §12.46.3's gap made visible:
        /// rows the app no longer wants, still in the database because
        /// automatic runs do not reconcile.
        let databaseDropped: Int
        /// Collapsed by `dedup` on the database side.
        let databaseCollapsed: Int

        // Identity

        /// In the app's list and not in the twin.
        let storeOnly: [String]
        /// In the twin and not in the app's list.
        let databaseOnly: [String]
        /// How many activities were actually compared. THE denominator.
        let common: Int

        // Order

        /// Positions compared — the common ids, in each side's own order.
        let orderCompared: Int
        let orderDiffered: Int
        /// Where it first went wrong, so a disagreement leads somewhere.
        let firstOrderDisagreement: Int?

        // Day grouping

        let daysCompared: Int
        let daysOnlyInStore: [String]
        let daysOnlyInDatabase: [String]
        /// Days both sides have, holding a different SEQUENCE of activities.
        /// Sequence and not set: `Dictionary(grouping:)` preserves encounter
        /// order and patch 168 says callers depend on it.
        let daysWithDifferentMembers: [String]

        // Zones

        let zoneChangesCompared: Int
        let zonesAgree: Bool

        /// Whether the app's own list survives its own rules unchanged.
        ///
        /// A FREE CONTINUOUS CONTROL, and it is about the store rather than the
        /// database. `settle` is idempotent (`settlingTwiceChangesNothing`), so
        /// this is true on every healthy launch — and false the day something
        /// writes to `activities` without going through a door.
        let storeIsSettled: Bool

        // MARK: Where the app side came from — patch 381, §12.125

        /// **THE DEFAULT NAMES THE SINGLETON, DELIBERATELY.** 356's argument,
        /// on the slice that needs it most: a caller nobody updated announces
        /// itself in the paste rather than hiding, and after 382 this sentence
        /// on this line IS the defect it exists to catch.
        var appSideCameFrom = "ActivityStore.shared"

        /// False when the file could not be read and the store was compared
        /// instead. It is not a difference — it is the comparison losing its
        /// independence, which `isHealthy` refuses to call a pass.
        var appSideWasReadCleanly = true

        /// **WHETHER THE LIVE STORE'S OWN LIST SURVIVES ITS OWN RULES — patch
        /// 381a, and it exists because 381 emptied the field above it.**
        ///
        /// `storeIsSettled` describes the list handed to `compare`. Until 381
        /// that was `ActivityStore.shared.activities`; since 381 it is the
        /// file's, which `load` settled on the way in — so it is true by
        /// construction and can no longer say anything about the store.
        /// §12.69: a check that cannot fail has not been tested, and this one
        /// was emptied by a patch about keeping evidence alive.
        ///
        /// **THREE STATES, BECAUSE NOBODY ASKED IS NOT YES.** Nil is what a
        /// report built by a test or by a caller that has no store carries;
        /// it contributes nothing to `unexplained`, and the paste says *not
        /// asked* rather than printing a cheerful `yes`. §12.15.
        var liveStoreIsSettled: Bool?

        /// Everything above that should be zero. There is no approved list for
        /// activities, so every difference counts — see the header.
        var unexplained: Int {
            storeOnly.count + databaseOnly.count + orderDiffered
            + daysOnlyInStore.count + daysOnlyInDatabase.count
            + daysWithDifferentMembers.count
            + (zonesAgree ? 0 : 1)
            + (storeIsSettled ? 0 : 1)
            // PATCH 381a. NIL CONTRIBUTES NOTHING — not asked is not a
            // disagreement, and counting it as one would make every report a
            // test builds report a difference it never had.
            + (liveStoreIsSettled == false ? 1 : 0)
        }

        /// THE GUARD AGAINST AGREEING ABOUT NOTHING — groundwork §2.1 case 2.
        /// Zero compared against zero agrees perfectly and proves nothing.
        var lookedAtSomething: Bool { common > 0 }

        /// MOVED UP FROM `Outcome` AT 313, when running and holding went to
        /// `ShadowParity`. A report that can say whether it passed lets a
        /// caller ask without owning the enum — and lets a test assert on the
        /// thing it built rather than on a wrapper.
        /// **AND IT ASKS WHERE ITS OWN SIDE CAME FROM — patch 381.** Zero
        /// differences over an app side that could not be read is not a pass:
        /// the fallback compares the database against whatever was to hand,
        /// and after 382 that is the database. §12.69 — a check that cannot
        /// fail has not been tested.
        var isHealthy: Bool {
            lookedAtSomething && unexplained == 0 && appSideWasReadCleanly
        }

        var summary: String {
            guard lookedAtSomething else {
                return "nothing compared — \(storeCount) in the app, "
                     + "\(databaseKept) in the database"
            }
            return unexplained == 0
                ? "\(common) compared · no differences"
                : "\(common) compared · \(unexplained) differences"
        }

        /// For the redacted paste. Counts and day keys only — a day key is a
        /// date and this project already prints dates of imports; no activity
        /// names, no ids.
        ///
        /// UNCONDITIONAL, every line, including the zeros. 266c wrote the rule
        /// and 273 repeated it: *a line that only appears when something is
        /// wrong cannot be distinguished from a line nobody wired in.*
        var diagnosticLines: [String] {
            ["Activity parity: \(common) compared of \(storeCount) in the app",
             // PATCH 381 — §12.101's two lines, UNCONDITIONAL and FIRST,
             // because they are what every count below them means. The second
             // shouts when it is false: that is the state in which the numbers
             // under it describe the database twice.
             "  the app side came from: \(appSideCameFrom)",
             "  the app side was read cleanly: "
             + "\(appSideWasReadCleanly ? "yes" : "NO")",
             "  database rows offered: \(databaseOffered)",
             "  database rows the reader skipped: \(databaseSkipped)",
             "  database rows after the same rules: \(databaseKept)",
             "  database rows the rules dropped: \(databaseDropped)",
             "  database rows collapsed as duplicates: \(databaseCollapsed)",
             "  in the app only: \(storeOnly.count)",
             "  in the database only: \(databaseOnly.count)",
             "  order disagreements: \(orderDiffered) of \(orderCompared)",
             "  days compared: \(daysCompared)",
             "  days only in the app: \(daysOnlyInStore.count)",
             "  days only in the database: \(daysOnlyInDatabase.count)",
             "  days holding a different sequence: \(daysWithDifferentMembers.count)",
             "  time-zone changes compared: \(zoneChangesCompared)",
             "  time-zone changes agree: \(zonesAgree ? "yes" : "no")",
             "  the app's own list is settled: \(storeIsSettled ? "yes" : "no")",
             // PATCH 381a — THE CONTROL 381 EMPTIED, PUT BACK BESIDE IT. The
             // line above describes whichever list was compared, and since
             // 381 that is the file's — settled by `load` on the way in, so
             // true by construction. This one asks the live store.
             "  the live store's list is settled: "
             + (liveStoreIsSettled.map { $0 ? "yes" : "no" } ?? "not asked"),
             "  unexplained differences: \(unexplained)"]
        }
    }

    // MARK: The comparison

    /// Both sides handed in.
    ///
    /// STATIC AND TAKING ITS INPUTS, so a test can build the two sides from
    /// genuinely different places — which is the only answer this project has
    /// to groundwork §2.1's third failure, both sides secretly being the same
    /// object.
    ///
    /// `deviceOffset` is passed to BOTH zone builds so the only thing compared
    /// is the recorded changes. `DayZones.trailingOffsetSeconds` is the phone's
    /// current offset and identical by construction; letting each side read the
    /// clock separately would compare a value neither side derives from data.
    /// Does a list survive its own rules — patch 381a.
    ///
    /// EXTRACTED SO THAT `ShadowParity` CAN ASK IT OF THE LIVE STORE without
    /// writing the expression a second time. §12.43, and the eleventh-plus
    /// application: *a derivation with one caller looks like part of that
    /// caller, and stops being that the moment something else must agree with
    /// it.*
    static func isSettled(_ list: [Activity]) -> Bool {
        ActivityRoster.settle(list).activities.map(\.id) == list.map(\.id)
    }

    static func compare(store: [Activity],
                        databaseRows: [Activity],
                        databaseSkipped: Int,
                        deviceOffset: Int = TimeZone.current.secondsFromGMT()) -> Report {

        let twin = ActivityRoster.settle(databaseRows)

        let mine = store.map(\.id)
        let theirs = twin.activities.map(\.id)
        let mineSet = Set(mine)
        let theirsSet = Set(theirs)

        let storeOnly = mine.filter { !theirsSet.contains($0) }
        let databaseOnly = theirs.filter { !mineSet.contains($0) }

        // ORDER IS COMPARED OVER THE COMMON IDS ONLY, and that is not
        // leniency. A single missing activity shifts every position after it,
        // so comparing the raw sequences would report one absence as four
        // hundred order differences — the same mistake §12.39 had to fix for
        // sample lengths, where one short stream reported as three hundred
        // differing samples.
        let mineCommon = mine.filter { theirsSet.contains($0) }
        let theirsCommon = theirs.filter { mineSet.contains($0) }
        var differed = 0
        var firstAt: Int?
        for i in 0 ..< min(mineCommon.count, theirsCommon.count)
        where mineCommon[i] != theirsCommon[i] {
            differed += 1
            if firstAt == nil { firstAt = i }
        }

        // THE SAME FUNCTION ON BOTH SIDES — moved into `ActivityRoster` by this
        // patch for exactly this call.
        let myDays = ActivityRoster.byDay(store)
        let theirDays = ActivityRoster.byDay(twin.activities)
        let myKeys = Set(myDays.keys)
        let theirKeys = Set(theirDays.keys)
        let sharedKeys = myKeys.intersection(theirKeys)
        let differingDays = sharedKeys.filter {
            (myDays[$0] ?? []).map(\.id) != (theirDays[$0] ?? []).map(\.id)
        }.sorted()

        let myZones = DayZones.from(activities: store, deviceOffset: deviceOffset)
        let theirZones = DayZones.from(activities: twin.activities,
                                       deviceOffset: deviceOffset)

        return Report(
            storeCount: store.count,
            databaseOffered: databaseRows.count,
            databaseSkipped: databaseSkipped,
            databaseKept: twin.activities.count,
            databaseDropped: twin.dropped,
            databaseCollapsed: twin.collapsed,
            storeOnly: storeOnly.sorted(),
            databaseOnly: databaseOnly.sorted(),
            common: mineCommon.count,
            orderCompared: min(mineCommon.count, theirsCommon.count),
            orderDiffered: differed,
            firstOrderDisagreement: firstAt,
            daysCompared: sharedKeys.count,
            daysOnlyInStore: myKeys.subtracting(theirKeys).sorted(),
            daysOnlyInDatabase: theirKeys.subtracting(myKeys).sorted(),
            daysWithDifferentMembers: differingDays,
            zoneChangesCompared: max(myZones.changes.count, theirZones.changes.count),
            zonesAgree: myZones == theirZones,
            // PATCH 381a — through `isSettled`, which ShadowParity also
            // calls. The expression was identical and lived in one place;
            // it now lives in one place and has two callers.
            storeIsSettled: isSettled(store))
    }
}
