import XCTest
@testable import SurfLyrics

final class ModelTests: XCTestCase {
    func testLRCParserSupportsCommonTimestampFormatsAndSortsLines() {
        let lines = LRCParser.parse(
            """
            [01:02]Third
            [00:02.5]Second
            [00:01.025]First
            [00:61.00]Invalid
            """
        )

        XCTAssertEqual(
            lines,
            [
                LyricsLine(timeMs: 1_025, text: "First"),
                LyricsLine(timeMs: 2_500, text: "Second"),
                LyricsLine(timeMs: 62_000, text: "Third"),
            ]
        )
    }

    func testLyricsLookupFindsCurrentAndNextLineWithBoundaries() {
        let lyrics = Lyrics(lines: [
            LyricsLine(timeMs: 1_000, text: "One"),
            LyricsLine(timeMs: 2_000, text: "Two"),
            LyricsLine(timeMs: 3_000, text: "Three"),
        ])

        XCTAssertEqual(
            lyrics.lookup(at: 500),
            LyricsLookup(currentText: nil, nextLineTimeMs: 1_000)
        )
        XCTAssertEqual(
            lyrics.lookup(at: 2_000),
            LyricsLookup(currentText: "Two", nextLineTimeMs: 3_000)
        )
        XCTAssertEqual(
            lyrics.lookup(at: 4_000),
            LyricsLookup(currentText: "Three", nextLineTimeMs: nil)
        )
    }

    func testLRCBlankTimestampsClearLyricsDuringInstrumentalGaps() {
        let lyrics = Lyrics(lines: LRCParser.parse("[00:01.00]Voice\n[00:02.00]\n[00:03]  \n[00:04.00]Next"))
        XCTAssertEqual(lyrics.lines.count, 4)
        XCTAssertEqual(lyrics.lookup(at: 2_500), LyricsLookup(currentText: "", nextLineTimeMs: 3_000))
        XCTAssertEqual(lyrics.lookup(at: 4_000).currentText, "Next")
    }

    @MainActor
    func testInstrumentalMarkersUseTheSameEmptyTitleAsTheIdleIcon() {
        let defaults = makeDefaults()
        let formatter = StatusTextFormatter(preferences: AppPreferences(defaults: defaults))
        let track = MusicTrack(source: .spotify, name: "Song", artist: "Artist", album: "Album",
            durationMs: 180_000, progressMs: 0, isPlaying: true)
        for marker in ["", " \n", "♪", "♫ ♬", "🎵", "🎶", "♪\u{FE0F}"] {
            XCTAssertEqual(formatter.text(for: track, lyricsLine: marker, isLoadingLyrics: false), "")
        }
        for lyric in ["♪ Sing with me", "Music ♫", "[Instrumental love]"] {
            XCTAssertEqual(formatter.text(for: track, lyricsLine: lyric, isLoadingLyrics: false), lyric)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
