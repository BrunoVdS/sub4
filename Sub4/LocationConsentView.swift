//
//  LocationConsentView.swift
//  Sub4
//
//  Asked before a coordinate leaves — patch 193, plan step 2.4.5, finding
//  PRIV-04.
//
//  WHAT WAS WRONG
//  --------------
//  The weather feature sends where an activity started — to about eleven metres
//  — and the time it happened, to Apple Weather or to Open-Meteo. There was no
//  consent screen. The release gate stood in for one, and the inventory said so
//  in `gaps` rather than pretending otherwise.
//
//  A gate is a good switch and a poor consent. It says what it sends in a row of
//  a settings list, next to four other rows, and a person flipping it is
//  choosing to enable a feature rather than agreeing to a transfer. Those are
//  different acts even when the same finger performs them.
//
//  WHY ONE SHEET AT THE SWITCH
//  ---------------------------
//  The alternative was asking the first time a particular activity needed
//  weather. That is closer to the moment data moves, and worse: it arrives as an
//  interruption while somebody is reading a session, which is precisely when
//  people tap through a prompt to get back to what they were doing. Consent
//  collected that way is a formality.
//
//  At the switch, the person has just decided to think about transfers, the
//  screen has their attention, and declining costs them nothing they were in
//  the middle of. One decision, at the moment it becomes real.
//
//  IT NAMES THE PRECISION
//  ----------------------
//  "Your location" would be a lie by vagueness. Eleven metres is a doorway. The
//  sheet says the number, says the track is never sent, and says which two
//  companies could receive it — because "a weather provider" is not a party you
//  can form a view about.
//

import SwiftUI

struct LocationConsentView: View {

    /// True when the reader agrees. The gate is opened by the caller, not here —
    /// a consent screen that also performs the action it is asking about makes
    /// "cancel" ambiguous.
    var onAgree: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("To show the weather for a session, Sub4 sends two "
                         + "things to a weather service:")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    line("Where the activity started",
                         "A single coordinate, accurate to about 11 metres. "
                         + "Close enough to identify a doorway.")
                    line("When it happened",
                         "The date and the hours it covered.")
                }

                Section {
                    line("The route is never sent",
                         "Only the starting point. The track itself stays on "
                         + "this phone.")
                    line("Nothing is sent for a session you do not open",
                         "The request happens when weather is fetched for an "
                         + "activity, not in the background for all of them.")
                } header: {
                    Text("What is not sent")
                }

                Section {
                    line("Apple Weather", "Covered by Apple's privacy policy.")
                    line("Open-Meteo",
                         "An open weather service in Germany, used when Apple "
                         + "has no answer for a past date.")
                } header: {
                    Text("Who receives it")
                } footer: {
                    Text("Sub4 tries Apple first and falls back to Open-Meteo. "
                         + "Each stored reading records which one answered, and "
                         + "the activity card credits it.")
                        .font(.caption2)
                }

                Section {
                    Text("You can switch this off again at any time in Data & "
                         + "privacy. Weather already fetched stays until you "
                         + "clear it, and Clear cached weather removes it.")
                        .font(.caption)
                        .foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Sending a location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // NOT "Cancel". The reader is declining a transfer, and the
                    // word should say so — a cancel button reads as "go back",
                    // which is not the decision being recorded.
                    Button("Don't send") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Allow") {
                        onAgree()
                        dismiss()
                    }
                }
            }
        }
    }

    private func line(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(detail).font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}
