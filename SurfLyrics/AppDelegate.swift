import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusBarController: StatusBarController?
    private let settingsWindowController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        let preferences = AppPreferences()
        let appState = AppState(preferences: preferences)
        self.appState = appState
        statusBarController = StatusBarController(
            appState: appState,
            actions: StatusMenuActions(
                openAutomationSettings: AppCommands.openAutomationSettings,
                openSettings: { [settingsWindowController] in
                    settingsWindowController.show(appState: appState)
                },
                restartApp: AppCommands.restartApp,
                terminateApp: AppCommands.terminateApp
            )
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let appState {
            settingsWindowController.show(appState: appState)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}
