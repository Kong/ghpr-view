import SwiftUI

@main
struct PRDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-testing-browser-") }) {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--ui-testing-uiux") {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        #endif
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
