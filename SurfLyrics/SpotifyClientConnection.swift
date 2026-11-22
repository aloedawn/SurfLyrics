import AppKit
import Combine

@MainActor
protocol SpotifyConnectionPreparing: Sendable {
    func ensureReady(for track: MusicTrack) async -> Bool
    var isWarmingUp: Bool { get }
}

@MainActor
protocol SpotifyConnectionEnvironment {
    var spotifyIsRunning: Bool { get }
    func isReady() async -> Bool
    func prepareConnection() async throws
    func restorePlayback(_ track: MusicTrack) async
}

enum SpotifyConnectionState: Equatable {
    case idle, connecting, connected, failed

    var message: String {
        switch self {
        case .idle: "Spotify 재생 시 자동으로 연결합니다."
        case .connecting: "Spotify 연결을 준비하고 있습니다…"
        case .connected: "Spotify 자동 연결됨"
        case .failed: "Spotify에 연결하지 못했습니다. 다시 시도할 수 있습니다."
        }
    }
}

@MainActor
final class SpotifyClientConnection: ObservableObject, SpotifyConnectionPreparing {
    static let shared = SpotifyClientConnection(environment: NativeSpotifyConnectionEnvironment())
    @Published private(set) var state: SpotifyConnectionState = .idle

    private let environment: any SpotifyConnectionEnvironment
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let connectionDidOpen: () -> Void
    private var inFlight: Task<Bool, Never>?
    private var lastAttempt: Date?
    private var connectedAt: Date?

    var isWarmingUp: Bool {
        connectedAt.map { now().timeIntervalSince($0) < 15 } ?? false
    }

    init(
        environment: any SpotifyConnectionEnvironment,
        isEnabled: @escaping () -> Bool = { AppPreferences().usesSpotifyClient },
        now: @escaping () -> Date = Date.init,
        connectionDidOpen: @escaping () -> Void = {
            NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
        }
    ) {
        self.environment = environment
        self.isEnabled = isEnabled
        self.now = now
        self.connectionDidOpen = connectionDidOpen
    }

    func retry() {
        lastAttempt = nil
    }

    func handleSpotifyTerminated() {
        if state == .connected {
            state = .idle
            connectedAt = nil
        }
    }

    func ensureReady(for track: MusicTrack) async -> Bool {
        guard isEnabled(), track.source == .spotify, track.itemKind == .track else { return false }
        if let inFlight { return await inFlight.value }
        // This task outlives a track lookup: restarting Spotify temporarily cancels that lookup.
        let work = Task { await self.connectIfNeeded(restoring: track) }
        inFlight = work
        let ready = await work.value
        inFlight = nil
        return ready
    }

    private func connectIfNeeded(restoring track: MusicTrack) async -> Bool {
        if await environment.isReady() {
            if state != .connected { connectedAt = now() }
            lastAttempt = nil
            state = .connected
            return true
        }
        guard isEnabled(), environment.spotifyIsRunning else {
            state = .idle
            return false
        }
        guard lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return false }
        lastAttempt = now()
        state = .connecting
        do {
            try await environment.prepareConnection()
            await environment.restorePlayback(track)
            lastAttempt = nil
            connectedAt = now()
            state = .connected
            connectionDidOpen()
            return true
        } catch {
            await environment.restorePlayback(track)
            lastAttempt = now()
            state = .failed
            return false
        }
    }
}

@MainActor
private final class NativeSpotifyConnectionEnvironment: SpotifyConnectionEnvironment {
    private let session = SpotifyClientEndpoint.sharedSession
    private let restorer = SpotifyPlaybackRestorer()
    private var spotifyProcessBeforeLaunch: pid_t?

    var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    func isReady() async -> Bool {
        (try? await SpotifyClientEndpoint.debuggerURL(using: session)) != nil
    }

    func prepareConnection() async throws {
        spotifyProcessBeforeLaunch = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
            .first?.processIdentifier
        try await SpotifyConnectionLauncher(environment: NativeSpotifyLaunchEnvironment()).connect()
    }

    func restorePlayback(_ track: MusicTrack) async {
        guard let previous = spotifyProcessBeforeLaunch,
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first,
            current.processIdentifier != previous
        else { return }
        await restorer.restore(track, pid: current.processIdentifier)
    }
}

actor SpotifyPlaybackRestorer {
    typealias TrackIDFetcher = @Sendable (pid_t) -> String?
    typealias PositionSetter = @Sendable (Double, pid_t) -> Bool
    typealias PlaybackCommandSender = @Sendable (Bool, pid_t) -> Void

    private let fetchTrackID: TrackIDFetcher
    private let setPosition: PositionSetter
    private let sendPlaybackCommand: PlaybackCommandSender

    init(
        fetchTrackID: @escaping TrackIDFetcher = { pid in
            guard let track = AppleEventClient.currentTrackSpecifier(),
                let idSpec = AppleEventClient.propertySpecifier(
                    container: track,
                    property: AppleEventClient.trackIDProperty
                ),
                case let .success(descriptor) = AppleEventClient.getData(of: idSpec, pid: pid, timeout: 5.0)
            else { return nil }
            return descriptor.stringValue
        },
        setPosition: @escaping PositionSetter = { position, pid in
            if case .success = AppleEventClient.setProperty(
                AppleEventClient.playerPositionProperty,
                value: NSAppleEventDescriptor(double: position),
                pid: pid,
                timeout: 5.0
            ) {
                return true
            }
            return false
        },
        sendPlaybackCommand: @escaping PlaybackCommandSender = { isPlaying, pid in
            _ = AppleEventClient.sendCommand(
                eventClass: AppleEventClient.spotifySuite,
                eventID: isPlaying ? AppleEventClient.spotifyPlayEvent : AppleEventClient.spotifyPauseEvent,
                pid: pid,
                timeout: 5.0
            )
        }
    ) {
        self.fetchTrackID = fetchTrackID
        self.setPosition = setPosition
        self.sendPlaybackCommand = sendPlaybackCommand
    }

    func restore(_ track: MusicTrack, pid: pid_t) {
        guard let id = track.sourceTrackID, SpotifyClientLyricsClient.isValidTrackID(id) else { return }
        guard let currentID = fetchTrackID(pid),
            currentID == "spotify:track:\(id)" || currentID == id
        else { return }
        // Do not log player responses. A changed track is intentionally left alone.
        let position = Double(max(0, min(track.progressMs, track.durationMs))) / 1_000
        _ = setPosition(position, pid)
        sendPlaybackCommand(track.isPlaying, pid)
    }
}
