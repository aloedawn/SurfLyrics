import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("displayMode") private var displayMode = "trackAndArtist"
    @AppStorage("maxTextLength") private var maxTextLength = 60
    @AppStorage("lyricsTransitionEnabled") private var fadeEnabled = false
    @AppStorage("lyricsSourceLRCLIB") private var useLRCLIB = true
    @AppStorage("lyricsSourceMusixmatch") private var useMusixmatch = true
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled()
    @State private var musixmatchTokenExists = UserDefaults.standard.string(forKey: "musixmatch.token")?.isEmpty == false

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

            Divider()

            Group {
                Text("가사 소스")
                    .font(.headline)

                Toggle("LRCLIB (공개 API)", isOn: $useLRCLIB)
                Toggle("Musixmatch (비공개 API)", isOn: $useMusixmatch)

                if musixmatchTokenExists {
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

            Divider()

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
            Text("버전 \(version) (\(build))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 380)
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
