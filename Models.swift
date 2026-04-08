import Foundation
import ServiceManagement

// MARK: - SpotifyTrack

struct SpotifyTrack: Codable {
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool
}

// MARK: - Lyrics

struct Lyrics {
    let lines: [(timeMs: Int, text: String)]

    func currentLine(at progressMs: Int) -> String? {
        lines.last(where: { $0.timeMs <= progressMs })?.text
    }

    func nextLineTime(after progressMs: Int) -> Int? {
        lines.first(where: { $0.timeMs > progressMs })?.timeMs
    }
}

// MARK: - LaunchAtLoginManager

struct LaunchAtLoginManager {
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
