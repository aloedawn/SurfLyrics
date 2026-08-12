import Foundation
import XCTest
@testable import SurfLyrics

@MainActor
final class LyricsCacheTests: XCTestCase {
    func testFoundValueIsCachedAndLeastRecentlyUsedEntryIsEvicted() async {
        let cache = LyricsCache(capacity: 2)
        let track1 = makeTrack(name: "One")
        let track2 = makeTrack(name: "Two")
        let track3 = makeTrack(name: "Three")
        let key1 = LyricsCacheKey(provider: .lrclib, track: track1)
        let key2 = LyricsCacheKey(provider: .lrclib, track: track2)
        let key3 = LyricsCacheKey(provider: .lrclib, track: track3)
        var loads = 0

        _ = await cache.value(for: key1) { loads += 1; return self.found("One") }
        _ = await cache.value(for: key2) { loads += 1; return self.found("Two") }
        _ = await cache.value(for: key1) { loads += 1; return self.found("Wrong") }
        _ = await cache.value(for: key3) { loads += 1; return self.found("Three") }
        _ = await cache.value(for: key2) { loads += 1; return self.found("Two again") }

        XCTAssertEqual(loads, 4)
    }

    func testNegativeCacheExpiresAndTransientFailuresAreNeverCached() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let cache = LyricsCache(negativeTTL: 300, now: { currentDate })
        let key = LyricsCacheKey(provider: .lrclib, track: makeTrack(name: "Missing"))
        var loads = 0

        _ = await cache.value(for: key) { loads += 1; return .notFound }
        _ = await cache.value(for: key) { loads += 1; return .found(Lyrics(lines: [])) }
        XCTAssertEqual(loads, 1)

        currentDate.addTimeInterval(301)
        _ = await cache.value(for: key) { loads += 1; return .transientFailure }
        _ = await cache.value(for: key) { loads += 1; return .transientFailure }
        XCTAssertEqual(loads, 3)
    }

    func testMetadataCacheSeparatesPlaybackItemKinds() async {
        let cache = LyricsCache()
        let regularKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(name: "Shared")
        )
        let localKey = LyricsCacheKey(
            provider: .lrclib,
            track: MusicTrack(
                source: .spotify,
                itemKind: .localTrack,
                name: "Shared",
                artist: "Artist",
                album: "Album",
                durationMs: 180_000,
                progressMs: 0,
                isPlaying: true
            )
        )
        var loads = 0

        _ = await cache.value(for: regularKey) {
            loads += 1
            return self.found("Regular")
        }
        let local = await cache.value(for: localKey) {
            loads += 1
            return self.found("Local")
        }

        XCTAssertEqual(local, found("Local"))
        XCTAssertEqual(loads, 2)
    }

    func testConcurrentRequestsShareOneLoader() async {
        let cache = LyricsCache()
        let key = LyricsCacheKey(provider: .lrclib, track: makeTrack(name: "Shared"))
        var loaderCount = 0
        var continuation: CheckedContinuation<LyricsFetchResult, Never>?

        let first = Task {
            await cache.value(for: key) {
                loaderCount += 1
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        let loaderStarted = await eventually { continuation != nil }
        XCTAssertTrue(loaderStarted)

        let second = Task {
            await cache.value(for: key) {
                loaderCount += 1
                return self.found("Duplicate")
            }
        }
        await Task.yield()
        XCTAssertEqual(loaderCount, 1)

        continuation?.resume(returning: found("Shared"))
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, found("Shared"))
        XCTAssertEqual(secondResult, found("Shared"))
    }

    func testCancellingLookupCancelsInFlightLoader() async {
        let cache = LyricsCache()
        let key = LyricsCacheKey(provider: .lrclib, track: makeTrack(name: "Cancelled"))
        var loaderStarted = false
        var loaderObservedCancellation = false

        let lookup = Task {
            await cache.value(for: key) {
                loaderStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return self.found("Too late")
                } catch {
                    loaderObservedCancellation = Task.isCancelled
                    return .transientFailure
                }
            }
        }
        let started = await eventually { loaderStarted }
        XCTAssertTrue(started)

        lookup.cancel()
        let result = await lookup.value

        XCTAssertEqual(result, .transientFailure)
        XCTAssertTrue(loaderObservedCancellation)
    }

    func testCancellingOneWaiterKeepsSharedLoaderRunning() async {
        let cache = LyricsCache()
        let key = LyricsCacheKey(provider: .lrclib, track: makeTrack(name: "Shared"))
        var loaderStarted = false
        var loaderObservedCancellation = false
        var loaderCount = 0

        let first = Task {
            await cache.value(for: key) {
                loaderCount += 1
                loaderStarted = true
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return self.found("Too late")
                } catch {
                    loaderObservedCancellation = Task.isCancelled
                    return .transientFailure
                }
            }
        }
        let started = await eventually { loaderStarted }
        XCTAssertTrue(started)

        let second = Task {
            await cache.value(for: key) {
                loaderCount += 1
                return self.found("Duplicate")
            }
        }
        await Task.yield()
        second.cancel()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(loaderCount, 1)
        XCTAssertFalse(loaderObservedCancellation)

        first.cancel()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .transientFailure)
        XCTAssertEqual(secondResult, .transientFailure)
        XCTAssertTrue(loaderObservedCancellation)
    }

    func testFoundLyricsAreSharedAcrossLocalizedMetadataForStableSourceID() async {
        let cache = LyricsCache()
        let localizedKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(
                name: "현지화된 제목",
                sourceTrackID: "StableTrack123",
                artist: "현지화된 가수"
            )
        )
        let canonicalKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(
                name: "Canonical Title",
                sourceTrackID: "StableTrack123",
                artist: "Canonical Artist"
            )
        )
        var loads = 0

        let first = await cache.value(for: localizedKey) {
            loads += 1
            return self.found("Shared")
        }
        let second = await cache.value(for: canonicalKey) {
            loads += 1
            return self.found("Wrong")
        }

        XCTAssertEqual(first, found("Shared"))
        XCTAssertEqual(second, found("Shared"))
        XCTAssertEqual(loads, 1)
    }

    func testNegativeLyricsRemainScopedToLocalizedQueryEvenWithStableSourceID() async {
        let cache = LyricsCache()
        let localizedKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(
                name: "현지화된 제목",
                sourceTrackID: "StableTrack123",
                artist: "현지화된 가수"
            )
        )
        let canonicalKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(
                name: "Canonical Title",
                sourceTrackID: "StableTrack123",
                artist: "Canonical Artist"
            )
        )
        var loads = 0

        _ = await cache.value(for: localizedKey) {
            loads += 1
            return .notFound
        }
        let canonical = await cache.value(for: canonicalKey) {
            loads += 1
            return self.found("Canonical")
        }

        XCTAssertEqual(canonical, found("Canonical"))
        XCTAssertEqual(loads, 2)
    }

    func testOlderLocalizedResultCannotOverwriteNewerStableIDResult() async {
        let cache = LyricsCache()
        let localizedKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(name: "Localized", sourceTrackID: "StableTrack123")
        )
        let canonicalKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(name: "Canonical", sourceTrackID: "StableTrack123")
        )
        var localizedContinuation: CheckedContinuation<LyricsFetchResult, Never>?
        var canonicalContinuation: CheckedContinuation<LyricsFetchResult, Never>?

        let localizedTask = Task {
            await cache.value(for: localizedKey) {
                await withCheckedContinuation { localizedContinuation = $0 }
            }
        }
        let localizedStarted = await eventually { localizedContinuation != nil }
        XCTAssertTrue(localizedStarted)

        let canonicalTask = Task {
            await cache.value(for: canonicalKey) {
                await withCheckedContinuation { canonicalContinuation = $0 }
            }
        }
        let canonicalStarted = await eventually { canonicalContinuation != nil }
        XCTAssertTrue(canonicalStarted)

        canonicalContinuation?.resume(returning: found("Canonical"))
        let canonicalResult = await canonicalTask.value
        XCTAssertEqual(canonicalResult, found("Canonical"))
        localizedContinuation?.resume(returning: found("Localized"))
        let localizedResult = await localizedTask.value
        XCTAssertEqual(localizedResult, found("Localized"))

        let cached = await cache.value(for: canonicalKey) { self.found("Wrong") }
        XCTAssertEqual(cached, found("Canonical"))
    }

    func testOlderFoundResultIsCachedWhenNewerStableIDLookupFails() async {
        let cache = LyricsCache()
        let olderKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(name: "Localized", sourceTrackID: "StableTrack123")
        )
        let newerKey = LyricsCacheKey(
            provider: .lrclib,
            track: makeTrack(name: "Canonical", sourceTrackID: "StableTrack123")
        )
        var olderContinuation: CheckedContinuation<LyricsFetchResult, Never>?
        var newerContinuation: CheckedContinuation<LyricsFetchResult, Never>?

        let olderTask = Task {
            await cache.value(for: olderKey) {
                await withCheckedContinuation { olderContinuation = $0 }
            }
        }
        let olderStarted = await eventually { olderContinuation != nil }
        XCTAssertTrue(olderStarted)
        let newerTask = Task {
            await cache.value(for: newerKey) {
                await withCheckedContinuation { newerContinuation = $0 }
            }
        }
        let newerStarted = await eventually { newerContinuation != nil }
        XCTAssertTrue(newerStarted)

        newerContinuation?.resume(returning: .transientFailure)
        let newerResult = await newerTask.value
        XCTAssertEqual(newerResult, .transientFailure)
        olderContinuation?.resume(returning: found("Recovered older"))
        let olderResult = await olderTask.value
        XCTAssertEqual(olderResult, found("Recovered older"))

        var loads = 0
        let cached = await cache.value(for: newerKey) {
            loads += 1
            return self.found("Wrong")
        }
        XCTAssertEqual(cached, found("Recovered older"))
        XCTAssertEqual(loads, 0)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func found(_ text: String) -> LyricsFetchResult {
        .found(Lyrics(lines: [LyricsLine(timeMs: 1_000, text: text)]))
    }

    private func makeTrack(
        name: String,
        sourceTrackID: String? = nil,
        artist: String = "Artist",
        album: String = "Album"
    ) -> MusicTrack {
        MusicTrack(
            source: .spotify,
            sourceTrackID: sourceTrackID,
            name: name,
            artist: artist,
            album: album,
            durationMs: 180_000,
            progressMs: 0,
            isPlaying: true
        )
    }
}

@MainActor
final class LyricsServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.state.reset()
    }

    func testLRCLIBExactRequestUsesFullSignatureAndSessionCache() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)

        MockURLProtocol.state.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/get")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["track_name"], "Track")
            XCTAssertEqual(query["artist_name"], "Artist")
            XCTAssertEqual(query["album_name"], "Album")
            XCTAssertEqual(query["duration"], "180")
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "User-Agent")?
                    .hasPrefix("SurfLyrics/") == true
            )
            return (200, Data(Self.lrclibExactResponse.utf8))
        }

        let first = await service.getLyrics(for: makeTrack())
        let second = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(first.0?.lines.first?.text, "Hello")
        XCTAssertEqual(first.1, "LRCLIB")
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(MockURLProtocol.state.requestCount, 1)
    }

    func testLRCLIBSearchSelectsCanonicalCandidateAfterExactMiss() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        let track = makeTrack(
            name: "HÉLLO！ (feat. Guest)",
            artist: "Beyoncé feat. JAY-Z"
        )

        MockURLProtocol.state.setHandler { request in
            if request.url?.path == "/api/get" {
                return (404, Data())
            }
            XCTAssertEqual(request.url?.path, "/api/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["track_name"], "HÉLLO！ (feat. Guest)")
            XCTAssertEqual(query["artist_name"], "Beyoncé feat. JAY-Z")
            return (200, Data(Self.lrclibCanonicalSearchResponse.utf8))
        }

        let result = await service.getLyrics(for: track)

        XCTAssertEqual(result.0?.lines.first?.text, "Canonical")
        XCTAssertEqual(result.1, "LRCLIB")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 2)
    }

    func testLRCLIBTitleOnlySearchRecoversAfterArtistConstrainedSearchMisses() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        let track = makeTrack(name: "Dynamite", artist: "BTS", album: "BE")

        MockURLProtocol.state.setHandler { request in
            if request.url?.path == "/api/get" {
                return (404, Data())
            }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let hasArtist = items.contains(where: { $0.name == "artist_name" })
            if hasArtist {
                return (200, Data("[]".utf8))
            }
            return (200, Data(Self.lrclibLocalizedArtistSearchResponse.utf8))
        }

        let result = await service.getLyrics(for: track)

        XCTAssertEqual(result.0?.lines.first?.text, "Recovered")
        XCTAssertEqual(result.1, "LRCLIB")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 3)
    }

    func testSpotifyEmbedMetadataRecoversFullyLocalizedTitleAndArtist() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        let track = makeTrack(
            sourceTrackID: "StableTrack123",
            name: "현지화된 제목",
            artist: "현지화된 가수",
            album: "Localized Album",
            durationMs: 179_000
        )

        MockURLProtocol.state.setHandler { request in
            if request.url?.host == "open.spotify.com" {
                XCTAssertEqual(request.url?.path, "/embed/track/StableTrack123")
                return (200, Data(Self.spotifyEmbedResponse.utf8))
            }

            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            if query["track_name"] == "Canonical Title",
                query["artist_name"] == "Canonical Artist",
                request.url?.path == "/api/get"
            {
                XCTAssertEqual(query["duration"], "180")
                return (200, Data(Self.lrclibCanonicalExactResponse.utf8))
            }
            return request.url?.path == "/api/get"
                ? (404, Data())
                : (200, Data("[]".utf8))
        }

        let result = await service.getLyrics(for: track)

        XCTAssertEqual(result.0?.lines.first?.text, "Canonical fallback")
        XCTAssertEqual(result.1, "LRCLIB")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 5)
    }

    func testSpotifyEmbedResolverRejectsMismatchedTrackID() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let resolver = SpotifyMetadataResolver(
            urlSession: URLSession(configuration: configuration)
        )
        let track = makeTrack(sourceTrackID: "ExpectedTrack123")
        MockURLProtocol.state.setHandler { _ in
            (200, Data(Self.spotifyEmbedResponse.utf8))
        }

        let resolved = await resolver.resolve(track)

        XCTAssertNil(resolved)
    }

    func testSpotifyEmbedResolverCachesMetadataByStableID() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let resolver = SpotifyMetadataResolver(
            urlSession: URLSession(configuration: configuration)
        )
        let track = makeTrack(sourceTrackID: "StableTrack123")
        MockURLProtocol.state.setHandler { _ in
            (200, Data(Self.spotifyEmbedResponse.utf8))
        }

        let first = await resolver.resolve(track)
        let second = await resolver.resolve(track)

        XCTAssertEqual(first?.name, "Canonical Title")
        XCTAssertEqual(second?.artist, "Canonical Artist")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 1)
    }

    func testMusixmatchRunsAfterAllLRCLIBLookupsMiss() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        AppPreferences(defaults: defaults).storeMusixmatchToken(
            "cached-token",
            expiresAt: Date().addingTimeInterval(600)
        )
        let service = makeService(defaults: defaults)

        MockURLProtocol.state.setHandler { request in
            if request.url?.host == "lrclib.net" {
                return (404, Data())
            }
            return (200, Data(Self.musixmatchResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(result.0?.lines.first?.text, "Hello")
        XCTAssertEqual(result.1, "Musixmatch")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 4)
    }

    func testMusixmatchUsesValidCachedTokenAndCachesLyrics() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let preferences = AppPreferences(defaults: defaults)
        preferences.storeMusixmatchToken("cached-token", expiresAt: Date().addingTimeInterval(600))
        let service = makeService(defaults: defaults)

        MockURLProtocol.state.setHandler { request in
            XCTAssertTrue(request.url?.path.contains("macro.subtitles.get") == true)
            return (200, Data(Self.musixmatchResponse.utf8))
        }

        let first = await service.getLyrics(for: makeTrack())
        let second = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(first.0?.lines.first?.text, "Hello")
        XCTAssertEqual(first.1, "Musixmatch")
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(MockURLProtocol.state.requestCount, 1)
    }

    func testMusixmatchUsesSharedMatcherForCanonicalMetadata() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        AppPreferences(defaults: defaults).storeMusixmatchToken(
            "cached-token",
            expiresAt: Date().addingTimeInterval(600)
        )
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { _ in
            (200, Data(Self.musixmatchCanonicalResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack(
            name: "HÉLLO！ (feat. Guest)",
            artist: "Beyoncé feat. JAY-Z"
        ))

        XCTAssertEqual(result.0?.lines.first?.text, "Canonical")
        XCTAssertEqual(result.1, "Musixmatch")
    }

    func testMusixmatchRejectsConflictingEdition() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        AppPreferences(defaults: defaults).storeMusixmatchToken(
            "cached-token",
            expiresAt: Date().addingTimeInterval(600)
        )
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { _ in
            (200, Data(Self.musixmatchLiveResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
    }

    func testMusixmatchRejectsSubtitleWithoutMatchedTrackMetadata() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        AppPreferences(defaults: defaults).storeMusixmatchToken(
            "cached-token",
            expiresAt: Date().addingTimeInterval(600)
        )
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { _ in
            (200, Data(Self.musixmatchSubtitleOnlyResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
    }

    func testNonFiniteProviderDurationDoesNotCrashDecoder() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { request in
            if request.url?.path == "/api/get" {
                return (404, Data())
            }
            return (200, Data(Self.lrclibNonFiniteDurationResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(result.0?.lines.first?.text, "Safe")
        XCTAssertEqual(result.1, "LRCLIB")
    }

    func testOverflowProviderDurationDoesNotCrashDecoder() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { request in
            if request.url?.path == "/api/get" {
                return (404, Data())
            }
            return (200, Data(Self.lrclibOverflowDurationResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(result.0?.lines.first?.text, "Safe")
        XCTAssertEqual(result.1, "LRCLIB")
    }

    func testExpiredMusixmatchTokenIsRefreshedBeforeLyricsRequest() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let preferences = AppPreferences(defaults: defaults)
        preferences.storeMusixmatchToken("expired-token", expiresAt: Date().addingTimeInterval(-1))
        let service = makeService(defaults: defaults)

        MockURLProtocol.state.setHandler { request in
            if request.url?.path.contains("token.get") == true {
                return (200, Data(#"{"message":{"body":{"user_token":"fresh-token"}}}"#.utf8))
            }
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "usertoken" })?.value
            XCTAssertEqual(token, "fresh-token")
            return (200, Data(Self.musixmatchResponse.utf8))
        }

        let result = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(result.0?.lines.first?.text, "Hello")
        XCTAssertEqual(preferences.musixmatchToken, "fresh-token")
        XCTAssertEqual(MockURLProtocol.state.requestCount, 2)
    }

    func testMalformedPayloadIsTransientAndNotCached() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { _ in (200, Data("not-json".utf8)) }

        _ = await service.getLyrics(for: makeTrack())
        _ = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(MockURLProtocol.state.requestCount, 2)
    }

    func testLRCLIBRateLimitStartsClientCooldown() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)
        MockURLProtocol.state.setHandler { _ in (429, Data()) }

        let first = await service.getLyrics(for: makeTrack())
        let second = await service.getLyrics(for: makeTrack())

        XCTAssertNil(first.0)
        XCTAssertNil(second.0)
        XCTAssertEqual(MockURLProtocol.state.requestCount, 1)
    }

    private func makeService(defaults: UserDefaults) -> LyricsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return LyricsService(
            preferences: AppPreferences(defaults: defaults),
            urlSession: URLSession(configuration: configuration)
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LyricsServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTrack(
        sourceTrackID: String? = nil,
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        durationMs: Int = 180_000
    ) -> MusicTrack {
        MusicTrack(
            source: .spotify,
            sourceTrackID: sourceTrackID,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs,
            progressMs: 0,
            isPlaying: true
        )
    }

    nonisolated private static let lrclibExactResponse = #"{"id":1,"trackName":"Track","artistName":"Artist","albumName":"Album","duration":180,"syncedLyrics":"[00:01.00]Hello"}"#
    nonisolated private static let lrclibCanonicalSearchResponse = #"[{"id":1,"trackName":"Hello","artistName":"Wrong Artist","albumName":"Other","duration":180,"syncedLyrics":"[00:01.00]Wrong"},{"id":2,"trackName":"hello","artistName":"Beyonce","albumName":"Album","duration":180.5,"syncedLyrics":"[00:01.00]Canonical"}]"#
    nonisolated private static let lrclibLocalizedArtistSearchResponse = #"[{"id":3,"trackName":"Dynamite","artistName":"BTS","albumName":"BE","duration":180,"syncedLyrics":"[00:01.00]Recovered"}]"#
    nonisolated private static let lrclibCanonicalExactResponse = #"{"id":6,"trackName":"Canonical Title","artistName":"Canonical Artist","albumName":"Localized Album","duration":180,"syncedLyrics":"[00:01.00]Canonical fallback"}"#
    nonisolated private static let spotifyEmbedResponse = #"<!doctype html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"track","id":"StableTrack123","name":"Canonical Title","artists":[{"name":"Canonical Artist"}],"duration":180123}}}}}}</script>"#
    nonisolated private static let lrclibNonFiniteDurationResponse = #"[{"id":4,"trackName":"Track","artistName":"Artist","albumName":"Album","duration":"NaN","syncedLyrics":"[00:01.00]Safe"}]"#
    nonisolated private static let lrclibOverflowDurationResponse = #"[{"id":5,"trackName":"Track","artistName":"Artist","albumName":"Album","duration":"9.223372036854776e15","syncedLyrics":"[00:01.00]Safe"}]"#
    nonisolated private static let musixmatchResponse = #"{"message":{"body":{"macro_calls":{"matcher.track.get":{"message":{"body":{"track":{"track_name":"Track","artist_name":"Artist","track_length":180}}}},"track.subtitles.get":{"message":{"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01.00]Hello"}}]}}}}}}}"#
    nonisolated private static let musixmatchCanonicalResponse = #"{"message":{"body":{"macro_calls":{"matcher.track.get":{"message":{"body":{"track":{"track_name":"hello","artist_name":"beyonce","album_name":"Album","track_length":180}}}},"track.subtitles.get":{"message":{"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01.00]Canonical"}}]}}}}}}}"#
    nonisolated private static let musixmatchLiveResponse = #"{"message":{"body":{"macro_calls":{"matcher.track.get":{"message":{"body":{"track":{"track_name":"Track (Live)","artist_name":"Artist","album_name":"Album","track_length":180}}}},"track.subtitles.get":{"message":{"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01.00]Wrong edition"}}]}}}}}}}"#
    nonisolated private static let musixmatchSubtitleOnlyResponse = #"{"message":{"body":{"macro_calls":{"track.subtitles.get":{"message":{"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01.00]Unverified"}}]}}}}}}}"#
}

private final class MockURLProtocol: URLProtocol {
    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (statusCode, data) = Self.state.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    final class State: @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) -> (Int, Data)

        private let lock = NSLock()
        private var handler: Handler?
        private var count = 0

        var requestCount: Int {
            lock.withLock { count }
        }

        func setHandler(_ handler: @escaping Handler) {
            lock.withLock { self.handler = handler }
        }

        func response(for request: URLRequest) -> (Int, Data) {
            lock.withLock {
                count += 1
                return handler?(request) ?? (500, Data())
            }
        }

        func reset() {
            lock.withLock {
                handler = nil
                count = 0
            }
        }
    }
}
