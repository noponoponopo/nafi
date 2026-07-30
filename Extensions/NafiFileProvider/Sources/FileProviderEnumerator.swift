import CryptoKit
import FileProvider
import Foundation
import os

private let fpEnumeratorLogger = Logger(subsystem: "app.nafi.filemanager.fileprovider", category: "enumerator")

final class NafiFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
  private struct PageToken: Codable {
    let generation: UUID
    let offset: Int
    let sortByDate: Bool
  }

  private struct StoredSnapshot: Codable {
    let generation: UUID
    let savedAt: Date
    let items: [StoredItem]
  }

  private struct StoredItem: Codable {
    let filename: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modification: Date?
    let identityToken: String?
    let contentFingerprint: String
    let readOnly: Bool
    let unavailable: Bool
  }

  private struct EnumerationCache {
    let generation: UUID
    let sortByDate: Bool
    let items: [NafiFileProviderItem]
  }

  private let containerIdentifier: NSFileProviderItemIdentifier
  private let relativePath: String
  private let domain: NSFileProviderDomain
  private let isWorkingSet: Bool
  private let lock = NSLock()
  private var invalidated = false
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var completedTaskTokens = Set<UUID>()
  private var enumerationCache: EnumerationCache?
  private let pageSize = 500
  private let maximumPageTokenBytes = 1_024
  private static let workingSetAnchor = Data("nafi-working-set".utf8)

  init(containerIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) throws {
    isWorkingSet = containerIdentifier == .workingSet
    relativePath = isWorkingSet
      ? ""
      : try FPIdentifierCodec.path(for: containerIdentifier)
    self.containerIdentifier = containerIdentifier
    self.domain = domain
    super.init()
  }

  func invalidate() {
    lock.lock()
    invalidated = true
    let active = Array(tasks.values)
    tasks.removeAll()
    completedTaskTokens.removeAll()
    enumerationCache = nil
    lock.unlock()
    active.forEach { $0.cancel() }
  }

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage
  ) {
    if isWorkingSet {
      observer.finishEnumerating(upTo: nil)
      return
    }
    let token = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      defer { self.removeTask(token) }
      do {
        try self.ensureActive()
        let pageData = page as NSData
        let initialByName = pageData == NSFileProviderPage.initialPageSortedByName
        let initialByDate = pageData == NSFileProviderPage.initialPageSortedByDate
        let cache: EnumerationCache
        let offset: Int

        if initialByName || initialByDate {
          let sortByDate = initialByDate
          var items = try await self.listItems()
          try Task.checkCancellation()
          items.sort { lhs, rhs in
            if sortByDate {
              let left = lhs.contentModificationDate ?? .distantPast
              let right = rhs.contentModificationDate ?? .distantPast
              if left != right { return left > right }
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
          }
          cache = EnumerationCache(generation: UUID(), sortByDate: sortByDate, items: items)
          self.setEnumerationCache(cache)
          offset = 0
        } else {
          let decoded = try self.decodePage(page)
          guard let existing = self.getEnumerationCache(),
            existing.generation == decoded.generation,
            existing.sortByDate == decoded.sortByDate,
            decoded.offset >= 0,
            decoded.offset <= existing.items.count
          else { throw NSFileProviderError(.pageExpired) }
          cache = existing
          offset = decoded.offset
        }

        try self.ensureActive()
        let batch = Array(cache.items.dropFirst(offset).prefix(self.pageSize))
        observer.didEnumerate(batch)
        let nextOffset = offset + batch.count
        if nextOffset < cache.items.count {
          observer.finishEnumerating(upTo: try self.encodePage(
            PageToken(generation: cache.generation, offset: nextOffset, sortByDate: cache.sortByDate)
          ))
        } else {
          try self.saveSnapshot(cache.items, generation: cache.generation)
          self.setEnumerationCache(nil)
          observer.finishEnumerating(upTo: nil)
        }
      } catch {
        fpEnumeratorLogger.error("enumerateItems failed: \(error.localizedDescription, privacy: .public)")
        observer.finishEnumeratingWithError(self.map(error))
      }
    }
    register(task, token: token)
  }

  func enumerateChanges(
    for observer: NSFileProviderChangeObserver,
    from syncAnchor: NSFileProviderSyncAnchor
  ) {
    if isWorkingSet {
      observer.finishEnumeratingChanges(
        upTo: NSFileProviderSyncAnchor(Self.workingSetAnchor),
        moreComing: false
      )
      return
    }
    let token = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      defer { self.removeTask(token) }
      do {
        try self.ensureActive()
        let previous = try self.loadSnapshot()
        guard syncAnchor.rawValue == Data(previous.generation.uuidString.utf8) else {
          throw NSFileProviderError(.syncAnchorExpired)
        }
        let current = try await self.listItems()
        try self.ensureActive()

        var previousMap: [NSFileProviderItemIdentifier: NafiFileProviderItem] = [:]
        for item in previous.items {
          let restored = try self.restore(item)
          guard previousMap.updateValue(restored, forKey: restored.itemIdentifier) == nil else {
            throw NSFileProviderError(.syncAnchorExpired)
          }
        }
        var currentMap: [NSFileProviderItemIdentifier: NafiFileProviderItem] = [:]
        for item in current {
          guard currentMap.updateValue(item, forKey: item.itemIdentifier) == nil else {
            throw FPBridgeError.malformedResponse
          }
        }

        let deleted = previousMap.keys.filter { currentMap[$0] == nil }
        let updated = current.filter { item in
          guard let old = previousMap[item.itemIdentifier] else { return true }
          return !self.sameVersion(old.itemVersion, item.itemVersion)
        }
        for chunk in updated.chunked(maximum: 2_000) where !chunk.isEmpty {
          observer.didUpdate(chunk)
        }
        for chunk in deleted.chunked(maximum: 2_000) where !chunk.isEmpty {
          observer.didDeleteItems(withIdentifiers: chunk)
        }

        let generation = UUID()
        try self.saveSnapshot(current, generation: generation)
        observer.finishEnumeratingChanges(
          upTo: NSFileProviderSyncAnchor(Data(generation.uuidString.utf8)),
          moreComing: false
        )
      } catch {
        observer.finishEnumeratingWithError(self.map(error))
      }
    }
    register(task, token: token)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    if isWorkingSet {
      completionHandler(NSFileProviderSyncAnchor(Self.workingSetAnchor))
      return
    }
    do {
      let snapshot = try loadSnapshot()
      completionHandler(NSFileProviderSyncAnchor(Data(snapshot.generation.uuidString.utf8)))
    } catch {
      completionHandler(nil)
    }
  }

  private func listItems() async throws -> [NafiFileProviderItem] {
    try ensureActive()
    let record = try FPSharedStore.domainRecord(for: domain)
    let bridge = try FPRcloneBridge()
    let relative = relativePath
    let response = try await bridge.call("operations/list", [
      "fs": record.fs,
      "remote": try fullPath(relative, record: record),
      "opt": [
        "recurse": false,
        "showOrigIDs": true,
        "showHash": false,
        "noMimeType": true,
        "metadata": false,
      ],
    ], timeout: 300)
    guard let list = response["list"] as? [[String: Any]], list.count <= 250_000 else {
      throw FPBridgeError.malformedResponse
    }

    let ordered = list.sorted { lhs, rhs in
      let leftName = (lhs["Name"] as? String) ?? ""
      let rightName = (rhs["Name"] as? String) ?? ""
      let nameOrder = leftName.localizedStandardCompare(rightName)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      let leftID = (lhs["ID"] as? String) ?? ""
      let rightID = (rhs["ID"] as? String) ?? ""
      if leftID != rightID { return leftID < rightID }
      let leftSize = (lhs["Size"] as? NSNumber)?.int64Value ?? -1
      let rightSize = (rhs["Size"] as? NSNumber)?.int64Value ?? -1
      if leftSize != rightSize { return leftSize < rightSize }
      return ((lhs["ModTime"] as? String) ?? "") < ((rhs["ModTime"] as? String) ?? "")
    }
    let grouped = Dictionary(grouping: ordered) { object in
      duplicateKey((object["Name"] as? String) ?? "")
    }
    var usedPathKeys = Set(grouped.keys)
    var occurrence: [String: Int] = [:]
    var result: [NafiFileProviderItem] = []
    result.reserveCapacity(ordered.count)

    for object in ordered {
      try Task.checkCancellation()
      guard let originalName = object["Name"] as? String, !originalName.isEmpty else {
        throw FPBridgeError.malformedResponse
      }
      let key = duplicateKey(originalName)
      let index = occurrence[key, default: 0]
      occurrence[key] = index + 1
      let duplicate = (grouped[key]?.count ?? 0) > 1
      let backendID = object["ID"] as? String
      let fingerprint = contentFingerprint(object)
      let syntheticID = backendID ?? "synthetic:\(fingerprint):\(index)"

      do {
        let relativePath = try FPIdentifierCodec.appending(originalName, to: relative)
        let suffix = backendID.map { String($0.prefix(8)) } ?? "\(index + 1)"
        let displayName = duplicate ? "\(originalName) — 重複 \(suffix)" : originalName
        result.append(try NafiFileProviderItem(
          path: relativePath,
          name: displayName,
          isDirectory: object["IsDir"] as? Bool ?? false,
          size: (object["Size"] as? NSNumber)?.int64Value,
          modTime: parseDate(object["ModTime"] as? String),
          readOnly: duplicate,
          unavailable: duplicate,
          identityToken: duplicate ? syntheticID : nil,
          contentFingerprint: fingerprint
        ))
      } catch FPBridgeError.invalidName {
        let safeToken = shortDigest(Data("\(originalName)|\(syntheticID)".utf8))
        var safeName = ".nafi-unavailable-\(safeToken)"
        var attempt = 1
        while usedPathKeys.contains(duplicateKey(safeName)) {
          safeName = ".nafi-unavailable-\(safeToken)-\(attempt)"
          attempt += 1
          guard attempt <= 10_000 else { throw FPBridgeError.malformedResponse }
        }
        usedPathKeys.insert(duplicateKey(safeName))
        let safePath = try FPIdentifierCodec.appending(safeName, to: relative)
        result.append(try NafiFileProviderItem(
          path: safePath,
          name: "扱えないリモート名 — \(safeToken)",
          isDirectory: object["IsDir"] as? Bool ?? false,
          size: (object["Size"] as? NSNumber)?.int64Value,
          modTime: parseDate(object["ModTime"] as? String),
          readOnly: true,
          unavailable: true,
          identityToken: syntheticID,
          contentFingerprint: fingerprint
        ))
      }
    }
    return result
  }

  private func fullPath(_ relative: String, record: FPDomainRecord) throws -> String {
    let root = try FPIdentifierCodec.validatedPath(
      record.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    )
    let child = try FPIdentifierCodec.validatedPath(relative)
    if root.isEmpty { return child }
    return child.isEmpty ? root : "\(root)/\(child)"
  }

  private func duplicateKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private func contentFingerprint(_ object: [String: Any]) -> String {
    return [
      String((object["Size"] as? NSNumber)?.int64Value ?? -1),
      object["ModTime"] as? String ?? "",
      String(object["IsDir"] as? Bool ?? false),
      object["ID"] as? String ?? "",
    ].joined(separator: "|")
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value, value != "2000-01-01T00:00:00Z" else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private func snapshotURL() throws -> URL {
    let key = Data("\(domain.identifier.rawValue)|\(containerIdentifier.rawValue)".utf8)
    return try FPSharedStore.snapshotsDirectory()
      .appendingPathComponent(shortDigest(key, full: true) + ".json")
  }

  private func saveSnapshot(_ items: [NafiFileProviderItem], generation: UUID) throws {
    let values = items.map {
      StoredItem(
        filename: $0.filename,
        path: $0.path,
        isDirectory: $0.isDirectory,
        size: $0.documentSize?.int64Value,
        modification: $0.contentModificationDate,
        identityToken: $0.identityToken,
        contentFingerprint: $0.contentFingerprint,
        readOnly: !$0.capabilities.contains(.allowsWriting),
        unavailable: $0.capabilities.isEmpty
      )
    }
    let snapshot = StoredSnapshot(generation: generation, savedAt: Date(), items: values)
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 64 * 1024 * 1024 else { throw FPBridgeError.malformedResponse }
    let url = try snapshotURL()
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func loadSnapshot() throws -> StoredSnapshot {
    let url = try snapshotURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NSFileProviderError(.syncAnchorExpired)
    }
    do {
      let data = try FPSharedStore.regularFileData(at: url, maximumBytes: 64 * 1024 * 1024)
      guard !data.isEmpty else { throw FPBridgeError.malformedResponse }
      let snapshot = try JSONDecoder().decode(StoredSnapshot.self, from: data)
      let savedAt = snapshot.savedAt.timeIntervalSinceReferenceDate
      let now = Date().timeIntervalSinceReferenceDate
      guard snapshot.items.count <= 250_000, savedAt.isFinite,
        savedAt > now - 7 * 24 * 60 * 60, savedAt <= now + 24 * 60 * 60
      else { throw FPBridgeError.malformedResponse }
      return snapshot
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw NSFileProviderError(.syncAnchorExpired)
    }
  }

  private func restore(_ item: StoredItem) throws -> NafiFileProviderItem {
    try NafiFileProviderItem(
      path: item.path,
      name: item.filename,
      isDirectory: item.isDirectory,
      size: item.size,
      modTime: item.modification,
      readOnly: item.readOnly,
      unavailable: item.unavailable,
      identityToken: item.identityToken,
      contentFingerprint: item.contentFingerprint
    )
  }

  private func encodePage(_ token: PageToken) throws -> NSFileProviderPage {
    let data = try JSONEncoder().encode(token)
    guard data.count <= maximumPageTokenBytes else { throw NSFileProviderError(.pageExpired) }
    return NSFileProviderPage(data)
  }

  private func decodePage(_ page: NSFileProviderPage) throws -> PageToken {
    guard !page.rawValue.isEmpty, page.rawValue.count <= maximumPageTokenBytes else {
      throw NSFileProviderError(.pageExpired)
    }
    do { return try JSONDecoder().decode(PageToken.self, from: page.rawValue) }
    catch { throw NSFileProviderError(.pageExpired) }
  }

  private func sameVersion(
    _ lhs: NSFileProviderItemVersion,
    _ rhs: NSFileProviderItemVersion
  ) -> Bool {
    lhs.contentVersion == rhs.contentVersion && lhs.metadataVersion == rhs.metadataVersion
  }

  private func shortDigest(_ data: Data, full: Bool = false) -> String {
    let value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return full ? value : String(value.prefix(16))
  }

  private func register(_ task: Task<Void, Never>, token: UUID) {
    lock.lock()
    if invalidated {
      lock.unlock()
      task.cancel()
      return
    }
    if completedTaskTokens.remove(token) != nil {
      lock.unlock()
      return
    }
    tasks[token] = task
    lock.unlock()
  }

  private func removeTask(_ token: UUID) {
    lock.lock()
    if tasks.removeValue(forKey: token) == nil, !invalidated {
      completedTaskTokens.insert(token)
    }
    lock.unlock()
  }

  private func ensureActive() throws {
    try Task.checkCancellation()
    lock.lock()
    let stopped = invalidated
    lock.unlock()
    if stopped { throw CancellationError() }
  }

  private func setEnumerationCache(_ value: EnumerationCache?) {
    lock.lock()
    enumerationCache = value
    lock.unlock()
  }

  private func getEnumerationCache() -> EnumerationCache? {
    lock.lock()
    defer { lock.unlock() }
    return enumerationCache
  }

  private func map(_ error: Error) -> Error {
    if error is CancellationError { return CocoaError(.userCancelled) }
    return (error as? FPBridgeError)?.fileProviderError ?? error
  }
}

private extension Array {
  func chunked(maximum: Int) -> [[Element]] {
    guard maximum > 0, !isEmpty else { return isEmpty ? [] : [self] }
    return stride(from: 0, to: count, by: maximum).map {
      Array(self[$0..<Swift.min($0 + maximum, count)])
    }
  }
}
