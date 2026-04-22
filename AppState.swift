import AppKit
import Foundation

// MARK: - Notification Names

extension Notification.Name {
    static let settingsDisplayModeChanged = Notification.Name("surflyrics.displayModeChanged")
    static let settingsLyricsSourcesChanged = Notification.Name("surflyrics.lyricsSourcesChanged")
}

// MARK: - AppState

@MainActor
final class AppState {
    @Published var statusText = "♪ Initializing"
    @Published var lyricsSource: String? = nil
    @Published var needsAutomationPermission = false

    private let spotifyManager = SpotifyManager()
    private var timer: Timer?
    private var updateInterval: TimeInterval = 1.0
    private var currentTrackId = ""
    private var currentLyrics: Lyrics?
    private var isLoadingLyrics = false
    private var currentTrack: SpotifyTrack?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }

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

        updateStatusBar()
        scheduleNextUpdate()
    }

    // MARK: - Timer

    private func scheduleNextUpdate() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Update Logic

    private func updateStatusBar() {
        Task {
            let (track, error) = await spotifyManager.getCurrentTrack()
            if let track {
                needsAutomationPermission = false
                track.isPlaying ? handlePlaying(track) : handlePaused()
            } else {
                let isPermissionError = error?.contains("-1743") == true
                needsAutomationPermission = isPermissionError
                if isPermissionError {
                    statusText = "⚠ Spotify 접근 권한 필요"
                    scheduleNextUpdate()
                } else {
                    statusText = "♪ Waiting"
                    stopTimer()
                }
                currentTrackId = ""
                currentLyrics = nil
                currentTrack = nil
                lyricsSource = nil
                updateInterval = 3.0
            }
        }
    }

    private func handlePlaying(_ track: SpotifyTrack) {
        let id = trackIdentifier(for: track)
        currentTrack = track
        if id != currentTrackId {
            currentTrackId = id
            currentLyrics = nil
            isLoadingLyrics = false
            updateInterval = 1.0
            loadLyrics(for: track)
        } else {
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate()
    }

    private func handlePaused() { stopTimer() }

    private func handleNotPlaying() {
        statusText = "♪ Waiting"
        currentTrackId = ""
        currentLyrics = nil
        currentTrack = nil
        lyricsSource = nil
        updateInterval = 1.0
        stopTimer()
    }

    private func reloadLyrics(for track: SpotifyTrack) {
        currentLyrics = nil
        lyricsSource = nil
        isLoadingLyrics = false
        currentTrackId = trackIdentifier(for: track)
        loadLyrics(for: track)
        scheduleNextUpdate()
    }

    private func loadLyrics(for track: SpotifyTrack) {
        guard !isLoadingLyrics else { return }
        isLoadingLyrics = true
        statusText = formatTrackInfo(track)
        let requestedTrackId = trackIdentifier(for: track)

        Task {
            let (lyrics, source) = await spotifyManager.getLyrics(for: track)
            guard requestedTrackId == self.currentTrackId else { return }
            self.isLoadingLyrics = false
            self.currentLyrics = lyrics
            self.lyricsSource = source
            if lyrics == nil { self.stopTimer() }
            if let track = self.currentTrack { self.updateDisplay(for: track, force: false) }
        }
    }

    private func updateDisplay(for track: SpotifyTrack, force: Bool) {
        let text = displayText(for: track)
        guard force || text != statusText else { return }
        statusText = text
    }

    private func displayText(for track: SpotifyTrack) -> String {
        guard !isLoadingLyrics else { return formatTrackInfo(track) }
        if let lyrics = currentLyrics, let line = lyrics.currentLine(at: track.progressMs) {
            adjustInterval(lyrics: lyrics, progressMs: track.progressMs, durationMs: track.durationMs)
            return truncate(line)
        }
        return formatTrackInfo(track)
    }

    private func adjustInterval(lyrics: Lyrics, progressMs: Int, durationMs: Int) {
        if let next = lyrics.nextLineTime(after: progressMs) {
            updateInterval = max(0.3, min(Double(next - progressMs) / 1000.0, 10.0))
        } else {
            let remaining = Double(durationMs - progressMs) / 1000.0
            updateInterval = remaining > 1.0 ? min(remaining, 10.0) : 1.0
        }
    }

    private func formatTrackInfo(_ track: SpotifyTrack) -> String {
        let mode = UserDefaults.standard.string(forKey: "displayMode") ?? "trackAndArtist"
        let text: String
        switch mode {
        case "trackOnly":  text = "♫ \(track.name)"
        case "artistOnly": text = "♫ \(track.artist)"
        default:           text = "♫ \(track.name) — \(track.artist)"
        }
        return truncate(text)
    }

    private func truncate(_ text: String) -> String {
        let limit = { let v = UserDefaults.standard.integer(forKey: "maxTextLength"); return v > 0 ? v : 60 }()
        return text.count > limit ? String(text.prefix(limit - 3)) + "..." : text
    }

    private func trackIdentifier(for track: SpotifyTrack) -> String {
        "\(track.name)|\(track.artist)|\(track.album)|\(track.durationMs)"
    }
}
