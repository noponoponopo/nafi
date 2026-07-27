import SwiftUI

@main
struct NamiApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(appState)
        .frame(minWidth: 1080, minHeight: 680)
        .task { await appState.start() }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands { NamiCommands(appState: appState) }

    Settings {
      SettingsView()
        .environmentObject(appState)
        .frame(width: 560, height: 390)
    }
  }
}
