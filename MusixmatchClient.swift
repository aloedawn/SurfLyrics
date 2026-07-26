import Foundation

@MainActor
final class MusixmatchClient {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private let preferences: AppPreferences
    private let urlSession: URLSession
    private var token: String?
    private var tokenExpiry: Date?

    init(preferences: AppPreferences, urlSession: URLSession) {
        self.preferences = preferences
        self.urlSession = urlSession
        token = preferences.musixmatchToken
        tokenExpiry = preferences.musixmatchTokenExpiry
    }

    func fetch(for track: MusicTrack) async -> Lyrics? {
        guard let token = await validToken() else { return nil }

        var components = URLComponents(
            string: "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get"
        )!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynced"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "q_track", value: track.name),
            URLQueryItem(name: "q_artist", value: track.artist),
            URLQueryItem(name: "q_album", value: track.album),
            URLQueryItem(name: "q_duration", value: String(track.durationMs / 1000)),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            return nil
        }

        return parseResponse(data, for: track)
    }

    private func validToken() async -> String? {
        token = preferences.musixmatchToken
        tokenExpiry = preferences.musixmatchTokenExpiry

        if let token, let tokenExpiry, Date() < tokenExpiry {
            return token
        }

        guard let url = URL(
            string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0"
        ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let token = body["user_token"] as? String
        else {
            return nil
        }

        let expiry = Date().addingTimeInterval(3600)
        self.token = token
        tokenExpiry = expiry
        preferences.storeMusixmatchToken(token, expiresAt: expiry)
        return token
    }

    private func parseResponse(_ data: Data, for track: MusicTrack) -> Lyrics? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let macroCalls = body["macro_calls"] as? [String: Any]
        else {
            return nil
        }

        if let matchedTrack = matchedTrack(from: macroCalls),
            !isLikelySameTrack(matchedTrack, expected: track)
        {
            return nil
        }

        guard let subtitles = macroCalls["track.subtitles.get"] as? [String: Any],
            let subtitleMessage = subtitles["message"] as? [String: Any],
            let subtitleBody = subtitleMessage["body"] as? [String: Any],
            let list = subtitleBody["subtitle_list"] as? [[String: Any]],
            let first = list.first,
            let subtitle = first["subtitle"] as? [String: Any],
            let lrc = subtitle["subtitle_body"] as? String,
            !lrc.isEmpty
        else {
            return nil
        }

        let lines = LRCParser.parse(lrc)
        return lines.isEmpty ? nil : Lyrics(lines: lines)
    }

    private func matchedTrack(from macroCalls: [String: Any]) -> [String: Any]? {
        guard let matcher = macroCalls["matcher.track.get"] as? [String: Any],
            let message = matcher["message"] as? [String: Any],
            let body = message["body"] as? [String: Any]
        else {
            return nil
        }
        return body["track"] as? [String: Any]
    }

    private func isLikelySameTrack(_ track: [String: Any], expected: MusicTrack) -> Bool {
        let matchedTrack = track["track_name"] as? String ?? ""
        let matchedArtist = track["artist_name"] as? String ?? ""
        return textMatches(matchedTrack, expected.name)
            && textMatches(matchedArtist, expected.artist)
            && durationMatches(track["track_length"], expectedMs: expected.durationMs)
    }

    private func durationMatches(_ value: Any?, expectedMs: Int) -> Bool {
        guard expectedMs > 0, let actualSeconds = numericValue(value), actualSeconds > 0 else {
            return true
        }
        let expectedSeconds = Double(expectedMs) / 1000.0
        let tolerance = max(4.0, expectedSeconds * 0.04)
        return abs(actualSeconds - expectedSeconds) <= tolerance
    }

    private func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            value
        case let value as Int:
            Double(value)
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    private func textMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedForMatch(lhs)
        let right = normalizedForMatch(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func normalizedForMatch(_ text: String) -> String {
        let folded = text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                !word.isEmpty && !["feat", "ft", "featuring"].contains(word)
            }
        return words.joined(separator: " ")
    }
}
