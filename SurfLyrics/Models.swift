import Foundation

// MARK: - MusicPlayer

enum MusicPlayer: String, CaseIterable, Sendable {
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

struct TrackIdentity: Hashable, Sendable {
    let source: MusicPlayer
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
}

struct MusicTrack: Equatable, Sendable {
    let source: MusicPlayer
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool

    var identity: TrackIdentity {
        TrackIdentity(
            source: source,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }
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

struct LyricsLine: Equatable, Sendable {
    let timeMs: Int
    let text: String
}

struct LyricsLookup: Equatable, Sendable {
    let currentText: String?
    let nextLineTimeMs: Int?
}

struct Lyrics: Equatable, Sendable {
    let lines: [LyricsLine]

    func lookup(at progressMs: Int) -> LyricsLookup {
        var lowerBound = 0
        var upperBound = lines.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lines[middle].timeMs <= progressMs {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return LyricsLookup(
            currentText: lowerBound > 0 ? lines[lowerBound - 1].text : nil,
            nextLineTimeMs: lowerBound < lines.count ? lines[lowerBound].timeMs : nil
        )
    }
}
