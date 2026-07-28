import AppKit
import SwiftUI

struct FileThumbnailView: View {
  let item: FileItem
  let width: CGFloat
  let height: CGFloat
  var contentMode: SwiftUI.ContentMode = .fit
  var cornerRadius: CGFloat = 4

  @AppStorage(ThumbnailPreferenceKey.localImages) private var localImages = true
  @AppStorage(ThumbnailPreferenceKey.localVideos) private var localVideos = true
  @AppStorage(ThumbnailPreferenceKey.remoteImages) private var remoteImages = false
  @AppStorage(ThumbnailPreferenceKey.remoteVideos) private var remoteVideos = false

  @State private var thumbnail: NSImage?

  var body: some View {
    ZStack {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: contentMode)
      } else {
        Image(nsImage: item.icon)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .padding(fallbackPadding)
      }
    }
    .frame(width: width, height: height)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .task(id: requestIdentity) {
      thumbnail = nil
      guard thumbnailsEnabled else { return }
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let image = await FileThumbnailService.shared.thumbnail(
        for: item,
        pointSize: CGSize(width: width, height: height),
        scale: scale
      )
      guard !Task.isCancelled else { return }
      thumbnail = image
    }
  }

  private var fallbackPadding: CGFloat {
    min(width, height) >= 48 ? 4 : 0
  }

  private var thumbnailsEnabled: Bool {
    guard let kind = item.thumbnailMediaKind else { return false }
    let isRemote = NafiURL.isRemote(item.url)
    switch (isRemote, kind) {
    case (false, .image): return localImages
    case (false, .video): return localVideos
    case (true, .image): return remoteImages
    case (true, .video): return remoteVideos
    }
  }

  private var requestIdentity: RequestIdentity {
    RequestIdentity(
      url: item.url,
      modified: item.modificationDate,
      fileSize: item.fileSize,
      width: width,
      height: height,
      enabled: thumbnailsEnabled
    )
  }
}

private struct RequestIdentity: Hashable {
  let url: URL
  let modified: Date?
  let fileSize: Int64?
  let width: CGFloat
  let height: CGFloat
  let enabled: Bool
}

enum ThumbnailPreferenceKey {
  static let localImages = "Nami.thumbnails.localImages"
  static let localVideos = "Nami.thumbnails.localVideos"
  static let remoteImages = "Nami.thumbnails.remoteImages"
  static let remoteVideos = "Nami.thumbnails.remoteVideos"
}
