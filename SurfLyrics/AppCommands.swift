import AppKit
import Foundation

@MainActor
enum AppCommands {
    private static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    static func openAutomationSettings() {
        NSWorkspace.shared.open(automationSettingsURL)
    }

    static func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        terminateApp()
    }

    static func terminateApp() {
        NSApp.terminate(nil)
    }
}
