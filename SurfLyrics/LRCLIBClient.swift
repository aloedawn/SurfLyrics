import Foundation
import os

@MainActor
final class LRCLIBClient {
    private let urlSession: URLSession
    private let decoder: LyricsPayloadDecoder
    private let logger = Logger(subsystem: "com.aloedawn.surflyrics", category: "LRCLIB")

    init(urlSession: URLSession, decoder: LyricsPayloadDecoder) {
        self.urlSession = urlSession
        self.decoder = decoder
    }

    func fetch(artist: String, trackName: String, album: String?) async -> LyricsFetchResult {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
        ]
        if let album {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }

        guard let url = components.url else { return .transientFailure }
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 10.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }
            if httpResponse.statusCode == 404 {
                return .notFound
            }
            guard httpResponse.statusCode == 200 else {
                logger.error("LRCLIB returned a non-success status")
                return .transientFailure
            }
            return await decoder.decodeLRCLIB(data)
        } catch {
            if !Task.isCancelled {
                logger.error("LRCLIB request failed")
            }
            return .transientFailure
        }
    }
}
