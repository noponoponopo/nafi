import Foundation
import UniformTypeIdentifiers

enum FileSearchFilterMode: String, CaseIterable, Identifiable, Sendable {
  case all
  case folders
  case kinds
  case extensions

  var id: String { rawValue }

  var label: String {
    switch self {
    case .all: "すべて"
    case .folders: "フォルダのみ"
    case .kinds: "指定した種類"
    case .extensions: "拡張子を指定"
    }
  }

  var systemImage: String {
    switch self {
    case .all: "square.grid.2x2"
    case .folders: "folder"
    case .kinds: "doc.on.doc"
    case .extensions: "character.cursor.ibeam"
    }
  }
}

enum FileSearchKind: String, CaseIterable, Identifiable, Hashable, Sendable {
  case images
  case video
  case audio
  case pdf
  case documents
  case sourceCode
  case archives

  var id: String { rawValue }

  var label: String {
    switch self {
    case .images: "画像"
    case .video: "動画"
    case .audio: "オーディオ"
    case .pdf: "PDF"
    case .documents: "書類・テキスト"
    case .sourceCode: "ソースコード"
    case .archives: "アーカイブ"
    }
  }

  var systemImage: String {
    switch self {
    case .images: "photo"
    case .video: "film"
    case .audio: "waveform"
    case .pdf: "doc.richtext"
    case .documents: "doc.text"
    case .sourceCode: "chevron.left.forwardslash.chevron.right"
    case .archives: "archivebox"
    }
  }

  func matches(_ item: FileItem) -> Bool {
    guard !item.isDirectory else { return false }
    let matchesKnownExtension = fallbackExtensions.contains(item.url.pathExtension.lowercased())
    guard let type = contentType(for: item) else {
      return matchesKnownExtension
    }

    switch self {
    case .images:
      return matchesKnownExtension || type.conforms(to: .image)
    case .video:
      return matchesKnownExtension || type.conforms(to: .movie) || type.conforms(to: .video)
    case .audio:
      return matchesKnownExtension || type.conforms(to: .audio)
    case .pdf:
      return matchesKnownExtension || type.conforms(to: .pdf)
    case .documents:
      return matchesKnownExtension
        || (type.conforms(to: .text) && !type.conforms(to: .sourceCode))
        || type.conforms(to: .rtf)
        || type.conforms(to: .spreadsheet)
        || type.conforms(to: .presentation)
    case .sourceCode:
      return matchesKnownExtension || type.conforms(to: .sourceCode)
    case .archives:
      return matchesKnownExtension || type.conforms(to: .archive)
    }
  }

  private func contentType(for item: FileItem) -> UTType? {
    if let identifier = item.contentTypeIdentifier, let type = UTType(identifier) {
      return type
    }
    let fileExtension = item.url.pathExtension
    return fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
  }

  private var fallbackExtensions: Set<String> {
    switch self {
    case .images:
      ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "svg", "raw"]
    case .video:
      ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpeg", "mpg"]
    case .audio:
      ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]
    case .pdf:
      ["pdf"]
    case .documents:
      [
        "txt", "md", "rtf", "pages", "doc", "docx", "xls", "xlsx", "numbers", "ppt", "pptx", "key",
        "csv", "tsv",
      ]
    case .sourceCode:
      [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "py", "rb",
        "rs", "go", "java", "kt", "kts", "sh", "zsh", "fish", "html", "css", "scss", "json", "yaml",
        "yml", "toml", "xml",
      ]
    case .archives:
      ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
    }
  }
}

struct FileSearchFilter: Equatable, Sendable {
  let mode: FileSearchFilterMode
  let kinds: Set<FileSearchKind>
  let extensions: Set<String>

  static let all = FileSearchFilter(mode: .all, kinds: [], extensions: [])

  func matches(_ item: FileItem) -> Bool {
    switch mode {
    case .all:
      return true
    case .folders:
      return item.isDirectory && !item.isPackage
    case .kinds:
      return !kinds.isEmpty && kinds.contains { $0.matches(item) }
    case .extensions:
      guard !item.isDirectory else { return false }
      return !extensions.isEmpty && extensions.contains(item.url.pathExtension.lowercased())
    }
  }

  var summary: String {
    switch mode {
    case .all:
      return "すべて"
    case .folders:
      return "フォルダのみ"
    case .kinds:
      let labels = FileSearchKind.allCases.filter(kinds.contains).map(\.label)
      return labels.isEmpty ? "種類未選択" : labels.joined(separator: "・")
    case .extensions:
      return extensions.isEmpty
        ? "拡張子未指定" : extensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }
  }

  static func parseExtensions(_ text: String) -> Set<String> {
    let separators = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ",;、，"))
    return Set(
      text.components(separatedBy: separators)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        .filter { !$0.isEmpty }
    )
  }
}
