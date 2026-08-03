//
//  ReviewLoad.swift
//  Sub4
//
//  Turning the load engine into things the monthly review can say.
//
//  WHAT THIS ADDS THAT THE REVIEW DID NOT HAVE
//  -------------------------------------------
//  Until now the review reasoned entirely about ADHERENCE and EFFORT: did you
//  do the sessions, and how did they feel. Both come from the plan and your
//  notes. Neither can see the shape of the load itself — whether fitness is
//  climbing faster than it should, whether freshness has been deeply negative
//  for a fortnight, whether every week looks like every other week.
//
//  Those three are what the PMC and Foster's monotony were built for, and they
//  are the difference between a review that reports the month and one that can
//  steer the next.
//
//  A FLAG THAT CANNOT BE SUPPORTED DOES NOT FIRE
//  --------------------------------------------
//  Every metric here is suppressed when its inputs are thin, and the review
//  says which one was skipped and why. This is not caution for its own sake:
//  an imputed day is filled from the trailing mean, which shrinks the spread
//  and pushes monotony UP, so a monotony flag on a window containing one is
//  reporting the fill rather than the training. The fitness card already
//  refuses to draw a conclusion it cannot support; this follows the same rule
//  rather than inventing a second one.
//
//  "Not assessed, and here is why" is a useful sentence. "Probably too fast,
//  but the data is unreliable" is not — it leaves the reader to do arithmetic
//  they have no way of doing.
//

import Foundation

enum ReviewLoad {

    /// Everything the flags need, and the reasons any of it is missing.
    struct Assessment {
        var ramp: Double?
        var rampSkipped: String?

        var deepRun: Int = 0            // longest run of consecutive deep days
        var tsbSkipped: String?

        var highMonotonyWeeks: Int = 0
        var assessedMonotonyWeeks: Int = 0
        var monotonySkipped: String?

        var ctl: Double?
        var tsb: Double?
    }

    /// Read the load series across one review window.
    ///
    /// `LoadStore` materialises from the ingest cutoff to today, so the window
    /// is a slice rather than a rebuild.
    static func assess(startDay: String, endDay: String) -> Assessment {
        let store = LoadStore.shared
        store.recomputeIfNeeded()

        let pmc = store.pmc
        var a = Assessment()
        a.ctl = pmc.ctl
        a.tsb = pmc.tsb

        let inWindow = pmc.points.filter { $0.dayKey >= startDay && $0.dayKey <= endDay }
        guard !inWindow.isEmpty else {
            a.rampSkipped = "no load series covers this window"
            a.tsbSkipped = a.rampSkipped
            a.monotonySkipped = a.rampSkipped
            return a
        }

        // --- Ramp rate.
        //
        // Suppressed during the warm-up: inside the first 42 days CTL is
        // climbing out of a cold start of zero, and the "gain" is the average
        // filling rather than fitness arriving. A ramp flag there would fire on
        // every athlete who ever installed the app.
        if pmc.isWarmup {
            a.rampSkipped = "the fitness average is still filling — "
                          + "\(pmc.daysOfData) of \(PMC.warmupDays) days. CTL is "
                          + "climbing out of a cold start, so a ramp rate "
                          + "measured now describes the start, not the training."
        } else if let last = inWindow.last,
                  let i = pmc.points.firstIndex(where: { $0.dayKey == last.dayKey }) {
            let recent = pmc.points[Swift.max(0, i - 7)...i]
            let imputed = recent.filter(\.imputed).count
            if imputed > 0 {
                a.rampSkipped = "\(imputed) of the last 8 days had nothing that "
                              + "could be scored and were filled in. A ramp rate "
                              + "across a filled-in day measures the fill."
            } else {
                a.ramp = PMC.rampRate(pmc.points, on: i)
            }
        }

        // --- Deep freshness, as a run rather than a reading.
        let tsbDays = inWindow.compactMap { p -> (Double, Bool)? in
            p.tsb.map { ($0, p.imputed) }
        }
        if tsbDays.count < 14 {
            a.tsbSkipped = "only \(tsbDays.count) days of freshness in the window"
        } else if tsbDays.filter(\.1).count > 2 {
            a.tsbSkipped = "\(tsbDays.filter(\.1).count) imputed days in the "
                         + "window — freshness across a fill is not freshness"
        } else {
            let deep = LoadThresholds.shared.tsbDeep
            var run = 0
            for (v, _) in tsbDays {
                run = v <= deep ? run + 1 : 0
                a.deepRun = Swift.max(a.deepRun, run)
            }
        }

        // --- Monotony, per week, imputed windows excluded.
        let series = Monotony.series(pmc.points)
            .filter { $0.dayKey >= startDay && $0.dayKey <= endDay }
        let clean = series.filter { $0.isTrustworthy && $0.monotony != nil }
        if clean.count < 7 {
            a.monotonySkipped = "\(series.count - clean.count) of \(series.count) "
                              + "windows contained an imputed day, which pushes "
                              + "monotony up for a reason that is not training"
        } else {
            let high = LoadThresholds.shared.monotonyHigh
            a.assessedMonotonyWeeks = clean.count
            a.highMonotonyWeeks = clean.filter { ($0.monotony ?? 0) >= high }.count
        }
        return a
    }

    // MARK: Flags

    static func flags(_ a: Assessment) -> [Review.Flag] {
        var out: [Review.Flag] = []
        let t = LoadThresholds.shared

        // --- Ramp.
        if let why = a.rampSkipped {
            out.append(.init(level: .note, title: "Ramp rate not assessed",
                             detail: why.prefix(1).uppercased() + why.dropFirst() + "."))
        } else if let r = a.ramp {
            if r >= t.rampWarn {
                out.append(.init(level: .warning, title: "Fitness climbing quickly",
                    detail: String(format: "CTL rose %.1f in the last seven days, "
                        + "against a threshold of %.1f. ", r, t.rampWarn)
                        + "The conventional ceiling of 5 a week is a cycling "
                        + "figure at steady volume; re-acquiring a base you "
                        + "already had legitimately moves faster than building "
                        + "one. Worth reading alongside how the sessions felt."))
            } else if r >= t.rampNote {
                out.append(.init(level: .note, title: "Fitness climbing steadily",
                    detail: String(format: "CTL rose %.1f in the last seven days. "
                        + "Above the quiet level of %.1f and below the threshold "
                        + "of %.1f — noted rather than flagged.",
                        r, t.rampNote, t.rampWarn)))
            } else if r < 0 {
                out.append(.init(level: .note, title: "Fitness falling",
                    detail: String(format: "CTL fell %.1f over the last seven "
                        + "days. Expected in a taper or a rest week; worth "
                        + "explaining in any other kind.", abs(r))))
            }
        }

        // --- Freshness.
        if let why = a.tsbSkipped {
            out.append(.init(level: .note, title: "Freshness not assessed",
                             detail: why.prefix(1).uppercased() + why.dropFirst() + "."))
        } else if a.deepRun >= t.tsbDeepDays {
            out.append(.init(level: .warning, title: "Sustained deep fatigue",
                detail: String(format: "%d consecutive days with freshness at or "
                    + "below %.0f. ", a.deepRun, t.tsbDeep)
                    + "There is no defensible target for TSB on any given day — "
                    + "the literature is explicit that race-day figures are "
                    + "folklore — so this fires on the RUN, not the reading. A "
                    + "hard weekend is one thing; a fortnight without the number "
                    + "coming back up is another."))
        }

        // --- Monotony.
        if let why = a.monotonySkipped {
            out.append(.init(level: .note, title: "Monotony not assessed",
                             detail: why.prefix(1).uppercased() + why.dropFirst() + "."))
        } else if a.highMonotonyWeeks > 0 {
            out.append(.init(level: .warning, title: "Weeks with no shape",
                detail: String(format: "%d of %d assessable weeks scored monotony "
                    + "%.1f or above. ", a.highMonotonyWeeks,
                    a.assessedMonotonyWeeks, t.monotonyHigh)
                    + "Monotony rises when every day looks like every other day, "
                    + "and it is deliberately sensitive to rest days — a week "
                    + "with no zeros scores high even at a modest total. Foster "
                    + "associated this with a rise in illness, which is why it "
                    + "is here at all."))
        }
        return out
    }
}
