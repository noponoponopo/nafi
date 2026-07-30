import Darwin
import FileProvider
import Foundation

struct FPRuntimeDescriptor: Codable {
  let baseURL: URL
  let username: String
  let password: String
  let generation: UUID
  let processIdentifier: Int32
  let expiresAt: Date
}

struct FPDomainRecord: Codable {
  let id: UUID
  let displayName: String
  let fs: String
  let rootPath: String
  let updatedAt: Date
  let configurationRevision: UUID?
}

enum FPRemoteTransactionPhase: String, Codable {
  case uploading
  case backingUp
  case committing
  case committed
  case directoryCopying
  case directoryVerified
  case directoryCommitting
  case directoryCommitted
}

struct FPRemoteTransactionRecord: Codable {
  let id: UUID
  let domainID: UUID
  let fs: String
  let configurationRevision: UUID?
  let source: String?
  let destination: String
  let temporary: String?
  let backup: String?
  var phase: FPRemoteTransactionPhase
  var expectedFingerprint: String? = nil
  var originalFingerprint: String? = nil
  let createdAt: Date
  var updatedAt: Date
}

enum FPSharedStore {
  static var root: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("nafi", isDirectory: true)
  }

  static func descriptor() throws -> FPRuntimeDescriptor {
    guard let url = root?.appendingPathComponent("rclone-runtime.json") else {
      throw FPBridgeError.runtimeUnavailable
    }
    let data = try regularFileData(at: url, maximumBytes: 64 * 1024)
    let value = try JSONDecoder().decode(FPRuntimeDescriptor.self, from: data)
    let processAlive = kill(value.processIdentifier, 0) == 0 || errno == EPERM
    let now = Date()
    guard value.expiresAt > now,
      value.expiresAt <= now.addingTimeInterval(3 * 60 * 60),
      value.processIdentifier > 1, processAlive,
      value.baseURL.scheme == "http", value.baseURL.host == "127.0.0.1",
      value.baseURL.user == nil, value.baseURL.password == nil,
      value.baseURL.path.isEmpty || value.baseURL.path == "/",
      value.baseURL.query == nil, value.baseURL.fragment == nil,
      value.baseURL.port.map({ (1...65535).contains($0) }) == true,
      !value.username.isEmpty, value.username.utf8.count <= 1_024,
      !value.password.isEmpty, value.password.utf8.count <= 16 * 1_024
    else {
      throw FPBridgeError.runtimeUnavailable
    }
    return value
  }

  static func domainRecord(for domain: NSFileProviderDomain) throws -> FPDomainRecord {
    guard let root else { throw FPBridgeError.domainUnavailable }
    let data = try regularFileData(
      at: root.appendingPathComponent("file-provider-domains.json"),
      maximumBytes: 4 * 1024 * 1024
    )
    let records = try JSONDecoder().decode([FPDomainRecord].self, from: data)
    guard records.count <= 10_000 else { throw FPBridgeError.malformedResponse }
    let raw = domain.identifier.rawValue
    guard let id = UUID(uuidString: raw.components(separatedBy: ".").last ?? ""),
      let record = records.first(where: { $0.id == id })
    else { throw FPBridgeError.domainUnavailable }
    return record
  }

  static func transferDirectory() throws -> URL {
    guard let root else { throw FPBridgeError.runtimeUnavailable }
    let url = root.appendingPathComponent("FileProviderTransfers", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    cleanupOldTransfers(in: url)
    return url
  }

  private static func cleanupOldTransfers(in directory: URL) {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
    guard let values = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for value in values {
      guard let resources = try? value.resourceValues(forKeys: keys),
        let modified = resources.contentModificationDate, modified < cutoff
      else { continue }
      try? FileManager.default.removeItem(at: value)
    }
  }

  static func snapshotsDirectory() throws -> URL {
    guard let root else { throw FPBridgeError.runtimeUnavailable }
    let url = root.appendingPathComponent("FileProviderSnapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    cleanupSnapshots(in: url)
    return url
  }

  static func saveTransaction(_ record: FPRemoteTransactionRecord) throws {
    try validateTransaction(record)
    let directory = try transactionsDirectory()
    let existing = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    let destination = directory.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
    guard existing.count < 10_000 || existing.contains(destination) else {
      throw FPBridgeError.malformedResponse
    }
    let data = try JSONEncoder().encode(record)
    guard data.count <= 64 * 1_024 else { throw FPBridgeError.malformedResponse }
    try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  static func removeTransaction(id: UUID) {
    guard let directory = try? transactionsDirectory() else { return }
    try? FileManager.default.removeItem(
      at: directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    )
  }

  static func transactions(domainID: UUID) throws -> [FPRemoteTransactionRecord] {
    let directory = try transactionsDirectory()
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    guard urls.count <= 10_000 else { throw FPBridgeError.malformedResponse }
    var records: [FPRemoteTransactionRecord] = []
    var quarantinedCorruptRecord = false
    for url in urls {
      do {
        let data = try regularFileData(at: url, maximumBytes: 64 * 1_024)
        let value = try JSONDecoder().decode(FPRemoteTransactionRecord.self, from: data)
        guard url.deletingPathExtension().lastPathComponent == value.id.uuidString.lowercased() else {
          throw FPBridgeError.malformedResponse
        }
        try validateTransaction(value)
        if value.domainID == domainID { records.append(value) }
      } catch {
        quarantinedCorruptRecord = true
        try? quarantineTransaction(url)
      }
    }
    // Never continue recovery in the same pass after silently skipping an
    // unreadable write-ahead record. The record is now outside the scan path,
    // so a subsequent retry can safely continue with the remaining records.
    if quarantinedCorruptRecord { throw FPBridgeError.malformedResponse }
    return records.sorted { $0.createdAt < $1.createdAt }
  }

  private static func quarantineTransaction(_ source: URL) throws {
    let directory = try transactionsDirectory().appendingPathComponent("Invalid", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let stem = source.deletingPathExtension().lastPathComponent
    let destination = directory.appendingPathComponent(
      "\(stem).invalid-\(UUID().uuidString.lowercased()).json"
    )
    try FileManager.default.moveItem(at: source, to: destination)
    cleanupInvalidTransactions(in: directory)
  }

  private static func validateTransaction(_ record: FPRemoteTransactionRecord) throws {
    let created = record.createdAt.timeIntervalSinceReferenceDate
    let updated = record.updatedAt.timeIntervalSinceReferenceDate
    let now = Date().timeIntervalSinceReferenceDate
    guard created.isFinite, updated.isFinite,
      created > -10_000_000_000, created <= now + 24 * 60 * 60,
      updated > -10_000_000_000, updated <= now + 24 * 60 * 60,
      updated >= created - 5,
      record.fs.utf8.count > 0, record.fs.utf8.count <= 64 * 1_024,
      !record.fs.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      record.expectedFingerprint.map({ $0.utf8.count <= 64 * 1_024 }) ?? true,
      record.originalFingerprint.map({ $0.utf8.count <= 64 * 1_024 }) ?? true
    else { throw FPBridgeError.malformedResponse }

    let paths = [record.source, record.destination, record.temporary, record.backup].compactMap { $0 }
    for path in paths {
      guard !path.isEmpty, path.utf8.count <= 32 * 1_024,
        (try? FPIdentifierCodec.validatedPath(path)) == path
      else { throw FPBridgeError.malformedResponse }
    }

    switch record.phase {
    case .uploading, .backingUp, .committing, .committed:
      guard record.source == nil, let temporary = record.temporary, let backup = record.backup,
        Set([record.destination, temporary, backup]).count == 3
      else {
        throw FPBridgeError.malformedResponse
      }
    case .directoryCopying, .directoryVerified, .directoryCommitting, .directoryCommitted:
      guard let source = record.source, let temporary = record.temporary, record.backup == nil,
        Set([source, record.destination, temporary]).count == 3
      else {
        throw FPBridgeError.malformedResponse
      }
    }
  }

  private static func cleanupInvalidTransactions(in directory: URL) {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    guard var values = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    values.sort {
      let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      return left > right
    }
    let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
    for (index, value) in values.enumerated() {
      let modified = (try? value.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      if index >= 2_000 || modified < cutoff { try? FileManager.default.removeItem(at: value) }
    }
  }

  private static func transactionsDirectory() throws -> URL {
    guard let root else { throw FPBridgeError.runtimeUnavailable }
    let url = root.appendingPathComponent("FileProviderTransactions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  static func regularFileData(at url: URL, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else { throw FPBridgeError.malformedResponse }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    let values = try url.resourceValues(forKeys: keys)
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size >= 0, size <= maximumBytes
    else { throw FPBridgeError.malformedResponse }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count == size else { throw FPBridgeError.malformedResponse }
    return data
  }

  private static func cleanupSnapshots(in directory: URL) {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard var values = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    var retained: [(URL, Date, Int64)] = []
    for value in values {
      guard let resources = try? value.resourceValues(forKeys: keys) else { continue }
      let modified = resources.contentModificationDate ?? .distantPast
      if modified < cutoff {
        try? FileManager.default.removeItem(at: value)
      } else {
        retained.append((value, modified, Int64(resources.fileSize ?? 0)))
      }
    }
    // Keep snapshot storage bounded even if many folders are visited once.
    let maximumFiles = 5_000
    let maximumBytes: Int64 = 512 * 1_024 * 1_024
    retained.sort { $0.1 > $1.1 }
    var bytes: Int64 = 0
    for (index, item) in retained.enumerated() {
      bytes += max(0, item.2)
      if index >= maximumFiles || bytes > maximumBytes {
        try? FileManager.default.removeItem(at: item.0)
      }
    }
  }
}

enum FPBridgeError: LocalizedError {
  case runtimeUnavailable
  case domainUnavailable
  case malformedResponse
  case invalidName
  case collision
  case noSuchItem
  case versionMismatch
  case remote(String)

  var errorDescription: String? {
    switch self {
    case .runtimeUnavailable: "nafiのバックグラウンドサービスが利用できません。nafiを起動してください。"
    case .domainUnavailable: "このFile Provider接続の設定が見つかりません。"
    case .malformedResponse: "rcloneから不正な応答を受け取りました。"
    case .invalidName: "この名前はmacOSのFile Providerでは安全に扱えません。"
    case .collision: "同じ名前の項目が既に存在します。"
    case .noSuchItem: "項目が見つかりません。"
    case .versionMismatch: "項目は別の場所で変更されています。最新状態を読み込み直してください。"
    case .remote(let message): message
    }
  }

  var fileProviderError: Error {
    switch self {
    case .runtimeUnavailable: NSFileProviderError(.serverUnreachable)
    case .domainUnavailable: NSFileProviderError(.notAuthenticated)
    case .malformedResponse, .remote: NSFileProviderError(.serverUnreachable)
    case .invalidName, .collision: NSFileProviderError(.filenameCollision)
    case .noSuchItem: NSFileProviderError(.noSuchItem)
    case .versionMismatch: NSFileProviderError(.versionNoLongerAvailable)
    }
  }
  var isNotFound: Bool {
    switch self {
    case .noSuchItem: return true
    case .remote(let message):
      let lower = message.lowercased()
      return lower.contains("not found") || lower.contains("does not exist")
        || lower.contains("doesn't exist") || lower.contains("object not found")
    default: return false
    }
  }

}
