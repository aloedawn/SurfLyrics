import XCTest
@testable import SurfLyrics

@MainActor
final class LyricsCandidateMatcherTests: XCTestCase {
    private let matcher = LyricsCandidateMatcher()

    func testNormalizesUnicodePunctuationWidthAndFeatureCredits() {
        let track = makeTrack(
            name: "HÉLLO！ (feat. Guest)",
            artist: "Beyoncé feat. JAY-Z",
            album: "Ａlbum"
        )
        let candidate = LyricsCandidate(
            trackName: "hello",
            artistName: "beyonce",
            albumName: "album",
            durationMs: 180_500
        )

        XCTAssertTrue(matcher.isLikelyMatch(candidate, for: track))
    }

    func testFeatureArtistNamedLiveIsNotTreatedAsEdition() {
        let track = makeTrack(name: "Song (feat. Live)", artist: "Artist")
        let candidate = LyricsCandidate(
            trackName: "Song feat. Live",
            artistName: "Artist",
            albumName: "Album",
            durationMs: 180_000
        )

        XCTAssertTrue(matcher.isLikelyMatch(candidate, for: track))
    }

    func testPunctuationDifferenceDoesNotSplitEquivalentArtistName() {
        let track = makeTrack(name: "Thunderstruck", artist: "AC/DC")
        let candidate = LyricsCandidate(
            trackName: "Thunderstruck",
            artistName: "ACDC",
            albumName: "Album",
            durationMs: 180_000
        )

        XCTAssertTrue(matcher.isLikelyMatch(candidate, for: track))
    }

    func testDoesNotTreatSubstringAsTitleMatch() {
        let track = makeTrack(name: "Home")
        let candidate = LyricsCandidate(
            trackName: "Homecoming",
            artistName: track.artist,
            albumName: track.album,
            durationMs: track.durationMs
        )

        XCTAssertFalse(matcher.isLikelyMatch(candidate, for: track))
    }

    func testDoesNotAcceptSingleTokenTitleAsPartOfLongerTitle() {
        let track = makeTrack(name: "Song")
        let candidate = LyricsCandidate(
            trackName: "Another Song",
            artistName: track.artist,
            albumName: track.album,
            durationMs: track.durationMs
        )

        XCTAssertFalse(matcher.isLikelyMatch(candidate, for: track))
    }

    func testRejectsCandidateOutsideDurationHardGate() {
        let track = makeTrack(name: "Song", durationMs: 180_000)
        let candidate = LyricsCandidate(
            trackName: track.name,
            artistName: track.artist,
            albumName: track.album,
            durationMs: 190_000
        )

        XCTAssertFalse(matcher.isLikelyMatch(candidate, for: track))
    }

    func testAllowsExactTextWhenCandidateDurationIsUnavailable() {
        let track = makeTrack(name: "Song")
        let candidate = LyricsCandidate(
            trackName: track.name,
            artistName: track.artist,
            albumName: nil,
            durationMs: nil
        )

        XCTAssertTrue(matcher.isLikelyMatch(candidate, for: track))
    }

    func testRejectsEditionConflicts() {
        let conflictingTitles = [
            "Song (Live)",
            "Song - Remix",
            "Song (Acoustic)",
            "Song - Instrumental",
            "Song (Karaoke)",
            "Song - Sped-Up",
            "Song (Slowed + Reverb)",
            "Song Live",
            "Song Remix",
            "Song Acoustic",
        ]
        let track = makeTrack(name: "Song")

        for title in conflictingTitles {
            let candidate = LyricsCandidate(
                trackName: title,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs
            )
            XCTAssertFalse(
                matcher.isLikelyMatch(candidate, for: track),
                "Expected edition conflict for \(title)"
            )
        }
    }

    func testAcceptsMatchingLiveEditionsWithoutTreatingTitleWordAsEdition() {
        let liveTrack = makeTrack(name: "Song (Live at Seoul)")
        let liveCandidate = LyricsCandidate(
            trackName: "Song - Live",
            artistName: liveTrack.artist,
            albumName: liveTrack.album,
            durationMs: liveTrack.durationMs
        )
        XCTAssertTrue(matcher.isLikelyMatch(liveCandidate, for: liveTrack))

        let lexicalTrack = makeTrack(name: "I Want to Live")
        let lexicalCandidate = LyricsCandidate(
            trackName: "I Want to Live",
            artistName: lexicalTrack.artist,
            albumName: lexicalTrack.album,
            durationMs: lexicalTrack.durationMs
        )
        XCTAssertTrue(matcher.isLikelyMatch(lexicalCandidate, for: lexicalTrack))
    }

    func testBestMatchReturnsClearWinner() {
        let track = makeTrack(name: "The Song")
        let candidates = [
            LyricsCandidate(
                trackName: "Another Song",
                artistName: "Another Artist",
                albumName: "Another Album",
                durationMs: track.durationMs
            ),
            LyricsCandidate(
                trackName: "The Song",
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs
            ),
            LyricsCandidate(
                trackName: "The Song",
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs + 5_000
            ),
        ]

        XCTAssertEqual(matcher.bestMatchIndex(for: track, among: candidates), 1)
        XCTAssertEqual(matcher.bestMatch(for: track, among: candidates), candidates[1])
    }

    func testBestMatchTreatsNormalizedDuplicateRowsAsEquivalent() {
        let track = makeTrack(name: "Song")
        let candidates = [
            LyricsCandidate(
                trackName: track.name,
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs
            ),
            LyricsCandidate(
                trackName: "Song!",
                artistName: "Artist",
                albumName: "Album",
                durationMs: track.durationMs
            ),
        ]

        XCTAssertEqual(matcher.bestMatchIndex(for: track, among: candidates), 0)
        XCTAssertEqual(matcher.bestMatch(for: track, among: candidates), candidates[0])
    }

    func testBestMatchIgnoresEquivalentDuplicateRows() {
        let track = makeTrack(name: "Song", artist: "Artist", album: "Album")
        let duplicate = LyricsCandidate(
            trackName: "Song",
            artistName: "Artist",
            albumName: "Album",
            durationMs: 180_000
        )

        XCTAssertEqual(
            matcher.bestMatchIndex(for: track, among: [duplicate, duplicate]),
            0
        )
    }

    func testBestMatchGroupsDuplicateRowsWithOptionalAlbumAndCloseDuration() {
        let track = makeTrack(name: "Song", artist: "Artist", album: "Album")
        let candidates = [
            LyricsCandidate(
                trackName: "Song",
                artistName: "Artist",
                albumName: "Album",
                durationMs: 180_000
            ),
            LyricsCandidate(
                trackName: "Song!",
                artistName: "Artist",
                albumName: nil,
                durationMs: 180_100
            ),
        ]

        XCTAssertEqual(matcher.bestMatchIndex(for: track, among: candidates), 0)
    }

    func testBestMatchRejectsDistinctCandidatesWithinAmbiguityMargin() {
        let track = makeTrack(name: "Song", artist: "Artist", album: "Album")
        let candidates = [
            LyricsCandidate(
                trackName: "Song",
                artistName: "Artist",
                albumName: "Album",
                durationMs: 180_000
            ),
            LyricsCandidate(
                trackName: "Song",
                artistName: "Artist",
                albumName: "Album Deluxe",
                durationMs: 180_000
            ),
        ]

        XCTAssertNil(matcher.bestMatchIndex(for: track, among: candidates))
    }

    func testRejectsDifferentArtistEvenWhenAlbumAndDurationMatch() {
        let track = makeTrack(name: "Intro", artist: "Expected", album: "Greatest Hits")
        let candidate = LyricsCandidate(
            trackName: "Intro",
            artistName: "Someone Else",
            albumName: "Greatest Hits",
            durationMs: track.durationMs
        )

        XCTAssertFalse(matcher.isLikelyMatch(candidate, for: track))
    }

    func testMatchesRemasterDecorationUsingArtistAndDuration() {
        let track = makeTrack(name: "Song - 2011 Remaster", artist: "Artist")
        let candidate = LyricsCandidate(
            trackName: "Song",
            artistName: "Artist",
            durationMs: 180_000
        )

        XCTAssertTrue(matcher.isLikelyMatch(candidate, for: track))
    }

    func testBestMatchReturnsNilWhenNoCandidateIsLikely() {
        let track = makeTrack(name: "Song")
        let candidates = [
            LyricsCandidate(
                trackName: "Different",
                artistName: track.artist,
                albumName: track.album,
                durationMs: track.durationMs
            ),
        ]

        XCTAssertNil(matcher.bestMatchIndex(for: track, among: candidates))
    }

    private func makeTrack(
        name: String,
        artist: String = "Artist",
        album: String = "Album",
        durationMs: Int = 180_000
    ) -> MusicTrack {
        MusicTrack(
            source: .spotify,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs,
            progressMs: 0,
            isPlaying: true
        )
    }
}
