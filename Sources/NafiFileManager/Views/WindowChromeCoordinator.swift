import AppKit
import SwiftUI

/// Connects each SwiftUI browser scene to a real NSWindow. The NSWindow title
/// is the native tab title, and every browser window opts into macOS tabbing.
struct ActiveWindowChromeCoordinator: View {
  @ObservedObject var appState: AppState
  @ObservedObject var windowState: BrowserWindowState

  var body: some View {
    ActiveWindowChromeContent(
      appState: appState,
      windowState: windowState,
      workspace: windowState.workspace
    )
  }
}

private struct ActiveWindowChromeContent: View {
  @ObservedObject var appState: AppState
  @ObservedObject var windowState: BrowserWindowState
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    WindowChromeCoordinator(
      appState: appState,
      windowState: windowState,
      model: workspace.activeModel
    )
  }
}

private struct WindowChromeCoordinator: View {
  @ObservedObject var appState: AppState
  @ObservedObject var windowState: BrowserWindowState
  @ObservedObject var model: FilePaneModel

  var body: some View {
    WindowChromeBridge(
      appState: appState,
      windowState: windowState,
      title: model.title,
      representedURL: model.isRemote ? nil : model.currentURL
    )
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

private struct WindowChromeBridge: NSViewRepresentable {
  let appState: AppState
  let windowState: BrowserWindowState
  let title: String
  let representedURL: URL?

  func makeCoordinator() -> Coordinator {
    Coordinator(appState: appState, windowState: windowState)
  }

  func makeNSView(context: Context) -> WindowAttachmentView {
    let view = WindowAttachmentView()
    view.onWindowChange = { [weak coordinator = context.coordinator] window in
      if let window { coordinator?.attach(to: window) }
    }
    return view
  }

  func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
    context.coordinator.update(title: title, representedURL: representedURL)
    if let window = nsView.window { context.coordinator.attach(to: window) }
  }

  @MainActor
  final class Coordinator {
    private weak var appState: AppState?
    private weak var windowState: BrowserWindowState?
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var title = "nafi"
    private var representedURL: URL?

    init(appState: AppState, windowState: BrowserWindowState) {
      self.appState = appState
      self.windowState = windowState
    }

    deinit {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func update(title: String, representedURL: URL?) {
      self.title = title
      self.representedURL = representedURL
      applyMetadata()
    }

    func attach(to window: NSWindow) {
      guard self.window !== window else {
        applyMetadata()
        return
      }

      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll(keepingCapacity: true)
      self.window = window

      window.tabbingMode = .preferred
      window.tabbingIdentifier = "app.nafi.filemanager.browser"
      applyMetadata()

      guard let appState, let windowState else { return }

      appState.register(window: window, for: windowState)

      let center = NotificationCenter.default
      observers.append(
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main)
        {
          [weak appState, weak windowState] _ in
          guard let id = windowState?.id else { return }
          Task { @MainActor in appState?.activateWindow(id) }
        }
      )
      observers.append(
        center.addObserver(
          forName: NSWindow.didBecomeMainNotification, object: window, queue: .main
        ) {
          [weak appState, weak windowState] _ in
          guard let id = windowState?.id else { return }
          Task { @MainActor in appState?.activateWindow(id) }
        }
      )
      observers.append(
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
          [weak appState, weak windowState] _ in
          guard let id = windowState?.id else { return }
          Task { @MainActor in appState?.unregisterWindow(id) }
        }
      )

      attemptNativeTabJoin()
    }

    private func applyMetadata() {
      guard let window else { return }
      let displayTitle = title.isEmpty ? "nafi" : title
      if window.title != displayTitle { window.title = displayTitle }
      if window.tab.title != displayTitle { window.tab.title = displayTitle }
      let tooltip = representedURL?.path ?? displayTitle
      if window.tab.toolTip != tooltip { window.tab.toolTip = tooltip }
      if window.representedURL != representedURL { window.representedURL = representedURL }
      window.tabbingMode = .preferred
      window.tabbingIdentifier = "app.nafi.filemanager.browser"
    }

    private func attemptNativeTabJoin() {
      guard let appState, let windowState, let window else { return }
      guard windowState.parentWindowID != nil else { return }

      if appState.joinAsNativeTabIfNeeded(window: window, state: windowState) {
        return
      }

      // Browser tabs register synchronously before attachment. A missing parent
      // has closed; present one ordinary window instead of polling the main queue.
      window.makeKeyAndOrderFront(nil)
      appState.activateWindow(windowState.id)
    }
  }
}

/// Keeps utility/settings windows out of the browser's native tab group.
struct WindowTabbingDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowAttachmentView {
    let view = WindowAttachmentView()
    view.onWindowChange = { $0?.tabbingMode = .disallowed }
    return view
  }

  func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
    nsView.window?.tabbingMode = .disallowed
  }
}

final class WindowAttachmentView: NSView {
  var onWindowChange: ((NSWindow?) -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?(window)
  }
}
