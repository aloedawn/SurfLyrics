import Foundation
import os

@MainActor
final class MusixmatchClient {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private let preferences: AppPreferences
    private let urlSession: URLSession
    private let decoder: LyricsPayloadDecoder
    private let logger = Logger(subsystem: "com.aloedawn.surflyrics", category: "Musixmatch")
    private var token: String?
    private var tokenExpiry: Date?

    init(
        preferences: AppPreferences,
        urlSession: URLSession,
        decoder: LyricsPayloadDecoder
    ) {
        self.preferences = preferences
        self.urlSession = urlSession
        self.decoder = decoder
        token = preferences.musixmatchToken
        tokenExpiry = preferences.musixmatchTokenExpiry
    }

    func fetch(for track: MusicTrack) async -> LyricsFetchResult {
        guard let token = await validToken() else { return .transientFailure }

        var components = URLComponents(
            string: "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get"
        )!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynced"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "q_track", value: track.name),
            URLQueryItem(name: "q_artist", value: track.artist),
            URLQueryItem(name: "q_album", value: track.album),
            URLQueryItem(name: "q_duration", value: String(track.durationMs / 1000)),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
        ]
        guard let url = components.url else { return .transientFailure }

        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 10.0
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }
            if httpResponse.statusCode == 404 {
                return .notFound
            }
            guard httpResponse.statusCode == 200 else {
                logger.error("Musixmatch returned a non-success status")
                return .transientFailure
            }
            return await decoder.decodeMusixmatch(data, expectedTrack: track)
        } catch {
            if !Task.isCancelled {
                logger.error("Musixmatch request failed")
            }
            return .transientFailure
        }
    }

    private func validToken() async -> String? {
        token = preferences.musixmatchToken
        tokenExpiry = preferences.musixmatchTokenExpiry

        if let token, let tokenExpiry, Date() < tokenExpiry {
            return token
        }

        guard let url = URL(
            string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0"
        ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 10.0
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                let token = await decoder.decodeMusixmatchToken(data)
            else {
                logger.error("Musixmatch token refresh failed")
                return nil
            }

            let expiry = Date().addingTimeInterval(3600)
            self.token = token
            tokenExpiry = expiry
            preferences.storeMusixmatchToken(token, expiresAt: expiry)
            return token
        } catch {
            if !Task.isCancelled {
                logger.error("Musixmatch token request failed")
            }
            return nil
        }
    }
}
