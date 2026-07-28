import AppKit
import UniformTypeIdentifiers

@MainActor
final class OpenWithApplicationCache {
  static let shared = OpenWithApplicationCache()

  private var cache: [String: [URL]] = [:]

  func applications(for item: FileItem) -> [URL] {
    let key =
      item.isDirectory
      ? "public.folder"
      : (item.contentTypeIdentifier ?? item.url.pathExtension.lowercased())
    if let cached = cache[key] { return cached }

    var candidates =
      item.url.isFileURL
      ? NSWorkspace.shared.urlsForApplications(toOpen: item.url)
      : []
    if item.isDirectory {
      candidates.append(contentsOf: NSWorkspace.shared.urlsForApplications(toOpen: .folder))
    } else if let identifier = item.contentTypeIdentifier, let type = UTType(identifier) {
      candidates.append(contentsOf: NSWorkspace.shared.urlsForApplications(toOpen: type))
    }

    var seen = Set<URL>()
    let result =
      candidates
      .filter { seen.insert($0.standardizedFileURL).inserted }
      .sorted {
        $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
          $1.deletingPathExtension().lastPathComponent
        ) == .orderedAscending
      }
    cache[key] = result
    return result
  }

  func defaultApplication(for item: FileItem) -> URL? {
    if item.url.isFileURL {
      return NSWorkspace.shared.urlForApplication(toOpen: item.url)?.standardizedFileURL
    }
    guard let identifier = item.contentTypeIdentifier, let type = UTType(identifier) else {
      return nil
    }
    return NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL
  }

  func chooseApplication() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "アプリケーションを選択"
    panel.prompt = "選択"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
  }

  func chooseApplicationAndOpen(_ url: URL) {
    guard let applicationURL = chooseApplication() else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open(
      [url],
      withApplicationAt: applicationURL,
      configuration: configuration,
      completionHandler: nil
    )
  }

  func setDefaultApplication(
    _ applicationURL: URL,
    forFileAt fileURL: URL
  ) async throws {
    try await NSWorkspace.shared.setDefaultApplication(
      at: applicationURL,
      toOpenFileAt: fileURL
    )
  }

  func setDefaultApplicationForMatchingExtension(
    _ applicationURL: URL,
    fileURL: URL
  ) async throws {
    let pathExtension = fileURL.pathExtension
    guard !pathExtension.isEmpty, let contentType = UTType(filenameExtension: pathExtension) else {
      throw DefaultApplicationError.extensionUnavailable
    }
    try await NSWorkspace.shared.setDefaultApplication(
      at: applicationURL,
      toOpen: contentType
    )
  }
}

enum DefaultApplicationError: LocalizedError {
  case extensionUnavailable

  var errorDescription: String? {
    switch self {
    case .extensionUnavailable:
      "この項目には一括変更に使える拡張子がありません。"
    }
  }
}
