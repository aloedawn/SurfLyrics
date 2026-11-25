import Foundation

@MainActor
protocol MusicManaging: AnyObject {
    func getCurrentTrack(preferredPlayer: MusicPlayer?, probeMode: PlaybackProbeMode) async -> MusicPlaybackResult
    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?)
    func invalidateLyricsCache(for track: MusicTrack)
    func invalidateSpotifyEndpoint()
}

extension MusicManaging {
    func getCurrentTrack(preferredPlayer: MusicPlayer?) async -> MusicPlaybackResult {
        await getCurrentTrack(preferredPlayer: preferredPlayer, probeMode: .fullMetadata)
    }

    func invalidateLyricsCache(for track: MusicTrack) {}
    func invalidateSpotifyEndpoint() {}
}

@MainActor
final class MusicManager: MusicManaging {
    private let playbackClient: MusicPlaybackClient
    private let lyricsService: LyricsService

    init(
        preferences: AppPreferences = AppPreferences(),
        playbackClient: MusicPlaybackClient = MusicPlaybackClient(),
        lyricsService: LyricsService? = nil
    ) {
        self.playbackClient = playbackClient
        self.lyricsService = lyricsService ?? LyricsService(preferences: preferences)
    }

    func getCurrentTrack(
        preferredPlayer: MusicPlayer?,
        probeMode: PlaybackProbeMode
    ) async -> MusicPlaybackResult {
        await playbackClient.getCurrentTrack(
            preferredPlayer: preferredPlayer,
            probeMode: probeMode
        )
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        await lyricsService.getLyrics(for: track)
    }

    func invalidateLyricsCache(for track: MusicTrack) {
        lyricsService.invalidateCache(for: track)
    }

    func invalidateSpotifyEndpoint() {
        Task { await lyricsService.invalidateSpotifyEndpoint() }
    }
}
