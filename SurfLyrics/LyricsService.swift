import Foundation
import os

@MainActor
final class LyricsService {
    private let preferences: AppPreferences
    private let lrclibClient: LRCLIBClient
    private let musixmatchClient: MusixmatchClient
    private let spotifyMetadataResolver: SpotifyMetadataResolver
    private let spotifyClient: any SpotifyClientLyricsProviding
    private let cache: LyricsCache
    private let signposter = OSSignposter(
        subsystem: "com.aloedawn.surflyrics",
        category: "LyricsLoading"
    )

    init(
        preferences: AppPreferences = AppPreferences(),
        urlSession: URLSession? = nil,
        cache: LyricsCache? = nil,
        decoder: LyricsPayloadDecoder? = nil,
        spotifyClient: (any SpotifyClientLyricsProviding)? = nil
    ) {
        let urlSession = urlSession ?? LyricsSessionFactory.make()
        let decoder = decoder ?? LyricsPayloadDecoder()
        self.preferences = preferences
        self.cache = cache ?? LyricsCache()
        self.spotifyClient = spotifyClient ?? SpotifyClientLyricsClient(connection: SpotifyClientConnection.shared)
        lrclibClient = LRCLIBClient(urlSession: urlSession, decoder: decoder)
        musixmatchClient = MusixmatchClient(
            preferences: preferences,
            urlSession: urlSession,
            decoder: decoder
        )
        spotifyMetadataResolver = SpotifyMetadataResolver(urlSession: urlSession)
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        let interval = signposter.beginInterval("LyricsLoad")
        defer { signposter.endInterval("LyricsLoad", interval) }
        guard track.itemKind.supportsLyricsLookup, !Task.isCancelled else { return (nil, nil) }

        var canonicalTrack: MusicTrack?
        var didResolveMetadata = false
        for provider in preferences.lyricsProviders(for: track) {
            let result = await fetch(from: provider, for: track)
            guard !Task.isCancelled else { return (nil, nil) }
            if let lyrics = result.lyrics {
                return (lyrics, provider.displayName)
            }

            // Client lyrics use the stable Spotify ID and never need translated metadata.
            guard provider != .spotifyClient else { continue }
            if !didResolveMetadata {
                canonicalTrack = await canonicalAlternative(for: track)
                didResolveMetadata = true
            }
            guard !Task.isCancelled else { return (nil, nil) }
            if let canonicalTrack {
                let canonicalResult = await fetch(from: provider, for: canonicalTrack)
                guard !Task.isCancelled else { return (nil, nil) }
                if let lyrics = canonicalResult.lyrics {
                    return (lyrics, provider.displayName)
                }
            }
        }
        return (nil, nil)
    }

    func invalidateCache(for track: MusicTrack) {
        cache.invalidate(for: track)
    }

    func invalidateSpotifyEndpoint() async {
        await spotifyClient.invalidateEndpoint()
    }

    private func fetch(from provider: LyricsProvider, for track: MusicTrack) async -> LyricsFetchResult {
        guard !Task.isCancelled else { return .transientFailure }
        return await cache.value(for: LyricsCacheKey(provider: provider, track: track)) {
            [spotifyClient, lrclibClient, musixmatchClient] in
            switch provider {
            case .spotifyClient: await spotifyClient.fetch(for: track)
            case .lrclib: await lrclibClient.fetch(for: track)
            case .musixmatch: await musixmatchClient.fetch(for: track)
            }
        }
    }

    private func canonicalAlternative(for track: MusicTrack) async -> MusicTrack? {
        guard track.source == .spotify, track.itemKind == .track,
            let canonical = await spotifyMetadataResolver.resolve(track),
            canonical.lyricsQueryIdentity != track.lyricsQueryIdentity
        else { return nil }
        return canonical
    }
}

@MainActor
private enum LyricsSessionFactory {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        configuration.timeoutIntervalForResource = 15.0
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }
}
