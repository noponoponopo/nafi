import Foundation

enum RemoteOperationJournalKind: String, Codable, Sendable {
  case replaceCopy
  case replaceMove
  case batchRename
}

enum RemoteOperationJournalPhase: String, Codable, Sendable {
  case prepared
  case backedUp
  case staged
  case committed
}

struct RemoteRenameJournalPlan: Codable, Hashable, Sendable {
  let original: URL
  let temporary: URL
  let destination: URL
}

struct RemoteOperationJournalRecord: Codable, Identifiable, Sendable {
  let id: UUID
  let kind: RemoteOperationJournalKind
  let profileID: UUID
  let configurationRevision: UUID
  let fs: String
  let source: URL?
  let staged: URL?
  let destination: URL?
  let backup: URL?
  let batchPlans: [RemoteRenameJournalPlan]
  var phase: RemoteOperationJournalPhase
  let createdAt: Date
  var updatedAt: Date
}

struct RemoteOperationJournalLoadResult: Sendable {
  let records: [RemoteOperationJournalRecord]
  let warnings: [String]
}

actor RemoteOperationJournal {
  static let shared = RemoteOperationJournal()

  private let directory: URL
  private let maximumRecords = 2_000
  private let maximumRecordBytes = 2 * 1_024 * 1_024

  init() {
    directory = AppStoragePaths.directory(named: "RemoteOperationJournal")
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path
    )
  }

  func save(_ record: RemoteOperationJournalRecord) throws {
    try validate(record)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 36 }
    guard files.count < maximumRecords || files.contains(recordURL(id: record.id)) else {
      throw CocoaError(.fileWriteOutOfSpace, userInfo: [
        NSLocalizedDescriptionKey: "未完了のリモート操作記録が多すぎます。復旧警告を確認してください。"
      ])
    }
    let data = try JSONEncoder().encode(record)
    guard data.count <= maximumRecordBytes else { throw CocoaError(.fileWriteOutOfSpace) }
    let destination = recordURL(id: record.id)
    try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path
    )
  }

  func remove(id: UUID) {
    try? FileManager.default.removeItem(at: recordURL(id: id))
  }

  func records() -> RemoteOperationJournalLoadResult {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      ).filter { $0.pathExtension == "json" }
    } catch {
      return RemoteOperationJournalLoadResult(
        records: [],
        warnings: ["リモート操作の復旧記録を読み込めませんでした。\n\(error.localizedDescription)"]
      )
    }
    guard files.count <= maximumRecords else {
      return RemoteOperationJournalLoadResult(
        records: [],
        warnings: ["未完了のリモート操作記録が上限（\(maximumRecords)件）を超えています。自動復旧を停止しました。"]
      )
    }

    var values: [RemoteOperationJournalRecord] = []
    var warnings: [String] = []
    for file in files {
      do {
        let data = try AppStoragePaths.readRegularFile(at: file, maximumBytes: maximumRecordBytes)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let record = try JSONDecoder().decode(RemoteOperationJournalRecord.self, from: data)
        guard file.deletingPathExtension().lastPathComponent == record.id.uuidString.lowercased() else {
          throw CocoaError(.fileReadCorruptFile)
        }
        try validate(record)
        values.append(record)
      } catch {
        let moved = quarantine(file)
        warnings.append(
          moved
            ? "破損したリモート操作記録を隔離しました: \(file.lastPathComponent)"
            : "破損したリモート操作記録を隔離できませんでした: \(file.lastPathComponent)"
        )
      }
    }
    cleanupQuarantine()
    return RemoteOperationJournalLoadResult(
      records: values.sorted { $0.createdAt < $1.createdAt },
      warnings: warnings
    )
  }

  private func validate(_ record: RemoteOperationJournalRecord) throws {
    guard record.createdAt.isFiniteDate,
      record.updatedAt.isFiniteDate,
      record.updatedAt >= record.createdAt.addingTimeInterval(-5),
      record.createdAt <= Date().addingTimeInterval(24 * 60 * 60),
      record.batchPlans.count <= 100_000,
      !record.fs.isEmpty, record.fs.utf8.count <= 64 * 1_024,
      !record.fs.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw CocoaError(.fileReadCorruptFile) }

    switch record.kind {
    case .replaceCopy:
      guard record.source == nil, record.staged != nil, record.destination != nil,
        record.backup != nil, record.batchPlans.isEmpty
      else { throw CocoaError(.fileReadCorruptFile) }
    case .replaceMove:
      guard record.source != nil, record.staged == nil, record.destination != nil,
        record.backup != nil, record.batchPlans.isEmpty
      else { throw CocoaError(.fileReadCorruptFile) }
    case .batchRename:
      guard record.source == nil, record.staged == nil, record.destination == nil,
        record.backup == nil, !record.batchPlans.isEmpty
      else { throw CocoaError(.fileReadCorruptFile) }
    }

    let urls = [record.source, record.staged, record.destination, record.backup].compactMap { $0 }
      + record.batchPlans.flatMap { [$0.original, $0.temporary, $0.destination] }
    guard !urls.isEmpty, urls.allSatisfy({ url in
      NafiURL.isRemote(url)
        && NafiURL.profileID(in: url) == record.profileID
        && NafiURL.remoteIdentity(in: url) == nil
        && url.absoluteString.utf8.count <= 128 * 1_024
        && NafiURL.remotePath(in: url).map({ $0 != "/" && !$0.isEmpty }) == true
    }) else { throw CocoaError(.fileReadCorruptFile) }

    if record.kind == .batchRename {
      let parents = record.batchPlans.flatMap { plan in
        [NafiURL.parent(of: plan.original), NafiURL.parent(of: plan.temporary), NafiURL.parent(of: plan.destination)]
      }
      guard let firstParent = parents.first,
        parents.allSatisfy({ NafiURL.sameLocation($0, firstParent) }),
        record.batchPlans.allSatisfy({ plan in
          (NafiURL.remotePath(in: plan.temporary).map(RemotePath.name) ?? "")
            .hasPrefix(".nafi-rename-")
        })
      else { throw CocoaError(.fileReadCorruptFile) }

      let originals = Set(record.batchPlans.map { NafiURL.normalized($0.original) })
      let temporaries = Set(record.batchPlans.map { NafiURL.normalized($0.temporary) })
      let destinations = Set(record.batchPlans.map { NafiURL.normalized($0.destination) })
      guard originals.count == record.batchPlans.count,
        temporaries.count == record.batchPlans.count,
        destinations.count == record.batchPlans.count,
        originals.isDisjoint(with: temporaries),
        temporaries.isDisjoint(with: destinations)
      else { throw CocoaError(.fileReadCorruptFile) }
    }
  }

  private func quarantine(_ source: URL) -> Bool {
    do {
      let invalidDirectory = directory.appendingPathComponent("Invalid", isDirectory: true)
      try FileManager.default.createDirectory(
        at: invalidDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let destination = invalidDirectory.appendingPathComponent(
        "\(source.deletingPathExtension().lastPathComponent).invalid-\(UUID().uuidString.lowercased()).json"
      )
      try FileManager.default.moveItem(at: source, to: destination)
      return true
    } catch {
      return false
    }
  }

  private func cleanupQuarantine() {
    let invalidDirectory = directory.appendingPathComponent("Invalid", isDirectory: true)
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    guard var files = try? FileManager.default.contentsOfDirectory(
      at: invalidDirectory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    files.sort {
      let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      return left > right
    }
    let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
    for (index, file) in files.enumerated() {
      let modified = (try? file.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
      if index >= 2_000 || modified < cutoff { try? FileManager.default.removeItem(at: file) }
    }
  }

  private func recordURL(id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
  }
}

private extension Date {
  var isFiniteDate: Bool {
    let value = timeIntervalSinceReferenceDate
    return value.isFinite && value > -10_000_000_000 && value < 100_000_000_000
  }
}
