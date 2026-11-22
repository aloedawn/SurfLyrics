import AppKit
import CoreServices
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
    func probe(_ player: MusicPlayer, forceFullMetadata: Bool) async -> TrackProbeResult
}

extension MusicPlayerProbing {
    func probe(_ player: MusicPlayer) async -> TrackProbeResult {
        await probe(player, forceFullMetadata: true)
    }
}

@MainActor
final class MusicPlaybackClient {
    private let playerProbe: any MusicPlayerProbing
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aloedawn.surflyrics",
        category: "Playback"
    )

    init(playerProbe: (any MusicPlayerProbing)? = nil) {
        self.playerProbe = playerProbe ?? AppleEventPlayerProbe()
    }

    func getCurrentTrack(
        preferredPlayer: MusicPlayer?,
        forceFullMetadata: Bool = true
    ) async -> MusicPlaybackResult {
        let runningPlayers = playerProbe.runningPlayers()
        guard !runningPlayers.isEmpty else {
            return MusicPlaybackResult(
                track: nil,
                issue: .noRunningPlayers
            )
        }

        let orderedPlayers = orderedPlayers(preferredPlayer: preferredPlayer)
        var pausedTrack: MusicTrack?
        var permissionErrors: [String] = []
        var failures: [String] = []

        for player in orderedPlayers where runningPlayers.contains(player) {
            let interval = signposter.beginInterval("PlayerProbe")
            let result = await playerProbe.probe(player, forceFullMetadata: forceFullMetadata)
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
final class AppleEventPlayerProbe: MusicPlayerProbing {
    private let worker = AppleEventProbeWorker()

    func runningPlayers() -> Set<MusicPlayer> {
        Set(MusicPlayer.allCases.filter { player in
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: player.bundleIdentifier
            ).isEmpty
        })
    }

    func probe(_ player: MusicPlayer, forceFullMetadata: Bool) async -> TrackProbeResult {
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: player.bundleIdentifier
        ).first?.processIdentifier else {
            await worker.invalidateCache(for: player)
            return .inactive
        }
        return await worker.probe(player: player, pid: pid, forceFullMetadata: forceFullMetadata)
    }
}

struct SpotifyTrackIdentityParser {
    struct Identity: Equatable, Sendable {
        let trackID: String?
        let itemKind: PlaybackItemKind
    }

    private enum ResourceIdentity: Equatable {
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

    static func parse(rawID: String, rawURL: String) -> Identity {
        let idIdentity = resourceIdentity(from: rawID)
        let urlIdentity = resourceIdentity(from: rawURL)

        switch (idIdentity, urlIdentity) {
        case let (.track(id), .track(urlID)):
            return id == urlID
                ? Identity(trackID: id, itemKind: .track)
                : Identity(trackID: nil, itemKind: .unsupported)
        case let (.track(id), .bare(bareID)), let (.bare(bareID), .track(id)):
            return id == bareID
                ? Identity(trackID: id, itemKind: .track)
                : Identity(trackID: nil, itemKind: .unsupported)
        case let (.track(id), .empty), let (.empty, .track(id)):
            return Identity(trackID: id, itemKind: .track)
        case let (.localTrack(id), .localTrack(urlID)):
            return Identity(
                trackID: nil,
                itemKind: id == urlID ? .localTrack : .unsupported
            )
        case (.localTrack, .empty), (.empty, .localTrack),
            (.localTrack, .bare), (.bare, .localTrack):
            return Identity(trackID: nil, itemKind: .localTrack)
        case (.episode, .episode), (.episode, .empty), (.empty, .episode),
            (.episode, .bare), (.bare, .episode):
            return Identity(trackID: nil, itemKind: .episode)
        case (.advertisement, .advertisement), (.advertisement, .empty),
            (.empty, .advertisement), (.advertisement, .bare), (.bare, .advertisement):
            return Identity(trackID: nil, itemKind: .advertisement)
        case (.unsupported, _), (_, .unsupported), (.nonTrack, _), (_, .nonTrack),
            (.malformed, .track), (.track, .malformed), (.malformed, .localTrack),
            (.localTrack, .malformed), (.malformed, .episode), (.episode, .malformed),
            (.malformed, .advertisement), (.advertisement, .malformed),
            (.track, .localTrack), (.localTrack, .track), (.track, .episode),
            (.episode, .track), (.track, .advertisement), (.advertisement, .track),
            (.localTrack, .episode), (.episode, .localTrack),
            (.localTrack, .advertisement), (.advertisement, .localTrack),
            (.episode, .advertisement), (.advertisement, .episode):
            return Identity(trackID: nil, itemKind: .unsupported)
        case (.bare, .bare), (.bare, .empty), (.empty, .bare), (.empty, .empty),
            (.malformed, .malformed), (.malformed, .bare), (.bare, .malformed),
            (.malformed, .empty), (.empty, .malformed):
            return Identity(trackID: nil, itemKind: .unknown)
        }
    }

    private static func resourceIdentity(from candidate: String) -> ResourceIdentity {
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

protocol AppleEventQuerySending: Sendable {
    func getApplicationProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError>
    func getTrackProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError>
    func checkCurrentTrackExists(pid: pid_t) -> Result<Void, AppleEventError>
}

final class NativeAppleEventQuerySender: AppleEventQuerySending, @unchecked Sendable {
    private let currentTrackSpecifier: NSAppleEventDescriptor?
    private let appSpecifiers: [OSType: NSAppleEventDescriptor]
    private let trackSpecifiers: [OSType: NSAppleEventDescriptor]

    init() {
        let track = AppleEventClient.currentTrackSpecifier()
        currentTrackSpecifier = track

        var appSpecs: [OSType: NSAppleEventDescriptor] = [:]
        for property in [
            AppleEventClient.playerStateProperty,
            AppleEventClient.playerPositionProperty,
        ] {
            if let spec = AppleEventClient.propertySpecifier(property: property) {
                appSpecs[property] = spec
            }
        }
        appSpecifiers = appSpecs

        var trackSpecs: [OSType: NSAppleEventDescriptor] = [:]
        if let track {
            for property in [
                AppleEventClient.trackNameProperty,
                AppleEventClient.trackArtistProperty,
                AppleEventClient.trackAlbumProperty,
                AppleEventClient.trackDurationProperty,
                AppleEventClient.trackIDProperty,
                AppleEventClient.spotifyURLProperty,
                AppleEventClient.persistentIDProperty,
            ] {
                if let spec = AppleEventClient.propertySpecifier(container: track, property: property) {
                    trackSpecs[property] = spec
                }
            }
        }
        trackSpecifiers = trackSpecs
    }

    func getApplicationProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        guard let specifier = appSpecifiers[property]
            ?? AppleEventClient.propertySpecifier(property: property)
        else {
            return .failure(.osError(OSStatus(errAEParamMissed), "Specifier error"))
        }
        return AppleEventClient.getData(of: specifier, pid: pid)
    }

    func getTrackProperty(
        _ property: OSType,
        pid: pid_t
    ) -> Result<NSAppleEventDescriptor, AppleEventError> {
        guard let specifier = trackSpecifiers[property]
            ?? currentTrackSpecifier.flatMap({
                AppleEventClient.propertySpecifier(container: $0, property: property)
            })
        else {
            return .failure(.osError(OSStatus(errAEParamMissed), "Specifier error"))
        }
        return AppleEventClient.getData(of: specifier, pid: pid)
    }

    func checkCurrentTrackExists(pid: pid_t) -> Result<Void, AppleEventError> {
        guard let specifier = currentTrackSpecifier else {
            return .failure(.osError(OSStatus(errAEParamMissed), "Specifier error"))
        }
        return AppleEventClient.getData(of: specifier, pid: pid).map { _ in () }
    }
}

final class AppleEventProbeWorker: @unchecked Sendable {
    private struct CachedTrack {
        let pid: pid_t
        let rawTrackKey: String
        let track: MusicTrack
    }

    private let queue = DispatchQueue(label: "com.aloedawn.surflyrics.playback-probe", qos: .utility)
    private let sender: any AppleEventQuerySending
    private var cache: [MusicPlayer: CachedTrack] = [:]

    init(sender: any AppleEventQuerySending = NativeAppleEventQuerySender()) {
        self.sender = sender
    }

    func invalidateCache(for player: MusicPlayer) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cache[player] = nil
                continuation.resume()
            }
        }
    }

    func probe(
        player: MusicPlayer,
        pid: pid_t,
        forceFullMetadata: Bool = true
    ) async -> TrackProbeResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(
                    returning: probeSync(
                        player: player,
                        pid: pid,
                        forceFullMetadata: forceFullMetadata
                    )
                )
            }
        }
    }

    private func probeSync(
        player: MusicPlayer,
        pid: pid_t,
        forceFullMetadata: Bool
    ) -> TrackProbeResult {
        let isPlaying: Bool
        switch sender.getApplicationProperty(AppleEventClient.playerStateProperty, pid: pid) {
        case let .success(descriptor):
            guard let stateCode = AppleEventClient.enumCode(from: descriptor) else {
                cache[player] = nil
                return .inactive
            }
            switch stateCode {
            case AppleEventClient.playingEnum,
                AppleEventClient.fastForwardingEnum,
                AppleEventClient.rewindingEnum:
                isPlaying = true
            case AppleEventClient.pausedEnum:
                isPlaying = false
            default:
                cache[player] = nil
                return .inactive
            }
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let progressMs: Int
        switch optionalDoubleProperty(
            AppleEventClient.playerPositionProperty,
            onTrack: false,
            pid: pid
        ) {
        case let .success(positionSeconds):
            progressMs = max(0, Int((positionSeconds ?? 0) * 1_000))
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let trackKeyProperty = player == .spotify
            ? AppleEventClient.trackIDProperty
            : AppleEventClient.persistentIDProperty
        let rawTrackKey: String
        switch optionalStringProperty(trackKeyProperty, onTrack: true, pid: pid) {
        case let .success(value):
            if value == nil {
                switch sender.checkCurrentTrackExists(pid: pid) {
                case .success:
                    rawTrackKey = ""
                case let .failure(error):
                    return mapTerminalError(error, player: player)
                }
            } else {
                rawTrackKey = value ?? ""
            }
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        if !forceFullMetadata,
            let cached = cache[player],
            cached.pid == pid,
            !rawTrackKey.isEmpty,
            cached.rawTrackKey == rawTrackKey,
            !cached.track.name.isEmpty,
            !cached.track.artist.isEmpty,
            cached.track.itemKind != .unknown
        {
            let refreshed = MusicTrack(
                source: cached.track.source,
                sourceTrackID: cached.track.sourceTrackID,
                itemKind: cached.track.itemKind,
                name: cached.track.name,
                artist: cached.track.artist,
                album: cached.track.album,
                durationMs: cached.track.durationMs,
                progressMs: progressMs,
                isPlaying: isPlaying
            )
            return .track(refreshed)
        }

        let name: String
        switch optionalStringProperty(AppleEventClient.trackNameProperty, onTrack: true, pid: pid) {
        case let .success(value):
            name = value ?? ""
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let artist: String
        switch optionalStringProperty(AppleEventClient.trackArtistProperty, onTrack: true, pid: pid) {
        case let .success(value):
            artist = value ?? ""
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let album: String
        switch optionalStringProperty(AppleEventClient.trackAlbumProperty, onTrack: true, pid: pid) {
        case let .success(value):
            album = value ?? ""
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let durationValue: Double
        switch optionalDoubleProperty(AppleEventClient.trackDurationProperty, onTrack: true, pid: pid) {
        case let .success(value):
            durationValue = value ?? 0
        case let .failure(error):
            return mapTerminalError(error, player: player)
        }

        let durationMs = player.reportsDurationInMilliseconds
            ? max(0, Int(durationValue))
            : max(0, Int(durationValue * 1_000))

        let identity: SpotifyTrackIdentityParser.Identity
        if player == .spotify {
            let rawURL: String
            switch optionalStringProperty(AppleEventClient.spotifyURLProperty, onTrack: true, pid: pid) {
            case let .success(value):
                rawURL = value ?? ""
            case let .failure(error):
                return mapTerminalError(error, player: player)
            }
            identity = SpotifyTrackIdentityParser.parse(rawID: rawTrackKey, rawURL: rawURL)
        } else {
            identity = SpotifyTrackIdentityParser.Identity(trackID: nil, itemKind: .track)
        }

        let track = MusicTrack(
            source: player,
            sourceTrackID: identity.trackID,
            itemKind: identity.itemKind,
            name: name,
            artist: artist,
            album: album,
            durationMs: durationMs,
            progressMs: progressMs,
            isPlaying: isPlaying
        )
        if !rawTrackKey.isEmpty {
            cache[player] = CachedTrack(pid: pid, rawTrackKey: rawTrackKey, track: track)
        } else {
            cache[player] = nil
        }
        return .track(track)
    }

    private func optionalStringProperty(
        _ property: OSType,
        onTrack: Bool,
        pid: pid_t
    ) -> Result<String?, AppleEventError> {
        let response = onTrack
            ? sender.getTrackProperty(property, pid: pid)
            : sender.getApplicationProperty(property, pid: pid)
        switch response {
        case let .success(descriptor):
            return .success(descriptor.stringValue ?? "")
        case let .failure(.targetUnavailable(code)) where code == OSStatus(errAENoSuchObject):
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func optionalDoubleProperty(
        _ property: OSType,
        onTrack: Bool,
        pid: pid_t
    ) -> Result<Double?, AppleEventError> {
        let response = onTrack
            ? sender.getTrackProperty(property, pid: pid)
            : sender.getApplicationProperty(property, pid: pid)
        switch response {
        case let .success(descriptor):
            return .success(AppleEventClient.doubleValue(from: descriptor))
        case let .failure(.targetUnavailable(code)) where code == OSStatus(errAENoSuchObject):
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func mapTerminalError(_ error: AppleEventError, player: MusicPlayer) -> TrackProbeResult {
        cache[player] = nil
        switch error {
        case let .permissionDenied(code):
            return .permissionDenied("\(player.displayName) AE err \(code): 접근 권한 필요")
        case .targetUnavailable:
            return .inactive
        case let .osError(code, message):
            return .failure("\(player.displayName) AE err \(code): \(message)")
        }
    }
}
