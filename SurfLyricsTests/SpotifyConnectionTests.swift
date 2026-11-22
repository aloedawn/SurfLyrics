import XCTest
@testable import SurfLyrics

@MainActor
final class SpotifyConnectionTests: XCTestCase {
    func testExistingConnectionNeverRestartsSpotifyOrChangesPlayback() async {
        let environment = FakeConnectionEnvironment(ready: [true])
        let connection = makeConnection(environment)
        let ready = await connection.ensureReady(for: track())
        XCTAssertTrue(ready)
        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(environment.preparations, 0)
        XCTAssertEqual(environment.restoredTracks, [])
    }

    func testSpotifyTerminationResetsConnectedState() async {
        let environment = FakeConnectionEnvironment(ready: [false, true])
        let connection = makeConnection(environment)
        let ready = await connection.ensureReady(for: track())
        XCTAssertTrue(ready)
        XCTAssertEqual(connection.state, .connected)
        XCTAssertTrue(connection.isWarmingUp)

        connection.handleSpotifyTerminated()
        XCTAssertEqual(connection.state, .idle)
        XCTAssertFalse(connection.isWarmingUp)
    }

    func testDisabledSourceAndClosedSpotifyDoNotLaunchApplications() async {
        let environment = FakeConnectionEnvironment(ready: [false])
        let disabled = SpotifyClientConnection(environment: environment, isEnabled: { false })
        let disabledResult = await disabled.ensureReady(for: track())
        XCTAssertFalse(disabledResult)
        XCTAssertEqual(environment.probes, 0)
        environment.spotifyIsRunning = false
        let connection = makeConnection(environment)
        let closedResult = await connection.ensureReady(for: track())
        XCTAssertFalse(closedResult)
        XCTAssertEqual(connection.state, .idle)
        XCTAssertEqual(environment.preparations, 0)
    }

    func testFailedLaunchHasCooldownAndExplicitRetry() async {
        let environment = FakeConnectionEnvironment(ready: [])
        environment.launchFails = true
        let connection = makeConnection(environment)
        _ = await connection.ensureReady(for: track())
        _ = await connection.ensureReady(for: track())
        XCTAssertEqual(connection.state, .failed)
        XCTAssertEqual(environment.preparations, 1)
        connection.retry()
        _ = await connection.ensureReady(for: track())
        XCTAssertEqual(environment.preparations, 2)
    }

    func testConcurrentLookupsShareConnectionAndSurviveLookupCancellation() async {
        let environment = FakeConnectionEnvironment(ready: [false, true])
        environment.holdFirstProbe = true
        var opened = 0
        let connection = makeConnection(environment) { opened += 1 }
        let first = Task { await connection.ensureReady(for: self.track()) }
        for _ in 0..<100 where environment.probeContinuation == nil { await Task.yield() }
        XCTAssertNotNil(environment.probeContinuation)
        let second = Task { await connection.ensureReady(for: self.track()) }
        first.cancel()
        environment.probeContinuation?.resume()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(environment.preparations, 1)
        XCTAssertEqual(opened, 1)
    }

    private func makeConnection(
        _ environment: FakeConnectionEnvironment, opened: @escaping () -> Void = {}
    ) -> SpotifyClientConnection {
        SpotifyClientConnection(environment: environment, isEnabled: { true }, connectionDidOpen: opened)
    }

    private func track() -> MusicTrack {
        MusicTrack(source: .spotify, sourceTrackID: "6vgarqZvEEzWUgCK45gCfz", name: "Test", artist: "Artist",
            album: "Album", durationMs: 200_000, progressMs: 50_000, isPlaying: true)
    }
}

final class SpotifyPlaybackRestorerTests: XCTestCase {
    private final class RecordedRestoreState: @unchecked Sendable {
        private let lock = NSLock()
        private var position: Double?
        private var playState: Bool?
        private var modified = false

        var recordedPosition: Double? { lock.withLock { position } }
        var recordedPlayState: Bool? { lock.withLock { playState } }
        var didModifyPlayback: Bool { lock.withLock { modified } }

        func recordPosition(_ value: Double) {
            lock.withLock {
                position = value
                modified = true
            }
        }

        func recordPlayState(_ value: Bool) {
            lock.withLock {
                playState = value
                modified = true
            }
        }
    }

    func testRestoresPositionAndPlaybackStateWhenTrackMatches() async {
        let state = RecordedRestoreState()
        let restorer = SpotifyPlaybackRestorer(
            fetchTrackID: { _ in "spotify:track:6vgarqZvEEzWUgCK45gCfz" },
            setPosition: { position, _ in
                state.recordPosition(position)
                return true
            },
            sendPlaybackCommand: { isPlaying, _ in
                state.recordPlayState(isPlaying)
            }
        )
        let track = MusicTrack(
            source: .spotify,
            sourceTrackID: "6vgarqZvEEzWUgCK45gCfz",
            name: "Test",
            artist: "Artist",
            album: "Album",
            durationMs: 200_000,
            progressMs: 45_500,
            isPlaying: false
        )
        await restorer.restore(track, pid: 123)
        XCTAssertEqual(state.recordedPosition, 45.5)
        XCTAssertEqual(state.recordedPlayState, false)
    }

    func testDoesNotAlterPlaybackWhenUserChangedTrack() async {
        let state = RecordedRestoreState()
        let restorer = SpotifyPlaybackRestorer(
            fetchTrackID: { _ in "spotify:track:0000000000000000000000" },
            setPosition: { position, _ in
                state.recordPosition(position)
                return true
            },
            sendPlaybackCommand: { isPlaying, _ in
                state.recordPlayState(isPlaying)
            }
        )
        let track = MusicTrack(
            source: .spotify,
            sourceTrackID: "6vgarqZvEEzWUgCK45gCfz",
            name: "Test",
            artist: "Artist",
            album: "Album",
            durationMs: 200_000,
            progressMs: 45_500,
            isPlaying: true
        )
        await restorer.restore(track, pid: 123)
        XCTAssertFalse(state.didModifyPlayback)
    }
}

@MainActor
private final class FakeConnectionEnvironment: SpotifyConnectionEnvironment {
    var spotifyIsRunning = true
    var launchFails = false
    var holdFirstProbe = false
    var probeContinuation: CheckedContinuation<Void, Never>?
    var restoredTracks: [MusicTrack] = []
    var preparations = 0
    var probes = 0
    private var ready: [Bool]

    init(ready: [Bool]) { self.ready = ready }

    func isReady() async -> Bool {
        probes += 1
        if holdFirstProbe && probes == 1 {
            await withCheckedContinuation { probeContinuation = $0 }
        }
        return ready.isEmpty ? false : ready.removeFirst()
    }

    func prepareConnection() throws {
        preparations += 1
        if launchFails { throw SpotifyClientBridgeError.unavailable }
    }

    func restorePlayback(_ track: MusicTrack) { restoredTracks.append(track) }
}

@MainActor
final class SpotifyConnectionLauncherTests: XCTestCase {
    func testReadySpotifyIsReusedWithoutRestart() async throws {
        let environment = FakeLaunchEnvironment(ready: [true])
        try await launcher(environment).connect()
        XCTAssertEqual(environment.quitCount, 0)
        XCTAssertEqual(environment.launchModes, [])
    }

    func testNormalSpotifyIsRestartedOnceForConnection() async throws {
        let environment = FakeLaunchEnvironment(ready: [false, true])
        try await launcher(environment).connect()
        XCTAssertEqual(environment.quitCount, 1)
        XCTAssertEqual(environment.launchModes, [true])
    }

    func testUnsafeListenerRestoresNormalSpotifyInsteadOfLeavingDebuggingOpen() async {
        let environment = FakeLaunchEnvironment(ready: [false, true])
        environment.loopback = false
        do {
            try await launcher(environment).connect()
            XCTFail("Unexpected success with a non-loopback listener")
        } catch {}
        XCTAssertEqual(environment.quitCount, 2)
        XCTAssertEqual(environment.launchModes, [true, false])
    }

    func testTimeoutRestoresNormalStartup() async {
        let environment = FakeLaunchEnvironment(ready: [])
        do {
            try await launcher(environment).connect()
            XCTFail("Unexpected success without a ready endpoint")
        } catch {}
        XCTAssertEqual(environment.launchModes, [true, false])
    }

    func testBindingValidationRejectsWildcardRemoteAndMissingListeners() {
        XCTAssertTrue(NativeSpotifyLaunchEnvironment.isLoopbackOnly("p123\nf4\nn127.0.0.1:43827\n"))
        for output in ["", "p123\nf4", "n*:43827", "n0.0.0.0:43827", "n192.168.1.1:43827", "n127.0.0.1:43827\nn*:43827"] {
            XCTAssertFalse(NativeSpotifyLaunchEnvironment.isLoopbackOnly(output))
        }
    }

    private func launcher(_ environment: FakeLaunchEnvironment) -> SpotifyConnectionLauncher {
        SpotifyConnectionLauncher(environment: environment, maximumPolls: 1, sleep: {})
    }
}

@MainActor
private final class FakeLaunchEnvironment: SpotifyLaunchEnvironment {
    var loopback = true
    var quitCount = 0
    var launchModes: [Bool] = []
    private var ready: [Bool]
    init(ready: [Bool]) { self.ready = ready }
    func isReady() -> Bool { ready.isEmpty ? false : ready.removeFirst() }
    func quitSpotify() { quitCount += 1 }
    func launchSpotify(withConnection: Bool) { launchModes.append(withConnection) }
    func hasLoopbackListener() -> Bool { loopback }
}
