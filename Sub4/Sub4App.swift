//
//  Sub4App.swift
//  Sub4
//

import SwiftUI

@main
struct Sub4App: App {

    /// THE FIRST LINE OF THIS APP'S OWN CODE — patch 421, §12.166.
    ///
    /// Everything before it (dyld, the runtime, SwiftUI's own start-up) is
    /// measured by subtraction from the kernel's process start time, which is
    /// why the sample has to be taken HERE and cannot be taken when somebody
    /// opens the Database screen. It reads no file and opens nothing.
    init() { LaunchClock.appStarted() }

    var body: some Scene {
        // `RootView`, NOT `ContentView` — patch 215, plan step 3.3.1.
        //
        // Every disk-backed store loads its file inside its own `private
        // init()`, and those run while SwiftUI initialises `ContentView`'s
        // stored properties — before `body`, before any `.task`. `RootView`
        // keeps `ContentView()` behind a branch that is not taken until the
        // database has been migrated, which is the only hook early enough to
        // matter and still able to show an error.
        //
        // NOTE FOR BACKGROUND REFRESH, below: it does NOT go through
        // `RootView`. A background wake runs `BackgroundRefresh.run()` without
        // building the scene, so anything it eventually needs from the database
        // has to open it itself. Nothing does today; 3.3.3 will have to.
        WindowGroup {
            RootView()
                // Not "first paint" — the first time the root view appears,
                // which is the earliest event this app can observe without
                // reaching into UIKit's layer tree. The label says so.
                .onAppear { LaunchClock.firstViewAppeared() }
        }
        // SwiftUI registers the launch handler for us. The equivalent
        // BGTaskScheduler.register call has to happen before
        // didFinishLaunching returns or it throws — this modifier removes that
        // trap entirely.
        //
        // Registering is only half of it: the identifier must also appear in
        // Info.plist under BGTaskSchedulerPermittedIdentifiers, and the target
        // needs Background Modes → Background fetch. Without both, submit()
        // throws notPermitted, which BackgroundRefresh records and Settings
        // shows.
        .backgroundTask(.appRefresh(BackgroundRefresh.taskId)) {
            await BackgroundRefresh.run()
        }
    }
}
