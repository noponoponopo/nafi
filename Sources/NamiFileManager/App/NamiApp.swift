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

    Settings {
      SettingsView()
        .environmentObject(appState)
        .frame(width: 760, height: 600)
    }
  }
}
