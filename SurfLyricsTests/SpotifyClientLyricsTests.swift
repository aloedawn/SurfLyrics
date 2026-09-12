import XCTest
@testable import SurfLyrics

final class SpotifyClientLyricsTests: XCTestCase {
    private let trackID = "6vgarqZvEEzWUgCK45gCfz"

    @MainActor
    func testFreshConnectionWaitsForClientWarmupBeforeFallingBack() async throws {
        let responses = ClientResponseSequence([
            try payload(status: "unsupported"), try payload(status: "transientFailure"), try payload(),
        ])
        let client = SpotifyClientLyricsClient(connection: WarmupConnection(isWarmingUp: true),
            evaluator: { _ in await responses.next() }, warmupDelay: {})
        let result = await client.fetch(for: track())
        XCTAssertEqual(result.lyrics?.lines.first?.text, "Line")
        let count = await responses.count
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testConfirmedMissingLyricsSkipWarmupRetries() async throws {
        let responses = ClientResponseSequence([try payload(status: "notFound")])
        let client = SpotifyClientLyricsClient(connection: WarmupConnection(isWarmingUp: true),
            evaluator: { _ in await responses.next() }, warmupDelay: {})
        let result = await client.fetch(for: track())
        XCTAssertEqual(result, .notFound)
        let count = await responses.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testStableConnectionFailureDoesNotTriggerWarmupRetries() async throws {
        let responses = ClientResponseSequence([try payload(status: "transientFailure")])
        let client = SpotifyClientLyricsClient(connection: WarmupConnection(isWarmingUp: false),
            evaluator: { _ in await responses.next() }, warmupDelay: {})
        let result = await client.fetch(for: track())
        XCTAssertEqual(result, .transientFailure)
        let count = await responses.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testWarmupRetriesAreBoundedForIncompatibleClients() async throws {
        let responses = ClientResponseSequence(Array(repeating: try payload(status: "unsupported"), count: 10))
        let client = SpotifyClientLyricsClient(connection: WarmupConnection(isWarmingUp: true),
            evaluator: { _ in await responses.next() }, warmupDelay: {})
        let result = await client.fetch(for: track())
        XCTAssertEqual(result, .transientFailure)
        let count = await responses.count
        XCTAssertEqual(count, 4)
    }

    func testClientTimesAndBlankLinesArePreserved() throws {
        let result = SpotifyClientLyricsClient.decode(try payload(lines: [
            ["startTimeMs": "1025", "words": "First"],
            ["startTimeMs": "2250", "words": ""],
            ["startTimeMs": "3075", "words": "Next"],
        ]), expectedTrack: track())
        guard case let .found(lyrics) = result else { return XCTFail("Expected synced lyrics") }
        XCTAssertEqual(lyrics.lookup(at: 2_000).currentText, "First")
        XCTAssertEqual(lyrics.lookup(at: 2_250).currentText, "")
        XCTAssertEqual(lyrics.lookup(at: 3_075).currentText, "Next")
        XCTAssertEqual(lyrics.lines.last?.timeMs, 3_075)
    }

    func testDifferentTrackOrInvalidTimesAreNeverDisplayed() throws {
        let differentTrack = try payload(id: "7vgarqZvEEzWUgCK45gCfz")
        XCTAssertEqual(SpotifyClientLyricsClient.decode(differentTrack, expectedTrack: track()), .transientFailure)
        for time in ["-1", "NaN", "1.5", "9999999999999999999999", "300000"] {
            let data = try payload(lines: [["startTimeMs": time, "words": "Invalid"]])
            XCTAssertEqual(SpotifyClientLyricsClient.decode(data, expectedTrack: track()), .transientFailure)
        }
        let unsorted = try payload(lines: [
            ["startTimeMs": "2000", "words": "Second"],
            ["startTimeMs": "1000", "words": "First"],
        ])
        XCTAssertEqual(SpotifyClientLyricsClient.decode(unsorted, expectedTrack: track()), .transientFailure)
    }

    func testPlainLyricsAndClientErrorsDoNotBecomeSyncedLyrics() throws {
        for status in ["unsynced", "notFound"] {
            let data = try payload(status: status)
            XCTAssertEqual(SpotifyClientLyricsClient.decode(data, expectedTrack: track()), .notFound)
        }
        for status in ["unsupported", "transientFailure"] {
            let data = try payload(status: status)
            XCTAssertEqual(SpotifyClientLyricsClient.decode(data, expectedTrack: track()), .transientFailure)
        }
        let plain = try payload(syncType: "UNSYNCED")
        XCTAssertEqual(SpotifyClientLyricsClient.decode(plain, expectedTrack: track()), .notFound)
    }

    func testOnlySpotifyPageOnFixedLoopbackPortCanBeEvaluated() {
        let valid = "ws://127.0.0.1:43827/devtools/page/123"
        let accepted = SpotifyClientTarget(type: "page", url: "https://xpui.app.spotify.com/index.html", webSocketDebuggerUrl: valid)
        XCTAssertNotNil(accepted.validatedWebSocketURL)
        for socket in [
            "ws://example.com:43827/devtools/page/123",
            "ws://127.0.0.1:9222/devtools/page/123",
            "ws://127.0.0.1:43827/devtools/browser/123",
            "ws://name:secret@127.0.0.1:43827/devtools/page/123",
        ] {
            XCTAssertNil(SpotifyClientTarget(type: "page", url: accepted.url, webSocketDebuggerUrl: socket).validatedWebSocketURL)
        }
        XCTAssertNil(SpotifyClientTarget(type: "page", url: "https://open.spotify.com", webSocketDebuggerUrl: valid).validatedWebSocketURL)
        XCTAssertNil(SpotifyClientTarget(type: "service_worker", url: accepted.url, webSocketDebuggerUrl: valid).validatedWebSocketURL)
    }

    func testTrackIDCannotInjectJavaScript() {
        XCTAssertTrue(SpotifyClientLyricsClient.isValidTrackID(trackID))
        for invalid in ["", "spotify:track:\(trackID)", "\(trackID)\"", "\(trackID)\n", String(repeating: "가", count: 22)] {
            XCTAssertFalse(SpotifyClientLyricsClient.isValidTrackID(invalid))
        }
    }

    @MainActor
    func testConnectionFailureCanBeRetriedWithoutMetadataOrFallbackRequests() async {
        let suite = "SpotifyClientLyricsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferenceKey.lyricsSourceSpotifyClient)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceLRCLIB)
        defaults.set(false, forKey: AppPreferenceKey.lyricsSourceMusixmatch)
        let lyrics = Lyrics(lines: [LyricsLine(timeMs: 10, text: "Client line")])
        let provider = StubClient(results: [.transientFailure, .found(lyrics)])
        let service = LyricsService(preferences: AppPreferences(defaults: defaults), spotifyClient: provider)
        let testTrack = track()
        let first = await service.getLyrics(for: testTrack)
        XCTAssertNil(first.0)
        let second = await service.getLyrics(for: testTrack)
        XCTAssertEqual(second.0, lyrics)
        XCTAssertEqual(second.1, "Spotify 클라이언트")
        let count = await provider.requestCount
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testDisabledClientProviderIsNotCalled() async {
        let suite = "SpotifyClientLyricsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [AppPreferenceKey.lyricsSourceSpotifyClient, AppPreferenceKey.lyricsSourceLRCLIB, AppPreferenceKey.lyricsSourceMusixmatch] {
            defaults.set(false, forKey: key)
        }
        let provider = StubClient(results: [.found(Lyrics(lines: []))])
        let service = LyricsService(preferences: AppPreferences(defaults: defaults), spotifyClient: provider)
        let testTrack = track()
        _ = await service.getLyrics(for: testTrack)
        let count = await provider.requestCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testClientSuccessTakesPriorityOverEnabledFallbackProviders() async {
        let suite = "SpotifyClientLyricsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let lyrics = Lyrics(lines: [LyricsLine(timeMs: 1000, text: "Client line")])
        let provider = StubClient(results: [.found(lyrics)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedFallbackProtocol.self]
        let service = LyricsService(
            preferences: AppPreferences(defaults: defaults),
            urlSession: URLSession(configuration: configuration), spotifyClient: provider
        )
        let result = await service.getLyrics(for: track())
        XCTAssertEqual(result.0, lyrics)
        XCTAssertEqual(result.1, "Spotify 클라이언트")
    }

    private func track() -> MusicTrack {
        MusicTrack(source: .spotify, sourceTrackID: trackID, name: "Faded Words", artist: "An da eun", album: "My Royal Nemesis", durationMs: 246_660, progressMs: 0, isPlaying: true)
    }

    private func payload(
        id: String? = nil, status: String = "found", syncType: String = "LINE_SYNCED",
        lines: [[String: String]] = [["startTimeMs": "1000", "words": "Line"]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": status, "trackID": id ?? trackID, "syncType": syncType, "lines": lines,
        ])
    }
}

@MainActor
private final class WarmupConnection: SpotifyConnectionPreparing {
    let isWarmingUp: Bool
    init(isWarmingUp: Bool) { self.isWarmingUp = isWarmingUp }
    func ensureReady(for track: MusicTrack) async -> Bool { true }
}

private actor ClientResponseSequence {
    private var responses: [Data]
    private(set) var count = 0
    init(_ responses: [Data]) { self.responses = responses }
    func next() -> Data {
        count += 1
        return responses.isEmpty ? Data() : responses.removeFirst()
    }
}

private actor StubClient: SpotifyClientLyricsProviding {
    private var results: [LyricsFetchResult]
    private(set) var requestCount = 0
    init(results: [LyricsFetchResult]) { self.results = results }
    func fetch(for track: MusicTrack) async -> LyricsFetchResult {
        requestCount += 1
        return results.isEmpty ? .transientFailure : results.removeFirst()
    }
}

private final class UnexpectedFallbackProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Client lyrics must be returned before requesting a fallback provider")
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
