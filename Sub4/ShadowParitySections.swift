//
//  ShadowParitySections.swift
//  Sub4
//
//  Shadow parity's two sections, lifted out of DatabaseHealthView — patch 330c.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  It is not a new feature. Every row below was in `DatabaseHealthView` an hour
//  ago and renders identically. The move is structural, and the reason is a
//  crash.
//
//  330 appended slice 8's rows inside `paritySection` and the device died on
//  the first press of Compare: `EXC_BAD_ACCESS` inside `___chkstk_darwin`, the
//  stack probe. 330b split those rows into their own `Section` and three
//  builder functions, which made it WORSE — the crash moved earlier, to
//  opening the tab, before any comparison has run and while slice 8 renders
//  nothing at all.
//
//  That second result is the informative one. If the fault were the volume of
//  rows slice 8 draws, a screen that draws none of them could not crash. What
//  330b actually changed on open was the SHAPE of the type: one more child in
//  `DatabaseHealthView.body`, which is a left-leaning chain — twenty-one
//  children mean twenty nested `TupleView`s, and every step of that chain is a
//  frame in the recursive walk SwiftUI does before a single row is drawn.
//  Adding a child adds a level whether or not it draws anything.
//
//  So the remedy is depth, not volume, and there are two ways to spend it:
//
//   1. BALANCE THE CHAIN. Twenty-one children in a row is depth twenty; six
//      groups of three or four is depth nine. `DatabaseHealthView.body` now
//      holds six group builders instead of twenty-one sections.
//
//   2. END THE CHAIN. A separate `View` struct is a boundary: the parent's
//      body type contains `ShadowParitySections`, which is one `Sub4Database`
//      wide, and none of what is below. The seven hundred lines of view code
//      that used to sit inside the parent's type now sit inside this one's.
//
//  Parity earns the boundary because its dependency surface is one line long.
//  Every row here reads `ShadowParity.shared` and the open database; not one
//  of them touches any of `DatabaseHealthView`'s forty `@State` properties. A
//  section that needed half of them would not be worth extracting, and this
//  one needed none.
//
//  ADR-0003 §12.75.10 said `DatabaseHealthView` had reached the size where
//  adding to it is a structural change rather than an edit. 330b treated that
//  as advice about the section being added. It was advice about the screen.
//

import SwiftUI

/// Slices 1–5 and slice 8, in the two sections they have always been drawn in.
///
/// EVERY ROW IS UNCONDITIONAL once a comparison has run. §12.54.2, and this
/// screen has now learned that twice.
struct ShadowParitySections: View {

    /// The open database. Needed for exactly one thing — the button.
    let db: Sub4Database

    /// D6c — patch 312, moved off `@State` at 313.
    ///
    /// OBSERVED RATHER THAN OWNED. The result used to live in the screen, so
    /// pressing Done discarded it — and the diagnostics paste, which is the
    /// thing somebody reads later, said "Not compared since this launch" a
    /// minute after the comparison passed. True of the `@State` and false
    /// about the world. §12.57.
    @State private var parity = ShadowParity.shared

    var body: some View {
        paritySection
        summaryParitySection
    }

    // MARK: - Slices 1 to 5

    /// ONE SECTION, ONE BUTTON, EVERY SLICE. Groundwork §7 left the shape open
    /// until there was more than one comparison to lay out. They need the SAME
    /// database read and the SAME `ActivityRoster.settle`, and two buttons
    /// would let somebody run half of it and see something that looked whole.
    ///
    /// The read-back sections above ask *do both sides hold the same records* —
    /// nineteen named fields per activity. This asks *would the app derive the
    /// same answers*: the same list, in the same order, in the same days, and
    /// adding up to the same distances.
    @ViewBuilder
    private var paritySection: some View {
        Section {
            controlRows
            listRows
            volumeRows
            loadRows
            detailRows
            matchRows
        } header: {
            Text("Shadow parity")
        } footer: {
            Text(Self.parityFooter).font(.caption2)
        }
    }

    @ViewBuilder
    private var controlRows: some View {
        if parity.isRunning {
            HStack { ProgressView(); Text("Deriving…").font(.caption) }
        } else {
            Button("Compare the derived lists") { runParity() }
        }

        LabeledContent("Parity", value: parity.last.line)
            .font(.caption)
            .foregroundStyle(parity.last.isHealthy ? Color.dim : .red)
    }

    // MARK: Slice 1 — the list

    @ViewBuilder
    private var listRows: some View {
        if let r = parity.last.activities {
            Text("The list")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            listCountRows(r)
            listOrderAndDayRows(r)
            listCarriedRows(r)
        }
    }

    @ViewBuilder
    private func listCountRows(_ r: ActivityParity.Report) -> some View {
        // THE THREE DENOMINATORS — groundwork §2.1 case 2. A dead read stops
        // them matching, and zero compared to zero agrees perfectly while
        // meaning nothing.
        LabeledContent("In the app", value: "\(r.storeCount)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("In the database",
                       value: "\(r.databaseKept) of \(r.databaseOffered) rows")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Compared", value: "\(r.common)")
            .font(.caption)
            .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

        LabeledContent("In the app only", value: "\(r.storeOnly.count)")
            .font(.caption)
            .foregroundStyle(r.storeOnly.isEmpty ? Color.dim : .red)
        LabeledContent("In the database only", value: "\(r.databaseOnly.count)")
            .font(.caption)
            .foregroundStyle(r.databaseOnly.isEmpty ? Color.dim : .red)
    }

    @ViewBuilder
    private func listOrderAndDayRows(_ r: ActivityParity.Report) -> some View {
        LabeledContent("Order disagreements",
                       value: "\(r.orderDiffered) of \(r.orderCompared)")
            .font(.caption)
            .foregroundStyle(r.orderDiffered == 0 ? Color.dim : .red)
        if let at = r.firstOrderDisagreement {
            Text("  first at position \(at + 1)")
                .font(.caption2).foregroundStyle(.red)
        }

        LabeledContent("Days compared", value: "\(r.daysCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Days that disagree",
                       value: "\(r.daysOnlyInStore.count + r.daysOnlyInDatabase.count + r.daysWithDifferentMembers.count)")
            .font(.caption)
            .foregroundStyle(r.daysOnlyInStore.isEmpty
                             && r.daysOnlyInDatabase.isEmpty
                             && r.daysWithDifferentMembers.isEmpty
                             ? Color.dim : .red)
        ForEach(r.daysWithDifferentMembers.prefix(5), id: \.self) { day in
            Text("  \(day)").font(.caption2).foregroundStyle(.red)
        }

        LabeledContent("Time-zone changes",
                       value: r.zonesAgree
                           ? "\(r.zoneChangesCompared), agreed"
                           : "\(r.zoneChangesCompared), disagreed")
            .font(.caption)
            .foregroundStyle(r.zonesAgree ? Color.dim : .red)
    }

    @ViewBuilder
    private func listCarriedRows(_ r: ActivityParity.Report) -> some View {
        // DIM WHEN ZERO, INK WHEN NOT — not red. These are not disagreements;
        // they are rows the database is still carrying that the app's own
        // rules refuse. §12.46.3 predicted them.
        LabeledContent("Rows the rules dropped", value: "\(r.databaseDropped)")
            .font(.caption)
            .foregroundStyle(r.databaseDropped == 0 ? Color.dim : Color.ink)
        LabeledContent("Rows collapsed as duplicates",
                       value: "\(r.databaseCollapsed)")
            .font(.caption)
            .foregroundStyle(r.databaseCollapsed == 0 ? Color.dim : Color.ink)
        LabeledContent("Rows the reader could not read",
                       value: "\(r.databaseSkipped)")
            .font(.caption)
            .foregroundStyle(r.databaseSkipped == 0 ? Color.dim : .red)

        LabeledContent("The app's list is settled",
                       value: r.storeIsSettled ? "yes" : "no")
            .font(.caption)
            .foregroundStyle(r.storeIsSettled ? Color.dim : .red)
    }

    // MARK: Slice 2 — the numbers derived from it

    @ViewBuilder
    private var volumeRows: some View {
        if let v = parity.last.volume {
            Text("Daily and weekly volume")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            // EACH COUNT BESIDE ITS OWN DENOMINATOR — §12.54.3. "0 of 324" is
            // evidence; a bare 0 is noise.
            LabeledContent("Day distances",
                           value: "\(v.daysDiffering.count) of \(v.daysCompared) disagree")
                .font(.caption)
                .foregroundStyle(v.daysDiffering.isEmpty ? Color.dim : .red)
            ForEach(v.daysDiffering.prefix(5), id: \.self) { day in
                Text("  \(day)").font(.caption2).foregroundStyle(.red)
            }

            LabeledContent("Week figures",
                           value: "\(v.weeksDiffering.count) of \(v.weekValuesCompared) disagree")
                .font(.caption)
                .foregroundStyle(v.weeksDiffering.isEmpty ? Color.dim : .red)
            ForEach(v.weeksDiffering.prefix(5), id: \.self) { w in
                Text("  \(w)").font(.caption2).foregroundStyle(.red)
            }

            LabeledContent("History bands",
                           value: "\(v.bandsDiffering.count) of \(v.bandsCompared) disagree")
                .font(.caption)
                .foregroundStyle(v.bandsDiffering.isEmpty ? Color.dim : .red)
            ForEach(v.bandsDiffering.prefix(6), id: \.self) { b in
                Text("  \(b)").font(.caption2).foregroundStyle(.red)
            }

            LabeledContent("The history starts on the same day",
                           value: v.historyStartAgrees ? "yes" : "no")
                .font(.caption)
                .foregroundStyle(v.historyStartAgrees ? Color.dim : .red)

            // ON SCREEN, because a threshold nobody can see is a threshold
            // nobody can argue with.
            LabeledContent("Tolerance", value: VolumeParity.toleranceLabel)
                .font(.caption).foregroundStyle(Color.dim)
        }
    }

    // MARK: Slice 3 — the fitness curve, patch 315

    @ViewBuilder
    private var loadRows: some View {
        if let l = parity.last.load {
            Text("Fitness and load")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            loadCountRows(l)
            loadShapeRows(l)
            loadCurveRows(l)
        } else if case .ran = parity.last {
            // NOT ZERO DIFFERENCES — NO ANSWER. The app's own series had not
            // been built, so there was nothing to compare against.
            LabeledContent("Fitness and load",
                           value: "the app's load series was not built")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func loadCountRows(_ l: LoadParity.Report) -> some View {
        LabeledContent("Days in each series",
                       value: "\(l.appDays) vs \(l.databaseDays)")
            .font(.caption)
            .foregroundStyle(l.appDays == l.databaseDays ? Color.dim : .red)
        LabeledContent("Days compared", value: "\(l.daysCompared)")
            .font(.caption)
            .foregroundStyle(l.daysCompared > 0 ? Color.dim : .red)
        // THE DEEP DENOMINATOR. Four hundred rest days would satisfy the row
        // above and describe no training at all.
        LabeledContent("Sessions compared", value: "\(l.workoutsCompared)")
            .font(.caption)
            .foregroundStyle(l.workoutsCompared > 0 ? Color.dim : .red)
        LabeledContent("Scored from a trace",
                       value: "\(l.appTraces) vs \(l.databaseTraces)")
            .font(.caption)
            .foregroundStyle(l.appTraces == l.databaseTraces ? Color.dim : .red)

        LabeledContent("Days with a different state",
                       value: "\(l.daysWithDifferentState.count)")
            .font(.caption)
            .foregroundStyle(l.daysWithDifferentState.isEmpty ? Color.dim : .red)
        ForEach(l.daysWithDifferentState.prefix(5), id: \.self) { day in
            Text("  \(day)").font(.caption2).foregroundStyle(.red)
        }
        LabeledContent("Days with a different total",
                       value: "\(l.daysWithDifferentLoad.count)")
            .font(.caption)
            .foregroundStyle(l.daysWithDifferentLoad.isEmpty ? Color.dim : .red)
        ForEach(l.daysWithDifferentLoad.prefix(5), id: \.self) { day in
            Text("  \(day)").font(.caption2).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func loadShapeRows(_ l: LoadParity.Report) -> some View {
        // THE ROW THIS SLICE EXISTS FOR — see LoadParity's header. A session
        // scored from the trace on one side and from the session average on
        // the other is D6a's accepted trace loss costing a number somebody
        // reads.
        LabeledContent("Sessions on a different rung",
                       value: "\(l.workoutsWithDifferentSource.count)")
            .font(.caption)
            .foregroundStyle(l.workoutsWithDifferentSource.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Sessions with a different figure",
                       value: "\(l.workoutsWithDifferentFigure.count)")
            .font(.caption)
            .foregroundStyle(l.workoutsWithDifferentFigure.isEmpty
                             ? Color.dim : .red)

        // THE SHAPE UNDER THE NUMBER — patch 316. TRIMP is an integral; this
        // is the distribution it integrates. Two different distributions
        // produce the same TRIMP, and the distribution is what the
        // Time-in-zone card draws.
        LabeledContent("Heart-rate buckets compared",
                       value: "\(l.hrBucketsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Sessions with a different distribution",
                       value: "\(l.workoutsWithDifferentHistogram.count)")
            .font(.caption)
            .foregroundStyle(l.workoutsWithDifferentHistogram.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Zones that disagree",
                       value: "\(l.zonesDiffering.count) of \(l.zonesCompared)")
            .font(.caption)
            .foregroundStyle(l.zonesDiffering.isEmpty ? Color.dim : .red)
        LabeledContent("Sessions in the zone card",
                       value: "\(l.zoneTracedApp) vs \(l.zoneTracedDatabase)")
            .font(.caption)
            .foregroundStyle(l.zoneTracedApp == l.zoneTracedDatabase
                             ? Color.dim : .red)
        LabeledContent("Sessions it left out",
                       value: "\(l.zoneUntracedApp) vs \(l.zoneUntracedDatabase)")
            .font(.caption)
            .foregroundStyle(l.zoneUntracedApp == l.zoneUntracedDatabase
                             ? Color.dim : .red)
    }

    @ViewBuilder
    private func loadCurveRows(_ l: LoadParity.Report) -> some View {
        LabeledContent("Curve points that disagree",
                       value: "\(l.pointsWithDifferentFitness) of \(l.pointsCompared)")
            .font(.caption)
            .foregroundStyle(l.pointsWithDifferentFitness == 0 ? Color.dim : .red)
        LabeledContent("Fitness", value: l.fitnessLine)
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Fatigue", value: l.fatigueLine)
            .font(.caption).foregroundStyle(Color.dim)

        // THE LIMIT, PRINTED. A comparison that does not say what it held
        // constant is a comparison whose result cannot be read.
        LabeledContent("Held from the app", value: LoadParity.heldFromTheApp)
            .font(.caption).foregroundStyle(Color.dim)
        // PATCH 317. "Held from the app" and "held from the app and never
        // checked" are different sentences, and until the athlete read-back
        // existed this screen could only say the second one.
        LabeledContent("Of those, verified", value: LoadParity.verifiedByReadBack)
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Tolerance", value: LoadParity.toleranceLabel)
            .font(.caption).foregroundStyle(Color.dim)
    }

    // MARK: Slice 4 — details, splits and laps

    @ViewBuilder
    private var detailRows: some View {
        if let d = parity.last.details {
            Text("Details, splits and laps")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            detailCountRows(d)
            detailSplitRows(d)
            detailLapRows(d)
        } else if case .ran = parity.last {
            // NOT ZERO DIFFERENCES — NO ANSWER, again. The detail read itself
            // failed, which is a different fact from a device that holds no
            // details.
            LabeledContent("Details, splits and laps",
                           value: "the details could not be read")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func detailCountRows(_ d: DetailParity.Report) -> some View {
        LabeledContent("Details in each side",
                       value: "\(d.appDetails) vs \(d.databaseDetails)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Details compared", value: "\(d.detailsCompared)")
            .font(.caption)
            .foregroundStyle(d.detailsCompared > 0 ? Color.dim : .red)
        LabeledContent("In the app only", value: "\(d.detailsOnlyInApp.count)")
            .font(.caption)
            .foregroundStyle(d.detailsOnlyInApp.isEmpty ? Color.dim : .red)
        // DIM, NOT RED — patch 298's rule. DataCorrections refuses two
        // sessions and the importer declines their details at the door, while
        // DetailStore keeps them because it keys by Strava id and never sees
        // an Activity. A permanently correct red row is a row that stops being
        // read.
        LabeledContent("Excluded on purpose",
                       value: "\(d.detailsExcluded.count)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("In the database only",
                       value: "\(d.detailsOnlyInDatabase.count)")
            .font(.caption)
            .foregroundStyle(d.detailsOnlyInDatabase.isEmpty ? Color.dim : .red)

        // THE TWO DENOMINATORS, AND THE SECOND IS THE REAL ONE. A pace that is
        // nil on both sides agrees perfectly and proves nothing, so the count
        // of figures BOTH sides answered is what says whether this looked at
        // anything.
        LabeledContent("Pace figures compared",
                       value: "\(d.paceFiguresCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("  both sides answered",
                       value: "\(d.paceFiguresAnswered)")
            .font(.caption)
            .foregroundStyle(d.paceFiguresAnswered > 0 ? Color.dim : .red)
        LabeledContent("Pace figures that differ",
                       value: "\(d.paceFiguresDiffering.count)")
            .font(.caption)
            .foregroundStyle(d.paceFiguresDiffering.isEmpty ? Color.dim : .red)
        ForEach(d.paceFiguresDiffering.prefix(6), id: \.self) { f in
            Text("    \(f)").font(.caption2).foregroundStyle(.red)
        }
        if d.paceFiguresDiffering.count > 6 {
            Text("    + \(d.paceFiguresDiffering.count - 6) more figures")
                .font(.caption2).foregroundStyle(Color.dim)
        }
    }

    @ViewBuilder
    private func detailSplitRows(_ d: DetailParity.Report) -> some View {
        LabeledContent("Splits compared", value: "\(d.splitsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Splits with a different pace",
                       value: "\(d.splitsWithDifferentPace)")
            .font(.caption)
            .foregroundStyle(d.splitsWithDifferentPace == 0 ? Color.dim : .red)
        LabeledContent("Splits with a different heart rate",
                       value: "\(d.splitsWithDifferentHR)")
            .font(.caption)
            .foregroundStyle(d.splitsWithDifferentHR == 0 ? Color.dim : .red)
        // DIM AND ALWAYS PRESENT — patch 320a. Carried differently, drawn the
        // same: the importer's `positiveOrNil` on a stored zero. Not a
        // difference, and not allowed to vanish either.
        LabeledContent("  zero heart rates normalised",
                       value: "\(d.splitsWithNormalisedHR)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("Details with a different split set",
                       value: "\(d.detailsWithDifferentSplitSet.count)")
            .font(.caption)
            .foregroundStyle(d.detailsWithDifferentSplitSet.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Details with different flags",
                       value: "\(d.detailsWithDifferentFlags.count)")
            .font(.caption)
            .foregroundStyle(d.detailsWithDifferentFlags.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Details with different elevation",
                       value: "\(d.detailsWithDifferentElevation.count)")
            .font(.caption)
            .foregroundStyle(d.detailsWithDifferentElevation.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Details with a different track",
                       value: "\(d.detailsWithDifferentTrack.count)")
            .font(.caption)
            .foregroundStyle(d.detailsWithDifferentTrack.isEmpty
                             ? Color.dim : .red)
    }

    @ViewBuilder
    private func detailLapRows(_ d: DetailParity.Report) -> some View {
        LabeledContent("Laps offered to the detector",
                       value: "\(d.lapsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Details read as intervals", value: d.intervalLine)
            .font(.caption)
            .foregroundStyle(d.appDetailsReadAsIntervals
                             == d.databaseDetailsReadAsIntervals
                             ? Color.dim : .red)
        LabeledContent("Details with a different lap reading",
                       value: "\(d.detailsWithDifferentLapReading.count)")
            .font(.caption)
            .foregroundStyle(d.detailsWithDifferentLapReading.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Reps compared", value: "\(d.repsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Reps that differ", value: "\(d.repsDiffering)")
            .font(.caption)
            .foregroundStyle(d.repsDiffering == 0 ? Color.dim : .red)
        LabeledContent("  zero heart rates normalised",
                       value: "\(d.repsWithNormalisedHR)")
            .font(.caption2).foregroundStyle(Color.dim)

        // THE ROW D6a's ACCEPTED LOSS IS AIMED AT. `hasHRSplits` is the only
        // derived property that reads averageHR, and it treats a stored zero
        // and a missing value alike — so these two matching is the evidence
        // that the normalisation costs no figure.
        LabeledContent("Details with heart-rate splits", value: d.hrSplitsLine)
            .font(.caption)
            .foregroundStyle(d.appDetailsWithHRSplits
                             == d.databaseDetailsWithHRSplits
                             ? Color.dim : .red)
        LabeledContent("Details with a route", value: d.routeLine)
            .font(.caption)
            .foregroundStyle(d.appDetailsWithRoute == d.databaseDetailsWithRoute
                             ? Color.dim : .red)

        LabeledContent("Held from the app", value: DetailParity.heldFromTheApp)
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Tolerance", value: DetailParity.toleranceLabel)
            .font(.caption).foregroundStyle(Color.dim)
    }

    // MARK: Slice 5 — plan matching

    @ViewBuilder
    private var matchRows: some View {
        if let m = parity.last.matches {
            Text("Plan matching")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            matchCountRows(m)
            matchDifferenceRows(m)
        }
    }

    @ViewBuilder
    private func matchCountRows(_ m: MatchParity.Report) -> some View {
        LabeledContent("Days compared", value: "\(m.daysCompared)")
            .font(.caption)
            .foregroundStyle(m.daysCompared > 0 ? Color.dim : .red)
        LabeledContent("Planned sessions compared",
                       value: "\(m.sessionsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        // THE DENOMINATOR THAT MEANS SOMETHING. Most planned sessions resolve
        // to nothing on both sides and agree perfectly; this is the count of
        // sessions that actually claimed an activity.
        LabeledContent("  claimed an activity on both sides",
                       value: "\(m.matchesResolved)")
            .font(.caption)
            .foregroundStyle(m.matchesResolved > 0 ? Color.dim : .red)
        LabeledContent("Extras compared", value: "\(m.extrasCompared)")
            .font(.caption).foregroundStyle(Color.dim)

        LabeledContent("Days only in the app",
                       value: "\(m.daysOnlyInApp.count)")
            .font(.caption)
            .foregroundStyle(m.daysOnlyInApp.isEmpty ? Color.dim : .red)
        LabeledContent("Days only in the database",
                       value: "\(m.daysOnlyInDatabase.count)")
            .font(.caption)
            .foregroundStyle(m.daysOnlyInDatabase.isEmpty ? Color.dim : .red)
        LabeledContent("Sessions on one side only",
                       value: "\(m.sessionsOnOneSideOnly.count)")
            .font(.caption)
            .foregroundStyle(m.sessionsOnOneSideOnly.isEmpty ? Color.dim : .red)
    }

    @ViewBuilder
    private func matchDifferenceRows(_ m: MatchParity.Report) -> some View {
        // THE ROW THIS SLICE EXISTS FOR.
        LabeledContent("Sessions that claimed a different activity",
                       value: "\(m.sessionsWithADifferentActivity.count)")
            .font(.caption)
            .foregroundStyle(m.sessionsWithADifferentActivity.isEmpty
                             ? Color.dim : .red)
        ForEach(m.sessionsWithADifferentActivity.prefix(6), id: \.self) { u in
            Text("    \(u)").font(.caption2).foregroundStyle(.red)
        }
        // AND THE ONE THAT TURNS 4/4 INTO 3/4.
        LabeledContent("Sessions done on one side only",
                       value: "\(m.sessionsDoneOnOneSideOnly.count)")
            .font(.caption)
            .foregroundStyle(m.sessionsDoneOnOneSideOnly.isEmpty
                             ? Color.dim : .red)
        ForEach(m.sessionsDoneOnOneSideOnly.prefix(6), id: \.self) { u in
            Text("    \(u)").font(.caption2).foregroundStyle(.red)
        }
        LabeledContent("Sessions chosen a different way",
                       value: "\(m.sessionsWithADifferentSource.count)")
            .font(.caption)
            .foregroundStyle(m.sessionsWithADifferentSource.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Days with different extras",
                       value: "\(m.daysWithDifferentExtras.count)")
            .font(.caption)
            .foregroundStyle(m.daysWithDifferentExtras.isEmpty
                             ? Color.dim : .red)
        LabeledContent("Days with a different extras order",
                       value: "\(m.daysWithDifferentExtraOrder.count)")
            .font(.caption)
            .foregroundStyle(m.daysWithDifferentExtraOrder.isEmpty
                             ? Color.dim : .red)

        // THE WEEK SCREEN'S OWN FIGURE, both sides. A reader can hold this
        // against the Week tab without pressing anything else.
        LabeledContent("Adherence", value: m.adherenceLine)
            .font(.caption)
            .foregroundStyle(m.appSessionsDone == m.databaseSessionsDone
                             ? Color.dim : .red)
        // ZERO IS THE HONEST ANSWER TODAY — match_decision holds no rows.
        // Printed so that "no differences" is not read as coverage of the
        // override branch, which was never entered.
        LabeledContent("Overrides applied", value: "\(m.overridesApplied)")
            .font(.caption).foregroundStyle(Color.dim)

        LabeledContent("Held from the app", value: MatchParity.heldFromTheApp)
            .font(.caption).foregroundStyle(Color.dim)
        // PATCH 322. One of the three is now checked by the authored
        // read-back rather than assumed.
        LabeledContent("Of those, verified",
                       value: MatchParity.verifiedByReadBack)
            .font(.caption).foregroundStyle(Color.dim)
    }

    // MARK: - Slice 8, in a section of its own — patch 330b

    /// A SECTION OF ITS OWN, AND THREE FUNCTIONS INSTEAD OF ONE.
    ///
    /// It reads better than appending to the section above: §12.40.1 measured
    /// that a screen nobody scrolls to the bottom of is a screen whose bottom
    /// rows are not read, and slice 8's figures were the bottom of the bottom.
    @ViewBuilder
    private var summaryParitySection: some View {
        if let s = parity.last.summaries {
            Section {
                summaryWeekRows(s)
                summaryDayAndVolumeRows(s)
                summaryContextRows(s)
            } header: {
                Text("Shadow parity · tab summaries")
            } footer: {
                Text(Self.summaryFooter).font(.caption2)
            }
        } else if case .ran = parity.last {
            Section {
                LabeledContent("Compared",
                               value: "the plan could not be read from the database")
                    .font(.caption).foregroundStyle(.red)
            } header: {
                Text("Shadow parity · tab summaries")
            }
        }
    }

    @ViewBuilder
    private func summaryWeekRows(_ s: SummaryParity.Report) -> some View {
        LabeledContent("Compared", value: s.summary)
            .font(.caption)
            .foregroundStyle(s.lookedAtSomething ? Color.dim : .red)
        LabeledContent("Weeks in each side",
                       value: "\(s.weeksInApp) vs \(s.weeksInDatabase)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Weeks compared", value: "\(s.weeksCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("  fields compared", value: "\(s.weekFieldsCompared)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("Only in the app", value: "\(s.weeksOnlyInApp.count)")
            .font(.caption)
            .foregroundStyle(s.weeksOnlyInApp.isEmpty ? Color.dim : .red)
        LabeledContent("Only in the database", value: "\(s.weeksOnlyInDatabase.count)")
            .font(.caption)
            .foregroundStyle(s.weeksOnlyInDatabase.isEmpty ? Color.dim : .red)
        LabeledContent("Week fields that differ", value: "\(s.weekDifferences.count)")
            .font(.caption)
            .foregroundStyle(s.weekDifferences.isEmpty ? Color.dim : .red)
        ForEach(s.weekDifferences.prefix(6), id: \.self) { d in
            Text("    \(d)").font(.caption2).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryDayAndVolumeRows(_ s: SummaryParity.Report) -> some View {
        // THE ONLY PLACE A DAY-SHAPED HOLE COULD SHOW. Every figure above is
        // per WEEK, and the day closure returns an empty day for a key the
        // database has nothing for — indistinguishable from a day that holds
        // nothing unless it is counted. §12.75.4.
        LabeledContent("Days asked for", value: "\(s.daysAskedFor)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("  with anything in each side",
                       value: "\(s.daysWithContentInApp) vs \(s.daysWithContentInDatabase)")
            .font(.caption2)
            .foregroundStyle(s.daysWithContentInApp == s.daysWithContentInDatabase
                             ? Color.dim : .red)

        LabeledContent("Volume rows compared", value: "\(s.volumeRowsCompared)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("  fields compared", value: "\(s.volumeFieldsCompared)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("Volume figures that differ", value: "\(s.volumeDifferences.count)")
            .font(.caption)
            .foregroundStyle(s.volumeDifferences.isEmpty ? Color.dim : .red)
        ForEach(s.volumeDifferences.prefix(4), id: \.self) { d in
            Text("    \(d)").font(.caption2).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryContextRows(_ s: SummaryParity.Report) -> some View {
        LabeledContent("Block sessions", value: s.blockLine)
            .font(.caption)
            .foregroundStyle(s.blockDiffers ? .red : Color.dim)
        // CONTEXT, NOT A DIFFERENCE — slice 6b owns the plan. But a slice
        // reading 261 against 260 would produce week differences with no
        // visible cause, and this is the line that gives one.
        LabeledContent("Plan sessions each side read",
                       value: "\(s.planSessionsInApp) vs \(s.planSessionsInDatabase)")
            .font(.caption2)
            .foregroundStyle(s.planSessionsInApp == s.planSessionsInDatabase
                             ? Color.dim : .red)
        LabeledContent("Tolerance", value: SummaryParity.toleranceLabel)
            .font(.caption2).foregroundStyle(Color.dim)
        // SHORTER THAN EVERY OTHER SLICE'S, and that is the point.
        LabeledContent("Held from the app", value: SummaryParity.heldFromTheApp)
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Of those, verified", value: SummaryParity.verifiedByReadBack)
            .font(.caption2).foregroundStyle(Color.dim)
    }

    // MARK: - Running it

    private func runParity() {
        // The runner holds the result now, so it survives this sheet being
        // dismissed — patch 313. It also does the read off the main actor,
        // which is what lets the spinner draw before the work starts.
        Task { await parity.run(db) }
    }

    // MARK: - Footers

    /// HOISTED, like `reviewFooter` at 327a and for the same reason: a
    /// twenty-clause string concatenation inside a `Section`'s footer builder
    /// is type-checker work paid on every rebuild of the enclosing view.
    private static let parityFooter =
        "Builds the activity list a second time, from the database "
      + "instead of the files, and compares what the app would "
      + "derive from each. Both sides run through the same rules — "
      + "one copy, called twice — so a difference here is a "
      + "difference in the DATA, not in how it was derived.\n\n"
      + "It does not re-check fields. The read-backs above do "
      + "that.\n\n"
      + "Volume is compared with a tolerance, because two identical "
      + "sums of decimals can end in a different last digit. A "
      + "difference under a metre or a second is arithmetic; "
      + "anything larger is data.\n\n"
      + "Rows the rules dropped are not disagreements: the database "
      + "is carrying something the app no longer wants, which is "
      + "what automatic write-throughs not reconciling looks like. "
      + "Details excluded on purpose are not disagreements either — "
      + "two sessions are refused by name. Every other number above "
      + "zero is real.\n\n"
      + "Details, splits and laps compare what the activity screen "
      + "would DERIVE: the closing, opening and best-window paces, "
      + "the split table, and what the laps read as. The plan is not "
      + "consulted, so laps are read with no cut pace — that is "
      + "slice 5. A pace that is missing on both sides agrees and "
      + "proves nothing, which is why the figures BOTH sides "
      + "answered are counted separately.\n\n"
      + "Heart rates are compared as the tables DRAW them — every "
      + "one of them guards `hr > 0`, so a stored zero and a missing "
      + "value are the same pixel. What is carried differently and "
      + "drawn the same is counted on its own line, dim, because a "
      + "row that vanishes once it is understood is a row nobody can "
      + "watch. See ADR-0003 §12.63.8.\n\n"
      + "Plan matching runs the app's own resolver twice, over two "
      + "activity lists. The plan, the match decisions and the "
      + "commute decisions come from the app on both sides, so the "
      + "only thing that moves is the activities. A vague session "
      + "takes the first candidate, so the ORDER of that list "
      + "decides what it claims — which is why this slice's answer "
      + "rests on the list slice reporting zero order "
      + "disagreements. See ADR-0003 §12.64.\n\n"
      + "The fitness comparison holds the constants, your zones, "
      + "the FTP, your session RPEs and Apple Health identical on "
      + "both sides — the database has no reader for them yet, and "
      + "Health it will never have. So it answers one question: do "
      + "the database's activities and traces produce the same "
      + "load, and the same shape underneath it.\n\n"
      + "A training load is an integral over the heart-rate trace. "
      + "The distribution it integrates is what the Time-in-zone "
      + "card draws, and two different distributions can add up to "
      + "the same load — so both are compared. See ADR-0003 "
      + "§12.56, §12.57, §12.59 and §12.60."

    /// Hoisted, like `reviewFooter` at 327a and for the same reason.
    private static let summaryFooter =
        "Slice 8 — what the Progress chart and the Week card add up to, "
      + "derived a second time from the database. The week points, the four "
      + "volume rows, and the block tally.\n\n"
      + "THE ONLY SLICE THAT READS THE PLAN FROM THE DATABASE. Every other "
      + "one holds it from the app and lets the plan read-back verify it "
      + "separately, so this is the closest thing on this screen to what the "
      + "cutover will actually do.\n\n"
      + "The longest run is a maximum rather than a sum, which makes it the "
      + "one figure a matching total cannot hide — two runs of 10 + 10 and "
      + "4 + 16 agree on 20 km and disagree on the longest.\n\n"
      + "Days asked for is here because every other figure is per week: a "
      + "handful of missing days would barely move one of them, and a day the "
      + "database has nothing for looks exactly like a day with nothing in "
      + "it. ADR-0003 §12.75."
}
