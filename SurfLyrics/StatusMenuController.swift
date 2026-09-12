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

    private var sourceMenuItems: [NSMenuItem] = []
    private var sourceSeparator: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var permissionSeparator: NSMenuItem?

    init(actions: StatusMenuActions) {
        self.actions = actions
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        sourceMenuItems = (0..<2).map { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
            return item
        }

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
        let lines = source?.components(separatedBy: "\n") ?? []
        for (index, item) in sourceMenuItems.enumerated() {
            item.title = index < lines.count ? lines[index] : ""
            item.isHidden = item.title.isEmpty
        }
        sourceSeparator?.isHidden = sourceMenuItems.allSatisfy(\.isHidden)
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
