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

    private func makeTrack(name: String) -> MusicTrack {
        MusicTrack(
            source: .spotify,
            name: name,
            artist: "Artist",
            album: "Album",
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

    func testLRCLIBFallbackOrderAndSessionCache() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let service = makeService(defaults: defaults)

        MockURLProtocol.state.setHandler { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let hasAlbum = query?.contains(where: { $0.name == "album_name" }) == true
            if hasAlbum {
                return (404, Data())
            }
            return (200, Data(#"{"syncedLyrics":"[00:01.00]Hello"}"#.utf8))
        }

        let first = await service.getLyrics(for: makeTrack())
        let second = await service.getLyrics(for: makeTrack())

        XCTAssertEqual(first.0?.lines.first?.text, "Hello")
        XCTAssertEqual(first.1, "LRCLIB")
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(MockURLProtocol.state.requestCount, 2)
    }

    func testMusixmatchRunsAfterBothLRCLIBLookupsMiss() async {
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
        XCTAssertEqual(MockURLProtocol.state.requestCount, 3)
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

        XCTAssertEqual(MockURLProtocol.state.requestCount, 4)
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

    private func makeTrack() -> MusicTrack {
        MusicTrack(
            source: .spotify,
            name: "Track",
            artist: "Artist",
            album: "Album",
            durationMs: 180_000,
            progressMs: 0,
            isPlaying: true
        )
    }

    nonisolated private static let musixmatchResponse = #"{"message":{"body":{"macro_calls":{"matcher.track.get":{"message":{"body":{"track":{"track_name":"Track","artist_name":"Artist","track_length":180}}}},"track.subtitles.get":{"message":{"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01.00]Hello"}}]}}}}}}}"#
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
