//
//  ReleaseGatesView.swift
//  Sub4
//
//  The switches from ReleaseGates, made visible — patch 178, plan step 0.3.
//
//  WHY THE REASON IS ON SCREEN AND NOT IN A COMMIT MESSAGE
//  ------------------------------------------------------
//  A switch that is off for a reason the reader cannot see reads as a fault,
//  and a fault gets fixed — by turning it back on. Each row therefore carries
//  two sentences that have to be there for the control to mean anything: what
//  crosses the boundary if it is open, and why it is currently shut. Neither is
//  decoration. The first is the consent, the second is the argument.
//
//  This is also the app's own promise applied to itself. Sub4's release promise
//  is that every figure is traceable to its evidence and that an absence is
//  never presented as a measurement. A compliance layer that silently stopped
//  the sync and let the user conclude Strava was broken would be the one screen
//  in the app breaking the rule the rest of it is built on.
//

import SwiftUI

struct ReleaseGatesView: View {

    /// Local mirror. `ReleaseGates` reads UserDefaults directly, which SwiftUI
    /// does not observe, so the toggles need a state of their own to animate
    /// from. Seeded on appear and written straight through on change.
    @State private var open: [String: Bool] = [:]

    /// Set when a gate needs consent before it may be opened — patch 193.
    /// A value rather than a Bool so the sheet cannot be shown without knowing
    /// which gate asked for it.
    struct ConsentRequest: Identifiable {
        let id = UUID()
        let gate: ReleaseGate
    }
    @State private var consent: ConsentRequest?

    var body: some View {
        Section {
            ForEach(ReleaseGate.allCases) { gate in
                row(gate)
            }
        } header: {
            Text("External data transfers")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(ReleaseGates.distributionLabel)
                Text("Each switch controls a request that leaves this phone. "
                     + "They are checked where the request is built rather than "
                     + "where the button is, so nothing in the app can go around "
                     + "them — including the background refresh.")
                Text("Reasoning: ADR-0002 in the project repository.")
                    .foregroundStyle(Color.dim.opacity(0.8))
            }
            .font(.caption2)
        }
        .onAppear {
            for g in ReleaseGate.allCases { open[g.rawValue] = ReleaseGates.isOpen(g) }
        }
        // PRIV-04. The only gate that needs it today is coordinateWeather; the
        // sheet is chosen by gate rather than hard-coded here so a second one
        // that transmits something identifying can ask too.
        .sheet(item: $consent) { request in
            switch request.gate {
            case .coordinateWeather:
                LocationConsentView { grant(request.gate) }
            default:
                // Unreachable while coordinateWeather is the only gate that
                // requires consent, and a screen rather than a crash if that
                // stops being true.
                LocationConsentView { grant(request.gate) }
            }
        }
    }

    private func row(_ gate: ReleaseGate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding(gate)) {
                Text(gate.title).font(.subheadline)
            }
            .disabled(!gate.permitted)

            // WHAT IT SENDS — always shown, open or shut. Reading it only when
            // the switch is already on is reading it too late.
            Label {
                Text(gate.transmits)
            } icon: {
                Image(systemName: "arrow.up.forward.app")
            }
            .font(.caption2)
            .foregroundStyle(Color.dim)

            // WHY IT IS SHUT — only while it is.
            if !isOpen(gate) {
                Label {
                    Text(gate.reasonClosed)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.caption2)
                .foregroundStyle(Color.accent4.opacity(0.9))
            }

            if !gate.permitted {
                Text("This build cannot switch it on.")
                    .font(.caption2)
                    .foregroundStyle(Color.dim.opacity(0.7))
            }
        }
        .padding(.vertical, 3)
    }

    private func isOpen(_ gate: ReleaseGate) -> Bool {
        open[gate.rawValue] ?? ReleaseGates.isOpen(gate)
    }

    /// Writes through on every change rather than on a Save button. There is no
    /// draft state worth having here — the switch IS the decision, and a gate
    /// that is on in the UI and off in the store, or the reverse, is the exact
    /// confusion this screen exists to prevent.
    private func binding(_ gate: ReleaseGate) -> Binding<Bool> {
        Binding(
            get: { isOpen(gate) },
            set: { v in
                // OPENING a gate that transmits a location asks first — PRIV-04.
                // Closing never does: withdrawing consent is not a decision that
                // needs confirming, and a sheet in front of "stop sending my
                // location" would be the wrong kind of friction.
                if v, gate.needsLocationConsent, !ReleaseGates.hasLocationConsent {
                    consent = ConsentRequest(gate: gate)
                    // The toggle stays where it was. It moves when the sheet
                    // comes back with an answer, so the switch never shows a
                    // state the app has not actually entered.
                    open[gate.rawValue] = ReleaseGates.isOpen(gate)
                    return
                }
                ReleaseGates.set(gate, open: v)
                // Read BACK rather than trusting the write. In an external
                // build `set` is a no-op, and the toggle must return to where
                // it was rather than showing a state the app will not honour.
                open[gate.rawValue] = ReleaseGates.isOpen(gate)
            }
        )
    }

    /// Called by the consent sheet, and only by it.
    private func grant(_ gate: ReleaseGate) {
        ReleaseGates.recordLocationConsent()
        ReleaseGates.set(gate, open: true)
        open[gate.rawValue] = ReleaseGates.isOpen(gate)
    }
}
