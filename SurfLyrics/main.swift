import SwiftUI

struct SurfLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

SurfLyricsApp.main()
