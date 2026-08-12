import AppKit
import XCTest
@testable import SurfLyrics

@MainActor
final class PlaybackTests: XCTestCase {
    func testInstalledPlayerAppleScriptsCompile() async {
        let installedPlayers = MusicPlayer.allCases.filter { player in
            NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier
            ) != nil
        }
        XCTAssertFalse(installedPlayers.isEmpty)

        let failures = await Task.detached {
            installedPlayers.compactMap { player -> String? in
                guard let script = NSAppleScript(
                    source: AppleScriptPlayerProbe.currentTrackScript(for: player)
                ) else {
                    return "Could not create \(player.displayName) AppleScript"
                }
                var errorInfo: NSDictionary?
                guard script.compileAndReturnError(&errorInfo) else {
                    return "\(player.displayName) AppleScript failed to compile: \(String(describing: errorInfo))"
                }
                return nil
            }
        }.value
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testTrackIdentityPrefersStableSourceIDOverLocalizedMetadata() {
        let localizedTrack = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: "  AbC123xYz  ",
            name: "현지화된 제목",
            artist: "현지화된 가수",
            album: "현지화된 앨범"
        )
        let canonicalTrack = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: "AbC123xYz",
            name: "Canonical Title",
            artist: "Canonical Artist",
            album: "Canonical Album"
        )
        let otherSourceTrack = makeTrack(
            source: .appleMusic,
            isPlaying: true,
            sourceTrackID: "AbC123xYz",
            name: "Canonical Title",
            artist: "Canonical Artist",
            album: "Canonical Album"
        )

        XCTAssertEqual(localizedTrack.identity, canonicalTrack.identity)
        XCTAssertNotEqual(localizedTrack.identity, otherSourceTrack.identity)
    }

    func testTrackIdentityFallsBackToMetadataForMissingOrBlankSourceID() {
        let missingID = makeTrack(source: .spotify, isPlaying: true)
        let blankID = makeTrack(
            source: .spotify,
            isPlaying: true,
            sourceTrackID: " \n "
        )

        XCTAssertEqual(missingID.identity, blankID.identity)
        XCTAssertEqual(
            missingID.identity,
            .metadata(
                source: .spotify,
                itemKind: .track,
                name: "Track",
                artist: "Artist",
                album: "Album",
                durationMs: 180_000
            )
        )
    }

    func testSpotifyTrackResponseNormalizesTrackURIWithoutChangingIDCase() throws {
        let response = makeProbeResponse(
            name: "현지화된 제목",
            artist: "현지화된 가수",
            rawID: "spotify:track:AbC123xYz",
            rawURL: ""
        )

        let track = try AppleScriptTrackResponseParser.parse(response, player: .spotify)

        XCTAssertEqual(track.sourceTrackID, "AbC123xYz")
        XCTAssertEqual(track.name, "현지화된 제목")
        XCTAssertEqual(track.artist, "현지화된 가수")
        XCTAssertEqual(track.durationMs, 180_000)
        XCTAssertEqual(track.progressMs, 12_500)
    }

    func testSpotifyTrackResponseFallsBackToTrackURLAndRejectsNonTrackIdentifiers() throws {
        let trackURLResponse = makeProbeResponse(
            rawID: "ZyX987AbC",
            rawURL: "https://open.spotify.com/intl-ko/track/ZyX987AbC?si=share"
        )
        let episodeResponse = makeProbeResponse(
            rawID: "spotify:episode:Episode123",
            rawURL: "https://open.spotify.com/episode/Episode123"
        )

        let track = try AppleScriptTrackResponseParser.parse(trackURLResponse, player: .spotify)
        let episode = try AppleScriptTrackResponseParser.parse(episodeResponse, player: .spotify)

        XCTAssertEqual(track.sourceTrackID, "ZyX987AbC")
        XCTAssertEqual(track.itemKind, .track)
        XCTAssertNil(episode.sourceTrackID)
        XCTAssertEqual(episode.itemKind, .episode)
    }

    func testSpotifyTrackResponseClassifiesLocalTracksAndAdvertisements() throws {
        let localResponse = makeProbeResponse(
            rawID: "spotify:local:Artist:Album:Track:180",
            rawURL: "spotify:local:Artist:Album:Track:180"
        )
        let advertisementResponse = makeProbeResponse(
            rawID: "spotify:ad:Advertisement123",
            rawURL: ""
        )

        let localTrack = try AppleScriptTrackResponseParser.parse(
            localResponse,
            player: .spotify
        )
        let advertisement = try AppleScriptTrackResponseParser.parse(
            advertisementResponse,
            player: .spotify
        )

        XCTAssertEqual(localTrack.itemKind, .localTrack)
        XCTAssertTrue(localTrack.itemKind.supportsLyricsLookup)
        XCTAssertEqual(advertisement.itemKind, .advertisement)
        XCTAssertFalse(advertisement.itemKind.supportsLyricsLookup)
    }

    func testSpotifyTrackResponseRejectsMalformedOrConflictingLocalTracks() throws {
        let malformed = makeProbeResponse(
            rawID: "spotify:local:Artist:Album",
            rawURL: ""
        )
        let conflicting = makeProbeResponse(
            rawID: "spotify:local:Artist:Album:Track:180",
            rawURL: "spotify:local:Artist:Album:Other:180"
        )

        let malformedTrack = try AppleScriptTrackResponseParser.parse(
            malformed,
            player: .spotify
        )
        let conflictingTrack = try AppleScriptTrackResponseParser.parse(
            conflicting,
            player: .spotify
        )

        XCTAssertFalse(malformedTrack.itemKind.supportsLyricsLookup)
        XCTAssertFalse(conflictingTrack.itemKind.supportsLyricsLookup)
    }

    func testSpotifyTrackResponseRejectsBareIDAndConflictingTypedIdentities() throws {
        let bareIDResponse = makeProbeResponse(
            rawID: "UnTypedBareID123",
            rawURL: ""
        )
        let conflictingTypeResponse = makeProbeResponse(
            rawID: "spotify:track:Track123",
            rawURL: "spotify:episode:Episode123"
        )
        let conflictingTrackResponse = makeProbeResponse(
            rawID: "spotify:track:Track123",
            rawURL: "https://open.spotify.com/track/OtherTrack456"
        )
        let conflictingBareResponse = makeProbeResponse(
            rawID: "Track123",
            rawURL: "https://open.spotify.com/track/OtherTrack456"
        )
        let bareEpisodeResponse = makeProbeResponse(
            rawID: "0zLhl3WsOCQHbe1BPTiHgr",
            rawURL: "spotify:episode:0zLhl3WsOCQHbe1BPTiHgr"
        )
        let nestedTrackPathResponse = makeProbeResponse(
            rawID: "",
            rawURL: "https://open.spotify.com/embed/track/Track123"
        )

        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(bareIDResponse, player: .spotify)
                .sourceTrackID
        )
        XCTAssertFalse(
            try AppleScriptTrackResponseParser.parse(bareIDResponse, player: .spotify)
                .itemKind.supportsLyricsLookup
        )
        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(
                conflictingTypeResponse,
                player: .spotify
            ).sourceTrackID
        )
        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(
                conflictingTrackResponse,
                player: .spotify
            ).sourceTrackID
        )
        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(
                conflictingBareResponse,
                player: .spotify
            ).sourceTrackID
        )
        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(
                bareEpisodeResponse,
                player: .spotify
            ).sourceTrackID
        )
        XCTAssertNil(
            try AppleScriptTrackResponseParser.parse(
                nestedTrackPathResponse,
                player: .spotify
            ).sourceTrackID
        )
    }

    func testAppleMusicTrackResponseAcceptsEmptyIdentityFields() throws {
        let response = makeProbeResponse(
            duration: "180.5",
            rawID: "",
            rawURL: ""
        )

        let track = try AppleScriptTrackResponseParser.parse(response, player: .appleMusic)

        XCTAssertNil(track.sourceTrackID)
        XCTAssertEqual(track.durationMs, 180_500)
        XCTAssertEqual(track.progressMs, 12_500)
    }

    func testTrackResponseParserReportsUnexpectedFieldCount() {
        let response = ["playing", "Track"].joined(
            separator: AppleScriptTrackResponseParser.separator
        )

        XCTAssertThrowsError(
            try AppleScriptTrackResponseParser.parse(response, player: .spotify)
        ) { error in
            XCTAssertEqual(
                error as? AppleScriptTrackResponseParser.ParseError,
                AppleScriptTrackResponseParser.ParseError(actualFieldCount: 2)
            )
        }
    }

    func testPreferredPlayingPlayerShortCircuitsOtherProbe() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .track(makeTrack(source: .appleMusic, isPlaying: true)),
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .appleMusic)
        XCTAssertEqual(probe.calls, [.appleMusic])
    }

    func testPausedPreferredPlayerFallsBackToPlayingPlayer() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .track(makeTrack(source: .appleMusic, isPlaying: false)),
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .spotify)
        XCTAssertEqual(probe.calls, [.appleMusic, .spotify])
    }

    func testUnavailablePreferredPlayerFallsBackToPlayingPlayer() async {
        let probe = StubPlayerProbe(
            running: [.spotify, .appleMusic],
            results: [
                .appleMusic: .inactive,
                .spotify: .track(makeTrack(source: .spotify, isPlaying: true)),
            ]
        )
        let client = MusicPlaybackClient(playerProbe: probe)

        let result = await client.getCurrentTrack(preferredPlayer: .appleMusic)

        XCTAssertEqual(result.track?.source, .spotify)
        XCTAssertEqual(probe.calls, [.appleMusic, .spotify])
    }

    func testRefreshRequestsCoalesceIntoOneTrailingRefresh() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        let initialRefreshStarted = await eventually { manager.playbackCallCount == 1 }
        XCTAssertTrue(initialRefreshStarted)

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        XCTAssertEqual(manager.playbackCallCount, 1)

        manager.resolveNextPlayback(with: .init(track: nil, issue: .unavailable("idle")))
        let trailingRefreshStarted = await eventually { manager.playbackCallCount == 2 }
        XCTAssertTrue(trailingRefreshStarted)
        XCTAssertEqual(manager.preferredPlayers, [nil, .appleMusic])

        manager.resolveNextPlayback(with: .init(track: nil, issue: .unavailable("idle")))
        let trailingRefreshFinished = await eventually { manager.pendingPlaybackCount == 0 }
        XCTAssertTrue(trailingRefreshFinished)
        XCTAssertEqual(manager.playbackCallCount, 2)
    }

    func testShutdownCancelsRefreshAndRejectsLaterRequests() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        let refreshStarted = await eventually { manager.playbackCallCount == 1 }
        XCTAssertTrue(refreshStarted)

        state.shutdown()
        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        manager.resolveNextPlayback(with: .init(track: nil, issue: .unavailable("idle")))
        let refreshFinished = await eventually { manager.pendingPlaybackCount == 0 }

        XCTAssertTrue(refreshFinished)
        XCTAssertEqual(manager.playbackCallCount, 1)
        XCTAssertEqual(state.statusText, "♪ Initializing")
    }

    func testStaleLyricsCompletionCannotOverwriteNewTrack() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, name: "Old Track"),
            issue: nil
        ))
        let oldLookupStarted = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertTrue(oldLookupStarted)

        state.requestPlaybackRefresh(preferredPlayer: .appleMusic)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .appleMusic, isPlaying: true, name: "New Track"),
            issue: nil
        ))
        let newLookupStarted = await eventually { manager.lyricsCallCount == 1 }
        XCTAssertTrue(newLookupStarted)

        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotEqual(state.statusText, "Stale lyric")

        manager.resolveLyrics(
            forTrackNamed: "New Track",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Fresh lyric")]), "Test")
        )
        let freshLyricsDisplayed = await eventually { state.statusText == "Fresh lyric" }
        XCTAssertTrue(freshLyricsDisplayed)
    }

    func testLyricsCompletionDoesNotPostponeExistingRefresh() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        guard let originalRefreshDate = state.scheduledRefreshDate else {
            return XCTFail("Expected the initial playback refresh to be scheduled")
        }

        manager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 2_000, text: "Next"),
            ]), "Test")
        )

        let lyricsDisplayed = await eventually { state.statusText == "Now" }
        XCTAssertTrue(lyricsDisplayed)
        XCTAssertEqual(state.scheduledRefreshDate, originalRefreshDate)
    }

    func testScheduledLyricsDisplayDoesNotWaitForPlaybackRefresh() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 2_000, text: "Next"),
            ]), "Test")
        )
        _ = await eventually { state.statusText == "Now" }

        state.fireScheduledRefreshForTesting()

        XCTAssertEqual(state.statusText, "Next")
        let refreshStarted = await eventually {
            manager.playbackCallCount == 2 && manager.pendingPlaybackCount == 1
        }
        XCTAssertTrue(refreshStarted)
        XCTAssertEqual(state.statusText, "Next")

        manager.resolveNextPlayback(with: .init(
            track: MusicTrack(
                source: .spotify,
                name: "Track",
                artist: "Artist",
                album: "Album",
                durationMs: 180_000,
                progressMs: 2_000,
                isPlaying: true
            ),
            issue: nil
        ))
        _ = await eventually { manager.pendingPlaybackCount == 0 }
        state.shutdown()
    }

    func testLocalizedMissRetriesChangedMetadataForSameSourceID() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "현지화된 제목",
                artist: "현지화된 가수"
            ),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(forTrackNamed: "현지화된 제목", with: (nil, nil))
        _ = await eventually { state.scheduledRefreshInterval == 5.0 }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Canonical Title",
                artist: "Canonical Artist"
            ),
            issue: nil
        ))
        let metadataUpdated = await eventually { state.statusText.contains("Canonical Title") }
        let canonicalLookupStarted = await eventually { manager.lyricsCallCount == 1 }

        XCTAssertTrue(metadataUpdated)
        XCTAssertTrue(canonicalLookupStarted)

        manager.resolveLyrics(
            forTrackNamed: "Canonical Title",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Recovered")]), "Test")
        )
        let recoveredLyricsDisplayed = await eventually { state.statusText == "Recovered" }
        XCTAssertTrue(recoveredLyricsDisplayed)
    }

    func testSuccessfulLyricsStayLoadedAcrossMetadataChangeForSameSourceID() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Localized Title"
            ),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }
        manager.resolveLyrics(
            forTrackNamed: "Localized Title",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Found")]), "Test")
        )
        _ = await eventually { state.statusText == "Found" }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                sourceTrackID: "StableTrack123",
                name: "Canonical Title"
            ),
            issue: nil
        ))
        let playbackFinished = await eventually { manager.pendingPlaybackCount == 0 }

        XCTAssertTrue(playbackFinished)
        XCTAssertEqual(state.statusText, "Found")
        XCTAssertEqual(manager.lyricsCallCount, 0)
    }

    func testEpisodePlaybackDoesNotStartLyricsLookup() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                itemKind: .episode,
                name: "Podcast Episode"
            ),
            issue: nil
        ))
        let playbackFinished = await eventually { manager.pendingPlaybackCount == 0 }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(playbackFinished)
        XCTAssertEqual(manager.lyricsCallCount, 0)
    }

    func testEpisodeTransitionCancelsPreviousTrackLyricsLookup() async {
        let manager = ControlledMusicManager()
        let state = AppState(musicManager: manager)
        defer { state.shutdown() }

        _ = await eventually { manager.playbackCallCount == 1 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true, name: "Track A"),
            issue: nil
        ))
        _ = await eventually { manager.lyricsCallCount == 1 }

        state.requestPlaybackRefresh(preferredPlayer: .spotify)
        _ = await eventually { manager.playbackCallCount == 2 }
        manager.resolveNextPlayback(with: .init(
            track: makeTrack(
                source: .spotify,
                isPlaying: true,
                itemKind: .episode,
                name: "Podcast"
            ),
            issue: nil
        ))
        let pendingLyricsCancelled = await eventually { manager.lyricsCallCount == 0 }

        XCTAssertTrue(pendingLyricsCancelled)
    }

    func testTimerReschedulesForIdleMissingLyricsAndUpcomingLine() async {
        let idleManager = ControlledMusicManager()
        let idleState = AppState(musicManager: idleManager)
        _ = await eventually { idleManager.playbackCallCount == 1 }
        idleManager.resolveNextPlayback(with: .init(track: nil, issue: .unavailable("idle")))
        let idleScheduled = await eventually { idleState.scheduledRefreshInterval == 3.0 }
        XCTAssertTrue(idleScheduled)
        XCTAssertEqual(idleState.scheduledRefreshInterval, 3.0)
        XCTAssertEqual(idleState.scheduledRefreshTolerance ?? -1, 0, accuracy: 0.001)
        idleState.shutdown()

        let missingManager = ControlledMusicManager()
        let missingState = AppState(musicManager: missingManager)
        _ = await eventually { missingManager.playbackCallCount == 1 }
        missingManager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { missingManager.lyricsCallCount == 1 }
        missingManager.resolveLyrics(forTrackNamed: "Track", with: (nil, nil))
        let missingScheduled = await eventually { missingState.scheduledRefreshInterval == 5.0 }
        XCTAssertTrue(missingScheduled)
        XCTAssertEqual(missingState.scheduledRefreshTolerance ?? -1, 0, accuracy: 0.001)
        missingState.shutdown()

        let syncedManager = ControlledMusicManager()
        let syncedState = AppState(musicManager: syncedManager)
        _ = await eventually { syncedManager.playbackCallCount == 1 }
        syncedManager.resolveNextPlayback(with: .init(
            track: makeTrack(source: .spotify, isPlaying: true),
            issue: nil
        ))
        _ = await eventually { syncedManager.lyricsCallCount == 1 }
        syncedManager.resolveLyrics(
            forTrackNamed: "Track",
            with: (Lyrics(lines: [
                LyricsLine(timeMs: 1_000, text: "Now"),
                LyricsLine(timeMs: 1_500, text: "Next"),
            ]), "Test")
        )
        let syncedScheduled = await eventually { syncedState.scheduledRefreshInterval == 0.5 }
        XCTAssertTrue(syncedScheduled)
        XCTAssertEqual(syncedState.scheduledRefreshTolerance ?? -1, 0, accuracy: 0.001)
        syncedState.shutdown()
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func makeTrack(
        source: MusicPlayer,
        isPlaying: Bool,
        sourceTrackID: String? = nil,
        itemKind: PlaybackItemKind = .track,
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album"
    ) -> MusicTrack {
        MusicTrack(
            source: source,
            sourceTrackID: sourceTrackID,
            itemKind: itemKind,
            name: name,
            artist: artist,
            album: album,
            durationMs: 180_000,
            progressMs: 1_000,
            isPlaying: isPlaying
        )
    }

    private func makeProbeResponse(
        state: String = "playing",
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        duration: String = "180000",
        position: String = "12.5",
        rawID: String,
        rawURL: String
    ) -> String {
        [state, name, artist, album, duration, position, rawID, rawURL]
            .joined(separator: AppleScriptTrackResponseParser.separator)
    }
}

@MainActor
private final class StubPlayerProbe: MusicPlayerProbing {
    let running: Set<MusicPlayer>
    let results: [MusicPlayer: TrackProbeResult]
    private(set) var calls: [MusicPlayer] = []

    init(running: Set<MusicPlayer>, results: [MusicPlayer: TrackProbeResult]) {
        self.running = running
        self.results = results
    }

    func runningPlayers() -> Set<MusicPlayer> {
        running
    }

    func probe(_ player: MusicPlayer) async -> TrackProbeResult {
        calls.append(player)
        return results[player] ?? .inactive
    }
}

@MainActor
private final class ControlledMusicManager: MusicManaging {
    private(set) var preferredPlayers: [MusicPlayer?] = []
    private var playbackContinuations: [CheckedContinuation<MusicPlaybackResult, Never>] = []
    private var lyricsContinuations: [(
        track: MusicTrack,
        continuation: CheckedContinuation<(Lyrics?, String?), Never>
    )] = []

    var playbackCallCount: Int { preferredPlayers.count }
    var pendingPlaybackCount: Int { playbackContinuations.count }
    var lyricsCallCount: Int { lyricsContinuations.count }

    func getCurrentTrack(preferredPlayer: MusicPlayer?) async -> MusicPlaybackResult {
        preferredPlayers.append(preferredPlayer)
        return await withCheckedContinuation { continuation in
            playbackContinuations.append(continuation)
        }
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lyricsContinuations.append((track, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                    let index = lyricsContinuations.firstIndex(where: { $0.track == track })
                else {
                    return
                }
                lyricsContinuations.remove(at: index).continuation.resume(returning: (nil, nil))
            }
        }
    }

    func resolveNextPlayback(with result: MusicPlaybackResult) {
        playbackContinuations.removeFirst().resume(returning: result)
    }

    func resolveLyrics(forTrackNamed name: String, with result: (Lyrics?, String?)) {
        guard let index = lyricsContinuations.firstIndex(where: { $0.track.name == name }) else {
            XCTFail("No pending lyrics request for \(name)")
            return
        }
        lyricsContinuations.remove(at: index).continuation.resume(returning: result)
    }
}
