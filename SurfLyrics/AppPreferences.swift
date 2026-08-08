import Foundation

enum AppPreferenceKey {
    static let displayMode = "displayMode"
    static let maxTextLength = "maxTextLength"
    static let lyricsTransitionEnabled = "lyricsTransitionEnabled"
    static let lyricsSourceLRCLIB = "lyricsSourceLRCLIB"
    static let lyricsSourceMusixmatch = "lyricsSourceMusixmatch"

    fileprivate static let musixmatchToken = "musixmatch.token"
    fileprivate static let musixmatchTokenExpiry = "musixmatch.tokenExpiry"
}

enum DisplayMode: String, Sendable {
    case trackAndArtist
    case trackOnly
    case artistOnly
}

struct AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var displayMode: DisplayMode {
        let rawValue = defaults.string(forKey: AppPreferenceKey.displayMode)
        return rawValue.flatMap(DisplayMode.init(rawValue:)) ?? .trackAndArtist
    }

    var maxTextLength: Int {
        let value = defaults.integer(forKey: AppPreferenceKey.maxTextLength)
        return value > 0 ? value : 60
    }

    var lyricsTransitionEnabled: Bool {
        defaults.bool(forKey: AppPreferenceKey.lyricsTransitionEnabled)
    }

    var usesLRCLIB: Bool {
        bool(forKey: AppPreferenceKey.lyricsSourceLRCLIB, defaultValue: true)
    }

    var usesMusixmatch: Bool {
        bool(forKey: AppPreferenceKey.lyricsSourceMusixmatch, defaultValue: true)
    }

    var musixmatchTokenExists: Bool {
        musixmatchToken != nil
    }

    var musixmatchToken: String? {
        guard let token = defaults.string(forKey: AppPreferenceKey.musixmatchToken), !token.isEmpty else {
            return nil
        }
        return token
    }

    var musixmatchTokenExpiry: Date? {
        let timestamp = defaults.double(forKey: AppPreferenceKey.musixmatchTokenExpiry)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func storeMusixmatchToken(_ token: String, expiresAt expiry: Date) {
        defaults.set(token, forKey: AppPreferenceKey.musixmatchToken)
        defaults.set(expiry.timeIntervalSince1970, forKey: AppPreferenceKey.musixmatchTokenExpiry)
    }

    func clearMusixmatchToken() {
        defaults.removeObject(forKey: AppPreferenceKey.musixmatchToken)
        defaults.removeObject(forKey: AppPreferenceKey.musixmatchTokenExpiry)
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

extension Notification.Name {
    static let settingsDisplayModeChanged = Notification.Name("surflyrics.displayModeChanged")
    static let settingsLyricsSourcesChanged = Notification.Name("surflyrics.lyricsSourcesChanged")
}
