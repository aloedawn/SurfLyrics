import AppKit
import os

@MainActor
final class ConnectionHelperDelegate: NSObject, NSApplicationDelegate {
    private var connectionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        connect()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        connect()
        return false
    }

    private func connect() {
        guard connectionTask == nil else { return }
        connectionTask = Task {
            do {
                try await SpotifyConnectionLauncher(environment: NativeSpotifyLaunchEnvironment()).connect()
            } catch {
                Logger(subsystem: "com.aloedawn.surflyrics.connectionhelper", category: "Connection")
                    .error("Spotify connection setup failed")
            }
            NSApp.terminate(nil)
        }
    }
}

let application = NSApplication.shared
let delegate = ConnectionHelperDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
