import Foundation

enum ArchiveService {
  private struct Entry {
    let path: String
    let normalizedKey: String
    let isDirectory: Bool
    let uncompressedSize: UInt64
    let compressedSize: UInt64
  }

  private static let maximumEntryCount = 100_000
  private static let maximumExpandedBytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
  private static let maximumListingBytes: UInt64 = 32 * 1_024 * 1_024
  private static let maximumCompressionRatio: UInt64 = 10_000

  static func extractZIP(at archive: URL, to destination: URL) async throws {
    guard archive.isFileURL, destination.isFileURL else {
      throw FileOperationError.processFailed("ZIP展開にはローカルファイルが必要です。")
    }
    guard archive.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
      throw FileOperationError.processFailed("現在展開できる形式はZIPです。")
    }

    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: archive.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { throw CocoaError(.fileNoSuchFile) }

    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    guard try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty else {
      throw FileOperationError.processFailed("展開先フォルダが空ではありません。")
    }

    let entries = try await inspectZIP(at: archive)
    try ensureCapacity(for: entries, at: destination)
    try Task.checkCancellation()

    let extraction = try await run(
      executable: URL(fileURLWithPath: "/usr/bin/ditto"),
      arguments: ["-x", "-k", archive.path, destination.path],
      captureStandardOutput: false
    )
    guard extraction.terminationStatus == 0 else {
      throw FileOperationError.processFailed(
        errorMessage(from: extraction, fallback: "ZIPの展開に失敗しました。")
      )
    }

    do {
      try validateExtractedTree(at: destination, expectedEntries: entries)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  private static func inspectZIP(at archive: URL) async throws -> [Entry] {
    let namesResult = try await run(
      executable: URL(fileURLWithPath: "/usr/bin/unzip"),
      arguments: ["-Z", "-1", archive.path],
      captureStandardOutput: true
    )
    guard namesResult.terminationStatus == 0 else {
      throw FileOperationError.processFailed(
        errorMessage(from: namesResult, fallback: "ZIPの内容を読み取れませんでした。")
      )
    }
    let names = try readListing(namesResult.stdout)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
    guard !names.isEmpty else {
      throw FileOperationError.processFailed("ZIPに展開できる項目がありません。")
    }
    guard names.count <= maximumEntryCount else {
      throw FileOperationError.processFailed("ZIP内の項目数が安全上の上限を超えています。")
    }

    let metadataResult = try await run(
      executable: URL(fileURLWithPath: "/usr/bin/unzip"),
      arguments: ["-Z", "-l", archive.path],
      captureStandardOutput: true
    )
    guard metadataResult.terminationStatus == 0 else {
      throw FileOperationError.processFailed(
        errorMessage(from: metadataResult, fallback: "ZIPのサイズ情報を読み取れませんでした。")
      )
    }
    let metadataLines = try readListing(metadataResult.stdout)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    var metadata: [(isDirectory: Bool, uncompressed: UInt64, compressed: UInt64)] = []
    metadata.reserveCapacity(names.count)
    for line in metadataLines {
      guard let first = line.first, "-dlbcps".contains(first) else { continue }
      let fields = line.split(maxSplits: 7, whereSeparator: \.isWhitespace)
      guard fields.count >= 7,
        let uncompressed = UInt64(fields[3]),
        let compressed = UInt64(fields[5])
      else {
        throw FileOperationError.processFailed("ZIPのエントリ情報を安全に解析できませんでした。")
      }
      if first == "l" {
        throw FileOperationError.processFailed("シンボリックリンクを含むZIPは安全のため展開できません。")
      }
      metadata.append((first == "d", uncompressed, compressed))
    }
    guard metadata.count == names.count else {
      throw FileOperationError.processFailed("ZIPのエントリ一覧に不整合があります。")
    }

    var seen = Set<String>()
    var entries: [Entry] = []
    entries.reserveCapacity(names.count)
    var totalExpanded: UInt64 = 0
    var totalCompressed: UInt64 = 0

    for (index, rawName) in names.enumerated() {
      let checked = try validateEntryPath(rawName, directoryHint: metadata[index].isDirectory)
      guard seen.insert(checked.key).inserted else {
        throw FileOperationError.processFailed("ZIP内に同一視される重複パスがあります: \(rawName)")
      }
      totalExpanded = try addingWithoutOverflow(totalExpanded, metadata[index].uncompressed)
      totalCompressed = try addingWithoutOverflow(totalCompressed, metadata[index].compressed)
      entries.append(
        Entry(
          path: checked.path,
          normalizedKey: checked.key,
          isDirectory: metadata[index].isDirectory,
          uncompressedSize: metadata[index].uncompressed,
          compressedSize: metadata[index].compressed
        )
      )
    }

    guard totalExpanded <= maximumExpandedBytes else {
      throw FileOperationError.processFailed("ZIPの展開後サイズが安全上の上限を超えています。")
    }
    if totalExpanded > 1_024 * 1_024 {
      guard totalCompressed > 0,
        totalExpanded / max(totalCompressed, 1) <= maximumCompressionRatio
      else {
        throw FileOperationError.processFailed("異常に高い圧縮率のZIPは安全のため展開できません。")
      }
    }

    let directoryKeys = Set(entries.filter(\.isDirectory).map(\.normalizedKey))
    let itemKeys = Set(entries.map(\.normalizedKey))
    for entry in entries {
      let components = entry.normalizedKey.split(separator: "/")
      guard components.count > 1 else { continue }
      for end in 1..<components.count {
        let parent = components.prefix(end).joined(separator: "/")
        if itemKeys.contains(parent), !directoryKeys.contains(parent) {
          throw FileOperationError.processFailed("ZIP内でファイルと子項目のパスが衝突しています。")
        }
      }
    }
    return entries
  }

  static func validateEntryPath(
    _ rawName: String,
    directoryHint: Bool
  ) throws -> (path: String, key: String) {
    guard !rawName.isEmpty,
      !rawName.hasPrefix("/"),
      !rawName.hasPrefix("\\"),
      !rawName.contains("\\"),
      !rawName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw FileOperationError.processFailed("ZIPに危険なパスが含まれています。")
    }

    let withoutTrailingSlash = rawName.hasSuffix("/") ? String(rawName.dropLast()) : rawName
    guard !withoutTrailingSlash.isEmpty else {
      throw FileOperationError.processFailed("ZIPに不正なルート項目があります。")
    }
    let components = withoutTrailingSlash.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty else {
      throw FileOperationError.processFailed("ZIPに不正なパスがあります。")
    }
    if let first = components.first, first.count >= 2,
      first[first.index(after: first.startIndex)] == ":"
    {
      throw FileOperationError.processFailed("ZIPに絶対パスが含まれています。")
    }
    for component in components {
      guard !component.isEmpty, component != ".", component != "..",
        component.utf8.count <= 255
      else {
        throw FileOperationError.processFailed("ZIPに危険または長すぎるパスが含まれています。")
      }
    }
    guard withoutTrailingSlash.utf8.count <= 4_096 else {
      throw FileOperationError.processFailed("ZIPに長すぎるパスが含まれています。")
    }
    if directoryHint != rawName.hasSuffix("/") {
      // Some producers omit the trailing slash for explicit directory records. Trust the mode bit,
      // but still normalize to a single path representation.
    }

    let normalized = withoutTrailingSlash.precomposedStringWithCanonicalMapping
    let key = normalized.folding(
      options: [.caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    return (normalized, key)
  }

  private static func ensureCapacity(for entries: [Entry], at destination: URL) throws {
    let expanded = entries.reduce(UInt64(0)) { partial, entry in
      partial &+ entry.uncompressedSize
    }
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
    if let availableNumber = attributes[.systemFreeSize] as? NSNumber {
      let available = availableNumber.int64Value
      let reserve: Int64 = 256 * 1_024 * 1_024
      let required = Int64(clamping: expanded)
      guard required <= max(0, available - reserve) else {
        throw FileOperationError.processFailed("ZIPを安全に展開するための空き容量が不足しています。")
      }
    }
  }

  private static func validateExtractedTree(at root: URL, expectedEntries: [Entry]) throws {
    let expectedByKey = Dictionary(
      uniqueKeysWithValues: expectedEntries.map { ($0.normalizedKey, $0) })
    var permittedImplicitDirectories = Set<String>()
    for entry in expectedEntries {
      let components = entry.normalizedKey.split(separator: "/")
      guard components.count > 1 else { continue }
      for end in 1..<components.count {
        permittedImplicitDirectories.insert(components.prefix(end).joined(separator: "/"))
      }
    }

    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
        ],
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw FileOperationError.processFailed("展開後の内容を検証できませんでした。")
    }

    let rootComponents = root.standardizedFileURL.pathComponents
    var seenExpectedKeys = Set<String>()
    var actualCount = 0
    var totalSize: UInt64 = 0
    for case let item as URL in enumerator {
      try Task.checkCancellation()
      actualCount += 1
      guard actualCount <= maximumEntryCount + expectedEntries.count else {
        throw FileOperationError.processFailed("展開後の項目数が安全上の上限を超えています。")
      }

      let values = try item.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else {
        throw FileOperationError.processFailed("展開後にシンボリックリンクが検出されました。")
      }
      let actualIsDirectory = values.isDirectory == true
      guard actualIsDirectory || values.isRegularFile == true else {
        throw FileOperationError.processFailed("展開後に通常ファイルでもフォルダでもない項目が検出されました。")
      }

      let itemComponents = item.standardizedFileURL.pathComponents
      guard itemComponents.count > rootComponents.count,
        Array(itemComponents.prefix(rootComponents.count)) == rootComponents
      else {
        throw FileOperationError.processFailed("展開先の外側を指す項目が検出されました。")
      }
      let relativePath = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
      let checked = try validateEntryPath(
        actualIsDirectory ? relativePath + "/" : relativePath,
        directoryHint: actualIsDirectory
      )

      if let expected = expectedByKey[checked.key] {
        guard seenExpectedKeys.insert(checked.key).inserted,
          expected.isDirectory == actualIsDirectory
        else {
          throw FileOperationError.processFailed("展開後の項目種別またはパスに不整合があります。")
        }
        if !actualIsDirectory {
          let actualSize = UInt64(max(values.fileSize ?? 0, 0))
          guard actualSize == expected.uncompressedSize else {
            throw FileOperationError.processFailed("展開後のファイルサイズがZIPの一覧と一致しません。")
          }
          totalSize = try addingWithoutOverflow(totalSize, actualSize)
          guard totalSize <= maximumExpandedBytes else {
            throw FileOperationError.processFailed("展開後サイズが安全上の上限を超えています。")
          }
        }
      } else {
        guard actualIsDirectory, permittedImplicitDirectories.contains(checked.key) else {
          throw FileOperationError.processFailed("ZIPの一覧にない項目が展開されました。")
        }
      }
    }
    if let enumerationError { throw enumerationError }

    let missing = Set(expectedByKey.keys).subtracting(seenExpectedKeys)
    guard missing.isEmpty else {
      throw FileOperationError.processFailed("ZIPの一覧にある項目が展開後に見つかりません。")
    }
  }

  private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
      throw FileOperationError.processFailed("ZIPのサイズ情報が不正です。")
    }
    return result
  }

  private static func run(
    executable: URL,
    arguments: [String],
    captureStandardOutput: Bool
  ) async throws -> BoundedProcessRunner.Result {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw FileOperationError.processFailed("必要なシステムツールが見つかりません: \(executable.path)")
    }
    do {
      return try await BoundedProcessRunner.run(
        executableURL: executable,
        arguments: arguments,
        timeout: captureStandardOutput ? 120 : 60 * 60,
        maximumStandardOutputBytes: captureStandardOutput
          ? Int(maximumListingBytes) : 1 * 1_024 * 1_024,
        maximumStandardErrorBytes: 1 * 1_024 * 1_024
      )
    } catch BoundedProcessRunner.Failure.cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw FileOperationError.processFailed(error.localizedDescription)
    }
  }

  private static func errorMessage(
    from result: BoundedProcessRunner.Result,
    fallback: String
  ) -> String {
    let text = String(data: result.stderr, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
  }

  private static func readListing(_ data: Data) throws -> String {
    guard UInt64(data.count) <= maximumListingBytes else {
      throw FileOperationError.processFailed("ZIPの一覧が安全上の上限を超えています。")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw FileOperationError.processFailed("UTF-8で表現できないファイル名を含むZIPは展開できません。")
    }
    return text
  }
}
