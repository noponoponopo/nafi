import Foundation

@MainActor
final class TransferQueueModel: ObservableObject {
  @Published private(set) var jobs: [TransferQueue.Job] = []
  @Published private(set) var isRefreshing = false
  @Published var errorMessage: String?

  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .nafiTransferQueueDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.refresh()
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func refresh() async {
    isRefreshing = true
    jobs = await TransferQueue.shared.snapshots()
    errorMessage = await TransferQueue.shared.latestPersistenceError()
    isRefreshing = false
  }

  func pause(_ job: TransferQueue.Job) {
    perform { try await TransferQueue.shared.pause(job.id) }
  }

  func resume(_ job: TransferQueue.Job) {
    perform { try await TransferQueue.shared.resume(job.id) }
  }

  func cancel(_ job: TransferQueue.Job) {
    perform { try await TransferQueue.shared.cancel(job.id) }
  }

  func remove(_ job: TransferQueue.Job) {
    perform { try await TransferQueue.shared.remove(job.id) }
  }

  func removeFinished() {
    perform { try await TransferQueue.shared.removeFinished() }
  }

  private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
    Task {
      let operationError: String?
      do {
        try await operation()
        operationError = nil
      } catch {
        operationError = error.localizedDescription
      }
      await refresh()
      if let operationError { errorMessage = operationError }
    }
  }
}
