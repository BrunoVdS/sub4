//
//  Sub4App.swift
//  Sub4
//

import SwiftUI

@main
struct Sub4App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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
