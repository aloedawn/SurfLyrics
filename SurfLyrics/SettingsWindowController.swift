import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            window = makeWindow(appState: appState)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(appState: AppState) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(appState: appState))
        let window = NSWindow(contentViewController: controller)
        window.title = "설정"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "SurfLyricsSettingsToolbar")
        window.setContentSize(NSSize(width: 720, height: 440))
        window.minSize = NSSize(width: 640, height: 380)
        window.isReleasedWhenClosed = false
        return window
    }
}
