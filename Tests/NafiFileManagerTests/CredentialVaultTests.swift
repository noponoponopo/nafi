import Foundation
import XCTest

@testable import NafiFileManager

final class CredentialVaultTests: XCTestCase {
  func testConcurrentReadersUnlockAndMigrateOnlyOnce() async throws {
    let id = UUID()
    let expected = ServerSecrets(
      password: "password", keyPassphrase: "phrase", sessionToken: "session")
    let backend = MemoryCredentialBackend(legacy: [id: expected])
    let vault = KeychainStore(backend: backend)
    try await withThrowingTaskGroup(of: ServerSecrets.self) { group in
      for _ in 0..<64 { group.addTask { try await vault.secrets(for: id) } }
      for try await result in group { XCTAssertEqual(result, expected) }
    }
    XCTAssertEqual(backend.snapshot.reads, 1)
    XCTAssertEqual(backend.snapshot.writes, 1)
    XCTAssertEqual(backend.snapshot.legacyReads, 1)
  }

  func testBatchPreparationUsesOneDurableWrite() async throws {
    let ids = (0..<20).map { _ in UUID() }
    let backend = MemoryCredentialBackend(
      legacy: Dictionary(
        uniqueKeysWithValues: ids.map {
          ($0, ServerSecrets(password: $0.uuidString))
        }))
    let vault = KeychainStore(backend: backend)
    try await vault.prepare(profileIDs: ids + ids)
    for id in ids {
      let value = try await vault.secrets(for: id)
      XCTAssertEqual(value.password, id.uuidString)
    }
    XCTAssertEqual(backend.snapshot.reads, 1)
    XCTAssertEqual(backend.snapshot.writes, 1)
    XCTAssertEqual(backend.snapshot.legacyReads, 20)
  }

  func testDeniedUnlockIsSharedUntilExplicitRetry() async throws {
    let backend = MemoryCredentialBackend()
    backend.setReadFailure(true)
    let vault = KeychainStore(backend: backend)
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            _ = try await vault.secrets(for: UUID())
            return false
          } catch { return true }
        }
      }
      for await failed in group { XCTAssertTrue(failed) }
    }
    XCTAssertEqual(backend.snapshot.reads, 1)
    backend.setReadFailure(false)
    await vault.retryUnlock()
    _ = try await vault.secrets(for: UUID())
    XCTAssertEqual(backend.snapshot.reads, 2)
  }

  func testFailedWriteDoesNotChangeCachedSecretsOrDeleteLegacy() async throws {
    let id = UUID()
    let backend = MemoryCredentialBackend(legacy: [id: ServerSecrets(password: "old")])
    let vault = KeychainStore(backend: backend)
    backend.setWriteFailure(true)
    do {
      _ = try await vault.secrets(for: id)
      XCTFail("Expected write failure")
    } catch {}
    XCTAssertTrue(backend.snapshot.removed.isEmpty)
    backend.setWriteFailure(false)
    let old = try await vault.secrets(for: id)
    backend.setWriteFailure(true)
    do {
      try await vault.save(ServerSecrets(password: "new"), for: id)
      XCTFail("Expected failure")
    } catch {}
    let unchanged = try await vault.secrets(for: id)
    XCTAssertEqual(unchanged, old)
  }

  func testCorruptVaultIsNeverOverwritten() async throws {
    let backend = MemoryCredentialBackend(data: Data("not a vault".utf8))
    let vault = KeychainStore(backend: backend)
    do {
      try await vault.save(ServerSecrets(password: "replacement"), for: UUID())
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(backend.snapshot.writes, 0)
    XCTAssertEqual(backend.snapshot.data, Data("not a vault".utf8))
  }

  func testInaccessibleLegacyCredentialRequiresExplicitReplacement() async throws {
    let id = UUID()
    let backend = MemoryCredentialBackend(legacy: [id: ServerSecrets(password: "old")])
    backend.denyLegacy(id)
    let vault = KeychainStore(backend: backend)
    for _ in 0..<3 {
      do {
        _ = try await vault.secrets(for: id)
        XCTFail("Expected denied read")
      } catch {}
    }
    XCTAssertEqual(backend.snapshot.legacyReads, 1)
    XCTAssertTrue(backend.snapshot.removed.isEmpty)
    let replacement = ServerSecrets(password: "reentered")
    try await vault.save(replacement, for: id)
    XCTAssertTrue(backend.snapshot.removed.isEmpty)
    await vault.finishMigration(for: id)
    let value = try await vault.secrets(for: id)
    XCTAssertEqual(value, replacement)
    XCTAssertTrue(backend.snapshot.removed.contains(id))
  }

  func testRemovalTombstonePreventsLegacyResurrectionAfterRestart() async throws {
    let id = UUID()
    let backend = MemoryCredentialBackend(legacy: [id: ServerSecrets(password: "old")])
    let vault = KeychainStore(backend: backend)
    _ = try await vault.removeSecrets(for: id)
    let restarted = KeychainStore(backend: backend)
    let value = try await restarted.secrets(for: id)
    XCTAssertEqual(value, ServerSecrets())
    XCTAssertEqual(backend.snapshot.legacyReads, 0)
  }

  func testRollbackRestoresOldValueAndRejectsConcurrentReplacement() async throws {
    let id = UUID()
    let vault = KeychainStore(backend: MemoryCredentialBackend())
    let old = ServerSecrets(password: "old")
    let edited = ServerSecrets(password: "edit")
    try await vault.save(old, for: id)
    let previous = try await vault.save(edited, for: id)
    try await vault.restore(previous, for: id, replacing: edited)
    let restored = try await vault.secrets(for: id)
    XCTAssertEqual(restored, old)
    try await vault.save(ServerSecrets(password: "newer"), for: id)
    do {
      try await vault.restore(previous, for: id, replacing: edited)
      XCTFail("Must not overwrite newer value")
    } catch {}
    let newer = try await vault.secrets(for: id)
    XCTAssertEqual(newer.password, "newer")
  }

  func testAtomicPasswordUpdatePreservesOtherSecrets() async throws {
    let id = UUID()
    let vault = KeychainStore(backend: MemoryCredentialBackend())
    try await vault.save(
      ServerSecrets(password: "old", keyPassphrase: "key", sessionToken: "session"), for: id)
    try await vault.updatePassword(for: id) { $0 + "-updated" }
    let value = try await vault.secrets(for: id)
    XCTAssertEqual(
      value, ServerSecrets(password: "old-updated", keyPassphrase: "key", sessionToken: "session"))
  }

  func testEditingUnrelatedOAuthOptionPreservesRefreshedToken() throws {
    let baseline = ServerSecrets(password: #"{"token":"old","client_secret":"old-secret"}"#)
    let latest = ServerSecrets(password: #"{"token":"refreshed","client_secret":"old-secret"}"#)
    let edited = ServerSecrets(password: #"{"token":"old","client_secret":"edited-secret"}"#)
    let merged = try edited.mergingUnchangedFields(
      from: latest, baseline: baseline, passwordIsJSON: true)
    let object = try JSONDecoder().decode([String: String].self, from: Data(merged.password.utf8))
    XCTAssertEqual(object["token"], "refreshed")
    XCTAssertEqual(object["client_secret"], "edited-secret")
  }

  func testExplicitReauthenticationWinsOverBackgroundRefresh() throws {
    let baseline = ServerSecrets(password: #"{"token":"old"}"#)
    let latest = ServerSecrets(password: #"{"token":"background"}"#)
    let edited = ServerSecrets(password: #"{"token":"reauthenticated"}"#)
    let merged = try edited.mergingUnchangedFields(
      from: latest, baseline: baseline, passwordIsJSON: true)
    let object = try JSONDecoder().decode([String: String].self, from: Data(merged.password.utf8))
    XCTAssertEqual(object["token"], "reauthenticated")
  }

  func testAtomicPrivateWriteReplacesContentsWithOwnerOnlyPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("vault")
    try AppStoragePaths.writePrivateAtomically(Data("before".utf8), to: file)
    try AppStoragePaths.writePrivateAtomically(Data("after".utf8), to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("after".utf8))
    let permissions =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["vault"])
  }

  func testAtomicWriteDoesNotFollowDestinationSymlink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original")
    let link = directory.appendingPathComponent("link")
    try Data("untouched".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    try AppStoragePaths.writePrivateAtomically(Data("replacement".utf8), to: link)
    XCTAssertEqual(try Data(contentsOf: original), Data("untouched".utf8))
    XCTAssertEqual(try Data(contentsOf: link), Data("replacement".utf8))
  }
}

private final class MemoryCredentialBackend: CredentialVaultBackend, @unchecked Sendable {
  struct Snapshot {
    var data: Data?
    var reads = 0
    var writes = 0
    var legacyReads = 0
    var removed = Set<UUID>()
  }
  enum Failure: Error { case denied, diskFull }
  private let lock = NSLock()
  private var state: Snapshot
  private var legacy: [UUID: ServerSecrets]
  private var readFailure = false
  private var writeFailure = false
  private var deniedLegacy = Set<UUID>()
  init(data: Data? = nil, legacy: [UUID: ServerSecrets] = [:]) {
    state = Snapshot(data: data)
    self.legacy = legacy
  }
  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return state
  }
  func setReadFailure(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    readFailure = value
  }
  func setWriteFailure(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    writeFailure = value
  }
  func denyLegacy(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    deniedLegacy.insert(id)
  }
  func read() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    state.reads += 1
    if readFailure { throw Failure.denied }
    return state.data
  }
  func write(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    if writeFailure { throw Failure.diskFull }
    state.writes += 1
    state.data = data
  }
  func legacySecrets(for profileID: UUID) throws -> ServerSecrets {
    lock.lock()
    defer { lock.unlock() }
    state.legacyReads += 1
    if deniedLegacy.contains(profileID) { throw Failure.denied }
    return legacy[profileID] ?? ServerSecrets()
  }
  func removeLegacySecrets(for profileID: UUID) {
    lock.lock()
    defer { lock.unlock() }
    state.removed.insert(profileID)
    legacy[profileID] = nil
  }
}
