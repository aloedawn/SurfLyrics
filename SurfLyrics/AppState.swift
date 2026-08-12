import Combine
import Foundation

@MainActor
final class AppState {
    private struct ScheduledLyricsDisplay {
        let trackID: TrackIdentity
        let progressMs: Int
    }

    @Published private(set) var statusText = "♪ Initializing"
    @Published private(set) var sourceText: String?
    @Published private(set) var needsAutomationPermission = false

    private let musicManager: any MusicManaging
    private let textFormatter: StatusTextFormatter
    private let idleStatusText = "♪"

    private var timer: Timer?
    private var scheduledInterval: TimeInterval?
    private var scheduledLyricsDisplay: ScheduledLyricsDisplay?
    private var scheduledUpdateGeneration: UInt = 0
    private var refreshTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var updateInterval: TimeInterval = 1.0
    private var currentTrackId: TrackIdentity?
    private var currentLyrics: Lyrics?
    private var isLoadingLyrics = false
    private var hasFinishedLyricsLookup = false
    private var currentTrack: MusicTrack?
    private var preferredPlayer: MusicPlayer?
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
            !isLoadingLyrics,
            let lyrics = currentLyrics
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
            self.preferredPlayer = preferredPlayer
        }

        guard !isRefreshInFlight else {
            needsTrailingRefresh = true
            return
        }

        isRefreshInFlight = true
        let musicManager = musicManager
        let requestedPlayer = self.preferredPlayer
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
        updateInterval = 3.0
        setStatusText(requiresPermission ? "⚠ 음악 앱 접근 권한 필요" : idleStatusText)

        lyricsTask?.cancel()
        currentTrackId = nil
        currentLyrics = nil
        currentTrack = nil
        setSourceText(nil)
        isLoadingLyrics = false
        hasFinishedLyricsLookup = false
        scheduleNextUpdate()
    }

    private func handlePlaying(_ track: MusicTrack) {
        let id = track.identity
        if id != currentTrackId {
            currentTrackId = id
            currentLyrics = nil
            isLoadingLyrics = false
            hasFinishedLyricsLookup = false
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
            updateInterval = 1.0
            loadLyrics(for: track)
        } else {
            if !hasFinishedLyricsLookup, !isLoadingLyrics {
                loadLyrics(for: track)
            }
            if sourceText == nil {
                setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
            }
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate(displaying: track)
    }

    private func handlePaused(_ track: MusicTrack) {
        let id = track.identity
        if id != currentTrackId {
            lyricsTask?.cancel()
            currentTrackId = id
            currentLyrics = nil
            isLoadingLyrics = false
            hasFinishedLyricsLookup = false
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
        }
        if sourceText == nil {
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
        }
        updateDisplay(for: track, force: false)
        updateInterval = 3.0
        scheduleNextUpdate()
    }

    private func reloadLyrics(for track: MusicTrack) {
        lyricsTask?.cancel()
        currentLyrics = nil
        setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: nil))
        isLoadingLyrics = false
        hasFinishedLyricsLookup = false
        currentTrackId = track.identity
        loadLyrics(for: track)
        scheduleNextUpdate(displaying: track.isPlaying ? track : nil)
    }

    private func loadLyrics(for track: MusicTrack) {
        guard !isLoadingLyrics else { return }
        isLoadingLyrics = true
        setStatusText(textFormatter.text(for: track, lyricsLine: nil, isLoadingLyrics: true))
        let requestedTrackId = track.identity

        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let (lyrics, source) = await musicManager.getLyrics(for: track)
            guard !Task.isCancelled, requestedTrackId == currentTrackId else { return }

            isLoadingLyrics = false
            hasFinishedLyricsLookup = true
            currentLyrics = lyrics
            setSourceText(textFormatter.sourceDescription(for: track, lyricsSource: source))
            if let currentTrack {
                updateDisplay(for: currentTrack, force: false)
            }
            if lyrics == nil {
                updateInterval = 5.0
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
        let lookup = currentLyrics?.lookup(at: track.progressMs)
        if let lookup, lookup.currentText != nil {
            adjustInterval(
                nextLineTimeMs: lookup.nextLineTimeMs,
                progressMs: track.progressMs,
                durationMs: track.durationMs
            )
        }
        return textFormatter.text(
            for: track,
            lyricsLine: lookup?.currentText,
            isLoadingLyrics: isLoadingLyrics
        )
    }

    private func adjustInterval(nextLineTimeMs: Int?, progressMs: Int, durationMs: Int) {
        if let next = nextLineTimeMs {
            updateInterval = max(0.3, min(Double(next - progressMs) / 1000.0, 10.0))
        } else {
            let remaining = Double(durationMs - progressMs) / 1000.0
            updateInterval = remaining > 1.0 ? min(remaining, 10.0) : 1.0
        }
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
