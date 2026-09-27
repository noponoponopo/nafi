import Foundation

actor RcloneRemoteSession: RemoteServerSession {
  let profile: ServerProfile
  private let runtime: RcloneRuntime
  private var secrets: RcloneProfileSecrets
  private let sftpHostKeyAlgorithms: [String]
  private(set) var capabilities: RcloneRemoteCapabilities
  private var isClosed = false
  private struct CachedDirectory {
    let loadedAt: Date
    let items: [RemoteFileItem]
  }
  private struct DirectoryLoad {
    let id: UUID
    let task: Task<[RemoteFileItem], Error>
  }
  private var cacheGeneration: UInt64 = 0
  private var directoryLoading: [String: DirectoryLoad] = [:]
  private var directoryCache: [String: CachedDirectory] = [:]
  private let directoryCacheLifetime: TimeInterval = 2.5
  private let maximumCachedDirectories = 256

  private struct CachedRecursiveCatalog {
    let loadedAt: Date
    let rootPath: String
    let items: [RemoteFileItem]
  }
  private var recursiveCatalogCache: [String: CachedRecursiveCatalog] = [:]
  private var recursiveCatalogLoading: [String: DirectoryLoad] = [:]
  // Search catalog data is metadata only. Five minutes avoids repeatedly asking
  // cloud providers for the same tree while still bounding remote-only staleness.
  private let recursiveCatalogLifetime: TimeInterval = 5 * 60
  private let maximumRecursiveCatalogRoots = 4

  private init(
    profile: ServerProfile,
    runtime: RcloneRuntime,
    secrets: RcloneProfileSecrets,
    sftpHostKeyAlgorithms: [String],
    capabilities: RcloneRemoteCapabilities
  ) {
    self.profile = profile
    self.runtime = runtime
    self.secrets = secrets
    self.sftpHostKeyAlgorithms = sftpHostKeyAlgorithms
    self.capabilities = capabilities
  }

  static func connect(
    profile: ServerProfile,
    secrets: RcloneProfileSecrets,
    runtime: RcloneRuntime = .shared
  ) async throws -> RcloneRemoteSession {
    let sftpHostKeyAlgorithms: [String]
    if profile.kind == .sftp {
      sftpHostKeyAlgorithms = try await SSHHostKeyService.shared.prepareKnownHosts(
        host: profile.host,
        port: profile.port
      )
      guard !sftpHostKeyAlgorithms.isEmpty else {
        throw RemoteServerError.invalidResponse(
          "SSHホストキーが登録されていません。設定画面で指紋を確認して信頼してください。"
        )
      }
    } else {
      sftpHostKeyAlgorithms = []
    }
    var currentSecrets = secrets
    if let token = try await runtime.configure(
      profile: profile,
      secrets: currentSecrets,
      sftpHostKeyAlgorithms: sftpHostKeyAlgorithms
    ) {
      currentSecrets = try currentSecrets.replacingOAuthToken(token)
    }
    let response = try await runtime.call(
      "operations/fsinfo",
      parameters: ["fs": .string(RcloneConfiguration.fs(for: profile))]
    )
    let session = RcloneRemoteSession(
      profile: profile,
      runtime: runtime,
      secrets: currentSecrets,
      sftpHostKeyAlgorithms: sftpHostKeyAlgorithms,
      capabilities: RcloneRemoteCapabilities(response: response)
    )
    return session
  }

  func listDirectory(at path: String) async throws -> [RemoteFileItem] {
    try Task.checkCancellation()
    guard !isClosed else { throw RemoteServerError.notConnected }
    let cacheKey = RemotePath.normalized(path)
    if let cached = directoryCache[cacheKey],
      Date().timeIntervalSince(cached.loadedAt) <= directoryCacheLifetime
    {
      return cached.items
    }
    if let pending = directoryLoading[cacheKey] {
      let expectedGeneration = cacheGeneration
      let items = try await pending.task.value
      guard !isClosed, cacheGeneration == expectedGeneration else { throw CancellationError() }
      try Task.checkCancellation()
      return items
    }
    let generation = cacheGeneration
    let id = UUID()
    let task = Task { try await self.loadDirectory(at: cacheKey) }
    directoryLoading[cacheKey] = DirectoryLoad(id: id, task: task)
    defer {
      if directoryLoading[cacheKey]?.id == id { directoryLoading[cacheKey] = nil }
    }
    let items = try await task.value
    guard !isClosed, generation == cacheGeneration else { throw CancellationError() }
    directoryCache[cacheKey] = CachedDirectory(loadedAt: Date(), items: items)
    if directoryCache.count > maximumCachedDirectories {
      for key in directoryCache.sorted(by: { $0.value.loadedAt < $1.value.loadedAt })
        .prefix(directoryCache.count - maximumCachedDirectories).map(\.key)
      {
        directoryCache[key] = nil
      }
    }
    try Task.checkCancellation()
    return items
  }

  private func loadDirectory(at path: String) async throws -> [RemoteFileItem] {
    try await ensureReady()
    let cleanPath = try remoteArgument(path)
    let response = try await listDirectoryResponse(at: cleanPath)
    guard let raw = response["list"] else { return [] }
    let data = try JSONEncoder().encode(raw)
    let entries = try JSONDecoder().decode([RcloneListEntry].self, from: data)
    guard entries.count <= 1_000_000 else {
      throw RemoteServerError.invalidResponse("一覧が100万項目を超えました。検索またはフィルターを使用してください。")
    }

    func duplicateKey(_ name: String) -> String {
      guard capabilities.caseInsensitive else { return name.precomposedStringWithCanonicalMapping }
      return name.precomposedStringWithCanonicalMapping.folding(
        options: [.caseInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
    }
    let groups = Dictionary(grouping: entries, by: { duplicateKey($0.name) })
    var occurrenceByKey: [String: Int] = [:]
    let items = entries.map { entry in
      let key = duplicateKey(entry.name)
      occurrenceByKey[key, default: 0] += 1
      let position = occurrenceByKey[key] ?? 1
      let isAmbiguous = (groups[key]?.count ?? 0) > 1
      let token =
        isAmbiguous
        ? (entry.id ?? "index:\(position):\(entry.path)")
        : nil
      let displayName = isAmbiguous ? "\(entry.name) — 重複 \(position)" : entry.name
      return RemoteFileItem(
        name: displayName,
        path: RemotePath.appending(entry.name, to: path),
        isDirectory: entry.isDir,
        size: entry.size.flatMap { $0 >= 0 ? UInt64($0) : nil },
        modifiedAt: entry.modTime,
        stableID: entry.id,
        mimeType: entry.mimeType,
        hashes: entry.hashes,
        metadata: entry.metadata,
        ambiguityToken: token
      )
    }.sorted(by: remoteItemSort)
    try Task.checkCancellation()
    return items
  }

  func recursiveCatalog(at path: String) async throws -> [RemoteFileItem] {
    try Task.checkCancellation()
    guard !isClosed else { throw RemoteServerError.notConnected }
    let rootPath = RemotePath.normalized(path)
    let now = Date()

    // A cached ancestor catalog can answer a descendant search without another
    // remote API call. Prefer the nearest ancestor to minimize in-memory work.
    let covering = recursiveCatalogCache.values
      .filter {
        now.timeIntervalSince($0.loadedAt) <= recursiveCatalogLifetime
          && Self.path($0.rootPath, contains: rootPath)
      }
      .max { $0.rootPath.count < $1.rootPath.count }
    if let covering {
      if covering.rootPath == rootPath { return covering.items }
      return covering.items.filter { Self.path(rootPath, contains: $0.path) }
    }

    // Actor reentrancy means a second pane can enter while the first request is
    // awaiting rclone. Share the in-flight catalog build instead of issuing a
    // duplicate full-tree listing.
    if let (loadingRoot, loading) = coveringRecursiveLoad(for: rootPath) {
      let expectedGeneration = cacheGeneration
      let items = try await loading.value
      guard !isClosed, cacheGeneration == expectedGeneration else { throw CancellationError() }
      try Task.checkCancellation()
      return loadingRoot == rootPath
        ? items : items.filter { Self.path(rootPath, contains: $0.path) }
    }

    // Do not wake/configure rclone when the metadata catalog can answer the
    // search entirely from memory. Only a genuine cache miss crosses into the
    // runtime. Recheck after the await because another pane may have filled it.
    try await ensureReady()
    let refreshedNow = Date()
    let refreshedCovering = recursiveCatalogCache.values
      .filter {
        refreshedNow.timeIntervalSince($0.loadedAt) <= recursiveCatalogLifetime
          && Self.path($0.rootPath, contains: rootPath)
      }
      .max { $0.rootPath.count < $1.rootPath.count }
    if let refreshedCovering {
      return refreshedCovering.rootPath == rootPath
        ? refreshedCovering.items
        : refreshedCovering.items.filter { Self.path(rootPath, contains: $0.path) }
    }
    if let (loadingRoot, loading) = coveringRecursiveLoad(for: rootPath) {
      let expectedGeneration = cacheGeneration
      let items = try await loading.value
      guard !isClosed, cacheGeneration == expectedGeneration else { throw CancellationError() }
      try Task.checkCancellation()
      return loadingRoot == rootPath
        ? items : items.filter { Self.path(rootPath, contains: $0.path) }
    }

    let id = UUID()
    let generation = cacheGeneration
    let task = Task<[RemoteFileItem], Error> { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.loadRecursiveCatalog(rootPath: rootPath)
    }
    recursiveCatalogLoading[rootPath] = DirectoryLoad(id: id, task: task)
    defer {
      if recursiveCatalogLoading[rootPath]?.id == id { recursiveCatalogLoading[rootPath] = nil }
    }
    do {
      let items = try await task.value
      guard !isClosed, generation == cacheGeneration, !task.isCancelled else {
        throw CancellationError()
      }
      // Preserve successful work even when the pane that initiated the load was
      // canceled after another pane had already joined the same request.
      recursiveCatalogCache[rootPath] = CachedRecursiveCatalog(
        loadedAt: Date(),
        rootPath: rootPath,
        items: items
      )
      trimRecursiveCatalogCacheIfNeeded()
      try Task.checkCancellation()
      return items
    } catch {
      throw error
    }
  }

  private func coveringRecursiveLoad(
    for rootPath: String
  ) -> (String, Task<[RemoteFileItem], Error>)? {
    recursiveCatalogLoading
      .filter { Self.path($0.key, contains: rootPath) }
      .max { $0.key.count < $1.key.count }
      .map { ($0.key, $0.value.task) }
  }

  private func loadRecursiveCatalog(rootPath: String) async throws -> [RemoteFileItem] {
    guard !Self.isLinuxPseudoFilesystemPath(rootPath) else {
      throw RemoteServerError.invalidResponse(
        "Linuxの擬似ファイルシステムは再帰検索の対象外です。"
      )
    }
    let cleanPath = try remoteArgument(rootPath)
    let options: [String: JSONValue] = [
      "recurse": .bool(true),
      "showHash": .bool(false),
      "noMimeType": .bool(true),
      "metadata": .bool(false),
    ]
    var parameters: [String: JSONValue] = [
      "fs": .string(RcloneConfiguration.fs(for: profile)),
      "remote": .string(cleanPath),
      "opt": .object(options),
    ]
    if rootPath == "/" {
      parameters["_filter"] = .object([
        "ExcludeRule": .array([.string("proc/**"), .string("sys/**"), .string("dev/**")])
      ])
    }
    let response = try await runtime.call(
      "operations/list",
      parameters: parameters,
      timeout: 300
    )
    guard let raw = response["list"] else { return [] }
    let data = try JSONEncoder().encode(raw)
    let entries = try JSONDecoder().decode([RcloneListEntry].self, from: data)
    guard entries.count <= 250_000 else {
      throw RemoteServerError.invalidResponse(
        "検索インデックスが25万項目を超えました。より狭いフォルダから検索してください。"
      )
    }

    func duplicateKey(_ relativePath: String) -> String {
      let canonical = relativePath.precomposedStringWithCanonicalMapping
      guard capabilities.caseInsensitive else { return canonical }
      return canonical.folding(
        options: [.caseInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
    }

    let relativePaths = entries.map { entry in entry.path.isEmpty ? entry.name : entry.path }
    let groups = Dictionary(
      grouping: zip(entries.indices, relativePaths), by: { duplicateKey($0.1) })
    var occurrenceByKey: [String: Int] = [:]
    var items: [RemoteFileItem] = []
    items.reserveCapacity(entries.count)

    for (index, entry) in entries.enumerated() {
      try Task.checkCancellation()
      let relativePath = relativePaths[index]
      let key = duplicateKey(relativePath)
      occurrenceByKey[key, default: 0] += 1
      let position = occurrenceByKey[key] ?? 1
      let isAmbiguous = (groups[key]?.count ?? 0) > 1
      let token = isAmbiguous ? (entry.id ?? "index:\(position):\(relativePath)") : nil
      let displayName = isAmbiguous ? "\(entry.name) — 重複 \(position)" : entry.name
      items.append(
        RemoteFileItem(
          name: displayName,
          path: RemotePath.appending(relativePath, to: rootPath),
          isDirectory: entry.isDir,
          size: entry.size.flatMap { $0 >= 0 ? UInt64($0) : nil },
          modifiedAt: entry.modTime,
          stableID: entry.id,
          ambiguityToken: token
        )
      )
    }
    return items
  }

  private func trimRecursiveCatalogCacheIfNeeded() {
    guard recursiveCatalogCache.count > maximumRecursiveCatalogRoots else { return }
    let overflow = recursiveCatalogCache.count - maximumRecursiveCatalogRoots
    for key
      in recursiveCatalogCache
      .sorted(by: { $0.value.loadedAt < $1.value.loadedAt })
      .prefix(overflow)
      .map(\.key)
    {
      recursiveCatalogCache[key] = nil
    }
  }

  func invalidateSearchCache() async {
    cacheGeneration &+= 1
    directoryLoading.values.forEach { $0.task.cancel() }
    directoryLoading.removeAll(keepingCapacity: true)
    directoryCache.removeAll(keepingCapacity: true)
    recursiveCatalogLoading.values.forEach { $0.task.cancel() }
    recursiveCatalogLoading.removeAll(keepingCapacity: true)
    recursiveCatalogCache.removeAll(keepingCapacity: true)
  }

  private static func path(_ ancestor: String, contains descendant: String) -> Bool {
    let parent = RemotePath.normalized(ancestor)
    let child = RemotePath.normalized(descendant)
    if parent == "/" { return true }
    return child == parent || child.hasPrefix(parent + "/")
  }

  private static func isLinuxPseudoFilesystemPath(_ path: String) -> Bool {
    guard
      let first = RemotePath.normalized(path)
        .split(separator: "/", omittingEmptySubsequences: true).first
    else { return false }
    return first == "proc" || first == "sys" || first == "dev"
  }

  private func listDirectoryResponse(at path: String) async throws -> [String: JSONValue] {
    try await runtime.call(
      "operations/list",
      parameters: [
        "fs": .string(RcloneConfiguration.fs(for: profile)),
        "remote": .string(path),
        "opt": .object([
          "recurse": .bool(false),
          "showHash": .bool(false),
          "noMimeType": .bool(true),
          "metadata": .bool(false),
        ]),
      ],
      timeout: 90
    )
  }

  func prepareForTransfer() async throws {
    try await ensureReady()
  }

  static func isHostKeyRelatedErrorMessage(_ rawMessage: String) -> Bool {
    let message = rawMessage.lowercased()
    return message.contains("knownhosts: key is unknown")
      || message.contains("knownhosts: key mismatch")
      || message.contains("knownhosts: key is revoked")
      || message.contains("couldn't parse known_hosts_file")
      || message.contains("sshホストキーが登録されていません")
  }

  func statItem(at path: String) async throws -> RemoteFileItem? {
    do {
      guard let entry = try await stat(at: path) else { return nil }
      return RemoteFileItem(
        name: entry.name.isEmpty ? RemotePath.name(of: path) : entry.name,
        path: RemotePath.normalized(path),
        isDirectory: entry.isDir,
        size: entry.size.flatMap { $0 >= 0 ? UInt64($0) : nil },
        modifiedAt: entry.modTime,
        stableID: entry.id,
        mimeType: entry.mimeType,
        hashes: entry.hashes,
        metadata: entry.metadata
      )
    } catch {
      guard isReadOnlyBoxMetadataError(error) else { throw error }
      let normalized = RemotePath.normalized(path)
      return try await listDirectory(at: RemotePath.parent(of: path)).first {
        RemotePath.normalized($0.path) == normalized
      }
    }
  }

  func createDirectory(at path: String) async throws {
    try await ensureReady()
    _ = try await runtime.call(
      "operations/mkdir",
      parameters: [
        "fs": .string(RcloneConfiguration.fs(for: profile)),
        "remote": .string(try remoteArgument(path)),
      ]
    )
    invalidateCache(containing: path)
    await FileProviderChangeNotifier.signal(profileID: profile.id)
  }

  func renameItem(at oldPath: String, to newPath: String) async throws {
    try await ensureReady()
    let oldRemote = try remoteArgument(oldPath)
    let newRemote = try remoteArgument(newPath)
    let stat = try await stat(at: oldPath)
    if stat?.isDir == true {
      try await moveDirectorySafely(from: oldRemote, to: newRemote)
    } else {
      _ = try await runtime.call(
        "operations/movefile",
        parameters: [
          "srcFs": .string(RcloneConfiguration.fs(for: profile)),
          "srcRemote": .string(oldRemote),
          "dstFs": .string(RcloneConfiguration.fs(for: profile)),
          "dstRemote": .string(newRemote),
        ],
        timeout: 180
      )
    }
    invalidateCache(containing: oldPath)
    invalidateCache(containing: newPath)
    await FileProviderChangeNotifier.signal(profileID: profile.id)
  }

  func removeItem(at path: String, isDirectory: Bool) async throws {
    try await ensureReady()
    if isDirectory {
      try await runAndWait(
        method: "operations/purge",
        parameters: [
          "fs": .string(RcloneConfiguration.fs(for: profile)),
          "remote": .string(try remoteArgument(path)),
        ]
      )
    } else {
      _ = try await runtime.call(
        "operations/deletefile",
        parameters: [
          "fs": .string(RcloneConfiguration.fs(for: profile)),
          "remote": .string(try remoteArgument(path)),
        ]
      )
    }
    invalidateCache(containing: path)
    await FileProviderChangeNotifier.signal(profileID: profile.id)
  }

  func downloadItem(at remotePath: String, to localURL: URL) async throws {
    try await ensureReady()
    let remote = try remoteArgument(remotePath)
    do {
      let info = try await stat(at: remotePath)
      if info?.isDir == true {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        try await runAndWait(
          method: "sync/copy",
          parameters: [
            "srcFs": .string(joinedFS(path: remote)),
            "dstFs": .string(localURL.path),
            "createEmptySrcDirs": .bool(true),
          ]
        )
      } else {
        try FileManager.default.createDirectory(
          at: localURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        _ = try await runtime.call(
          "operations/copyfile",
          parameters: [
            "srcFs": .string(RcloneConfiguration.fs(for: profile)),
            "srcRemote": .string(remote),
            "dstFs": .string("/"),
            "dstRemote": .string(localArgument(localURL)),
          ],
          timeout: 86_400
        )
      }
    } catch {
      guard isReadOnlyBoxMetadataError(error) else { throw error }
      try await downloadReadOnlyBoxFile(at: remotePath, to: localURL, originalError: error)
    }
  }

  private func isReadOnlyBoxMetadataError(_ error: Error) -> Bool {
    guard profile.rcloneBackend.caseInsensitiveCompare("box") == .orderedSame else { return false }
    let message = error.localizedDescription
    return message.contains("pre-upload check")
      && message.contains("access_denied_insufficient_permissions")
  }

  private func downloadReadOnlyBoxFile(
    at remotePath: String,
    to localURL: URL,
    originalError: Error
  ) async throws {
    let parent = RemotePath.parent(of: remotePath)
    let name = RemotePath.name(of: remotePath)
    let item = try await listDirectory(at: parent).first {
      RemotePath.normalized($0.path) == RemotePath.normalized(remotePath)
    }
    guard item?.isDirectory == false else { throw originalError }

    let destinationParent = localURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: destinationParent, withIntermediateDirectories: true)
    let staging = destinationParent.appendingPathComponent(
      ".nafi-box-download-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }

    try await runAndWait(
      method: "sync/copy",
      parameters: [
        "srcFs": .string(joinedFS(path: parent)),
        "dstFs": .string(staging.path),
        "createEmptySrcDirs": .bool(false),
        "_filter": Self.exactFileFilter(named: name),
      ]
    )
    let downloaded = staging.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: downloaded.path) else { throw originalError }
    try FileManager.default.moveItem(at: downloaded, to: localURL)
  }

  static func exactFileFilter(named name: String) -> JSONValue {
    let reserved = Set("*?\\[{}")
    let escaped = name.reduce(into: "") { result, character in
      if reserved.contains(character) { result.append("\\") }
      result.append(character)
    }
    return .object(["IncludeRule": .array([.string("/\(escaped)")])])
  }

  func uploadItem(from localURL: URL, to remotePath: String) async throws {
    try await ensureReady()
    let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
    let remote = try remoteArgument(remotePath)
    if values.isDirectory == true {
      try await runAndWait(
        method: "sync/copy",
        parameters: [
          "srcFs": .string(localURL.path),
          "dstFs": .string(joinedFS(path: remote)),
          "createEmptySrcDirs": .bool(true),
        ]
      )
    } else {
      _ = try await runtime.call(
        "operations/copyfile",
        parameters: [
          "srcFs": .string("/"),
          "srcRemote": .string(localArgument(localURL)),
          "dstFs": .string(RcloneConfiguration.fs(for: profile)),
          "dstRemote": .string(remote),
        ],
        timeout: 86_400
      )
    }
    invalidateCache(containing: remotePath)
    await FileProviderChangeNotifier.signal(profileID: profile.id)
  }

  func close() async {
    isClosed = true
    cacheGeneration &+= 1
    directoryLoading.values.forEach { $0.task.cancel() }
    directoryLoading.removeAll()
    directoryCache.removeAll()
    recursiveCatalogLoading.values.forEach { $0.task.cancel() }
    recursiveCatalogLoading.removeAll()
    recursiveCatalogCache.removeAll()
  }

  func stat(at path: String) async throws -> RcloneListEntry? {
    try await ensureReady()
    let response = try await runtime.call(
      "operations/stat",
      parameters: [
        "fs": .string(RcloneConfiguration.fs(for: profile)),
        "remote": .string(try remoteArgument(path)),
        "opt": .object([
          "showHash": .bool(false),
          "noMimeType": .bool(true),
          "metadata": .bool(false),
        ]),
      ]
    )
    guard let item = response["item"], item != .null else { return nil }
    let data = try JSONEncoder().encode(item)
    return try JSONDecoder().decode(RcloneListEntry.self, from: data)
  }

  private func moveDirectorySafely(from oldRemote: String, to newRemote: String) async throws {
    let source = joinedFS(path: oldRemote)
    let destination = joinedFS(path: newRemote)
    if capabilities.dirMove {
      try await runAndWait(
        method: "sync/move",
        parameters: [
          "srcFs": .string(source),
          "dstFs": .string(destination),
          "createEmptySrcDirs": .bool(true),
          "deleteEmptySrcDirs": .bool(true),
        ]
      )
      return
    }

    // Backends without a native directory move cannot provide an atomic rename.
    // Keep the source intact until a complete copy and backend-aware comparison
    // have both succeeded. A failed source purge can leave two complete copies,
    // but never a silently truncated source.
    do {
      try await runAndWait(
        method: "sync/copy",
        parameters: [
          "srcFs": .string(source),
          "dstFs": .string(destination),
          "createEmptySrcDirs": .bool(true),
        ]
      )
      try await runAndWait(
        method: "operations/check",
        parameters: [
          "srcFs": .string(source),
          "dstFs": .string(destination),
          "oneWay": .bool(false),
          "download": .bool(false),
        ]
      )
    } catch {
      _ = try? await runtime.call(
        "operations/purge",
        parameters: [
          "fs": .string(RcloneConfiguration.fs(for: profile)),
          "remote": .string(newRemote),
        ],
        timeout: 86_400
      )
      throw error
    }

    do {
      try await runAndWait(
        method: "operations/purge",
        parameters: [
          "fs": .string(RcloneConfiguration.fs(for: profile)),
          "remote": .string(oldRemote),
        ]
      )
    } catch {
      throw RemoteServerError.invalidResponse(
        "フォルダのコピーと検証は完了しましたが、移動元を削除できませんでした。両方の完全なコピーが残っています。\n\(error.localizedDescription)"
      )
    }
  }

  private func runAndWait(method: String, parameters: [String: JSONValue]) async throws {
    var payload = parameters
    payload["_async"] = .bool(true)
    payload["_group"] = .string("nafi-session-\(UUID().uuidString)")
    let job: RcloneJobReference = try await runtime.callDecodable(
      method,
      parameters: payload,
      timeout: 90
    )
    var pollDelay: UInt64 = 200_000_000
    do {
      while true {
        try Task.checkCancellation()
        let status: RcloneJobStatus = try await runtime.callDecodable(
          "job/status",
          parameters: ["jobid": .integer(job.jobID)]
        )
        guard status.executeID == job.executeID else {
          throw RemoteServerError.invalidResponse(
            "rcloneが再起動され、処理ジョブの世代が変わりました。安全のため結果を採用しません。"
          )
        }
        if status.finished {
          guard status.success == true, status.error.isEmpty else {
            throw RemoteServerError.invalidResponse(
              status.error.isEmpty ? "rclone処理に失敗しました。" : status.error)
          }
          return
        }
        // Poll aggressively for short metadata operations, then back off to
        // avoid burning CPU on long-running remote jobs.
        try await Task.sleep(nanoseconds: pollDelay)
        pollDelay = min(5_000_000_000, pollDelay * 2)
      }
    } catch {
      let runtime = self.runtime
      await Task.detached(priority: .utility) {
        guard
          let status: RcloneJobStatus = try? await runtime.callDecodable(
            "job/status",
            parameters: ["jobid": .integer(job.jobID)]
          ), status.executeID == job.executeID
        else { return }
        _ = try? await runtime.call("job/stop", parameters: ["jobid": .integer(job.jobID)])
      }.value
      throw error
    }
  }

  private func invalidateCache(containing path: String) {
    cacheGeneration &+= 1
    directoryLoading.values.forEach { $0.task.cancel() }
    directoryLoading.removeAll(keepingCapacity: true)
    let normalized = RemotePath.normalized(path)
    directoryCache[normalized] = nil
    directoryCache[RemotePath.parent(of: normalized)] = nil
    // Any mutation may affect an ancestor recursive catalog. Cancel in-flight
    // builds too, otherwise a stale pre-mutation listing could be cached after
    // the write has completed.
    recursiveCatalogLoading.values.forEach { $0.task.cancel() }
    recursiveCatalogLoading.removeAll(keepingCapacity: true)
    recursiveCatalogCache.removeAll(keepingCapacity: true)
  }

  private func joinedFS(path: String) -> String {
    RclonePath.combinedFS(RcloneConfiguration.fs(for: profile), path: path)
  }

  private func remoteArgument(_ path: String) throws -> String {
    let validated = try RemotePath.validatedForCommand(path)
    return validated.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func localArgument(_ url: URL) -> String {
    url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func ensureReady() async throws {
    if isClosed { throw RemoteServerError.notConnected }
    if let token = try await runtime.configure(
      profile: profile,
      secrets: secrets,
      sftpHostKeyAlgorithms: sftpHostKeyAlgorithms
    ) {
      secrets = try secrets.replacingOAuthToken(token)
    }
    try Task.checkCancellation()
    guard !isClosed else { throw RemoteServerError.notConnected }
  }

  func updateOAuthToken(_ token: String) throws {
    secrets = try secrets.replacingOAuthToken(token)
  }
}
