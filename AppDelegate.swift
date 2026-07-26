import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusBarController: StatusBarController?
    private let settingsWindowController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = AppPreferences()
        let appState = AppState(preferences: preferences)
        self.appState = appState
        statusBarController = StatusBarController(
            appState: appState,
            preferences: preferences,
            actions: StatusMenuActions(
                openAutomationSettings: AppCommands.openAutomationSettings,
                openSettings: { [settingsWindowController] in
                    settingsWindowController.show()
                },
                restartApp: AppCommands.restartApp,
                terminateApp: AppCommands.terminateApp
            )
        )
    }
}
