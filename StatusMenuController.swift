import AppKit

@MainActor
struct StatusMenuActions {
    let openAutomationSettings: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    let restartApp: @MainActor () -> Void
    let terminateApp: @MainActor () -> Void
}

@MainActor
final class StatusMenuController: NSObject {
    private let actions: StatusMenuActions

    private var sourceMenuItem: NSMenuItem?
    private var sourceSeparator: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var permissionSeparator: NSMenuItem?

    init(actions: StatusMenuActions) {
        self.actions = actions
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sourceItem.isEnabled = false
        sourceItem.isHidden = true
        menu.addItem(sourceItem)
        sourceMenuItem = sourceItem

        let sourceSeparator = NSMenuItem.separator()
        sourceSeparator.isHidden = true
        menu.addItem(sourceSeparator)
        self.sourceSeparator = sourceSeparator

        let permissionItem = NSMenuItem(
            title: "⚠ 음악 앱 접근 권한 설정 열기",
            action: #selector(openAutomationSettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)
        permissionMenuItem = permissionItem

        let permissionSeparator = NSMenuItem.separator()
        permissionSeparator.isHidden = true
        menu.addItem(permissionSeparator)
        self.permissionSeparator = permissionSeparator

        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(title: "재시작", action: #selector(restartApp), keyEquivalent: "r")
        restartItem.keyEquivalentModifierMask = [.command]
        restartItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        restartItem.target = self
        menu.addItem(restartItem)

        let terminateItem = NSMenuItem(title: "종료", action: #selector(terminateApp), keyEquivalent: "q")
        terminateItem.target = self
        menu.addItem(terminateItem)

        return menu
    }

    func updateSourceItem(_ source: String?) {
        if let source {
            sourceMenuItem?.title = source
            sourceMenuItem?.isHidden = false
            sourceSeparator?.isHidden = false
        } else {
            sourceMenuItem?.isHidden = true
            sourceSeparator?.isHidden = true
        }
    }

    func updatePermissionItem(_ needs: Bool) {
        permissionMenuItem?.isHidden = !needs
        permissionSeparator?.isHidden = !needs
    }

    @objc private func openAutomationSettings() {
        actions.openAutomationSettings()
    }

    @objc private func openSettings() {
        actions.openSettings()
    }

    @objc private func restartApp() {
        actions.restartApp()
    }

    @objc private func terminateApp() {
        actions.terminateApp()
    }
}
