import FileProvider
import Foundation
import os
import UniformTypeIdentifiers


private struct FPRemoteState {
  let isDirectory: Bool
  let fingerprint: String
}

private let fpExtensionLogger = Logger(subsystem: "app.nafi.filemanager.fileprovider", category: "extension")

private actor FPTransactionRecoveryGate {
  static let shared = FPTransactionRecoveryGate()
  private var completedDomains = Set<UUID>()

  func begin(domainID: UUID) -> Bool {
    completedDomains.insert(domainID).inserted
  }

  func reset(domainID: UUID) { completedDomains.remove(domainID) }
}

final class NafiFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  private let domain: NSFileProviderDomain
  private let taskLock = NSLock()
  private var invalidated = false
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var completedTaskTokens = Set<UUID>()

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    super.init()
  }

  func invalidate() {
    taskLock.lock()
    invalidated = true
    let active = Array(tasks.values)
    tasks.removeAll()
    completedTaskTokens.removeAll()
    taskLock.unlock()
    active.forEach { $0.cancel() }
  }

  private func configured() throws -> (FPDomainRecord, FPRcloneBridge) {
    try ensureActive()
    // Finder may launch the extension before the containing app. Resolve both
    // records for each request so an earlier startup failure is never cached.
    let record = try FPSharedStore.domainRecord(for: domain)
    return (record, FPRcloneBridge(record: record))
  }

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let token = UUID()
    let task = Task {
      defer { removeTask(token) }
      do {
        try Task.checkCancellation()
        let (record, bridge) = try configured()
        if identifier == .rootContainer {
          progress.completedUnitCount = 1
          completionHandler(try NafiFileProviderItem.root(displayName: record.displayName), nil)
          return
        }
        let relative = try usableIdentifier(identifier).path
        if FPSharedStore.isMachinePseudoFilesystemPath(relative, record: record) {
          throw FPBridgeError.noSuchItem
        }
        guard var value = try await statIfExists(relative, record: record, bridge: bridge, strongVersion: false) else {
          throw FPBridgeError.noSuchItem
        }
        if value.isDirectory,
          let recorded = FPSharedStore.recordedChild(relative, domain: domain),
          !recorded.isDirectory
        {
          // operations/stat resolves symlinks server-side, so a symlink child of
          // an enumerated folder would be reclassified as a directory here and
          // invite endless descent through /proc/thread-self/root/… cycles. The
          // parent enumeration's listing is authoritative for classification.
          value = try NafiFileProviderItem(snapshot: recorded)
        }
        progress.completedUnitCount = 1
        completionHandler(value, nil)
      } catch {
        completionHandler(nil, map(error))
      }
    }
    register(task, token: token)
    progress.cancellationHandler = { task.cancel() }
    return progress
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    let token = UUID()
    let task = Task {
      defer { removeTask(token) }
      var transferRoot: URL?
      do {
        try Task.checkCancellation()
        let (record, bridge) = try configured()
        let relative = try usableIdentifier(itemIdentifier).path
        guard !relative.isEmpty,
          let current = try await statIfExists(relative, record: record, bridge: bridge, strongVersion: true)
        else { throw FPBridgeError.noSuchItem }
        if let requestedVersion, !sameVersion(requestedVersion, current.itemVersion) {
          throw FPBridgeError.versionMismatch
        }
        guard !current.isDirectory else { throw FPBridgeError.noSuchItem }

        let directory = try FPSharedStore.transferDirectory()
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        transferRoot = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(current.filename)
        try await downloadFile(
          relative,
          named: current.filename,
          to: directory,
          record: record,
          bridge: bridge
        )
        guard FileManager.default.fileExists(atPath: destination.path) else {
          throw FPBridgeError.malformedResponse
        }
        try Task.checkCancellation()

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        if let expected = current.documentSize?.int64Value,
          Int64(values.fileSize ?? -1) != expected
        {
          throw FPBridgeError.malformedResponse
        }
        guard let afterDownload = try await statIfExists(
          relative,
          record: record,
          bridge: bridge,
          strongVersion: true
        ), sameVersion(current.itemVersion, afterDownload.itemVersion),
          current.contentFingerprint == afterDownload.contentFingerprint
        else {
          throw FPBridgeError.versionMismatch
        }
        progress.completedUnitCount = 100
        completionHandler(destination, afterDownload, nil)
      } catch {
        fpExtensionLogger.error("fetchContents failed: \(error.localizedDescription, privacy: .public)")
        if let transferRoot { try? FileManager.default.removeItem(at: transferRoot) }
        completionHandler(nil, nil, map(error))
      }
    }
    register(task, token: token)
    progress.cancellationHandler = { task.cancel() }
    return progress
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem,
    fields: NSFileProviderItemFields,
    contents: URL?,
    options: NSFileProviderCreateItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    let token = UUID()
    let task = Task {
      defer { removeTask(token) }
      do {
        try Task.checkCancellation()
        let (record, bridge) = try configured()
        try await recoverTransactionsIfNeeded(record: record, bridge: bridge)
        let parent = try usableIdentifier(itemTemplate.parentItemIdentifier).path
        let relative = try FPIdentifierCodec.appending(itemTemplate.filename, to: parent)
        if let existing = try await statIfExists(
          relative,
          record: record,
          bridge: bridge,
          strongVersion: true
        ) {
          // File Provider can retry an import after the remote creation already
          // succeeded, notably with a nil contents URL. Treat that explicit retry
          // as idempotent; never discard new local contents onto an unrelated item.
          if options.contains(.mayAlreadyExist), contents == nil {
            progress.completedUnitCount = 100
            let appliedFields: NSFileProviderItemFields = [.filename, .parentItemIdentifier]
            completionHandler(existing, fields.subtracting(appliedFields), false, nil)
            return
          }
          throw FPBridgeError.collision
        }

        let isDirectory = itemTemplate.contentType?.conforms(to: .folder) == true
        if isDirectory {
          guard contents == nil else { throw FPBridgeError.malformedResponse }
          _ = try await bridge.call("operations/mkdir", [
            "fs": record.fs,
            "remote": try fullPath(relative, record: record),
          ])
        } else {
          guard let contents else { throw FPBridgeError.noSuchItem }
          try await uploadTransaction(
            contents,
            to: relative,
            expectedExistingFingerprint: nil,
            record: record,
            bridge: bridge
          )
        }
        guard let created = try await statIfExists(relative, record: record, bridge: bridge, strongVersion: true) else {
          throw FPBridgeError.malformedResponse
        }
        try Task.checkCancellation()
        progress.completedUnitCount = 100
        signal(parent: parent)
        var appliedFields: NSFileProviderItemFields = [.filename, .parentItemIdentifier]
        if !isDirectory, contents != nil { appliedFields.insert(.contents) }
        completionHandler(created, fields.subtracting(appliedFields), false, nil)
      } catch {
        completionHandler(nil, fields, false, map(error))
      }
    }
    register(task, token: token)
    progress.cancellationHandler = { task.cancel() }
    return progress
  }

  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    let token = UUID()
    let task = Task {
      defer { removeTask(token) }
      do {
        try Task.checkCancellation()
        let (record, bridge) = try configured()
        try await recoverTransactionsIfNeeded(record: record, bridge: bridge)
        let oldRelative = try usableIdentifier(item.itemIdentifier).path
        let oldParent = FPIdentifierCodec.parentPath(of: oldRelative)
        let oldName = (oldRelative as NSString).lastPathComponent
        let newParent = changedFields.contains(.parentItemIdentifier)
          ? try usableIdentifier(item.parentItemIdentifier).path
          : oldParent
        let newName = changedFields.contains(.filename) ? item.filename : oldName
        let newRelative = try FPIdentifierCodec.appending(newName, to: newParent)
        guard !oldRelative.isEmpty,
          let current = try await statIfExists(oldRelative, record: record, bridge: bridge, strongVersion: true)
        else { throw FPBridgeError.noSuchItem }
        guard sameVersion(version, current.itemVersion) else { throw FPBridgeError.versionMismatch }
        try await ensureMutationPathIsUnambiguous(oldRelative, record: record, bridge: bridge)

        var appliedFields: NSFileProviderItemFields = []
        if changedFields.contains(.filename) { appliedFields.insert(.filename) }
        if changedFields.contains(.parentItemIdentifier) {
          appliedFields.insert(.parentItemIdentifier)
        }
        let contentsToApply: URL?
        if changedFields.contains(.contents), !current.isDirectory, let newContents {
          contentsToApply = newContents
          appliedFields.insert(.contents)
        } else {
          guard newContents == nil else { throw FPBridgeError.malformedResponse }
          contentsToApply = nil
        }

        if oldRelative != newRelative,
          try await statIfExists(newRelative, record: record, bridge: bridge, strongVersion: false) != nil
        {
          throw FPBridgeError.collision
        }

        var activeRelative = oldRelative
        if current.isDirectory {
          if oldRelative != newRelative {
            try await moveDirectorySafely(
              from: oldRelative,
              to: newRelative,
              record: record,
              bridge: bridge
            )
            activeRelative = newRelative
          }
        } else if let contentsToApply {
          try await uploadTransaction(
            contentsToApply,
            to: newRelative,
            expectedExistingFingerprint: oldRelative == newRelative
              ? current.contentFingerprint
              : nil,
            record: record,
            bridge: bridge
          )
          if oldRelative != newRelative {
            try await ensureMutationPathIsUnambiguous(oldRelative, record: record, bridge: bridge)
            guard let sourceBeforeDelete = try await statIfExists(
              oldRelative,
              record: record,
              bridge: bridge,
              strongVersion: true
            ), sourceBeforeDelete.contentFingerprint == current.contentFingerprint else {
              // The newly uploaded item is already durable. Preserve both copies rather than
              // deleting a source that changed while the replacement upload was in flight.
              throw FPBridgeError.versionMismatch
            }
            do {
              _ = try await bridge.runJob("operations/deletefile", [
                "fs": record.fs,
                "remote": try fullPath(oldRelative, record: record),
              ])
            } catch {
              // The new version is already durable. Do not delete it on an
              // uncertain source-delete failure; reconciliation will expose both.
              throw error
            }
          }
          activeRelative = newRelative
        } else if oldRelative != newRelative {
          _ = try await bridge.runJob("operations/movefile", [
            "srcFs": record.fs,
            "srcRemote": try fullPath(oldRelative, record: record),
            "dstFs": record.fs,
            "dstRemote": try fullPath(newRelative, record: record),
          ])
          activeRelative = newRelative
        }

        guard let updated = try await statIfExists(activeRelative, record: record, bridge: bridge, strongVersion: true) else {
          throw FPBridgeError.malformedResponse
        }
        try Task.checkCancellation()
        progress.completedUnitCount = 100
        signal(parent: FPIdentifierCodec.parentPath(of: oldRelative))
        if FPIdentifierCodec.parentPath(of: activeRelative) != FPIdentifierCodec.parentPath(of: oldRelative) {
          signal(parent: FPIdentifierCodec.parentPath(of: activeRelative))
        }
        completionHandler(updated, changedFields.subtracting(appliedFields), false, nil)
      } catch {
        completionHandler(nil, changedFields, false, map(error))
      }
    }
    register(task, token: token)
    progress.cancellationHandler = { task.cancel() }
    return progress
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier,
    baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let token = UUID()
    let task = Task {
      defer { removeTask(token) }
      do {
        try Task.checkCancellation()
        let (record, bridge) = try configured()
        try await recoverTransactionsIfNeeded(record: record, bridge: bridge)
        let relative = try usableIdentifier(identifier).path
        guard !relative.isEmpty,
          let current = try await statIfExists(relative, record: record, bridge: bridge, strongVersion: true)
        else { throw FPBridgeError.noSuchItem }
        guard sameVersion(version, current.itemVersion) else { throw FPBridgeError.versionMismatch }
        try await ensureMutationPathIsUnambiguous(relative, record: record, bridge: bridge)

        _ = try await bridge.runJob(current.isDirectory ? "operations/purge" : "operations/deletefile", [
          "fs": record.fs,
          "remote": try fullPath(relative, record: record),
        ])
        progress.completedUnitCount = 1
        signal(parent: FPIdentifierCodec.parentPath(of: relative))
        completionHandler(nil)
      } catch {
        completionHandler(map(error))
      }
    }
    register(task, token: token)
    progress.cancellationHandler = { task.cancel() }
    return progress
  }

  func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
    // The working set mirrors the system's materialized set locally. Signal only
    // when macOS says that set actually changed; no timer and no rclone call.
    guard let manager = NSFileProviderManager(for: domain) else {
      completionHandler()
      return
    }
    manager.signalEnumerator(for: .workingSet) { _ in completionHandler() }
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    do {
      if containerItemIdentifier != .rootContainer, containerItemIdentifier != .workingSet {
        let path: String
        do {
          path = try FPIdentifierCodec.path(for: containerItemIdentifier)
        } catch {
          // Same reasoning as usableIdentifier: an undecodable identifier must
          // prune, not surface as a retriable server failure.
          throw FPBridgeError.noSuchItem
        }
        let record = try FPSharedStore.domainRecord(for: domain)
        if FPSharedStore.isMachinePseudoFilesystemPath(path, record: record) {
          throw FPBridgeError.noSuchItem
        }
        if let recorded = FPSharedStore.recordedChild(path, domain: domain), !recorded.isDirectory {
          // The parent enumeration recorded this child as a non-directory (for
          // example a symlink). Refuse to enumerate it even if a stat-follow
          // point lookup once reported it as a folder.
          throw FPBridgeError.noSuchItem
        }
      }
      return try NafiFileProviderEnumerator(
        containerIdentifier: containerItemIdentifier,
        domain: domain
      )
    } catch {
      throw map(error)
    }
  }

  private func usableIdentifier(
    _ identifier: NSFileProviderItemIdentifier
  ) throws -> FPIdentifierCodec.Decoded {
    let decoded: FPIdentifierCodec.Decoded
    do {
      decoded = try FPIdentifierCodec.decode(identifier)
    } catch {
      // A structurally invalid identifier (for example a path that outgrew the
      // codec's caps during a pathological traversal) is cached daemon state,
      // not a server fault. Reporting it missing lets fileproviderd prune the
      // row; mapping it to serverUnreachable would retry forever.
      throw FPBridgeError.noSuchItem
    }
    guard decoded.identity == nil else {
      // Generic rclone path APIs cannot select one member of a duplicate-name
      // set reliably. Keep it visible but never mutate an arbitrary sibling.
      throw FPBridgeError.noSuchItem
    }
    return decoded
  }

  private func recoverTransactionsIfNeeded(
    record: FPDomainRecord,
    bridge: FPRcloneBridge
  ) async throws {
    let gate = FPTransactionRecoveryGate.shared
    guard await gate.begin(domainID: record.id) else { return }
    do {
      for transaction in try FPSharedStore.transactions(domainID: record.id) {
        guard transaction.fs == record.fs,
          transaction.configurationRevision != nil,
          transaction.configurationRevision == record.configurationRevision
        else {
          throw FPBridgeError.remote(
            "未完了のFile Provider操作がありますが、接続先設定が変更されているため自動復旧を停止しました。"
          )
        }
        try validate(transaction)
        try await recoverTransaction(transaction, bridge: bridge)
        FPSharedStore.removeTransaction(id: transaction.id)
      }
    } catch {
      await gate.reset(domainID: record.id)
      throw error
    }
  }

  private func recoverTransaction(
    _ transaction: FPRemoteTransactionRecord,
    bridge: FPRcloneBridge
  ) async throws {
    let destination = try await remoteState(
      fs: transaction.fs,
      remote: transaction.destination,
      bridge: bridge,
      strongVersion: true
    )
    let temporary: FPRemoteState?
    if let value = transaction.temporary {
      temporary = try await remoteState(
        fs: transaction.fs, remote: value, bridge: bridge, strongVersion: true
      )
    } else {
      temporary = nil
    }
    let backup: FPRemoteState?
    if let value = transaction.backup {
      backup = try await remoteState(
        fs: transaction.fs, remote: value, bridge: bridge, strongVersion: true
      )
    } else {
      backup = nil
    }

    switch transaction.phase {
    case .uploading, .backingUp, .committing, .committed:
      try await recoverFileTransaction(
        transaction,
        destination: destination,
        temporary: temporary,
        backup: backup,
        bridge: bridge
      )

    case .directoryCopying, .directoryVerified, .directoryCommitting, .directoryCommitted:
      try await recoverDirectoryTransaction(
        transaction,
        destination: destination,
        temporary: temporary,
        bridge: bridge
      )
    }
  }

  private func recoverFileTransaction(
    _ transaction: FPRemoteTransactionRecord,
    destination initialDestination: FPRemoteState?,
    temporary initialTemporary: FPRemoteState?,
    backup initialBackup: FPRemoteState?,
    bridge: FPRcloneBridge
  ) async throws {
    var destination = initialDestination
    var temporary = initialTemporary
    var backup = initialBackup

    // If the original item was moved aside but the new item never committed,
    // restore the original before cleaning any other exact transaction path.
    if destination == nil, let backupPath = transaction.backup, backup != nil {
      guard await noncancellableMove(
        bridge: bridge,
        fs: transaction.fs,
        source: backupPath,
        destination: transaction.destination
      ) else {
        throw FPBridgeError.remote("元ファイルのバックアップを復元できませんでした。")
      }
      destination = backup
      backup = nil
    }

    // A create may have crashed after a verified upload but before the rename.
    // It is safe to finish only when the exact staged content fingerprint is known.
    if destination == nil,
      transaction.originalFingerprint == nil,
      let temporaryPath = transaction.temporary,
      let staged = temporary,
      staged.fingerprint == transaction.expectedFingerprint,
      transaction.phase == .committing || transaction.phase == .committed
    {
      guard await noncancellableMove(
        bridge: bridge,
        fs: transaction.fs,
        source: temporaryPath,
        destination: transaction.destination
      ) else {
        throw FPBridgeError.remote("検証済み一時ファイルを確定先へ復元できませんでした。")
      }
      destination = staged
      temporary = nil
    }

    if let backupPath = transaction.backup, let backup {
      guard let destination else {
        throw FPBridgeError.remote("確定先がなく、バックアップだけが残っています。")
      }
      let destinationIsExpected = transaction.expectedFingerprint.map {
        destination.fingerprint == $0
      } ?? false
      let destinationIsOriginal = transaction.originalFingerprint.map {
        destination.fingerprint == $0
      } ?? false
      let backupIsOriginal = transaction.originalFingerprint.map {
        backup.fingerprint == $0
      } ?? false
      guard destinationIsExpected || (destinationIsOriginal && backupIsOriginal) else {
        throw FPBridgeError.remote(
          "確定先とバックアップの内容を安全に判別できないため、両方を保持しました。"
        )
      }
      guard await noncancellableDelete(
        bridge: bridge,
        fs: transaction.fs,
        remote: backupPath,
        directory: backup.isDirectory
      ) else {
        throw FPBridgeError.remote("保全バックアップを清掃できませんでした。")
      }
    }

    if let temporaryPath = transaction.temporary, let temporary {
      // Keep the only recoverable copy rather than deleting it. In all other
      // cases the source operation can safely be rolled back by exact cleanup.
      guard destination != nil || backup != nil || transaction.phase == .uploading else {
        throw FPBridgeError.remote("一時ファイルが唯一の回収可能なコピーのため保持しました。")
      }
      guard await noncancellableDelete(
        bridge: bridge,
        fs: transaction.fs,
        remote: temporaryPath,
        directory: temporary.isDirectory
      ) else {
        throw FPBridgeError.remote("一時ファイルを清掃できませんでした。")
      }
    }

    if transaction.phase == .committed,
      let expected = transaction.expectedFingerprint,
      let destination,
      destination.fingerprint != expected
    {
      throw FPBridgeError.remote("確定済みファイルの内容が記録と一致しません。")
    }
  }

  private func recoverDirectoryTransaction(
    _ transaction: FPRemoteTransactionRecord,
    destination: FPRemoteState?,
    temporary: FPRemoteState?,
    bridge: FPRcloneBridge
  ) async throws {
    let source: FPRemoteState?
    if let value = transaction.source {
      source = try await remoteState(
        fs: transaction.fs, remote: value, bridge: bridge, strongVersion: false
      )
    } else {
      source = nil
    }

    switch transaction.phase {
    case .directoryCopying, .directoryVerified:
      guard source != nil else {
        throw FPBridgeError.remote("元ディレクトリがなく、一時コピーを自動削除できません。")
      }
    case .directoryCommitting:
      guard source != nil || destination != nil else {
        throw FPBridgeError.remote("元・確定先の両方がなく、一時コピーを保持しました。")
      }
    case .directoryCommitted:
      guard destination != nil else {
        throw FPBridgeError.remote("確定済みディレクトリが見つかりません。")
      }
    default:
      throw FPBridgeError.malformedResponse
    }

    if let temporaryPath = transaction.temporary, let temporary {
      guard await noncancellableDelete(
        bridge: bridge,
        fs: transaction.fs,
        remote: temporaryPath,
        directory: temporary.isDirectory
      ) else {
        throw FPBridgeError.remote("ディレクトリ一時コピーを清掃できませんでした。")
      }
    }
    // When both source and destination remain, preserving both is deliberate:
    // the operation reports failure, but no user data is guessed away.
  }

  private func validate(_ transaction: FPRemoteTransactionRecord) throws {
    func validatePath(_ value: String) throws {
      guard !value.isEmpty, value.utf8.count <= 64 * 1_024,
        !value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n"),
        !value.contains("\r")
      else { throw FPBridgeError.malformedResponse }
      for part in value.split(separator: "/", omittingEmptySubsequences: false) {
        guard !part.isEmpty, part != ".", part != ".." else {
          throw FPBridgeError.malformedResponse
        }
      }
    }

    try validatePath(transaction.destination)
    if let source = transaction.source { try validatePath(source) }
    let destinationParent = (transaction.destination as NSString).deletingLastPathComponent
    let token = transaction.id.uuidString.lowercased()
    if let fingerprint = transaction.expectedFingerprint {
      guard fingerprint.utf8.count <= 64 * 1_024 else { throw FPBridgeError.malformedResponse }
    }
    if let fingerprint = transaction.originalFingerprint {
      guard fingerprint.utf8.count <= 64 * 1_024 else { throw FPBridgeError.malformedResponse }
    }
    switch transaction.phase {
    case .uploading, .backingUp, .committing, .committed:
      guard transaction.source == nil, transaction.temporary != nil, transaction.backup != nil else {
        throw FPBridgeError.malformedResponse
      }
    case .directoryCopying, .directoryVerified, .directoryCommitting, .directoryCommitted:
      guard transaction.source != nil, transaction.temporary != nil, transaction.backup == nil else {
        throw FPBridgeError.malformedResponse
      }
    }

    if let temporary = transaction.temporary {
      try validatePath(temporary)
      guard (temporary as NSString).deletingLastPathComponent == destinationParent else {
        throw FPBridgeError.malformedResponse
      }
      let expectedName: String
      switch transaction.phase {
      case .uploading, .backingUp, .committing, .committed:
        expectedName = ".nafi-upload-\(token)"
      case .directoryCopying, .directoryVerified, .directoryCommitting, .directoryCommitted:
        expectedName = ".nafi-directory-\(token)"
      }
      guard (temporary as NSString).lastPathComponent == expectedName else {
        throw FPBridgeError.malformedResponse
      }
    }

    if let backup = transaction.backup {
      try validatePath(backup)
      guard (backup as NSString).deletingLastPathComponent == destinationParent,
        (backup as NSString).lastPathComponent == ".nafi-backup-\(token)"
      else { throw FPBridgeError.malformedResponse }
    }
  }

  private func remoteExists(
    fs: String,
    remote: String,
    bridge: FPRcloneBridge
  ) async throws -> Bool {
    try await remoteState(fs: fs, remote: remote, bridge: bridge, strongVersion: false) != nil
  }

  private func remoteState(
    fs: String,
    remote: String,
    bridge: FPRcloneBridge,
    strongVersion: Bool
  ) async throws -> FPRemoteState? {
    guard let object = try await listedObject(
      fs: fs,
      remote: remote,
      bridge: bridge,
      strongVersion: strongVersion
    ) else { return nil }
    return FPRemoteState(
      isDirectory: object["IsDir"] as? Bool ?? false,
      fingerprint: contentFingerprint(object, includeHashes: true, includeBackendID: false)
    )
  }

  private func uploadTransaction(
    _ contents: URL,
    to relative: String,
    expectedExistingFingerprint: String?,
    record: FPDomainRecord,
    bridge: FPRcloneBridge
  ) async throws {
    let destinationParent = FPIdentifierCodec.parentPath(of: relative)
    let transactionID = UUID().uuidString.lowercased()
    let temporaryName = ".nafi-upload-\(transactionID)"
    let backupName = ".nafi-backup-\(transactionID)"
    let temporaryRelative = try FPIdentifierCodec.appending(temporaryName, to: destinationParent)
    let backupRelative = try FPIdentifierCodec.appending(backupName, to: destinationParent)
    let destinationRemote = try fullPath(relative, record: record)
    let temporaryRemote = try fullPath(temporaryRelative, record: record)
    let backupRemote = try fullPath(backupRelative, record: record)
    var journal = FPRemoteTransactionRecord(
      id: UUID(uuidString: transactionID) ?? UUID(),
      domainID: record.id,
      fs: record.fs,
      configurationRevision: record.configurationRevision,
      source: nil,
      destination: destinationRemote,
      temporary: temporaryRemote,
      backup: backupRemote,
      phase: .uploading,
      createdAt: Date(),
      updatedAt: Date()
    )

    guard try await statIfExists(temporaryRelative, record: record, bridge: bridge, strongVersion: false) == nil,
      try await statIfExists(backupRelative, record: record, bridge: bridge, strongVersion: false) == nil
    else {
      throw FPBridgeError.collision
    }

    let staging = try FPSharedStore.transferDirectory()
      .appendingPathComponent("upload-\(transactionID)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let localCopy = staging.appendingPathComponent(temporaryName)
    try coordinatedCopy(from: contents, to: localCopy)
    let localValues = try localCopy.resourceValues(forKeys: [.isDirectoryKey])
    guard localValues.isDirectory != true else { throw FPBridgeError.malformedResponse }
    try FPSharedStore.saveTransaction(journal)

    do {
      _ = try await bridge.runJob("operations/copyfile", [
        "srcFs": "/",
        "srcRemote": localRemote(localCopy),
        "dstFs": record.fs,
        "dstRemote": temporaryRemote,
      ])
      let remoteParent = try fullPath(destinationParent, record: record)
      let checked = try await bridge.runJob("operations/check", [
        "srcFs": staging.path,
        "dstFs": combinedFS(record.fs, path: remoteParent),
        "oneWay": true,
        "download": false,
        // The staging directory contains one transaction file. Keep rclone from
        // traversing/checking unrelated siblings in a very large destination.
        "_filter": ["IncludeRule": [exactFilterRule(temporaryName)]],
      ])
      guard checked["success"] as? Bool == true else {
        throw FPBridgeError.remote((checked["status"] as? String) ?? "アップロード検証に失敗しました。")
      }
      guard let uploadedState = try await remoteState(
        fs: record.fs,
        remote: temporaryRemote,
        bridge: bridge,
        strongVersion: true
      ) else { throw FPBridgeError.malformedResponse }
      journal.expectedFingerprint = uploadedState.fingerprint
      journal.updatedAt = Date()
      try FPSharedStore.saveTransaction(journal)
      try Task.checkCancellation()

      let existing = try await statIfExists(relative, record: record, bridge: bridge, strongVersion: true)
      journal.originalFingerprint = existing?.contentFingerprint
      journal.updatedAt = Date()
      try FPSharedStore.saveTransaction(journal)
      if let expectedExistingFingerprint {
        guard existing?.contentFingerprint == expectedExistingFingerprint else {
          throw FPBridgeError.versionMismatch
        }
        if existing != nil {
          try await ensureMutationPathIsUnambiguous(relative, record: record, bridge: bridge)
        }
      } else if existing != nil {
        throw FPBridgeError.collision
      }
      var backupCreated = false
      if existing != nil {
        journal.phase = .backingUp
        journal.updatedAt = Date()
        try FPSharedStore.saveTransaction(journal)
        _ = try await bridge.runJob("operations/movefile", [
          "srcFs": record.fs,
          "srcRemote": destinationRemote,
          "dstFs": record.fs,
          "dstRemote": backupRemote,
        ])
        backupCreated = true
      }

      do {
        journal.phase = .committing
        journal.updatedAt = Date()
        try FPSharedStore.saveTransaction(journal)
        _ = try await bridge.runJob("operations/movefile", [
          "srcFs": record.fs,
          "srcRemote": temporaryRemote,
          "dstFs": record.fs,
          "dstRemote": destinationRemote,
        ])
        journal.phase = .committed
        journal.updatedAt = Date()
        try FPSharedStore.saveTransaction(journal)
      } catch {
        if backupCreated {
          let restored = await noncancellableMove(
            bridge: bridge,
            fs: record.fs,
            source: backupRemote,
            destination: destinationRemote
          )
          guard restored else {
            throw FPBridgeError.remote(
              "置換に失敗し、元ファイルを自動復元できませんでした。バックアップは \(backupRelative) に保持されています。"
            )
          }
        }
        throw error
      }

      if backupCreated {
        let cleaned = await noncancellableDelete(
          bridge: bridge,
          fs: record.fs,
          remote: backupRemote,
          directory: false
        )
        if cleaned {
          FPSharedStore.removeTransaction(id: journal.id)
        } else {
          await FPTransactionRecoveryGate.shared.reset(domainID: record.id)
        }
      } else {
        FPSharedStore.removeTransaction(id: journal.id)
      }
    } catch {
      let originalError = error
      do {
        try await recoverTransaction(journal, bridge: bridge)
        FPSharedStore.removeTransaction(id: journal.id)
      } catch {
        await FPTransactionRecoveryGate.shared.reset(domainID: record.id)
        throw FPBridgeError.remote(
          "ファイル操作に失敗し、自動復旧も完了できませんでした。保全用項目は \(temporaryRelative) または \(backupRelative) に残されています。原因: \(originalError.localizedDescription) / 復旧: \(error.localizedDescription)"
        )
      }
      throw originalError
    }

  }

  private func moveDirectorySafely(
    from source: String,
    to destination: String,
    record: FPDomainRecord,
    bridge: FPRcloneBridge
  ) async throws {
    let sourceRemote = try fullPath(source, record: record)
    let destinationRemote = try fullPath(destination, record: record)
    let destinationParent = FPIdentifierCodec.parentPath(of: destination)
    let transactionID = UUID()
    let temporaryRelative = try FPIdentifierCodec.appending(
      ".nafi-directory-\(transactionID.uuidString.lowercased())",
      to: destinationParent
    )
    let temporaryRemote = try fullPath(temporaryRelative, record: record)
    let sourceFS = combinedFS(record.fs, path: sourceRemote)
    let temporaryFS = combinedFS(record.fs, path: temporaryRemote)
    let destinationFS = combinedFS(record.fs, path: destinationRemote)
    guard try await statIfExists(
      temporaryRelative,
      record: record,
      bridge: bridge,
      strongVersion: false
    ) == nil else { throw FPBridgeError.collision }
    var journal = FPRemoteTransactionRecord(
      id: transactionID,
      domainID: record.id,
      fs: record.fs,
      configurationRevision: record.configurationRevision,
      source: sourceRemote,
      destination: destinationRemote,
      temporary: temporaryRemote,
      backup: nil,
      phase: .directoryCopying,
      createdAt: Date(),
      updatedAt: Date()
    )
    try FPSharedStore.saveTransaction(journal)
    do {
      _ = try await bridge.runJob("sync/copy", [
        "srcFs": sourceFS,
        "dstFs": temporaryFS,
        "createEmptySrcDirs": true,
      ])
      let check = try await bridge.runJob("operations/check", [
        "srcFs": sourceFS,
        "dstFs": temporaryFS,
        "oneWay": false,
      ])
      guard check["success"] as? Bool == true else {
        throw FPBridgeError.remote((check["status"] as? String) ?? "ディレクトリ移動の検証に失敗しました。")
      }
      journal.phase = .directoryVerified
      journal.updatedAt = Date()
      try FPSharedStore.saveTransaction(journal)
    } catch {
      let cleaned = await noncancellableDelete(
        bridge: bridge,
        fs: record.fs,
        remote: temporaryRemote,
        directory: true
      )
      if cleaned {
        FPSharedStore.removeTransaction(id: journal.id)
      } else {
        await FPTransactionRecoveryGate.shared.reset(domainID: record.id)
      }
      throw error
    }
    do {
      guard try await remoteExists(fs: record.fs, remote: destinationRemote, bridge: bridge) == false else {
        throw FPBridgeError.collision
      }
      journal.phase = .directoryCommitting
      journal.updatedAt = Date()
      try FPSharedStore.saveTransaction(journal)
      _ = try await bridge.runJob("sync/move", [
        "srcFs": temporaryFS,
        "dstFs": destinationFS,
        "createEmptySrcDirs": true,
        "deleteEmptySrcDirs": true,
      ])
      let committedCheck = try await bridge.runJob("operations/check", [
        "srcFs": sourceFS,
        "dstFs": destinationFS,
        "oneWay": false,
      ])
      guard committedCheck["success"] as? Bool == true else {
        throw FPBridgeError.remote(
          (committedCheck["status"] as? String) ?? "ディレクトリ移動の確定検証に失敗しました。"
        )
      }
      journal.phase = .directoryCommitted
      journal.updatedAt = Date()
      try FPSharedStore.saveTransaction(journal)
      _ = try await bridge.runJob("operations/purge", [
        "fs": record.fs,
        "remote": sourceRemote,
      ])
      FPSharedStore.removeTransaction(id: journal.id)
    } catch {
      let originalError = error
      do {
        try await recoverTransaction(journal, bridge: bridge)
        FPSharedStore.removeTransaction(id: journal.id)
      } catch {
        await FPTransactionRecoveryGate.shared.reset(domainID: record.id)
        throw FPBridgeError.remote(
          "ディレクトリ操作に失敗し、自動復旧も完了できませんでした。元・確定先・一時先を保持しています。原因: \(originalError.localizedDescription) / 復旧: \(error.localizedDescription)"
        )
      }
      throw originalError
    }
  }

  private func ensureMutationPathIsUnambiguous(
    _ relative: String,
    record: FPDomainRecord,
    bridge: FPRcloneBridge
  ) async throws {
    guard try await bridge.allowsDuplicateFiles(
      fs: record.fs, configurationRevision: record.configurationRevision
    ) else { return }
    let path = try fullPath(relative, record: record)
    let parent = FPIdentifierCodec.parentPath(of: path)
    let name = (path as NSString).lastPathComponent
    let response = try await bridge.call("operations/list", [
      "fs": record.fs,
      "remote": parent,
      "opt": [
        "recurse": false,
        "showOrigIDs": true,
        "showHash": false,
        "noMimeType": true,
        "metadata": false,
      ],
      // rclone may still need a backend directory listing, but only duplicate-name
      // capable remotes pay this cost and the response is constrained to one name.
      "_filter": ["IncludeRule": [exactFilterRule(name)]],
    ], timeout: 120)
    guard let values = response["list"] as? [[String: Any]], values.count <= 16 else {
      throw FPBridgeError.malformedResponse
    }
    let matches = values.filter { $0["Name"] as? String == name }
    guard matches.count == 1 else {
      if matches.isEmpty { throw FPBridgeError.noSuchItem }
      throw FPBridgeError.collision
    }
  }

  private func statIfExists(
    _ relative: String,
    record: FPDomainRecord,
    bridge: FPRcloneBridge,
    strongVersion: Bool
  ) async throws -> NafiFileProviderItem? {
    guard let object = try await listedObject(
      fs: record.fs,
      remote: try fullPath(relative, record: record),
      bridge: bridge,
      strongVersion: strongVersion
    ) else { return nil }
    return try makeItem(object, relativePath: relative)
  }

  private func listedObject(
    fs: String,
    remote: String,
    bridge: FPRcloneBridge,
    strongVersion: Bool
  ) async throws -> [String: Any]? {
    let path = try FPIdentifierCodec.validatedPath(remote)
    guard !path.isEmpty else { throw FPBridgeError.malformedResponse }
    do {
      // A point lookup must stay a point lookup. Listing the parent directory here
      // made every save/delete/version check proportional to the number of siblings.
      // operations/stat asks the backend for exactly this path; showHash still requests
      // backend-provided hashes only and never enables download-based hashing.
      let response = try await bridge.call("operations/stat", [
        "fs": fs,
        "remote": path,
        "opt": [
          "showOrigIDs": true,
          "showHash": strongVersion,
          "noMimeType": true,
          "metadata": false,
        ],
      ], timeout: strongVersion ? 300 : 120)
      guard let item = response["item"] else { throw FPBridgeError.malformedResponse }
      if item is NSNull { return nil }
      guard let object = item as? [String: Any] else { throw FPBridgeError.malformedResponse }
      return object
    } catch let error as FPBridgeError where error.isNotFound {
      return nil
    }
  }

  private func downloadFile(
    _ relative: String,
    named name: String,
    to localDirectory: URL,
    record: FPDomainRecord,
    bridge: FPRcloneBridge
  ) async throws {
    let sourceRemote = try fullPath(relative, record: record)
    let destination = localDirectory.appendingPathComponent(name, isDirectory: false)
    do {
      // Single-file materialization should not enumerate the parent directory.
      // copyfile addresses exactly one object and is the cheapest path on normal
      // backends. A known Box read-only metadata failure retains the previous
      // exact-name filtered fallback below.
      _ = try await bridge.runJob("operations/copyfile", [
        "srcFs": record.fs,
        "srcRemote": sourceRemote,
        "dstFs": "/",
        "dstRemote": localRemote(destination),
      ])
      return
    } catch {
      guard isReadOnlyBoxMetadataFailure(error) else { throw error }
    }

    let parent = FPIdentifierCodec.parentPath(of: relative)
    let source = combinedFS(record.fs, path: try fullPath(parent, record: record))
    _ = try await bridge.runJob("sync/copy", [
      "srcFs": source,
      "dstFs": localDirectory.path,
      "createEmptySrcDirs": false,
      "_filter": ["IncludeRule": [exactFilterRule(name)]],
    ])
  }

  private func isReadOnlyBoxMetadataFailure(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("pre-upload check")
      && message.contains("access_denied_insufficient_permissions")
  }

  private func exactFilterRule(_ name: String) -> String {
    let reserved = Set("*?\\[{}")
    let escaped = name.reduce(into: "") { result, character in
      if reserved.contains(character) { result.append("\\") }
      result.append(character)
    }
    return "/\(escaped)"
  }

  private func makeItem(
    _ object: [String: Any],
    relativePath: String
  ) throws -> NafiFileProviderItem {
    let name = (object["Name"] as? String) ?? (relativePath as NSString).lastPathComponent
    let fingerprint = contentFingerprint(object, includeHashes: true, includeBackendID: false)
    let versionFingerprint = contentFingerprint(object, includeHashes: false, includeBackendID: true)
    return try NafiFileProviderItem(
      path: relativePath,
      name: name,
      isDirectory: object["IsDir"] as? Bool ?? false,
      size: (object["Size"] as? NSNumber)?.int64Value,
      modTime: parseDate(object["ModTime"] as? String),
      contentFingerprint: fingerprint,
      versionFingerprint: versionFingerprint
    )
  }

  private func contentFingerprint(
    _ object: [String: Any],
    includeHashes: Bool = true,
    includeBackendID: Bool = false
  ) -> String {
    var components = [
      String((object["Size"] as? NSNumber)?.int64Value ?? -1),
      object["ModTime"] as? String ?? "",
      String(object["IsDir"] as? Bool ?? false),
    ]
    if includeBackendID { components.append(object["ID"] as? String ?? "") }
    if includeHashes {
      components.append(canonicalHashes(object["Hashes"]))
    }
    return components.joined(separator: "|")
  }

  private func canonicalHashes(_ value: Any?) -> String {
    guard let hashes = value as? [String: Any] else { return "" }
    return hashes.compactMap { key, value -> String? in
      if let text = value as? String { return "\(key)=\(text)" }
      if let number = value as? NSNumber { return "\(key)=\(number.stringValue)" }
      return nil
    }.sorted().joined(separator: ",")
  }

  private func fullPath(_ relative: String, record: FPDomainRecord) throws -> String {
    let root = try FPIdentifierCodec.validatedPath(
      record.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    )
    let child = try FPIdentifierCodec.validatedPath(relative)
    if root.isEmpty { return child }
    return child.isEmpty ? root : "\(root)/\(child)"
  }

  private func combinedFS(_ fs: String, path: String) -> String {
    let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !clean.isEmpty else { return fs }
    if fs.hasSuffix(":") { return "\(fs)\(clean)" }
    return fs.hasSuffix("/") ? "\(fs)\(clean)" : "\(fs)/\(clean)"
  }

  private func localRemote(_ url: URL) -> String {
    url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func coordinatedCopy(from source: URL, to destination: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var operationError: Error?
    coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) {
      coordinatedURL in
      do { try FileManager.default.copyItem(at: coordinatedURL, to: destination) }
      catch { operationError = error }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
  }

  private func noncancellableMove(
    bridge: FPRcloneBridge,
    fs: String,
    source: String,
    destination: String
  ) async -> Bool {
    await Task.detached(priority: .utility) {
      do {
        _ = try await bridge.runJob("operations/movefile", [
          "srcFs": fs,
          "srcRemote": source,
          "dstFs": fs,
          "dstRemote": destination,
        ], timeout: 300)
        return true
      } catch {
        return false
      }
    }.value
  }

  private func noncancellableDelete(
    bridge: FPRcloneBridge,
    fs: String,
    remote: String,
    directory: Bool
  ) async -> Bool {
    await Task.detached(priority: .utility) {
      do {
        _ = try await bridge.runJob(directory ? "operations/purge" : "operations/deletefile", [
          "fs": fs,
          "remote": remote,
        ], timeout: 300)
        return true
      } catch {
        return false
      }
    }.value
  }

  private func sameVersion(
    _ lhs: NSFileProviderItemVersion,
    _ rhs: NSFileProviderItemVersion
  ) -> Bool {
    lhs.contentVersion == rhs.contentVersion && lhs.metadataVersion == rhs.metadataVersion
  }

  private func register(_ task: Task<Void, Never>, token: UUID) {
    taskLock.lock()
    if invalidated {
      taskLock.unlock()
      task.cancel()
      return
    }
    if completedTaskTokens.remove(token) != nil {
      taskLock.unlock()
      return
    }
    tasks[token] = task
    taskLock.unlock()
  }

  private func removeTask(_ token: UUID) {
    taskLock.lock()
    if tasks.removeValue(forKey: token) == nil, !invalidated {
      completedTaskTokens.insert(token)
    }
    taskLock.unlock()
  }

  private func ensureActive() throws {
    try Task.checkCancellation()
    taskLock.lock()
    let stopped = invalidated
    taskLock.unlock()
    if stopped { throw CancellationError() }
  }

  private func signal(parent: String) {
    #if compiler(>=6.2)
    if let record = try? FPSharedStore.domainRecord(for: domain) {
      Task { await FPRemoteSearchCatalogCache.shared.invalidate(domainID: record.id) }
    }
    #endif
    guard let manager = NSFileProviderManager(for: domain) else { return }
    let parentIdentifier = (try? FPIdentifierCodec.identifier(for: parent)) ?? .rootContainer
    manager.signalEnumerator(for: parentIdentifier) { _ in }
    manager.signalEnumerator(for: .workingSet) { _ in }
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value, value != "2000-01-01T00:00:00Z" else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private func map(_ error: Error) -> Error {
    if error is CancellationError { return CocoaError(.userCancelled) }
    return (error as? FPBridgeError)?.fileProviderError ?? error
  }
}

#if compiler(>=6.2)
private struct FPRemoteSearchEntry: Sendable {
  let path: String
  let name: String
  var displayName: String
  var identityToken: String?
  var isDuplicate: Bool
  let isDirectory: Bool
  let size: Int64?
  let modTime: Date?
  let backendID: String?
  let normalizedName: String

  var fingerprint: String {
    [String(size ?? -1), modTime.map { String($0.timeIntervalSinceReferenceDate) } ?? "", String(isDirectory)]
      .joined(separator: "|")
  }
}

private actor FPRemoteSearchCatalogCache {
  static let shared = FPRemoteSearchCatalogCache()

  private struct Cached {
    let loadedAt: Date
    let revision: UUID?
    let rootPath: String
    let entries: [FPRemoteSearchEntry]
  }

  private var values: [UUID: Cached] = [:]
  private var loading: [UUID: Task<[FPRemoteSearchEntry], Error>] = [:]
  private let lifetime: TimeInterval = 2 * 60

  func invalidate(domainID: UUID) {
    values[domainID] = nil
    loading[domainID]?.cancel()
    loading[domainID] = nil
  }

  private static func normalizeName(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )
  }

  private static func duplicateKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  func entries(record: FPDomainRecord, bridge: FPRcloneBridge) async throws -> [FPRemoteSearchEntry] {
    if let cached = values[record.id],
      cached.revision == record.configurationRevision,
      cached.rootPath == record.rootPath,
      Date().timeIntervalSince(cached.loadedAt) <= lifetime
    {
      return cached.entries
    }
    if let current = loading[record.id] { return try await current.value }

    let task = Task<[FPRemoteSearchEntry], Error> {
      let root = record.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if !root.isEmpty, FPSharedStore.isLinuxPseudoFilesystemPath(root) {
        throw FPBridgeError.remote("Linuxの擬似ファイルシステムは再帰検索の対象外です。")
      }
      var parameters: [String: Any] = [
        "fs": record.fs,
        "remote": root,
        "opt": [
          "recurse": true,
          "showHash": false,
          "noMimeType": true,
          "metadata": false,
        ],
      ]
      // When the domain root resolves to a machine root, Linux pseudo-
      // filesystems are pure noise in Finder search and enormous. Scoped to
      // that case so a real folder named "proc" in a user subtree stays
      // searchable. rclone's recursive walk never follows symlinks, so these
      // rules only skip real trees.
      if root.isEmpty {
        parameters["_filter"] = ["ExcludeRule": ["proc/**", "sys/**", "dev/**"]]
      }
      let response = try await bridge.call("operations/list", parameters, timeout: 300)
      guard let raw = response["list"] as? [[String: Any]], raw.count <= 250_000 else {
        throw FPBridgeError.malformedResponse
      }
      var result: [FPRemoteSearchEntry] = []
      result.reserveCapacity(raw.count)
      // Reuse formatters across the entire recursive response. Constructing two
      // ISO8601 formatters per remote entry is disproportionately expensive on a
      // six-figure catalog and provides no search-quality benefit.
      let fractionalDateFormatter = ISO8601DateFormatter()
      fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standardDateFormatter = ISO8601DateFormatter()
      for object in raw {
        try Task.checkCancellation()
        let rawPath = (object["Path"] as? String) ?? (object["Name"] as? String) ?? ""
        guard !rawPath.isEmpty,
          let path = try? FPIdentifierCodec.validatedPath(rawPath),
          let name = try? FPIdentifierCodec.validatedName((object["Name"] as? String) ?? (path as NSString).lastPathComponent)
        else { continue }
        let size = (object["Size"] as? NSNumber)?.int64Value
        let modTime: Date? = {
          guard let text = object["ModTime"] as? String, text != "2000-01-01T00:00:00Z" else { return nil }
          return fractionalDateFormatter.date(from: text) ?? standardDateFormatter.date(from: text)
        }()
        result.append(FPRemoteSearchEntry(
          path: path,
          name: name,
          displayName: name,
          identityToken: nil,
          isDuplicate: false,
          isDirectory: object["IsDir"] as? Bool ?? false,
          size: size,
          modTime: modTime,
          backendID: object["ID"] as? String,
          normalizedName: Self.normalizeName(name)
        ))
      }

      // Duplicate detection is catalog metadata, not query work. Compute it once
      // here so every Finder keystroke does not rebuild an O(N) grouping table.
      let groups = Dictionary(grouping: result.indices, by: { Self.duplicateKey(result[$0].path) })
      for indices in groups.values where indices.count > 1 {
        for (position, index) in indices.enumerated() {
          result[index].isDuplicate = true
          result[index].identityToken = result[index].backendID ?? "search:\(position + 1):\(result[index].path)"
          result[index].displayName = "\(result[index].name) — 重複 \(position + 1)"
        }
      }
      return result
    }
    loading[record.id] = task
    do {
      let result = try await task.value
      loading[record.id] = nil
      values[record.id] = Cached(
        loadedAt: Date(),
        revision: record.configurationRevision,
        rootPath: record.rootPath,
        entries: result
      )
      return result
    } catch {
      loading[record.id] = nil
      throw error
    }
  }
}

@available(macOS 26.0, *)
private final class NafiFileProviderSearchEnumerator: NSObject, NSFileProviderSearchEnumerator {
  private let domain: NSFileProviderDomain
  private let text: String
  private let requestedLimit: Int
  private let lock = NSLock()
  private var invalidated = false
  private var tasks: [UUID: Task<Void, Never>] = [:]

  init(domain: NSFileProviderDomain, text: String, desiredNumberOfResults: Int) {
    self.domain = domain
    self.text = text
    requestedLimit = max(1, min(desiredNumberOfResults > 0 ? desiredNumberOfResults : 500, 5_000))
  }

  func invalidate() {
    lock.lock()
    invalidated = true
    let active = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    active.forEach { $0.cancel() }
  }

  func enumerateSearchResults(
    for observer: any NSFileProviderSearchEnumerationObserver,
    startingAt page: NSFileProviderPage?
  ) {
    let token = UUID()
    let task = Task { [weak self] in
      defer { self?.removeTask(token) }
      guard let self else { return }
      do {
        try self.checkActive()
        let record = try FPSharedStore.domainRecord(for: domain)
        let entries = try await FPRemoteSearchCatalogCache.shared.entries(
          record: record,
          bridge: FPRcloneBridge(record: record)
        )
        try Task.checkCancellation()

        let terms = Self.terms(text)
        guard !terms.isEmpty else {
          observer.didEnumerate([])
          observer.finishEnumerating(upTo: nil)
          return
        }

        var ranked: [(Int, NafiFileProviderItem)] = []
        ranked.reserveCapacity(min(entries.count, requestedLimit * 4))

        for entry in entries {
          try Task.checkCancellation()
          let normalizedName = entry.normalizedName
          guard terms.allSatisfy(normalizedName.contains) else { continue }
          let item = try NafiFileProviderItem(
            path: entry.path,
            name: entry.displayName,
            isDirectory: entry.isDirectory,
            size: entry.size,
            modTime: entry.modTime,
            readOnly: entry.isDuplicate,
            unavailable: entry.isDuplicate,
            identityToken: entry.identityToken,
            contentFingerprint: entry.fingerprint
          )
          let rank: Int
          if normalizedName == terms.joined(separator: " ") { rank = 0 }
          else if terms.first.map(normalizedName.hasPrefix) == true { rank = 1 }
          else { rank = 2 }
          ranked.append((rank, item))
        }

        ranked.sort {
          if $0.0 != $1.0 { return $0.0 < $1.0 }
          return $0.1.filename.localizedStandardCompare($1.1.filename) == .orderedAscending
        }
        if ranked.count > requestedLimit { ranked.removeSubrange(requestedLimit...) }

        let start = Self.offset(from: page)
        guard start <= ranked.count else { throw FPBridgeError.malformedResponse }
        let observerLimit = observer.maximumNumberOfResultsPerPage
        guard observerLimit > 0 else {
          observer.finishEnumerating(upTo: nil)
          return
        }
        let pageSize = min(observerLimit, requestedLimit, 200)
        let end = min(ranked.count, start + pageSize)
        let results: [any NSFileProviderSearchResult] = ranked[start..<end].map { $0.1 }
        observer.didEnumerate(results)
        if end < ranked.count {
          observer.finishEnumerating(upTo: Self.page(for: end))
        } else {
          observer.finishEnumerating(upTo: nil)
        }
      } catch {
        observer.finishEnumeratingWithError((error as? FPBridgeError)?.fileProviderError ?? error)
      }
    }
    register(task, token: token)
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )
  }

  private static func terms(_ value: String) -> [String] {
    normalize(value).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
  }

  private static func offset(from page: NSFileProviderPage?) -> Int {
    guard let page else { return 0 }
    let data = page.rawValue
    guard data.count == MemoryLayout<UInt64>.size else { return 0 }
    return data.reduce(0) { ($0 << 8) | Int($1) }
  }

  private static func page(for offset: Int) -> NSFileProviderPage {
    var value = UInt64(offset).bigEndian
    return withUnsafeBytes(of: &value) { NSFileProviderPage(Data($0)) }
  }

  private func checkActive() throws {
    try Task.checkCancellation()
    lock.lock()
    let stopped = invalidated
    lock.unlock()
    if stopped { throw CancellationError() }
  }

  private func register(_ task: Task<Void, Never>, token: UUID) {
    lock.lock()
    if invalidated {
      lock.unlock()
      task.cancel()
      return
    }
    tasks[token] = task
    lock.unlock()
  }

  private func removeTask(_ token: UUID) {
    lock.lock()
    tasks[token] = nil
    lock.unlock()
  }
}

@available(macOS 26.0, *)
extension NafiFileProviderExtension: NSFileProviderSearching {
  func searchEnumerator(for request: NSFileProviderStringSearchRequest) -> any NSFileProviderSearchEnumerator {
    NafiFileProviderSearchEnumerator(
      domain: domain,
      text: request.query,
      desiredNumberOfResults: request.desiredNumberOfResults
    )
  }
}

#endif
