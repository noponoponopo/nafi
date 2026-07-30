import AppKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension Notification.Name {
  static let nafiFileSystemDidChange = Notification.Name("app.nafi.file-system-did-change")
  static let nafiMaintenanceWarning = Notification.Name("app.nafi.maintenance-warning")
}

private final class DirectorySnapshotBox: NSObject, @unchecked Sendable {
  let createdAt: Date
  let items: [FileItem]

  init(createdAt: Date = Date(), items: [FileItem]) {
    self.createdAt = createdAt
    self.items = items
  }
}

private final class FileSystemRuntime: @unchecked Sendable {
  private let notificationQueue = DispatchQueue(label: "app.nafi.file-change-coalescer")
  private let snapshotCache: NSCache<NSString, DirectorySnapshotBox> = {
    let cache = NSCache<NSString, DirectorySnapshotBox>()
    cache.countLimit = 96
    cache.totalCostLimit = 120_000
    return cache
  }()
  private var pendingDirectories: Set<URL> = []
  private var pendingNotification: DispatchWorkItem?
  private var notificationGeneration = 0

  func cachedItems(for key: NSString) -> [FileItem]? {
    guard let snapshot = snapshotCache.object(forKey: key),
      Date().timeIntervalSince(snapshot.createdAt) < 0.8
    else { return nil }
    return snapshot.items
  }

  func store(_ items: [FileItem], for key: NSString) {
    snapshotCache.setObject(DirectorySnapshotBox(items: items), forKey: key, cost: items.count)
  }

  func invalidateSnapshots(for directories: Set<URL>, key: (URL, Bool) -> NSString) {
    for directory in directories {
      snapshotCache.removeObject(forKey: key(directory, false))
      snapshotCache.removeObject(forKey: key(directory, true))
    }
  }

  func postChanges(_ directories: Set<URL>) {
    notificationQueue.async { [self] in
      pendingDirectories.formUnion(directories)
      pendingNotification?.cancel()
      notificationGeneration &+= 1
      let generation = notificationGeneration

      let work = DispatchWorkItem { [self] in
        guard generation == notificationGeneration else { return }
        let changedDirectories = Array(pendingDirectories)
        pendingDirectories.removeAll(keepingCapacity: true)
        pendingNotification = nil
        DispatchQueue.main.async {
          NotificationCenter.default.post(
            name: .nafiFileSystemDidChange,
            object: nil,
            userInfo: ["directories": changedDirectories]
          )
        }
      }
      pendingNotification = work
      notificationQueue.asyncAfter(deadline: .now() + .milliseconds(90), execute: work)
    }
  }
}

struct FileSystemService {
  enum ExistingItemPolicy: Sendable, Equatable {
    case keepBoth
    case replace
  }

  private static let runtime = FileSystemRuntime()

  static let resourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .isPackageKey,
    .isHiddenKey,
    .fileSizeKey,
    .creationDateKey,
    .contentModificationDateKey,
    .contentTypeKey,
    .tagNamesKey,
    .nameKey,
  ]

  static func contents(of directory: URL, showHidden: Bool) throws -> [FileItem] {
    let cacheKey = snapshotKey(for: directory, showHidden: showHidden)
    if let cached = runtime.cachedItems(for: cacheKey) {
      return cached
    }

    let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(resourceKeys),
      options: options
    )

    var result: [FileItem] = []
    result.reserveCapacity(urls.count)

    for (index, url) in urls.enumerated() {
      if index.isMultiple(of: 128), Task.isCancelled { throw CancellationError() }
      let item: FileItem? = autoreleasepool {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        let name = values.name ?? url.lastPathComponent
        if !showHidden && (values.isHidden == true || name.hasPrefix(".")) { return nil }
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
      if let item { result.append(item) }
    }
    runtime.store(result, for: cacheKey)
    return result
  }

  static func directorySize(at url: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [],
        errorHandler: { _, _ in true }
      )
    else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      total += Int64(size)
    }
    return total
  }

  static func createFile(named name: String, in directory: URL) throws -> URL {
    let safeName = try validatedName(name)
    let url = uniqueURL(for: safeName, in: directory)
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
      throw FileOperationError.cannotCreate(url.lastPathComponent)
    }
    notifyChanges(in: [directory])
    return url
  }

  static func createFolder(named name: String, in directory: URL) throws -> URL {
    let safeName = try validatedName(name)
    let url = uniqueURL(for: safeName, in: directory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    notifyChanges(in: [directory])
    return url
  }

  static func rename(_ url: URL, to newName: String) throws -> URL {
    let safeName = try validatedName(newName)
    let directory = url.deletingLastPathComponent()
    let destination = directory.appendingPathComponent(safeName)
    guard destination != url else { return url }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw FileOperationError.alreadyExists(safeName)
    }
    try FileManager.default.moveItem(at: url, to: destination)
    notifyChanges(in: [directory])
    return destination
  }

  static func duplicate(_ url: URL) throws -> URL {
    let directory = url.deletingLastPathComponent()
    let ext = url.pathExtension
    let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    let candidateName = ext.isEmpty ? "\(base) のコピー" : "\(base) のコピー.\(ext)"
    let destination = uniqueURL(for: candidateName, in: directory)
    try FileManager.default.copyItem(at: url, to: destination)
    notifyChanges(in: [directory])
    return destination
  }

  static func createAlias(to url: URL) throws -> URL {
    let directory = url.deletingLastPathComponent()
    let aliasName = "\(url.lastPathComponent) のエイリアス"
    var destination = directory.appendingPathComponent(aliasName)
    var suffix = 2
    while FileManager.default.fileExists(atPath: destination.path) {
      destination = directory.appendingPathComponent("\(aliasName) \(suffix)")
      suffix += 1
    }

    let bookmarkData = try url.bookmarkData(
      options: .suitableForBookmarkFile,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    try URL.writeBookmarkData(bookmarkData, to: destination)
    notifyChanges(in: [directory])
    return destination
  }

  static func trash(_ url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    notifyChanges(in: [directory])
  }

  static func copy(
    _ source: URL,
    to directory: URL,
    existingItemPolicy: ExistingItemPolicy = .keepBoth
  ) throws -> URL {
    let requestedDestination = directory.appendingPathComponent(source.lastPathComponent)
    let sourceURL = source.standardizedFileURL
    let requestedURL = requestedDestination.standardizedFileURL
    let copiesOntoSource = NafiURL.sameLocation(sourceURL, requestedURL)

    // Replacing an item with itself would destroy the source. A same-folder copy is always kept
    // as a second item instead.
    let destination =
      existingItemPolicy == .keepBoth || copiesOntoSource
      ? uniqueURL(for: source.lastPathComponent, in: directory)
      : requestedDestination

    if existingItemPolicy == .replace, !copiesOntoSource,
      FileManager.default.fileExists(atPath: destination.path)
    {
      try replaceExistingItem(at: destination) {
        try FileManager.default.copyItem(at: source, to: destination)
      }
    } else {
      do {
        try FileManager.default.copyItem(at: source, to: destination)
      } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
      }
    }

    notifyChanges(in: [directory])
    return destination
  }

  static func move(
    _ source: URL,
    to directory: URL,
    existingItemPolicy: ExistingItemPolicy = .keepBoth
  ) throws -> URL {
    if NafiURL.sameLocation(source.deletingLastPathComponent(), directory) {
      return source
    }

    let sourceDirectory = source.deletingLastPathComponent()
    let requestedDestination = directory.appendingPathComponent(source.lastPathComponent)
    let destination =
      existingItemPolicy == .keepBoth
      ? uniqueURL(for: source.lastPathComponent, in: directory)
      : requestedDestination

    let performMove = {
      do {
        try FileManager.default.moveItem(at: source, to: destination)
      } catch {
        // Only a genuine cross-device rename is retried as copy + remove. Permission,
        // collision and malformed-path failures must retain their original meaning.
        guard isCrossDeviceMoveError(error) else { throw error }
        do {
          try FileManager.default.copyItem(at: source, to: destination)
        } catch {
          try? FileManager.default.removeItem(at: destination)
          throw error
        }
        do {
          try FileManager.default.removeItem(at: source)
        } catch {
          try? FileManager.default.removeItem(at: destination)
          throw error
        }
      }
    }

    if existingItemPolicy == .replace, FileManager.default.fileExists(atPath: destination.path) {
      try replaceExistingItem(at: destination, operation: performMove)
    } else {
      try performMove()
    }

    notifyChanges(in: [sourceDirectory, directory])
    return destination
  }

  static func compress(_ urls: [URL], in directory: URL) async throws -> URL {
    guard !urls.isEmpty else { throw FileOperationError.noSelection }
    let normalizedDirectory = directory.standardizedFileURL
    guard normalizedDirectory.isFileURL,
      urls.allSatisfy({
        $0.isFileURL
          && NafiURL.sameLocation($0.deletingLastPathComponent(), normalizedDirectory)
      })
    else {
      throw FileOperationError.processFailed("圧縮対象は同じローカルフォルダ内にある必要があります。")
    }
    try await Task.detached(priority: .utility) {
      try validateCompressionInputs(urls)
    }.value

    let baseName =
      urls.count == 1
      ? urls[0].deletingPathExtension().lastPathComponent
      : "アーカイブ"
    let destination = uniqueURL(for: "\(baseName).zip", in: directory)

    do {
      let result = try await BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
        arguments: ["-r", "-q", destination.path, "--"] + urls.map(\.lastPathComponent),
        currentDirectoryURL: directory,
        timeout: 6 * 60 * 60,
        maximumStandardOutputBytes: 1 * 1_024 * 1_024,
        maximumStandardErrorBytes: 1 * 1_024 * 1_024
      )
      guard result.terminationStatus == 0 else {
        let message = String(data: result.stderr, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        throw FileOperationError.processFailed(
          message.flatMap { $0.isEmpty ? nil : $0 } ?? "圧縮に失敗しました。"
        )
      }
    } catch BoundedProcessRunner.Failure.cancelled {
      try? FileManager.default.removeItem(at: destination)
      throw CancellationError()
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: destination)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }

    notifyChanges(in: [directory])
    return destination
  }

  private static func validateCompressionInputs(_ roots: [URL]) throws {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
    var pending = roots.map { $0.standardizedFileURL }
    var visited = 0
    while let item = pending.popLast() {
      if Task.isCancelled { throw CancellationError() }
      visited += 1
      guard visited <= 1_000_000 else {
        throw FileOperationError.processFailed("圧縮対象が100万項目を超えています。対象を分割してください。")
      }
      let values = try item.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true {
        throw FileOperationError.processFailed(
          "シンボリックリンクを含む項目は安全のため圧縮できません: \(item.path)"
        )
      }
      if values.isDirectory == true {
        pending.append(contentsOf: try FileManager.default.contentsOfDirectory(
          at: item,
          includingPropertiesForKeys: Array(keys),
          options: []
        ))
      } else if values.isRegularFile != true {
        throw FileOperationError.processFailed(
          "通常ファイルでもフォルダでもない項目は圧縮できません: \(item.path)"
        )
      }
    }
  }

  static func setTags(_ tags: [String], for urls: [URL]) throws {
    let normalized = Array(
      Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    for url in urls {
      // URLResourceValues.tagNames の setter は macOS 26 以降に限定されるため、
      // macOS 14 から利用できる NSURL のキー指定 API を使う。
      try (url as NSURL).setResourceValue(normalized, forKey: .tagNamesKey)
    }
    notifyChanges(in: urls.map { $0.deletingLastPathComponent() })
  }

  static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func notifyFileChanged(at url: URL) {
    notifyChanges(in: [url.deletingLastPathComponent()])
  }


  private static func isCrossDeviceMoveError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == EXDEV { return true }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isCrossDeviceMoveError(underlying)
    }
    if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [Error] {
      return detailed.contains(where: isCrossDeviceMoveError)
    }
    return false
  }

  private static func validatedName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
      value.utf8.count <= 255,
      !value.unicodeScalars.contains(where: { $0.value == 0 || $0 == "\r" || $0 == "\n" })
    else {
      throw FileOperationError.invalidName
    }
    return value
  }

  private static func replaceExistingItem(
    at destination: URL,
    operation: () throws -> Void
  ) throws {
    let fileManager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    let backup = directory.appendingPathComponent(
      ".nafi-replaced-\(UUID().uuidString)",
      isDirectory: false
    )

    try fileManager.moveItem(at: destination, to: backup)
    do {
      try operation()
    } catch {
      try? fileManager.removeItem(at: destination)
      do {
        try fileManager.moveItem(at: backup, to: destination)
      } catch let restoreError {
        throw FileOperationError.processFailed(
          "置き換えに失敗し、元の項目も復元できませんでした。バックアップ: \(backup.path)\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try fileManager.removeItem(at: backup)
    } catch {
      NotificationCenter.default.post(
        name: .nafiMaintenanceWarning,
        object: nil,
        userInfo: [
          "message":
            "置き換えは完了しましたが、古いバックアップを削除できませんでした。必要に応じて削除してください: \(backup.path)\n\(error.localizedDescription)"
        ]
      )
    }
  }

  private static func uniqueURL(for name: String, in directory: URL) -> URL {
    let original = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: original.path) else { return original }

    let nsName = name as NSString
    let ext = nsName.pathExtension
    let stem = ext.isEmpty ? name : nsName.deletingPathExtension
    var index = 2
    while true {
      let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
      let candidate = directory.appendingPathComponent(nextName)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      index += 1
    }
  }

  private static func snapshotKey(for directory: URL, showHidden: Bool) -> NSString {
    "\(directory.standardizedFileURL.path)|hidden:\(showHidden)" as NSString
  }

  private static func notifyChanges(in directories: [URL]) {
    let normalized = Set(directories.map { $0.standardizedFileURL })
    runtime.invalidateSnapshots(for: normalized) { directory, showHidden in
      snapshotKey(for: directory, showHidden: showHidden)
    }
    runtime.postChanges(normalized)
  }
}

enum FileOperationError: LocalizedError {
  case invalidName
  case cannotCreate(String)
  case alreadyExists(String)
  case noSelection
  case processFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidName: "使用できない名前です。"
    case .cannotCreate(let name): "「\(name)」を作成できませんでした。"
    case .alreadyExists(let name): "「\(name)」はすでに存在します。"
    case .noSelection: "項目が選択されていません。"
    case .processFailed(let message): message
    }
  }
}
