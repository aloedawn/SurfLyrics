import AppKit
import Foundation

@MainActor
final class MusicPlaybackClient {
    func getCurrentTrack() async -> MusicPlaybackResult {
        var results: [TrackProbeResult] = []
        for player in MusicPlayer.allCases {
            results.append(await getCurrentTrack(from: player))
        }

        let tracks = results.compactMap { result -> MusicTrack? in
            if case let .track(track) = result { return track }
            return nil
        }
        if let playing = tracks.first(where: \.isPlaying) {
            return MusicPlaybackResult(track: playing, issue: nil)
        }
        if let paused = tracks.first {
            return MusicPlaybackResult(track: paused, issue: nil)
        }

        let permissionErrors = results.compactMap { result -> String? in
            if case let .permissionDenied(message) = result { return message }
            return nil
        }
        if !permissionErrors.isEmpty {
            return MusicPlaybackResult(
                track: nil,
                issue: .permissionDenied(permissionErrors.joined(separator: "\n"))
            )
        }

        let failures = results.compactMap { result -> String? in
            if case let .failure(message) = result { return message }
            return nil
        }
        return MusicPlaybackResult(
            track: nil,
            issue: .unavailable(failures.first ?? "빈 응답 (지원 음악 앱 미실행 또는 미재생)")
        )
    }

    private enum TrackProbeResult: Sendable {
        case track(MusicTrack)
        case inactive
        case permissionDenied(String)
        case failure(String)
    }

    private func getCurrentTrack(from player: MusicPlayer) async -> TrackProbeResult {
        let script = currentTrackScript(for: player)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
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
