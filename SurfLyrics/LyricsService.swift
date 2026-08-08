import Foundation
import os

enum LyricsProvider: Hashable, Sendable {
    case lrclib
    case musixmatch
}

enum LyricsFetchResult: Equatable, Sendable {
    case found(Lyrics)
    case notFound
    case transientFailure
}

struct LyricsCacheKey: Hashable, Sendable {
    let provider: LyricsProvider
    let name: String
    let artist: String
    let album: String
    let durationMs: Int

    init(provider: LyricsProvider, track: MusicTrack) {
        self.provider = provider
        name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        durationMs = track.durationMs
    }
}

@MainActor
final class LyricsCache {
    private struct Entry {
        let result: LyricsFetchResult
        var lastAccess: UInt64
        let expiresAt: Date?
    }

    private let capacity: Int
    private let negativeTTL: TimeInterval
    private let now: () -> Date
    private var entries: [LyricsCacheKey: Entry] = [:]
    private var inFlight: [LyricsCacheKey: Task<LyricsFetchResult, Never>] = [:]
    private var accessCounter: UInt64 = 0

    init(
        capacity: Int = 64,
        negativeTTL: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        self.capacity = max(1, capacity)
        self.negativeTTL = negativeTTL
        self.now = now
    }

    func value(
        for key: LyricsCacheKey,
        loader: @escaping @MainActor () async -> LyricsFetchResult
    ) async -> LyricsFetchResult {
        if let result = cachedValue(for: key) {
            return result
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { await loader() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        store(result, for: key)
        return result
    }

    private func cachedValue(for key: LyricsCacheKey) -> LyricsFetchResult? {
        guard var entry = entries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= now() {
            entries[key] = nil
            return nil
        }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.result
    }

    private func store(_ result: LyricsFetchResult, for key: LyricsCacheKey) {
        let expiresAt: Date?
        switch result {
        case .found:
            expiresAt = nil
        case .notFound:
            expiresAt = now().addingTimeInterval(negativeTTL)
        case .transientFailure:
            return
        }

        accessCounter &+= 1
        entries[key] = Entry(
            result: result,
            lastAccess: accessCounter,
            expiresAt: expiresAt
        )
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard entries.count > capacity,
            let oldestKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        else {
            return
        }
        entries[oldestKey] = nil
    }
}

actor LyricsPayloadDecoder {
    private let signposter = OSSignposter(
        subsystem: "com.aloedawn.surflyrics",
        category: "LyricsDecoding"
    )

    func decodeLRCLIB(_ data: Data) -> LyricsFetchResult {
        let interval = signposter.beginInterval("LRCLIBDecode")
        defer { signposter.endInterval("LRCLIBDecode", interval) }

        guard let payload = try? JSONDecoder().decode(LRCLIBPayload.self, from: data) else {
            return .transientFailure
        }
        guard let lrc = payload.syncedLyrics, !lrc.isEmpty else {
            return .notFound
        }
        return lyricsResult(from: lrc)
    }

    func decodeMusixmatch(_ data: Data, expectedTrack: MusicTrack) -> LyricsFetchResult {
        let interval = signposter.beginInterval("MusixmatchDecode")
        defer { signposter.endInterval("MusixmatchDecode", interval) }

        guard let payload = try? JSONDecoder().decode(MusixmatchPayload.self, from: data),
            let calls = payload.message?.body?.macroCalls
        else {
            return .transientFailure
        }

        if let matchedTrack = calls.matcherTrack?.message?.body?.track,
            !isLikelySameTrack(matchedTrack, expected: expectedTrack)
        {
            return .notFound
        }

        guard let lrc = calls.subtitles?.message?.body?.subtitleList?.first?.subtitle?.body,
            !lrc.isEmpty
        else {
            return .notFound
        }
        return lyricsResult(from: lrc)
    }

    func decodeMusixmatchToken(_ data: Data) -> String? {
        try? JSONDecoder().decode(MusixmatchTokenPayload.self, from: data)
            .message?.body?.userToken
    }

    private func lyricsResult(from lrc: String) -> LyricsFetchResult {
        let lines = LRCParser.parse(lrc)
        return lines.isEmpty ? .notFound : .found(Lyrics(lines: lines))
    }

    private func isLikelySameTrack(
        _ track: MusixmatchPayload.Track,
        expected: MusicTrack
    ) -> Bool {
        textMatches(track.name ?? "", expected.name)
            && textMatches(track.artist ?? "", expected.artist)
            && durationMatches(track.length?.value, expectedMs: expected.durationMs)
    }

    private func durationMatches(_ actualSeconds: Double?, expectedMs: Int) -> Bool {
        guard expectedMs > 0, let actualSeconds, actualSeconds > 0 else { return true }
        let expectedSeconds = Double(expectedMs) / 1000.0
        let tolerance = max(4.0, expectedSeconds * 0.04)
        return abs(actualSeconds - expectedSeconds) <= tolerance
    }

    private func textMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedForMatch(lhs)
        let right = normalizedForMatch(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func normalizedForMatch(_ text: String) -> String {
        let folded = text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["feat", "ft", "featuring"].contains($0) }
            .joined(separator: " ")
    }
}

@MainActor
final class LyricsService {
    private let preferences: AppPreferences
    private let lrclibClient: LRCLIBClient
    private let musixmatchClient: MusixmatchClient
    private let cache: LyricsCache
    private let signposter = OSSignposter(
        subsystem: "com.aloedawn.surflyrics",
        category: "LyricsLoading"
    )

    init(
        preferences: AppPreferences = AppPreferences(),
        urlSession: URLSession? = nil,
        cache: LyricsCache? = nil,
        decoder: LyricsPayloadDecoder? = nil
    ) {
        let urlSession = urlSession ?? LyricsSessionFactory.make()
        let decoder = decoder ?? LyricsPayloadDecoder()
        self.preferences = preferences
        self.cache = cache ?? LyricsCache()
        lrclibClient = LRCLIBClient(urlSession: urlSession, decoder: decoder)
        musixmatchClient = MusixmatchClient(
            preferences: preferences,
            urlSession: urlSession,
            decoder: decoder
        )
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        let interval = signposter.beginInterval("LyricsLoad")
        defer { signposter.endInterval("LyricsLoad", interval) }

        if preferences.usesLRCLIB {
            let key = LyricsCacheKey(provider: .lrclib, track: track)
            let result = await cache.value(for: key) { [lrclibClient] in
                await Self.fetchLRCLIB(track: track, client: lrclibClient)
            }
            if case let .found(lyrics) = result {
                return (lyrics, "LRCLIB")
            }
        }

        if preferences.usesMusixmatch {
            let key = LyricsCacheKey(provider: .musixmatch, track: track)
            let result = await cache.value(for: key) { [musixmatchClient] in
                await musixmatchClient.fetch(for: track)
            }
            if case let .found(lyrics) = result {
                return (lyrics, "Musixmatch")
            }
        }

        return (nil, nil)
    }

    private static func fetchLRCLIB(
        track: MusicTrack,
        client: LRCLIBClient
    ) async -> LyricsFetchResult {
        let exactResult = await client.fetch(
            artist: track.artist,
            trackName: track.name,
            album: track.album
        )
        if case .found = exactResult {
            return exactResult
        }

        let fallbackResult = await client.fetch(
            artist: track.artist,
            trackName: track.name,
            album: nil
        )
        if case .found = fallbackResult {
            return fallbackResult
        }
        if exactResult == .notFound, fallbackResult == .notFound {
            return .notFound
        }
        return .transientFailure
    }
}

private struct LRCLIBPayload: Decodable {
    let syncedLyrics: String?
}

private struct MusixmatchTokenPayload: Decodable {
    let message: Message?

    struct Message: Decodable {
        let body: Body?
    }

    struct Body: Decodable {
        let userToken: String?

        enum CodingKeys: String, CodingKey {
            case userToken = "user_token"
        }
    }
}

private struct MusixmatchPayload: Decodable {
    let message: Message?

    struct Message: Decodable {
        let body: Body?
    }

    struct Body: Decodable {
        let macroCalls: MacroCalls?

        enum CodingKeys: String, CodingKey {
            case macroCalls = "macro_calls"
        }
    }

    struct MacroCalls: Decodable {
        let matcherTrack: MatcherCall?
        let subtitles: SubtitleCall?

        enum CodingKeys: String, CodingKey {
            case matcherTrack = "matcher.track.get"
            case subtitles = "track.subtitles.get"
        }
    }

    struct MatcherCall: Decodable {
        let message: MatcherMessage?
    }

    struct MatcherMessage: Decodable {
        let body: MatcherBody?
    }

    struct MatcherBody: Decodable {
        let track: Track?
    }

    struct Track: Decodable {
        let name: String?
        let artist: String?
        let length: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case name = "track_name"
            case artist = "artist_name"
            case length = "track_length"
        }
    }

    struct SubtitleCall: Decodable {
        let message: SubtitleMessage?
    }

    struct SubtitleMessage: Decodable {
        let body: SubtitleBody?
    }

    struct SubtitleBody: Decodable {
        let subtitleList: [SubtitleItem]?

        enum CodingKeys: String, CodingKey {
            case subtitleList = "subtitle_list"
        }
    }

    struct SubtitleItem: Decodable {
        let subtitle: Subtitle?
    }

    struct Subtitle: Decodable {
        let body: String?

        enum CodingKeys: String, CodingKey {
            case body = "subtitle_body"
        }
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = Double(string)
        } else {
            value = nil
        }
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
        return URLSession(configuration: configuration)
    }
}
