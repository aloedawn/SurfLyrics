import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    private struct PlaybackClock {
        let trackID: TrackIdentity
        let anchorProgressMs: Int
        let anchorUptime: TimeInterval
        let durationMs: Int

        func estimatedProgressMs(at uptime: TimeInterval) -> Int {
            let elapsedSeconds = max(0, uptime - anchorUptime)
            let elapsedMs = elapsedSeconds >= Double(Int.max / 1_000)
                ? Int.max
                : Int((elapsedSeconds * 1_000).rounded())
            let (raw, overflow) = anchorProgressMs.addingReportingOverflow(elapsedMs)
            let clampedRaw = overflow ? Int.max : max(0, raw)
            if durationMs > 0 {
                return min(clampedRaw, durationMs)
            }
            return clampedRaw
        }
    }

    private enum LyricsLoadState {
        case idle
        case loading(LyricsQueryIdentity)
        case finished(LyricsQueryIdentity?, Lyrics?)

        var lyrics: Lyrics? {
            if case let .finished(_, lyrics) = self { return lyrics }
            return nil
        }

        var queryIdentity: LyricsQueryIdentity? {
            switch self {
            case .idle: nil
            case let .loading(query), let .finished(query?, _): query
            case .finished(nil, _): nil
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var hasFinished: Bool {
            if case .finished = self { return true }
            return false
        }
    }

    private enum SyncPolicy {
        static let inactiveInterval: TimeInterval = 15.0
        static let inactiveTolerance: TimeInterval = 5.0
        static let playingSyncedInterval: TimeInterval = 2.0
        static let playingSyncedTolerance: TimeInterval = 0.4
        static let lyricPiggybackMinInterval: TimeInterval = 1.5
        static let loadingInterval: TimeInterval = 5.0
        static let loadingTolerance: TimeInterval = 1.0
        static let endOfTrackThreshold: TimeInterval = 8.0
        static let endOfTrackPadding: TimeInterval = 0.2
        static let endOfTrackMinimum: TimeInterval = 0.5
        static let endOfTrackTolerance: TimeInterval = 0.2
        static let missingLyricsMaxInterval: TimeInterval = 15.0
        static let missingLyricsMinInterval: TimeInterval = 1.0
        static let missingLyricsPadding: TimeInterval = 0.5
        static let missingLyricsTolerance: TimeInterval = 2.0
        static let lyricTimerMinimum: TimeInterval = 0.05
        static let lyricTimerTolerance: TimeInterval = 0.03
    }

    @Published private(set) var statusText = ""
    @Published private(set) var sourceText: String?
    @Published private(set) var needsAutomationPermission = false

    private let musicManager: any MusicManaging
    private let textFormatter: StatusTextFormatter
    private let workspaceNotificationCenter: NotificationCenter
    private let monotonicTime: () -> TimeInterval
    private let onSpotifyTerminated: @MainActor () -> Void
    private let idleStatusText = ""

    private var syncTimer: Timer?
    private var scheduledSyncIntervalValue: TimeInterval?
    private var syncTimerGeneration: UInt = 0

    private var lyricTimer: Timer?
    private var scheduledLyricIntervalValue: TimeInterval?
    private var lyricTimerGeneration: UInt = 0

    private var playbackClock: PlaybackClock?
    private var refreshTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var currentTrackId: TrackIdentity?
    private var lyricsState: LyricsLoadState = .idle
    private var currentTrack: MusicTrack?
    private var preferredPlayer: MusicPlayer?
    private var pendingPreferredPlayer: MusicPlayer?
    private var pendingProbeMode: PlaybackProbeMode?
    private var lastSyncUptime: TimeInterval?
    private var isRefreshInFlight = false
    private var needsTrailingRefresh = false
    private var isShuttingDown = false

    var scheduledSyncInterval: TimeInterval? { scheduledSyncIntervalValue }
    var scheduledSyncTolerance: TimeInterval? { syncTimer?.tolerance }
    var scheduledSyncDate: Date? { syncTimer?.fireDate }
    var scheduledLyricInterval: TimeInterval? { scheduledLyricIntervalValue }
    var scheduledLyricTolerance: TimeInterval? { lyricTimer?.tolerance }
    var scheduledLyricDate: Date? { lyricTimer?.fireDate }

    init(
        preferences: AppPreferences = AppPreferences(),
        musicManager: (any MusicManaging)? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onSpotifyTerminated: @escaping @MainActor () -> Void = {
            SpotifyClientConnection.shared.handleSpotifyTerminated()
        }
    ) {
        self.musicManager = musicManager ?? MusicManager(preferences: preferences)
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.monotonicTime = monotonicTime
        self.onSpotifyTerminated = onSpotifyTerminated
        textFormatter = StatusTextFormatter(preferences: preferences)

        observePlaybackChanges()
        observeSettingsChanges()
        observeWorkspaceChanges()
        requestPlaybackRefresh(probeMode: .fullMetadata)
    }

    private func observePlaybackChanges() {
        for player in MusicPlayer.allCases {
            for notificationName in player.playbackNotificationNames {
                let observer = DistributedNotificationCenter.default().addObserver(
                    forName: notificationName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.requestPlaybackRefresh(preferredPlayer: player, probeMode: .fullMetadata)
                    }
                }
                distributedObservers.append(observer)
            }
        }
    }

    private func observeSettingsChanges() {
        let displayObserver = NotificationCenter.default.addObserver(
            forName: .settingsDisplayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                let progressMs = self.resolvedProgressMs(for: track)
                self.updateDisplay(for: track, progressMs: progressMs, force: true)
            }
        }
        localObservers.append(displayObserver)

        let lyricsObserver = NotificationCenter.default.addObserver(
            forName: .settingsLyricsSourcesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                self.musicManager.invalidateLyricsCache(for: track)
                self.reloadLyrics(for: track)
            }
        }
        localObservers.append(lyricsObserver)
    }

    private func observeWorkspaceChanges() {
        let launchObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, let bundleID,
                    let player = MusicPlayer.allCases.first(where: { $0.bundleIdentifier == bundleID })
                else { return }
                self.requestPlaybackRefresh(preferredPlayer: player, probeMode: .fullMetadata)
            }
        }
        workspaceObservers.append(launchObserver)

        let terminateObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, let bundleID,
                    let player = MusicPlayer.allCases.first(where: { $0.bundleIdentifier == bundleID })
                else { return }
                if player == .spotify {
                    self.onSpotifyTerminated()
                    self.musicManager.invalidateSpotifyEndpoint()
                }
                self.requestPlaybackRefresh(probeMode: .fullMetadata)
            }
        }
        workspaceObservers.append(terminateObserver)

        let wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestPlaybackRefresh(probeMode: .fullMetadata)
            }
        }
        workspaceObservers.append(wakeObserver)
    }

    func requestPlaybackRefresh(
        preferredPlayer: MusicPlayer? = nil,
        probeMode: PlaybackProbeMode = .fullMetadata
    ) {
        guard !isShuttingDown else { return }
        if let preferredPlayer {
            cancelSyncTimer()
            pendingPreferredPlayer = preferredPlayer
        }
        pendingProbeMode = pendingProbeMode?.merged(with: probeMode) ?? probeMode

        guard !isRefreshInFlight else {
            needsTrailingRefresh = true
            return
        }

        isRefreshInFlight = true
        let musicManager = musicManager
        let requestedPlayer = pendingPreferredPlayer ?? self.preferredPlayer
        let requestedProbeMode = pendingProbeMode ?? .fullMetadata
        pendingPreferredPlayer = nil
        pendingProbeMode = nil
        refreshTask = Task { [weak self] in
            let result = await musicManager.getCurrentTrack(
                preferredPlayer: requestedPlayer,
                probeMode: requestedProbeMode
            )
            guard let self else { return }
            finishPlaybackRefresh(result, wasCancelled: Task.isCancelled)
        }
    }

    private func finishPlaybackRefresh(_ result: MusicPlaybackResult, wasCancelled: Bool) {
        isRefreshInFlight = false
        refreshTask = nil

        if !wasCancelled, !isShuttingDown {
            applyPlaybackResult(result)
        }

        if needsTrailingRefresh, !isShuttingDown {
            needsTrailingRefresh = false
            requestPlaybackRefresh(probeMode: pendingProbeMode ?? .trackAndState)
        }
    }

    private func applyPlaybackResult(_ result: MusicPlaybackResult) {
        guard let track = result.track else {
            handleUnavailablePlayback(result.issue)
            return
        }

        setNeedsAutomationPermission(false)
        currentTrack = track
        preferredPlayer = track.source
        track.isPlaying ? handlePlaying(track) : handlePaused(track)
    }

    private func handleUnavailablePlayback(_ issue: MusicPlaybackIssue?) {
        cancelLyricTimer()
        playbackClock = nil
        lastSyncUptime = nil
        resetLyrics(for: nil)
        currentTrack = nil

        if case .noRunningPlayers = issue {
            setNeedsAutomationPermission(false)
            setStatusText(idleStatusText)
            cancelSyncTimer()
            return
        }

        let requiresPermission = issue?.requiresAutomationPermission == true
        setNeedsAutomationPermission(requiresPermission)
        setStatusText(requiresPermission ? "⚠ 음악 앱 접근 권한 필요" : idleStatusText)
        scheduleSyncTimer(
            interval: SyncPolicy.inactiveInterval,
            tolerance: SyncPolicy.inactiveTolerance
        )
    }

    private func handlePlaying(_ track: MusicTrack) {
        let now = monotonicTime()
        lastSyncUptime = now
        playbackClock = PlaybackClock(
            trackID: track.identity,
            anchorProgressMs: track.progressMs,
            anchorUptime: now,
            durationMs: track.durationMs
        )

        let id = track.identity
        if id != currentTrackId {
            resetLyrics(for: track)
            if track.itemKind.supportsLyricsLookup {
                loadLyrics(for: track)
            } else {
                lyricsState = .finished(nil, nil)
                updateDisplay(for: track, progressMs: track.progressMs, force: false)
            }
        } else {
            if track.itemKind.supportsLyricsLookup,
                lyricsState.lyrics == nil,
                (!lyricsState.hasFinished || lyricsState.queryIdentity != track.lyricsQueryIdentity)
            {
                loadLyrics(for: track)
            }
            if sourceText == nil || lyricsState.lyrics == nil {
                setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
            }
            updateDisplay(for: track, progressMs: track.progressMs, force: false)
        }

        updateTimers(for: track, progressMs: track.progressMs)
    }

    private func handlePaused(_ track: MusicTrack) {
        cancelLyricTimer()
        playbackClock = nil
        lastSyncUptime = nil

        let id = track.identity
        if id != currentTrackId {
            resetLyrics(for: track)
        }
        if track.itemKind.supportsLyricsLookup,
            lyricsState.lyrics == nil,
            (!lyricsState.hasFinished || lyricsState.queryIdentity != track.lyricsQueryIdentity)
        {
            loadLyrics(for: track)
        }
        if sourceText == nil {
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
        }
        updateDisplay(for: track, progressMs: track.progressMs, force: false)
        scheduleSyncTimer(
            interval: SyncPolicy.inactiveInterval,
            tolerance: SyncPolicy.inactiveTolerance
        )
    }

    private func resetLyrics(for track: MusicTrack?) {
        lyricsTask?.cancel()
        lyricsTask = nil
        currentTrackId = track?.identity
        lyricsState = .idle
        setSourceText(track.map { textFormatter.sourceDescription(for: $0, lyricsSource: nil) })
    }

    private func reloadLyrics(for track: MusicTrack) {
        resetLyrics(for: track)
        let progressMs = resolvedProgressMs(for: track)
        if track.itemKind.supportsLyricsLookup {
            loadLyrics(for: track)
        } else {
            lyricsState = .finished(nil, nil)
            updateDisplay(for: track, progressMs: progressMs, force: false)
        }
        updateTimers(for: track, progressMs: progressMs)
    }

    private func loadLyrics(for track: MusicTrack) {
        let requestedQueryIdentity = track.lyricsQueryIdentity
        if lyricsState.isLoading, lyricsState.queryIdentity == requestedQueryIdentity {
            return
        }
        cancelLyricTimer()
        lyricsTask?.cancel()
        lyricsState = .loading(requestedQueryIdentity)
        setStatusText(textFormatter.text(for: track, lyricsLine: nil, isLoadingLyrics: true))
        let requestedTrackId = track.identity

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let (lyrics, source) = await musicManager.getLyrics(for: track)
            guard !Task.isCancelled,
                requestedTrackId == currentTrackId,
                requestedQueryIdentity == lyricsState.queryIdentity
            else {
                return
            }

            lyricsState = .finished(requestedQueryIdentity, lyrics)
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: source))
            guard let currentTrack else { return }
            let progressMs = resolvedProgressMs(for: currentTrack)
            updateDisplay(for: currentTrack, progressMs: progressMs, force: false)
            if currentTrack.isPlaying {
                if lyrics != nil {
                    scheduleLyricTimer(for: currentTrack, progressMs: progressMs)
                    let schedule = syncSchedule(for: currentTrack, progressMs: progressMs)
                    scheduleSyncTimer(
                        interval: schedule.interval,
                        tolerance: schedule.tolerance,
                        onlyIfEarlier: true
                    )
                } else {
                    cancelLyricTimer()
                    let schedule = syncSchedule(for: currentTrack, progressMs: progressMs)
                    scheduleSyncTimer(
                        interval: schedule.interval,
                        tolerance: schedule.tolerance
                    )
                }
            } else {
                cancelLyricTimer()
                scheduleSyncTimer(
                    interval: SyncPolicy.inactiveInterval,
                    tolerance: SyncPolicy.inactiveTolerance,
                    onlyIfEarlier: true
                )
            }
        }
    }

    private func updateTimers(for track: MusicTrack, progressMs: Int) {
        if track.isPlaying, !lyricsState.isLoading, lyricsState.lyrics != nil {
            scheduleLyricTimer(for: track, progressMs: progressMs)
        } else {
            cancelLyricTimer()
        }
        let schedule = syncSchedule(for: track, progressMs: progressMs)
        scheduleSyncTimer(interval: schedule.interval, tolerance: schedule.tolerance)
    }

    private func scheduleLyricTimer(for track: MusicTrack, progressMs: Int) {
        guard track.isPlaying,
            !lyricsState.isLoading,
            let lookup = lyricsState.lyrics?.lookup(at: progressMs),
            let nextLineTimeMs = lookup.nextLineTimeMs
        else {
            cancelLyricTimer()
            return
        }

        let interval = max(
            SyncPolicy.lyricTimerMinimum,
            Double(nextLineTimeMs - progressMs) / 1_000.0
        )
        cancelLyricTimer()
        scheduledLyricIntervalValue = interval
        let generation = lyricTimerGeneration
        let timer = Timer(
            fire: Date().addingTimeInterval(interval),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLyricTimer(generation: generation)
            }
        }
        timer.tolerance = SyncPolicy.lyricTimerTolerance
        lyricTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleLyricTimer(generation: UInt) {
        guard !isShuttingDown,
            generation == lyricTimerGeneration,
            let track = currentTrack,
            track.isPlaying,
            !lyricsState.isLoading,
            lyricsState.lyrics != nil
        else {
            cancelLyricTimer()
            return
        }

        let progressMs = resolvedProgressMs(for: track)
        updateDisplay(for: track, progressMs: progressMs, force: false)
        scheduleLyricTimer(for: track, progressMs: progressMs)
        piggybackPositionSyncIfNeeded(for: track, progressMs: progressMs)
    }

    private func piggybackPositionSyncIfNeeded(for track: MusicTrack, progressMs: Int) {
        guard !isRefreshInFlight,
            let lastSyncUptime,
            monotonicTime() - lastSyncUptime >= SyncPolicy.lyricPiggybackMinInterval
        else {
            return
        }
        cancelSyncTimer()
        requestPlaybackRefresh(probeMode: syncProbeMode(for: track, progressMs: progressMs))
    }

    private func syncProbeMode(for track: MusicTrack, progressMs: Int) -> PlaybackProbeMode {
        guard track.isPlaying,
            !lyricsState.isLoading,
            lyricsState.lyrics != nil,
            let playbackClock,
            playbackClock.trackID == track.identity
        else {
            return .trackAndState
        }

        if track.durationMs > 0 {
            let remaining = Double(max(0, track.durationMs - progressMs)) / 1_000.0
            if remaining < SyncPolicy.endOfTrackThreshold {
                return .trackAndState
            }
        }
        return .positionOnly(expectedProgressMs: progressMs)
    }

    private func cancelLyricTimer() {
        lyricTimerGeneration &+= 1
        lyricTimer?.invalidate()
        lyricTimer = nil
        scheduledLyricIntervalValue = nil
    }

    private func syncSchedule(
        for track: MusicTrack,
        progressMs: Int
    ) -> (interval: TimeInterval, tolerance: TimeInterval) {
        guard track.isPlaying else {
            return (SyncPolicy.inactiveInterval, SyncPolicy.inactiveTolerance)
        }
        if lyricsState.isLoading {
            return (SyncPolicy.loadingInterval, SyncPolicy.loadingTolerance)
        }
        if lyricsState.lyrics != nil {
            if track.durationMs > 0 {
                let remaining = Double(max(0, track.durationMs - progressMs)) / 1_000.0
                if remaining < SyncPolicy.endOfTrackThreshold {
                    let interval = max(
                        SyncPolicy.endOfTrackMinimum,
                        remaining + SyncPolicy.endOfTrackPadding
                    )
                    return (interval, SyncPolicy.endOfTrackTolerance)
                }
            }
            return (SyncPolicy.playingSyncedInterval, SyncPolicy.playingSyncedTolerance)
        }

        if track.durationMs > 0 {
            let remaining = Double(max(0, track.durationMs - progressMs)) / 1_000.0
            let interval = max(
                SyncPolicy.missingLyricsMinInterval,
                min(remaining + SyncPolicy.missingLyricsPadding, SyncPolicy.missingLyricsMaxInterval)
            )
            return (interval, SyncPolicy.missingLyricsTolerance)
        }
        return (SyncPolicy.missingLyricsMaxInterval, SyncPolicy.missingLyricsTolerance)
    }

    private func scheduleSyncTimer(
        interval: TimeInterval,
        tolerance: TimeInterval,
        onlyIfEarlier: Bool = false
    ) {
        let fireDate: Date
        if onlyIfEarlier, let existing = syncTimer, existing.isValid {
            let candidate = Date().addingTimeInterval(interval)
            guard candidate < existing.fireDate else { return }
            fireDate = candidate
        } else {
            fireDate = Date().addingTimeInterval(interval)
        }

        cancelSyncTimer()
        scheduledSyncIntervalValue = interval
        let generation = syncTimerGeneration
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSyncTimer(generation: generation)
            }
        }
        timer.tolerance = tolerance
        syncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleSyncTimer(generation: UInt) {
        guard !isShuttingDown, generation == syncTimerGeneration else { return }
        cancelSyncTimer()
        if let track = currentTrack {
            let progressMs = resolvedProgressMs(for: track)
            requestPlaybackRefresh(probeMode: syncProbeMode(for: track, progressMs: progressMs))
        } else {
            requestPlaybackRefresh(probeMode: .trackAndState)
        }
    }

    private func cancelSyncTimer() {
        syncTimerGeneration &+= 1
        syncTimer?.invalidate()
        syncTimer = nil
        scheduledSyncIntervalValue = nil
    }

    private func resolvedProgressMs(for track: MusicTrack) -> Int {
        if track.isPlaying,
            let playbackClock,
            playbackClock.trackID == track.identity
        {
            return playbackClock.estimatedProgressMs(at: monotonicTime())
        }
        return track.progressMs
    }

    private func updateDisplay(for track: MusicTrack, progressMs: Int, force: Bool) {
        let lookup = lyricsState.lyrics?.lookup(at: progressMs)
        let text = textFormatter.text(
            for: track,
            lyricsLine: lookup?.currentText,
            isLoadingLyrics: lyricsState.isLoading
        )
        guard force || text != statusText else { return }
        setStatusText(text)
    }

    private func setStatusText(_ text: String) {
        guard statusText != text else { return }
        statusText = text
    }

    private func setSourceText(_ text: String?) {
        guard sourceText != text else { return }
        sourceText = text
    }

    private func setNeedsAutomationPermission(_ needsPermission: Bool) {
        guard needsAutomationPermission != needsPermission else { return }
        needsAutomationPermission = needsPermission
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelLyricTimer()
        cancelSyncTimer()
        playbackClock = nil
        lastSyncUptime = nil
        refreshTask?.cancel()
        lyricsTask?.cancel()
        refreshTask = nil
        lyricsTask = nil

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        localObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver)
        distributedObservers.removeAll()
        localObservers.removeAll()
        workspaceObservers.removeAll()
    }

    func fireScheduledLyricUpdateForTesting() {
        guard lyricTimer != nil else { return }
        handleLyricTimer(generation: lyricTimerGeneration)
    }

    func fireScheduledSyncForTesting() {
        guard syncTimer != nil else { return }
        handleSyncTimer(generation: syncTimerGeneration)
    }
}
