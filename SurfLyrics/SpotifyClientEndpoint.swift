import Foundation

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
            socket.port == SpotifyClientEndpoint.port,
            socket.user == nil, socket.password == nil,
            socket.path.hasPrefix("/devtools/page/"),
            socket.query == nil, socket.fragment == nil
        else { return nil }
        return socket
    }
}

enum SpotifyClientEndpoint {
    static let port = 43827
    static let targetListURL = URL(string: "http://127.0.0.1:\(port)/json/list")!

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: LocalOnlySessionDelegate(), delegateQueue: nil)
    }

    static func debuggerURL(using session: URLSession) async throws -> URL {
        let (data, response) = try await session.data(from: targetListURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
            let targets = try? JSONDecoder().decode([SpotifyClientTarget].self, from: data),
            let socketURL = targets.compactMap(\.validatedWebSocketURL).first
        else { throw SpotifyClientBridgeError.unavailable }
        return socketURL
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
