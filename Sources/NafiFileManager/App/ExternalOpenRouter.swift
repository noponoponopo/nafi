import AppKit
import Foundation

@MainActor
final class ExternalOpenRouter {
  static let shared = ExternalOpenRouter()

  private var pendingURLs: [URL] = []
  private var handler: (([URL]) -> Void)?

  private init() {}

  func connect(_ handler: @escaping ([URL]) -> Void) {
    self.handler = handler
    guard !pendingURLs.isEmpty else { return }
    let queued = pendingURLs
    pendingURLs.removeAll(keepingCapacity: true)
    handler(queued)
  }

  func submit(_ urls: [URL]) {
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else { return }
    if let handler {
      handler(fileURLs)
    } else {
      pendingURLs.append(contentsOf: fileURLs)
    }
  }
}

final class NafiServiceProvider: NSObject {
  @objc func openInNafi(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL],
      !urls.isEmpty
    else {
      error.pointee = "ファイルまたはフォルダのURLを取得できませんでした。"
      return
    }

    Task { @MainActor in
      ExternalOpenRouter.shared.submit(urls)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }
}

final class NafiAppDelegate: NSObject, NSApplicationDelegate {
  private let serviceProvider = NafiServiceProvider()

  func applicationWillFinishLaunching(_ notification: Notification) {
    // The macOS window tab bar is nafi's only tab UI. nafi groups windows
    // explicitly so a Finder open never creates a second, temporary tab group.
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.servicesProvider = serviceProvider
    NSUpdateDynamicServices()

    // Finder can launch the app with an external file event before SwiftUI
    // creates the browser scene. Use the same native-window path as new tabs
    // only when no browser scene appeared on its own.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard
        !NSApplication.shared.windows.contains(where: {
          $0.title == "nafi" || $0.tabbingIdentifier == "app.nafi.filemanager.browser"
        })
      else { return }
      NativeTabCommandRouter.shared.submit()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      ExternalOpenRouter.shared.submit(urls)
      application.activate(ignoringOtherApps: true)
    }
  }

  func application(_ application: NSApplication, openFiles filenames: [String]) {
    self.application(application, open: filenames.map { URL(fileURLWithPath: $0) })
    application.reply(toOpenOrPrint: .success)
  }

  /// Called by the + button in the native macOS tab bar and by Window > New Tab.
  @IBAction func newWindowForTab(_ sender: Any?) {
    Task { @MainActor in
      NativeTabCommandRouter.shared.submit()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

enum ExternalOpenBehavior: String, CaseIterable, Identifiable {
  case currentTab
  case newTab

  var id: String { rawValue }

  var label: String {
    switch self {
    case .currentTab: "現在のウインドウタブで開く"
    case .newTab: "新しいウインドウタブで開く"
    }
  }
}
