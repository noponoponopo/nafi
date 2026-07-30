import AppKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let nafiFileCollection = UTType(exportedAs: "app.nafi.file-collection")
  static let nafiSidebarFavorite = UTType(exportedAs: "app.nafi.sidebar-favorite")
  static let nafiDropStackInternal = UTType(exportedAs: "app.nafi.drop-stack-internal")
}

enum DragPayloadLimits {
  static let maximumPayloadBytes = 4 * 1_024 * 1_024
  static let maximumURLs = 10_000
  static let maximumURLBytes = 32 * 1_024
  static let maximumProviders = 10_000
}

struct FileDragPayload: Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case urls
  }

  let urls: [URL]

  init(urls: [URL]) {
    self.urls = urls
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decoded = try container.decode([URL].self, forKey: .urls)
    guard decoded.count <= DragPayloadLimits.maximumURLs,
      decoded.allSatisfy({
        $0.absoluteString.utf8.count <= DragPayloadLimits.maximumURLBytes
          && NafiURL.locationKey($0) != nil
      })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .urls,
        in: container,
        debugDescription: "Invalid or oversized file drag payload"
      )
    }
    urls = decoded
  }

  func encode(to encoder: Encoder) throws {
    guard urls.count <= DragPayloadLimits.maximumURLs,
      urls.allSatisfy({
        $0.absoluteString.utf8.count <= DragPayloadLimits.maximumURLBytes
          && NafiURL.locationKey($0) != nil
      })
    else {
      throw EncodingError.invalidValue(
        urls,
        .init(codingPath: encoder.codingPath, debugDescription: "Invalid or oversized file drag payload")
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(urls, forKey: .urls)
  }
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
    guard data.count <= DragPayloadLimits.maximumPayloadBytes else { return nil }
    return try? JSONDecoder().decode(payloadType, from: data)
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

  static func pasteboardItem(for payload: FileDragPayload) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    if let firstURL = payload.urls.first, firstURL.isFileURL {
      item.setString(firstURL.absoluteString, forType: .fileURL)
    }
    if let data = try? JSONEncoder().encode(payload),
      data.count <= DragPayloadLimits.maximumPayloadBytes
    {
      item.setData(
        data,
        forType: NSPasteboard.PasteboardType(UTType.nafiFileCollection.identifier)
      )
    }
    return item
  }

  static func sidebarFavoriteProvider(for favoriteID: UUID) -> NSItemProvider {
    register(
      SidebarFavoriteDragPayload(favoriteID: favoriteID),
      contentType: .nafiSidebarFavorite,
      on: NSItemProvider()
    )
  }

  static func dropStackFileProvider(for payload: FileDragPayload) -> NSItemProvider {
    let provider = fileProvider(for: payload)
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.nafiDropStackInternal.identifier,
      visibility: .ownProcess
    ) { completion in
      completion(Data(), nil)
      return nil
    }
    return provider
  }

  static func containsDropStackInternal(in providers: [NSItemProvider]) -> Bool {
    providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiDropStackInternal.identifier)
    }
  }

  static func canLoadFileURLs(from providers: [NSItemProvider]) -> Bool {
    providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.nafiFileCollection.identifier)
        || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
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
        let urls = uniqueLocations(payloads.flatMap(\.urls))
        if urls.isEmpty {
          loadFileURLRepresentations(from: providers, completion: completion)
        } else {
          completion(urls)
        }
      }
      return
    }

    loadFileURLRepresentations(from: providers, completion: completion)
  }

  private static func loadFileURLRepresentations(
    from providers: [NSItemProvider],
    completion: @escaping ([URL]) -> Void
  ) {
    let fileProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }.prefix(DragPayloadLimits.maximumProviders)
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
    guard let data = try? JSONEncoder().encode(payload),
      data.count <= DragPayloadLimits.maximumPayloadBytes
    else { return provider }
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
    let matching = Array(providers.lazy.filter {
      $0.hasItemConformingToTypeIdentifier(contentType.identifier)
    }.prefix(DragPayloadLimits.maximumProviders))
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
    if let data = item as? Data,
      data.count <= DragPayloadLimits.maximumURLBytes,
      let string = String(data: data, encoding: .utf8)
    {
      return parsedFileURL(string)
    }
    return nil
  }

  private static func parsedFileURL(_ value: String) -> URL? {
    guard value.utf8.count <= DragPayloadLimits.maximumURLBytes else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  private static func uniqueLocations(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.prefix(DragPayloadLimits.maximumURLs).compactMap { url in
      guard let key = NafiURL.locationKey(url), seen.insert(key).inserted else { return nil }
      return NafiURL.normalized(url)
    }
  }
}
