import Foundation

enum LyricsProvider: CaseIterable, Hashable, Sendable {
    // Declaration order is the lookup priority, including after a cached fallback hit.
    case spotifyClient
    case lrclib
    case musixmatch

    var displayName: String {
        switch self {
        case .spotifyClient: "Spotify 클라이언트"
        case .lrclib: "LRCLIB"
        case .musixmatch: "Musixmatch"
        }
    }
}

enum LyricsFetchResult: Equatable, Sendable {
    case found(Lyrics)
    case notFound
    case transientFailure

    var lyrics: Lyrics? {
        guard case let .found(lyrics) = self else { return nil }
        return lyrics
    }
}
