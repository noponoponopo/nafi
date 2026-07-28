import Foundation

/// A value passed to SwiftUI when a new browser window should become a native
/// macOS window tab. Every request has a unique identity so opening the same
/// location twice still creates two independent tabs.
struct NativeTabRequest: Codable, Hashable, Identifiable {
  let id: UUID
  let location: URL
  let revealURL: URL?
  let parentWindowID: UUID?

  init(
    id: UUID = UUID(),
    location: URL,
    revealURL: URL? = nil,
    parentWindowID: UUID? = nil
  ) {
    self.id = id
    self.location = location
    self.revealURL = revealURL
    self.parentWindowID = parentWindowID
  }
}

@MainActor
final class BrowserWindowState: ObservableObject, Identifiable {
  let id: UUID
  let workspace: WorkspaceModel
  let parentWindowID: UUID?

  private let revealURL: URL?
  private var hasStarted = false

  init(request: NativeTabRequest? = nil) {
    PreferenceMigration.run()
    let defaults = UserDefaults.standard
    let showHidden = defaults.bool(forKey: "Nafi.defaultShowHidden")
    let viewMode =
      defaults.string(forKey: "Nafi.defaultViewMode")
      .flatMap(FileViewMode.init(rawValue:)) ?? .list

    id = request?.id ?? UUID()
    parentWindowID = request?.parentWindowID
    revealURL = request?.revealURL
    workspace = WorkspaceModel(
      initialURL: request?.location ?? FileManager.default.homeDirectoryForCurrentUser,
      showHidden: showHidden,
      viewMode: viewMode
    )
  }

  var activeModel: FilePaneModel { workspace.activeModel }

  var isPristineHomeWindow: Bool {
    workspace.paneCount == 1
      && workspace.activeModel.currentURL.standardizedFileURL
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    if let revealURL {
      workspace.activeModel.selectAfterNextLoad(revealURL)
    }
    workspace.loadAll()
  }
}

@MainActor
final class NativeTabCommandRouter {
  static let shared = NativeTabCommandRouter()

  private var pendingCount = 0
  private var handler: (() -> Void)?

  private init() {}

  func connect(_ handler: @escaping () -> Void) {
    self.handler = handler
    guard pendingCount > 0 else { return }
    let count = pendingCount
    pendingCount = 0
    for _ in 0..<count { handler() }
  }

  func submit() {
    if let handler {
      handler()
    } else {
      pendingCount += 1
    }
  }
}
