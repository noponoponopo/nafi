import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import NafiFileManager

final class RcloneIntegrationTests: XCTestCase {
  func testOAuthTokenReplacementPreservesOtherSecrets() throws {
    let oldToken = #"{"access_token":"old","refresh_token":"old-refresh"}"#
    let newToken = #"{"access_token":"new","refresh_token":"new-refresh"}"#
    let existing = String(decoding: try JSONEncoder().encode([
      "client_secret": JSONValue.string("keep"),
      "token": JSONValue.string(oldToken),
    ]), as: UTF8.self)

    let updated = try RcloneConfiguration.replacingOAuthToken(newToken, in: existing)
    let values = try JSONDecoder().decode([String: JSONValue].self, from: Data(updated.utf8))

    XCTAssertEqual(values["client_secret"]?.stringValue, "keep")
    XCTAssertEqual(values["token"]?.stringValue, newToken)
  }

  func testOAuthTokenReplacementRejectsNonObjectTokens() {
    XCTAssertThrowsError(try RcloneConfiguration.replacingOAuthToken("not-json", in: "{}"))
    XCTAssertThrowsError(try RcloneConfiguration.replacingOAuthToken("[]", in: "{}"))
  }

  private let profileID = UUID(uuidString: "8BAEC51F-8383-4E0F-BEC5-D7535C15A1F5")!

  func testCombinedFSHandlesRemoteAndLocalRoots() {
    XCTAssertEqual(RclonePath.combinedFS("remote:", path: "/folder/file"), "remote:folder/file")
    XCTAssertEqual(RclonePath.combinedFS("remote:root", path: "child"), "remote:root/child")
    XCTAssertEqual(RclonePath.combinedFS("/", path: "/Users/example"), "/Users/example")
    XCTAssertEqual(RclonePath.combinedFS("remote:", path: "/"), "remote:")
  }

  func testReadOnlyBoxDownloadFilterTreatsFileNameLiterally() {
    XCTAssertEqual(
      RcloneRemoteSession.exactFileFilter(named: "report [final]*.pdf"),
      .object(["IncludeRule": .array([.string(#"/report \[final]\*.pdf"#)])])
    )
  }

  func testLiveReadOnlyBoxFileDownloadWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let secret = environment["NAFI_LIVE_BOX_SECRET"],
      let remotePath = environment["NAFI_LIVE_BOX_FILE"]
    else {
      throw XCTSkip("Set NAFI_LIVE_BOX_SECRET and NAFI_LIVE_BOX_FILE to run the live Box test.")
    }

    let profile = ServerProfile(
      name: "Live read-only Box test",
      kind: .rclone,
      host: "",
      port: 1,
      path: "",
      username: "",
      useTLS: true,
      autoConnect: false,
      localMountPath: "",
      rcloneBackend: "box"
    )
    let session = try await RcloneRemoteSession.connect(
      profile: profile,
      secrets: RcloneProfileSecrets(password: secret, keyPassphrase: "", sessionToken: "")
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-live-box-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent(RemotePath.name(of: remotePath))
    try await session.downloadItem(at: remotePath, to: destination)
    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
    XCTAssertGreaterThan(size ?? 0, 0)
    await session.close()
  }

  func testSFTPFsPreservesServerRootSemantics() {
    let profile = ServerProfile(
      id: profileID,
      name: "SFTP",
      kind: .sftp,
      host: "example.com",
      port: 22,
      path: "/srv/data",
      username: "user",
      useTLS: true,
      autoConnect: false,
      localMountPath: ""
    )
    XCTAssertTrue(RcloneConfiguration.fs(for: profile).hasSuffix(":/"))
    XCTAssertEqual(
      RclonePath.combinedFS(RcloneConfiguration.fs(for: profile), path: "srv/data"),
      RcloneConfiguration.remoteName(for: profileID) + ":/srv/data"
    )
  }

  func testSFTPConfigurationRestrictsNegotiationToTrustedHostKeyAlgorithms() throws {
    let profile = ServerProfile(
      id: profileID,
      name: "SFTP",
      kind: .sftp,
      host: "example.com",
      port: 22,
      path: "",
      username: "user",
      useTLS: true,
      autoConnect: false,
      localMountPath: ""
    )
    let secrets = RcloneProfileSecrets(password: "password", keyPassphrase: "", sessionToken: "")

    let parameters = try RcloneConfiguration.parameters(
      for: profile,
      secrets: secrets,
      sftpHostKeyAlgorithms: ["ssh-ed25519", "ssh-rsa"]
    )

    XCTAssertEqual(parameters["host_key_algorithms"]?.stringValue, "ssh-ed25519 ssh-rsa")
  }

  func testOAuthPortProbeDetectsAnOccupiedCallbackPort() throws {
    #if canImport(Darwin)
    XCTAssertTrue(RcloneRuntime.canBindOAuthPort())
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(53_682).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(result, 0)
    XCTAssertFalse(RcloneRuntime.canBindOAuthPort())
    #endif
  }

  func testProviderConfigurationAutomaticallyAcceptsDefaultsButNotRequiredChoices() throws {
    let decoder = JSONDecoder()
    let defaultQuestion = try decoder.decode(
      RcloneConfigResponse.self,
      from: Data(#"{"State":"teamdrive","Result":"","Error":"","Option":{"Name":"teamdrive","Help":"","Default":false,"DefaultStr":"false","Examples":[],"Hide":0,"Required":false,"IsPassword":false,"Advanced":false,"Exclusive":false,"Sensitive":false,"Type":"bool"}}"#.utf8)
    )
    XCTAssertEqual(
      RcloneProviderEditor.automaticAnswer(for: try XCTUnwrap(defaultQuestion.option)),
      "false"
    )

    let requiredQuestion = try decoder.decode(
      RcloneConfigResponse.self,
      from: Data(#"{"State":"drive","Result":"","Error":"","Option":{"Name":"drive_id","Help":"","Default":"","DefaultStr":"","Examples":[],"Hide":0,"Required":true,"IsPassword":false,"Advanced":false,"Exclusive":false,"Sensitive":false,"Type":"string"}}"#.utf8)
    )
    XCTAssertNil(
      RcloneProviderEditor.automaticAnswer(for: try XCTUnwrap(requiredQuestion.option))
    )

    let sharedDriveQuestion = try decoder.decode(
      RcloneConfigResponse.self,
      from: Data(#"{"State":"teamdrive_ok","Result":"","Error":"","Option":{"Name":"config_change_team_drive","Help":"","Default":false,"DefaultStr":"false","Examples":[],"Hide":0,"Required":false,"IsPassword":false,"Advanced":false,"Exclusive":false,"Sensitive":false,"Type":"bool"}}"#.utf8)
    )
    let sharedDriveOption = try XCTUnwrap(sharedDriveQuestion.option)
    XCTAssertEqual(
      RcloneProviderEditor.automaticAnswer(for: sharedDriveOption, useSharedDrive: false),
      "false"
    )
    XCTAssertEqual(
      RcloneProviderEditor.automaticAnswer(for: sharedDriveOption, useSharedDrive: true),
      "true"
    )
  }

  func testRcloneListEntryToleratesMissingOptionalAttributes() throws {
    let data = Data(#"""
    {
      "name": "Legacy",
      "source": "file:///Users/example/Source",
      "destination": "file:///Users/example/Destination"
    }
    """#.utf8)
    let profile = try JSONDecoder().decode(SavedSyncProfile.self, from: data)
    XCTAssertEqual(profile.mode, .update)
    XCTAssertEqual(profile.trigger, .manual)
    XCTAssertEqual(profile.maxDeleteCount, 100)
    XCTAssertEqual(profile.maxDeleteRatio, 0.20, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(profile.stableForSeconds, 1)
    XCTAssertEqual(profile.maxConcurrentIncrementalTransfers, 3)
  }

  @MainActor
  func testExternalCommandURLParsing() {
    XCTAssertEqual(NafiExternalCommand(url: URL(string: "nafi://quick-open")!), .quickOpen)
    XCTAssertEqual(
      NafiExternalCommand(url: URL(string: "nafi://sync?profile=Daily%20Backup")!),
      .sync(profile: "Daily Backup")
    )
    XCTAssertEqual(NafiExternalCommand(url: URL(string: "nafi://drop-stack")!), .dropStack)
    XCTAssertNil(NafiExternalCommand(url: URL(string: "https://example.com")!))
  }
}
