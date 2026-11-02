import SwiftUI

// App entry point. The test action sets NOOP_TEST_HOST (see project.yml) so hosted tests get a bare
// process: the real app would open the live database and connect to the strap.
@main
enum AppEntry {
    static func main() {
        _ = LaunchMode.started
        if ProcessInfo.processInfo.environment["NOOP_TEST_HOST"] != nil {
            NSApplication.shared.run()
        } else {
            StrandApp.main()
        }
    }
}

struct StrandApp: App {
    // One AppModel for the whole app, shared to every view through the environment.
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.heart)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar item: live heart rate at a glance plus a compact popover.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
                .environmentObject(model.heart)
                .environmentObject(model.profile)
        } label: {
            MenuBarLabel()
                .environmentObject(model.live)
                .environmentObject(model.heart)
                .environmentObject(model.profile)
        }
        .menuBarExtraStyle(.window)
    }
}
