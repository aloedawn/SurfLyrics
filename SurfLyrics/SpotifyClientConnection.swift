import AppKit
import Combine
import Security

@MainActor
protocol SpotifyConnectionPreparing: Sendable {
    func ensureReady(for track: MusicTrack) async -> Bool
    var isWarmingUp: Bool { get }
}

@MainActor
protocol SpotifyConnectionEnvironment {
    var spotifyIsRunning: Bool { get }
    var helperIsInstalled: Bool { get }
    func isReady() async -> Bool
    func launchHelper() async throws
    func restorePlayback(_ track: MusicTrack) async
}

enum SpotifyConnectionState: Equatable {
    case idle, connecting, connected, helperRequired, failed

    var message: String {
        switch self {
        case .idle: "Spotify 재생 시 자동으로 연결합니다."
        case .connecting: "Spotify 연결을 준비하고 있습니다…"
        case .connected: "Spotify 자동 연결됨"
        case .helperRequired: "연결 도우미를 처음 한 번 설치해 주세요."
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
    private let sleep: () async throws -> Void
    private let connectionDidOpen: () -> Void
    private let maximumPolls: Int
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
        maximumPolls: Int = 30,
        sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) },
        connectionDidOpen: @escaping () -> Void = {
            NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
        }
    ) {
        self.environment = environment
        self.isEnabled = isEnabled
        self.now = now
        self.maximumPolls = maximumPolls
        self.sleep = sleep
        self.connectionDidOpen = connectionDidOpen
    }

    func retry() {
        lastAttempt = nil
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
        guard environment.helperIsInstalled else {
            state = .helperRequired
            return false
        }
        guard lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return false }
        lastAttempt = now()
        state = .connecting
        do {
            try await environment.launchHelper()
            for _ in 0..<maximumPolls {
                if await environment.isReady() {
                    await environment.restorePlayback(track)
                    lastAttempt = nil
                    connectedAt = now()
                    state = .connected
                    connectionDidOpen()
                    return true
                }
                try await sleep()
            }
        } catch {}
        await environment.restorePlayback(track)
        lastAttempt = now()
        state = .failed
        return false
    }
}

@MainActor
private final class NativeSpotifyConnectionEnvironment: SpotifyConnectionEnvironment {
    private let session = SpotifyClientEndpoint.makeSession()
    private let restorer = SpotifyPlaybackRestorer()
    private var spotifyProcessBeforeLaunch: pid_t?

    var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    private var helperURL: URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyConnectionHelperIdentity.bundleID)
        else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(SpotifyConnectionHelperIdentity.bundleID)\" and certificate leaf[subject.OU] = \"\(SpotifyConnectionHelperIdentity.teamID)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else { return nil }
        return url
    }

    var helperIsInstalled: Bool { helperURL != nil }

    func isReady() async -> Bool {
        (try? await SpotifyClientEndpoint.debuggerURL(using: session)) != nil
    }

    func launchHelper() async throws {
        guard let helperURL else { throw SpotifyClientBridgeError.unavailable }
        spotifyProcessBeforeLaunch = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
            .first?.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // Sandboxed callers can launch the separately installed helper, but cannot pass launch arguments.
        _ = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
    }

    func restorePlayback(_ track: MusicTrack) async {
        guard let previous = spotifyProcessBeforeLaunch,
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first,
            current.processIdentifier != previous else { return }
        await restorer.restore(track)
    }
}

enum SpotifyConnectionHelperIdentity {
    static let bundleID = "com.aloedawn.surflyrics.connectionhelper"
    static let teamID = "2RDF6J3XVV"
}

private actor SpotifyPlaybackRestorer {
    func restore(_ track: MusicTrack) {
        guard let id = track.sourceTrackID, SpotifyClientLyricsClient.isValidTrackID(id) else { return }
        let position = Double(max(0, min(track.progressMs, track.durationMs))) / 1_000
        let script = """
        with timeout of 5 seconds
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    set currentID to id of current track as text
                    if currentID is "spotify:track:\(id)" or currentID is "\(id)" then
                        set player position to \(position)
                        \(track.isPlaying ? "play" : "pause")
                    end if
                end tell
            end if
        end timeout
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        // Do not log player responses. A changed track is intentionally left alone.
    }
}
