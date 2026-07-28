import AppKit
import Foundation

@MainActor
final class CloudStorageService: ObservableObject {
  @Published private(set) var iCloudDriveURL: URL?
  @Published private(set) var usesUserSelectedLocation = false
  @Published var errorMessage: String?

  private let bookmarkURL = AppStoragePaths.file(named: "icloud-drive.bookmark")
  private var securityScopedURL: URL?
  private var isAccessingSecurityScopedURL = false

  init() {
    refresh()
  }

  deinit {
    if isAccessingSecurityScopedURL {
      securityScopedURL?.stopAccessingSecurityScopedResource()
    }
  }

  var isAvailable: Bool { iCloudDriveURL != nil }

  var statusText: String {
    if let iCloudDriveURL {
      return usesUserSelectedLocation
        ? "選択した場所: \(iCloudDriveURL.path)"
        : "iCloud Driveを利用できます。"
    }
    return "iCloud Driveが見つかりません。macOSでiCloud Driveを有効にするか、場所を選択してください。"
  }

  func refresh() {
    releaseSecurityScopedAccess()

    if let bookmarkedURL = resolveStoredBookmark(), isDirectory(bookmarkedURL) {
      usesUserSelectedLocation = true
      iCloudDriveURL = bookmarkedURL.standardizedFileURL
      beginSecurityScopedAccess(to: bookmarkedURL)
      errorMessage = nil
      return
    }

    if let automaticURL = Self.automaticICloudDriveURL(), isDirectory(automaticURL) {
      usesUserSelectedLocation = false
      iCloudDriveURL = automaticURL.standardizedFileURL
      errorMessage = nil
      return
    }

    usesUserSelectedLocation = false
    iCloudDriveURL = nil
  }

  func chooseICloudDriveLocation() {
    let panel = NSOpenPanel()
    panel.title = "iCloud Driveの場所を選択"
    panel.message = "iCloud Drive本体、またはnafiでクラウドとして表示したいフォルダを選択してください。"
    panel.prompt = "この場所を使用"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    panel.directoryURL =
      Self.automaticICloudDriveURL() ?? FileManager.default.homeDirectoryForCurrentUser

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

    do {
      let data = try selectedURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: [.isDirectoryKey],
        relativeTo: nil
      )
      try data.write(to: bookmarkURL, options: .atomic)
      refresh()
    } catch {
      errorMessage = "iCloud Driveの場所を保存できませんでした: \(error.localizedDescription)"
    }
  }

  func forgetSelectedLocation() {
    try? FileManager.default.removeItem(at: bookmarkURL)
    refresh()
  }

  static func automaticICloudDriveURL() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let cloudDocs =
      home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Mobile Documents", isDirectory: true)
      .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return cloudDocs
  }

  private func resolveStoredBookmark() -> URL? {
    guard let data = try? Data(contentsOf: bookmarkURL) else { return nil }

    do {
      var isStale = false
      let resolvedURL = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      if isStale {
        let refreshed = try resolvedURL.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: [.isDirectoryKey],
          relativeTo: nil
        )
        try refreshed.write(to: bookmarkURL, options: .atomic)
      }
      return resolvedURL
    } catch {
      try? FileManager.default.removeItem(at: bookmarkURL)
      errorMessage = "保存していたiCloud Driveのアクセス情報を読み込めませんでした。"
      return nil
    }
  }

  private func beginSecurityScopedAccess(to url: URL) {
    securityScopedURL = url
    isAccessingSecurityScopedURL = url.startAccessingSecurityScopedResource()
  }

  private func releaseSecurityScopedAccess() {
    if isAccessingSecurityScopedURL {
      securityScopedURL?.stopAccessingSecurityScopedResource()
    }
    securityScopedURL = nil
    isAccessingSecurityScopedURL = false
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
