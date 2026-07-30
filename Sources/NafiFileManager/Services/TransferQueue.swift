import Foundation

extension Notification.Name {
  static let nafiTransferQueueDidChange = Notification.Name("app.nafi.transfer-queue-did-change")
}

enum TransferQueueError: LocalizedError {
  case partialFailure(completed: Int, total: Int, message: String)
  case persistence(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .partialFailure(let completed, let total, let message):
      if completed == 0 { return message }
      return "\(total) 件中 \(completed) 件の転送後に失敗しました。\n\(message)"
    case .persistence(let message):
      return message
    case .cancelled:
      return "転送をキャンセルしました。"
    }
  }
}

actor TransferQueue {
  static let shared = TransferQueue()

  enum State: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
  }

  struct Job: Codable, Identifiable, Sendable {
    let id: UUID
    let sources: [URL]
    let destination: URL
    let move: Bool
    let policy: UnifiedFileSystemService.ExistingItemPolicy
    let createdAt: Date
    var updatedAt: Date
    var state: State
    var completedSourceCount: Int
    var resultURLs: [URL]
    var attemptCount: Int
    var errorMessage: String?

    var totalSourceCount: Int { sources.count }
    var fractionCompleted: Double {
      guard !sources.isEmpty else { return 1 }
      return min(max(Double(completedSourceCount) / Double(sources.count), 0), 1)
    }
  }

  private struct PersistedQueue: Codable {
    let version: Int
    let jobs: [Job]
  }

  private static let maximumPersistenceBytes = 16 * 1_024 * 1_024
  private static let maximumJobCount = 10_000
  private static let maximumSourcesPerJob = 10_000
  private static let maximumURLBytes = 16_384
  private static let maximumAttempts = 1_000_000
  private static let retainedTerminalJobCount = 300

  private let persistenceURL = AppStoragePaths.file(named: "transfers.json")
  private var jobs: [Job] = []
  private var loaded = false
  private var workerTask: Task<Void, Never>?
  private var activeTask: Task<[URL], Error>?
  private var activeJobID: UUID?
  private var waiters: [UUID: [CheckedContinuation<[URL], Error>]] = [:]
  private var persistenceErrorMessage: String?

  func start() {
    loadIfNeeded()
    UnifiedFileSystemService.cleanupStaleStagingItems()
    kickWorker()
  }

  func snapshots() -> [Job] {
    loadIfNeeded()
    return jobs.sorted { $0.createdAt > $1.createdAt }
  }

  func latestPersistenceError() -> String? {
    loadIfNeeded()
    return persistenceErrorMessage
  }

  @discardableResult
  func enqueue(
    sources: [URL],
    destination: URL,
    move: Bool,
    policy: UnifiedFileSystemService.ExistingItemPolicy
  ) throws -> UUID {
    loadIfNeeded()
    let job = try makeJob(
      sources: sources,
      destination: destination,
      move: move,
      policy: policy
    )
    jobs.append(job)
    do {
      try persistRecordingFailure()
    } catch {
      jobs.removeAll { $0.id == job.id }
      throw error
    }
    postChange()
    kickWorker()
    return job.id
  }

  func enqueueAndWait(
    sources: [URL],
    destination: URL,
    move: Bool,
    policy: UnifiedFileSystemService.ExistingItemPolicy
  ) async throws -> [URL] {
    loadIfNeeded()
    let job = try makeJob(
      sources: sources,
      destination: destination,
      move: move,
      policy: policy
    )
    jobs.append(job)
    do {
      try persistRecordingFailure()
    } catch {
      jobs.removeAll { $0.id == job.id }
      throw error
    }
    postChange()

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if let current = jobs.first(where: { $0.id == job.id }), current.state == .cancelled {
          continuation.resume(throwing: TransferQueueError.cancelled)
          return
        }
        waiters[job.id, default: []].append(continuation)
        kickWorker()
      }
    } onCancel: {
      Task { await self.cancelFromWaiter(job.id) }
    }
  }

  func pause(_ id: UUID) throws {
    loadIfNeeded()
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    guard jobs[index].state == .queued || jobs[index].state == .running else { return }
    let previous = jobs[index]
    jobs[index].state = .paused
    jobs[index].updatedAt = Date()
    do {
      try persistRecordingFailure()
    } catch {
      jobs[index] = previous
      throw error
    }
    if activeJobID == id { activeTask?.cancel() }
    postChange()
  }

  func resume(_ id: UUID) throws {
    loadIfNeeded()
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    guard jobs[index].state == .paused || jobs[index].state == .failed else { return }
    let previous = jobs[index]
    jobs[index].state = .queued
    jobs[index].errorMessage = nil
    jobs[index].updatedAt = Date()
    do {
      try persistRecordingFailure()
    } catch {
      jobs[index] = previous
      throw error
    }
    postChange()
    kickWorker()
  }

  func cancel(_ id: UUID) throws {
    loadIfNeeded()
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    guard ![State.completed, .cancelled].contains(jobs[index].state) else { return }
    let previous = jobs[index]
    jobs[index].state = .cancelled
    jobs[index].updatedAt = Date()
    jobs[index].errorMessage = TransferQueueError.cancelled.localizedDescription
    do {
      try persistRecordingFailure()
    } catch {
      jobs[index] = previous
      throw error
    }
    if activeJobID == id { activeTask?.cancel() }
    resumeWaiters(for: id, with: .failure(TransferQueueError.cancelled))
    postChange()
  }

  func remove(_ id: UUID) throws {
    loadIfNeeded()
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    guard [.completed, .failed, .cancelled].contains(jobs[index].state) else { return }
    let removed = jobs.remove(at: index)
    do {
      try persistRecordingFailure()
    } catch {
      jobs.insert(removed, at: index)
      throw error
    }
    waiters[id] = nil
    postChange()
  }

  func removeFinished() throws {
    loadIfNeeded()
    let previous = jobs
    let removable = Set(
      jobs.filter { [.completed, .failed, .cancelled].contains($0.state) }.map(\.id)
    )
    jobs.removeAll { removable.contains($0.id) }
    do {
      try persistRecordingFailure()
    } catch {
      jobs = previous
      throw error
    }
    for id in removable { waiters[id] = nil }
    postChange()
  }

  private func makeJob(
    sources: [URL],
    destination: URL,
    move: Bool,
    policy: UnifiedFileSystemService.ExistingItemPolicy
  ) throws -> Job {
    guard jobs.count < Self.maximumJobCount else {
      throw TransferQueueError.persistence("転送キューの件数が上限に達しています。完了済みの履歴を削除してください。")
    }
    guard sources.count <= Self.maximumSourcesPerJob else {
      throw TransferQueueError.persistence("1つの転送ジョブに含められる項目数の上限を超えています。")
    }
    let normalizedSources = try uniqueLocations(sources)
    guard !normalizedSources.isEmpty else {
      throw FileOperationError.noSelection
    }
    let normalizedDestination = try validatedLocation(destination)
    let now = Date()
    return Job(
      id: UUID(),
      sources: normalizedSources,
      destination: normalizedDestination,
      move: move,
      policy: policy,
      createdAt: now,
      updatedAt: now,
      state: .queued,
      completedSourceCount: 0,
      resultURLs: [],
      attemptCount: 0,
      errorMessage: nil
    )
  }

  private func kickWorker() {
    guard workerTask == nil else { return }
    workerTask = Task { [weak self] in
      await self?.drain()
    }
  }

  private func drain() async {
    defer { workerTask = nil }

    while let jobID = nextQueuedJobID() {
      guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
      if jobs[index].completedSourceCount >= jobs[index].sources.count {
        finishJob(at: index)
        continue
      }

      jobs[index].state = .running
      jobs[index].attemptCount += 1
      jobs[index].updatedAt = Date()
      jobs[index].errorMessage = nil
      do {
        try persistRecordingFailure()
      } catch {
        failForPersistence(jobID: jobID, underlying: error, afterCompletedTransfer: false)
        continue
      }
      postChange()

      let sourceIndex = jobs[index].completedSourceCount
      let source = jobs[index].sources[sourceIndex]
      let destination = jobs[index].destination
      let move = jobs[index].move
      let policy = jobs[index].policy
      activeJobID = jobID
      let operation = Task {
        try await UnifiedFileSystemService.transfer(
          [source],
          to: destination,
          move: move,
          policy: policy
        )
      }
      activeTask = operation

      do {
        let result = try await operation.value
        activeTask = nil
        activeJobID = nil
        guard let currentIndex = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
        guard jobs[currentIndex].state != .cancelled else { continue }
        if jobs[currentIndex].state == .paused { continue }
        jobs[currentIndex].resultURLs.append(contentsOf: result)
        jobs[currentIndex].completedSourceCount += 1
        jobs[currentIndex].updatedAt = Date()
        if jobs[currentIndex].completedSourceCount >= jobs[currentIndex].sources.count {
          finishJob(at: currentIndex)
        } else {
          jobs[currentIndex].state = .queued
          do {
            try persistRecordingFailure()
          } catch {
            failForPersistence(jobID: jobID, underlying: error, afterCompletedTransfer: true)
            continue
          }
          postChange()
        }
      } catch is CancellationError {
        activeTask = nil
        activeJobID = nil
        guard let currentIndex = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
        switch jobs[currentIndex].state {
        case .paused, .cancelled:
          break
        default:
          jobs[currentIndex].state = .cancelled
          jobs[currentIndex].errorMessage = TransferQueueError.cancelled.localizedDescription
          jobs[currentIndex].updatedAt = Date()
          resumeWaiters(for: jobID, with: .failure(TransferQueueError.cancelled))
        }
        do { try persistRecordingFailure() } catch {
          persistenceErrorMessage = persistenceMessage(for: error, afterCompletedTransfer: false)
        }
        postChange()
      } catch {
        activeTask = nil
        activeJobID = nil
        guard let currentIndex = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
        let completed = jobs[currentIndex].completedSourceCount
        let total = jobs[currentIndex].sources.count
        let queueError = TransferQueueError.partialFailure(
          completed: completed,
          total: total,
          message: error.localizedDescription
        )
        jobs[currentIndex].state = .failed
        jobs[currentIndex].errorMessage = queueError.localizedDescription
        jobs[currentIndex].updatedAt = Date()
        do { try persistRecordingFailure() } catch {
          persistenceErrorMessage = persistenceMessage(for: error, afterCompletedTransfer: false)
        }
        resumeWaiters(for: jobID, with: .failure(queueError))
        postChange()
      }
    }
  }

  private func finishJob(at index: Int) {
    let previousJobs = jobs
    let id = jobs[index].id
    jobs[index].state = .completed
    jobs[index].completedSourceCount = jobs[index].sources.count
    jobs[index].updatedAt = Date()
    jobs[index].errorMessage = nil
    let results = jobs[index].resultURLs
    trimHistory()
    do {
      try persistRecordingFailure()
      resumeWaiters(for: id, with: .success(results))
    } catch {
      jobs = previousJobs
      failForPersistence(jobID: id, underlying: error, afterCompletedTransfer: true)
      return
    }
    postChange()
  }

  private func failForPersistence(
    jobID: UUID,
    underlying: Error,
    afterCompletedTransfer: Bool
  ) {
    let message = persistenceMessage(
      for: underlying,
      afterCompletedTransfer: afterCompletedTransfer
    )
    persistenceErrorMessage = message
    let queueError = TransferQueueError.persistence(message)
    if let index = jobs.firstIndex(where: { $0.id == jobID }) {
      jobs[index].state = .failed
      jobs[index].errorMessage = message
      jobs[index].updatedAt = Date()
    }
    resumeWaiters(for: jobID, with: .failure(queueError))
    postChange()
  }

  private func persistenceMessage(for error: Error, afterCompletedTransfer: Bool) -> String {
    let prefix =
      afterCompletedTransfer
      ? "転送は完了しましたが、進行状況を保存できませんでした。重複を避けるため、このジョブは自動再試行しません。"
      : "転送キューを保存できなかったため、処理を開始しませんでした。"
    return "\(prefix) 空き容量とApplication Supportフォルダの権限を確認してください。\n\(error.localizedDescription)"
  }

  private func nextQueuedJobID() -> UUID? {
    jobs.first(where: { $0.state == .queued })?.id
  }

  private func resumeWaiters(for id: UUID, with result: Result<[URL], Error>) {
    let continuations = waiters.removeValue(forKey: id) ?? []
    for continuation in continuations {
      continuation.resume(with: result)
    }
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }

    do {
      let data = try AppStoragePaths.readRegularFile(
        at: persistenceURL,
        maximumBytes: Self.maximumPersistenceBytes
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let persisted = try decoder.decode(PersistedQueue.self, from: data)
      guard persisted.version == 1, persisted.jobs.count <= Self.maximumJobCount else {
        throw CocoaError(.coderInvalidValue)
      }

      var identifiers = Set<UUID>()
      jobs = try persisted.jobs.map { job in
        guard identifiers.insert(job.id).inserted else {
          throw TransferQueueError.persistence("転送キューに重複したジョブIDがあります。")
        }
        var recovered = try validatedPersistedJob(job)
        if recovered.state == .running {
          // A crash can occur after the destination was committed but before the
          // progress record was flushed. Automatically retrying that source can
          // create a duplicate (keep-both) or repeat a move. Require an explicit
          // resume after the user has inspected the destination.
          recovered.state = .paused
          recovered.errorMessage =
            "前回の実行中にアプリが終了したため一時停止しました。転送先を確認してから再開してください。"
          recovered.updatedAt = Date()
        }
        return recovered
      }
      trimHistory()
      do { try persistRecordingFailure() } catch
      { /* recovered state remains available in memory and is surfaced in Settings */  }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: persistenceURL)
      jobs = []
      persistenceErrorMessage = "転送キューの保存データが破損または不正だったため隔離しました。\n\(error.localizedDescription)"
    }
  }

  private func persistRecordingFailure() throws {
    do {
      try persist()
      persistenceErrorMessage = nil
    } catch {
      persistenceErrorMessage =
        "転送キューを保存できませんでした。空き容量とApplication Supportフォルダの権限を確認してください。\n\(error.localizedDescription)"
      throw error
    }
  }

  private func persist() throws {
    guard jobs.count <= Self.maximumJobCount else {
      throw TransferQueueError.persistence("転送キューの件数が安全上の上限を超えています。")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(PersistedQueue(version: 1, jobs: jobs))
    guard data.count <= Self.maximumPersistenceBytes else {
      throw TransferQueueError.persistence("転送キューの保存サイズが安全上の上限を超えています。")
    }
    try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: persistenceURL.path
    )
  }

  private func trimHistory() {
    let terminal =
      jobs
      .filter { [.completed, .failed, .cancelled].contains($0.state) }
      .sorted { $0.updatedAt > $1.updatedAt }
    let retainedTerminalIDs = Set(terminal.prefix(Self.retainedTerminalJobCount).map(\.id))
    jobs.removeAll {
      [.completed, .failed, .cancelled].contains($0.state)
        && !retainedTerminalIDs.contains($0.id)
    }
  }

  private func validatedPersistedJob(_ job: Job) throws -> Job {
    guard !job.sources.isEmpty, job.sources.count <= Self.maximumSourcesPerJob,
      job.completedSourceCount >= 0, job.completedSourceCount <= job.sources.count,
      job.resultURLs.count <= job.completedSourceCount,
      job.attemptCount >= 0, job.attemptCount <= Self.maximumAttempts,
      job.createdAt.timeIntervalSinceReferenceDate.isFinite,
      job.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      job.errorMessage?.utf8.count ?? 0 <= 64 * 1_024
    else {
      throw TransferQueueError.persistence("転送キューの進行状況に不整合があります。")
    }
    if job.state == .completed, job.completedSourceCount != job.sources.count {
      throw TransferQueueError.persistence("完了済み転送の進行状況に不整合があります。")
    }

    let validatedSources = try uniqueLocations(job.sources)
    guard validatedSources.count == job.sources.count else {
      throw TransferQueueError.persistence("転送キューに重複した転送元があります。")
    }
    return Job(
      id: job.id,
      sources: validatedSources,
      destination: try validatedLocation(job.destination),
      move: job.move,
      policy: job.policy,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      state: job.state,
      completedSourceCount: job.completedSourceCount,
      resultURLs: try job.resultURLs.map(validatedLocation),
      attemptCount: job.attemptCount,
      errorMessage: job.errorMessage
    )
  }

  private func validatedLocation(_ url: URL) throws -> URL {
    let normalized = NafiURL.normalized(url)
    let isValidRemote =
      NafiURL.isRemote(normalized)
      && NafiURL.profileID(in: normalized) != nil
      && NafiURL.remotePath(in: normalized) != nil
    guard normalized.isFileURL || isValidRemote,
      normalized.absoluteString.utf8.count <= Self.maximumURLBytes
    else {
      throw TransferQueueError.persistence("転送キューに不正または長すぎるURLがあります。")
    }
    return normalized
  }

  private func uniqueLocations(_ urls: [URL]) throws -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    result.reserveCapacity(urls.count)
    for url in urls {
      let normalized = try validatedLocation(url)
      guard let key = NafiURL.locationKey(normalized) else {
        throw TransferQueueError.persistence("転送キューに不正なURLがあります。")
      }
      if seen.insert(key).inserted { result.append(normalized) }
    }
    return result
  }

  private func cancelFromWaiter(_ id: UUID) {
    do {
      try cancel(id)
    } catch {
      let message = persistenceMessage(for: error, afterCompletedTransfer: false)
      resumeWaiters(for: id, with: .failure(TransferQueueError.persistence(message)))
    }
  }

  private func postChange() {
    if Thread.isMainThread {
      NotificationCenter.default.post(name: .nafiTransferQueueDidChange, object: nil)
    } else {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .nafiTransferQueueDidChange, object: nil)
      }
    }
  }
}
