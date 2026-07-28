import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
  let url: URL
  let name: String
  let isDirectory: Bool
  let isPackage: Bool
  let isHidden: Bool
  let fileSize: Int64?
  let creationDate: Date?
  let modificationDate: Date?
  let contentTypeIdentifier: String?
  let tagNames: [String]

  // Frequently rendered and sorted values are prepared once during enumeration.
  let kindLabel: String
  let sizeLabel: String
  let modifiedLabel: String
  let normalizedName: String
  let normalizedKind: String

  var id: URL { url }

  init(
    url: URL,
    name: String,
    isDirectory: Bool,
    isPackage: Bool,
    isHidden: Bool,
    fileSize: Int64?,
    creationDate: Date?,
    modificationDate: Date?,
    contentTypeIdentifier: String?,
    tagNames: [String]
  ) {
    self.url = url
    self.name = name
    self.isDirectory = isDirectory
    self.isPackage = isPackage
    self.isHidden = isHidden
    self.fileSize = fileSize
    self.creationDate = creationDate
    self.modificationDate = modificationDate
    self.contentTypeIdentifier = contentTypeIdentifier
    self.tagNames = tagNames

    let kind: String
    if isDirectory {
      kind = isPackage ? "パッケージ" : "フォルダ"
    } else if let identifier = contentTypeIdentifier,
      let type = UTType(identifier)
    {
      kind = type.localizedDescription ?? type.identifier
    } else {
      kind = "ファイル"
    }
    kindLabel = kind

    if !isDirectory, let fileSize {
      sizeLabel = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    } else {
      sizeLabel = "—"
    }

    if let modificationDate {
      modifiedLabel = modificationDate.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened)
          .locale(Locale(identifier: "ja_JP"))
      )
    } else {
      modifiedLabel = "—"
    }

    normalizedName = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )
    normalizedKind = kind.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )
  }

  @MainActor
  var icon: NSImage {
    FileIconCache.shared.icon(for: self)
  }

  static func make(from url: URL) -> FileItem? {
    guard url.isFileURL || url.scheme == nil else { return nil }
    guard let values = try? url.resourceValues(forKeys: FileSystemService.resourceKeys)
    else { return nil }
    let name = values.name ?? url.lastPathComponent
    return FileItem(
      url: url,
      name: name,
      isDirectory: values.isDirectory == true,
      isPackage: values.isPackage == true,
      isHidden: values.isHidden == true || name.hasPrefix("."),
      fileSize: values.fileSize.map(Int64.init),
      creationDate: values.creationDate,
      modificationDate: values.contentModificationDate,
      contentTypeIdentifier: values.contentType?.identifier,
      tagNames: values.tagNames ?? []
    )
  }
}

enum FileSort: String, CaseIterable, Identifiable, Sendable {
  case name
  case modified
  case size
  case kind

  var id: String { rawValue }
  var label: String {
    switch self {
    case .name: "名前"
    case .modified: "更新日"
    case .size: "サイズ"
    case .kind: "種類"
    }
  }
}

enum FileViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case list
  case matrix
  case columns
  case gallery

  var id: String { rawValue }

  var label: String {
    switch self {
    case .list: "リスト"
    case .matrix: "マトリクス"
    case .columns: "カラム"
    case .gallery: "ギャラリー"
    }
  }

  var systemImage: String {
    switch self {
    case .list: "list.bullet"
    case .matrix: "square.grid.3x3"
    case .columns: "rectangle.split.3x1"
    case .gallery: "rectangle.on.rectangle.angled"
    }
  }
}

@MainActor
private final class FileIconCache {
  static let shared = FileIconCache()

  private let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 768
    cache.totalCostLimit = 48 * 1_024 * 1_024
    return cache
  }()

  func icon(for item: FileItem) -> NSImage {
    let key: NSString
    if item.isPackage {
      key = "path:\(item.url.path)" as NSString
    } else if item.isDirectory {
      key = "type:public.folder" as NSString
    } else if let identifier = item.contentTypeIdentifier {
      key = "type:\(identifier)" as NSString
    } else {
      key = "ext:\(item.url.pathExtension.lowercased())" as NSString
    }

    if let cached = cache.object(forKey: key) { return cached }

    let icon: NSImage
    if item.isPackage {
      icon = NSWorkspace.shared.icon(forFile: item.url.path)
    } else if item.isDirectory {
      icon = NSWorkspace.shared.icon(for: .folder)
    } else if let identifier = item.contentTypeIdentifier,
      let contentType = UTType(identifier)
    {
      icon = NSWorkspace.shared.icon(for: contentType)
    } else if let inferredType = UTType(filenameExtension: item.url.pathExtension) {
      icon = NSWorkspace.shared.icon(for: inferredType)
    } else {
      icon = NSWorkspace.shared.icon(for: .data)
    }

    cache.setObject(icon, forKey: key, cost: 64 * 64 * 4)
    return icon
  }
}
