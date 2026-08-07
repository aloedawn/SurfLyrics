import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case display
    case behavior
    case lyrics
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .display: "표시"
        case .behavior: "동작"
        case .lyrics: "가사 소스"
        case .about: "정보"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "textformat"
        case .behavior: "slider.horizontal.3"
        case .lyrics: "music.note.list"
        case .about: "info.circle"
        }
    }
}

struct DisplaySettingsPane: View {
    @AppStorage(AppPreferenceKey.displayMode) private var displayMode = DisplayMode.trackAndArtist.rawValue
    @AppStorage(AppPreferenceKey.maxTextLength) private var maxTextLength = 60

    var body: some View {
        SettingsPane(title: "표시") {
            LabeledRow("표시 모드") {
                Picker("", selection: $displayMode) {
                    Text("트랙 & 아티스트").tag(DisplayMode.trackAndArtist.rawValue)
                    Text("트랙만").tag(DisplayMode.trackOnly.rawValue)
                    Text("아티스트만").tag(DisplayMode.artistOnly.rawValue)
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
                .frame(width: 240)
            }
        }
        .onChange(of: displayMode) {
            NotificationCenter.default.post(name: .settingsDisplayModeChanged, object: nil)
        }
    }
}

struct BehaviorSettingsPane: View {
    @AppStorage(AppPreferenceKey.lyricsTransitionEnabled) private var fadeEnabled = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled()

    var body: some View {
        SettingsPane(title: "동작") {
            Toggle("가사 전환 페이드 효과", isOn: $fadeEnabled)

            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    LaunchAtLoginManager.toggle()
                    launchAtLogin = LaunchAtLoginManager.isEnabled()
                }
        }
    }
}

struct LyricsSettingsPane: View {
    @AppStorage(AppPreferenceKey.lyricsSourceLRCLIB) private var useLRCLIB = true
    @AppStorage(AppPreferenceKey.lyricsSourceMusixmatch) private var useMusixmatch = true
    @State private var musixmatchTokenExists = AppPreferences().musixmatchTokenExists

    var body: some View {
        SettingsPane(title: "가사 소스") {
            Toggle("LRCLIB (공개 API)", isOn: $useLRCLIB)
            Toggle("Musixmatch (비공개 API)", isOn: $useMusixmatch)

            if musixmatchTokenExists {
                Divider()

                LabeledRow("토큰") {
                    Button("캐시 초기화") {
                        AppPreferences().clearMusixmatchToken()
                        musixmatchTokenExists = false
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: useLRCLIB) {
            notifyLyricsSourcesChanged()
        }
        .onChange(of: useMusixmatch) {
            notifyLyricsSourcesChanged()
        }
    }

    private func notifyLyricsSourcesChanged() {
        NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
    }
}

struct AboutSettingsPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        SettingsPane(title: "정보") {
            VStack(alignment: .leading, spacing: 6) {
                Text("SurfLyrics")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("버전 \(version) (\(build))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                content()
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LabeledRow<Content: View>: View {
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
