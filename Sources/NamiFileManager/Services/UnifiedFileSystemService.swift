import Foundation

struct UnifiedFileSystemService {
  enum ExistingItemPolicy: Sendable {
    case keepBoth
    case replace
  }

  private static let stagingDirectory: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nafi-remote-staging", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static func contents(of directory: URL, showHidden: Bool) async throws -> [FileItem] {
    guard NafiURL.isRemote(directory) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.contents(of: directory, showHidden: showHidden)
      }.value
    }

    guard let profileID = NafiURL.profileID(in: directory),
      let path = NafiURL.remotePath(in: directory)
    else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: profileID)
    return try await session.listDirectory(at: path)
      .filter { showHidden || !$0.name.hasPrefix(".") }
      .map { FileItem(remote: $0, profileID: profileID) }
  }

  static func exists(_ url: URL) async -> Bool {
    if !NafiURL.isRemote(url) {
      return FileManager.default.fileExists(atPath: url.path)
    }
    guard let name = itemName(url), !name.isEmpty else { return true }
    let parent = NafiURL.parent(of: url)
    return (try? await contents(of: parent, showHidden: true).contains { $0.name == name }) ?? false
  }

  static func createFile(named name: String, in directory: URL) async throws -> URL {
    let clean = try validatedName(name)
    guard NafiURL.isRemote(directory) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.createFile(named: clean, in: directory)
      }.value
    }
    let destination = NafiURL.appending(clean, to: directory)
    guard !(await exists(destination)) else { throw CocoaError(.fileWriteFileExists) }
    let temporary = stagingDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Data().write(to: temporary)
    try await upload(localURL: temporary, to: destination, replacing: false)
    notifyChanges(in: [directory])
    return destination
  }

  static func createFolder(named name: String, in directory: URL) async throws -> URL {
    let clean = try validatedName(name)
    guard NafiURL.isRemote(directory) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.createFolder(named: clean, in: directory)
      }.value
    }
    let destination = NafiURL.appending(clean, to: directory)
    guard !(await exists(destination)) else { throw CocoaError(.fileWriteFileExists) }
    guard let path = NafiURL.remotePath(in: destination) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: destination)
    try await session.createDirectory(at: path)
    notifyChanges(in: [directory])
    return destination
  }

  static func rename(_ url: URL, to newName: String) async throws -> URL {
    let clean = try validatedName(newName)
    guard NafiURL.isRemote(url) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.rename(url, to: clean)
      }.value
    }
    let destination = NafiURL.appending(clean, to: NafiURL.parent(of: url))
    guard !NafiURL.sameLocation(url, destination) else { return url }
    guard !(await exists(destination)) else { throw CocoaError(.fileWriteFileExists) }
    guard let oldPath = NafiURL.remotePath(in: url),
      let newPath = NafiURL.remotePath(in: destination)
    else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: url)
    try await session.renameItem(at: oldPath, to: newPath)
    notifyChanges(in: [NafiURL.parent(of: url)])
    return destination
  }

  static func remove(_ url: URL, isDirectory: Bool) async throws {
    guard NafiURL.isRemote(url) else {
      try await Task.detached(priority: .userInitiated) {
        try FileSystemService.trash(url)
      }.value
      return
    }
    guard let path = NafiURL.remotePath(in: url) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: url)
    if isDirectory {
      let children = try await contents(of: url, showHidden: true)
      for child in children {
        try await remove(child.url, isDirectory: child.isDirectory)
      }
    }
    try await session.removeItem(at: path, isDirectory: isDirectory)
    notifyChanges(in: [NafiURL.parent(of: url)])
  }

  static func compress(_ urls: [URL], in destinationDirectory: URL) async throws -> URL {
    guard !urls.isEmpty else { throw RemoteServerError.invalidResponse("圧縮する項目がありません。") }
    if destinationDirectory.isFileURL,
      urls.allSatisfy({ $0.isFileURL && $0.deletingLastPathComponent() == destinationDirectory })
    {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.compress(urls, in: destinationDirectory)
      }.value
    }

    let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    var stagedItems: [URL] = []
    for source in urls {
      let name = itemName(source) ?? "item"
      let target = staging.appendingPathComponent(name)
      if source.isFileURL {
        try FileManager.default.copyItem(at: source, to: target)
      } else {
        try await download(remoteURL: source, to: target)
      }
      stagedItems.append(target)
    }

    let archive = try await Task.detached(priority: .userInitiated) {
      try FileSystemService.compress(stagedItems, in: staging)
    }.value
    let result = try await transferOne(
      archive,
      to: destinationDirectory,
      move: false,
      policy: .keepBoth
    )
    notifyChanges(in: [destinationDirectory])
    return result
  }

  static func duplicate(_ url: URL) async throws -> URL {
    guard NafiURL.isRemote(url) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.duplicate(url)
      }.value
    }
    return try await transferOne(url, to: NafiURL.parent(of: url), move: false, policy: .keepBoth)
  }

  static func transfer(
    _ urls: [URL],
    to destination: URL,
    move: Bool,
    policy: ExistingItemPolicy
  ) async throws -> [URL] {
    var results: [URL] = []
    for url in urls {
      results.append(try await transferOne(url, to: destination, move: move, policy: policy))
    }
    var changedDirectories = [destination]
    if move {
      changedDirectories.append(
        contentsOf: urls.map {
          NafiURL.isRemote($0) ? NafiURL.parent(of: $0) : $0.deletingLastPathComponent()
        })
    }
    notifyChanges(in: changedDirectories)
    return results
  }

  static func conflictingItems(_ urls: [URL], in destination: URL) async -> [URL] {
    var conflicts: [URL] = []
    for source in urls {
      let target = appending(itemName(source) ?? source.lastPathComponent, to: destination)
      if await exists(target) { conflicts.append(source) }
    }
    return conflicts
  }

  static func prepareLocalCopy(of url: URL) async throws -> URL {
    guard NafiURL.isRemote(url) else { return url }
    let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let local = directory.appendingPathComponent(itemName(url) ?? "remote-item")
    try await download(remoteURL: url, to: local)
    return local
  }

  static func uploadEditedLocalCopy(_ localURL: URL, to remoteURL: URL) async throws {
    try await upload(localURL: localURL, to: remoteURL, replacing: true)
  }

  static func displayPath(for url: URL) async -> String {
    guard NafiURL.isRemote(url), let id = NafiURL.profileID(in: url) else { return url.path }
    let profile = await RemoteFileSystemRegistry.shared.profile(for: id)
    return NafiURL.displayPath(url, profile: profile)
  }

  static func profile(for url: URL) async -> ServerProfile? {
    await RemoteFileSystemRegistry.shared.profile(for: url)
  }

  private static func transferOne(
    _ source: URL,
    to destinationDirectory: URL,
    move: Bool,
    policy: ExistingItemPolicy
  ) async throws -> URL {
    let sourceRemote = NafiURL.isRemote(source)
    let destinationRootRemote = NafiURL.isRemote(destinationDirectory)

    if !sourceRemote && !destinationRootRemote {
      var isDirectory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
      if isDirectory.boolValue, NafiURL.isDescendant(destinationDirectory, of: source) {
        throw RemoteServerError.invalidResponse("フォルダをそのフォルダ自身の中へコピーまたは移動することはできません。")
      }
      return try await Task.detached(priority: .userInitiated) {
        let localPolicy: FileSystemService.ExistingItemPolicy =
          policy == .replace ? .replace : .keepBoth
        return move
          ? try FileSystemService.move(
            source, to: destinationDirectory, existingItemPolicy: localPolicy)
          : try FileSystemService.copy(
            source, to: destinationDirectory, existingItemPolicy: localPolicy)
      }.value
    }

    let sourceItem = try await item(at: source)
    if sourceItem?.isDirectory == true, NafiURL.isDescendant(destinationDirectory, of: source) {
      throw RemoteServerError.invalidResponse("フォルダをそのフォルダ自身の中へコピーまたは移動することはできません。")
    }

    var destination = appending(
      itemName(source) ?? source.lastPathComponent, to: destinationDirectory)
    if NafiURL.sameLocation(source, destination) {
      if move { return source }
      destination = try await uniqueDestination(for: destination)
    } else if await exists(destination) {
      switch policy {
      case .replace:
        let targetItem = try await item(at: destination)
        try await remove(destination, isDirectory: targetItem?.isDirectory ?? false)
      case .keepBoth:
        destination = try await uniqueDestination(for: destination)
      }
    }

    let destinationRemote = NafiURL.isRemote(destination)

    if move, sourceRemote, destinationRemote,
      NafiURL.profileID(in: source) == NafiURL.profileID(in: destination)
    {
      guard let oldPath = NafiURL.remotePath(in: source),
        let newPath = NafiURL.remotePath(in: destination)
      else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
      let session = try await RemoteFileSystemRegistry.shared.session(for: source)
      try await session.renameItem(at: oldPath, to: newPath)
      return destination
    }

    if !sourceRemote && destinationRemote {
      try await upload(localURL: source, to: destination, replacing: false)
      if move { try FileManager.default.removeItem(at: source) }
      return destination
    }

    if sourceRemote && !destinationRemote {
      try await download(remoteURL: source, to: destination)
      if move {
        try await remove(source, isDirectory: sourceItem?.isDirectory ?? false)
      }
      return destination
    }

    let temporaryRoot = stagingDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let local = temporaryRoot.appendingPathComponent(itemName(source) ?? "remote-item")
    try await download(remoteURL: source, to: local)
    try await upload(localURL: local, to: destination, replacing: false)
    if move {
      try await remove(source, isDirectory: sourceItem?.isDirectory ?? false)
    }
    return destination
  }

  private static func item(at url: URL) async throws -> FileItem? {
    let parent = NafiURL.isRemote(url) ? NafiURL.parent(of: url) : url.deletingLastPathComponent()
    let name = itemName(url) ?? url.lastPathComponent
    return try await contents(of: parent, showHidden: true).first { $0.name == name }
  }

  private static func download(remoteURL: URL, to localURL: URL) async throws {
    guard let remotePath = NafiURL.remotePath(in: remoteURL) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: remoteURL)
    let remoteItem = try await item(at: remoteURL)
    if remoteItem?.isDirectory == true {
      try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
      for child in try await contents(of: remoteURL, showHidden: true) {
        try await download(
          remoteURL: child.url,
          to: localURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
        )
      }
    } else {
      try FileManager.default.createDirectory(
        at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await session.downloadItem(at: remotePath, to: localURL)
    }
  }

  private static func upload(localURL: URL, to remoteURL: URL, replacing: Bool) async throws {
    guard let remotePath = NafiURL.remotePath(in: remoteURL) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: remoteURL)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
      throw CocoaError(.fileNoSuchFile)
    }
    if replacing, await exists(remoteURL), let existing = try await item(at: remoteURL) {
      try await remove(remoteURL, isDirectory: existing.isDirectory)
    }
    if isDirectory.boolValue {
      if !(await exists(remoteURL)) { try await session.createDirectory(at: remotePath) }
      let children = try FileManager.default.contentsOfDirectory(
        at: localURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
      for child in children {
        try await upload(
          localURL: child, to: NafiURL.appending(child.lastPathComponent, to: remoteURL),
          replacing: false)
      }
    } else {
      try await session.uploadItem(from: localURL, to: remotePath)
    }
  }

  private static func uniqueDestination(for desired: URL) async throws -> URL {
    let parent =
      NafiURL.isRemote(desired) ? NafiURL.parent(of: desired) : desired.deletingLastPathComponent()
    let name = itemName(desired) ?? desired.lastPathComponent
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var index = 2
    var candidate = desired
    while await exists(candidate) {
      let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
      candidate = appending(nextName, to: parent)
      index += 1
    }
    return candidate
  }

  private static func appending(_ name: String, to directory: URL) -> URL {
    NafiURL.isRemote(directory)
      ? NafiURL.appending(name, to: directory)
      : directory.appendingPathComponent(name)
  }

  private static func itemName(_ url: URL) -> String? {
    if NafiURL.isRemote(url) {
      guard let path = NafiURL.remotePath(in: url), path != "/" else { return nil }
      return RemotePath.name(of: path)
    }
    return url.lastPathComponent
  }

  private static func validatedName(_ name: String) throws -> String {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != ".", clean != "..", !clean.contains("/") else {
      throw RemoteServerError.invalidName
    }
    return clean
  }

  private static func notifyChanges(in directories: [URL]) {
    NotificationCenter.default.post(
      name: .namiFileSystemDidChange,
      object: nil,
      userInfo: ["directories": directories.map(NafiURL.normalized)]
    )
  }

}
