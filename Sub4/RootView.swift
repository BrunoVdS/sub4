//
//  RootView.swift
//  Sub4
//
//  The gate that owns launch — patch 215, plan step 3.3.1.
//
//  WHY THIS IS A BRANCH AND NOT A MODIFIER
//  ---------------------------------------
//  The whole point is that `ContentView()` is not CONSTRUCTED until the
//  database has been migrated. SwiftUI's `ViewBuilder` does not build the arm
//  it does not take, so putting `ContentView()` behind `if launch.isFinished`
//  is what defers `ContentView.init` — and with it the `init` of every store
//  it holds as `@State`, each of which reads its own file synchronously.
//
//  An `.onAppear` or a `.task` on `ContentView` would be too late by
//  construction: the properties are initialised before either runs. This is the
//  only hook in SwiftUI that is early enough and still has somewhere to put an
//  error. See `Sub4Launch`'s header for why not `Sub4App.init()`.
//
//  WHY THE PLACEHOLDER TRIES NOT TO BE SEEN
//  ----------------------------------------
//  After the first run the migration is a few milliseconds. A spinner that
//  flashes for three frames on every single launch is worse than no spinner:
//  it reads as the app being slow to start, every time, for a step that is
//  effectively instant. So the placeholder is the app's own background colour,
//  and the spinner only appears if the wait passes a third of a second — which
//  in practice means a fresh install, or a problem.
//

import SwiftUI

struct RootView: View {

    @State private var launch = Sub4Launch.shared
    @State private var showSpinner = false

    var body: some View {
        Group {
            if launch.isFinished {
                // Constructed HERE and nowhere earlier. Everything downstream —
                // ActivityStore reading activities.json, StravaAuth reading the
                // Keychain — happens on this line, after the migration.
                ContentView()
            } else {
                preparing
            }
        }
        .task { await launch.begin() }
    }

    private var preparing: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            if showSpinner {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing the database…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if !launch.isFinished { showSpinner = true }
        }
    }
}
