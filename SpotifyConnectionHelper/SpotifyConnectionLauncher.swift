import AppKit

#if !SURFLYRICS_CONNECTION_HELPER
@testable import SurfLyrics
#endif

enum SpotifyConnectionLaunchError: Error {
    case spotifyMissing, couldNotQuit, timedOut, unsafeListener
}

@MainActor
protocol SpotifyLaunchEnvironment {
    func isReady() async -> Bool
    func quitSpotify() async throws
    func launchSpotify(withConnection: Bool) async throws
    func hasLoopbackListener() async -> Bool
}

@MainActor
struct SpotifyConnectionLauncher {
    let environment: any SpotifyLaunchEnvironment
    var maximumPolls = 30
    var sleep: () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }

    func connect() async throws {
        if await environment.isReady() {
            guard await environment.hasLoopbackListener() else { throw SpotifyConnectionLaunchError.unsafeListener }
            return
        }
        try await environment.quitSpotify()
        do {
            try await environment.launchSpotify(withConnection: true)
            for _ in 0..<maximumPolls {
                if await environment.isReady() {
                    guard await environment.hasLoopbackListener() else { throw SpotifyConnectionLaunchError.unsafeListener }
                    return
                }
                try await sleep()
            }
            throw SpotifyConnectionLaunchError.timedOut
        } catch {
            // Recover normal Spotify startup if this connection attempt fails.
            try? await environment.quitSpotify()
            try? await environment.launchSpotify(withConnection: false)
            throw error
        }
    }
}

@MainActor
final class NativeSpotifyLaunchEnvironment: SpotifyLaunchEnvironment {
    private let session = SpotifyClientEndpoint.makeSession()

    func isReady() async -> Bool {
        (try? await SpotifyClientEndpoint.debuggerURL(using: session)) != nil
    }

    func quitSpotify() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
        for application in applications {
            guard application.terminate() else { throw SpotifyConnectionLaunchError.couldNotQuit }
        }
        for _ in 0..<50 {
            if applications.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SpotifyConnectionLaunchError.couldNotQuit
    }

    func launchSpotify(withConnection: Bool) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
        else { throw SpotifyConnectionLaunchError.spotifyMissing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        if withConnection {
            configuration.arguments = [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=\(SpotifyClientEndpoint.port)",
            ]
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func hasLoopbackListener() async -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
            .first?.processIdentifier else { return false }
        return await Task.detached {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(SpotifyClientEndpoint.port)", "-sTCP:LISTEN", "-Fn"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return task.terminationStatus == 0 && Self.isLoopbackOnly(String(decoding: data, as: UTF8.self))
            } catch { return false }
        }.value
    }

    nonisolated static func isLoopbackOnly(_ output: String) -> Bool {
        let addresses = output.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return !addresses.isEmpty && addresses.allSatisfy { $0 == "127.0.0.1:\(SpotifyClientEndpoint.port)" }
    }
}
