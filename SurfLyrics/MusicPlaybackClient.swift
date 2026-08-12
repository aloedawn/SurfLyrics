import AppKit
import Foundation
import os

enum TrackProbeResult: Sendable {
    case track(MusicTrack)
    case inactive
    case permissionDenied(String)
    case failure(String)
}

@MainActor
protocol MusicPlayerProbing: AnyObject {
    func runningPlayers() -> Set<MusicPlayer>
    func probe(_ player: MusicPlayer) async -> TrackProbeResult
}

@MainActor
final class MusicPlaybackClient {
    private let playerProbe: any MusicPlayerProbing
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aloedawn.surflyrics",
        category: "Playback"
    )

    init(playerProbe: (any MusicPlayerProbing)? = nil) {
        self.playerProbe = playerProbe ?? AppleScriptPlayerProbe()
    }

    func getCurrentTrack(preferredPlayer: MusicPlayer?) async -> MusicPlaybackResult {
        let runningPlayers = playerProbe.runningPlayers()
        guard !runningPlayers.isEmpty else {
            return MusicPlaybackResult(
                track: nil,
                issue: .unavailable("지원 음악 앱 미실행")
            )
        }

        let orderedPlayers = orderedPlayers(preferredPlayer: preferredPlayer)
        var pausedTrack: MusicTrack?
        var permissionErrors: [String] = []
        var failures: [String] = []

        for player in orderedPlayers where runningPlayers.contains(player) {
            let interval = signposter.beginInterval("PlayerProbe")
            let result = await playerProbe.probe(player)
            signposter.endInterval("PlayerProbe", interval)

            switch result {
            case let .track(track) where track.isPlaying:
                return MusicPlaybackResult(track: track, issue: nil)
            case let .track(track):
                pausedTrack = pausedTrack ?? track
            case .inactive:
                break
            case let .permissionDenied(message):
                permissionErrors.append(message)
            case let .failure(message):
                failures.append(message)
            }
        }

        if let paused = pausedTrack {
            return MusicPlaybackResult(track: paused, issue: nil)
        }

        if !permissionErrors.isEmpty {
            return MusicPlaybackResult(
                track: nil,
                issue: .permissionDenied(permissionErrors.joined(separator: "\n"))
            )
        }

        return MusicPlaybackResult(
            track: nil,
            issue: .unavailable(failures.first ?? "빈 응답 (지원 음악 앱 미실행 또는 미재생)")
        )
    }

    private func orderedPlayers(preferredPlayer: MusicPlayer?) -> [MusicPlayer] {
        guard let preferredPlayer else { return MusicPlayer.allCases }
        return [preferredPlayer] + MusicPlayer.allCases.filter { $0 != preferredPlayer }
    }
}

@MainActor
final class AppleScriptPlayerProbe: MusicPlayerProbing {
    private let worker = AppleScriptProbeWorker()

    func runningPlayers() -> Set<MusicPlayer> {
        Set(MusicPlayer.allCases.filter { player in
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: player.bundleIdentifier
            ).isEmpty
        })
    }

    func probe(_ player: MusicPlayer) async -> TrackProbeResult {
        let script = Self.currentTrackScript(for: player)
        return await worker.probe(player: player, source: script)
    }

    nonisolated static func currentTrackScript(for player: MusicPlayer) -> String {
        let spotifyIdentityScript: String
        switch player {
        case .spotify:
            spotifyIdentityScript = """
                    try
                        set trackID to id of currentItem as text
                    end try
                    try
                        set trackURL to spotify url of currentItem as text
                    end try
                """
        case .appleMusic:
            spotifyIdentityScript = ""
        }

        return """
        if application id "\(player.bundleIdentifier)" is running then
            tell application id "\(player.bundleIdentifier)"
                if player state is playing or player state is paused then
                    set sep to character id 31
                    set stateStr to "playing"
                    if player state is paused then set stateStr to "paused"
                    try
                        set currentItem to current track
                    on error
                        return ""
                    end try
                    set trackName to ""
                    set artistName to ""
                    set albumName to ""
                    set trackDuration to 0
                    set trackPosition to 0
                    set trackID to ""
                    set trackURL to ""
                    try
                        set trackName to name of currentItem as text
                    end try
                    try
                        set artistName to artist of currentItem as text
                    end try
                    try
                        set albumName to album of currentItem as text
                    end try
                    try
                        set trackDuration to duration of currentItem
                    end try
                    try
                        set trackPosition to player position
                    end try
        \(spotifyIdentityScript)
                    return stateStr & sep & trackName & sep & artistName & sep & albumName & sep & trackDuration & sep & trackPosition & sep & trackID & sep & trackURL
                end if
            end tell
        end if
        return ""
        """
    }
}

struct AppleScriptTrackResponseParser {
    struct ParseError: Error, Equatable {
        let actualFieldCount: Int
    }

    static let separator = "\u{1F}"
    static let expectedFieldCount = 8

    private enum Field: Int {
        case state
        case name
        case artist
        case album
        case duration
        case position
        case sourceTrackID
        case sourceTrackURL
    }

    static func parse(_ response: String, player: MusicPlayer) throws -> MusicTrack {
        let parts = response.components(separatedBy: separator)
        guard parts.count == expectedFieldCount else {
            throw ParseError(actualFieldCount: parts.count)
        }

        let durationValue = Double(parts[Field.duration.rawValue]) ?? 0
        let durationMs = player.reportsDurationInMilliseconds
            ? Int(durationValue)
            : Int(durationValue * 1000)
        let progressMs = Int((Double(parts[Field.position.rawValue]) ?? 0) * 1000)
        let spotifyIdentity = player == .spotify
            ? spotifyPlaybackIdentity(
                rawID: parts[Field.sourceTrackID.rawValue],
                rawURL: parts[Field.sourceTrackURL.rawValue]
            )
            : SpotifyPlaybackIdentity(trackID: nil, itemKind: .track)

        return MusicTrack(
            source: player,
            sourceTrackID: spotifyIdentity.trackID,
            itemKind: spotifyIdentity.itemKind,
            name: parts[Field.name.rawValue],
            artist: parts[Field.artist.rawValue],
            album: parts[Field.album.rawValue],
            durationMs: durationMs,
            progressMs: progressMs,
            isPlaying: parts[Field.state.rawValue] == "playing"
        )
    }

    private struct SpotifyPlaybackIdentity {
        let trackID: String?
        let itemKind: PlaybackItemKind
    }

    private enum SpotifyResourceIdentity: Equatable {
        case track(String)
        case localTrack(String)
        case episode
        case advertisement
        case unsupported
        case bare(String)
        case nonTrack
        case empty
        case malformed
    }

    private static func spotifyPlaybackIdentity(
        rawID: String,
        rawURL: String
    ) -> SpotifyPlaybackIdentity {
        let idIdentity = spotifyResourceIdentity(from: rawID)
        let urlIdentity = spotifyResourceIdentity(from: rawURL)

        switch (idIdentity, urlIdentity) {
        case let (.track(id), .track(urlID)):
            return id == urlID
                ? SpotifyPlaybackIdentity(trackID: id, itemKind: .track)
                : SpotifyPlaybackIdentity(trackID: nil, itemKind: .unsupported)
        case let (.track(id), .bare(bareID)), let (.bare(bareID), .track(id)):
            return id == bareID
                ? SpotifyPlaybackIdentity(trackID: id, itemKind: .track)
                : SpotifyPlaybackIdentity(trackID: nil, itemKind: .unsupported)
        case let (.track(id), .empty), let (.empty, .track(id)):
            return SpotifyPlaybackIdentity(trackID: id, itemKind: .track)
        case let (.localTrack(id), .localTrack(urlID)):
            return SpotifyPlaybackIdentity(
                trackID: nil,
                itemKind: id == urlID ? .localTrack : .unsupported
            )
        case (.localTrack, .empty), (.empty, .localTrack),
            (.localTrack, .bare), (.bare, .localTrack):
            return SpotifyPlaybackIdentity(trackID: nil, itemKind: .localTrack)
        case (.episode, .episode), (.episode, .empty), (.empty, .episode),
            (.episode, .bare), (.bare, .episode):
            return SpotifyPlaybackIdentity(trackID: nil, itemKind: .episode)
        case (.advertisement, .advertisement), (.advertisement, .empty),
            (.empty, .advertisement), (.advertisement, .bare), (.bare, .advertisement):
            return SpotifyPlaybackIdentity(trackID: nil, itemKind: .advertisement)
        case (.unsupported, _), (_, .unsupported), (.nonTrack, _), (_, .nonTrack),
            (.malformed, .track), (.track, .malformed), (.malformed, .localTrack),
            (.localTrack, .malformed), (.malformed, .episode), (.episode, .malformed),
            (.malformed, .advertisement), (.advertisement, .malformed),
            (.track, .localTrack), (.localTrack, .track), (.track, .episode),
            (.episode, .track), (.track, .advertisement), (.advertisement, .track),
            (.localTrack, .episode), (.episode, .localTrack),
            (.localTrack, .advertisement), (.advertisement, .localTrack),
            (.episode, .advertisement), (.advertisement, .episode):
            return SpotifyPlaybackIdentity(trackID: nil, itemKind: .unsupported)
        case (.bare, .bare), (.bare, .empty), (.empty, .bare), (.empty, .empty),
            (.malformed, .malformed), (.malformed, .bare), (.bare, .malformed),
            (.malformed, .empty), (.empty, .malformed):
            return SpotifyPlaybackIdentity(trackID: nil, itemKind: .unknown)
        }
    }

    private static func spotifyResourceIdentity(from candidate: String) -> SpotifyResourceIdentity {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }

        let uriParts = value.split(separator: ":", omittingEmptySubsequences: false)
        if uriParts.count >= 2, uriParts[0].lowercased() == "spotify" {
            switch uriParts[1].lowercased() {
            case "track":
                guard uriParts.count == 3,
                    let id = validatedSpotifyID(String(uriParts[2]))
                else {
                    return .malformed
                }
                return .track(id)
            case "local":
                guard uriParts.count == 6,
                    Int(uriParts[5]) != nil
                else {
                    return .malformed
                }
                return .localTrack(value)
            case "episode":
                return .episode
            case "ad":
                return .advertisement
            default:
                return .unsupported
            }
        }

        if let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(),
            ["spotify.com", "www.spotify.com", "open.spotify.com", "play.spotify.com"].contains(host)
        {
            var pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            if pathParts.first?.lowercased().hasPrefix("intl-") == true {
                pathParts.removeFirst()
            }
            if pathParts.count == 2, pathParts[0].lowercased() == "track" {
                let encodedIdentifier = String(pathParts[1])
                guard let id = validatedSpotifyID(
                    encodedIdentifier.removingPercentEncoding ?? encodedIdentifier
                ) else {
                    return .malformed
                }
                return .track(id)
            }
            if pathParts.count == 2, pathParts[0].lowercased() == "episode" {
                return .episode
            }
            return .nonTrack
        }

        if let id = validatedSpotifyID(value) {
            return .bare(id)
        }
        return .malformed
    }

    private static func validatedSpotifyID(_ candidate: String) -> String? {
        guard !candidate.isEmpty,
            candidate.unicodeScalars.allSatisfy({ scalar in
                scalar.value < 128 && CharacterSet.alphanumerics.contains(scalar)
            })
        else {
            return nil
        }
        return candidate
    }
}

private final class AppleScriptProbeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aloedawn.surflyrics.playback-probe", qos: .utility)
    private var scripts: [MusicPlayer: NSAppleScript] = [:]

    func probe(player: MusicPlayer, source: String) async -> TrackProbeResult {
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let appleScript = compiledScript(for: player, source: source) else {
                    continuation.resume(returning: .failure("\(player.displayName) 스크립트 생성 실패"))
                    return
                }

                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? -1
                    let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                    let message = "\(player.displayName) AS err \(code): \(msg)"
                    if code == -1743 {
                        continuation.resume(returning: .permissionDenied(message))
                    } else {
                        continuation.resume(returning: .failure(message))
                    }
                    return
                }
                guard let str = result.stringValue, !str.isEmpty else {
                    continuation.resume(returning: .inactive)
                    return
                }
                let track: MusicTrack
                do {
                    track = try AppleScriptTrackResponseParser.parse(str, player: player)
                } catch let parseError as AppleScriptTrackResponseParser.ParseError {
                    continuation.resume(returning: .failure(
                        "\(player.displayName) 파싱 오류: \(parseError.actualFieldCount)개"
                    ))
                    return
                } catch {
                    continuation.resume(returning: .failure("\(player.displayName) 파싱 오류"))
                    return
                }
                continuation.resume(returning: .track(track))
            }
        }
    }

    private func compiledScript(for player: MusicPlayer, source: String) -> NSAppleScript? {
        if let script = scripts[player] {
            return script
        }

        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return nil }
        scripts[player] = script
        return script
    }
}
