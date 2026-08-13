import Foundation

struct StatusTextFormatter {
    private let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func text(for track: MusicTrack, lyricsLine: String?, isLoadingLyrics: Bool) -> String {
        guard !isLoadingLyrics, let lyricsLine else {
            return trackDescription(for: track)
        }
        return lyricsLine
    }

    func sourceDescription(for track: MusicTrack, lyricsSource: String?) -> String {
        if let lyricsSource {
            return "재생 앱: \(track.source.displayName) · 가사 소스: \(lyricsSource)"
        }
        return "재생 앱: \(track.source.displayName)"
    }

    private func trackDescription(for track: MusicTrack) -> String {
        let text: String
        switch preferences.displayMode {
        case .trackOnly:
            text = "♫ \(track.name)"
        case .artistOnly:
            text = "♫ \(track.artist)"
        case .trackAndArtist:
            text = "♫ \(track.name) — \(track.artist)"
        }
        return text
    }
}
