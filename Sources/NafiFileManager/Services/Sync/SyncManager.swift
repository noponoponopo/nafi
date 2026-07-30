import Foundation

@MainActor
final class SyncManager: ObservableObject {
  @Published private(set) var profiles: [SavedSyncProfile] = []
  @Published private(set) var statuses: [UUID: SyncRunStatus] = [:]
  @Published var selectedPreview: SyncPreview?
  @Published var errorMessage: String?

  private let persistenceURL = AppStoragePaths.file(named: "sync-profiles.json")
  private let runtime: RcloneRuntime
  private var runningTasks: [UUID: Task<Void, Never>] = [:]
  private var scheduledTask: Task<Void, Never>?
  private var incremental: IncrementalSyncCoordinator!

  init(runtime: RcloneRuntime = .shared) {
    self.runtime = runtime
    load()
    incremental = IncrementalSyncCoordinator(
      reconcile: { [weak self] profileID in
        await self?.runProfileAndWait(id: profileID, requiringPreview: true)
      },
      status: { [weak self] profileID, phase, message in
        await self?.updateIncrementalStatus(profileID: profileID, phase: phase, message: message)
      }
    )
  }

  deinit {
    scheduledTask?.cancel()
    for task in runningTasks.values { task.cancel() }
    let incremental = incremental
    Task { await incremental?.stopAll() }
  }

  func startScheduling() {
    guard scheduledTask == nil else { return }
    Task { await incremental.updateProfiles(profiles) }
    scheduledTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.runDueProfiles()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
      }
    }
  }

  @discardableResult
  func save(_ profile: SavedSyncProfile) -> Bool {
    var profile = profile
    profile.clamp()
    guard !profile.name.isEmpty else {
      errorMessage = "同期名を入力してください。"
      return false
    }
    guard !NafiURL.sameLocation(profile.source, profile.destination),
      !NafiURL.isDescendant(profile.destination, of: profile.source),
      !NafiURL.isDescendant(profile.source, of: profile.destination)
    else {
      errorMessage = "同期元と同期先は同じ場所または親子関係にできません。"
      return false
    }
    if profile.enabled, let conflicting = profiles.first(where: {
      $0.id != profile.id && $0.enabled && profilesCanMutateSameLocation(profile, $0)
    }) {
      errorMessage = "同期設定「\(conflicting.name)」と書き込み先が重なっています。同時実行による上書きを避けるため、どちらかを無効にするか場所を分けてください。"
      return false
    }
    var updatedProfiles = profiles
    if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
      let old = updatedProfiles[index]
      if old.bisyncIdentity != profile.bisyncIdentity || old.mode != profile.mode {
        profile.bisyncInitialized = false
        profile.bisyncStateSignature = nil
      }
      updatedProfiles[index] = profile
    } else {
      updatedProfiles.append(profile)
    }
    updatedProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard persist(updatedProfiles) else { return false }
    profiles = updatedProfiles
    Task { await incremental.updateProfiles(profiles) }
    return true
  }

  func remove(_ profile: SavedSyncProfile) {
    let updatedProfiles = profiles.filter { $0.id != profile.id }
    guard persist(updatedProfiles) else { return }
    stop(profileID: profile.id)
    profiles = updatedProfiles
    statuses[profile.id] = nil
    if selectedPreview?.profileID == profile.id { selectedPreview = nil }
    Task { await incremental.updateProfiles(profiles) }
  }

  func preview(_ profile: SavedSyncProfile) async -> SyncPreview? {
    var status = statuses[profile.id] ?? SyncRunStatus(profileID: profile.id)
    status.phase = .previewing
    status.updatedAt = Date()
    status.message = nil
    statuses[profile.id] = status
    do {
      let preview = try await buildPreview(profile)
      selectedPreview = preview
      status.phase = .idle
      status.updatedAt = Date()
      status.message = preview.canRun ? nil : preview.blockingReasons.joined(separator: "\n")
      statuses[profile.id] = status
      return preview
    } catch {
      status.phase = .failed
      status.updatedAt = Date()
      status.message = error.localizedDescription
      statuses[profile.id] = status
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func run(
    _ profile: SavedSyncProfile,
    requiringPreview: Bool = true,
    allowingInitialBisync: Bool = false
  ) {
    guard runningTasks[profile.id] == nil else { return }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.execute(
        profile,
        requiringPreview: requiringPreview,
        allowingInitialBisync: allowingInitialBisync
      )
    }
    runningTasks[profile.id] = task
  }


  func requiresInitialBisyncConfirmation(_ profile: SavedSyncProfile) -> Bool {
    profile.mode == .bidirectional && !isBisyncInitialized(profile)
  }

  func runProfileAndWait(id: UUID, requiringPreview: Bool = true) async {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    if let task = runningTasks[id] {
      await task.value
      return
    }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.execute(
        profile,
        requiringPreview: requiringPreview,
        allowingInitialBisync: false
      )
    }
    runningTasks[id] = task
    await task.value
  }

  func runProfile(id: UUID, requiringPreview: Bool = true) {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    run(profile, requiringPreview: requiringPreview)
  }

  @discardableResult
  func runProfile(matching identifierOrName: String, requiringPreview: Bool = true) -> Bool {
    let key = identifierOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return false }
    let profile: SavedSyncProfile?
    if let id = UUID(uuidString: key) {
      profile = profiles.first(where: { $0.id == id })
    } else {
      profile = profiles.first(where: {
        $0.name.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      })
    }
    guard let profile else { return false }
    run(profile, requiringPreview: requiringPreview)
    return true
  }

  func makeProfile(source: URL, destination: URL) -> SavedSyncProfile {
    SavedSyncProfile(
      name: "\(source.lastPathComponent.isEmpty ? "同期" : source.lastPathComponent) → \(destination.lastPathComponent.isEmpty ? "同期先" : destination.lastPathComponent)",
      source: source,
      destination: destination
    )
  }

  private func updateIncrementalStatus(profileID: UUID, phase: SyncRunPhase, message: String?) {
    var value = statuses[profileID] ?? SyncRunStatus(profileID: profileID)
    value.phase = phase
    value.updatedAt = Date()
    value.currentItem = message
    if phase == .failed { value.message = message }
    statuses[profileID] = value
  }

  func stop(profileID: UUID) {
    runningTasks.removeValue(forKey: profileID)?.cancel()
    if let jobID = statuses[profileID]?.rcloneJobID,
      let executeID = statuses[profileID]?.rcloneExecuteID
    {
      Self.stopJobNoncancellable(RcloneJobReference(jobID: jobID, executeID: executeID))
    }
    guard var status = statuses[profileID] else { return }
    status.phase = .cancelled
    status.updatedAt = Date()
    status.message = "キャンセルしました。"
    statuses[profileID] = status
  }

  private func execute(
    _ original: SavedSyncProfile,
    requiringPreview: Bool,
    allowingInitialBisync: Bool
  ) async {
    defer { runningTasks[original.id] = nil }
    var profile = original
    profile.clamp()
    var status = statuses[profile.id] ?? SyncRunStatus(profileID: profile.id)
    status.startedAt = Date()
    status.updatedAt = Date()
    status.phase = .previewing
    status.message = nil
    statuses[profile.id] = status
    var activeJobID: Int64?
    var activeExecuteID: String?
    var activeStatsGroup: String?

    do {
      guard Self.validEndpoint(profile.source), Self.validEndpoint(profile.destination),
        !NafiURL.sameLocation(profile.source, profile.destination),
        !NafiURL.isDescendant(profile.destination, of: profile.source),
        !NafiURL.isDescendant(profile.source, of: profile.destination)
      else {
        throw RemoteServerError.invalidResponse(
          "同期元と同期先は同じ場所または親子関係にできません。"
        )
      }
      if profile.enabled, let conflicting = profiles.first(where: {
        $0.id != profile.id && $0.enabled && profilesCanMutateSameLocation(profile, $0)
      }) {
        throw RemoteServerError.invalidResponse(
          "同期設定「\(conflicting.name)」と場所が重なっているため実行できません。"
        )
      }
      let preview = requiringPreview ? try await buildPreview(profile) : nil
      if let preview {
        selectedPreview = preview
        guard preview.canRun else {
          throw RemoteServerError.invalidResponse(preview.blockingReasons.joined(separator: "\n"))
        }
      }
      if requiresInitialBisyncConfirmation(profile), !allowingInitialBisync {
        throw RemoteServerError.invalidResponse(
          "初回の双方向同期は、同期元を基準に状態を作成します。同期画面で差分を確認し、初期化を明示的に許可してください。"
        )
      }

      try Task.checkCancellation()
      status.phase = .running
      status.updatedAt = Date()
      statuses[profile.id] = status
      let endpoints = try await endpoints(for: profile)
      let group = "nafi-sync-\(profile.id.uuidString.lowercased())-\(UUID().uuidString)"
      activeStatsGroup = group
      var parameters = syncParameters(profile: profile, endpoints: endpoints)
      parameters["_async"] = .bool(true)
      parameters["_group"] = .string(group)
      let transferPolicy = await effectivePolicy(for: endpoints)
      let effectiveDeleteLimit = effectiveMaximumDeleteCount(profile: profile, preview: preview)
      parameters["_config"] = .object(
        configOptions(for: profile, policy: transferPolicy, maximumDeleteCount: effectiveDeleteLimit)
      )
      if let filter = filterOptions(for: profile) { parameters["_filter"] = .object(filter) }

      let method: String
      switch profile.mode {
      case .update: method = "sync/copy"
      case .mirror: method = "sync/sync"
      case .bidirectional: method = "sync/bisync"
      }
      let job: RcloneJobReference = try await runtime.callDecodable(
        method,
        parameters: parameters,
        timeout: 90
      )
      activeJobID = job.jobID
      activeExecuteID = job.executeID
      status.rcloneJobID = job.jobID
      status.rcloneExecuteID = job.executeID
      statuses[profile.id] = status

      while true {
        try Task.checkCancellation()
        let stats = (try? await stats(group: group)) ?? RcloneTransferStats()
        status.progress = TransferEngineProgress(
          bytesTransferred: stats.bytes,
          totalBytes: stats.totalBytes,
          bytesPerSecond: stats.speed,
          estimatedSecondsRemaining: stats.eta,
          currentItem: stats.transferring.first?.name,
          completedItems: stats.transfers,
          totalItems: max(stats.transfers, stats.transfers + Int64(stats.transferring.count))
        )
        status.currentItem = stats.transferring.first?.name
        status.updatedAt = Date()
        if let lastError = stats.lastError, !lastError.isEmpty { status.message = lastError }
        statuses[profile.id] = status

        let jobStatus: RcloneJobStatus = try await runtime.callDecodable(
          "job/status",
          parameters: ["jobid": .integer(job.jobID)]
        )
        guard jobStatus.executeID == job.executeID else {
          throw RemoteServerError.invalidResponse(
            "rcloneが再起動され、同期ジョブの世代が変わりました。安全のため結果を採用しません。"
          )
        }
        if jobStatus.finished {
          guard jobStatus.success == true, jobStatus.error.isEmpty else {
            throw RemoteServerError.invalidResponse(
              jobStatus.error.isEmpty ? "同期に失敗しました。" : jobStatus.error
            )
          }
          break
        }
        try await Task.sleep(nanoseconds: 450_000_000)
      }

      status.phase = .verifying
      status.updatedAt = Date()
      statuses[profile.id] = status
      if profile.mode != .bidirectional {
        var checkParameters: [String: JSONValue] = [
          "srcFs": .string(endpoints.source.combinedFS),
          "dstFs": .string(endpoints.destination.combinedFS),
          "oneWay": .bool(profile.mode == .update),
          "download": .bool(transferPolicy.verification == .downloadAndHash),
        ]
        if transferPolicy.verification == .sizeOnly {
          checkParameters["_config"] = .object(["SizeOnly": .bool(true)])
        }
        if let filter = filterOptions(for: profile) {
          checkParameters["_filter"] = .object(filter)
        }
        let check = try await runtime.call(
          "operations/check",
          parameters: checkParameters,
          timeout: 86_400
        )
        guard check["success"]?.boolValue == true else {
          throw RemoteServerError.invalidResponse(
            check["status"]?.stringValue ?? "同期後の一致検証に失敗しました。"
          )
        }
      }

      status.phase = .completed
      status.updatedAt = Date()
      status.currentItem = nil
      status.message = "同期が完了しました。"
      var persistenceWarning: String?
      if var saved = profiles.first(where: { $0.id == profile.id }) {
        saved.lastRunAt = Date()
        saved.lastSuccessfulRunAt = Date()
        if saved.mode == .bidirectional {
          saved.bisyncInitialized = true
          saved.bisyncStateSignature = saved.bisyncIdentity
        }
        if !save(saved) {
          persistenceWarning = "同期は完了しましたが、実行履歴を保存できませんでした。次回実行前に設定を確認してください。"
        }
      }
      if let persistenceWarning { status.message = persistenceWarning }
      statuses[profile.id] = status
      if let sourceProfileID = endpoints.source.profileID {
        await FileProviderChangeNotifier.signal(profileID: sourceProfileID)
      }
      if let destinationProfileID = endpoints.destination.profileID,
        destinationProfileID != endpoints.source.profileID
      {
        await FileProviderChangeNotifier.signal(profileID: destinationProfileID)
      }
      _ = try? await runtime.call("core/stats-delete", parameters: ["group": .string(group)])
      activeStatsGroup = nil
      activeJobID = nil
    } catch is CancellationError {
      if let activeJobID, let activeExecuteID {
        await Self.stopJobNoncancellable(
          RcloneJobReference(jobID: activeJobID, executeID: activeExecuteID)
        )
      }
      if let activeStatsGroup {
        Self.deleteStatsNoncancellable(group: activeStatsGroup)
      }
      status.phase = .cancelled
      status.updatedAt = Date()
      status.message = "キャンセルしました。"
      statuses[profile.id] = status
    } catch {
      if let activeJobID, let activeExecuteID {
        await Self.stopJobNoncancellable(
          RcloneJobReference(jobID: activeJobID, executeID: activeExecuteID)
        )
      }
      if let activeStatsGroup {
        Self.deleteStatsNoncancellable(group: activeStatsGroup)
      }
      status.phase = .failed
      status.updatedAt = Date()
      status.message = error.localizedDescription
      statuses[profile.id] = status
      errorMessage = error.localizedDescription
      if var saved = profiles.first(where: { $0.id == profile.id }) {
        saved.lastRunAt = Date()
        _ = save(saved)
      }
    }
  }

  private func buildPreview(_ profile: SavedSyncProfile) async throws -> SyncPreview {
    let maximumPreviewEntries = 250_000
    let endpoints = try await endpoints(for: profile)
    let result = try await runtime.call(
      "operations/check",
      parameters: [
        "srcFs": .string(endpoints.source.combinedFS),
        "dstFs": .string(endpoints.destination.combinedFS),
        "download": .bool(false),
        "oneWay": .bool(profile.mode == .update),
        "combined": .bool(true),
        "missingOnSrc": .bool(true),
        "missingOnDst": .bool(true),
        "match": .bool(false),
        "differ": .bool(true),
        "error": .bool(true),
        "_filter": filterOptions(for: profile).map(JSONValue.object) ?? .object([:]),
      ],
      timeout: 86_400
    )

    var items: [SyncPreviewItem] = []
    let missingOnDestination = stringArray(result["missingOnDst"])
    let missingOnSource = stringArray(result["missingOnSrc"])
    let different = stringArray(result["differ"])
    let errors = stringArray(result["error"])
    let totalReportedEntries = missingOnDestination.count + missingOnSource.count
      + different.count + errors.count
    guard totalReportedEntries <= maximumPreviewEntries else {
      throw RemoteServerError.invalidResponse(
        "差分が\(maximumPreviewEntries)項目を超えました。安全にプレビューできる範囲へ同期対象を分割するか、除外ルールを追加してください。"
      )
    }
    if profile.mode == .bidirectional {
      items.append(contentsOf: missingOnDestination.map {
        SyncPreviewItem(path: cleanReportPath($0), action: .conflict, detail: "片側のみ。反映方向はbisync履歴で判定")
      })
      items.append(contentsOf: missingOnSource.map {
        SyncPreviewItem(path: cleanReportPath($0), action: .conflict, detail: "片側のみ。反映方向はbisync履歴で判定")
      })
      items.append(contentsOf: different.map {
        SyncPreviewItem(path: cleanReportPath($0), action: .conflict, detail: "双方の現在状態が不一致")
      })
    } else {
      items.append(contentsOf: missingOnDestination.map { SyncPreviewItem(path: cleanReportPath($0), action: .copy) })
      items.append(contentsOf: different.map { SyncPreviewItem(path: cleanReportPath($0), action: .update) })
      if profile.mode == .mirror {
        items.append(contentsOf: missingOnSource.map { SyncPreviewItem(path: cleanReportPath($0), action: .delete) })
      }
    }
    items.append(contentsOf: errors.map {
      SyncPreviewItem(path: cleanReportPath($0), action: .conflict, detail: "比較エラー")
    })

    var sizeParameters: [String: JSONValue] = [
      "fs": .string(endpoints.destination.combinedFS)
    ]
    if let filter = filterOptions(for: profile) { sizeParameters["_filter"] = .object(filter) }
    let destinationSize = try await runtime.call(
      "operations/size",
      parameters: sizeParameters,
      timeout: 86_400
    )
    let totalItems = destinationSize["count"]?.intValue ?? 0
    let deleteCount = Int64(items.lazy.filter { $0.action == .delete }.count)
    var warnings: [String] = []
    var blocking: [String] = []
    if deleteCount > 0 {
      let ratio = totalItems > 0 ? Double(deleteCount) / Double(totalItems) : 1
      if deleteCount > Int64(profile.maxDeleteCount) {
        blocking.append("削除予定が上限の\(profile.maxDeleteCount)項目を超えています。")
      }
      if ratio > profile.maxDeleteRatio {
        blocking.append("削除予定の割合が上限の\(Int(profile.maxDeleteRatio * 100))%を超えています。")
      }
    }
    if profile.mode == .bidirectional {
      let initialized = isBisyncInitialized(profile)
      warnings.append(initialized
        ? "双方向同期は前回のrclone状態を継続して競合を検出します。"
        : "初回は同期元を基準にrclone bisyncの状態を作成します。現在状態の比較だけでは反映方向を断定できないため、明示確認なしでは実行しません。")
    }
    if !errors.isEmpty { blocking.append("比較できない項目があります。競合を解消してください。") }
    if items.count > 100_000 {
      warnings.append("差分が10万項目を超えています。フィルターまたは分割した同期設定を推奨します。")
    }

    return SyncPreview(
      profileID: profile.id,
      generatedAt: Date(),
      items: items,
      totalDestinationItems: totalItems,
      warnings: warnings,
      blockingReasons: blocking
    )
  }

  private func endpoints(for profile: SavedSyncProfile) async throws -> (
    source: TransferEndpoint, destination: TransferEndpoint
  ) {
    if NafiURL.isRemote(profile.source) {
      _ = try await RemoteFileSystemRegistry.shared.session(for: profile.source)
    }
    if NafiURL.isRemote(profile.destination) {
      _ = try await RemoteFileSystemRegistry.shared.session(for: profile.destination)
    }
    return (
      try await TransferEndpoint.resolve(profile.source),
      try await TransferEndpoint.resolve(profile.destination)
    )
  }

  private func syncParameters(
    profile: SavedSyncProfile,
    endpoints: (source: TransferEndpoint, destination: TransferEndpoint)
  ) -> [String: JSONValue] {
    switch profile.mode {
    case .update, .mirror:
      return [
        "srcFs": .string(endpoints.source.combinedFS),
        "dstFs": .string(endpoints.destination.combinedFS),
        "createEmptySrcDirs": .bool(true),
      ]
    case .bidirectional:
      let initialized = isBisyncInitialized(profile)
      let workdir = AppStoragePaths.directory(named: "Bisync/\(profile.id.uuidString.lowercased())")
      return [
        "path1": .string(endpoints.source.combinedFS),
        "path2": .string(endpoints.destination.combinedFS),
        "checkAccess": .bool(false),
        "checkSync": .string("true"),
        "recover": .bool(true),
        "resilient": .bool(true),
        "resync": .bool(!initialized),
        "resyncMode": .string("path1"),
        "conflictResolve": .string("none"),
        "conflictLoser": .string("num"),
        "conflictSuffix": .string(".nafi-conflict"),
        "workdir": .string(workdir.path),
      ]
    }
  }

  private func effectivePolicy(
    for endpoints: (source: TransferEndpoint, destination: TransferEndpoint)
  ) async -> ConnectionTransferPolicy {
    let destinationProfile: ServerProfile?
    if let id = endpoints.destination.profileID {
      destinationProfile = await RemoteFileSystemRegistry.shared.profile(for: id)
    } else {
      destinationProfile = nil
    }
    let sourceProfile: ServerProfile?
    if let id = endpoints.source.profileID {
      sourceProfile = await RemoteFileSystemRegistry.shared.profile(for: id)
    } else {
      sourceProfile = nil
    }
    var policy = destinationProfile?.transferPolicy ?? sourceProfile?.transferPolicy ?? .default
    policy.clamp()
    return policy
  }

  private func configOptions(
    for profile: SavedSyncProfile,
    policy: ConnectionTransferPolicy,
    maximumDeleteCount: Int
  ) -> [String: JSONValue] {
    var options: [String: JSONValue] = [
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
      options["BwLimit"] = .string(bandwidth)
    }
    if profile.mode == .mirror || profile.mode == .bidirectional {
      options["MaxDelete"] = .integer(Int64(maximumDeleteCount))
    }
    return options
  }

  private func isBisyncInitialized(_ profile: SavedSyncProfile) -> Bool {
    guard profile.bisyncInitialized,
      profile.bisyncStateSignature == profile.bisyncIdentity
    else { return false }
    let workdir = AppStoragePaths.directory(named: "Bisync/\(profile.id.uuidString.lowercased())")
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: workdir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return false }
    return !entries.isEmpty
  }

  private func effectiveMaximumDeleteCount(
    profile: SavedSyncProfile, preview: SyncPreview?
  ) -> Int {
    guard profile.mode == .mirror || profile.mode == .bidirectional else {
      return profile.maxDeleteCount
    }
    guard let preview else { return profile.maxDeleteCount }
    let ratioLimit = Int(
      floor(Double(max(0, preview.totalDestinationItems)) * profile.maxDeleteRatio)
    )
    return max(0, min(profile.maxDeleteCount, ratioLimit))
  }

  private func profilesCanMutateSameLocation(
    _ lhs: SavedSyncProfile, _ rhs: SavedSyncProfile
  ) -> Bool {
    let lhsWrites = lhs.mode == .bidirectional ? [lhs.source, lhs.destination] : [lhs.destination]
    let rhsWrites = rhs.mode == .bidirectional ? [rhs.source, rhs.destination] : [rhs.destination]
    let lhsAll = [lhs.source, lhs.destination]
    let rhsAll = [rhs.source, rhs.destination]
    return lhsWrites.contains { writable in rhsAll.contains { locationsOverlap(writable, $0) } }
      || rhsWrites.contains { writable in lhsAll.contains { locationsOverlap(writable, $0) } }
  }

  private func locationsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    NafiURL.sameLocation(lhs, rhs)
      || NafiURL.isDescendant(lhs, of: rhs)
      || NafiURL.isDescendant(rhs, of: lhs)
  }

  private func filterOptions(for profile: SavedSyncProfile) -> [String: JSONValue]? {
    var result: [String: JSONValue] = [:]
    if !profile.includeRules.isEmpty {
      result["IncludeRule"] = .array(profile.includeRules.map(JSONValue.string))
    }
    if !profile.excludeRules.isEmpty {
      result["ExcludeRule"] = .array(profile.excludeRules.map(JSONValue.string))
    }
    return result.isEmpty ? nil : result
  }

  private func stats(group: String) async throws -> RcloneTransferStats {
    let object = try await runtime.call(
      "core/stats",
      parameters: ["group": .string(group), "short": .bool(false)]
    )
    let active = object["transferring"]?.arrayValue?.compactMap { value -> RcloneTransferStats.ActiveTransfer? in
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
      transferring: active
    )
  }

  private func stringArray(_ value: JSONValue?) -> [String] {
    value?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  private func cleanReportPath(_ value: String) -> String {
    let symbols = CharacterSet(charactersIn: "=+-*! ")
    return value.trimmingCharacters(in: symbols)
  }

  private nonisolated static func stopJobNoncancellable(_ job: RcloneJobReference) async {
    await Task.detached(priority: .utility) {
      let runtime = RcloneRuntime.shared
      guard let status: RcloneJobStatus = try? await runtime.callDecodable(
        "job/status",
        parameters: ["jobid": .integer(job.jobID)]
      ), status.executeID == job.executeID else { return }
      _ = try? await runtime.call("job/stop", parameters: ["jobid": .integer(job.jobID)])
    }.value
  }

  private nonisolated static func stopJobNoncancellable(_ job: RcloneJobReference) {
    Task.detached(priority: .utility) { await stopJobNoncancellable(job) }
  }

  private nonisolated static func deleteStatsNoncancellable(group: String) {
    Task.detached(priority: .utility) {
      _ = try? await RcloneRuntime.shared.call(
        "core/stats-delete",
        parameters: ["group": .string(group)]
      )
    }
  }

  private func runDueProfiles() async {
    let now = Date()
    for profile in profiles where profile.enabled && runningTasks[profile.id] == nil {
      if profile.mode == .bidirectional && !isBisyncInitialized(profile) { continue }
      let due: Bool
      switch profile.trigger {
      case .manual, .continuous:
        due = false
      case .hourly:
        due = now.timeIntervalSince(profile.lastRunAt ?? .distantPast) >= 60 * 60
      case .daily:
        due = now.timeIntervalSince(profile.lastRunAt ?? .distantPast) >= 24 * 60 * 60
      }
      if due { run(profile) }
    }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: persistenceURL,
        maximumBytes: 8 * 1_024 * 1_024
      )
      let decoded = try JSONDecoder().decode([SavedSyncProfile].self, from: data)
      guard decoded.count <= 10_000 else { throw CocoaError(.fileReadCorruptFile) }
      var seen = Set<UUID>()
      var values: [SavedSyncProfile] = []
      var disabledForOverlap = false
      for var profile in decoded where seen.insert(profile.id).inserted {
        profile.clamp()
        guard Self.validEndpoint(profile.source), Self.validEndpoint(profile.destination),
          !profile.name.isEmpty,
          !NafiURL.sameLocation(profile.source, profile.destination),
          !NafiURL.isDescendant(profile.destination, of: profile.source),
          !NafiURL.isDescendant(profile.source, of: profile.destination)
        else { continue }
        if profile.enabled, values.contains(where: {
          $0.enabled && profilesCanMutateSameLocation(profile, $0)
        }) {
          profile.enabled = false
          disabledForOverlap = true
        }
        values.append(profile)
      }
      profiles = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if profiles.count != decoded.count || disabledForOverlap {
        errorMessage = disabledForOverlap
          ? "不正・重複した設定を除外し、場所が重なる同期設定を安全のため無効化しました。"
          : "不正または重複した同期設定を除外しました。"
        _ = persist(profiles)
      }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: persistenceURL)
      errorMessage = "同期設定が破損していたため隔離しました。\n\(error.localizedDescription)"
    }
  }

  private static func validEndpoint(_ url: URL) -> Bool {
    guard url.absoluteString.utf8.count <= 16_384, url.user == nil, url.password == nil else { return false }
    if url.isFileURL { return url.path.utf8.count <= 8_192 }
    return NafiURL.isRemote(url) && NafiURL.profileID(in: url) != nil
      && (NafiURL.remotePath(in: url)?.utf8.count ?? Int.max) <= 8_192
  }

  @discardableResult
  private func persist(_ values: [SavedSyncProfile]? = nil) -> Bool {
    do {
      let data = try JSONEncoder().encode(values ?? profiles)
      guard data.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
      try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
      return true
    } catch {
      errorMessage = "同期設定を保存できません。\n\(error.localizedDescription)"
      return false
    }
  }
}
