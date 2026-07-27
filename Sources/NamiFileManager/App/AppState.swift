import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  @Published var isServerSheetPresented = false
  @Published var isInspectorPresented = false
  @Published var isSidebarEditorPresented = false
  @Published var sidebarVisibility: NavigationSplitViewVisibility = .all

  let workspace: WorkspaceModel
  let serverManager = ServerManager()
  let sidebarModel = SidebarModel()

  init() {
    let defaults = UserDefaults.standard
    let showHidden = defaults.bool(forKey: "Nami.defaultShowHidden")
    let viewMode =
      defaults.string(forKey: "Nami.defaultViewMode")
      .flatMap(FileViewMode.init(rawValue:)) ?? .list
    workspace = WorkspaceModel(
      initialURL: FileManager.default.homeDirectoryForCurrentUser,
      showHidden: showHidden,
      viewMode: viewMode
    )
  }

  var activeModel: FilePaneModel { workspace.activeModel }

  func start() async {
    workspace.loadAll()
    serverManager.refreshMountedVolumes()
    await serverManager.connectAutoProfiles()
  }

  func openInNewPane(_ url: URL) {
    workspace.openInNewPane(url)
  }

  func openInNewTab(_ url: URL) {
    workspace.newTab(at: url)
  }
}
