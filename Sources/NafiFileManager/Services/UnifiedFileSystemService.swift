import Foundation

struct UnifiedFileSystemService {
  enum ExistingItemPolicy: String, Codable, Sendable {
    case keepBoth
    case replace
  }

  private struct ItemDescriptor: Sendable {
    let isDirectory: Bool
    let size: UInt64?
    let isSymbolicLink: Bool
  }

  private struct BatchRenamePlan: Sendable {
    let original: URL
    let temporary: URL
    let destination: URL
  }

  private static let stagingDirectory: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nafi-remote-staging", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }()

  static func cleanupStaleStagingItems(olderThan age: TimeInterval = 24 * 60 * 60) {
    let now = Date()
    guard
      let items = try? FileManager.default.contentsOfDirectory(
        at: stagingDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsSubdirectoryDescendants]
      )
    else { return }

    for item in items {
      let modified =
        (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) >= age {
        try? FileManager.default.removeItem(at: item)
      }
    }
  }

  static func contents(of directory: URL, showHidden: Bool) async throws -> [FileItem] {
    try Task.checkCancellation()
    guard NafiURL.isRemote(directory) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.contents(of: directory, showHidden: showHidden)
      }.value
    }

    if NafiURL.isAmbiguousRemoteItem(directory) {
      throw RemoteServerError.unsupported(
        "同名のリモートフォルダは安全に一意指定できないため開けません。接続先側で名前を一意にしてください。"
      )
    }
    guard let profileID = NafiURL.profileID(in: directory),
      let path = NafiURL.remotePath(in: directory)
    else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: profileID)
    let items = try await session.listDirectory(at: path)
    try Task.checkCancellation()
    return
      items
      .filter { showHidden || !$0.name.hasPrefix(".") }
      .map { FileItem(remote: $0, profileID: profileID) }
  }

  static func exists(_ url: URL) async throws -> Bool {
    try await descriptor(at: url) != nil
  }

  static func createFile(named name: String, in directory: URL) async throws -> URL {
    let clean = try validatedName(name)
    guard NafiURL.isRemote(directory) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.createFile(named: clean, in: directory)
      }.value
    }

    let destination = NafiURL.appending(clean, to: directory)
    guard try await descriptor(at: destination) == nil else {
      throw CocoaError(.fileWriteFileExists)
    }

    let staging = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent(UUID().uuidString)
    try Data().write(to: temporary, options: .atomic)
    try await upload(localURL: temporary, to: destination)
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
    guard try await descriptor(at: destination) == nil else {
      throw CocoaError(.fileWriteFileExists)
    }
    guard let path = NafiURL.remotePath(in: destination) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: destination)
    try await session.createDirectory(at: path)
    notifyChanges(in: [directory])
    return destination
  }

  static func rename(_ url: URL, to newName: String) async throws -> URL {
    try ensureUnambiguous(url)
    let clean = try validatedName(newName)
    guard NafiURL.isRemote(url) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.rename(url, to: clean)
      }.value
    }

    let destination = NafiURL.appending(clean, to: NafiURL.parent(of: url))
    guard !NafiURL.sameLocation(url, destination) else { return url }
    guard try await descriptor(at: destination) == nil else {
      throw CocoaError(.fileWriteFileExists)
    }
    guard let oldPath = NafiURL.remotePath(in: url),
      let newPath = NafiURL.remotePath(in: destination)
    else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: url)
    try await session.renameItem(at: oldPath, to: newPath)
    notifyChanges(in: [NafiURL.parent(of: url)])
    return destination
  }

  static func batchRename(_ urls: [URL], pattern: String) async throws -> [URL] {
    try urls.forEach(ensureUnambiguous)
    var seenLocations = Set<String>()
    let sources = try urls.compactMap { url -> URL? in
      let normalized = NafiURL.normalized(url)
      guard let key = NafiURL.locationKey(normalized) else {
        throw RemoteServerError.invalidResponse("一括名称変更に不正なURLが含まれています。")
      }
      return seenLocations.insert(key).inserted ? normalized : nil
    }.sorted {
      (itemName($0) ?? $0.lastPathComponent).localizedStandardCompare(
        itemName($1) ?? $1.lastPathComponent
      ) == .orderedAscending
    }
    guard sources.count >= 2 else {
      throw RemoteServerError.invalidResponse("一括名称変更には2項目以上を選択してください。")
    }
    try Task.checkCancellation()

    let parent =
      NafiURL.isRemote(sources[0])
      ? NafiURL.parent(of: sources[0])
      : sources[0].deletingLastPathComponent().standardizedFileURL
    guard
      sources.dropFirst().allSatisfy({ source in
        let sourceParent =
          NafiURL.isRemote(source)
          ? NafiURL.parent(of: source)
          : source.deletingLastPathComponent().standardizedFileURL
        return NafiURL.sameLocation(sourceParent, parent)
      })
    else {
      throw RemoteServerError.invalidResponse("同じフォルダ内の項目だけを一括名称変更できます。")
    }

    let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPattern.isEmpty else { throw RemoteServerError.invalidName }
    let sourceSet = Set(sources)
    var sourceDescriptors: [URL: ItemDescriptor] = [:]
    for source in sources {
      guard let value = try await descriptor(at: source) else {
        throw CocoaError(.fileNoSuchFile)
      }
      sourceDescriptors[source] = value
    }

    var seenNames = Set<String>()
    var destinations: [URL] = []
    destinations.reserveCapacity(sources.count)

    for (offset, source) in sources.enumerated() {
      let originalName = itemName(source) ?? source.lastPathComponent
      let generated = try generatedBatchName(
        pattern: cleanPattern,
        originalName: originalName,
        index: offset + 1,
        preserveExtension: sourceDescriptors[source]?.isDirectory != true
      )
      let cleanName = try validatedName(generated)
      let key = filenameCollisionKey(cleanName)
      guard seenNames.insert(key).inserted else {
        throw RemoteServerError.invalidResponse("一括名称変更後の名前が重複します: \(cleanName)")
      }
      destinations.append(appending(cleanName, to: parent))
    }

    let sourceNameKeys = Set(sources.compactMap(itemName).map(filenameCollisionKey))
    let externalNameKeys = Set(
      try await contents(of: parent, showHidden: true)
        .filter { !sourceSet.contains(NafiURL.normalized($0.url)) }
        .map { filenameCollisionKey($0.name) }
    )
    for destination in destinations {
      let destinationName = itemName(destination) ?? destination.lastPathComponent
      let key = filenameCollisionKey(destinationName)
      if externalNameKeys.contains(key) {
        throw CocoaError(.fileWriteFileExists)
      }
      if !sourceNameKeys.contains(key), try await descriptor(at: destination) != nil {
        throw CocoaError(.fileWriteFileExists)
      }
    }

    if zip(sources, destinations).allSatisfy({ NafiURL.sameLocation($0.0, $0.1) }) {
      return sources
    }

    var plans: [BatchRenamePlan] = []
    plans.reserveCapacity(sources.count)
    for (source, destination) in zip(sources, destinations) {
      let temporary = NafiURL.isRemote(parent)
        ? try await uniqueRemoteTemporarySibling(of: destination, prefix: ".nafi-rename")
        : uniqueLocalTemporarySibling(of: destination, prefix: ".nafi-rename")
      plans.append(BatchRenamePlan(
        original: source,
        temporary: temporary,
        destination: destination
      ))
    }

    if NafiURL.isRemote(parent) {
      let session = try await RemoteFileSystemRegistry.shared.session(for: parent)
      let journal = try await makeRemoteJournal(
        kind: .batchRename,
        reference: parent,
        batchPlans: plans.map {
          RemoteRenameJournalPlan(
            original: $0.original,
            temporary: $0.temporary,
            destination: $0.destination
          )
        }
      )
      try await RemoteOperationJournal.shared.save(journal)
      do {
        try await executeRemoteRenameTransaction(plans, session: session)
        await RemoteOperationJournal.shared.remove(id: journal.id)
      } catch {
        throw error
      }
    } else {
      try await Task.detached(priority: .userInitiated) {
        try executeLocalRenameTransaction(plans)
      }.value
    }

    notifyChanges(in: [parent])
    return destinations
  }

  static func remove(_ url: URL, isDirectory: Bool) async throws {
    try ensureUnambiguous(url)
    guard NafiURL.isRemote(url) else {
      try await Task.detached(priority: .userInitiated) {
        try FileSystemService.trash(url)
      }.value
      return
    }

    try await removeRemote(
      url,
      descriptor: ItemDescriptor(
        isDirectory: isDirectory,
        size: nil,
        isSymbolicLink: false
      ))
    notifyChanges(in: [NafiURL.parent(of: url)])
  }

  static func compress(_ urls: [URL], in destinationDirectory: URL) async throws -> URL {
    guard !urls.isEmpty else {
      throw RemoteServerError.invalidResponse("圧縮する項目がありません。")
    }
    if destinationDirectory.isFileURL,
      urls.allSatisfy({
        $0.isFileURL
          && NafiURL.sameLocation($0.deletingLastPathComponent(), destinationDirectory)
      })
    {
      return try await FileSystemService.compress(urls, in: destinationDirectory)
    }

    let staging = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }

    var stagedItems: [URL] = []
    for source in urls {
      try Task.checkCancellation()
      let name = itemName(source) ?? "item"
      let target = uniqueLocalURL(for: name, in: staging)
      if source.isFileURL {
        try FileManager.default.copyItem(at: source, to: target)
      } else {
        try await download(remoteURL: source, to: target)
      }
      stagedItems.append(target)
    }

    let archive = try await FileSystemService.compress(stagedItems, in: staging)
    let result = try await transferOne(
      archive,
      to: destinationDirectory,
      move: false,
      policy: .keepBoth
    )
    notifyChanges(in: [destinationDirectory])
    return result
  }

  static func extractArchive(_ archive: URL, to destinationDirectory: URL) async throws -> URL {
    guard archive.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
      throw RemoteServerError.invalidResponse("現在展開できる形式はZIPです。")
    }
    let staging = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }

    let localArchive: URL
    if archive.isFileURL {
      localArchive = archive
    } else {
      localArchive = staging.appendingPathComponent("source.zip")
      try await download(remoteURL: archive, to: localArchive)
    }

    let rawBase = ((itemName(archive) ?? "アーカイブ") as NSString).deletingPathExtension
    let baseName = (try? validatedName(rawBase)) ?? "展開したアーカイブ"
    let extractedFolder = staging.appendingPathComponent(baseName, isDirectory: true)
    try await ArchiveService.extractZIP(at: localArchive, to: extractedFolder)
    try Task.checkCancellation()

    let result = try await transferOne(
      extractedFolder,
      to: destinationDirectory,
      move: true,
      policy: .keepBoth
    )
    notifyChanges(in: [destinationDirectory])
    return result
  }

  static func duplicate(_ url: URL) async throws -> URL {
    try ensureUnambiguous(url)
    guard NafiURL.isRemote(url) else {
      return try await Task.detached(priority: .userInitiated) {
        try FileSystemService.duplicate(url)
      }.value
    }
    return try await transferOne(
      url,
      to: NafiURL.parent(of: url),
      move: false,
      policy: .keepBoth
    )
  }

  static func transfer(
    _ urls: [URL],
    to destination: URL,
    move: Bool,
    policy: ExistingItemPolicy
  ) async throws -> [URL] {
    try ensureUnambiguous(destination)
    try urls.forEach(ensureUnambiguous)
    var results: [URL] = []
    results.reserveCapacity(urls.count)
    for url in urls {
      try Task.checkCancellation()
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

  static func conflictingItems(_ urls: [URL], in destination: URL) async throws -> [URL] {
    try ensureUnambiguous(destination)
    try urls.forEach(ensureUnambiguous)
    var conflicts: [URL] = []
    for source in urls {
      try Task.checkCancellation()
      let target = appending(itemName(source) ?? source.lastPathComponent, to: destination)
      if try await exists(target) { conflicts.append(source) }
    }
    return conflicts
  }

  static func prepareLocalCopy(of url: URL) async throws -> URL {
    guard NafiURL.isRemote(url) else { return url }
    let directory = try makeStagingDirectory()
    let local = directory.appendingPathComponent(itemName(url) ?? "remote-item")
    do {
      try await download(remoteURL: url, to: local)
      return local
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  static func withTemporaryLocalCopy<T>(
    of url: URL,
    operation: (URL) async throws -> T
  ) async throws -> T {
    guard NafiURL.isRemote(url) else {
      return try await operation(url)
    }

    let directory = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let local = directory.appendingPathComponent(itemName(url) ?? "remote-item")
    try await download(remoteURL: url, to: local)
    return try await operation(local)
  }

  static func uploadEditedLocalCopy(_ localURL: URL, to remoteURL: URL) async throws {
    guard NafiURL.isRemote(remoteURL) else {
      throw RemoteServerError.invalidResponse("保存先がリモートURLではありません。")
    }
    let existing = try await descriptor(at: remoteURL)
    let staged = try await uniqueRemoteTemporarySibling(of: remoteURL, prefix: ".nafi-edit")
    do {
      try await upload(localURL: localURL, to: staged)
      try await verifyUpload(localURL: localURL, remoteURL: staged)
      try await commitRemote(staged: staged, to: remoteURL, replacing: existing)
    } catch {
      await cleanupRemoteIfPresent(staged)
      throw error
    }
    notifyChanges(in: [NafiURL.parent(of: remoteURL)])
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
    try Task.checkCancellation()
    try ensureUnambiguous(source)
    try ensureUnambiguous(destinationDirectory)
    let sourceRemote = NafiURL.isRemote(source)
    let destinationRootRemote = NafiURL.isRemote(destinationDirectory)

    if !sourceRemote && !destinationRootRemote {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
        throw CocoaError(.fileNoSuchFile)
      }
      if isDirectory.boolValue, NafiURL.isDescendant(destinationDirectory, of: source) {
        throw RemoteServerError.invalidResponse(
          "フォルダをそのフォルダ自身の中へコピーまたは移動することはできません。"
        )
      }

      return try await Task.detached(priority: .userInitiated) {
        let localPolicy: FileSystemService.ExistingItemPolicy =
          policy == .replace ? .replace : .keepBoth
        let result =
          move
          ? try FileSystemService.move(
            source,
            to: destinationDirectory,
            existingItemPolicy: localPolicy
          )
          : try FileSystemService.copy(
            source,
            to: destinationDirectory,
            existingItemPolicy: localPolicy
          )
        if !move {
          do {
            try FileIntegrityService.verifyEquivalent(source, result)
          } catch {
            try? FileManager.default.removeItem(at: result)
            throw error
          }
        }
        return result
      }.value
    }

    guard let sourceDescriptor = try await descriptor(at: source) else {
      throw CocoaError(.fileNoSuchFile)
    }
    if sourceDescriptor.isDirectory, NafiURL.isDescendant(destinationDirectory, of: source) {
      throw RemoteServerError.invalidResponse(
        "フォルダをそのフォルダ自身の中へコピーまたは移動することはできません。"
      )
    }
    if sourceDescriptor.isSymbolicLink, sourceRemote != destinationRootRemote {
      throw RemoteServerError.invalidResponse(
        "シンボリックリンクをローカルとリモートの間で安全に転送できません。リンク先ではなく実体を選択してください。"
      )
    }

    var destination = appending(
      itemName(source) ?? source.lastPathComponent,
      to: destinationDirectory
    )
    if NafiURL.sameLocation(source, destination) {
      if move { return source }
      destination = try await uniqueDestination(for: destination)
    }

    var existing = try await descriptor(at: destination)
    if existing != nil, policy == .keepBoth {
      destination = try await uniqueDestination(for: destination)
      existing = nil
    }

    let destinationRemote = NafiURL.isRemote(destination)

    if move, sourceRemote, destinationRemote,
      NafiURL.profileID(in: source) == NafiURL.profileID(in: destination)
    {
      guard let oldPath = NafiURL.remotePath(in: source),
        let newPath = NafiURL.remotePath(in: destination)
      else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
      let session = try await RemoteFileSystemRegistry.shared.session(for: source)
      if let existing {
        try await commitRemoteMove(
          session: session,
          sourcePath: oldPath,
          destination: destination,
          destinationPath: newPath,
          replacing: existing
        )
      } else {
        try await session.renameItem(at: oldPath, to: newPath)
      }
      return destination
    }

    let engine = RcloneTransferEngine()
    let stagedDestination: URL = destinationRemote
      ? try await uniqueRemoteTemporarySibling(of: destination, prefix: ".nafi-partial")
      : uniqueLocalTemporarySibling(of: destination, prefix: ".nafi-partial")

    do {
      if sourceRemote && !destinationRemote {
        try await download(remoteURL: source, to: stagedDestination)
        if sourceDescriptor.isDirectory {
          let verification = await engine.effectiveVerificationMode(
            source: source,
            destination: stagedDestination
          )
          try await engine.verify(
            source: source,
            destination: stagedDestination,
            isDirectory: true,
            mode: verification
          )
        }
      } else {
        _ = try await engine.copy(
          source: source,
          destination: stagedDestination,
          isDirectory: sourceDescriptor.isDirectory,
          progress: { _ in }
        )

        let verification = await engine.effectiveVerificationMode(
          source: source,
          destination: stagedDestination
        )
        try await engine.verify(
          source: source,
          destination: stagedDestination,
          isDirectory: sourceDescriptor.isDirectory,
          mode: verification
        )
      }

      if destinationRemote {
        try await commitRemote(
          staged: stagedDestination,
          to: destination,
          replacing: existing
        )
      } else {
        try commitLocal(
          staged: stagedDestination,
          to: destination,
          replacing: existing != nil
        )
      }
    } catch {
      if destinationRemote {
        await cleanupRemoteIfPresent(stagedDestination)
      } else {
        try? FileManager.default.removeItem(at: stagedDestination)
      }
      throw error
    }

    if move {
      do {
        if sourceRemote {
          try await removeRemote(source, descriptor: sourceDescriptor)
        } else {
          try FileManager.default.removeItem(at: source)
        }
      } catch {
        postMaintenanceWarning(
          "コピー先は作成されましたが、移動元を削除できなかったため元の項目が残っています: \(NafiURL.displayPath(source))\n\(error.localizedDescription)"
        )
      }
    }
    return destination
  }

  private static func descriptor(at url: URL) async throws -> ItemDescriptor? {
    if !NafiURL.isRemote(url) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return nil
      }
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
      ])
      return ItemDescriptor(
        isDirectory: values.isDirectory ?? isDirectory.boolValue,
        size: values.isDirectory == true ? nil : values.fileSize.map { UInt64(max($0, 0)) },
        isSymbolicLink: values.isSymbolicLink == true
      )
    }

    try ensureUnambiguous(url)
    guard let path = NafiURL.remotePath(in: url) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    if path == "/" {
      return ItemDescriptor(isDirectory: true, size: nil, isSymbolicLink: false)
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: url)
    guard let item = try await session.statItem(at: path) else { return nil }
    return ItemDescriptor(
      isDirectory: item.isDirectory,
      size: item.size,
      isSymbolicLink: false
    )
  }

  private static func download(remoteURL: URL, to localURL: URL) async throws {
    try Task.checkCancellation()
    guard let remotePath = NafiURL.remotePath(in: remoteURL) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    guard let descriptor = try await descriptor(at: remoteURL) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let partial = uniqueLocalTemporarySibling(of: localURL, prefix: ".nafi-partial")
    defer { try? FileManager.default.removeItem(at: partial) }
    let session = try await RemoteFileSystemRegistry.shared.session(for: remoteURL)
    try await session.downloadItem(at: remotePath, to: partial)
    if !descriptor.isDirectory {
      try FileIntegrityService.verifySize(of: partial, expected: descriptor.size)
    }
    try commitLocal(staged: partial, to: localURL, replacing: false)
  }

  private static func upload(localURL: URL, to remoteURL: URL) async throws {
    try Task.checkCancellation()
    guard let remotePath = NafiURL.remotePath(in: remoteURL) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: remoteURL)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let values = try localURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw RemoteServerError.invalidResponse(
        "シンボリックリンクは接続先の意味論が異なるため、既定では転送しません。"
      )
    }
    guard try await descriptor(at: remoteURL) == nil else {
      throw CocoaError(.fileWriteFileExists)
    }
    do {
      try await session.uploadItem(from: localURL, to: remotePath)
    } catch {
      await cleanupRemoteIfPresent(remoteURL)
      throw error
    }
  }

  private static func verifyUpload(localURL: URL, remoteURL: URL) async throws {
    let verificationDirectory = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: verificationDirectory) }
    let downloaded = verificationDirectory.appendingPathComponent(
      localURL.lastPathComponent,
      isDirectory: false
    )
    try await download(remoteURL: remoteURL, to: downloaded)
    try await Task.detached(priority: .utility) {
      try FileIntegrityService.verifyEquivalent(localURL, downloaded)
    }.value
  }

  private static func commitRemote(
    staged: URL,
    to destination: URL,
    replacing existing: ItemDescriptor?
  ) async throws {
    guard let stagedPath = NafiURL.remotePath(in: staged),
      let destinationPath = NafiURL.remotePath(in: destination)
    else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: destination)

    guard let existing else {
      try await session.renameItem(at: stagedPath, to: destinationPath)
      return
    }

    let backup = try await uniqueRemoteTemporarySibling(of: destination, prefix: ".nafi-backup")
    guard let backupPath = NafiURL.remotePath(in: backup) else {
      throw RemoteServerError.invalidResponse("バックアップパスを作成できません。")
    }
    var journal = try await makeRemoteJournal(
      kind: .replaceCopy,
      reference: destination,
      staged: staged,
      destination: destination,
      backup: backup
    )
    try await RemoteOperationJournal.shared.save(journal)
    try await session.renameItem(at: destinationPath, to: backupPath)
    journal.phase = .backedUp
    journal.updatedAt = Date()
    do {
      try await RemoteOperationJournal.shared.save(journal)
    } catch {
      do {
        try await session.renameItem(at: backupPath, to: destinationPath)
        await RemoteOperationJournal.shared.remove(id: journal.id)
      } catch let restoreError {
        throw RemoteServerError.invalidResponse(
          "バックアップ後に復旧記録を更新できず、元の項目も復元できませんでした。バックアップ: \(NafiURL.displayPath(backup))\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try await session.renameItem(at: stagedPath, to: destinationPath)
      journal.phase = .committed
      journal.updatedAt = Date()
      do {
        try await RemoteOperationJournal.shared.save(journal)
      } catch {
        postMaintenanceWarning(
          "置き換えは確定しましたが、復旧記録の完了状態を保存できませんでした。バックアップ清掃後に記録を再確認します。\n\(error.localizedDescription)"
        )
      }
    } catch {
      do {
        try await session.renameItem(at: backupPath, to: destinationPath)
        await RemoteOperationJournal.shared.remove(id: journal.id)
      } catch let restoreError {
        throw RemoteServerError.invalidResponse(
          "転送先の置き換えに失敗し、元の項目も復元できませんでした。バックアップ: \(NafiURL.displayPath(backup))\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try await removeRemote(backup, descriptor: existing)
      await RemoteOperationJournal.shared.remove(id: journal.id)
    } catch {
      postMaintenanceWarning(
        "置き換えは完了しましたが、古いバックアップを削除できませんでした。必要に応じて削除してください: \(NafiURL.displayPath(backup))\n\(error.localizedDescription)"
      )
    }
  }

  private static func commitRemoteMove(
    session: any RemoteServerSession,
    sourcePath: String,
    destination: URL,
    destinationPath: String,
    replacing existing: ItemDescriptor
  ) async throws {
    let backup = try await uniqueRemoteTemporarySibling(of: destination, prefix: ".nafi-backup")
    guard let backupPath = NafiURL.remotePath(in: backup),
      let profileID = NafiURL.profileID(in: destination)
    else {
      throw RemoteServerError.invalidResponse("バックアップパスを作成できません。")
    }
    let sourceURL = NafiURL.remoteURL(profileID: profileID, path: sourcePath)
    var journal = try await makeRemoteJournal(
      kind: .replaceMove,
      reference: destination,
      source: sourceURL,
      destination: destination,
      backup: backup
    )
    try await RemoteOperationJournal.shared.save(journal)
    try await session.renameItem(at: destinationPath, to: backupPath)
    journal.phase = .backedUp
    journal.updatedAt = Date()
    do {
      try await RemoteOperationJournal.shared.save(journal)
    } catch {
      do {
        try await session.renameItem(at: backupPath, to: destinationPath)
        await RemoteOperationJournal.shared.remove(id: journal.id)
      } catch let restoreError {
        throw RemoteServerError.invalidResponse(
          "バックアップ後に復旧記録を更新できず、元の項目も復元できませんでした。バックアップ: \(NafiURL.displayPath(backup))\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }
    do {
      try await session.renameItem(at: sourcePath, to: destinationPath)
      journal.phase = .committed
      journal.updatedAt = Date()
      do {
        try await RemoteOperationJournal.shared.save(journal)
      } catch {
        postMaintenanceWarning(
          "移動は確定しましたが、復旧記録の完了状態を保存できませんでした。バックアップ清掃後に記録を再確認します。\n\(error.localizedDescription)"
        )
      }
    } catch {
      do {
        try await session.renameItem(at: backupPath, to: destinationPath)
        await RemoteOperationJournal.shared.remove(id: journal.id)
      } catch let restoreError {
        throw RemoteServerError.invalidResponse(
          "移動先の置き換えに失敗し、元の項目も復元できませんでした。バックアップ: \(NafiURL.displayPath(backup))\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try await removeRemote(backup, descriptor: existing)
      await RemoteOperationJournal.shared.remove(id: journal.id)
    } catch {
      postMaintenanceWarning(
        "移動は完了しましたが、置き換え前のバックアップを削除できませんでした。必要に応じて削除してください: \(NafiURL.displayPath(backup))\n\(error.localizedDescription)"
      )
    }
  }

  private static func commitLocal(staged: URL, to destination: URL, replacing: Bool) throws {
    let fileManager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

    let destinationExists = fileManager.fileExists(atPath: destination.path)
    if destinationExists && !replacing {
      throw CocoaError(.fileWriteFileExists)
    }
    guard destinationExists else {
      try fileManager.moveItem(at: staged, to: destination)
      return
    }

    let backup = uniqueLocalTemporarySibling(of: destination, prefix: ".nafi-backup")
    try fileManager.moveItem(at: destination, to: backup)
    do {
      try fileManager.moveItem(at: staged, to: destination)
    } catch {
      do {
        try fileManager.moveItem(at: backup, to: destination)
      } catch let restoreError {
        throw RemoteServerError.invalidResponse(
          "ローカル項目の置き換えに失敗し、元の項目も復元できませんでした。バックアップ: \(backup.path)\n\(restoreError.localizedDescription)"
        )
      }
      throw error
    }

    do {
      try fileManager.removeItem(at: backup)
    } catch {
      postMaintenanceWarning(
        "置き換えは完了しましたが、古いローカルバックアップを削除できませんでした。必要に応じて削除してください: \(backup.path)\n\(error.localizedDescription)"
      )
    }
  }

  private static func removeRemote(
    _ url: URL,
    descriptor: ItemDescriptor,
    checksCancellation: Bool = true
  ) async throws {
    guard let path = NafiURL.remotePath(in: url) else {
      throw RemoteServerError.invalidResponse("リモートパスが正しくありません。")
    }
    try ensureUnambiguous(url)
    if checksCancellation { try Task.checkCancellation() }
    let session = try await RemoteFileSystemRegistry.shared.session(for: url)
    try await session.removeItem(at: path, isDirectory: descriptor.isDirectory)
  }

  private static func cleanupRemoteIfPresent(_ url: URL) async {
    guard let existing = try? await descriptor(at: url) else { return }
    try? await removeRemote(url, descriptor: existing, checksCancellation: false)
  }

  private static func uniqueDestination(for desired: URL) async throws -> URL {
    let parent =
      NafiURL.isRemote(desired)
      ? NafiURL.parent(of: desired)
      : desired.deletingLastPathComponent()
    let name = itemName(desired) ?? desired.lastPathComponent
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var index = 2
    var candidate = desired
    while try await descriptor(at: candidate) != nil {
      try Task.checkCancellation()
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

  private static func uniqueRemoteTemporarySibling(
    of destination: URL,
    prefix: String
  ) async throws -> URL {
    let parent = NafiURL.parent(of: destination)
    for _ in 0..<32 {
      let candidate = NafiURL.appending(
        "\(prefix)-\(UUID().uuidString.lowercased())",
        to: parent
      )
      if try await descriptor(at: candidate) == nil { return candidate }
    }
    throw RemoteServerError.invalidResponse("安全な一時リモート名を確保できません。")
  }

  private static func uniqueLocalTemporarySibling(
    of destination: URL,
    prefix: String
  ) -> URL {
    let directory = destination.deletingLastPathComponent()
    while true {
      let candidate = directory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString.lowercased())-\(destination.lastPathComponent)"
      )
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
  }

  private static func ensureUnambiguous(_ url: URL) throws {
    guard !NafiURL.isAmbiguousRemoteItem(url) else {
      throw RemoteServerError.unsupported(
        "接続先に同名項目が複数あり、安全に一意指定できません。接続先側で名前を一意にしてから操作してください。"
      )
    }
  }

  static func generatedBatchName(
    pattern: String,
    originalName: String,
    index: Int,
    preserveExtension: Bool = true
  ) throws -> String {
    let extensionName = (originalName as NSString).pathExtension
    let stem = (originalName as NSString).deletingPathExtension
    var result =
      pattern
      .replacingOccurrences(of: "[name]", with: stem)
      .replacingOccurrences(of: "[ext]", with: extensionName)

    let expression = try NSRegularExpression(pattern: "#+")
    let matches = expression.matches(
      in: result,
      range: NSRange(result.startIndex..., in: result)
    )
    for match in matches.reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      let width = match.range.length
      let number = String(format: "%0*d", width, index)
      result.replaceSubrange(range, with: number)
    }

    if preserveExtension, !pattern.contains("[ext]"), !extensionName.isEmpty {
      let currentExtension = (result as NSString).pathExtension
      if currentExtension.localizedCaseInsensitiveCompare(extensionName) != .orderedSame {
        result += ".\(extensionName)"
      }
    }
    return result
  }

  private static func filenameCollisionKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  static func recoverPendingRemoteOperations() async -> [String] {
    let loaded = await RemoteOperationJournal.shared.records()
    var warnings = loaded.warnings
    for record in loaded.records {
      do {
        guard let profile = await RemoteFileSystemRegistry.shared.profile(for: record.profileID),
          profile.configurationRevision == record.configurationRevision,
          RcloneConfiguration.fs(for: profile) == record.fs
        else {
          warnings.append("未完了のリモート操作 \(record.id.uuidString) は接続設定が変更されているため自動復旧しません。")
          continue
        }
        switch record.kind {
        case .replaceCopy, .replaceMove:
          try await recoverReplacement(record)
        case .batchRename:
          try await recoverBatchRename(record)
        }
      } catch {
        warnings.append("未完了のリモート操作 \(record.id.uuidString) を安全に復旧できませんでした。記録と保全用項目を保持します。\n\(error.localizedDescription)")
      }
    }
    return warnings
  }

  private static func makeRemoteJournal(
    kind: RemoteOperationJournalKind,
    reference: URL,
    source: URL? = nil,
    staged: URL? = nil,
    destination: URL? = nil,
    backup: URL? = nil,
    batchPlans: [RemoteRenameJournalPlan] = []
  ) async throws -> RemoteOperationJournalRecord {
    guard let profile = await RemoteFileSystemRegistry.shared.profile(for: reference) else {
      throw RemoteServerError.invalidResponse("リモート接続設定をジャーナルへ記録できません。")
    }
    let now = Date()
    return RemoteOperationJournalRecord(
      id: UUID(),
      kind: kind,
      profileID: profile.id,
      configurationRevision: profile.configurationRevision,
      fs: RcloneConfiguration.fs(for: profile),
      source: source,
      staged: staged,
      destination: destination,
      backup: backup,
      batchPlans: batchPlans,
      phase: .prepared,
      createdAt: now,
      updatedAt: now
    )
  }

  private static func recoverReplacement(
    _ record: RemoteOperationJournalRecord
  ) async throws {
    guard let destination = record.destination, let backup = record.backup,
      let destinationPath = NafiURL.remotePath(in: destination),
      let backupPath = NafiURL.remotePath(in: backup)
    else { throw RemoteServerError.invalidResponse("置換復旧記録が不完全です。") }
    let session = try await RemoteFileSystemRegistry.shared.session(for: destination)
    let destinationState = try await descriptor(at: destination)
    let backupState = try await descriptor(at: backup)

    if record.phase == .committed {
      if destinationState != nil, let backupState {
        try await removeRemote(backup, descriptor: backupState, checksCancellation: false)
        await RemoteOperationJournal.shared.remove(id: record.id)
        return
      }
      if destinationState != nil, backupState == nil {
        await RemoteOperationJournal.shared.remove(id: record.id)
        return
      }
      throw RemoteServerError.invalidResponse(
        "確定済みとして記録された置換先が見つかりません。古いバックアップを自動復元せず保持しました: \(NafiURL.displayPath(backup))"
      )
    }

    if destinationState == nil, backupState != nil {
      try await session.renameItem(at: backupPath, to: destinationPath)
      await RemoteOperationJournal.shared.remove(id: record.id)
      if let staged = record.staged, try await descriptor(at: staged) != nil {
        postMaintenanceWarning(
          "中断された置換から元の項目を復元しました。検証済み一時項目はデータ保全のため残しています: \(NafiURL.displayPath(staged))"
        )
      }
      return
    }

    if destinationState != nil, backupState == nil {
      if let staged = record.staged, try await descriptor(at: staged) != nil {
        postMaintenanceWarning(
          "元の項目は復元済みですが、一時項目をデータ保全のため残しています: \(NafiURL.displayPath(staged))"
        )
      }
      await RemoteOperationJournal.shared.remove(id: record.id)
      return
    }

    if destinationState != nil, backupState != nil {
      throw RemoteServerError.invalidResponse(
        "確定先とバックアップの両方が存在します。内容を推測して削除せず保持しました: \(NafiURL.displayPath(destination)) / \(NafiURL.displayPath(backup))"
      )
    }

    throw RemoteServerError.invalidResponse(
      "確定先とバックアップの両方が見つかりません。自動復旧を停止しました。"
    )
  }

  private static func recoverBatchRename(
    _ record: RemoteOperationJournalRecord
  ) async throws {
    guard !record.batchPlans.isEmpty else {
      throw RemoteServerError.invalidResponse("一括名称変更の復旧記録が空です。")
    }
    let reference = record.batchPlans[0].original
    let session = try await RemoteFileSystemRegistry.shared.session(for: reference)
    var states: [(RemoteRenameJournalPlan, Bool, Bool, Bool)] = []
    for plan in record.batchPlans {
      states.append((
        plan,
        try await descriptor(at: plan.original) != nil,
        try await descriptor(at: plan.temporary) != nil,
        try await descriptor(at: plan.destination) != nil
      ))
    }

    if states.allSatisfy({ $0.1 && !$0.2 && !$0.3 })
      || states.allSatisfy({ !$0.1 && !$0.2 && $0.3 })
    {
      await RemoteOperationJournal.shared.remove(id: record.id)
      return
    }

    guard states.allSatisfy({ !$0.3 }) else {
      throw RemoteServerError.invalidResponse(
        "一括名称変更が途中まで確定されています。元名・一時名・新名を推測で変更せず保持しました。"
      )
    }

    for (plan, originalExists, temporaryExists, _) in states.reversed() {
      if originalExists && temporaryExists {
        throw RemoteServerError.invalidResponse(
          "元名と一時名の両方が存在するため、自動復旧を停止しました: \(NafiURL.displayPath(plan.original))"
        )
      }
      guard !originalExists, temporaryExists,
        let temporaryPath = NafiURL.remotePath(in: plan.temporary),
        let originalPath = NafiURL.remotePath(in: plan.original)
      else { continue }
      try await session.renameItem(at: temporaryPath, to: originalPath)
    }
    var restored = true
    for plan in record.batchPlans {
      let originalExists = try await descriptor(at: plan.original) != nil
      let temporaryExists = try await descriptor(at: plan.temporary) != nil
      if !originalExists || temporaryExists {
        restored = false
        break
      }
    }
    guard restored else {
      throw RemoteServerError.invalidResponse("一括名称変更を完全には復元できませんでした。")
    }
    await RemoteOperationJournal.shared.remove(id: record.id)
  }

  private static func executeLocalRenameTransaction(
    _ plans: [BatchRenamePlan]
  ) throws {
    let fileManager = FileManager.default
    var stagedCount = 0
    do {
      for plan in plans {
        try Task.checkCancellation()
        try fileManager.moveItem(at: plan.original, to: plan.temporary)
        stagedCount += 1
      }
    } catch {
      var rollbackFailures: [String] = []
      for plan in plans.prefix(stagedCount).reversed() {
        do { try fileManager.moveItem(at: plan.temporary, to: plan.original) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      if rollbackFailures.isEmpty { throw error }
      throw RemoteServerError.invalidResponse(
        "一括名称変更の準備に失敗し、一部を復元できませんでした。\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }

    var committedCount = 0
    do {
      for plan in plans {
        try Task.checkCancellation()
        try fileManager.moveItem(at: plan.temporary, to: plan.destination)
        committedCount += 1
      }
    } catch {
      let originalError = error
      var rollbackFailures: [String] = []
      for plan in plans.prefix(committedCount).reversed() {
        do { try fileManager.moveItem(at: plan.destination, to: plan.temporary) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      for plan in plans {
        guard fileManager.fileExists(atPath: plan.temporary.path) else { continue }
        do { try fileManager.moveItem(at: plan.temporary, to: plan.original) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      if rollbackFailures.isEmpty { throw originalError }
      throw RemoteServerError.invalidResponse(
        "一括名称変更に失敗し、一部を復元できませんでした。\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }
  }

  private static func executeRemoteRenameTransaction(
    _ plans: [BatchRenamePlan],
    session: any RemoteServerSession
  ) async throws {
    var paths: [(original: String, temporary: String, destination: String)] = []
    for plan in plans {
      guard let original = NafiURL.remotePath(in: plan.original),
        let temporary = NafiURL.remotePath(in: plan.temporary),
        let destination = NafiURL.remotePath(in: plan.destination)
      else { throw RemoteServerError.invalidResponse("リモートパスが正しくありません。") }
      paths.append((original, temporary, destination))
    }

    var stagedCount = 0
    do {
      for path in paths {
        try Task.checkCancellation()
        try await session.renameItem(at: path.original, to: path.temporary)
        stagedCount += 1
      }
    } catch {
      var rollbackFailures: [String] = []
      for path in paths.prefix(stagedCount).reversed() {
        do { try await session.renameItem(at: path.temporary, to: path.original) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      if rollbackFailures.isEmpty { throw error }
      throw RemoteServerError.invalidResponse(
        "一括名称変更の準備に失敗し、一部を復元できませんでした。\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }

    var committedCount = 0
    do {
      for path in paths {
        try Task.checkCancellation()
        try await session.renameItem(at: path.temporary, to: path.destination)
        committedCount += 1
      }
    } catch {
      let originalError = error
      var rollbackFailures: [String] = []
      for path in paths.prefix(committedCount).reversed() {
        do { try await session.renameItem(at: path.destination, to: path.temporary) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      for path in paths {
        do { try await session.renameItem(at: path.temporary, to: path.original) } catch {
          rollbackFailures.append(error.localizedDescription)
        }
      }
      if rollbackFailures.isEmpty { throw originalError }
      throw RemoteServerError.invalidResponse(
        "一括名称変更に失敗し、一部を復元できませんでした。\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }
  }

  private static func makeStagingDirectory() throws -> URL {
    let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
  }

  private static func uniqueLocalURL(for name: String, in directory: URL) -> URL {
    let desired = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: desired.path) else { return desired }
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var index = 2
    while true {
      let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
      let candidate = directory.appendingPathComponent(candidateName)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      index += 1
    }
  }

  private static func validatedName(_ name: String) throws -> String {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != ".", clean != "..", !clean.contains("/"),
      clean.utf8.count <= 255,
      !clean.unicodeScalars.contains(where: { $0.value == 0 || $0 == "\r" || $0 == "\n" })
    else {
      throw RemoteServerError.invalidName
    }
    return clean
  }

  private static func postMaintenanceWarning(_ message: String) {
    let post = {
      NotificationCenter.default.post(
        name: .nafiMaintenanceWarning,
        object: nil,
        userInfo: ["message": message]
      )
    }
    if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
  }

  private static func notifyChanges(in directories: [URL]) {
    var seen = Set<String>()
    let changedDirectories = directories.compactMap { directory -> URL? in
      let normalized = NafiURL.normalized(directory)
      guard let key = NafiURL.locationKey(normalized), seen.insert(key).inserted else {
        return nil
      }
      return normalized
    }
    let notification = {
      NotificationCenter.default.post(
        name: .nafiFileSystemDidChange,
        object: nil,
        userInfo: ["directories": changedDirectories]
      )
    }
    if Thread.isMainThread {
      notification()
    } else {
      DispatchQueue.main.async(execute: notification)
    }
  }
}
