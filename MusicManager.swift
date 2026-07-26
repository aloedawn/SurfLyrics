import Foundation

@MainActor
protocol MusicManaging: AnyObject {
    func getCurrentTrack() async -> MusicPlaybackResult
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

    func getCurrentTrack() async -> MusicPlaybackResult {
        await playbackClient.getCurrentTrack()
    }

    func getLyrics(for track: MusicTrack) async -> (Lyrics?, String?) {
        await lyricsService.getLyrics(for: track)
    }
}
