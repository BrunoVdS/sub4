//
//  ActivityDetailExtras.swift
//  Sub4
//
//  Laps, best efforts, the fact-row footer and the pending-fetch note.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI

extension ActivityDetailView {

    // MARK: Laps — the swim layout's core

    @ViewBuilder
    var lapsCard: some View {
        if activity.discipline == .swim, let d = detail, d.laps.count >= 2 {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("INTERVALS", "\(d.laps.count) laps")
                ForEach(d.laps) { lap in
                    HStack(spacing: 10) {
                        Text("\(lap.index)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(Color.dim).frame(width: 20, alignment: .trailing)
                        Text(String(format: "%.0f m", lap.distanceM))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(lapPace(lap)).font(.caption).monospacedDigit()
                            .foregroundStyle(tint)
                        Text(Fmt.duration(lap.movingTime))
                            .font(.caption2).monospacedDigit().foregroundStyle(Color.dim)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
            .cardStyle()
        }
    }

    func lapPace(_ lap: ActivityDetail.Lap) -> String {
        guard lap.distanceM > 20 else { return "—" }
        let s = Int((Double(lap.movingTime) / (lap.distanceM / 100)).rounded())
        return String(format: "%d:%02d /100m", s / 60, s % 60)
    }

    // MARK: Best efforts

    @ViewBuilder
    var effortsCard: some View {
        if activity.discipline == .run, let d = detail, !d.bestEfforts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("BEST EFFORTS", "within this run")
                ForEach(d.bestEfforts) { e in
                    HStack {
                        Text(e.name).font(.caption)
                        Spacer()
                        Text(e.timeLabel).font(.caption.weight(.bold))
                            .monospacedDigit().foregroundStyle(tint)
                    }
                    .foregroundStyle(Color.dim)
                }
            }
            .cardStyle()
        }
    }

    // MARK: Footer

    @ViewBuilder
    var footerCard: some View {
        let rows = footerRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in
                    HStack {
                        Text(row.id).font(.caption).foregroundStyle(Color.dim)
                        Spacer()
                        Text(row.value).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    var footerRows: [FactRow] {
        var r: [FactRow] = []
        // Elevation is gone: it is the hero row's "Climb", the same number under
        // a second name forty rows further down.
        if let c = detail?.calories, c > 0 {
            r.append(FactRow(id: "Energy", value: "\(Int(c)) kcal"))
        }
        if let w = detail?.averageWatts, w > 0 {
            let maxPart = detail?.maxWatts.map { " · \(Int($0)) W max" } ?? ""
            r.append(FactRow(id: "Power", value: "\(Int(w)) W avg" + maxPart))
        }
        if let c = detail?.averageCadence, c > 0 {
            // Strava reports run cadence one-legged; doubling gives steps/min.
            let isRun = activity.discipline == .run
            let value = Int(((isRun ? c * 2 : c)).rounded())
            r.append(FactRow(id: "Cadence", value: "\(value) \(isRun ? "spm" : "rpm")"))
        }
        if let shoe = athlete.shoe(id: activity.gearId) {
            r.append(FactRow(id: "Shoe", value: "\(shoe.name) · \(Int(shoe.km)) km"))
        }
        if let dev = detail?.deviceName, !dev.isEmpty {
            r.append(FactRow(id: "Device", value: dev))
        }
        if activity.elapsedTime > activity.movingTime + 60 {
            r.append(FactRow(id: "Elapsed", value: Fmt.duration(activity.elapsedTime)))
        }
        // Provenance, next to the recorded figures it overrides. A corrected
        // number with no source on the page is indistinguishable from a wrong
        // one, and the whole point of the correction is that it is checkable.
        if let o = DataCorrections.official(activity) {
            r.append(FactRow(id: "Watch", value: Fmt.duration(activity.movingTime)
                                                 + " moving · not used"))
            r.append(FactRow(id: "Timing", value: o.source))
        }
        if let note = detail?.descriptionText, !note.isEmpty {
            r.append(FactRow(id: "Note", value: note))
        }
        return r
    }

    // MARK: Pending

    var isIncomplete: Bool {
        detail == nil || store.isQueued(activity.id)
    }

    @ViewBuilder
    var pendingNote: some View {
        if isIncomplete {
            HStack(spacing: 8) {
                if store.isFetching || store.isQueued(activity.id) {
                    ProgressView().controlSize(.small)
                    Text("Downloading splits, route and profile…")
                } else if let until = store.rateLimitedUntil, Date() < until {
                    Image(systemName: "clock")
                    Text("Strava's rate limit is full — the rest arrives shortly.")
                } else {
                    Image(systemName: "icloud.slash")
                    Text("No detail for this activity yet.")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(Color.dim)
            .cardStyle()
        }
    }

}
