import Foundation
import XCTest

@testable import NafiFileManager

final class RobustnessTests: XCTestCase {
  func testSSHHostValidationRejectsOptionAndURLInjection() {
    XCTAssertThrowsError(try SSHHostKeyService.validatedHost("-oProxyCommand=bad"))
    XCTAssertThrowsError(try SSHHostKeyService.validatedHost("sftp://example.com"))
    XCTAssertThrowsError(try SSHHostKeyService.validatedHost("example.com\nother"))
    XCTAssertEqual(try SSHHostKeyService.validatedHost("[2001:db8::1]"), "2001:db8::1")
  }

  func testSSHUsernameValidationRejectsAmbiguousDestinationSyntax() {
    XCTAssertThrowsError(try SSHHostKeyService.validatedUsername("name@example.com"))
    XCTAssertThrowsError(try SSHHostKeyService.validatedUsername("name\nother"))
    XCTAssertEqual(try SSHHostKeyService.validatedUsername("nafi-user"), "nafi-user")
  }

  func testUnknownSFTPHostKeyErrorIsEligibleForAutomaticRecovery() {
    XCTAssertTrue(
      RcloneRemoteSession.isUnknownHostKeyError(
        RcloneRuntimeError.invalidResponse(
          "NewFs: couldn't connect SSH: ssh: handshake failed: knownhosts: key is unknown"
        )
      )
    )
    XCTAssertFalse(
      RcloneRemoteSession.isUnknownHostKeyError(
        RcloneRuntimeError.invalidResponse("rclone connection failed")
      )
    )
  }

  func testOpenSSHKnownHostIdentityParsingIgnoresCommentsAndMalformedKeys() {
    let algorithm = "ssh-ed25519"
    var keyData = Data([0, 0, 0, UInt8(algorithm.utf8.count)])
    keyData.append(Data(algorithm.utf8))
    keyData.append(Data(repeating: 7, count: 32))
    let encodedKey = keyData.base64EncodedString()
    let output = Data("""
      # Host example.com found: line 1
      example.com \(algorithm) \(encodedKey)
      example.com ssh-ed25519 invalid-base64
      example.com ssh-dss \(encodedKey)
      """.utf8)

    let identities = SSHHostKeyService.knownHostIdentities(in: output)

    XCTAssertEqual(identities.count, 1)
    XCTAssertTrue(identities.first?.hasPrefix("ssh-ed25519 SHA256:") == true)
  }

  func testArchiveEntryValidationRejectsTraversalAndAbsolutePaths() {
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("../outside", directoryHint: false))
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("/absolute", directoryHint: false))
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("folder\\file", directoryHint: false))
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("C:/absolute", directoryHint: false))
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("line\nbreak", directoryHint: false))
    XCTAssertThrowsError(try ArchiveService.validateEntryPath("tab\tname", directoryHint: false))
  }

  func testArchiveEntryValidationNormalizesUnicodeForCollisionChecks() throws {
    let composed = try ArchiveService.validateEntryPath("café.txt", directoryHint: false)
    let decomposed = try ArchiveService.validateEntryPath("cafe\u{0301}.txt", directoryHint: false)
    XCTAssertEqual(composed.key, decomposed.key)
  }

  func testArchiveCollisionChecksDoNotEraseRealDiacritics() throws {
    let plain = try ArchiveService.validateEntryPath("cafe.txt", directoryHint: false)
    let accented = try ArchiveService.validateEntryPath("café.txt", directoryHint: false)
    XCTAssertNotEqual(plain.key, accented.key)
  }

  func testBatchRenamePreservesFileExtensionButNotDottedDirectorySuffix() throws {
    XCTAssertEqual(
      try UnifiedFileSystemService.generatedBatchName(
        pattern: "Photo ##",
        originalName: "IMG_0001.JPG",
        index: 3
      ),
      "Photo 03.JPG"
    )
    XCTAssertEqual(
      try UnifiedFileSystemService.generatedBatchName(
        pattern: "Folder ##",
        originalName: "archive.bundle",
        index: 3,
        preserveExtension: false
      ),
      "Folder 03"
    )
  }

  func testFileIntegrityDetectsContentChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-integrity-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let lhs = directory.appendingPathComponent("lhs.txt")
    let rhs = directory.appendingPathComponent("rhs.txt")
    try Data("same".utf8).write(to: lhs)
    try Data("same".utf8).write(to: rhs)
    XCTAssertNoThrow(try FileIntegrityService.verifyEquivalent(lhs, rhs))

    try Data("different".utf8).write(to: rhs)
    XCTAssertThrowsError(try FileIntegrityService.verifyEquivalent(lhs, rhs))
  }

  func testCopyOntoSymlinkAliasNeverReplacesTheSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-copy-alias-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let realDirectory = root.appendingPathComponent("real", isDirectory: true)
    let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = aliasDirectory.appendingPathComponent("document.txt")
    try Data("original".utf8).write(to: source)
    let copied = try FileSystemService.copy(source, to: realDirectory, existingItemPolicy: .replace)

    XCTAssertFalse(NafiURL.sameLocation(source, copied))
    XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    XCTAssertEqual(try Data(contentsOf: copied), Data("original".utf8))
  }


  func testAppStorageBoundedReadRejectsOversizeAndSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-storage-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("record.json")
    try Data("1234".utf8).write(to: file)
    XCTAssertEqual(try AppStoragePaths.readRegularFile(at: file, maximumBytes: 4), Data("1234".utf8))
    XCTAssertThrowsError(try AppStoragePaths.readRegularFile(at: file, maximumBytes: 3))

    let link = directory.appendingPathComponent("record-link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try AppStoragePaths.readRegularFile(at: link, maximumBytes: 4))
  }

  func testFileProviderSharedStoreUsesTheExtensionContainer() {
    XCTAssertTrue(
      AppStoragePaths.sharedDirectory.path.hasSuffix(
        "/Library/Containers/app.nafi.filemanager.fileprovider/Data/Library/Application Support/nafi"
      )
    )
  }

  func testFileDragPayloadPreservesObjectEncodingAndRejectsUnsupportedURLs() throws {
    let validURL = URL(fileURLWithPath: "/tmp/example.txt")
    let data = try JSONEncoder().encode(FileDragPayload(urls: [validURL]))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(object["urls"])

    let decoded = try JSONDecoder().decode(FileDragPayload.self, from: data)
    XCTAssertEqual(decoded.urls, [validURL])

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        FileDragPayload.self,
        from: Data(#"{"urls":["https://example.com/file.txt"]}"#.utf8)
      )
    )
  }

  func testBoundedProcessRunnerEnforcesOutputLimit() async throws {
    do {
      _ = try await BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 1234567890"],
        timeout: 5,
        maximumStandardOutputBytes: 4,
        maximumStandardErrorBytes: 1_024
      )
      XCTFail("Expected output limit failure")
    } catch BoundedProcessRunner.Failure.outputLimitExceeded {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testBoundedProcessRunnerEnforcesTimeout() async throws {
    do {
      _ = try await BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 5"],
        timeout: 0.1
      )
      XCTFail("Expected timeout failure")
    } catch BoundedProcessRunner.Failure.timedOut {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testTransferPolicyClampRepairsNonFiniteValues() {
    var policy = ConnectionTransferPolicy()
    policy.stabilityDelaySeconds = .nan
    policy.clamp()
    XCTAssertEqual(policy.stabilityDelaySeconds, 8)
  }

  func testSyncProfileClampRepairsNonFiniteValues() {
    var profile = SavedSyncProfile(
      name: "test",
      source: URL(fileURLWithPath: "/tmp/source"),
      destination: URL(fileURLWithPath: "/tmp/destination")
    )
    profile.maxDeleteRatio = .nan
    profile.stableForSeconds = .infinity
    profile.fullReconciliationInterval = -.infinity
    profile.clamp()
    XCTAssertEqual(profile.maxDeleteRatio, 0.20)
    XCTAssertEqual(profile.stableForSeconds, 8)
    XCTAssertEqual(profile.fullReconciliationInterval, 6 * 60 * 60)
  }

  func testRcloneJobReferenceRejectsInvalidIdentity() throws {
    let decoder = JSONDecoder()
    XCTAssertThrowsError(
      try decoder.decode(
        RcloneJobReference.self,
        from: Data(#"{"jobid":-1,"executeId":"valid"}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try decoder.decode(
        RcloneJobReference.self,
        from: Data(#"{"jobid":1,"executeId":"bad\nvalue"}"#.utf8)
      )
    )
    let valid = try decoder.decode(
      RcloneJobReference.self,
      from: Data(#"{"jobid":42,"executeId":"generation-1"}"#.utf8)
    )
    XCTAssertEqual(valid.jobID, 42)
    XCTAssertEqual(valid.executeID, "generation-1")
  }

  func testRcloneJobStatusRejectsIncompleteOrInvalidCompletion() {
    let decoder = JSONDecoder()
    XCTAssertThrowsError(
      try decoder.decode(
        RcloneJobStatus.self,
        from: Data(#"{"finished":true,"error":"","duration":1}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try decoder.decode(
        RcloneJobStatus.self,
        from: Data(#"{"finished":false,"error":"","duration":-1}"#.utf8)
      )
    )
  }

  func testBoundedProcessRunnerRejectsNonFiniteTimeouts() async {
    for timeout in [TimeInterval.nan, .infinity] {
      do {
        _ = try await BoundedProcessRunner.run(
          executableURL: URL(fileURLWithPath: "/bin/true"),
          arguments: [],
          timeout: timeout
        )
        XCTFail("Expected invalid input for \(timeout)")
      } catch BoundedProcessRunner.Failure.invalidInput {
        // Expected.
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }
}
