import SwiftUI

@main
struct NamiApp: App {
  @NSApplicationDelegateAdaptor(NafiAppDelegate.self) private var appDelegate
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(appState)
        .frame(minWidth: 640, minHeight: 420)
        .task { await appState.start() }
    }
    .defaultSize(width: 1080, height: 680)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands { NamiCommands(appState: appState) }

    WindowGroup("サーバー接続", id: "server-editor", for: ServerProfile.self) { $profile in
      ServerEditorView(serverManager: appState.serverManager, profile: profile)
        .environmentObject(appState)
    }
    .defaultSize(width: 620, height: 640)
    .windowResizability(.contentMinSize)

    WindowGroup("情報", id: "file-inspector", for: URL.self) { $url in
      if let url {
        InspectorWindow(url: url)
          .environmentObject(appState)
      }
    }
    .defaultSize(width: 580, height: 650)
    .windowResizability(.contentMinSize)

    Settings {
      SettingsView()
        .environmentObject(appState)
        .frame(width: 760, height: 600)
    }
  }
}
