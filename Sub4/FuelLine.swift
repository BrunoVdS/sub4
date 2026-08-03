//
//  FuelLine.swift
//  Sub4
//
//  The plan's fuelling line, on a session row.
//
//  One view, used by Today, Week, Plan and the session sheet — the same rule
//  the note button follows. A fuelling instruction that appears on one screen
//  and not another is one you cannot rely on, and the whole reason this was
//  worth extracting is that it is per-session advice you read before going out.
//
//  "Water only" is drawn quieter than the rest. It is 78 of the 180 lines, and
//  it says there is nothing to carry — rendering that with the same weight as
//  "~80 g/hr · race fuel" would train you to stop reading the strip.
//

import SwiftUI

struct FuelLine: View {

    let session: Session
    /// Tapping opens the fuelling reference. Nil where there is nowhere to go.
    var onOpen: (() -> Void)?

    private var text: String? {
        guard let f = session.fuel?.trimmingCharacters(in: .whitespaces),
              !f.isEmpty else { return nil }
        return f
    }

    var body: some View {
        if let t = text {
            let quiet = session.fuelIsWaterOnly
            let pointer = session.fuelPointsAtLadder || session.fuelPointsAtRaceDay
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: quiet ? "drop" : "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(quiet ? Color.dim.opacity(0.6) : Color.accent4)
                    .padding(.top, 1)

                Text(t)
                    .font(.caption2)
                    .foregroundStyle(quiet ? Color.dim.opacity(0.75) : Color.dim)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if pointer, onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(Color.accent4)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Only the pointer lines are tappable. Making "Water only" open a
            // reference screen would be a control that does nothing useful.
            .onTapGesture { if pointer { onOpen?() } }
        }
    }
}

// MARK: - The rehearsal marker
//
// Three sessions in the whole plan carry one — the long runs where the race
// warm-up gets practised. Rare enough that it can afford to look different from
// the fuel line, and important enough that it should: the plan's rule is
// "nothing new on the day", and these are the only three chances to make that
// true for the warm-up.

struct PrepLine: View {

    let session: Session
    var onOpen: (() -> Void)?

    var body: some View {
        if let p = session.prep?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            let tint: Color = session.prepIsRaceDay
                ? Color.accent4
                : Color.longRunTint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: session.prepIsRaceDay
                      ? "figure.run" : "arrow.trianglehead.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                Text(p)
                    .font(.caption2)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(tint)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
        }
    }
}
