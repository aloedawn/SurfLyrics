import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @State private var selection: SettingsSection? = .display
    @AppStorage("displayMode") private var displayMode = "trackAndArtist"
    @AppStorage("maxTextLength") private var maxTextLength = 60
    @AppStorage("lyricsTransitionEnabled") private var fadeEnabled = false
    @AppStorage("lyricsSourceLRCLIB") private var useLRCLIB = true
    @AppStorage("lyricsSourceMusixmatch") private var useMusixmatch = true
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled()
    @State private var musixmatchTokenExists = UserDefaults.standard.string(forKey: "musixmatch.token")?.isEmpty == false

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("설정")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView(for: selection ?? .display)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 380, idealHeight: 440)
        .onChange(of: displayMode) {
            NotificationCenter.default.post(name: .settingsDisplayModeChanged, object: nil)
        }
        .onChange(of: useLRCLIB) {
            NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
        }
        .onChange(of: useMusixmatch) {
            NotificationCenter.default.post(name: .settingsLyricsSourcesChanged, object: nil)
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .display:
            displayPane
        case .behavior:
            behaviorPane
        case .lyrics:
            lyricsPane
        case .about:
            aboutPane
        }
    }

    private var displayPane: some View {
        SettingsPane(title: "표시") {
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
                .frame(width: 240)
            }
        }
    }

    private var behaviorPane: some View {
        SettingsPane(title: "동작") {
            Toggle("가사 전환 페이드 효과", isOn: $fadeEnabled)

            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    LaunchAtLoginManager.toggle()
                    launchAtLogin = LaunchAtLoginManager.isEnabled()
                }
        }
    }

    private var lyricsPane: some View {
        SettingsPane(title: "가사 소스") {
            Toggle("LRCLIB (공개 API)", isOn: $useLRCLIB)
            Toggle("Musixmatch (비공개 API)", isOn: $useMusixmatch)

            if musixmatchTokenExists {
                Divider()

                LabeledRow("토큰") {
                    Button("캐시 초기화") {
                        UserDefaults.standard.removeObject(forKey: "musixmatch.token")
                        UserDefaults.standard.removeObject(forKey: "musixmatch.tokenExpiry")
                        musixmatchTokenExists = false
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private var aboutPane: some View {
        SettingsPane(title: "정보") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"

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

// MARK: - SettingsSection

private enum SettingsSection: String, CaseIterable, Identifiable {
    case display
    case behavior
    case lyrics
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .display:  "표시"
        case .behavior: "동작"
        case .lyrics:   "가사 소스"
        case .about:    "정보"
        }
    }

    var systemImage: String {
        switch self {
        case .display:  "textformat"
        case .behavior: "slider.horizontal.3"
        case .lyrics:   "music.note.list"
        case .about:    "info.circle"
        }
    }
}

// MARK: - SettingsPane

private struct SettingsPane<Content: View>: View {
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

// MARK: - LabeledRow

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
