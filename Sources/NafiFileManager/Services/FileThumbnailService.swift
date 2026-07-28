import AppKit
import Foundation
import QuickLookThumbnailing

@MainActor
final class FileThumbnailService {
  static let shared = FileThumbnailService()

  private let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 512
    cache.totalCostLimit = 160 * 1_024 * 1_024
    return cache
  }()

  private var inFlight: [String: Task<NSImage?, Never>] = [:]

  private init() {}

  func thumbnail(for item: FileItem, pointSize: CGSize, scale: CGFloat) async -> NSImage? {
    guard item.thumbnailMediaKind != nil else { return nil }

    let requestSize = bucketedSize(for: pointSize)
    let cacheKey = makeCacheKey(for: item, pointSize: requestSize, scale: scale)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }
    if let task = inFlight[cacheKey] {
      return await task.value
    }

    let task = Task<NSImage?, Never> {
      do {
        return try await UnifiedFileSystemService.withTemporaryLocalCopy(of: item.url) { localURL in
          await Self.generateThumbnail(for: localURL, pointSize: requestSize, scale: scale)
        }
      } catch {
        return nil
      }
    }
    inFlight[cacheKey] = task

    let image = await task.value
    inFlight[cacheKey] = nil
    if let image {
      let pixelWidth = max(1, Int(image.size.width * scale))
      let pixelHeight = max(1, Int(image.size.height * scale))
      cache.setObject(image, forKey: cacheKey as NSString, cost: pixelWidth * pixelHeight * 4)
    }
    return image
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

  private static func generateThumbnail(
    for url: URL,
    pointSize: CGSize,
    scale: CGFloat
  ) async -> NSImage? {
    await withCheckedContinuation { continuation in
      let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: pointSize,
        scale: scale,
        representationTypes: [.thumbnail]
      )
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
        representation,
        _ in
        continuation.resume(returning: representation?.nsImage)
      }
    }
  }
}
