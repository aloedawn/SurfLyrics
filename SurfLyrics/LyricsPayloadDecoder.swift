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
        let interval = signposter.beginInterval("MusixmatchDecode")
        defer { signposter.endInterval("MusixmatchDecode", interval) }

        // Musixmatch reports API errors inside HTTP 200 responses, sometimes with body: [].
        for call in [nil, "matcher.track.get", "track.subtitles.get"] as [String?] {
            if let status = musixmatchStatusCode(data, call: call), status != 200 {
                return status == 404 ? .notFound : .transientFailure
            }
        }

        guard let payload = try? JSONDecoder().decode(MusixmatchPayload.self, from: data),
            let calls = payload.message?.body?.macroCalls
        else {
            return .transientFailure
        }

        guard let matchedTrack = calls.matcherTrack?.message?.body?.track else {
            return .notFound
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
            guard matchedID == expectedID else { return .notFound }
        } else {
            guard matcher.isLikelyMatch(candidate, for: expectedTrack) else {
                return .notFound
            }
        }

        guard let lrc = calls.subtitles?.message?.body?.subtitleList?.first?.subtitle?.body,
            !lrc.isEmpty
        else {
            return .notFound
        }
        return lyricsResult(from: lrc)
    }

    func decodeMusixmatchToken(_ data: Data) -> String? {
        if let status = musixmatchStatusCode(data), status != 200 { return nil }
        let token = try? JSONDecoder().decode(MusixmatchTokenPayload.self, from: data)
            .message?.body?.userToken
        return token?.isEmpty == false ? token : nil
    }

    func musixmatchRequiresTokenRefresh(_ data: Data) -> Bool {
        ([nil, "matcher.track.get", "track.subtitles.get"] as [String?]).contains {
            musixmatchStatusCode(data, call: $0) == 401
        }
    }

    private func musixmatchStatusCode(_ data: Data, call: String? = nil) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var message = root["message"] as? [String: Any]
        else { return nil }
        if let call {
            guard let body = message["body"] as? [String: Any],
                let calls = body["macro_calls"] as? [String: Any],
                let result = calls[call] as? [String: Any],
                let nestedMessage = result["message"] as? [String: Any]
            else { return nil }
            message = nestedMessage
        }
        return (message["header"] as? [String: Any])?["status_code"] as? Int
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

private struct MusixmatchTokenPayload: Decodable {
    let message: Message?

    struct Message: Decodable {
        let body: Body?
    }

    struct Body: Decodable {
        let userToken: String?

        enum CodingKeys: String, CodingKey {
            case userToken = "user_token"
        }
    }
}

private struct MusixmatchPayload: Decodable {
    let message: Message?

    struct Message: Decodable {
        let body: Body?
    }

    struct Body: Decodable {
        let macroCalls: MacroCalls?

        enum CodingKeys: String, CodingKey {
            case macroCalls = "macro_calls"
        }
    }

    struct MacroCalls: Decodable {
        let matcherTrack: MatcherCall?
        let subtitles: SubtitleCall?

        enum CodingKeys: String, CodingKey {
            case matcherTrack = "matcher.track.get"
            case subtitles = "track.subtitles.get"
        }
    }

    struct MatcherCall: Decodable {
        let message: MatcherMessage?
    }

    struct MatcherMessage: Decodable {
        let body: MatcherBody?
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
        let message: SubtitleMessage?
    }

    struct SubtitleMessage: Decodable {
        let body: SubtitleBody?
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
