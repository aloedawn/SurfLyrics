import Foundation
import os

@MainActor
final class LRCLIBClient {
    private enum ResponseResult {
        case success(Data)
        case notFound
        case transientFailure
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        return "SurfLyrics/\(version) (https://github.com/aloedawn/SurfLyrics)"
    }()

    private let urlSession: URLSession
    private let decoder: LyricsPayloadDecoder
    private let logger = Logger(subsystem: "com.aloedawn.surflyrics", category: "LRCLIB")
    private let minimumRequestInterval: TimeInterval = 0.25
    private var retryNotBefore: Date?
    private var lastRequestStartedAt: Date?

    init(urlSession: URLSession, decoder: LyricsPayloadDecoder) {
        self.urlSession = urlSession
        self.decoder = decoder
    }

    func fetchExact(for track: MusicTrack) async -> LyricsFetchResult {
        let trackName = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackName.isEmpty, !artist.isEmpty, !album.isEmpty, track.durationMs > 0 else {
            return .notFound
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(
                name: "duration",
                value: String(Int((Double(track.durationMs) / 1000.0).rounded()))
            ),
        ]

        guard let request = request(from: components) else { return .transientFailure }
        switch await responseData(for: request) {
        case let .success(data):
            return await decoder.decodeLRCLIB(data)
        case .notFound:
            return .notFound
        case .transientFailure:
            return .transientFailure
        }
    }

    func search(for track: MusicTrack, includeArtist: Bool) async -> LyricsFetchResult {
        guard !Task.isCancelled else { return .transientFailure }

        let trackName = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackName.isEmpty else { return .notFound }

        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: trackName)]
        if includeArtist, !artist.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "artist_name", value: artist))
        }

        guard let request = request(from: components) else { return .transientFailure }
        switch await responseData(for: request) {
        case let .success(data):
            return await decoder.decodeLRCLIBSearch(data, expectedTrack: track)
        case .notFound:
            return .notFound
        case .transientFailure:
            return .transientFailure
        }
    }

    private func request(from components: URLComponents) -> URLRequest? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 10.0
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func responseData(for request: URLRequest) async -> ResponseResult {
        guard !Task.isCancelled else { return .transientFailure }
        if let retryNotBefore, retryNotBefore > Date() {
            return .transientFailure
        }
        retryNotBefore = nil
        guard await waitForRequestSlot() else { return .transientFailure }
        if let retryNotBefore, retryNotBefore > Date() {
            return .transientFailure
        }
        retryNotBefore = nil

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }
            if httpResponse.statusCode == 404 {
                return .notFound
            }
            if httpResponse.statusCode == 429 {
                let retryAfter = TimeInterval(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "")
                    ?? 60
                retryNotBefore = Date().addingTimeInterval(max(1, retryAfter))
                logger.error("LRCLIB rate limit reached")
                return .transientFailure
            }
            guard httpResponse.statusCode == 200 else {
                logger.error("LRCLIB returned a non-success status")
                return .transientFailure
            }
            return .success(data)
        } catch {
            if !Task.isCancelled {
                logger.error("LRCLIB request failed")
            }
            return .transientFailure
        }
    }

    private func waitForRequestSlot() async -> Bool {
        while !Task.isCancelled {
            let now = Date()
            if let lastRequestStartedAt {
                let delay = lastRequestStartedAt
                    .addingTimeInterval(minimumRequestInterval)
                    .timeIntervalSince(now)
                if delay > 0 {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64((delay * 1_000_000_000).rounded())
                        )
                    } catch {
                        return false
                    }
                    continue
                }
            }
            lastRequestStartedAt = Date()
            return true
        }
        return false
    }
}
