import Foundation

protocol SpotifyClientLyricsProviding: Sendable {
    func fetch(for track: MusicTrack) async -> LyricsFetchResult
}

enum SpotifyClientBridgeError: Error {
    case unavailable
    case invalidResponse
}

struct SpotifyClientTarget: Decodable, Sendable {
    let type: String
    let url: String
    let webSocketDebuggerUrl: String?

    var validatedWebSocketURL: URL? {
        guard type == "page", let page = URL(string: url),
            page.host == "xpui.app.spotify.com",
            ["https", "http"].contains(page.scheme),
            let rawSocket = webSocketDebuggerUrl, let socket = URL(string: rawSocket),
            socket.scheme == "ws", socket.host == "127.0.0.1",
            socket.port == SpotifyClientLyricsClient.port,
            socket.user == nil, socket.password == nil,
            socket.path.hasPrefix("/devtools/page/"),
            socket.query == nil, socket.fragment == nil
        else { return nil }
        return socket
    }
}

actor SpotifyClientLyricsClient: SpotifyClientLyricsProviding {
    static let port = 43827
    private let session: URLSession
    private let bridgeSource: String?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: LocalOnlySessionDelegate(), delegateQueue: nil)
        bridgeSource = Bundle.main.url(forResource: "SpotifyClientBridge", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func fetch(for track: MusicTrack) async -> LyricsFetchResult {
        guard track.source == .spotify, track.itemKind == .track,
            let id = track.sourceTrackID, Self.isValidTrackID(id)
        else { return .notFound }
        guard !Task.isCancelled, let bridgeSource else { return .transientFailure }

        do {
            let value = try await evaluate("\(bridgeSource)(\"\(id)\")")
            try Task.checkCancellation()
            return Self.decode(value, expectedTrack: track)
        } catch {
            // Do not log CDP responses or request objects, which can contain client internals.
            return .transientFailure
        }
    }

    private func evaluate(_ expression: String) async throws -> Data {
        let targetURL = URL(string: "http://127.0.0.1:\(Self.port)/json/list")!
        let (data, response) = try await session.data(from: targetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
            let targets = try? JSONDecoder().decode([SpotifyClientTarget].self, from: data),
            let socketURL = targets.compactMap(\.validatedWebSocketURL).first
        else { throw SpotifyClientBridgeError.unavailable }
        try Task.checkCancellation()

        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 1_000_000
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        // CDP's evaluation timeout alone does not reliably bound a pending JS Promise.
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            let request: [String: Any] = [
                "id": 1, "method": "Runtime.evaluate",
                "params": [
                    "expression": expression, "awaitPromise": true,
                    "returnByValue": true, "timeout": 9_000,
                ],
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            try await socket.send(.string(String(decoding: requestData, as: UTF8.self)))
            while !Task.isCancelled {
                let message = try await socket.receive()
                let bytes: Data
                switch message {
                case let .data(data): bytes = data
                case let .string(text): bytes = Data(text.utf8)
                @unknown default: throw SpotifyClientBridgeError.invalidResponse
                }
                guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                else { throw SpotifyClientBridgeError.invalidResponse }
                guard envelope["id"] as? Int == 1 else { continue }
                guard envelope["error"] == nil,
                    let result = envelope["result"] as? [String: Any],
                    result["exceptionDetails"] == nil,
                    let remoteObject = result["result"] as? [String: Any],
                    let value = remoteObject["value"] as? [String: Any]
                else { throw SpotifyClientBridgeError.invalidResponse }
                return try JSONSerialization.data(withJSONObject: value)
            }
            throw CancellationError()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    nonisolated static func isValidTrackID(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    nonisolated static func decode(_ data: Data, expectedTrack: MusicTrack) -> LyricsFetchResult {
        guard data.count <= 1_000_000,
            let payload = try? JSONDecoder().decode(ClientLyricsPayload.self, from: data)
        else { return .transientFailure }
        guard payload.trackID == expectedTrack.sourceTrackID else { return .transientFailure }
        switch payload.status {
        case "notFound", "unsynced": return .notFound
        case "found": break
        default: return .transientFailure
        }
        guard payload.syncType == "LINE_SYNCED", let rawLines = payload.lines,
            !rawLines.isEmpty, rawLines.count <= 10_000
        else { return .notFound }

        var lines: [LyricsLine] = []
        let maximumTime = expectedTrack.durationMs > 0
            ? min(86_370_000, expectedTrack.durationMs) + 30_000 : 86_400_000
        for line in rawLines {
            guard let time = Int(line.startTimeMs), time >= 0, time <= maximumTime,
                time >= (lines.last?.timeMs ?? 0), line.words.utf8.count <= 16_384
            else { return .transientFailure }
            // Keep blank timed lines: Spotify uses these to clear the line during instrumental gaps.
            lines.append(LyricsLine(timeMs: time, text: line.words))
        }
        guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return .notFound }
        return .found(Lyrics(lines: lines))
    }
}

private struct ClientLyricsPayload: Decodable {
    let status: String
    let trackID: String?
    let syncType: String?
    let lines: [Line]?

    struct Line: Decodable {
        let startTimeMs: String
        let words: String
    }
}

private final class LocalOnlySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
