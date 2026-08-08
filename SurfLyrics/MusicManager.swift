import Foundation

@MainActor
protocol MusicManaging: AnyObject {
    func getCurrentTrack(preferredPlayer: MusicPlayer?) async -> MusicPlaybackResult
    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?)
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

    func getCurrentTrack(preferredPlayer: MusicPlayer?) async -> MusicPlaybackResult {
        await playbackClient.getCurrentTrack(preferredPlayer: preferredPlayer)
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        await lyricsService.getLyrics(for: track)
    }
}
