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

enum TrackIdentity: Hashable, Sendable {
    case sourceTrackID(source: MusicPlayer, id: String)
    case metadata(
        source: MusicPlayer,
        itemKind: PlaybackItemKind,
        name: String,
        artist: String,
        album: String,
        durationMs: Int
    )
}

struct LyricsQueryIdentity: Hashable, Sendable {
    let source: MusicPlayer
    let itemKind: PlaybackItemKind
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
}

enum PlaybackItemKind: Equatable, Sendable {
    case track
    case localTrack
    case episode
    case advertisement
    case unsupported
    case unknown

    var supportsLyricsLookup: Bool {
        switch self {
        case .track, .localTrack:
            true
        case .episode, .advertisement, .unsupported, .unknown:
            false
        }
    }
}

struct MusicTrack: Equatable, Sendable {
    let source: MusicPlayer
    let sourceTrackID: String?
    let itemKind: PlaybackItemKind
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool

    init(
        source: MusicPlayer,
        sourceTrackID: String? = nil,
        itemKind: PlaybackItemKind = .track,
        name: String,
        artist: String,
        album: String,
        durationMs: Int,
        progressMs: Int,
        isPlaying: Bool
    ) {
        self.source = source
        self.sourceTrackID = sourceTrackID
        self.itemKind = itemKind
        self.name = name
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.progressMs = progressMs
        self.isPlaying = isPlaying
    }

    var identity: TrackIdentity {
        if let sourceTrackID = sourceTrackID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sourceTrackID.isEmpty
        {
            return .sourceTrackID(source: source, id: sourceTrackID)
        }

        return .metadata(
            source: source,
            itemKind: itemKind,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }

    var lyricsQueryIdentity: LyricsQueryIdentity {
        LyricsQueryIdentity(
            source: source,
            itemKind: itemKind,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
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
