import Foundation

private struct SpotlightSearchSnapshot: Sendable {
  let urls: [URL]
}

@MainActor
private final class SpotlightQueryRunner {
  private let query = NSMetadataQuery()
  private var completionObserver: NSObjectProtocol?
  private var continuation: CheckedContinuation<SpotlightSearchSnapshot?, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var finished = false

  func run(terms: [String], root: URL, timeoutNanoseconds: UInt64 = 3_000_000_000) async -> SpotlightSearchSnapshot? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        query.searchScopes = [root.standardizedFileURL]
        query.predicate = NSCompoundPredicate(
          andPredicateWithSubpredicates: terms.map { term in
            NSCompoundPredicate(
              orPredicateWithSubpredicates: FileNameSearchMatcher.spotlightVariants(for: term).map { variant in
                NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, variant)
              }
            )
          }
        )
        query.notificationBatchingInterval = 0.2

        completionObserver = NotificationCenter.default.addObserver(
          forName: .NSMetadataQueryDidFinishGathering,
          object: query,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.completeWithCurrentResults() }
        }

        guard query.start() else {
          complete(nil)
          return
        }

        timeoutTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: timeoutNanoseconds)
          guard !Task.isCancelled else { return }
          await MainActor.run { self?.complete(nil) }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.complete(nil) }
    }
  }

  private func completeWithCurrentResults() {
    guard !finished else { return }
    query.disableUpdates()
    let urls = query.results.compactMap { result -> URL? in
      guard let item = result as? NSMetadataItem else { return nil }
      return item.value(forAttribute: NSMetadataItemURLKey) as? URL
    }
    complete(SpotlightSearchSnapshot(urls: urls))
  }

  private func complete(_ value: SpotlightSearchSnapshot?) {
    guard !finished else { return }
    finished = true
    timeoutTask?.cancel()
    timeoutTask = nil
    if let completionObserver {
      NotificationCenter.default.removeObserver(completionObserver)
      self.completionObserver = nil
    }
    query.stop()
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: value)
  }
}

enum FileSpotlightSearchService {
  /// Runs an indexed, one-shot Spotlight query restricted to `root`.
  /// Returns nil only when Spotlight cannot complete promptly; callers may then
  /// fall back to a direct filesystem walk for completeness on unindexed volumes.
  static func matchingURLs(text: String, root: URL) async -> [URL]? {
    guard root.isFileURL else { return nil }
    let terms = FileNameSearchMatcher.terms(text)
    guard !terms.isEmpty else { return [] }
    return await SpotlightQueryRunner().run(terms: terms, root: root)?.urls
  }
}
