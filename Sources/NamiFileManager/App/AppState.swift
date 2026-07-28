import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  @Published var isServerSheetPresented = false
  @Published var isInspectorPresented = false
  @Published var isSidebarEditorPresented = false
  @Published var quickEditRequest: QuickEditRequest?
  @Published var presentationErrorMessage: String?
  @Published var sidebarVisibility: NavigationSplitViewVisibility = .all

  let workspace: WorkspaceModel
  let serverManager = ServerManager()
  let sidebarModel = SidebarModel()
  let defaultFileManager = DefaultFileManagerService()
  let cloudStorage = CloudStorageService()

  private var hasHandledExternalOpen = false

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

    ExternalOpenRouter.shared.connect { [weak self] urls in
      self?.openExternalURLs(urls)
    }
  }

  var activeModel: FilePaneModel { workspace.activeModel }

  func start() async {
    defaultFileManager.refresh()
    cloudStorage.refresh()
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

  func openICloudDrive() {
    guard let url = cloudStorage.iCloudDriveURL else {
      cloudStorage.chooseICloudDriveLocation()
      guard let selectedURL = cloudStorage.iCloudDriveURL else { return }
      activeModel.navigate(to: selectedURL)
      return
    }
    activeModel.navigate(to: url)
  }

  var canQuickEditSelection: Bool {
    guard let item = activeModel.selectedItem else { return false }
    return QuickEditSupport.isEditable(item)
  }

  func presentQuickEdit(for item: FileItem) {
    guard QuickEditSupport.isEditable(item) else {
      presentationErrorMessage = "クイックエディットはテキスト系ファイルだけで利用できます。"
      return
    }
    quickEditRequest = QuickEditRequest(url: item.url)
  }

  func quickEditSelected() {
    guard let item = activeModel.selectedItem else {
      presentationErrorMessage = "編集するファイルを選択してください。"
      return
    }
    presentQuickEdit(for: item)
  }

  func quickEditDidSave(_ url: URL) {
    let parent = url.deletingLastPathComponent().standardizedFileURL
    for model in workspace.allModels where model.currentURL.standardizedFileURL == parent {
      model.load()
    }
  }

  func openExternalURLs(_ urls: [URL]) {
    let normalized =
      urls
      .map { $0.resolvingSymlinksInPath().standardizedFileURL }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !normalized.isEmpty else { return }

    NSApplication.shared.activate(ignoringOtherApps: true)

    let configuredBehavior =
      UserDefaults.standard.string(forKey: "Nafi.externalOpenBehavior")
      .flatMap(ExternalOpenBehavior.init(rawValue:)) ?? .newTab

    for (index, url) in normalized.enumerated() {
      let shouldReuseInitialTab =
        !hasHandledExternalOpen
        && index == 0
        && workspace.paneCount == 1
        && workspace.activeSession.tabs.count == 1
        && workspace.activeModel.currentURL.standardizedFileURL
          == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

      let behavior: ExternalOpenBehavior = shouldReuseInitialTab ? .currentTab : configuredBehavior
      openExternalURL(url, behavior: behavior)
    }

    hasHandledExternalOpen = true
  }

  private func openExternalURL(_ url: URL, behavior: ExternalOpenBehavior) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else { return }

    if isDirectory.boolValue {
      switch behavior {
      case .currentTab:
        workspace.activeModel.navigate(to: url)
      case .newTab:
        workspace.newTab(at: url)
      }
      return
    }

    let parent = url.deletingLastPathComponent()
    switch behavior {
    case .currentTab:
      workspace.activeModel.revealExternalItem(url)
    case .newTab:
      workspace.newTab(at: parent)?.selectAfterNextLoad(url)
    }
  }
}
