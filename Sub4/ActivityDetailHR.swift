//
//  ActivityDetailHR.swift
//  Sub4
//
//  Heart rate: the summary card, per-session time in zone, and the split-average fallback chart.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI
import Charts

extension ActivityDetailView {

    // MARK: Heart rate

    @ViewBuilder
    var hrCard: some View {
        if !hrIsRedundant,
           activity.averageHeartrate != nil || (detail?.hasHRSplits ?? false) {
            VStack(alignment: .leading, spacing: 9) {
                // The ⓘ opens the same zones glossary as the Progress card,
                // which now carries a group for this single-session view —
                // one topic for one quantity, wherever it appears.
                HStack(spacing: 6) {
                    Text("HEART RATE").font(.caption2.weight(.bold)).tracking(0.5)
                    InfoButton(topic: .zones)
                    Spacer()
                    Text(hrSummary).font(.caption2)
                }
                .foregroundStyle(Color.dim)

                if let hr = activity.averageHeartrate,
                   let z = athlete.zone(forHR: hr) {
                    ZoneChip(zone: z, bpm: Int(hr), showName: true)
                }

                // WHERE THE PEAK ZONE CAME FROM. The profile chart printed
                // "Heart rate peaks at 143 bpm — zone Z3, tempo" under its own
                // panel, two hundred points below a card already stating avg and
                // max. Two heart-rate statements about one run, disagreeing on
                // which zone to name. One statement now, here, where the rest of
                // the heart rate is.
                //
                // The zone BOUNDS stay in words rather than beside the chip:
                // the chip carries the name, this carries the numbers, and
                // neither repeats the other.
                if let line = hrZoneLine {
                    Text(line).font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                zoneBars

                // Per-kilometre averages only when there's no full profile —
                // once the stream is cached the chart above says the same thing
                // at far better resolution, and two versions of one measure on
                // one screen is just clutter.
                if store.streams(for: activity.id) == nil,
                   let d = detail, d.hasHRSplits, d.displaySplits.count >= 3 {
                    hrChart(d)
                }
            }
            .cardStyle()
        }
    }

    /// The label the hero row uses for average heart rate. A constant because
    /// `hrIsRedundant` matches on it: if the two ever disagree the card silently
    /// stops disappearing, which is a bug nobody would think to look for.
    static let avgHRLabel = "Avg HR"

    /// GONE WHEN THE PAGE ALREADY SAYS ALL OF IT — patch 149.
    ///
    /// On a walk this card was the third statement of the same number: the hero
    /// row prints "Avg HR 84", the card's own subtitle prints "avg 84 · max 96",
    /// and the profile chart prints "84 bpm" over the trace. Three of one fact
    /// on one screen.
    ///
    /// BOTH HALVES ARE REQUIRED, and that is what keeps this from being a blunt
    /// "hide it on walks":
    ///
    ///   the hero row shows Avg HR — true only for the disciplines whose hero
    ///   metrics are Duration / Avg HR / Energy, which is walks, kayaks, rows
    ///   and strength. A run's hero row is distance and pace, so a run keeps
    ///   the card and keeps its zone.
    ///
    ///   the profile chart is on screen — a Hevy circuit has heart rate and no
    ///   GPS, so there is no trace below to carry it. That session keeps the
    ///   card, and with it the only place its max and its zone are printed.
    ///
    /// WHAT IS ACTUALLY LOST, STATED. On a GPS walk: the max figure, and the
    /// zone chip. The chip is the only genuinely unique thing on the card, and
    /// "Z1 Recovery" on a lunchtime walk is not news — but it IS a removal
    /// rather than a de-duplication, and pretending otherwise would be the kind
    /// of quiet loss this project writes these notes to avoid.
    var hrIsRedundant: Bool {
        guard heroMetrics.contains(where: { $0.label == Self.avgHRLabel }) else { return false }
        return store.streams(for: activity.id)?.isUsable == true
    }

    // MARK: Time in zone, for this session
    //
    // THE DATA WAS ALREADY THERE. `LoadEngine` walks every cached trace once per
    // rebuild to integrate TRIMP, and since patch 91 that same walk records
    // seconds per bpm on each `WorkoutLoad`. The Progress card sums those across
    // a window; this reads one of them. Nothing new is computed and nothing new
    // is stored.
    //
    // WHY IT BELONGS BESIDE THE CHIP RATHER THAN INSTEAD OF IT. The chip says
    // which zone the AVERAGE landed in, and the whole argument for building this
    // card at all — see the header of ZoneTime — is that an average is not a
    // distribution: forty minutes easy and twenty hard averages into Z3 having
    // spent no time there. The chip is the one-line answer and the bars are the
    // shape; printing the shape does not make the summary wrong, it makes the
    // summary readable.
    //
    // TIME IN THE LABEL, NOT A PERCENTAGE. The Progress card uses shares because
    // it is comparing months to each other. One session has a duration you would
    // quote out loud — "sixteen minutes in Z2" — and a share of a number that is
    // itself on the same card is arithmetic asked of the reader.
    @ViewBuilder
    var zoneBars: some View {
        let zones = athlete.hrZones
        if !zones.isEmpty, let w = workoutLoad {
            let totals = ZoneTotals.build(w, zones: zones)
            if !totals.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(zones) { z in
                        zoneRow(z, seconds: totals.seconds[z.index] ?? 0,
                                of: totals.totalSeconds)
                    }
                    // WHY THIS DOES NOT ADD UP TO YOUR MOVING TIME, said here
                    // rather than left to be noticed. Bins under 0.3 m/s are
                    // dropped by the integral — standing at a crossing is not
                    // time in a zone — so a session with stops contributes less
                    // than its clock suggests. That is the correct answer and
                    // not a shortfall, but only if it is stated.
                    Text(zoneFootnote(totals))
                        .font(.system(size: 9)).foregroundStyle(Color.dim)
                }
                .padding(.top, 2)
            }
        }
    }

    func zoneRow(_ z: AthleteStore.HRZone,
                         seconds: Double, of total: Double) -> some View {
        let f = total > 0 ? seconds / total : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(z.titled).font(.caption2).foregroundStyle(Color.dim)
                Spacer(minLength: 4)
                Text(seconds >= 1 ? Fmt.duration(Int(seconds.rounded())) : "—")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(seconds >= 1 ? Color.ink : Color.dim)
            }
            // A track behind every bar, so a zone with no time still occupies a
            // row and the five read as one scale rather than as a ragged list.
            TrackBar(fraction: f, tint: z.color)
        }
    }

    func zoneFootnote(_ t: ZoneTotals) -> String {
        let traced = Int(t.totalSeconds.rounded())
        let clock = duration
        guard clock > traced + 30 else {
            return "\(Fmt.duration(traced)) traced."
        }
        return "\(Fmt.duration(traced)) traced of \(Fmt.duration(clock)) — "
             + "the rest was below the moving threshold."
    }

    /// This activity's row in the load series, which is where the histogram is.
    var workoutLoad: WorkoutLoad? {
        load.day(activity.dayKey)?.workouts.first { $0.activityId == activity.id }
    }

    var hrSummary: String {
        var p: [String] = []
        if let a = activity.averageHeartrate { p.append("avg \(Int(a))") }
        if let m = activity.maxHeartrate { p.append("max \(Int(m))") }
        return p.joined(separator: " · ")
    }

    /// "peaks into Z3 · your Z2 is 116–139 bpm" — the peak zone taken off the
    /// profile chart, and the bounds taken off the chip's trailing text.
    ///
    /// Assembled as a String outside any view builder, per the rule in
    /// VolumeCard.
    var hrZoneLine: String? {
        guard let avg = activity.averageHeartrate,
              let z = athlete.zone(forHR: avg) else { return nil }
        var parts: [String] = []
        // Only when it differs — "peaks into Z2" on a Z2 run says nothing.
        if let peak = peakHR, let pz = athlete.zone(forHR: peak),
           pz.index > z.index {
            parts.append("peaks into " + pz.label)
        }
        parts.append("your " + z.label + " is " + z.range + " bpm")
        return parts.joined(separator: " · ")
    }

    /// The trace's own maximum where there is one, Strava's otherwise.
    var peakHR: Double? {
        if let hr = store.streams(for: activity.id)?.heartRate, let m = hr.max(), m > 30 {
            return m
        }
        return activity.maxHeartrate
    }

    func hrChart(_ d: ActivityDetail) -> some View {
        let rows: [HRPoint] = d.displaySplits.compactMap { s in
            guard let hr = s.averageHR, hr > 0 else { return nil }
            return HRPoint(id: s.index, bpm: hr)
        }
        return Chart {
            ForEach(rows) { row in
                LineMark(x: .value("km", row.id), y: .value("bpm", row.bpm))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(height: 90)
    }

}
