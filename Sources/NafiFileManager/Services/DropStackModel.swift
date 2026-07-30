import Foundation

@MainActor
final class DropStackModel: ObservableObject {
  struct Entry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let originalURL: URL
    let bookmarkData: Data?
    let addedAt: Date

    init(url: URL) {
      id = UUID()
      originalURL = NafiURL.normalized(url)
      bookmarkData = url.isFileURL
        ? try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        : nil
      addedAt = Date()
    }

    func resolvedURL() -> URL {
      guard let bookmarkData else { return originalURL }
      var stale = false
      return (try? URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )) ?? originalURL
    }
  }

  @Published private(set) var entries: [Entry] = []
  @Published var errorMessage: String?

  private static let maximumEntryCount = 10_000
  private static let maximumPersistenceBytes = 16 * 1_024 * 1_024
  private static let maximumURLBytes = 16_384
  private static let maximumPathBytes = 8_192
  private static let maximumBookmarkBytes = 1 * 1_024 * 1_024

  private let persistenceURL = AppStoragePaths.file(named: "drop-stack.json")

  init() { load() }

  func add(_ urls: [URL]) {
    let previous = entries
    var locations = Set(entries.compactMap { NafiURL.locationKey($0.originalURL) })
    for url in urls.prefix(Self.maximumEntryCount) {
      let normalized = NafiURL.normalized(url)
      guard Self.isValidLocation(normalized), let key = NafiURL.locationKey(normalized),
        locations.insert(key).inserted
      else { continue }
      let entry = Entry(url: normalized)
      guard Self.isValid(entry) else { continue }
      entries.append(entry)
    }
    entries = Array(entries.suffix(Self.maximumEntryCount))
    if !persist() { entries = previous }
  }

  func remove(_ ids: Set<UUID>) {
    let previous = entries
    entries.removeAll { ids.contains($0.id) }
    if !persist() { entries = previous }
  }

  func clear() {
    let previous = entries
    entries.removeAll()
    if !persist() { entries = previous }
  }

  func enqueueTransfer(to destination: URL, move: Bool) {
    let urls = entries.map { $0.resolvedURL() }
    guard !urls.isEmpty else { return }
    Task {
      do {
        _ = try await TransferQueue.shared.enqueue(
          sources: urls,
          destination: destination,
          move: move,
          policy: .keepBoth
        )
        // Keep entries until the user removes them. Enqueueing is not completion:
        // a queued move can still fail or be retried after relaunch.
      } catch {
        await MainActor.run { self.errorMessage = error.localizedDescription }
      }
    }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: persistenceURL,
        maximumBytes: Self.maximumPersistenceBytes
      )
      let decoded = try JSONDecoder().decode([Entry].self, from: data)
      guard decoded.count <= Self.maximumEntryCount else { throw CocoaError(.fileReadCorruptFile) }
      var seenIDs = Set<UUID>()
      var seenLocations = Set<String>()
      let valid = decoded.filter {
        guard let location = NafiURL.locationKey($0.originalURL) else { return false }
        return Self.isValid($0) && seenIDs.insert($0.id).inserted
          && seenLocations.insert(location).inserted
      }
      entries = valid
      if valid.count != decoded.count {
        errorMessage = "不正または重複したDrop Stack項目を除外しました。"
        _ = persist()
      }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: persistenceURL)
      errorMessage = "Drop Stackの保存データを隔離しました。\n\(error.localizedDescription)"
    }
  }

  private static func isValidLocation(_ url: URL) -> Bool {
    let normalized = NafiURL.normalized(url)
    guard normalized.absoluteString.utf8.count <= maximumURLBytes,
      normalized.user == nil, normalized.password == nil
    else { return false }
    if normalized.isFileURL { return normalized.path.utf8.count <= maximumPathBytes }
    return NafiURL.isRemote(normalized) && NafiURL.profileID(in: normalized) != nil
      && (NafiURL.remotePath(in: normalized)?.utf8.count ?? Int.max) <= maximumPathBytes
  }

  private static func isValid(_ entry: Entry) -> Bool {
    isValidLocation(entry.originalURL)
      && (entry.bookmarkData?.count ?? 0) <= maximumBookmarkBytes
      && entry.addedAt.timeIntervalSinceReferenceDate.isFinite
      && entry.addedAt <= Date().addingTimeInterval(24 * 60 * 60)
  }

  @discardableResult
  private func persist() -> Bool {
    do {
      guard entries.count <= Self.maximumEntryCount else { throw CocoaError(.fileWriteOutOfSpace) }
      let data = try JSONEncoder().encode(entries)
      guard data.count <= Self.maximumPersistenceBytes else { throw CocoaError(.fileWriteOutOfSpace) }
      try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: persistenceURL.path
      )
      errorMessage = nil
      return true
    } catch {
      errorMessage = "Drop Stackを保存できません。\n\(error.localizedDescription)"
      return false
    }
  }
}
