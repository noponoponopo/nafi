import AppKit
import Foundation
import QuickLookThumbnailing

private actor ThumbnailGenerationLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let limit: Int
  private var active = 0
  private var waiters: [Waiter] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async -> Bool {
    if Task.isCancelled { return false }
    if active < limit {
      active += 1
      return true
    }

    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: false)
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func release() {
    if let waiter = waiters.popLast() {
      waiter.continuation.resume(returning: true)
    } else {
      active = max(0, active - 1)
    }
  }

  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}

private let thumbnailGenerationLimiter = ThumbnailGenerationLimiter(limit: 2)

@MainActor
final class FileThumbnailService {
  static let shared = FileThumbnailService()

  private let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  private struct PendingThumbnail {
    let id: UUID
    let task: Task<NSImage?, Never>
    var waiters: Set<UUID>
  }
  private var inFlight: [String: PendingThumbnail] = [:]

  private init() {}

  func thumbnail(for item: FileItem, pointSize: CGSize, scale: CGFloat) async -> NSImage? {
    guard item.thumbnailMediaKind != nil else { return nil }

    let requestSize = bucketedSize(for: pointSize)
    let cacheKey = makeCacheKey(for: item, pointSize: requestSize, scale: scale)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }
    guard !Task.isCancelled else { return nil }
    let waiterID = UUID()
    let pending: PendingThumbnail
    if var existing = inFlight[cacheKey] {
      existing.waiters.insert(waiterID)
      pending = existing
      inFlight[cacheKey] = existing
    } else {
      let task = Task<NSImage?, Never>(priority: .utility) {
        // Bound the download as well as decoding, not just Quick Look's final step.
        guard await thumbnailGenerationLimiter.acquire() else { return nil }
        let image: NSImage?
        do {
          try Task.checkCancellation()
          image = try await UnifiedFileSystemService.withTemporaryLocalCopy(of: item.url) {
            localURL in
            guard !Task.isCancelled else { return nil }
            return await ThumbnailRequest(url: localURL, size: requestSize, scale: scale).result()
          }
        } catch {
          image = nil
        }
        await thumbnailGenerationLimiter.release()
        return Task.isCancelled ? nil : image
      }
      pending = PendingThumbnail(id: UUID(), task: task, waiters: [waiterID])
      inFlight[cacheKey] = pending
    }

    let image = await withTaskCancellationHandler {
      await pending.task.value
    } onCancel: {
      Task { @MainActor in
        self.releaseWaiter(waiterID, key: cacheKey, requestID: pending.id)
      }
    }
    if inFlight[cacheKey]?.id == pending.id {
      inFlight[cacheKey] = nil
      if let image {
        let pixelWidth = max(1, Int(image.size.width * scale))
        let pixelHeight = max(1, Int(image.size.height * scale))
        cache.setObject(image, forKey: cacheKey as NSString, cost: pixelWidth * pixelHeight * 4)
      }
    }
    return Task.isCancelled ? nil : image
  }

  private func releaseWaiter(_ id: UUID, key: String, requestID: UUID) {
    guard var pending = inFlight[key], pending.id == requestID else { return }
    pending.waiters.remove(id)
    if pending.waiters.isEmpty {
      inFlight[key] = nil
      pending.task.cancel()
    } else {
      inFlight[key] = pending
    }
  }

  private func makeCacheKey(for item: FileItem, pointSize: CGSize, scale: CGFloat) -> String {
    let modified = item.modificationDate?.timeIntervalSince1970 ?? 0
    let size = item.fileSize ?? 0
    return
      "\(item.url.absoluteString)|\(modified)|\(size)|\(Int(pointSize.width))x\(Int(pointSize.height))@\(scale)"
  }

  private func bucketedSize(for size: CGSize) -> CGSize {
    let requested = max(size.width, size.height)
    let buckets: [CGFloat] = [32, 64, 96, 128, 192, 256, 384, 512]
    let edge = buckets.first(where: { $0 >= requested }) ?? 512
    return CGSize(width: edge, height: edge)
  }

}

@MainActor
private final class ThumbnailRequest {
  private let request: QLThumbnailGenerator.Request
  private var continuation: CheckedContinuation<NSImage?, Never>?
  private var completed = false

  init(url: URL, size: CGSize, scale: CGFloat) {
    request = QLThumbnailGenerator.Request(
      fileAt: url, size: size, scale: scale, representationTypes: [.thumbnail]
    )
  }

  func result() async -> NSImage? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !completed, !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        self.continuation = continuation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
          Task { @MainActor in self.finish(representation?.nsImage) }
        }
      }
    } onCancel: {
      Task { @MainActor in
        QLThumbnailGenerator.shared.cancel(self.request)
        self.finish(nil)
      }
    }
  }

  private func finish(_ image: NSImage?) {
    guard !completed else { return }
    completed = true
    let pending = continuation
    continuation = nil
    pending?.resume(returning: image)
  }
}
