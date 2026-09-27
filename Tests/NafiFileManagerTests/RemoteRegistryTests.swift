import Foundation
import XCTest

@testable import NafiFileManager

final class RemoteRegistryTests: XCTestCase {
  func testConcurrentRequestsForOneProfileShareOneConnection() async throws {
    let registry = RemoteFileSystemRegistry()
    let profile = ServerProfile.blank
    let probe = ConnectionProbe()
    await registry.registerProfiles([profile])
    await registry.configureConnector { id in
      let generation = await registry.connectionGeneration(for: id)
      await probe.started()
      try await Task.sleep(nanoseconds: 30_000_000)
      await registry.register(
        profile: profile, session: RegistryTestSession(), generation: generation)
      await probe.finished()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<64 { group.addTask { _ = try await registry.session(for: profile.id) } }
      try await group.waitForAll()
    }
    let result = await probe.result()
    XCTAssertEqual(result.started, 1)
    XCTAssertEqual(result.maximum, 1)
  }

  func testDifferentProfilesConnectConcurrently() async throws {
    let registry = RemoteFileSystemRegistry()
    let profiles = (0..<8).map { _ in ServerProfile.blank }
    let probe = ConnectionProbe()
    await registry.registerProfiles(profiles)
    await registry.configureConnector { id in
      let generation = await registry.connectionGeneration(for: id)
      await probe.started()
      try await Task.sleep(nanoseconds: 30_000_000)
      guard let profile = profiles.first(where: { $0.id == id }) else {
        throw RemoteServerError.notConnected
      }
      await registry.register(
        profile: profile, session: RegistryTestSession(), generation: generation)
      await probe.finished()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for profile in profiles { group.addTask { _ = try await registry.session(for: profile.id) } }
      try await group.waitForAll()
    }
    let result = await probe.result()
    XCTAssertEqual(result.started, profiles.count)
    XCTAssertGreaterThan(result.maximum, 1)
  }

  func testLateRegistrationCannotResurrectRemovedProfile() async throws {
    let registry = RemoteFileSystemRegistry()
    let profile = ServerProfile.blank
    await registry.registerProfiles([profile])
    let generation = await registry.connectionGeneration(for: profile.id)
    await registry.unregister(profileID: profile.id)
    await registry.register(
      profile: profile, session: RegistryTestSession(), generation: generation)
    let removed = await registry.profile(for: profile.id)
    XCTAssertNil(removed)
    do {
      _ = try await registry.session(for: profile.id)
      XCTFail("Deleted profile was reconnected")
    } catch {}
  }

  func testLateRegistrationCannotReplaceRevisedProfile() async throws {
    let registry = RemoteFileSystemRegistry()
    let profile = ServerProfile.blank
    var revised = profile
    revised.configurationRevision = UUID()
    await registry.registerProfiles([profile])
    let generation = await registry.connectionGeneration(for: profile.id)
    await registry.update(profile: revised)
    await registry.register(
      profile: profile, session: RegistryTestSession(), generation: generation)
    do {
      _ = try await registry.session(for: profile.id)
      XCTFail("Stale configuration was accepted")
    } catch {}
    let current = await registry.profile(for: profile.id)
    XCTAssertEqual(current?.configurationRevision, revised.configurationRevision)
  }

  func testLateRegistrationCannotUndoDisconnectOfUnchangedProfile() async throws {
    let registry = RemoteFileSystemRegistry()
    let profile = ServerProfile.blank
    await registry.registerProfiles([profile])
    let generation = await registry.connectionGeneration(for: profile.id)
    await registry.disconnect(profileID: profile.id)
    let accepted = await registry.register(
      profile: profile, session: RegistryTestSession(), generation: generation)
    XCTAssertFalse(accepted)
    do {
      _ = try await registry.session(for: profile.id)
      XCTFail("Disconnected session was resurrected")
    } catch {}
  }

  func testFailedConnectionCanBeRetried() async throws {
    let registry = RemoteFileSystemRegistry()
    let profile = ServerProfile.blank
    await registry.registerProfiles([profile])
    await registry.configureConnector { _ in throw RemoteServerError.notConnected }
    do {
      _ = try await registry.session(for: profile.id)
      XCTFail("Expected failed connection")
    } catch {}
    await registry.configureConnector { id in
      let generation = await registry.connectionGeneration(for: id)
      await registry.register(
        profile: profile, session: RegistryTestSession(), generation: generation)
    }
    _ = try await registry.session(for: profile.id)
  }
}

private actor ConnectionProbe {
  private var count = 0
  private var active = 0
  private var maximum = 0
  func started() {
    count += 1
    active += 1
    maximum = max(maximum, active)
  }
  func finished() { active -= 1 }
  func result() -> (started: Int, maximum: Int) { (count, maximum) }
}

private actor RegistryTestSession: RemoteServerSession {
  func listDirectory(at path: String) async throws -> [RemoteFileItem] { [] }
  func statItem(at path: String) async throws -> RemoteFileItem? { nil }
  func recursiveCatalog(at path: String) async throws -> [RemoteFileItem] { [] }
  func invalidateSearchCache() async {}
  func createDirectory(at path: String) async throws {}
  func renameItem(at oldPath: String, to newPath: String) async throws {}
  func removeItem(at path: String, isDirectory: Bool) async throws {}
  func downloadItem(at remotePath: String, to localURL: URL) async throws {}
  func uploadItem(from localURL: URL, to remotePath: String) async throws {}
  func close() async {}
}
