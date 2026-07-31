import Foundation

enum TransferEngineID: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case native
  case rclone

  var id: String { rawValue }
  var label: String {
    switch self {
    case .automatic: "自動"
    case .native: "macOS標準"
    case .rclone: "rclone"
    }
  }
}

struct TransferEndpoint: Hashable, Sendable {
  let fs: String
  let path: String
  let isRemote: Bool
  let profileID: UUID?

  static func resolve(_ url: URL) async throws -> TransferEndpoint {
    if NafiURL.isAmbiguousRemoteItem(url) {
      throw RemoteServerError.unsupported(
        "同名のリモート項目はrcloneの汎用パスAPIで安全に一意指定できません。"
      )
    }
    if NafiURL.isRemote(url) {
      guard let profile = await RemoteFileSystemRegistry.shared.profile(for: url),
        let path = NafiURL.remotePath(in: url)
      else { throw RemoteServerError.invalidResponse("リモート接続を解決できません。") }
      return TransferEndpoint(
        fs: RcloneConfiguration.fs(for: profile),
        path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        isRemote: true,
        profileID: profile.id
      )
    }
    return TransferEndpoint(
      fs: "/",
      path: url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      isRemote: false,
      profileID: nil
    )
  }

  var combinedFS: String { RclonePath.combinedFS(fs, path: path) }
}

struct TransferEngineProgress: Codable, Hashable, Sendable {
  let bytesTransferred: Int64
  let totalBytes: Int64
  let bytesPerSecond: Double
  let estimatedSecondsRemaining: Double?
  let currentItem: String?
  let completedItems: Int64
  let totalItems: Int64

  var fractionCompleted: Double {
    guard totalBytes > 0 else {
      return totalItems > 0 ? min(1, Double(completedItems) / Double(totalItems)) : 0
    }
    return min(1, Double(bytesTransferred) / Double(totalBytes))
  }
}

struct TransferEngineResult: Hashable, Sendable {
  let bytesTransferred: Int64
  let checks: Int64
  let transferredItems: Int64
  let errorCount: Int64
}

protocol TransferEngine: Sendable {
  var id: TransferEngineID { get }

  func copy(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult

  func move(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult

  func check(source: URL, destination: URL, download: Bool) async throws
}

enum TransferEngineSelector {
  static func engine(
    preference: TransferEngineID = .automatic,
    source: URL,
    destination: URL
  ) -> any TransferEngine {
    switch preference {
    case .native:
      return NativeTransferEngine()
    case .rclone:
      return RcloneTransferEngine()
    case .automatic:
      if NafiURL.isRemote(source) || NafiURL.isRemote(destination) {
        return RcloneTransferEngine()
      }
      return NativeTransferEngine()
    }
  }
}

struct NativeTransferEngine: TransferEngine {
  let id = TransferEngineID.native

  func copy(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    guard !NafiURL.isRemote(source), !NafiURL.isRemote(destination) else {
      throw RemoteServerError.unsupported("macOS標準エンジンはrclone管理リモートを直接処理しません。")
    }
    return try await Task.detached(priority: .userInitiated) {
      let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
      try FileManager.default.copyItem(at: source, to: destination)
      progress(TransferEngineProgress(
        bytesTransferred: size,
        totalBytes: size,
        bytesPerSecond: 0,
        estimatedSecondsRemaining: 0,
        currentItem: source.lastPathComponent,
        completedItems: 1,
        totalItems: 1
      ))
      return TransferEngineResult(
        bytesTransferred: size,
        checks: 0,
        transferredItems: 1,
        errorCount: 0
      )
    }.value
  }

  func move(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    guard !NafiURL.isRemote(source), !NafiURL.isRemote(destination) else {
      throw RemoteServerError.unsupported("macOS標準エンジンはrclone管理リモートを直接処理しません。")
    }
    return try await Task.detached(priority: .userInitiated) {
      let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
      try FileManager.default.moveItem(at: source, to: destination)
      progress(TransferEngineProgress(
        bytesTransferred: size,
        totalBytes: size,
        bytesPerSecond: 0,
        estimatedSecondsRemaining: 0,
        currentItem: source.lastPathComponent,
        completedItems: 1,
        totalItems: 1
      ))
      return TransferEngineResult(
        bytesTransferred: size,
        checks: 0,
        transferredItems: 1,
        errorCount: 0
      )
    }.value
  }

  func check(source: URL, destination: URL, download: Bool) async throws {
    try await Task.detached(priority: .utility) {
      try FileIntegrityService.verifyEquivalent(source, destination)
    }.value
  }
}

struct RcloneTransferEngine: TransferEngine {
  let id = TransferEngineID.rclone
  private let runtime = RcloneRuntime.shared

  func copy(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    try await execute(
      method: isDirectory ? "sync/copy" : "operations/copyfile",
      source: source,
      destination: destination,
      isDirectory: isDirectory,
      progress: progress
    )
  }

  func move(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    guard !isDirectory else {
      throw RemoteServerError.unsupported(
        "ディレクトリ移動は上書き・検証・ロールバックを管理する上位トランザクションから実行してください。"
      )
    }
    return try await execute(
      method: "operations/movefile",
      source: source,
      destination: destination,
      isDirectory: false,
      progress: progress
    )
  }

  func check(source: URL, destination: URL, download: Bool) async throws {
    try await verify(
      source: source,
      destination: destination,
      isDirectory: true,
      mode: download ? .downloadAndHash : .automatic
    )
  }

  func effectiveVerificationMode(source: URL, destination: URL) async -> TransferVerificationMode {
    await effectivePolicy(source: source, destination: destination).verification
  }

  func verify(
    source: URL,
    destination: URL,
    isDirectory: Bool,
    mode: TransferVerificationMode
  ) async throws {
    let sourceEndpoint = try await TransferEndpoint.resolve(source)
    let destinationEndpoint = try await TransferEndpoint.resolve(destination)
    if isDirectory {
      var parameters: [String: JSONValue] = [
        "srcFs": .string(sourceEndpoint.combinedFS),
        "dstFs": .string(destinationEndpoint.combinedFS),
        "download": .bool(mode == .downloadAndHash),
        "oneWay": .bool(false),
      ]
      if mode == .sizeOnly {
        parameters["_config"] = .object(["SizeOnly": .bool(true)])
      }
      let response = try await runtime.call(
        "operations/check",
        parameters: parameters,
        timeout: 86_400
      )
      guard response["success"]?.boolValue == true else {
        throw RemoteServerError.invalidResponse(
          response["status"]?.stringValue ?? "転送後の一致検証に失敗しました。"
        )
      }
      return
    }

    switch mode {
    case .sizeOnly:
      try await verifyFileSize(sourceEndpoint, destinationEndpoint)
    case .downloadAndHash:
      try await verifyFileHash(
        sourceEndpoint,
        destinationEndpoint,
        algorithms: ["SHA-256"],
        download: true,
        allowSizeFallback: false
      )
    case .checksum:
      try await verifyFileHash(
        sourceEndpoint,
        destinationEndpoint,
        algorithms: ["SHA-256", "SHA-1", "MD5", "DropboxHash", "QuickXorHash"],
        download: false,
        allowSizeFallback: false
      )
    case .automatic:
      try await verifyFileHash(
        sourceEndpoint,
        destinationEndpoint,
        algorithms: ["SHA-256", "SHA-1", "MD5", "DropboxHash", "QuickXorHash"],
        download: false,
        allowSizeFallback: true
      )
    }
  }

  private func verifyFileSize(
    _ source: TransferEndpoint,
    _ destination: TransferEndpoint
  ) async throws {
    let sourceSize = try await fileSize(source)
    let destinationSize = try await fileSize(destination)
    guard sourceSize == destinationSize else {
      throw RemoteServerError.invalidResponse(
        "転送後のファイルサイズが一致しません（元: \(sourceSize)、先: \(destinationSize)）。"
      )
    }
  }

  private func fileSize(_ endpoint: TransferEndpoint) async throws -> Int64 {
    let response = try await runtime.call(
      "operations/stat",
      parameters: [
        "fs": .string(endpoint.fs),
        "remote": .string(endpoint.path),
        "opt": .object(["filesOnly": .bool(true), "noMimeType": .bool(true)]),
      ]
    )
    guard let item = response["item"]?.objectValue,
      item["IsDir"]?.boolValue != true,
      let size = item["Size"]?.intValue,
      size >= 0
    else {
      throw RemoteServerError.invalidResponse("転送後のファイルサイズを取得できません。")
    }
    return size
  }

  private func verifyFileHash(
    _ source: TransferEndpoint,
    _ destination: TransferEndpoint,
    algorithms: [String],
    download: Bool,
    allowSizeFallback: Bool
  ) async throws {
    var lastError: Error?
    for algorithm in algorithms {
      do {
        async let sourceHash = hashFile(source, algorithm: algorithm, download: download)
        async let destinationHash = hashFile(destination, algorithm: algorithm, download: download)
        let pair = try await (sourceHash, destinationHash)
        guard !pair.0.isEmpty, pair.0.caseInsensitiveCompare(pair.1) == .orderedSame else {
          throw RemoteServerError.invalidResponse("転送後の\(algorithm)が一致しません。")
        }
        return
      } catch {
        lastError = error
      }
    }
    if allowSizeFallback {
      try await verifyFileSize(source, destination)
      return
    }
    throw RemoteServerError.invalidResponse(
      "接続先間で利用できる共通チェックサムがありません。"
        + (lastError.map { "\n\($0.localizedDescription)" } ?? "")
    )
  }

  private func hashFile(
    _ endpoint: TransferEndpoint,
    algorithm: String,
    download: Bool
  ) async throws -> String {
    let response = try await runtime.call(
      "operations/hashsumfile",
      parameters: [
        "fs": .string(endpoint.fs),
        "remote": .string(endpoint.path),
        "hashType": .string(algorithm),
        "download": .bool(download),
        "base64": .bool(false),
      ],
      timeout: 86_400
    )
    guard let hash = response["hash"]?.stringValue,
      !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw RemoteServerError.invalidResponse("\(algorithm)を取得できません。") }
    return hash.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func execute(
    method: String,
    source: URL,
    destination: URL,
    isDirectory: Bool,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    let sourceEndpoint = try await TransferEndpoint.resolve(source)
    let destinationEndpoint = try await TransferEndpoint.resolve(destination)
    try await prepareRemoteSessions(
      sourceEndpoint: sourceEndpoint,
      destinationEndpoint: destinationEndpoint
    )
    return try await executeOnce(
      method: method,
      source: source,
      destination: destination,
      isDirectory: isDirectory,
      sourceEndpoint: sourceEndpoint,
      destinationEndpoint: destinationEndpoint,
      progress: progress
    )
  }

  private func prepareRemoteSessions(
    sourceEndpoint: TransferEndpoint,
    destinationEndpoint: TransferEndpoint
  ) async throws {
    var profileIDs = Set<UUID>()
    for endpoint in [sourceEndpoint, destinationEndpoint] {
      guard let profileID = endpoint.profileID, profileIDs.insert(profileID).inserted else { continue }
      let session = try await RemoteFileSystemRegistry.shared.session(for: profileID)
      if let session = session as? RcloneRemoteSession {
        try await session.prepareForTransfer()
      }
    }
  }

  private func executeOnce(
    method: String,
    source: URL,
    destination: URL,
    isDirectory: Bool,
    sourceEndpoint: TransferEndpoint,
    destinationEndpoint: TransferEndpoint,
    progress: @escaping @Sendable (TransferEngineProgress) -> Void
  ) async throws -> TransferEngineResult {
    let group = "nafi-transfer-\(UUID().uuidString)"
    var parameters: [String: JSONValue]
    if isDirectory {
      parameters = [
        "srcFs": .string(sourceEndpoint.combinedFS),
        "dstFs": .string(destinationEndpoint.combinedFS),
        "createEmptySrcDirs": .bool(true),
      ]
      if method == "sync/move" { parameters["deleteEmptySrcDirs"] = .bool(true) }
    } else {
      parameters = [
        "srcFs": .string(sourceEndpoint.fs),
        "srcRemote": .string(sourceEndpoint.path),
        "dstFs": .string(destinationEndpoint.fs),
        "dstRemote": .string(destinationEndpoint.path),
      ]
    }
    parameters["_async"] = .bool(true)
    parameters["_group"] = .string(group)
    let policy = await effectivePolicy(source: source, destination: destination)
    parameters["_config"] = .object(configOptions(for: policy))

    let job: RcloneJobReference = try await runtime.callDecodable(
      method,
      parameters: parameters,
      timeout: 90
    )

    defer { Self.deleteStatsNoncancellable(group: group) }

    do {
      var lastStats = RcloneTransferStats()
      while true {
        try Task.checkCancellation()
        if let stats = try? await readStats(group: group) { lastStats = stats }
        let stats = lastStats
        progress(TransferEngineProgress(
          bytesTransferred: stats.bytes,
          totalBytes: stats.totalBytes,
          bytesPerSecond: stats.speed,
          estimatedSecondsRemaining: stats.eta,
          currentItem: stats.transferring.first?.name,
          completedItems: stats.transfers,
          totalItems: max(stats.transfers, stats.transfers + Int64(stats.transferring.count))
        ))

        let status: RcloneJobStatus = try await runtime.callDecodable(
          "job/status",
          parameters: ["jobid": .integer(job.jobID)]
        )
        guard status.executeID == job.executeID else {
          throw RemoteServerError.invalidResponse(
            "rcloneが再起動され、転送ジョブの世代が変わりました。安全のため結果を採用しません。"
          )
        }
        if status.finished {
          guard status.success == true, status.error.isEmpty else {
            throw RemoteServerError.invalidResponse(status.error.isEmpty ? "rclone転送に失敗しました。" : status.error)
          }
          if let stats = try? await readStats(group: group) { lastStats = stats }
          let final = lastStats
          progress(TransferEngineProgress(
            bytesTransferred: final.bytes,
            totalBytes: max(final.totalBytes, final.bytes),
            bytesPerSecond: final.speed,
            estimatedSecondsRemaining: 0,
            currentItem: nil,
            completedItems: final.transfers,
            totalItems: final.transfers
          ))
          if let profileID = destinationEndpoint.profileID {
            await FileProviderChangeNotifier.signal(profileID: profileID)
          }
          if method == "sync/move", let profileID = sourceEndpoint.profileID,
            profileID != destinationEndpoint.profileID
          {
            await FileProviderChangeNotifier.signal(profileID: profileID)
          }
          return TransferEngineResult(
            bytesTransferred: final.bytes,
            checks: final.checks,
            transferredItems: final.transfers,
            errorCount: final.errors
          )
        }
        try await Task.sleep(nanoseconds: 350_000_000)
      }
    } catch {
      await Self.stopJobNoncancellable(job)
      throw error
    }
  }

  private static func stopJobNoncancellable(_ job: RcloneJobReference) async {
    await Task.detached(priority: .utility) {
      let runtime = RcloneRuntime.shared
      guard let status: RcloneJobStatus = try? await runtime.callDecodable(
        "job/status",
        parameters: ["jobid": .integer(job.jobID)]
      ), status.executeID == job.executeID else { return }
      _ = try? await runtime.call("job/stop", parameters: ["jobid": .integer(job.jobID)])
    }.value
  }

  private static func deleteStatsNoncancellable(group: String) {
    Task.detached(priority: .utility) {
      _ = try? await RcloneRuntime.shared.call(
        "core/stats-delete",
        parameters: ["group": .string(group)]
      )
    }
  }


  private func effectivePolicy(source: URL, destination: URL) async -> ConnectionTransferPolicy {
    let destinationProfile = await RemoteFileSystemRegistry.shared.profile(for: destination)
    let sourceProfile = await RemoteFileSystemRegistry.shared.profile(for: source)
    var policy = destinationProfile?.transferPolicy ?? sourceProfile?.transferPolicy ?? .default
    policy.clamp()
    return policy
  }

  private func configOptions(for policy: ConnectionTransferPolicy) -> [String: JSONValue] {
    var result: [String: JSONValue] = [
      "Checkers": .integer(Int64(policy.parallelChecks)),
      "Transfers": .integer(Int64(policy.parallelTransfers)),
      "Retries": .integer(Int64(policy.retryCount)),
      "LowLevelRetries": .integer(Int64(policy.lowLevelRetryCount)),
      "PartialSuffix": .string(".nafi-partial"),
      "CreateEmptySrcDirs": .bool(policy.preserveEmptyDirectories),
      "ServerSideAcrossConfigs": .bool(policy.useServerSideCopy),
    ]
    let bandwidth = policy.bandwidthLimit.trimmingCharacters(in: .whitespacesAndNewlines)
    if !bandwidth.isEmpty, bandwidth.lowercased() != "off" {
      result["BwLimit"] = .string(bandwidth)
    }
    return result
  }

  private func readStats(group: String) async throws -> RcloneTransferStats {
    let object = try await runtime.call(
      "core/stats",
      parameters: ["group": .string(group), "short": .bool(false)]
    )
    let transfers: [RcloneTransferStats.ActiveTransfer] =
      object["transferring"]?.arrayValue?.compactMap { value in
        guard let item = value.objectValue else { return nil }
        return RcloneTransferStats.ActiveTransfer(
          name: item["name"]?.stringValue ?? "",
          size: item["size"]?.intValue,
          bytes: item["bytes"]?.intValue ?? 0,
          percentage: item["percentage"]?.doubleValue,
          speed: item["speed"]?.doubleValue,
          speedAvg: item["speedAvg"]?.doubleValue,
          eta: item["eta"]?.doubleValue
        )
      } ?? []
    return RcloneTransferStats(
      bytes: object["bytes"]?.intValue ?? 0,
      totalBytes: object["totalBytes"]?.intValue ?? 0,
      speed: object["speed"]?.doubleValue ?? 0,
      eta: object["eta"]?.doubleValue,
      checks: object["checks"]?.intValue ?? 0,
      transfers: object["transfers"]?.intValue ?? 0,
      errors: object["errors"]?.intValue ?? 0,
      lastError: object["lastError"]?.stringValue,
      transferring: transfers
    )
  }
}
