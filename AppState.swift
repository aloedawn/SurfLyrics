import Combine
import Foundation

@MainActor
final class AppState {
    @Published private(set) var statusText = "♪ Initializing"
    @Published private(set) var sourceText: String?
    @Published private(set) var needsAutomationPermission = false

    private let musicManager: any MusicManaging
    private let textFormatter: StatusTextFormatter
    private let idleStatusText = "♪"

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var updateInterval: TimeInterval = 1.0
    private var currentTrackId = ""
    private var currentLyrics: Lyrics?
    private var isLoadingLyrics = false
    private var currentTrack: MusicTrack?

    init(
        preferences: AppPreferences = AppPreferences(),
        musicManager: (any MusicManaging)? = nil
    ) {
        self.musicManager = musicManager ?? MusicManager(preferences: preferences)
        textFormatter = StatusTextFormatter(preferences: preferences)

        observePlaybackChanges()
        observeSettingsChanges()
        requestPlaybackRefresh()
        scheduleNextUpdate()
    }

    private func observePlaybackChanges() {
        for player in MusicPlayer.allCases {
            for notificationName in player.playbackNotificationNames {
                DistributedNotificationCenter.default().addObserver(
                    forName: notificationName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.requestPlaybackRefresh()
                    }
                }
            }
        }
    }

    private func observeSettingsChanges() {
        NotificationCenter.default.addObserver(
            forName: .settingsDisplayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                self.updateDisplay(for: track, force: true)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .settingsLyricsSourcesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                self.reloadLyrics(for: track)
            }
        }
    }

    private func scheduleNextUpdate() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestPlaybackRefresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func requestPlaybackRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await musicManager.getCurrentTrack()
            guard !Task.isCancelled else { return }
            applyPlaybackResult(result)
        }
    }

    private func applyPlaybackResult(_ result: MusicPlaybackResult) {
        guard let track = result.track else {
            handleUnavailablePlayback(result.issue)
            return
        }

        needsAutomationPermission = false
        currentTrack = track
        track.isPlaying ? handlePlaying(track) : handlePaused(track)
    }

    private func handleUnavailablePlayback(_ issue: MusicPlaybackIssue?) {
        let requiresPermission = issue?.requiresAutomationPermission == true
        needsAutomationPermission = requiresPermission
        updateInterval = 3.0
        statusText = requiresPermission ? "⚠ 음악 앱 접근 권한 필요" : idleStatusText

        lyricsTask?.cancel()
        currentTrackId = ""
        currentLyrics = nil
        currentTrack = nil
        sourceText = nil
        isLoadingLyrics = false
        scheduleNextUpdate()
    }

    private func handlePlaying(_ track: MusicTrack) {
        let id = textFormatter.identifier(for: track)
        if id != currentTrackId {
            currentTrackId = id
            currentLyrics = nil
            isLoadingLyrics = false
            sourceText = textFormatter.sourceDescription(for: track, lyricsSource: nil)
            updateInterval = 1.0
            loadLyrics(for: track)
        } else {
            if sourceText == nil {
                sourceText = textFormatter.sourceDescription(for: track, lyricsSource: nil)
            }
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate()
    }

    private func handlePaused(_ track: MusicTrack) {
        if sourceText == nil {
            sourceText = textFormatter.sourceDescription(for: track, lyricsSource: nil)
        }
        updateDisplay(for: track, force: false)
        updateInterval = 3.0
        scheduleNextUpdate()
    }

    private func reloadLyrics(for track: MusicTrack) {
        lyricsTask?.cancel()
        currentLyrics = nil
        sourceText = textFormatter.sourceDescription(for: track, lyricsSource: nil)
        isLoadingLyrics = false
        currentTrackId = textFormatter.identifier(for: track)
        loadLyrics(for: track)
        scheduleNextUpdate()
    }

    private func loadLyrics(for track: MusicTrack) {
        guard !isLoadingLyrics else { return }
        isLoadingLyrics = true
        statusText = textFormatter.text(for: track, lyricsLine: nil, isLoadingLyrics: true)
        let requestedTrackId = textFormatter.identifier(for: track)

        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let (lyrics, source) = await musicManager.getLyrics(for: track)
            guard !Task.isCancelled, requestedTrackId == currentTrackId else { return }

            isLoadingLyrics = false
            currentLyrics = lyrics
            sourceText = textFormatter.sourceDescription(for: track, lyricsSource: source)
            if lyrics == nil {
                updateInterval = 5.0
                scheduleNextUpdate()
            }
            if let currentTrack {
                updateDisplay(for: currentTrack, force: false)
            }
        }
    }

    private func updateDisplay(for track: MusicTrack, force: Bool) {
        let text = displayText(for: track)
        guard force || text != statusText else { return }
        statusText = text
    }

    private func displayText(for track: MusicTrack) -> String {
        let lyricsLine = currentLyrics?.currentLine(at: track.progressMs)
        if let currentLyrics, lyricsLine != nil {
            adjustInterval(
                lyrics: currentLyrics,
                progressMs: track.progressMs,
                durationMs: track.durationMs
            )
        }
        return textFormatter.text(
            for: track,
            lyricsLine: lyricsLine,
            isLoadingLyrics: isLoadingLyrics
        )
    }

    private func adjustInterval(lyrics: Lyrics, progressMs: Int, durationMs: Int) {
        if let next = lyrics.nextLineTime(after: progressMs) {
            updateInterval = max(0.3, min(Double(next - progressMs) / 1000.0, 10.0))
        } else {
            let remaining = Double(durationMs - progressMs) / 1000.0
            updateInterval = remaining > 1.0 ? min(remaining, 10.0) : 1.0
        }
    }
}
