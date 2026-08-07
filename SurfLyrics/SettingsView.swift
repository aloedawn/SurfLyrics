import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsSection? = .display

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
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .display:
            DisplaySettingsPane()
        case .behavior:
            BehaviorSettingsPane()
        case .lyrics:
            LyricsSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }
}
