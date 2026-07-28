import AppKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let nafiFileCollection = UTType(exportedAs: "app.nafi.file-collection")
  static let nafiPaneTab = UTType(exportedAs: "app.nafi.pane-tab")
  static let nafiSidebarFavorite = UTType(exportedAs: "app.nafi.sidebar-favorite")
}

struct FileDragPayload: Codable, Sendable {
  let urls: [URL]
}

struct PaneDragPayload: Codable, Sendable {
  let sourcePaneID: UUID
  let sourceTabID: UUID
  let url: URL
}

struct SidebarFavoriteDragPayload: Codable, Sendable {
  let favoriteID: UUID
}

private struct PayloadDecoder<Payload: Decodable & Sendable>: @unchecked Sendable {
  private let payloadType: Payload.Type

  init(_ payloadType: Payload.Type) {
    self.payloadType = payloadType
  }

  func decode(_ data: Data) -> Payload? {
    try? JSONDecoder().decode(payloadType, from: data)
  }
}

private final class LockedPayloadCollection<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Element] = []

  func append(_ element: Element) {
    lock.lock()
    storage.append(element)
    lock.unlock()
  }

  var values: [Element] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

enum DragPayloadProvider {
  static let fileDropTypes: [UTType] = [.nafiFileCollection, .fileURL]
  static let tabDropTypes: [UTType] = [.nafiPaneTab, .nafiFileCollection, .fileURL]
  static let favoriteDropTypes: [UTType] = [
    .nafiSidebarFavorite, .nafiFileCollection, .fileURL,
  ]

  static func fileProvider(for payload: FileDragPayload) -> NSItemProvider {
    let provider = NSItemProvider()
    if let firstURL = payload.urls.first {
      provider.suggestedName = firstURL.lastPathComponent
      if firstURL.isFileURL, let data = firstURL.absoluteString.data(using: .utf8) {
        provider.registerDataRepresentation(
          forTypeIdentifier: UTType.fileURL.identifier,
          visibility: .all
        ) { completion in
          completion(data, nil)
          return nil
        }
      }
    }
    return register(payload, contentType: .nafiFileCollection, on: provider)
  }

  static func paneProvider(for payload: PaneDragPayload) -> NSItemProvider {
    register(payload, contentType: .nafiPaneTab, on: NSItemProvider())
  }

  static func sidebarFavoriteProvider(for favoriteID: UUID) -> NSItemProvider {
    register(
      SidebarFavoriteDragPayload(favoriteID: favoriteID),
      contentType: .nafiSidebarFavorite,
      on: NSItemProvider()
    )
  }

  static func canLoadFileURLs(from providers: [NSItemProvider]) -> Bool {
    providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiFileCollection.identifier)
        || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
  }

  static func containsPanePayload(in providers: [NSItemProvider]) -> Bool {
    providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiPaneTab.identifier)
    }
  }

  static func containsSidebarFavoritePayload(in providers: [NSItemProvider]) -> Bool {
    providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiSidebarFavorite.identifier)
    }
  }

  static func draggingPasteboardContains(_ type: UTType) -> Bool {
    NSPasteboard(name: .drag).availableType(
      from: [NSPasteboard.PasteboardType(type.identifier)]) != nil
  }

  static func loadFileURLs(
    from providers: [NSItemProvider],
    completion: @escaping ([URL]) -> Void
  ) {
    let customProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiFileCollection.identifier)
    }

    if !customProviders.isEmpty {
      loadPayloads(
        FileDragPayload.self,
        from: customProviders,
        contentType: .nafiFileCollection
      ) { payloads in
        completion(uniqueLocations(payloads.flatMap(\.urls)))
      }
      return
    }

    let fileProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    guard !fileProviders.isEmpty else {
      completion([])
      return
    }

    let group = DispatchGroup()
    let urls = LockedPayloadCollection<URL>()

    for provider in fileProviders {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        if let url = fileURL(from: item) {
          urls.append(url)
        }
        group.leave()
      }
    }

    group.notify(queue: .main) {
      completion(uniqueLocations(urls.values))
    }
  }

  static func loadPanePayload(
    from providers: [NSItemProvider],
    completion: @escaping (PaneDragPayload?) -> Void
  ) {
    loadPayloads(PaneDragPayload.self, from: providers, contentType: .nafiPaneTab) {
      completion($0.first)
    }
  }

  static func loadSidebarFavoritePayload(
    from providers: [NSItemProvider],
    completion: @escaping (SidebarFavoriteDragPayload?) -> Void
  ) {
    loadPayloads(
      SidebarFavoriteDragPayload.self,
      from: providers,
      contentType: .nafiSidebarFavorite
    ) {
      completion($0.first)
    }
  }

  private static func register<Payload: Encodable>(
    _ payload: Payload,
    contentType: UTType,
    on provider: NSItemProvider
  ) -> NSItemProvider {
    guard let data = try? JSONEncoder().encode(payload) else { return provider }
    provider.registerDataRepresentation(
      forTypeIdentifier: contentType.identifier,
      visibility: .all
    ) { completion in
      completion(data, nil)
      return nil
    }
    return provider
  }

  private static func loadPayloads<Payload: Decodable & Sendable>(
    _ payloadType: Payload.Type,
    from providers: [NSItemProvider],
    contentType: UTType,
    completion: @escaping ([Payload]) -> Void
  ) {
    let matching = providers.filter {
      $0.hasItemConformingToTypeIdentifier(contentType.identifier)
    }
    guard !matching.isEmpty else {
      completion([])
      return
    }

    let group = DispatchGroup()
    let decoder = PayloadDecoder(payloadType)
    let payloads = LockedPayloadCollection<Payload>()

    for provider in matching {
      group.enter()
      provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
        if let data, let payload = decoder.decode(data) {
          payloads.append(payload)
        }
        group.leave()
      }
    }

    group.notify(queue: .main) {
      completion(payloads.values)
    }
  }

  private static func fileURL(from item: Any?) -> URL? {
    if let url = item as? URL, url.isFileURL { return url.standardizedFileURL }
    if let url = item as? NSURL {
      let value = url as URL
      if value.isFileURL { return value.standardizedFileURL }
    }
    if let string = item as? String {
      return parsedFileURL(string)
    }
    if let string = item as? NSString {
      return parsedFileURL(string as String)
    }
    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
      return parsedFileURL(string)
    }
    return nil
  }

  private static func parsedFileURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  private static func uniqueLocations(_ urls: [URL]) -> [URL] {
    var seen = Set<URL>()
    return urls.compactMap { url in
      let normalized = NafiURL.normalized(url)
      return seen.insert(normalized).inserted ? normalized : nil
    }
  }
}
