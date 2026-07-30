import AppKit
import Foundation

@MainActor
enum NafiExternalCommand: Equatable {
  case quickOpen
  case sync(profile: String?)
  case syncCenter
  case dropStack
  case workspaces

  init?(url: URL) {
    guard url.scheme?.lowercased() == "nafi" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
    switch command {
    case "quick-open": self = .quickOpen
    case "sync":
      let profile = components?.queryItems?.first(where: { $0.name == "profile" })?.value
      self = .sync(profile: profile?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    case "sync-center": self = .syncCenter
    case "drop-stack": self = .dropStack
    case "workspaces": self = .workspaces
    default: return nil
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
final class ExternalOpenRouter {
  static let shared = ExternalOpenRouter()

  private var pendingURLs: [URL] = []
  private var pendingCommands: [NafiExternalCommand] = []
  private var fileHandler: (([URL]) -> Void)?
  private var commandHandler: ((NafiExternalCommand) -> Void)?

  private init() {}

  func connect(_ handler: @escaping ([URL]) -> Void) {
    fileHandler = handler
    guard !pendingURLs.isEmpty else { return }
    let queued = pendingURLs
    pendingURLs.removeAll(keepingCapacity: true)
    handler(queued)
  }

  func connectCommands(_ handler: @escaping (NafiExternalCommand) -> Void) {
    commandHandler = handler
    guard !pendingCommands.isEmpty else { return }
    let queued = pendingCommands
    pendingCommands.removeAll(keepingCapacity: true)
    queued.forEach(handler)
  }

  func submit(_ urls: [URL]) {
    let commands = urls.compactMap(NafiExternalCommand.init(url:))
    let fileURLs = urls.filter(\.isFileURL)

    if !fileURLs.isEmpty {
      if let fileHandler { fileHandler(fileURLs) }
      else { pendingURLs.append(contentsOf: fileURLs) }
    }

    for command in commands {
      if let commandHandler { commandHandler(command) }
      else { pendingCommands.append(command) }
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
  private var isBackgroundLaunch: Bool { ProcessInfo.processInfo.arguments.contains("--background") }

  func applicationWillFinishLaunching(_ notification: Notification) {
    // The macOS window tab bar is nafi's only tab UI. nafi groups windows
    // explicitly so a Finder open never creates a second, temporary tab group.
    NSWindow.allowsAutomaticWindowTabbing = false
    if isBackgroundLaunch { NSApplication.shared.setActivationPolicy(.accessory) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.servicesProvider = serviceProvider
    NSUpdateDynamicServices()
    if isBackgroundLaunch {
      DispatchQueue.main.async {
        NSApplication.shared.windows.forEach { $0.orderOut(nil) }
      }
    }

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
