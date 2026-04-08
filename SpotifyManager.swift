import AppKit
import Foundation

class SpotifyManager {
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var musixmatchToken: String?
    private var musixmatchTokenExpiry: Date?

    init() {
        let stored = UserDefaults.standard.string(forKey: "musixmatch.token") ?? ""
        let expTs = UserDefaults.standard.double(forKey: "musixmatch.tokenExpiry")
        if !stored.isEmpty, expTs > 0 {
            musixmatchToken = stored
            musixmatchTokenExpiry = Date(timeIntervalSince1970: expTs)
        }
    }

    // MARK: - Current Track

    func getCurrentTrack() async -> (track: SpotifyTrack?, error: String?) {
        let script = """
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    if player state is playing or player state is paused then
                        set stateStr to "playing"
                        if player state is paused then set stateStr to "paused"
                        set trackName to name of current track
                        set artistName to artist of current track
                        set albumName to album of current track
                        set trackDuration to duration of current track
                        set trackPosition to player position
                        return stateStr & "|" & trackName & "|" & artistName & "|" & albumName & "|" & trackDuration & "|" & trackPosition
                    end if
                end tell
            end if
            return ""
            """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(returning: (nil, "스크립트 생성 실패"))
                    return
                }
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? -1
                    let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                    continuation.resume(returning: (nil, "AS err \(code): \(msg)"))
                    return
                }
                guard let str = result.stringValue, !str.isEmpty else {
                    continuation.resume(returning: (nil, "빈 응답 (Spotify 미실행 또는 미재생)"))
                    return
                }
                let parts = str.components(separatedBy: "|")
                guard parts.count == 6 else {
                    continuation.resume(returning: (nil, "파싱 오류: \(parts.count)개"))
                    return
                }
                continuation.resume(returning: (SpotifyTrack(
                    name: parts[1],
                    artist: parts[2],
                    album: parts[3],
                    durationMs: Int(Double(parts[4]) ?? 0),
                    progressMs: Int((Double(parts[5]) ?? 0) * 1000),
                    isPlaying: parts[0] == "playing"
                ), nil))
            }
        }
    }

    // MARK: - Lyrics

    func getLyrics(for track: SpotifyTrack) async -> (Lyrics?, String?) {
        if let lyrics = await fetchFromLRCLIB(artist: track.artist, trackName: track.name, album: track.album) {
            return (lyrics, "LRCLIB")
        }
        if let lyrics = await fetchFromLRCLIB(artist: track.artist, trackName: track.name, album: nil) {
            return (lyrics, "LRCLIB")
        }
        if let lyrics = await fetchFromMusixmatch(
            artist: track.artist, trackName: track.name,
            album: track.album, durationMs: track.durationMs
        ) {
            return (lyrics, "Musixmatch")
        }
        return (nil, nil)
    }

    // MARK: - LRCLIB

    private func fetchFromLRCLIB(artist: String, trackName: String, album: String?) async -> Lyrics? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
        ]
        if let album { comps.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }

        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10.0

        guard let (data, response) = try? await urlSession.data(for: req),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let synced = json["syncedLyrics"] as? String, !synced.isEmpty
        else { return nil }

        let lines = parseLRC(synced)
        return lines.isEmpty ? nil : Lyrics(lines: lines)
    }

    // MARK: - LRC Parser

    private static let lrcRegexes: [(NSRegularExpression, Bool)] = {
        [
            (#"\[(\d+):(\d+)\.(\d+)\](.+)"#, true),
            (#"\[(\d+):(\d+):(\d+)\](.+)"#, true),
            (#"\[(\d+):(\d+)\](.+)"#, false),
        ].compactMap { p, ms in (try? NSRegularExpression(pattern: p)).map { ($0, ms) } }
    }()

    private func parseLRC(_ lrc: String) -> [(timeMs: Int, text: String)] {
        var lines: [(Int, String)] = []
        for line in lrc.components(separatedBy: .newlines) {
            for (regex, hasMs) in SpotifyManager.lrcRegexes {
                if let parsed = parseLine(line, regex: regex, hasMs: hasMs) {
                    lines.append(parsed)
                    break
                }
            }
        }
        return lines.sorted { $0.0 < $1.0 }
    }

    private func parseLine(_ line: String, regex: NSRegularExpression, hasMs: Bool) -> (Int, String)? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        let min = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let sec = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let text = ns.substring(with: m.range(at: hasMs ? 4 : 3)).trimmingCharacters(in: .whitespaces)
        guard sec < 60, !text.isEmpty else { return nil }
        var ms = (min * 60 + sec) * 1000
        if hasMs { ms += (Int(ns.substring(with: m.range(at: 3))) ?? 0) * 10 }
        return (ms, text)
    }

    // MARK: - Musixmatch

    private func getMusixmatchToken() async -> String? {
        let stored = UserDefaults.standard.string(forKey: "musixmatch.token") ?? ""
        let expTs = UserDefaults.standard.double(forKey: "musixmatch.tokenExpiry")
        if !stored.isEmpty, expTs > 0 {
            musixmatchToken = stored
            musixmatchTokenExpiry = Date(timeIntervalSince1970: expTs)
        } else {
            musixmatchToken = nil
            musixmatchTokenExpiry = nil
        }

        if let token = musixmatchToken, let exp = musixmatchTokenExpiry, Date() < exp {
            return token
        }

        guard let url = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0")
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: req),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = json["message"] as? [String: Any],
            let body = msg["body"] as? [String: Any],
            let token = body["user_token"] as? String
        else { return nil }

        let exp = Date().addingTimeInterval(3600)
        musixmatchToken = token
        musixmatchTokenExpiry = exp
        UserDefaults.standard.set(token, forKey: "musixmatch.token")
        UserDefaults.standard.set(exp.timeIntervalSince1970, forKey: "musixmatch.tokenExpiry")
        return token
    }

    private func fetchFromMusixmatch(
        artist: String, trackName: String, album: String, durationMs: Int
    ) async -> Lyrics? {
        guard let token = await getMusixmatchToken() else { return nil }

        var comps = URLComponents(string: "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynced"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "q_track", value: trackName),
            URLQueryItem(name: "q_artist", value: artist),
            URLQueryItem(name: "q_album", value: album),
            URLQueryItem(name: "q_duration", value: String(durationMs / 1000)),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
        ]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: req),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }

        return parseMusixmatch(data, trackName: trackName, artist: artist)
    }

    private func parseMusixmatch(_ data: Data, trackName: String, artist: String) -> Lyrics? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let macroCalls = body["macro_calls"] as? [String: Any]
        else { return nil }

        if let matcher = macroCalls["matcher.track.get"] as? [String: Any],
            let mMsg = matcher["message"] as? [String: Any],
            let mBody = mMsg["body"] as? [String: Any],
            let mTrack = mBody["track"] as? [String: Any]
        {
            let mn = (mTrack["track_name"] as? String ?? "").lowercased()
            let ma = (mTrack["artist_name"] as? String ?? "").lowercased()
            let tn = trackName.lowercased()
            let ta = artist.lowercased()
            guard mn.contains(tn) || tn.contains(mn) || ma.contains(ta) || ta.contains(ma)
            else { return nil }
        }

        if let sub = macroCalls["track.subtitles.get"] as? [String: Any],
            let sMsg = sub["message"] as? [String: Any],
            let sBody = sMsg["body"] as? [String: Any],
            let list = sBody["subtitle_list"] as? [[String: Any]],
            let first = list.first,
            let subObj = first["subtitle"] as? [String: Any],
            let lrc = subObj["subtitle_body"] as? String, !lrc.isEmpty
        {
            let lines = parseLRC(lrc)
            if !lines.isEmpty { return Lyrics(lines: lines) }
        }
        return nil
    }
}
