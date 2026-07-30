import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  @Published var isSidebarEditorPresented = false
  @Published var quickEditRequest: QuickEditRequest?
  @Published var presentationErrorMessage: String?
  @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
  @Published var isQuickOpenPresented = false
  @Published var isSyncCenterPresented = false
  @Published var isWorkspaceLibraryPresented = false
  @Published private(set) var activeWindowID: UUID?

  var openServerEditor: ((ServerProfile) -> Void)?
  var openInspector: ((URL) -> Void)?
  var openDropStack: (() -> Void)?

  let serverManager = ServerManager()
  let sidebarModel = SidebarModel()
  let defaultFileManager = DefaultFileManagerService()
  let cloudStorage = CloudStorageService()
  let transferQueueModel = TransferQueueModel()
  let syncManager = SyncManager()
  let dropStack = DropStackModel()
  let quickOpenModel = QuickOpenModel()
  let workspaceLibrary = WorkspaceLibrary.shared
  let systemIntegration = SystemIntegrationService()

  private let fallbackWindowState = BrowserWindowState()
  private var windowStates: [UUID: BrowserWindowState] = [:]
  private var nativeWindows: [UUID: WeakWindowBox] = [:]
  private var pendingExternalURLs: [URL] = []
  private var ownedWindowControllers: [UUID: NSWindowController] = [:]
  private var startupTask: Task<Void, Never>?
  private var maintenanceObserver: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?
  private var workspaceObservers: [UUID: AnyCancellable] = [:]
  private var serverProfilesObserver: AnyCancellable?
  private var sessionPersistenceTask: Task<Void, Never>?
  private var didRestoreSessionTabs = false
  private var reusePristineWindowForNextExternalOpen = false

  init() {
    ExternalOpenRouter.shared.connect { [weak self] urls in
      self?.openExternalURLs(urls)
    }
    ExternalOpenRouter.shared.connectCommands { [weak self] command in
      self?.handleExternalCommand(command)
    }
    NativeTabCommandRouter.shared.connect { [weak self] in
      self?.newNativeTab()
    }
    maintenanceObserver = NotificationCenter.default.addObserver(
      forName: .nafiMaintenanceWarning,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let message = notification.userInfo?["message"] as? String else { return }
      Task { @MainActor in self?.presentationErrorMessage = message }
    }
    if let message = sidebarModel.persistenceErrorMessage {
      presentationErrorMessage = message
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.persistOpenWorkspaces() }
    }
    serverProfilesObserver = serverManager.$profiles.sink { [weak self] profiles in
      Task { @MainActor in self?.systemIntegration.reconcileFileProviderProfiles(profiles) }
    }
    configureGlobalQuickOpen()
  }

  deinit {
    if let maintenanceObserver { NotificationCenter.default.removeObserver(maintenanceObserver) }
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    sessionPersistenceTask?.cancel()
  }

  var activeWindowState: BrowserWindowState? {
    if let activeWindowID, let state = windowStates[activeWindowID] {
      return state
    }
    return windowStates.values.first
  }

  /// Compatibility accessor used by commands and existing views. It always
  /// resolves to the workspace belonging to the key native window tab.
  var workspace: WorkspaceModel {
    activeWindowState?.workspace ?? fallbackWindowState.workspace
  }

  var activeModel: FilePaneModel { workspace.activeModel }

  func register(window: NSWindow, for state: BrowserWindowState) {
    windowStates[state.id] = state
    nativeWindows[state.id] = WeakWindowBox(window)
    workspaceObservers[state.id] = state.workspace.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.scheduleSessionPersistence() }
    }

    if window.isKeyWindow || activeWindowID == nil {
      activeWindowID = state.id
    }

    if !pendingExternalURLs.isEmpty {
      let queued = pendingExternalURLs
      pendingExternalURLs.removeAll(keepingCapacity: true)
      openExternalURLs(queued)
    }
  }

  func activateWindow(_ id: UUID) {
    guard windowStates[id] != nil else { return }
    activeWindowID = id
  }

  func unregisterWindow(_ id: UUID) {
    windowStates[id] = nil
    nativeWindows[id] = nil
    ownedWindowControllers[id] = nil
    workspaceObservers[id] = nil
    scheduleSessionPersistence()
    guard activeWindowID == id else { return }

    if let keyWindow = NSApplication.shared.keyWindow,
      let next = nativeWindows.first(where: { $0.value.window === keyWindow })?.key
    {
      activeWindowID = next
    } else {
      activeWindowID = windowStates.keys.first
    }
  }

  @discardableResult
  func joinAsNativeTabIfNeeded(window: NSWindow, state: BrowserWindowState) -> Bool {
    guard let parentID = state.parentWindowID else { return true }
    guard let requestedParent = nativeWindows[parentID]?.window, requestedParent !== window else {
      return false
    }

    // Attach directly to the requested visible tab group. New tabs are created
    // as hidden AppKit windows, so this path never exposes a provisional window.
    let host = requestedParent.tabGroup?.selectedWindow ?? requestedParent
    let hostFrame = host.frame

    if host.tabbedWindows?.contains(where: { $0 === window }) != true {
      window.orderOut(nil)
      window.setFrame(hostFrame, display: false)
      host.addTabbedWindow(window, ordered: .above)
    }

    let group = host.tabGroup ?? window.tabGroup

    // Keep the existing group's placement and select only the newly added tab.
    window.setFrame(hostFrame, display: false)
    requestedParent.setFrame(hostFrame, display: false)
    window.makeKeyAndOrderFront(nil)
    group?.selectedWindow = window

    activeWindowID = state.id
    return true
  }

  func presentServerEditor(profile: ServerProfile = .blank) {
    openServerEditor?(profile)
  }

  func presentInspector(for url: URL) {
    openInspector?(NafiURL.normalized(url))
  }

  func start() async {
    if let startupTask {
      await startupTask.value
      return
    }

    let task = Task { @MainActor [defaultFileManager, cloudStorage, serverManager] in
      defaultFileManager.refresh()
      cloudStorage.refresh()
      serverManager.refreshMountedVolumes()
      await RcloneRuntime.shared.setOAuthTokenUpdateHandler { [weak serverManager] profileID, token in
        guard let serverManager else { return }
        try await serverManager.persistOAuthToken(token, for: profileID)
      }
      do { try await RcloneRuntime.shared.start() } catch {
        self.presentationErrorMessage = error.localizedDescription
      }
      await serverManager.connectAutoProfiles()
      await serverManager.configureFileProviderProfiles(systemIntegration.fileProviderProfileIDs)
      let recoveryWarnings = await UnifiedFileSystemService.recoverPendingRemoteOperations()
      if !recoveryWarnings.isEmpty {
        self.presentationErrorMessage = recoveryWarnings.joined(separator: "\n\n")
      }
      await TransferQueue.shared.start()
      syncManager.startScheduling()
      systemIntegration.refresh()
      restoreRemainingSessionTabsIfNeeded()
    }
    startupTask = task
    await task.value
  }

  func configureGlobalQuickOpen() {
    let enabled = UserDefaults.standard.object(forKey: "Nafi.globalQuickOpen") as? Bool ?? true
    GlobalHotKeyService.shared.configure(enabled: enabled) { [weak self] in
      self?.presentQuickOpen()
    }
  }


  func handleExternalCommand(_ command: NafiExternalCommand) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    switch command {
    case .quickOpen:
      presentQuickOpen()
    case .sync(let profile):
      guard let profile else {
        isSyncCenterPresented = true
        return
      }
      guard syncManager.runProfile(matching: profile) else {
        presentationErrorMessage = "同期設定「\(profile)」が見つかりません。同期名またはUUIDを確認してください。"
        isSyncCenterPresented = true
        return
      }
    case .syncCenter:
      isSyncCenterPresented = true
    case .dropStack:
      openDropStack?()
    case .workspaces:
      isWorkspaceLibraryPresented = true
    }
  }

  func presentQuickOpen() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    quickOpenModel.prepare(
      currentURL: activeModel.currentURL,
      favorites: sidebarModel.favorites,
      servers: serverManager.profiles,
      workspaces: workspaceLibrary.named
    )
    isQuickOpenPresented = true
  }

  func openQuickOpenResult(_ result: QuickOpenResult) {
    switch result.action {
    case .restoreWorkspace(let id):
      guard let snapshot = workspaceLibrary.named.first(where: { $0.id == id }) else {
        presentationErrorMessage = "ワークスペースが見つかりません。"
        return
      }
      restoreWorkspace(snapshot)

    case .open(let url):
      let normalized = NafiURL.normalized(url)
      if normalized.isFileURL {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: normalized.path, isDirectory: &directory), !directory.boolValue {
          activeModel.revealExternalItem(normalized)
          return
        }
      }
      activeModel.navigate(to: normalized)
    }
  }

  func addSelectionToDropStack() {
    let urls = activeModel.selectedItems.map(\.url)
    guard !urls.isEmpty else {
      presentationErrorMessage = "Drop Stackへ追加する項目を選択してください。"
      return
    }
    dropStack.add(urls)
  }

  func saveNamedWorkspace(_ name: String) {
    workspaceLibrary.saveNamed(name: name, workspace: workspace)
  }

  func restoreWorkspace(_ snapshot: WorkspaceSnapshot) {
    workspace.replace(with: snapshot)
    scheduleSessionPersistence()
  }

  private func restoreRemainingSessionTabsIfNeeded() {
    guard !didRestoreSessionTabs, let parentID = activeWindowState?.id else { return }
    didRestoreSessionTabs = true
    for snapshot in workspaceLibrary.consumeRemainingRestoration() {
      let active = snapshot.panes.first(where: { $0.id == snapshot.activePaneID }) ?? snapshot.panes.first
      let location = active?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
      createNativeTab(for: NativeTabRequest(
        location: location,
        parentWindowID: parentID,
        workspaceSnapshot: snapshot
      ))
    }
  }

  private func scheduleSessionPersistence() {
    sessionPersistenceTask?.cancel()
    sessionPersistenceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.persistOpenWorkspaces() }
    }
  }

  private func persistOpenWorkspaces() {
    let ordered = nativeWindows.compactMap { id, box -> (Int, WorkspaceModel)? in
      guard let window = box.window, let state = windowStates[id] else { return nil }
      let order = NSApplication.shared.orderedWindows.firstIndex(where: { $0 === window }) ?? Int.max
      return (order, state.workspace)
    }.sorted { $0.0 < $1.0 }.map(\.1)
    workspaceLibrary.saveLastSession(ordered.isEmpty ? [workspace] : ordered)
  }

  func openInNewPane(_ url: URL) {
    workspace.openInNewPane(url)
  }

  /// Opens a location in a real macOS window tab, not in an app-drawn tab strip.
  func openInNewTab(_ url: URL) {
    openURLInNativeTab(url)
  }

  func newNativeTab() {
    openURLInNativeTab(activeModel.currentURL)
  }

  func closeActiveNativeTab() {
    NSApplication.shared.keyWindow?.performClose(nil)
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
    let parent =
      NafiURL.isRemote(url)
      ? NafiURL.parent(of: url)
      : url.deletingLastPathComponent().standardizedFileURL

    let states = Array(windowStates.values) + [fallbackWindowState]
    for model in states.flatMap({ $0.workspace.allModels })
    where NafiURL.sameLocation(model.currentURL, parent) {
      model.load()
    }
  }

  func openExternalURLs(_ urls: [URL]) {
    let normalized =
      urls
      .map { $0.resolvingSymlinksInPath().standardizedFileURL }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !normalized.isEmpty else { return }

    guard let targetState = activeWindowState else {
      pendingExternalURLs.append(contentsOf: normalized)
      reusePristineWindowForNextExternalOpen = true
      return
    }

    NSApplication.shared.activate(ignoringOtherApps: true)

    let configuredBehavior =
      UserDefaults.standard.string(forKey: "Nafi.externalOpenBehavior")
      .flatMap(ExternalOpenBehavior.init(rawValue:)) ?? .newTab

    let mayReuseLaunchWindow = reusePristineWindowForNextExternalOpen
    reusePristineWindowForNextExternalOpen = false

    for (index, url) in normalized.enumerated() {
      let shouldReuseInitialWindow =
        mayReuseLaunchWindow && index == 0 && targetState.isPristineHomeWindow

      let behavior: ExternalOpenBehavior
      if shouldReuseInitialWindow {
        behavior = .currentTab
      } else if index > 0 {
        // Multiple Finder selections should never overwrite one another.
        behavior = .newTab
      } else {
        behavior = configuredBehavior
      }
      openExternalURL(url, behavior: behavior, targetState: targetState)
    }

  }

  private func openExternalURL(
    _ url: URL,
    behavior: ExternalOpenBehavior,
    targetState: BrowserWindowState
  ) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else { return }

    switch behavior {
    case .currentTab:
      activateWindow(targetState.id)
      if isDirectory.boolValue {
        targetState.activeModel.navigate(to: url)
      } else {
        targetState.activeModel.revealExternalItem(url)
      }
    case .newTab:
      openURLInNativeTab(url, parentWindowID: targetState.id)
    }
  }

  private func openURLInNativeTab(_ url: URL, parentWindowID: UUID? = nil) {
    let normalized = NafiURL.normalized(url)
    let parentID = parentWindowID ?? activeWindowState?.id
    let request: NativeTabRequest

    if normalized.isFileURL {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        request = NativeTabRequest(
          location: normalized.deletingLastPathComponent(),
          revealURL: normalized,
          parentWindowID: parentID
        )
      } else {
        request = NativeTabRequest(location: normalized, parentWindowID: parentID)
      }
    } else {
      request = NativeTabRequest(location: normalized, parentWindowID: parentID)
    }

    createNativeTab(for: request)
  }

  private func createNativeTab(for request: NativeTabRequest) {
    guard
      let parentID = request.parentWindowID,
      let requestedParent = nativeWindows[parentID]?.window
    else {
      // Finder events received during launch are queued until the initial
      // browser window registers, so this is only a closed-window fallback.
      createStandaloneBrowserWindow(for: request)
      return
    }

    let state = BrowserWindowState(request: request)
    let rootView = BrowserWindowView(appState: self, windowState: state)
      .environmentObject(self)
    let hostingController = NSHostingController(rootView: rootView)
    let window = makeBrowserWindow(contentViewController: hostingController)
    let controller = NSWindowController(window: window)
    ownedWindowControllers[state.id] = controller

    register(window: window, for: state)
    state.start()

    let host = requestedParent.tabGroup?.selectedWindow ?? requestedParent
    let hostFrame = host.frame
    window.setFrame(hostFrame, display: false)
    host.addTabbedWindow(window, ordered: .above)

    requestedParent.setFrame(hostFrame, display: false)
    window.setFrame(hostFrame, display: false)
    window.makeKeyAndOrderFront(nil)
    (host.tabGroup ?? window.tabGroup)?.selectedWindow = window
    activeWindowID = state.id
  }

  private func createStandaloneBrowserWindow(for request: NativeTabRequest) {
    let state = BrowserWindowState(request: request)
    let rootView = BrowserWindowView(appState: self, windowState: state)
      .environmentObject(self)
    let hostingController = NSHostingController(rootView: rootView)
    let window = makeBrowserWindow(contentViewController: hostingController)
    let controller = NSWindowController(window: window)
    ownedWindowControllers[state.id] = controller

    register(window: window, for: state)
    state.start()
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    activeWindowID = state.id
  }

  private func makeBrowserWindow(
    contentViewController: NSViewController
  ) -> NSWindow {
    let window = NSWindow(contentViewController: contentViewController)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.minSize = NSSize(width: 640, height: 420)
    window.setContentSize(NSSize(width: 1080, height: 680))
    window.title = "nafi"
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "app.nafi.filemanager.browser"
    window.isReleasedWhenClosed = false
    return window
  }
}

private final class WeakWindowBox {
  weak var window: NSWindow?

  init(_ window: NSWindow) {
    self.window = window
  }
}
