import Foundation

#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(Darwin)
import Darwin
#endif

struct LocalFileChange: Sendable {
  enum Kind: Sendable { case changed, removed, directory, rescan }
  let url: URL
  let kind: Kind
}

#if canImport(CoreServices)
final class FSEventsChangeMonitor: @unchecked Sendable {
  private let root: URL
  private let handler: @Sendable ([LocalFileChange]) -> Void
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "app.nafi.fsevents", qos: .utility)

  init(root: URL, handler: @escaping @Sendable ([LocalFileChange]) -> Void) {
    self.root = root.standardizedFileURL
    self.handler = handler
  }

  func start() throws {
    guard stream == nil else { return }
    let retained = Unmanaged.passRetained(CallbackBox(root: root, handler: handler))
    var context = FSEventStreamContext(
      version: 0,
      info: retained.toOpaque(),
      retain: nil,
      release: { pointer in
        guard let pointer else { return }
        Unmanaged<CallbackBox>.fromOpaque(pointer).release()
      },
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
      guard let values = unsafeBitCast(paths, to: NSArray.self) as? [String], values.count >= count else {
        return
      }
      var changes: [LocalFileChange] = []
      changes.reserveCapacity(count)
      for index in 0..<count {
        let flag = flags[index]
        let url = URL(fileURLWithPath: values[index]).standardizedFileURL
        let needsRescan =
          flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
          || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
          || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
          || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        let kind: LocalFileChange.Kind
        if needsRescan {
          kind = .rescan
        } else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
          kind = .rescan
        } else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
          kind = .removed
        } else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
          kind = .directory
        } else {
          kind = .changed
        }
        changes.append(LocalFileChange(url: url, kind: kind))
      }
      box.handler(changes)
    }
    guard let created = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      [root.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.35,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagWatchRoot
      )
    ) else {
      retained.release()
      throw CocoaError(.fileReadUnknown)
    }
    stream = created
    FSEventStreamSetDispatchQueue(created, queue)
    guard FSEventStreamStart(created) else {
      FSEventStreamInvalidate(created)
      FSEventStreamRelease(created)
      stream = nil
      throw CocoaError(.fileReadUnknown)
    }
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit { stop() }

  private final class CallbackBox: @unchecked Sendable {
    let root: URL
    let handler: @Sendable ([LocalFileChange]) -> Void
    init(root: URL, handler: @escaping @Sendable ([LocalFileChange]) -> Void) {
      self.root = root
      self.handler = handler
    }
  }
}
#else
final class FSEventsChangeMonitor: @unchecked Sendable {
  init(root: URL, handler: @escaping @Sendable ([LocalFileChange]) -> Void) {}
  func start() throws { throw CocoaError(.featureUnsupported) }
  func stop() {}
}
#endif

actor IncrementalSyncCoordinator {
  typealias FullReconciliation = @Sendable (UUID) async -> Void
  typealias StatusUpdate = @Sendable (UUID, SyncRunPhase, String?) async -> Void

  private struct ProfileRuntime {
    var profile: SavedSyncProfile
    var monitor: FSEventsChangeMonitor?
    var pending: [String: Task<Void, Never>] = [:]
    var changeCounts: [String: Int] = [:]
    var lastFullReconciliation = Date.distantPast
    var activeTransfers = 0
    var isReconciling = false
    var needsAnotherReconciliation = false
    var fullTask: Task<Void, Never>?
  }

  private var runtimes: [UUID: ProfileRuntime] = [:]
  private let reconcile: FullReconciliation
  private let status: StatusUpdate

  init(reconcile: @escaping FullReconciliation, status: @escaping StatusUpdate) {
    self.reconcile = reconcile
    self.status = status
    Self.cleanupStaleSnapshots()
  }

  func updateProfiles(_ profiles: [SavedSyncProfile]) async {
    let wanted = Set(
      profiles.lazy.filter { profile in
        guard profile.enabled && profile.trigger == .continuous else { return false }
        return profile.mode != .bidirectional
          || (profile.bisyncInitialized && profile.bisyncStateSignature == profile.bisyncIdentity)
      }.map(\.id)
    )
    for id in runtimes.keys where !wanted.contains(id) { stop(profileID: id) }
    for profile in profiles where wanted.contains(profile.id) {
      if runtimes[profile.id]?.profile != profile {
        stop(profileID: profile.id)
        await start(profile)
      }
    }
  }

  func stopAll() {
    for id in Array(runtimes.keys) { stop(profileID: id) }
  }

  private func start(_ profile: SavedSyncProfile) async {
    var profile = profile
    profile.clamp()
    let profileID = profile.id
    var state = ProfileRuntime(profile: profile)
    state.fullTask = makeReconciliationTask(profile)

    if profile.source.isFileURL, profile.mode != .bidirectional {
      let root = profile.source.standardizedFileURL
      let monitor = FSEventsChangeMonitor(root: root) { [weak self] changes in
        Task { await self?.consume(changes, profileID: profileID) }
      }
      do {
        try monitor.start()
        state.monitor = monitor
      } catch {
        await status(profile.id, .failed, "変更監視を開始できないため定期照合へ切り替えました。\n\(error.localizedDescription)")
      }
    }
    runtimes[profile.id] = state
    scheduleReconciliation(profileID: profile.id, delay: 2)
    await status(profile.id, .waitingForStability, "停止中の変更を確認しています。")
  }

  private func stop(profileID: UUID) {
    guard var state = runtimes.removeValue(forKey: profileID) else { return }
    state.monitor?.stop()
    state.fullTask?.cancel()
    for task in state.pending.values { task.cancel() }
    state.pending.removeAll()
  }

  private func makeReconciliationTask(_ profile: SavedSyncProfile) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        let interval = max(15 * 60, profile.fullReconciliationInterval)
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await self?.scheduleReconciliation(profileID: profile.id, delay: 1)
      }
    }
  }

  private func consume(_ changes: [LocalFileChange], profileID: UUID) async {
    guard var state = runtimes[profileID] else { return }

    // rclone filter syntax is richer than glob matching. Do not maintain a second,
    // subtly different filter implementation for incremental events. The built-in
    // housekeeping exclusions are handled locally; any user-defined rules fall
    // back to one authoritative rclone reconciliation.
    if hasCustomFilterRules(state.profile) {
      runtimes[profileID] = state
      scheduleReconciliation(profileID: profileID, delay: state.profile.stableForSeconds)
      await status(profileID, .waitingForStability, "フィルター付き変更を1回の差分照合へ集約しています。")
      return
    }

    if changes.count + state.pending.count >= state.profile.incrementalBatchThreshold {
      for (key, task) in state.pending where key != "__full__" { task.cancel() }
      state.pending = state.pending.filter { $0.key == "__full__" }
      state.changeCounts.removeAll()
      runtimes[profileID] = state
      scheduleReconciliation(profileID: profileID, delay: state.profile.stableForSeconds)
      await status(profileID, .waitingForStability, "多数の変更を1回の差分照合へ集約しています。")
      return
    }

    let root = state.profile.source.standardizedFileURL
    var needsReconciliation = false
    for change in changes {
      guard let relative = NafiURL.localRelativePath(of: change.url, under: root) else { continue }
      if relative.isEmpty || change.kind == .rescan || change.kind == .directory {
        needsReconciliation = true
        continue
      }
      if isBuiltInExcluded(relative) { continue }

      state.pending[relative]?.cancel()
      state.changeCounts[relative, default: 0] += 1
      let profile = state.profile
      let count = state.changeCounts[relative, default: 1]
      state.pending[relative] = Task { [weak self] in
        let delay = max(1, profile.stableForSeconds)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await self?.process(relativePath: relative, kind: change.kind, changeCount: count, profile: profile)
      }
    }
    runtimes[profileID] = state
    if needsReconciliation {
      scheduleReconciliation(profileID: profileID, delay: state.profile.stableForSeconds)
    }
  }

  private func scheduleReconciliation(profileID: UUID, delay: TimeInterval) {
    guard var state = runtimes[profileID] else { return }
    state.pending["__full__"]?.cancel()
    state.pending["__full__"] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.performFullReconciliation(profileID: profileID)
    }
    runtimes[profileID] = state
  }

  private func process(
    relativePath: String,
    kind: LocalFileChange.Kind,
    changeCount: Int,
    profile: SavedSyncProfile
  ) async {
    defer {
      if var state = runtimes[profile.id] {
        state.pending[relativePath] = nil
        state.changeCounts[relativePath] = nil
        runtimes[profile.id] = state
      }
    }

    var slotAcquired = false
    defer {
      if slotAcquired { releaseTransferSlot(profileID: profile.id) }
    }
    do {
      try Task.checkCancellation()
      if kind == .removed {
        // Mass deletion and rename sequences arrive as many independent FSEvents.
        // Never propagate them one-by-one; the full preview enforces count/ratio limits.
        scheduleReconciliation(profileID: profile.id, delay: profile.stableForSeconds)
        return
      }

      let source = profile.source.appendingPathComponent(relativePath)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
        scheduleReconciliation(profileID: profile.id, delay: profile.stableForSeconds)
        return
      }
      if isDirectory.boolValue {
        scheduleReconciliation(profileID: profile.id, delay: profile.stableForSeconds)
        return
      }

      await status(profile.id, .waitingForStability, relativePath)
      guard try await waitUntilStable(source, seconds: profile.stableForSeconds) else {
        scheduleReconciliation(profileID: profile.id, delay: profile.stableForSeconds)
        return
      }

      let values = try source.resourceValues(forKeys: [.fileSizeKey])
      let size = Int64(values.fileSize ?? 0)

      try await acquireTransferSlot(profileID: profile.id, maximum: profile.maxConcurrentIncrementalTransfers)
      slotAcquired = true
      let shouldCopySnapshot = size >= profile.largeFileThresholdBytes || changeCount >= 3
      // APFS clones are cheap and freeze a consistent point-in-time view even
      // when an application resumes writing immediately after the stability wait.
      // On non-cloneable volumes, avoid a full extra copy for ordinary small files.
      let transferSource = try makeSnapshot(
        of: source,
        allowingFullCopyFallback: shouldCopySnapshot
      ) ?? source
      defer {
        if transferSource != source {
          let snapshotDirectory = transferSource.deletingLastPathComponent()
          try? FileManager.default.removeItem(at: snapshotDirectory)
        }
      }

      let destination = append(relativePath, to: profile.destination)
      let engine = RcloneTransferEngine()
      _ = try await engine.copy(
        source: transferSource,
        destination: destination,
        isDirectory: false,
        progress: { [status] progress in
          Task { await status(profile.id, .running, progress.currentItem ?? relativePath) }
        }
      )
      let verification = await engine.effectiveVerificationMode(
        source: transferSource,
        destination: destination
      )
      try await engine.verify(
        source: transferSource,
        destination: destination,
        isDirectory: false,
        mode: verification
      )
      await status(profile.id, .completed, relativePath)
    } catch is CancellationError {
      return
    } catch {
      await status(profile.id, .failed, "\(relativePath): \(error.localizedDescription)")
      scheduleReconciliation(profileID: profile.id, delay: max(60, profile.stableForSeconds))
    }
  }

  private func acquireTransferSlot(profileID: UUID, maximum: Int) async throws {
    while true {
      try Task.checkCancellation()
      guard var state = runtimes[profileID] else { throw CancellationError() }
      if !state.isReconciling, state.activeTransfers < maximum {
        state.activeTransfers += 1
        runtimes[profileID] = state
        return
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
  }

  private func releaseTransferSlot(profileID: UUID) {
    guard var state = runtimes[profileID] else { return }
    state.activeTransfers = max(0, state.activeTransfers - 1)
    runtimes[profileID] = state
  }

  private func waitUntilStable(_ url: URL, seconds: TimeInterval) async throws -> Bool {
    let stableSeconds = seconds.isFinite ? min(max(seconds, 1), 3_600) : 8
    let interval = min(max(stableSeconds / 2, 0.75), 5)
    let stableNanoseconds = UInt64(stableSeconds * 1_000_000_000)
    let timeoutNanoseconds = UInt64(max(30, stableSeconds * 12) * 1_000_000_000)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let deadline = startedAt + timeoutNanoseconds
    var previous: (Int64, Date)?
    var unchangedSince = startedAt

    while DispatchTime.now().uptimeNanoseconds < deadline {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let current = (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
      let observedAt = DispatchTime.now().uptimeNanoseconds
      if let previous, previous.0 == current.0, previous.1 == current.1 {
        if observedAt - unchangedSince >= stableNanoseconds { return true }
      } else {
        previous = current
        unchangedSince = observedAt
      }
      try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return false
  }

  private func makeSnapshot(
    of source: URL,
    allowingFullCopyFallback: Bool
  ) throws -> URL? {
    let root = try AppStoragePaths.directory(named: "SyncSnapshots")
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(source.lastPathComponent)
    #if canImport(Darwin)
    let cloneResult = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in clonefile(sourcePath, destinationPath, 0) }
    }
    if cloneResult == 0 { return destination }
    #endif
    guard allowingFullCopyFallback else {
      try? FileManager.default.removeItem(at: folder)
      return nil
    }
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  private nonisolated static func cleanupStaleSnapshots() {
    let root = AppStoragePaths.directory(named: "SyncSnapshots")
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
    guard let values = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for value in values {
      guard let resources = try? value.resourceValues(forKeys: keys),
        resources.isDirectory == true,
        (resources.contentModificationDate ?? .distantPast) < cutoff
      else { continue }
      try? FileManager.default.removeItem(at: value)
    }
  }

  private func performFullReconciliation(profileID: UUID) async {
    guard var state = runtimes[profileID] else { return }
    if state.isReconciling {
      state.needsAnotherReconciliation = true
      runtimes[profileID] = state
      return
    }
    state.isReconciling = true
    for (key, task) in state.pending where key != "__full__" { task.cancel() }
    state.pending = state.pending.filter { $0.key == "__full__" }
    state.changeCounts.removeAll()
    runtimes[profileID] = state

    defer {
      if var updated = runtimes[profileID] {
        let rerun = updated.needsAnotherReconciliation
        updated.isReconciling = false
        updated.needsAnotherReconciliation = false
        updated.pending["__full__"] = nil
        runtimes[profileID] = updated
        if rerun { scheduleReconciliation(profileID: profileID, delay: updated.profile.stableForSeconds) }
      }
    }

    while let current = runtimes[profileID], current.activeTransfers > 0 {
      guard !Task.isCancelled else { return }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    guard !Task.isCancelled, runtimes[profileID] != nil else { return }
    await reconcile(profileID)
    if var updated = runtimes[profileID] {
      updated.lastFullReconciliation = Date()
      runtimes[profileID] = updated
    }
  }

  private func hasCustomFilterRules(_ profile: SavedSyncProfile) -> Bool {
    let defaults = [".DS_Store", ".Trash/**"]
    return !profile.includeRules.isEmpty || profile.excludeRules != defaults
  }

  private func isBuiltInExcluded(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/").map(String.init)
    guard !components.isEmpty else { return false }
    return components.contains(".DS_Store")
      || components.contains(".Trash")
  }

  private func append(_ relativePath: String, to root: URL) -> URL {
    if NafiURL.isRemote(root) { return NafiURL.appending(relativePath, to: root) }
    return root.appendingPathComponent(relativePath)
  }
}
