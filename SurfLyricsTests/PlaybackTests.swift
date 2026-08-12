import XCTest
@testable import SurfLyrics

@MainActor
final class PlaybackTests: XCTestCase {
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
        let newLookupStarted = await eventually { manager.lyricsCallCount == 2 }
        XCTAssertTrue(newLookupStarted)

        manager.resolveLyrics(
            forTrackNamed: "Old Track",
            with: (Lyrics(lines: [LyricsLine(timeMs: 0, text: "Stale lyric")]), "Test")
        )
        await Task.yield()
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
        name: String = "Track"
    ) -> MusicTrack {
        MusicTrack(
            source: source,
            name: name,
            artist: "Artist",
            album: "Album",
            durationMs: 180_000,
            progressMs: 1_000,
            isPlaying: isPlaying
        )
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
        await withCheckedContinuation { continuation in
            lyricsContinuations.append((track, continuation))
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
