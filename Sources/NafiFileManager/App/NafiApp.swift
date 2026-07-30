import SwiftUI

@main
struct NafiApp: App {
  @NSApplicationDelegateAdaptor(NafiAppDelegate.self) private var appDelegate
  @StateObject private var appState = AppState()

  var body: some Scene {
    Window("nafi", id: "browser") {
      RootView(request: nil)
        .environmentObject(appState)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { appDelegate.appState = appState }
        .task { await appState.start() }
    }
    .defaultSize(width: 1080, height: 680)
    .windowToolbarStyle(.unified(showsTitle: false))
    .handlesExternalEvents(matching: [])
    .commands { NafiCommands(appState: appState) }

    WindowGroup("サーバー接続", id: "server-editor", for: ServerProfile.self) { $profile in
      ServerEditorView(serverManager: appState.serverManager, profile: profile)
        .environmentObject(appState)
        .background(WindowTabbingDisabler())
    }
    .defaultSize(width: 620, height: 640)
    .windowResizability(.contentMinSize)
    .handlesExternalEvents(matching: [])

    WindowGroup("情報", id: "file-inspector", for: URL.self) { $url in
      if let url {
        InspectorWindow(url: url)
          .environmentObject(appState)
          .background(WindowTabbingDisabler())
      }
    }
    .defaultSize(width: 580, height: 650)
    .windowResizability(.contentMinSize)
    .handlesExternalEvents(matching: [])

    WindowGroup("Drop Stack", id: "drop-stack") {
      DropStackView(model: appState.dropStack)
        .environmentObject(appState)
        .background(WindowTabbingDisabler())
    }
    .defaultSize(width: 700, height: 480)
    .windowResizability(.contentMinSize)
    .handlesExternalEvents(matching: [])

    Settings {
      SettingsView()
        .environmentObject(appState)
        .frame(width: 760, height: 600)
        .background(WindowTabbingDisabler())
    }
  }
}
