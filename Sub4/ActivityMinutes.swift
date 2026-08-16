//
//  ActivityMinutes.swift
//  Sub4
//
//  Seconds add. Minutes do not — patch 375, ADR-0003 §12.119.
//
//  WHAT WAS WRONG
//  --------------
//  `Activity.minutes` is `movingTime / 60`, which throws away up to 59 seconds.
//  That is correct for ONE activity: a 29:59 ride is 29 minutes on its card and
//  nobody expects otherwise.
//
//  It is wrong the moment those values are added together. Seven places did:
//
//      TodayView          the day total, and the Extra movement header
//      DayDistance        the figure a mixed-discipline day is reported as
//      TabSummary         the week's moving time
//      CommuteView        the weekly buckets, and the all-time total
//
//  Each summed already-truncated minutes, so a set of N activities lost up to
//  N−1 minutes. A week with ten sessions read nine minutes short, and
//  `WeekView` printed that number. `CommuteView` then divided the all-time
//  total by 60 for hours, truncating a second time.
//
//  THE CODEBASE ALREADY HAD THE ANSWER
//  -----------------------------------
//  `MergedActivity`, patch 177:
//
//      var movingTime: Int { parts.reduce(0) { $0 + $1.movingTime } }
//      var minutes: Int { movingTime / 60 }
//
//  Sum the seconds, divide once, at the end. `MergedActivity.summarise` does
//  the same thing again at line 292. The rule existed and worked; it was never
//  written down, so seven other places did it the other way.
//
//  This file is the rule with a name: **minutes are DERIVED at the last
//  moment, never ACCUMULATED.** `check-invariants.py` enforces it from 375,
//  because no expression in the language states it and the compiler is happy
//  either way.
//
//  WHY AN EXTENSION AND NOT SEVEN INLINE FIXES
//  -------------------------------------------
//  Seven copies of an arithmetic rule is how seven of them come to disagree —
//  the same argument `StoreWrite`, `StoreRead` and `DayDistance` were each
//  built on. The inline version would have been fewer characters and would
//  have left nothing for the next person to find.
//
//  `@MainActor` DELIBERATELY. `DayDistance`'s header sets out the reasoning:
//  `Activity` is not `nonisolated` at type level — `dayKey`, `discipline` and
//  `hasStartPosition` are marked individually — so its stored properties
//  inherit the type's isolation. Every one of the seven call sites is already
//  main-actor work inside a view body. Claiming otherwise here would be the
//  inverse of the mistake that file says this project has made six times.
//

import Foundation

@MainActor
extension Sequence where Element == Activity {

    /// Total moving time in SECONDS. The only thing in this pair that may be
    /// added up, which is why it is the one the other is derived from.
    ///
    /// `movingSeconds` rather than `movingTime`: that is already the name this
    /// project uses for the same quantity on `MergedActivity`, on
    /// `RoutePlayback`, and as the column on `activity`.
    var movingSeconds: Int { reduce(0) { $0 + $1.movingTime } }

    /// Whole minutes of moving time across the whole sequence.
    ///
    /// FLOOR, not rounded, and that is the deliberate half. `minutes` on a
    /// single activity floors, so a total that rounded could exceed the sum of
    /// the rows printed above it — two 29:59 rides showing 29 and 29 under a
    /// total of 60. Flooring the SUM gives 59, which is both true and
    /// consistent with what a reader can add up by eye.
    ///
    /// The error against the real figure is now under one minute, whatever the
    /// count. It used to grow with it.
    var totalMinutes: Int { movingSeconds / 60 }
}
