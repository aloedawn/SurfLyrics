import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    private struct ScheduledLyricsDisplay {
        let trackID: TrackIdentity
        let progressMs: Int
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

    private enum RefreshPolicy {
        static let initial: TimeInterval = 1
        static let inactive: TimeInterval = 3
        static let missingLyrics: TimeInterval = 5

        static func interval(nextLineTimeMs: Int?, progressMs: Int, durationMs: Int) -> TimeInterval {
            if let next = nextLineTimeMs {
                return max(0.3, min(Double(next - progressMs) / 1000.0, 10.0))
            }
            let remaining = Double(durationMs - progressMs) / 1000.0
            return remaining > 1.0 ? min(remaining, 10.0) : initial
        }
    }

    @Published private(set) var statusText = ""
    @Published private(set) var sourceText: String?
    @Published private(set) var needsAutomationPermission = false

    private let musicManager: any MusicManaging
    private let textFormatter: StatusTextFormatter
    private let idleStatusText = ""

    private var timer: Timer?
    private var scheduledInterval: TimeInterval?
    private var scheduledLyricsDisplay: ScheduledLyricsDisplay?
    private var scheduledUpdateGeneration: UInt = 0
    private var refreshTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var updateInterval = RefreshPolicy.initial
    private var currentTrackId: TrackIdentity?
    private var lyricsState: LyricsLoadState = .idle
    private var currentTrack: MusicTrack?
    private var preferredPlayer: MusicPlayer?
    private var pendingPreferredPlayer: MusicPlayer?
    private var isRefreshInFlight = false
    private var needsTrailingRefresh = false
    private var isShuttingDown = false

    var scheduledRefreshInterval: TimeInterval { scheduledInterval ?? updateInterval }
    var scheduledRefreshTolerance: TimeInterval? { timer?.tolerance }
    var scheduledRefreshDate: Date? { timer?.fireDate }

    init(
        preferences: AppPreferences = AppPreferences(),
        musicManager: (any MusicManaging)? = nil
    ) {
        self.musicManager = musicManager ?? MusicManager(preferences: preferences)
        textFormatter = StatusTextFormatter(preferences: preferences)

        observePlaybackChanges()
        observeSettingsChanges()
        requestPlaybackRefresh()
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
                        self?.requestPlaybackRefresh(preferredPlayer: player)
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
                self.updateDisplay(for: track, force: true)
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
                self.reloadLyrics(for: track)
            }
        }
        localObservers.append(lyricsObserver)
    }

    private func scheduleNextUpdate(
        displaying track: MusicTrack? = nil,
        onlyIfEarlier: Bool = false
    ) {
        let fireDate: Date
        if onlyIfEarlier {
            guard let timer, timer.isValid, let scheduledInterval else { return }
            // Keep the original playback snapshot as the scheduling anchor.
            let candidateFireDate = timer.fireDate.addingTimeInterval(
                updateInterval - scheduledInterval
            )
            guard candidateFireDate < timer.fireDate else { return }
            fireDate = candidateFireDate
        } else {
            fireDate = Date().addingTimeInterval(updateInterval)
        }

        cancelScheduledUpdate()
        scheduledInterval = updateInterval
        if let track {
            scheduledLyricsDisplay = ScheduledLyricsDisplay(
                trackID: track.identity,
                progressMs: track.progressMs + Int((updateInterval * 1_000).rounded())
            )
        }
        let generation = scheduledUpdateGeneration
        let display = scheduledLyricsDisplay
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScheduledUpdate(generation: generation, display: display)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleScheduledUpdate(
        generation: UInt,
        display: ScheduledLyricsDisplay?
    ) {
        guard generation == scheduledUpdateGeneration else { return }
        cancelScheduledUpdate()
        if let display {
            displayScheduledLyrics(display)
        }
        requestPlaybackRefresh()
    }

    private func displayScheduledLyrics(_ display: ScheduledLyricsDisplay) {
        guard currentTrackId == display.trackID,
            let track = currentTrack,
            track.isPlaying,
            !lyricsState.isLoading,
            let lyrics = lyricsState.lyrics
        else {
            return
        }

        let lyricLine = lyrics.lookup(at: display.progressMs).currentText
        setStatusText(textFormatter.text(
            for: track,
            lyricsLine: lyricLine,
            isLoadingLyrics: false
        ))
    }

    private func cancelScheduledUpdate() {
        scheduledUpdateGeneration &+= 1
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
        scheduledLyricsDisplay = nil
    }

    func requestPlaybackRefresh(preferredPlayer: MusicPlayer? = nil) {
        guard !isShuttingDown else { return }
        if let preferredPlayer {
            cancelScheduledUpdate()
            pendingPreferredPlayer = preferredPlayer
        }

        guard !isRefreshInFlight else {
            needsTrailingRefresh = true
            return
        }

        isRefreshInFlight = true
        let musicManager = musicManager
        let requestedPlayer = pendingPreferredPlayer ?? self.preferredPlayer
        pendingPreferredPlayer = nil
        refreshTask = Task { [weak self] in
            let result = await musicManager.getCurrentTrack(preferredPlayer: requestedPlayer)
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
            requestPlaybackRefresh()
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
        let requiresPermission = issue?.requiresAutomationPermission == true
        setNeedsAutomationPermission(requiresPermission)
        updateInterval = RefreshPolicy.inactive
        setStatusText(requiresPermission ? "⚠ 음악 앱 접근 권한 필요" : idleStatusText)

        resetLyrics(for: nil)
        currentTrack = nil
        scheduleNextUpdate()
    }

    private func handlePlaying(_ track: MusicTrack) {
        let id = track.identity
        if id != currentTrackId {
            resetLyrics(for: track)
            updateInterval = RefreshPolicy.initial
            if track.itemKind.supportsLyricsLookup {
                loadLyrics(for: track)
            } else {
                lyricsState = .finished(nil, nil)
                updateDisplay(for: track, force: false)
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
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate(displaying: track)
    }

    private func handlePaused(_ track: MusicTrack) {
        let id = track.identity
        if id != currentTrackId {
            resetLyrics(for: track)
        }
        if track.itemKind.supportsLyricsLookup, lyricsState.lyrics == nil,
            (!lyricsState.hasFinished || lyricsState.queryIdentity != track.lyricsQueryIdentity)
        {
            loadLyrics(for: track)
        }
        if sourceText == nil {
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
        }
        updateDisplay(for: track, force: false)
        updateInterval = RefreshPolicy.inactive
        scheduleNextUpdate()
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
        if track.itemKind.supportsLyricsLookup {
            loadLyrics(for: track)
        } else {
            lyricsState = .finished(nil, nil)
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate(displaying: track.isPlaying ? track : nil)
    }

    private func loadLyrics(for track: MusicTrack) {
        let requestedQueryIdentity = track.lyricsQueryIdentity
        if lyricsState.isLoading, lyricsState.queryIdentity == requestedQueryIdentity {
            return
        }
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
            if let currentTrack {
                updateDisplay(for: currentTrack, force: false)
            }
            if lyrics == nil {
                updateInterval = RefreshPolicy.missingLyrics
                scheduleNextUpdate()
            } else if let currentTrack, timer != nil, currentTrack.isPlaying {
                scheduleNextUpdate(displaying: currentTrack, onlyIfEarlier: true)
            }
        }
    }

    private func updateDisplay(for track: MusicTrack, force: Bool) {
        let text = displayText(for: track)
        guard force || text != statusText else { return }
        setStatusText(text)
    }

    private func displayText(for track: MusicTrack) -> String {
        let lookup = lyricsState.lyrics?.lookup(at: track.progressMs)
        if track.isPlaying, let lookup, lookup.currentText != nil {
            updateInterval = RefreshPolicy.interval(
                nextLineTimeMs: lookup.nextLineTimeMs,
                progressMs: track.progressMs,
                durationMs: track.durationMs
            )
        }
        return textFormatter.text(
            for: track,
            lyricsLine: lookup?.currentText,
            isLoadingLyrics: lyricsState.isLoading
        )
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
        cancelScheduledUpdate()
        refreshTask?.cancel()
        lyricsTask?.cancel()
        refreshTask = nil
        lyricsTask = nil

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        localObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.removeAll()
        localObservers.removeAll()
    }

    func fireScheduledRefreshForTesting() {
        guard timer != nil else { return }
        handleScheduledUpdate(
            generation: scheduledUpdateGeneration,
            display: scheduledLyricsDisplay
        )
    }
}
