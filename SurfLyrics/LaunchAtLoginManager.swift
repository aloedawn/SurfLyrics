import ServiceManagement

enum LaunchAtLoginManager {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        isEnabled() ? disable() : enable()
    }

    private static func enable() {
        try? SMAppService.mainApp.register()
    }

    private static func disable() {
        try? SMAppService.mainApp.unregister()
    }
}
