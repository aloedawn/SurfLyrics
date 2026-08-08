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
        let script = currentTrackScript(for: player)
        return await worker.probe(player: player, source: script)
    }

    private func currentTrackScript(for player: MusicPlayer) -> String {
        """
        if application id "\(player.bundleIdentifier)" is running then
            tell application id "\(player.bundleIdentifier)"
                if player state is playing or player state is paused then
                    set sep to ASCII character 31
                    set stateStr to "playing"
                    if player state is paused then set stateStr to "paused"
                    set trackName to ""
                    set artistName to ""
                    set albumName to ""
                    set trackDuration to 0
                    set trackPosition to 0
                    try
                        set trackName to name of current track as text
                    end try
                    try
                        set artistName to artist of current track as text
                    end try
                    try
                        set albumName to album of current track as text
                    end try
                    try
                        set trackDuration to duration of current track
                    end try
                    try
                        set trackPosition to player position
                    end try
                    return stateStr & sep & trackName & sep & artistName & sep & albumName & sep & trackDuration & sep & trackPosition
                end if
            end tell
        end if
        return ""
        """
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
                let parts = str.components(separatedBy: "\u{1F}")
                guard parts.count == 6 else {
                    continuation.resume(returning: .failure("\(player.displayName) 파싱 오류: \(parts.count)개"))
                    return
                }

                let durationValue = Double(parts[4]) ?? 0
                let durationMs = player.reportsDurationInMilliseconds ? Int(durationValue) : Int(durationValue * 1000)
                let progressMs = Int((Double(parts[5]) ?? 0) * 1000)
                continuation.resume(returning: .track(MusicTrack(
                    source: player,
                    name: parts[1],
                    artist: parts[2],
                    album: parts[3],
                    durationMs: durationMs,
                    progressMs: progressMs,
                    isPlaying: parts[0] == "playing"
                )))
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
