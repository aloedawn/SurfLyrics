import Foundation

@MainActor
final class LyricsService {
    private let preferences: AppPreferences
    private let lrclibClient: LRCLIBClient
    private let musixmatchClient: MusixmatchClient

    init(
        preferences: AppPreferences = AppPreferences(),
        urlSession: URLSession? = nil
    ) {
        let urlSession = urlSession ?? LyricsSessionFactory.make()
        self.preferences = preferences
        lrclibClient = LRCLIBClient(urlSession: urlSession)
        musixmatchClient = MusixmatchClient(
            preferences: preferences,
            urlSession: urlSession
        )
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        if preferences.usesLRCLIB {
            if let lyrics = await lrclibClient.fetch(
                artist: track.artist,
                trackName: track.name,
                album: track.album
            ) {
                return (lyrics, "LRCLIB")
            }
            if let lyrics = await lrclibClient.fetch(
                artist: track.artist,
                trackName: track.name,
                album: nil
            ) {
                return (lyrics, "LRCLIB")
            }
        }

        if preferences.usesMusixmatch,
            let lyrics = await musixmatchClient.fetch(for: track)
        {
            return (lyrics, "Musixmatch")
        }

        return (nil, nil)
    }
}

@MainActor
private enum LyricsSessionFactory {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        configuration.timeoutIntervalForResource = 15.0
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
