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

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.servicesProvider = serviceProvider
    NSUpdateDynamicServices()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      ExternalOpenRouter.shared.submit(urls)
      application.activate(ignoringOtherApps: true)
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
    case .currentTab: "現在のタブで開く"
    case .newTab: "新しいタブで開く"
    }
  }
}
