//
//  Appearance.swift
//  Sub4
//
//  Dark, light, or follow the phone.
//
//  WHY THIS IS THREE VALUES AND NOT A SWITCH
//  -----------------------------------------
//  A two-position toggle forces a choice the phone has usually already made
//  correctly, and it cannot express "whatever iOS is doing". Automatic is the
//  default for exactly that reason: on a phone with a sunset schedule, the app
//  should follow it without being told twice.
//
//  WHERE IT IS APPLIED
//  -------------------
//  Once, at the root, by setting the WINDOW's interface style. Nothing else in
//  the app reads this value — every colour resolves itself through the dynamic
//  providers in Theme.swift, so a scheme change is a trait-collection change and
//  everything hosted in that window redraws from it. There is deliberately no
//  observable palette object: two sources of truth about appearance is how a
//  chart ends up one scheme behind the card it sits on.
//
//  Note for sheets: this sets the WINDOW's interface style, not a SwiftUI
//  preference, so sheets, popovers, alerts and system controls all follow. The
//  first version used `.preferredColorScheme` and did not — see the note on
//  `AppearanceScheme` for why that failed on the one screen it mattered most.
//

import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automatic"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }

    /// The window trait this maps to. `.unspecified` hands the decision back to
    /// iOS — it is not a synonym for light.
    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light:  .light
        case .dark:   .dark
        }
    }
}

enum AppearanceKey {
    static let selected = "appearance.selected"
}

/// Applied at the root and nowhere else.
///
/// WHY THIS SETS THE WINDOW AND NOT `preferredColorScheme`
/// ------------------------------------------------------
/// Patch 99 used `.preferredColorScheme` on the TabView. It worked for the four
/// tabs and for nothing else — flipping the toggle left the Settings sheet you
/// were flipping it in unchanged, which is the one screen guaranteed to be on
/// top when the switch is thrown.
///
/// `preferredColorScheme` is a PREFERENCE. It travels upwards to the enclosing
/// presentation and sets that. A sheet is its own presentation: it does not
/// inherit the preference the presenting view set on the window, so Settings,
/// the info sheets, the manual, the diagnostics screen and every alert stayed on
/// whatever the phone was doing. Chasing that by adding the modifier to each
/// sheet's content would mean remembering to add it to the next one too.
///
/// `overrideUserInterfaceStyle` on the window is a TRAIT. Everything hosted in
/// that window inherits it — sheets, popovers, alerts, the keyboard, and the
/// system controls inside a `Form` — and every colour in Theme.swift resolves
/// off exactly that trait collection. One assignment, no per-presentation
/// bookkeeping, and nothing left to forget.
struct AppearanceScheme: ViewModifier {
    @AppStorage(AppearanceKey.selected) private var raw = Appearance.system.rawValue

    private var appearance: Appearance { Appearance(rawValue: raw) ?? .system }

    func body(content: Content) -> some View {
        content
            // On change for the switch itself; on appear so a cold launch picks
            // up the stored value before the first frame is looked at.
            .onAppear { apply(appearance) }
            .onChange(of: raw) { _, _ in apply(appearance) }
    }

    /// `.unspecified` is what hands the decision back to iOS — it is not "light".
    @MainActor
    private func apply(_ a: Appearance) {
        let style = a.style
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

extension View {
    func appearanceScheme() -> some View { modifier(AppearanceScheme()) }
}
