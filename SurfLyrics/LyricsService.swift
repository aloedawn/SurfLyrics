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
    let source: MusicPlayer
    let sourceTrackID: String?
    let itemKind: PlaybackItemKind
    let name: String
    let artist: String
    let album: String
    let durationMs: Int

    init(provider: LyricsProvider, track: MusicTrack) {
        self.provider = provider
        source = track.source
        itemKind = track.itemKind
        let trimmedSourceTrackID = track.sourceTrackID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sourceTrackID = trimmedSourceTrackID?.isEmpty == false ? trimmedSourceTrackID : nil
        name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        durationMs = track.durationMs
    }

    fileprivate var positiveKey: LyricsPositiveCacheKey {
        let identity: LyricsPositiveCacheKey.Identity
        if let sourceTrackID {
            identity = .sourceID(source: source, id: sourceTrackID)
        } else {
            identity = .metadata(
                source: source,
                itemKind: itemKind,
                name: name,
                artist: artist,
                album: album,
                durationMs: durationMs
            )
        }
        return LyricsPositiveCacheKey(provider: provider, identity: identity)
    }
}

private struct LyricsPositiveCacheKey: Hashable, Sendable {
    enum Identity: Hashable, Sendable {
        case sourceID(source: MusicPlayer, id: String)
        case metadata(
            source: MusicPlayer,
            itemKind: PlaybackItemKind,
            name: String,
            artist: String,
            album: String,
            durationMs: Int
        )
    }

    let provider: LyricsProvider
    let identity: Identity
}

@MainActor
final class LyricsCache {
    private struct Entry {
        let result: LyricsFetchResult
        var lastAccess: UInt64
        let expiresAt: Date?
    }

    private struct InFlightRequest {
        let task: Task<LyricsFetchResult, Never>
        let generation: UInt64
        var waiters: Set<UUID>
    }

    private let capacity: Int
    private let negativeTTL: TimeInterval
    private let now: () -> Date
    private var positiveEntries: [LyricsPositiveCacheKey: Entry] = [:]
    private var negativeEntries: [LyricsCacheKey: Entry] = [:]
    private var inFlight: [LyricsCacheKey: InFlightRequest] = [:]
    private var positiveGenerations: [LyricsPositiveCacheKey: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var generationCounter: UInt64 = 0

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
        if let result = positiveValue(for: key.positiveKey) {
            return result
        }
        if let result = negativeValue(for: key) {
            return result
        }
        let waiterID = UUID()
        if var request = inFlight[key] {
            request.waiters.insert(waiterID)
            inFlight[key] = request
            let result = await value(
                from: request.task,
                for: key,
                waiterID: waiterID
            )
            finishWaiting(for: key, waiterID: waiterID)
            return result
        }

        generationCounter &+= 1
        let generation = generationCounter
        positiveGenerations[key.positiveKey] = generation
        let task = Task { await loader() }
        inFlight[key] = InFlightRequest(
            task: task,
            generation: generation,
            waiters: [waiterID]
        )
        let result = await value(from: task, for: key, waiterID: waiterID)
        if inFlight[key]?.generation == generation {
            inFlight[key] = nil
            store(result, for: key, generation: generation)
        }
        cleanGenerationIfUnused(for: key.positiveKey)
        return result
    }

    private func value(
        from task: Task<LyricsFetchResult, Never>,
        for key: LyricsCacheKey,
        waiterID: UUID
    ) async -> LyricsFetchResult {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiting(for: key, waiterID: waiterID)
            }
        }
    }

    private func cancelWaiting(for key: LyricsCacheKey, waiterID: UUID) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
            return
        }
        if request.waiters.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
            cleanGenerationIfUnused(for: key.positiveKey)
        } else {
            inFlight[key] = request
        }
    }

    private func finishWaiting(for key: LyricsCacheKey, waiterID: UUID) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
            return
        }
        inFlight[key] = request
    }

    private func positiveValue(for key: LyricsPositiveCacheKey) -> LyricsFetchResult? {
        guard var entry = positiveEntries[key] else { return nil }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        positiveEntries[key] = entry
        return entry.result
    }

    private func negativeValue(for key: LyricsCacheKey) -> LyricsFetchResult? {
        guard var entry = negativeEntries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= now() {
            negativeEntries[key] = nil
            return nil
        }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        negativeEntries[key] = entry
        return entry.result
    }

    private func store(
        _ result: LyricsFetchResult,
        for key: LyricsCacheKey,
        generation: UInt64
    ) {
        accessCounter &+= 1
        switch result {
        case .found:
            if positiveGenerations[key.positiveKey] == generation
                || positiveEntries[key.positiveKey] == nil
            {
                positiveEntries[key.positiveKey] = Entry(
                    result: result,
                    lastAccess: accessCounter,
                    expiresAt: nil
                )
            }
            negativeEntries[key] = nil
        case .notFound:
            negativeEntries[key] = Entry(
                result: result,
                lastAccess: accessCounter,
                expiresAt: now().addingTimeInterval(negativeTTL)
            )
        case .transientFailure:
            return
        }
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        if positiveEntries.count > capacity,
            let oldestKey = positiveEntries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key
        {
            positiveEntries[oldestKey] = nil
            cleanGenerationIfUnused(for: oldestKey)
        }
        if negativeEntries.count > capacity,
            let oldestKey = negativeEntries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key
        {
            negativeEntries[oldestKey] = nil
        }
    }

    private func cleanGenerationIfUnused(for positiveKey: LyricsPositiveCacheKey) {
        let hasInFlightRequest = inFlight.keys.contains { $0.positiveKey == positiveKey }
        if !hasInFlightRequest {
            positiveGenerations[positiveKey] = nil
        }
    }
}

actor LyricsPayloadDecoder {
    private let signposter = OSSignposter(
        subsystem: "com.aloedawn.surflyrics",
        category: "LyricsDecoding"
    )
    private let matcher = LyricsCandidateMatcher.default

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

    func decodeLRCLIBSearch(
        _ data: Data,
        expectedTrack: MusicTrack
    ) -> LyricsFetchResult {
        let interval = signposter.beginInterval("LRCLIBSearchDecode")
        defer { signposter.endInterval("LRCLIBSearchDecode", interval) }

        guard let payloads = try? JSONDecoder().decode([LRCLIBPayload].self, from: data) else {
            return .transientFailure
        }

        let viableRecords = payloads.compactMap { payload -> (LRCLIBPayload, LyricsCandidate)? in
            guard let syncedLyrics = payload.syncedLyrics, !syncedLyrics.isEmpty else {
                return nil
            }
            return (
                payload,
                LyricsCandidate(
                    trackName: payload.trackName ?? "",
                    artistName: payload.artistName ?? "",
                    albumName: payload.albumName,
                    durationMs: milliseconds(fromSeconds: payload.duration?.value)
                )
            )
        }
        let candidates = viableRecords.map { $0.1 }
        guard let matchIndex = matcher.bestMatchIndex(for: expectedTrack, among: candidates) else {
            return .notFound
        }
        guard let lrc = viableRecords[matchIndex].0.syncedLyrics else {
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

        guard let matchedTrack = calls.matcherTrack?.message?.body?.track else {
            return .notFound
        }
        let candidate = LyricsCandidate(
            trackName: matchedTrack.name ?? "",
            artistName: matchedTrack.artist ?? "",
            albumName: matchedTrack.album,
            durationMs: milliseconds(fromSeconds: matchedTrack.length?.value)
        )
        guard matcher.isLikelyMatch(candidate, for: expectedTrack) else {
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

    private func milliseconds(fromSeconds seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let milliseconds = (seconds * 1_000).rounded()
        let maximumTrackDurationMs = 24.0 * 60 * 60 * 1_000
        guard milliseconds.isFinite, milliseconds <= maximumTrackDurationMs else { return nil }
        return Int(milliseconds)
    }

}

@MainActor
final class LyricsService {
    private let preferences: AppPreferences
    private let lrclibClient: LRCLIBClient
    private let musixmatchClient: MusixmatchClient
    private let spotifyMetadataResolver: SpotifyMetadataResolver
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
        spotifyMetadataResolver = SpotifyMetadataResolver(urlSession: urlSession)
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        let interval = signposter.beginInterval("LyricsLoad")
        defer { signposter.endInterval("LyricsLoad", interval) }

        if preferences.usesLRCLIB {
            let result = await lyricsFromLRCLIB(for: track)
            if let lyrics = result {
                return (lyrics, "LRCLIB")
            }
            guard !Task.isCancelled else { return (nil, nil) }
        }

        let shouldResolveSpotifyMetadata = track.source == .spotify
            && track.itemKind == .track
            && track.sourceTrackID != nil
        let canonicalTrack = shouldResolveSpotifyMetadata
            ? await spotifyMetadataResolver.resolve(track)
            : nil
        guard !Task.isCancelled else { return (nil, nil) }
        let canonicalMetadataChanged: Bool
        if let canonicalTrack {
            canonicalMetadataChanged = canonicalTrack.lyricsQueryIdentity
                != track.lyricsQueryIdentity
        } else {
            canonicalMetadataChanged = false
        }

        if preferences.usesLRCLIB,
            canonicalMetadataChanged,
            let canonicalTrack,
            let lyrics = await lyricsFromLRCLIB(for: canonicalTrack)
        {
            return (lyrics, "LRCLIB")
        }
        guard !Task.isCancelled else { return (nil, nil) }

        if preferences.usesMusixmatch {
            if let lyrics = await lyricsFromMusixmatch(for: track) {
                return (lyrics, "Musixmatch")
            }
            guard !Task.isCancelled else { return (nil, nil) }

            if canonicalMetadataChanged,
                let canonicalTrack,
                let lyrics = await lyricsFromMusixmatch(for: canonicalTrack)
            {
                return (lyrics, "Musixmatch")
            }
        }

        return (nil, nil)
    }

    private func lyricsFromLRCLIB(for track: MusicTrack) async -> Lyrics? {
        let key = LyricsCacheKey(provider: .lrclib, track: track)
        let result = await cache.value(for: key) { [lrclibClient] in
            await Self.fetchLRCLIB(track: track, client: lrclibClient)
        }
        guard case let .found(lyrics) = result else { return nil }
        return lyrics
    }

    private func lyricsFromMusixmatch(for track: MusicTrack) async -> Lyrics? {
        let key = LyricsCacheKey(provider: .musixmatch, track: track)
        let result = await cache.value(for: key) { [musixmatchClient] in
            await musixmatchClient.fetch(for: track)
        }
        guard case let .found(lyrics) = result else { return nil }
        return lyrics
    }

    private static func fetchLRCLIB(
        track: MusicTrack,
        client: LRCLIBClient
    ) async -> LyricsFetchResult {
        let exactResult = await client.fetchExact(for: track)
        guard !Task.isCancelled else { return .transientFailure }
        switch exactResult {
        case .found:
            return exactResult
        case .transientFailure:
            return .transientFailure
        case .notFound:
            break
        }

        let artistSearchResult = await client.search(for: track, includeArtist: true)
        guard !Task.isCancelled else { return .transientFailure }
        switch artistSearchResult {
        case .found:
            return artistSearchResult
        case .transientFailure:
            return .transientFailure
        case .notFound:
            break
        }

        let titleSearchResult = await client.search(for: track, includeArtist: false)
        guard !Task.isCancelled else { return .transientFailure }
        switch titleSearchResult {
        case .found, .notFound:
            return titleSearchResult
        case .transientFailure:
            return .transientFailure
        }
    }
}

private struct LRCLIBPayload: Decodable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: FlexibleDouble?
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
        let album: String?
        let length: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case name = "track_name"
            case artist = "artist_name"
            case album = "album_name"
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
        let decoded: Double?
        if let double = try? container.decode(Double.self) {
            decoded = double
        } else if let string = try? container.decode(String.self) {
            decoded = Double(string)
        } else {
            decoded = nil
        }
        value = decoded?.isFinite == true ? decoded : nil
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
