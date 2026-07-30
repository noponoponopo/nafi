import CryptoKit
import Foundation

enum FileIntegrityError: LocalizedError {
  case itemMissing(String)
  case unsupportedItem(String)
  case itemLimitExceeded(Int)
  case checksumMismatch(String)
  case sizeMismatch(expected: UInt64, actual: UInt64, item: String)

  var errorDescription: String? {
    switch self {
    case .itemMissing(let item):
      "検証対象が見つかりません: \(item)"
    case .unsupportedItem(let item):
      "検証できない種類の項目です: \(item)"
    case .itemLimitExceeded(let limit):
      "検証対象が\(limit)項目を超えています。対象を分割してください。"
    case .checksumMismatch(let item):
      "転送後のチェックサムが一致しません: \(item)"
    case .sizeMismatch(let expected, let actual, let item):
      "転送後のサイズが一致しません: \(item)（期待値 \(expected) バイト、実際 \(actual) バイト）"
    }
  }
}

enum FileIntegrityService {
  private static let maximumDirectoryEntries = 1_000_000
  private static let resourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
  ]

  static func verifyEquivalent(_ lhs: URL, _ rhs: URL) throws {
    let left = try fingerprint(of: lhs)
    let right = try fingerprint(of: rhs)
    guard left == right else {
      throw FileIntegrityError.checksumMismatch(rhs.lastPathComponent)
    }
  }

  static func verifySize(of url: URL, expected: UInt64?) throws {
    guard let expected else { return }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    guard values.isDirectory != true else { return }
    let actual = UInt64(max(values.fileSize ?? 0, 0))
    guard actual == expected else {
      throw FileIntegrityError.sizeMismatch(
        expected: expected,
        actual: actual,
        item: url.lastPathComponent
      )
    }
  }

  static func fingerprint(of url: URL) throws -> String {
    if Task.isCancelled { throw CancellationError() }
    let normalized = url.standardizedFileURL
    guard FileManager.default.fileExists(atPath: normalized.path) else {
      throw FileIntegrityError.itemMissing(normalized.path)
    }

    let values = try normalized.resourceValues(forKeys: resourceKeys)
    var hasher = SHA256()

    if values.isSymbolicLink == true {
      update(&hasher, marker: "symlink")
      update(
        &hasher,
        value: try FileManager.default.destinationOfSymbolicLink(atPath: normalized.path)
      )
      return hex(hasher.finalize())
    }

    if values.isDirectory == true {
      update(&hasher, marker: "directory-root")
      try fingerprintDirectory(normalized, hasher: &hasher)
      return hex(hasher.finalize())
    }

    guard values.isRegularFile == true || values.isRegularFile == nil else {
      throw FileIntegrityError.unsupportedItem(normalized.path)
    }
    update(&hasher, marker: "file-root")
    try updateFileContents(normalized, hasher: &hasher)
    return hex(hasher.finalize())
  }

  private static func fingerprintDirectory(_ root: URL, hasher: inout SHA256) throws {
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw FileIntegrityError.itemMissing(root.path)
    }

    var entries: [URL] = []
    for case let entry as URL in enumerator {
      if Task.isCancelled { throw CancellationError() }
      entries.append(entry)
      guard entries.count <= maximumDirectoryEntries else {
        throw FileIntegrityError.itemLimitExceeded(maximumDirectoryEntries)
      }
      if let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink == true
      {
        enumerator.skipDescendants()
      }
    }
    if let enumerationError { throw enumerationError }
    entries.sort { relativePath(of: $0, from: root) < relativePath(of: $1, from: root) }

    for entry in entries {
      if Task.isCancelled { throw CancellationError() }
      let relative = relativePath(of: entry, from: root)
      let values = try entry.resourceValues(forKeys: resourceKeys)
      update(&hasher, value: relative)

      if values.isSymbolicLink == true {
        update(&hasher, marker: "symlink")
        update(
          &hasher,
          value: try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        )
      } else if values.isDirectory == true {
        update(&hasher, marker: "directory")
      } else if values.isRegularFile == true || values.isRegularFile == nil {
        update(&hasher, marker: "file")
        try updateFileContents(entry, hasher: &hasher)
      } else {
        throw FileIntegrityError.unsupportedItem(entry.path)
      }
    }
  }

  private static func updateFileContents(_ url: URL, hasher: inout SHA256) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    while true {
      if Task.isCancelled { throw CancellationError() }
      let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
  }

  private static func update(_ hasher: inout SHA256, marker: String) {
    update(&hasher, value: "type:\(marker)")
  }

  private static func update(_ hasher: inout SHA256, value: String) {
    let data = Data(value.utf8)
    var length = UInt64(data.count).bigEndian
    let lengthData = withUnsafeBytes(of: &length) { Data($0) }
    hasher.update(data: lengthData)
    hasher.update(data: data)
  }

  private static func relativePath(of url: URL, from root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "" }
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard path.hasPrefix(prefix) else { return path }
    return String(path.dropFirst(prefix.count))
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
