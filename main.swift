import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
    static let settingsDisplayModeChanged = Notification.Name("surflyrics.displayModeChanged")
}

// MARK: - App

struct SurfLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("displayMode") private var displayMode = "trackAndArtist"
    @AppStorage("maxTextLength") private var maxTextLength = 60
    @AppStorage("lyricsTransitionEnabled") private var fadeEnabled = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                Text("표시 형식")
                    .font(.headline)

                LabeledRow("표시 모드") {
                    Picker("", selection: $displayMode) {
                        Text("트랙 & 아티스트").tag("trackAndArtist")
                        Text("트랙만").tag("trackOnly")
                        Text("아티스트만").tag("artistOnly")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                LabeledRow("최대 길이") {
                    Picker("", selection: $maxTextLength) {
                        Text("40자").tag(40)
                        Text("60자").tag(60)
                        Text("80자").tag(80)
                        Text("100자").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            Divider()

            Group {
                Text("동작")
                    .font(.headline)

                Toggle("가사 전환 페이드 효과", isOn: $fadeEnabled)
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        LaunchAtLoginManager.toggle()
                        launchAtLogin = LaunchAtLoginManager.isEnabled()
                    }
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: displayMode) {
            NotificationCenter.default.post(name: .settingsDisplayModeChanged, object: nil)
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appState: AppState!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = appState.statusText
        statusItem?.menu = buildMenu()

        appState.onStatusUpdate = { [weak self] text in
            self?.updateLabel(text)
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart", action: #selector(restartApp), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        restart.target = self
        menu.addItem(restart)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restartApp() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments  = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Animation

    private func updateLabel(_ text: String) {
        guard let button = statusItem?.button else { return }
        let fade = UserDefaults.standard.bool(forKey: "lyricsTransitionEnabled")
        if fade {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                button.animator().alphaValue = 0
            }, completionHandler: {
                button.title = text
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    button.animator().alphaValue = 1
                }
            })
        } else {
            button.title = text
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var statusText = "♪ Initializing"
    var onStatusUpdate: ((String) -> Void)?

    private let spotifyManager = SpotifyManager()
    private var timer: Timer?
    private var updateInterval: TimeInterval = 1.0
    private var currentTrackId = ""
    private var currentLyrics: Lyrics?
    private var isLoadingLyrics = false
    private var currentTrack: SpotifyTrack?

    init() {
        // Spotify 재생 상태 변경 알림
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }

        // 설정창에서 표시 모드 변경 시
        NotificationCenter.default.addObserver(
            forName: .settingsDisplayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.currentTrack else { return }
                self.updateDisplay(for: track, force: true)
            }
        }

        updateStatusBar()
        scheduleNextUpdate()
    }

    // MARK: - Public

    func refresh() { updateStatusBar() }

    // MARK: - Timer

    private func scheduleNextUpdate() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Update Logic

    private func updateStatusBar() {
        spotifyManager.getCurrentTrack { [weak self] track in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let track {
                    track.isPlaying ? self.handlePlaying(track) : self.handlePaused()
                } else {
                    self.handleNotPlaying()
                }
            }
        }
    }

    private func handlePlaying(_ track: SpotifyTrack) {
        let id = "\(track.name)_\(track.artist)"
        currentTrack = track
        if id != currentTrackId {
            currentTrackId = id
            currentLyrics = nil
            isLoadingLyrics = false
            loadLyrics(for: track)
        } else {
            updateDisplay(for: track, force: false)
        }
        scheduleNextUpdate()
    }

    private func handlePaused() { stopTimer() }

    private func handleNotPlaying() {
        statusText = "♪ Waiting"
        onStatusUpdate?(statusText)
        currentTrackId = ""
        currentLyrics = nil
        currentTrack = nil
        updateInterval = 1.0
        stopTimer()
    }

    private func loadLyrics(for track: SpotifyTrack) {
        guard !isLoadingLyrics else { return }
        isLoadingLyrics = true
        statusText = formatTrackInfo(track)
        onStatusUpdate?(statusText)

        spotifyManager.getLyrics(for: track) { [weak self] lyrics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoadingLyrics = false
                self.currentLyrics = lyrics
                if lyrics == nil { self.stopTimer() }
                if let track = self.currentTrack { self.updateDisplay(for: track, force: false) }
            }
        }
    }

    private func updateDisplay(for track: SpotifyTrack, force: Bool) {
        let text = displayText(for: track)
        guard force || text != statusText else { return }
        statusText = text
        onStatusUpdate?(text)
    }

    private func displayText(for track: SpotifyTrack) -> String {
        guard !isLoadingLyrics else { return formatTrackInfo(track) }
        if let lyrics = currentLyrics {
            if let line = lyrics.currentLine(at: track.progressMs) {
                adjustInterval(
                    lyrics: lyrics, progressMs: track.progressMs, durationMs: track.durationMs)
                return truncate(line)
            }
            return formatTrackInfo(track)
        }
        return formatTrackInfo(track)
    }

    private func adjustInterval(lyrics: Lyrics, progressMs: Int, durationMs: Int) {
        if let next = lyrics.nextLineTime(after: progressMs) {
            updateInterval = max(0.3, min(Double(next - progressMs) / 1000.0, 10.0))
        } else {
            let remaining = Double(durationMs - progressMs) / 1000.0
            updateInterval = remaining > 1.0 ? min(remaining, 10.0) : 1.0
        }
    }

    private func formatTrackInfo(_ track: SpotifyTrack) -> String {
        let mode = UserDefaults.standard.string(forKey: "displayMode") ?? "trackAndArtist"
        let text: String
        switch mode {
        case "trackOnly": text = "♫ \(track.name)"
        case "artistOnly": text = "♫ \(track.artist)"
        default: text = "♫ \(track.name) — \(track.artist)"
        }
        return truncate(text)
    }

    private func truncate(_ text: String) -> String {
        let limit = {
            let v = UserDefaults.standard.integer(forKey: "maxTextLength")
            return v > 0 ? v : 60
        }()
        return text.count > limit ? String(text.prefix(limit - 3)) + "..." : text
    }
}

// MARK: - Launch at Login

struct LaunchAtLoginManager {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        isEnabled() ? disable() : enable()
    }

    private static func enable() {
        try? SMAppService.mainApp.register()
    }

    private static func disable() {
        try? SMAppService.mainApp.unregister()
    }
}

// MARK: - Data Models

struct SpotifyTrack: Codable {
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool
}

struct Lyrics {
    let lines: [(timeMs: Int, text: String)]

    func currentLine(at progressMs: Int) -> String? {
        lines.last(where: { $0.timeMs <= progressMs })?.text
    }

    func nextLineTime(after progressMs: Int) -> Int? {
        lines.first(where: { $0.timeMs > progressMs })?.timeMs
    }
}

// MARK: - Spotify Manager

class SpotifyManager {
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var musixmatchToken: String? = {
        let t = UserDefaults.standard.string(forKey: "musixmatch.token") ?? ""
        return t.isEmpty ? nil : t
    }()
    private var musixmatchTokenExpiry: Date? = {
        let ts = UserDefaults.standard.double(forKey: "musixmatch.tokenExpiry")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()

    func getCurrentTrack(completion: @escaping (SpotifyTrack?) -> Void) {
        let script = """
            if application "Spotify" is running then
                tell application "Spotify"
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

        DispatchQueue.global(qos: .userInitiated).async {
            guard let appleScript = NSAppleScript(source: script) else {
                completion(nil)
                return
            }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil,
                let str = result.stringValue, !str.isEmpty
            else {
                completion(nil)
                return
            }

            let parts = str.components(separatedBy: "|")
            guard parts.count == 6 else {
                completion(nil)
                return
            }

            completion(
                SpotifyTrack(
                    name: parts[1],
                    artist: parts[2],
                    album: parts[3],
                    durationMs: Int(Double(parts[4]) ?? 0),
                    progressMs: Int((Double(parts[5]) ?? 0) * 1000),
                    isPlaying: parts[0] == "playing"
                ))
        }
    }

    func getLyrics(for track: SpotifyTrack, completion: @escaping (Lyrics?) -> Void) {
        fetchFromLRCLIB(artist: track.artist, trackName: track.name, album: track.album) {
            [weak self] lyrics in
            if lyrics != nil {
                completion(lyrics)
                return
            }
            self?.fetchFromLRCLIB(artist: track.artist, trackName: track.name, album: nil) {
                [weak self] lyrics in
                if lyrics != nil {
                    completion(lyrics)
                    return
                }
                self?.fetchFromMusixmatch(
                    artist: track.artist, trackName: track.name,
                    album: track.album, durationMs: track.durationMs,
                    completion: completion
                )
            }
        }
    }

    // MARK: LRCLIB

    private func fetchFromLRCLIB(
        artist: String, trackName: String, album: String?,
        completion: @escaping (Lyrics?) -> Void
    ) {
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0
        }
        var url =
            "https://lrclib.net/api/get?artist_name=\(enc(artist))&track_name=\(enc(trackName))"
        if let album { url += "&album_name=\(enc(album))" }

        guard let endpoint = URL(string: url) else {
            completion(nil)
            return
        }
        var req = URLRequest(url: endpoint)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10.0

        urlSession.dataTask(with: req) { [weak self] data, response, error in
            guard error == nil,
                let data,
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let synced = json["syncedLyrics"] as? String, !synced.isEmpty
            else {
                completion(nil)
                return
            }
            let lines = self?.parseLRC(synced) ?? []
            completion(Lyrics(lines: lines))
        }.resume()
    }

    // MARK: LRC Parser

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

    private func parseLine(_ line: String, regex: NSRegularExpression, hasMs: Bool) -> (
        Int, String
    )? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        let min = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let sec = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let text = ns.substring(with: m.range(at: hasMs ? 4 : 3)).trimmingCharacters(
            in: .whitespaces)
        guard sec < 60, !text.isEmpty else { return nil }
        var ms = (min * 60 + sec) * 1000
        if hasMs { ms += (Int(ns.substring(with: m.range(at: 3))) ?? 0) * 10 }
        return (ms, text)
    }

    // MARK: Musixmatch

    private func getMusixmatchToken(completion: @escaping (String?) -> Void) {
        // UserDefaults 재동기화 — 설정창에서 리셋 시 즉시 반영
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
            completion(token)
            return
        }

        guard
            let url = URL(
                string:
                    "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0"
            )
        else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent")

        urlSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self,
                let data, error == nil,
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let msg = json["message"] as? [String: Any],
                let body = msg["body"] as? [String: Any],
                let token = body["user_token"] as? String
            else {
                completion(nil)
                return
            }

            let exp = Date().addingTimeInterval(3600)
            self.musixmatchToken = token
            self.musixmatchTokenExpiry = exp
            UserDefaults.standard.set(token, forKey: "musixmatch.token")
            UserDefaults.standard.set(exp.timeIntervalSince1970, forKey: "musixmatch.tokenExpiry")
            completion(token)
        }.resume()
    }

    private func fetchFromMusixmatch(
        artist: String, trackName: String, album: String, durationMs: Int,
        completion: @escaping (Lyrics?) -> Void
    ) {
        getMusixmatchToken { [weak self] token in
            guard let self, let token else {
                completion(nil)
                return
            }

            var comps = URLComponents(
                string: "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get")!
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
            guard let url = comps.url else {
                completion(nil)
                return
            }

            var req = URLRequest(url: url)
            req.timeoutInterval = 10.0
            req.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent")

            self.urlSession.dataTask(with: req) { [weak self] data, response, error in
                guard let self,
                    let data, error == nil,
                    let http = response as? HTTPURLResponse, http.statusCode == 200
                else {
                    completion(nil)
                    return
                }
                completion(self.parseMusixmatch(data, trackName: trackName, artist: artist))
            }.resume()
        }
    }

    private func parseMusixmatch(_ data: Data, trackName: String, artist: String) -> Lyrics? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let macroCalls = body["macro_calls"] as? [String: Any]
        else { return nil }

        // 매칭 검증
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

// MARK: - Entry Point

SurfLyricsApp.main()
