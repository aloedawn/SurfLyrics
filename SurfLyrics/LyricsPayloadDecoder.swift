import Foundation
import os

actor LyricsPayloadDecoder {
    private let signposter = OSSignposter(
        subsystem: "com.aloedawn.surflyrics",
        category: "LyricsDecoding"
    )
    private let matcher = LyricsCandidateMatcher.default

    func decodeLRCLIB(_ data: Data) -> LyricsFetchResult {
        let interval = signposter.beginInterval("LRCLIBDecode")
        defer { signposter.endInterval("LRCLIBDecode", interval) }

        guard let payload = try? JSONDecoder().decode(LRCLIBPayload.self, from: data) else {
            return .transientFailure
        }
        guard let lrc = payload.syncedLyrics, !lrc.isEmpty else {
            return .notFound
        }
        return lyricsResult(from: lrc)
    }

    func decodeLRCLIBSearch(
        _ data: Data,
        expectedTrack: MusicTrack
    ) -> LyricsFetchResult {
        let interval = signposter.beginInterval("LRCLIBSearchDecode")
        defer { signposter.endInterval("LRCLIBSearchDecode", interval) }

        guard let payloads = try? JSONDecoder().decode([LRCLIBPayload].self, from: data) else {
            return .transientFailure
        }

        let viableRecords = payloads.compactMap { payload -> (LRCLIBPayload, LyricsCandidate)? in
            guard let syncedLyrics = payload.syncedLyrics, !syncedLyrics.isEmpty else {
                return nil
            }
            return (
                payload,
                LyricsCandidate(
                    trackName: payload.trackName ?? "",
                    artistName: payload.artistName ?? "",
                    albumName: payload.albumName,
                    durationMs: milliseconds(fromSeconds: payload.duration?.value)
                )
            )
        }
        let candidates = viableRecords.map { $0.1 }
        guard let matchIndex = matcher.bestMatchIndex(for: expectedTrack, among: candidates) else {
            return .notFound
        }
        guard let lrc = viableRecords[matchIndex].0.syncedLyrics else {
            return .notFound
        }
        return lyricsResult(from: lrc)
    }

    func decodeMusixmatch(_ data: Data, expectedTrack: MusicTrack) -> LyricsFetchResult {
        evaluateMusixmatch(data, expectedTrack: expectedTrack).result
    }

    func evaluateMusixmatch(
        _ data: Data,
        expectedTrack: MusicTrack
    ) -> (requiresTokenRefresh: Bool, result: LyricsFetchResult) {
        let interval = signposter.beginInterval("MusixmatchDecode")
        defer { signposter.endInterval("MusixmatchDecode", interval) }

        guard let payload = try? JSONDecoder().decode(MusixmatchPayload.self, from: data)
        else {
            return (false, .transientFailure)
        }
        let requiresTokenRefresh = payload.statusCodes.contains(401)
        // Musixmatch reports API errors inside HTTP 200 responses, sometimes with body: [].
        if let status = payload.statusCodes.first(where: { $0 != 200 }) {
            return (requiresTokenRefresh, status == 404 ? .notFound : .transientFailure)
        }
        guard let calls = payload.message?.body?.macroCalls else {
            return (requiresTokenRefresh, .transientFailure)
        }

        guard let matchedTrack = calls.matcherTrack?.message?.body?.track else {
            return (requiresTokenRefresh, .notFound)
        }
        let candidate = LyricsCandidate(
            trackName: matchedTrack.name ?? "",
            artistName: matchedTrack.artist ?? "",
            albumName: matchedTrack.album,
            durationMs: milliseconds(fromSeconds: matchedTrack.length?.value)
        )
        if expectedTrack.source == .spotify, expectedTrack.itemKind == .track,
            let expectedID = expectedTrack.sourceTrackID, !expectedID.isEmpty,
            let matchedID = matchedTrack.spotifyID, !matchedID.isEmpty
        {
            // A provider-confirmed Spotify ID remains stable across translated metadata.
            guard matchedID == expectedID else { return (requiresTokenRefresh, .notFound) }
        } else {
            guard matcher.isLikelyMatch(candidate, for: expectedTrack) else {
                return (requiresTokenRefresh, .notFound)
            }
        }

        guard let lrc = calls.subtitles?.message?.body?.subtitleList?.first?.subtitle?.body,
            !lrc.isEmpty
        else {
            return (requiresTokenRefresh, .notFound)
        }
        return (requiresTokenRefresh, lyricsResult(from: lrc))
    }

    func decodeMusixmatchToken(_ data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(MusixmatchPayload.self, from: data)
        else { return nil }
        if let status = payload.message?.header?.statusCode, status != 200 { return nil }
        let token = payload.message?.body?.userToken
        return token?.isEmpty == false ? token : nil
    }

    func musixmatchRequiresTokenRefresh(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(MusixmatchPayload.self, from: data))?
            .statusCodes.contains(401) == true
    }

    private func lyricsResult(from lrc: String) -> LyricsFetchResult {
        let lines = LRCParser.parse(lrc)
        guard lines.contains(where: { !$0.text.isEmpty }) else { return .notFound }
        return .found(Lyrics(lines: lines))
    }

    private func milliseconds(fromSeconds seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let milliseconds = (seconds * 1_000).rounded()
        let maximumTrackDurationMs = 24.0 * 60 * 60 * 1_000
        guard milliseconds.isFinite, milliseconds <= maximumTrackDurationMs else { return nil }
        return Int(milliseconds)
    }

}

private struct LRCLIBPayload: Decodable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: FlexibleDouble?
    let syncedLyrics: String?
}

private struct MusixmatchPayload: Decodable {
    let message: MusixmatchMessage<Body>?

    var statusCodes: [Int] {
        [
            message?.header?.statusCode,
            message?.body?.macroCalls?.matcherTrack?.message?.header?.statusCode,
            message?.body?.macroCalls?.subtitles?.message?.header?.statusCode,
        ].compactMap { $0 }
    }

    struct Body: Decodable {
        let macroCalls: MacroCalls?
        let userToken: String?

        enum CodingKeys: String, CodingKey {
            case macroCalls = "macro_calls"
            case userToken = "user_token"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            macroCalls = try? container.decode(MacroCalls.self, forKey: .macroCalls)
            userToken = try? container.decode(String.self, forKey: .userToken)
        }
    }

    struct MacroCalls: Decodable {
        let matcherTrack: MatcherCall?
        let subtitles: SubtitleCall?

        enum CodingKeys: String, CodingKey {
            case matcherTrack = "matcher.track.get"
            case subtitles = "track.subtitles.get"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matcherTrack = try? container.decode(MatcherCall.self, forKey: .matcherTrack)
            subtitles = try? container.decode(SubtitleCall.self, forKey: .subtitles)
        }
    }

    struct MatcherCall: Decodable {
        let message: MusixmatchMessage<MatcherBody>?
    }

    struct MatcherBody: Decodable {
        let track: Track?
    }

    struct Track: Decodable {
        let spotifyID: String?
        let name: String?
        let artist: String?
        let album: String?
        let length: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case spotifyID = "track_spotify_id"
            case name = "track_name"
            case artist = "artist_name"
            case album = "album_name"
            case length = "track_length"
        }
    }

    struct SubtitleCall: Decodable {
        let message: MusixmatchMessage<SubtitleBody>?
    }

    struct SubtitleBody: Decodable {
        let subtitleList: [SubtitleItem]?

        enum CodingKeys: String, CodingKey {
            case subtitleList = "subtitle_list"
        }
    }

    struct SubtitleItem: Decodable {
        let subtitle: Subtitle?
    }

    struct Subtitle: Decodable {
        let body: String?

        enum CodingKeys: String, CodingKey {
            case body = "subtitle_body"
        }
    }
}

private struct MusixmatchMessage<Body: Decodable>: Decodable {
    let header: Header?
    let body: Body?

    struct Header: Decodable {
        let statusCode: Int?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
        }
    }

    enum CodingKeys: String, CodingKey {
        case header, body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try? container.decode(Header.self, forKey: .header)
        body = try? container.decode(Body.self, forKey: .body)
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded: Double?
        if let double = try? container.decode(Double.self) {
            decoded = double
        } else if let string = try? container.decode(String.self) {
            decoded = Double(string)
        } else {
            decoded = nil
        }
        value = decoded?.isFinite == true ? decoded : nil
    }
}
