import Foundation
import UniformTypeIdentifiers

enum QuickEditSupport {
  static let maximumFileSize: Int64 = 8 * 1_024 * 1_024

  private static let textExtensions: Set<String> = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html",
    "htm", "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx", "ts", "tsx",
    "swift", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "py", "rb", "php",
    "java", "kt", "kts", "go", "rs", "sh", "bash", "zsh", "fish", "yaml", "yml",
    "toml", "ini", "cfg", "conf", "config", "properties", "log", "sql", "graphql",
    "gql", "tex", "bib", "gradle", "cmake", "make", "dockerfile", "gitignore",
    "gitattributes", "editorconfig", "env",
  ]

  private static let extensionlessTextNames: Set<String> = [
    "makefile", "dockerfile", "gemfile", "podfile", "rakefile", "license", "readme",
    "changelog", "authors", "contributors", ".gitignore", ".gitattributes", ".editorconfig",
    ".env", ".npmrc", ".yarnrc", ".zshrc", ".bashrc", ".profile",
  ]

  static func isEditable(_ item: FileItem) -> Bool {
    guard !item.isDirectory, !item.isPackage else { return false }
    if let identifier = item.contentTypeIdentifier,
      let type = UTType(identifier),
      isTextType(type)
    {
      return true
    }
    return isKnownTextName(item.url)
  }

  static func isEditable(at url: URL) -> Bool {
    guard url.isFileURL else { return false }
    if let values = try? url.resourceValues(forKeys: [
      .isDirectoryKey, .isPackageKey, .contentTypeKey,
    ]),
      values.isDirectory != true,
      values.isPackage != true,
      let type = values.contentType,
      isTextType(type)
    {
      return true
    }
    return isKnownTextName(url)
  }

  private static func isTextType(_ type: UTType) -> Bool {
    type.conforms(to: .text)
      || type.conforms(to: .sourceCode)
      || type.conforms(to: .json)
      || type.conforms(to: .xml)
  }

  private static func isKnownTextName(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()
    return textExtensions.contains(ext) || extensionlessTextNames.contains(name)
  }
}

enum QuickEditLineEnding: String, Sendable {
  case lineFeed
  case carriageReturnLineFeed
  case carriageReturn

  var separator: String {
    switch self {
    case .lineFeed: "\n"
    case .carriageReturnLineFeed: "\r\n"
    case .carriageReturn: "\r"
    }
  }

  var label: String {
    switch self {
    case .lineFeed: "LF"
    case .carriageReturnLineFeed: "CRLF"
    case .carriageReturn: "CR"
    }
  }
}

struct QuickEditSnapshot: @unchecked Sendable {
  let text: String
  let encodingRawValue: UInt
  let encodingLabel: String
  let lineEnding: QuickEditLineEnding
  let hasByteOrderMark: Bool
  let modificationDate: Date?
  let isWritable: Bool
  let fileSize: Int64
}

enum QuickEditError: LocalizedError, Equatable {
  case unsupported
  case tooLarge(Int64)
  case binaryFile
  case unknownEncoding
  case readFailed
  case notWritable
  case changedExternally

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "このファイルはクイックエディットの対象外です。"
    case .tooLarge(let size):
      "ファイルサイズが大きすぎます（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）。クイックエディットは8 MBまでです。"
    case .binaryFile:
      "バイナリデータが含まれているため、テキストとして編集できません。"
    case .unknownEncoding:
      "文字コードを判定できませんでした。"
    case .readFailed:
      "ファイルを読み込めませんでした。"
    case .notWritable:
      "このファイルには書き込み権限がありません。"
    case .changedExternally:
      "開いた後に別のアプリで変更されています。再読み込みするか、内容を確認して強制保存してください。"
    }
  }
}

struct QuickEditService {
  static func read(_ url: URL) throws -> QuickEditSnapshot {
    guard QuickEditSupport.isEditable(at: url) else { throw QuickEditError.unsupported }

    if FileManager.default.isUbiquitousItem(at: url) {
      try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    var coordinationError: NSError?
    var result: Result<QuickEditSnapshot, Error>?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinatedURL in
      do {
        let values = try coordinatedURL.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey,
        ])
        let size = Int64(values.fileSize ?? 0)
        guard size <= QuickEditSupport.maximumFileSize else {
          throw QuickEditError.tooLarge(size)
        }

        let data = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
        let decoded = try decode(data)
        result = .success(
          QuickEditSnapshot(
            text: decoded.text,
            encodingRawValue: decoded.encoding.rawValue,
            encodingLabel: encodingLabel(decoded.encoding),
            lineEnding: detectLineEnding(in: decoded.text),
            hasByteOrderMark: decoded.hasByteOrderMark,
            modificationDate: values.contentModificationDate,
            isWritable: FileManager.default.isWritableFile(atPath: coordinatedURL.path),
            fileSize: Int64(data.count)
          )
        )
      } catch {
        result = .failure(error)
      }
    }

    if let coordinationError { throw coordinationError }
    guard let result else { throw QuickEditError.readFailed }
    return try result.get()
  }

  static func write(
    _ text: String,
    to url: URL,
    encodingRawValue: UInt,
    lineEnding: QuickEditLineEnding,
    hasByteOrderMark: Bool,
    expectedModificationDate: Date?,
    force: Bool
  ) throws -> Date? {
    let encoding = String.Encoding(rawValue: encodingRawValue)
    let normalizedText = normalizeLineEndings(text, to: lineEnding)
    guard var data = normalizedText.data(using: encoding, allowLossyConversion: false) else {
      throw QuickEditError.unknownEncoding
    }
    if hasByteOrderMark, let mark = byteOrderMark(for: encoding), !data.starts(with: mark) {
      data.insert(contentsOf: mark, at: 0)
    }

    var coordinationError: NSError?
    var result: Result<Date?, Error>?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
      coordinatedURL in
      do {
        guard FileManager.default.isWritableFile(atPath: coordinatedURL.path) else {
          throw QuickEditError.notWritable
        }
        let currentValues = try coordinatedURL.resourceValues(forKeys: [.contentModificationDateKey]
        )
        if !force,
          modificationDatesDiffer(expectedModificationDate, currentValues.contentModificationDate)
        {
          throw QuickEditError.changedExternally
        }

        try data.write(to: coordinatedURL, options: .atomic)

        let updated = try coordinatedURL.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        result = .success(updated)
      } catch {
        result = .failure(error)
      }
    }

    if let coordinationError { throw coordinationError }
    guard let result else { throw QuickEditError.readFailed }
    let modificationDate = try result.get()
    FileSystemService.notifyFileChanged(at: url)
    return modificationDate
  }

  private static func decode(_ data: Data) throws -> (
    text: String, encoding: String.Encoding, hasByteOrderMark: Bool
  ) {
    if data.isEmpty { return ("", .utf8, false) }

    let candidatesWithMarks: [(Data, String.Encoding)] = [
      (Data([0x00, 0x00, 0xFE, 0xFF]), .utf32BigEndian),
      (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian),
      (Data([0xEF, 0xBB, 0xBF]), .utf8),
      (Data([0xFE, 0xFF]), .utf16BigEndian),
      (Data([0xFF, 0xFE]), .utf16LittleEndian),
    ]

    for (mark, encoding) in candidatesWithMarks where data.starts(with: mark) {
      let payload = data.dropFirst(mark.count)
      guard let text = String(data: payload, encoding: encoding) else {
        throw QuickEditError.unknownEncoding
      }
      return (text, encoding, true)
    }

    if let text = String(data: data, encoding: .utf8), looksLikeText(text) {
      return (text, .utf8, false)
    }

    if looksLikeUTF16(data, littleEndian: true),
      let text = String(data: data, encoding: .utf16LittleEndian),
      looksLikeText(text)
    {
      return (text, .utf16LittleEndian, false)
    }
    if looksLikeUTF16(data, littleEndian: false),
      let text = String(data: data, encoding: .utf16BigEndian),
      looksLikeText(text)
    {
      return (text, .utf16BigEndian, false)
    }

    if data.prefix(4096).contains(0) { throw QuickEditError.binaryFile }

    let fallbackEncodings: [String.Encoding] = [
      .shiftJIS, .windowsCP1252, .isoLatin1, .macOSRoman,
    ]
    for encoding in fallbackEncodings {
      if let text = String(data: data, encoding: encoding), looksLikeText(text) {
        return (text, encoding, false)
      }
    }
    throw QuickEditError.unknownEncoding
  }

  private static func looksLikeText(_ text: String) -> Bool {
    guard !text.isEmpty else { return true }
    let sample = text.prefix(8_192)
    var controlCount = 0
    for scalar in sample.unicodeScalars {
      if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" {
        controlCount += 1
      }
    }
    return Double(controlCount) / Double(max(sample.count, 1)) < 0.02
  }

  private static func looksLikeUTF16(_ data: Data, littleEndian: Bool) -> Bool {
    let sample = Array(data.prefix(2_048))
    guard sample.count >= 4 else { return false }
    var expectedZeroCount = 0
    var pairCount = 0
    for index in stride(from: 0, to: sample.count - 1, by: 2) {
      let zeroIndex = littleEndian ? index + 1 : index
      if sample[zeroIndex] == 0 { expectedZeroCount += 1 }
      pairCount += 1
    }
    return pairCount > 0 && Double(expectedZeroCount) / Double(pairCount) > 0.35
  }

  private static func detectLineEnding(in text: String) -> QuickEditLineEnding {
    let crlf = text.components(separatedBy: "\r\n").count - 1
    let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
    let lf = withoutCRLF.filter { $0 == "\n" }.count
    let cr = withoutCRLF.filter { $0 == "\r" }.count
    if crlf >= lf, crlf >= cr, crlf > 0 { return .carriageReturnLineFeed }
    if cr > lf, cr > 0 { return .carriageReturn }
    return .lineFeed
  }

  private static func normalizeLineEndings(
    _ text: String,
    to lineEnding: QuickEditLineEnding
  ) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\n", with: lineEnding.separator)
  }

  private static func modificationDatesDiffer(_ lhs: Date?, _ rhs: Date?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): false
    case (let lhs?, let rhs?): abs(lhs.timeIntervalSince(rhs)) > 0.001
    default: true
    }
  }

  private static func byteOrderMark(for encoding: String.Encoding) -> Data? {
    switch encoding {
    case .utf8: Data([0xEF, 0xBB, 0xBF])
    case .utf16LittleEndian: Data([0xFF, 0xFE])
    case .utf16BigEndian: Data([0xFE, 0xFF])
    case .utf32LittleEndian: Data([0xFF, 0xFE, 0x00, 0x00])
    case .utf32BigEndian: Data([0x00, 0x00, 0xFE, 0xFF])
    default: nil
    }
  }

  private static func encodingLabel(_ encoding: String.Encoding) -> String {
    switch encoding {
    case .utf8: "UTF-8"
    case .utf16LittleEndian: "UTF-16 LE"
    case .utf16BigEndian: "UTF-16 BE"
    case .utf32LittleEndian: "UTF-32 LE"
    case .utf32BigEndian: "UTF-32 BE"
    case .shiftJIS: "Shift JIS"
    case .windowsCP1252: "Windows-1252"
    case .isoLatin1: "ISO Latin 1"
    case .macOSRoman: "Mac Roman"
    default: "文字コード \(encoding.rawValue)"
    }
  }
}
