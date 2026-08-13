import AppKit
import Combine

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menuController: StatusMenuController
    private let idleStatusImage: NSImage?
    private var cancellables = Set<AnyCancellable>()

    init(
        appState: AppState,
        actions: StatusMenuActions
    ) {
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .regular
        )
        idleStatusImage = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "음악"
        )?.withSymbolConfiguration(symbolConfiguration)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuController = StatusMenuController(actions: actions)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
        }
        updateLabel(appState.statusText)
        // On macOS 27, expanded-interface sessions are for custom popovers/windows.
        // Assigning NSMenu keeps AppKit's standard menu tracking and keyboard behavior.
        statusItem.menu = menuController.makeMenu()

        bind(to: appState)
    }

    private func bind(to appState: AppState) {
        appState.$statusText.removeDuplicates().sink { [weak self] text in
            self?.updateLabel(text)
        }.store(in: &cancellables)

        appState.$sourceText.removeDuplicates().sink { [weak self] source in
            self?.menuController.updateSourceItem(source)
        }.store(in: &cancellables)

        appState.$needsAutomationPermission.removeDuplicates().sink { [weak self] needs in
            self?.menuController.updatePermissionItem(needs)
        }.store(in: &cancellables)
    }

    private func updateLabel(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = text
        button.image = text.isEmpty ? idleStatusImage : nil
    }
}
