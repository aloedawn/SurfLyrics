import Foundation

@MainActor
final class LRCLIBClient {
    private let urlSession: URLSession

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func fetch(artist: String, trackName: String, album: String?) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
        ]
        if let album {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10.0

        guard let (data, response) = try? await urlSession.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let syncedLyrics = json["syncedLyrics"] as? String,
            !syncedLyrics.isEmpty
        else {
            return nil
        }

        let lines = LRCParser.parse(syncedLyrics)
        return lines.isEmpty ? nil : Lyrics(lines: lines)
    }
}
