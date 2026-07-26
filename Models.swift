import Foundation

// MARK: - MusicPlayer

enum MusicPlayer: String, Codable, CaseIterable, Sendable {
    case spotify
    case appleMusic

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
    }

    var reportsDurationInMilliseconds: Bool {
        switch self {
        case .spotify: true
        case .appleMusic: false
        }
    }

    var playbackNotificationNames: [Notification.Name] {
        switch self {
        case .spotify:
            [Notification.Name("com.spotify.client.PlaybackStateChanged")]
        case .appleMusic:
            [
                Notification.Name("com.apple.Music.playerInfo"),
                Notification.Name("com.apple.iTunes.playerInfo"),
            ]
        }
    }
}

// MARK: - MusicTrack

struct MusicTrack: Codable, Sendable {
    let source: MusicPlayer
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool
}

// MARK: - MusicPlaybackResult

struct MusicPlaybackResult: Sendable {
    let track: MusicTrack?
    let issue: MusicPlaybackIssue?
}

enum MusicPlaybackIssue: Sendable {
    case permissionDenied(String)
    case unavailable(String)

    var requiresAutomationPermission: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

// MARK: - Lyrics

struct Lyrics: Sendable {
    let lines: [(timeMs: Int, text: String)]

    func currentLine(at progressMs: Int) -> String? {
        lines.last(where: { $0.timeMs <= progressMs })?.text
    }

    func nextLineTime(after progressMs: Int) -> Int? {
        lines.first(where: { $0.timeMs > progressMs })?.timeMs
    }
}
