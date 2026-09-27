import AppKit
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

  func testOnlyExplicitKnownHostsErrorsAreClassified() {
    XCTAssertTrue(
      RcloneRemoteSession.isHostKeyRelatedErrorMessage(
        "NewFs: couldn't connect SSH: ssh: handshake failed: knownhosts: key is unknown"
      )
    )
    XCTAssertTrue(
      RcloneRemoteSession.isHostKeyRelatedErrorMessage("knownhosts: key mismatch")
    )
    XCTAssertFalse(
      RcloneRemoteSession.isHostKeyRelatedErrorMessage("host key verification failed")
    )
    XCTAssertFalse(
      RcloneRemoteSession.isHostKeyRelatedErrorMessage("rclone connection failed")
    )
  }

  func testHostKeyRelatedMessagesRequireExactKnownHostsErrors() {
    XCTAssertTrue(RcloneRemoteSession.isHostKeyRelatedErrorMessage("knownhosts: key mismatch"))
    XCTAssertTrue(RcloneRemoteSession.isHostKeyRelatedErrorMessage("couldn't parse known_hosts_file"))
    XCTAssertTrue(RcloneRemoteSession.isHostKeyRelatedErrorMessage("SSHホストキーが登録されていません。"))
    XCTAssertFalse(RcloneRemoteSession.isHostKeyRelatedErrorMessage("SSHホストキーを取得できませんでした。"))
    XCTAssertFalse(RcloneRemoteSession.isHostKeyRelatedErrorMessage("host key verification failed"))
    XCTAssertFalse(RcloneRemoteSession.isHostKeyRelatedErrorMessage("temporary network failure"))
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

  func testHostKeyApprovalDistinguishesNewAndChangedKeys() {
    let old = Set(["ssh-ed25519 SHA256:old"])
    XCTAssertTrue(
      SSHHostKeyApprovalRequest.isKeyChange(
        existingIdentities: old,
        scannedIdentities: ["ssh-ed25519 SHA256:new"]
      )
    )
    XCTAssertFalse(
      SSHHostKeyApprovalRequest.isKeyChange(
        existingIdentities: old,
        scannedIdentities: ["ssh-ed25519 SHA256:old"]
      )
    )
    XCTAssertFalse(
      SSHHostKeyApprovalRequest.isKeyChange(
        existingIdentities: [],
        scannedIdentities: ["ssh-ed25519 SHA256:new"]
      )
    )
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
    try Data("123456".utf8).write(to: file)
    XCTAssertEqual(try AppStoragePaths.readRegularFile(at: file, maximumBytes: 6), Data("123456".utf8))

    let link = directory.appendingPathComponent("record-link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try AppStoragePaths.readRegularFile(at: link, maximumBytes: 6))
  }

  func testFileProviderStoreNeverFallsBackToApplicationStorage() {
    let store = AppStoragePaths.fileProviderFile(named: "file-provider-domains.json")
    if let providerDirectory = AppStoragePaths.fileProviderDirectory {
      XCTAssertEqual(store, providerDirectory.appendingPathComponent("file-provider-domains.json"))
      XCTAssertTrue(providerDirectory.path.contains(
        "/Library/Containers/app.nafi.filemanager.fileprovider/Data/"))
    } else {
      XCTAssertNil(store)
    }
    XCTAssertNotEqual(store, AppStoragePaths.directory.appendingPathComponent("file-provider-domains.json"))
  }

  @MainActor
  func testFileProviderMigrationUsesReadableSourceWithoutReplacingExistingRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-fp-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("legacy.json")
    let original = Data(
      #"[{"id":"00000000-0000-0000-0000-000000000001","displayName":"Test","fs":"remote:","rootPath":"","updatedAt":0}]"#.utf8
    )
    try original.write(to: source)
    let shared = root.appendingPathComponent("extension", isDirectory: true)
    let destination = shared.appendingPathComponent("file-provider-domains.json")
    let unreadable = root.appendingPathComponent("unreadable.json", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: nil, legacyAppGroupStoreURL: source, legacyFileProviderStoreURL: source)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: shared, legacyAppGroupStoreURL: unreadable,
      legacyFileProviderStoreURL: root.appendingPathComponent("missing.json"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    let malformed = root.appendingPathComponent("malformed.json")
    try Data(#"[{"id":"00000000-0000-0000-0000-000000000002"}]"#.utf8).write(to: malformed)
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: shared, legacyAppGroupStoreURL: malformed,
      legacyFileProviderStoreURL: root.appendingPathComponent("missing.json"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: shared, legacyAppGroupStoreURL: unreadable, legacyFileProviderStoreURL: source)
    XCTAssertEqual(try Data(contentsOf: destination), original)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)

    try Data("changed".utf8).write(to: source)
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: shared, legacyAppGroupStoreURL: unreadable, legacyFileProviderStoreURL: source)
    XCTAssertEqual(try Data(contentsOf: destination), original)

    let second = root.appendingPathComponent("extension-two", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let legacyID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let legacyIDs = try JSONEncoder().encode(Set([legacyID]))
    try legacyIDs.write(to: source)
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: second, legacyAppGroupStoreURL: unreadable, legacyFileProviderStoreURL: source)
    XCTAssertEqual(
      try Data(contentsOf: second.appendingPathComponent("file-provider-domains.json")), legacyIDs)

    let olderGroup = root.appendingPathComponent("appgroup.json")
    try original.write(to: olderGroup)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: olderGroup.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: source.path)
    let third = root.appendingPathComponent("extension-three", isDirectory: true)
    try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
    try SystemIntegrationService.migrateLegacyFileProviderStoreIfNeeded(
      to: third, legacyAppGroupStoreURL: olderGroup, legacyFileProviderStoreURL: source)
    XCTAssertEqual(
      try Data(contentsOf: third.appendingPathComponent("file-provider-domains.json")), legacyIDs)
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

  @MainActor
  func testDragIconsFitWithoutChangingAspectRatio() throws {
    for symbol in ["folder.fill", "doc.fill"] {
      let icon = try XCTUnwrap(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
      let originalSize = icon.size
      let fitted = FileDragIcon.fitted(icon)
      XCTAssertEqual(fitted.size.width / fitted.size.height, originalSize.width / originalSize.height, accuracy: 0.001)
      XCTAssertEqual(max(fitted.size.width, fitted.size.height), 28, accuracy: 0.001)
      XCTAssertEqual(icon.size, originalSize)
    }
  }

  func testFileDragStartsOnlyFromASelectedItem() {
    let selectedURL = URL(fileURLWithPath: "/tmp/selected.txt")
    let otherURL = URL(fileURLWithPath: "/tmp/other.txt")
    let frames = [
      selectedURL: CGRect(x: 0, y: 0, width: 40, height: 40),
      otherURL: CGRect(x: 50, y: 0, width: 40, height: 40),
    ]

    XCTAssertEqual(
      FileDragHitTesting.selectedItemURL(
        at: CGPoint(x: 20, y: 20),
        itemFrames: frames,
        selectedURLs: [selectedURL]
      ),
      selectedURL
    )
    XCTAssertNil(
      FileDragHitTesting.selectedItemURL(
        at: CGPoint(x: 70, y: 20),
        itemFrames: frames,
        selectedURLs: [selectedURL]
      )
    )
    XCTAssertNil(
      FileDragHitTesting.selectedItemURL(
        at: CGPoint(x: 120, y: 20),
        itemFrames: frames,
        selectedURLs: [selectedURL]
      )
    )
  }

  @MainActor
  func testFileDragIncludesEverySelectedURL() {
    let primaryURL = URL(fileURLWithPath: "/tmp/primary.txt")
    let otherURL = URL(fileURLWithPath: "/tmp/other.txt")
    let selection = FileSelectionController()

    selection.replace(with: [primaryURL, otherURL], primary: primaryURL)

    XCTAssertEqual(selection.dragURLs.first, primaryURL)
    XCTAssertEqual(Set(selection.dragURLs), [primaryURL, otherURL])
  }

  @MainActor
  func testTogglingSelectionMaintainsPrimaryDragURL() {
    let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
    let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
    let addedURL = URL(fileURLWithPath: "/tmp/added.txt")
    let selection = FileSelectionController()

    selection.replace(with: [firstURL, secondURL], primary: firstURL)
    selection.toggle(addedURL)

    XCTAssertEqual(selection.primaryURL, addedURL)
    XCTAssertEqual(selection.dragURLs.first, addedURL)
    XCTAssertEqual(Set(selection.dragURLs), [firstURL, secondURL, addedURL])

    selection.toggle(addedURL)

    XCTAssertNotNil(selection.primaryURL)
    XCTAssertEqual(selection.dragURLs.first, selection.primaryURL)
    XCTAssertEqual(Set(selection.dragURLs), [firstURL, secondURL])
  }

  @MainActor
  func testNewlySplitPaneCanBeClosedDirectly() {
    let workspace = WorkspaceModel(
      initialURL: FileManager.default.temporaryDirectory,
      showHidden: false,
      viewMode: .list
    )
    let originalPaneID = workspace.activePaneID

    workspace.splitActive(axis: .horizontal)
    let newPaneID = workspace.activePaneID
    XCTAssertEqual(workspace.paneCount, 2)

    workspace.closePane(newPaneID)
    XCTAssertEqual(workspace.paneCount, 1)
    XCTAssertEqual(workspace.activePaneID, originalPaneID)
    XCTAssertNotNil(workspace.session(for: originalPaneID))
    XCTAssertNil(workspace.session(for: newPaneID))
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

extension RobustnessTests {
  func testFileNameSearchUsesANDTermsAndJapaneseWidthFolding() {
    let terms = FileNameSearchMatcher.terms(" Report   ２０２６ ")
    XCTAssertEqual(terms, ["report", "2026"])
    XCTAssertEqual(Set(FileNameSearchMatcher.spotlightVariants(for: "2026")), Set(["2026", "２０２６"]))
    XCTAssertTrue(
      FileNameSearchMatcher.matches(
        normalizedCandidate: FileNameSearchMatcher.normalize("2026_Final_REPORT.pdf"),
        terms: terms
      )
    )
    XCTAssertFalse(
      FileNameSearchMatcher.matches(
        normalizedCandidate: FileNameSearchMatcher.normalize("report-2025.pdf"),
        terms: terms
      )
    )
  }
}
