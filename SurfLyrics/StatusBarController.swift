import AppKit
import Combine

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menuController: StatusMenuController
    private let preferences: AppPreferences
    private var cancellables = Set<AnyCancellable>()
    private var transitionGeneration = 0

    init(
        appState: AppState,
        preferences: AppPreferences,
        actions: StatusMenuActions
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuController = StatusMenuController(actions: actions)
        self.preferences = preferences

        statusItem.button?.title = appState.statusText
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
        guard button.title != text else { return }
        transitionGeneration += 1
        let generation = transitionGeneration

        if preferences.lyricsTransitionEnabled {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                button.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.completeFade(to: text, generation: generation)
                }
            })
        } else {
            button.title = text
            button.alphaValue = 1
        }
    }

    private func completeFade(to text: String, generation: Int) {
        guard generation == transitionGeneration else { return }
        guard let button = statusItem.button else { return }
        button.title = text
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().alphaValue = 1
        }
    }
}
