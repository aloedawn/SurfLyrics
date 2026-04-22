import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appState: AppState!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var sourceMenuItem: NSMenuItem?
    private var sourceSeparator: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var permissionSeparator: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = appState.statusText
        statusItem?.menu = buildMenu()

        appState.$statusText.sink { [weak self] text in
            self?.updateLabel(text)
        }.store(in: &cancellables)

        appState.$lyricsSource.sink { [weak self] source in
            self?.updateSourceItem(source)
        }.store(in: &cancellables)

        appState.$needsAutomationPermission.sink { [weak self] needs in
            self?.updatePermissionItem(needs)
        }.store(in: &cancellables)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sourceItem.isEnabled = false
        sourceItem.isHidden = true
        menu.addItem(sourceItem)
        sourceMenuItem = sourceItem

        let sep = NSMenuItem.separator()
        sep.isHidden = true
        menu.addItem(sep)
        sourceSeparator = sep

        let permItem = NSMenuItem(title: "⚠ Spotify 접근 권한 설정 열기", action: #selector(openAutomationSettings), keyEquivalent: "")
        permItem.target = self
        permItem.isHidden = true
        menu.addItem(permItem)
        permissionMenuItem = permItem

        let permSep = NSMenuItem.separator()
        permSep.isHidden = true
        menu.addItem(permSep)
        permissionSeparator = permSep

        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "재시작", action: #selector(restartApp), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command]
        restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        restart.target = self
        menu.addItem(restart)

        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    private func updateSourceItem(_ source: String?) {
        if let source {
            sourceMenuItem?.title = "가사 소스: \(source)"
            sourceMenuItem?.isHidden = false
            sourceSeparator?.isHidden = false
        } else {
            sourceMenuItem?.isHidden = true
            sourceSeparator?.isHidden = true
        }
    }

    private func updatePermissionItem(_ needs: Bool) {
        permissionMenuItem?.isHidden = !needs
        permissionSeparator?.isHidden = !needs
    }

    // MARK: - Actions

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "설정"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "SurfLyricsSettingsToolbar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.setContentSize(NSSize(width: 720, height: 440))
            window.minSize = NSSize(width: 640, height: 380)
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restartApp() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments  = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Status Bar Animation

    private func updateLabel(_ text: String) {
        guard let button = statusItem?.button else { return }
        let fade = UserDefaults.standard.bool(forKey: "lyricsTransitionEnabled")
        if fade {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                button.animator().alphaValue = 0
            }, completionHandler: {
                button.title = text
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    button.animator().alphaValue = 1
                }
            })
        } else {
            button.title = text
        }
    }
}
