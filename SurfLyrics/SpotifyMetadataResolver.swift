import Foundation
import os

@MainActor
final class SpotifyMetadataResolver {
    private struct CacheEntry {
        let track: MusicTrack
        let expiresAt: Date
    }

    private struct EmbedPayload: Decodable {
        let props: Props
    }

    private struct Props: Decodable {
        let pageProps: PageProps
    }

    private struct PageProps: Decodable {
        let state: StatePayload
    }

    private struct StatePayload: Decodable {
        let data: DataPayload
    }

    private struct DataPayload: Decodable {
        let entity: Entity
    }

    private struct Entity: Decodable {
        let type: String
        let id: String
        let name: String
        let artists: [Artist]
        let duration: Int
        let album: Album?
    }

    private struct Artist: Decodable {
        let name: String
    }

    private struct Album: Decodable {
        let name: String
    }

    private let urlSession: URLSession
    private let logger = Logger(
        subsystem: "com.aloedawn.surflyrics",
        category: "SpotifyMetadata"
    )
    private var cache: [String: CacheEntry] = [:]

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func resolve(_ track: MusicTrack) async -> MusicTrack? {
        guard track.source == .spotify,
            track.itemKind == .track,
            let trackID = track.sourceTrackID,
            let url = URL(string: "https://open.spotify.com/embed/track/\(trackID)")
        else {
            return nil
        }
        if let cached = cache[trackID], cached.expiresAt > Date() {
            return Self.replacingPlaybackState(in: cached.track, with: track)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .useProtocolCachePolicy

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                let payloadData = Self.nextPayload(in: data),
                let entity = try? JSONDecoder().decode(EmbedPayload.self, from: payloadData)
                    .props.pageProps.state.data.entity,
                entity.type == "track",
                entity.id == trackID,
                !entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !entity.artists.isEmpty
            else {
                return nil
            }

            let resolvedTrack = MusicTrack(
                source: track.source,
                sourceTrackID: trackID,
                itemKind: .track,
                name: entity.name,
                artist: entity.artists.map(\.name).joined(separator: ", "),
                album: entity.album?.name ?? track.album,
                durationMs: entity.duration > 0 ? entity.duration : track.durationMs,
                progressMs: track.progressMs,
                isPlaying: track.isPlaying
            )
            cache[trackID] = CacheEntry(
                track: resolvedTrack,
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            )
            return resolvedTrack
        } catch {
            if !Task.isCancelled {
                logger.error("Spotify metadata request failed")
            }
            return nil
        }
    }

    private nonisolated static func replacingPlaybackState(
        in metadata: MusicTrack,
        with playbackTrack: MusicTrack
    ) -> MusicTrack {
        MusicTrack(
            source: playbackTrack.source,
            sourceTrackID: playbackTrack.sourceTrackID,
            itemKind: playbackTrack.itemKind,
            name: metadata.name,
            artist: metadata.artist,
            album: metadata.album,
            durationMs: metadata.durationMs,
            progressMs: playbackTrack.progressMs,
            isPlaying: playbackTrack.isPlaying
        )
    }

    nonisolated static func nextPayload(in data: Data) -> Data? {
        guard let html = String(data: data, encoding: .utf8),
            let markerRange = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
            let endRange = html.range(
                of: "</script>",
                range: markerRange.upperBound..<html.endIndex
            )
        else {
            return nil
        }
        return String(html[markerRange.upperBound..<endRange.lowerBound]).data(using: .utf8)
    }
}
