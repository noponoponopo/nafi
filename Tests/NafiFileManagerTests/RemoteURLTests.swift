import Foundation
import XCTest
@testable import NafiFileManager

final class RemoteURLTests: XCTestCase {
  private let profileID = UUID(uuidString: "D48516DE-14BE-4D75-95BD-5EA8247D0B68")!

  func testLocalRootRecognizesDescendants() {
    XCTAssertTrue(
      NafiURL.isDescendant(
        URL(fileURLWithPath: "/Users/example/Documents"),
        of: URL(fileURLWithPath: "/")
      )
    )
  }

  func testComponentBoundaryIsNotTreatedAsDescendant() {
    XCTAssertFalse(
      NafiURL.isDescendant(
        URL(fileURLWithPath: "/tmp/catalog"),
        of: URL(fileURLWithPath: "/tmp/cat")
      )
    )
  }

  func testLocalDescendantResolvesSymlinkedParents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nafi-url-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let apparentAncestor = root.appendingPathComponent("ancestor", isDirectory: true)
    let link = apparentAncestor.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: apparentAncestor, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: root) }

    let candidate = link.appendingPathComponent("file.txt")
    XCTAssertFalse(NafiURL.isDescendant(candidate, of: apparentAncestor))
    XCTAssertTrue(NafiURL.isDescendant(candidate, of: outside))
    XCTAssertEqual(NafiURL.localRelativePath(of: candidate, under: outside), "file.txt")
    XCTAssertNil(NafiURL.localRelativePath(of: candidate, under: apparentAncestor))
    XCTAssertTrue(NafiURL.sameLocation(link, outside))
  }

  func testLocationKeyIgnoresDirectoryURLHint() {
    let fileStyle = URL(fileURLWithPath: "/tmp/example")
    let directoryStyle = URL(fileURLWithPath: "/tmp/example", isDirectory: true)
    XCTAssertEqual(NafiURL.locationKey(fileStyle), NafiURL.locationKey(directoryStyle))
    XCTAssertTrue(NafiURL.sameLocation(fileStyle, directoryStyle))
  }

  func testRemoteLiteralPercentSequenceRoundTrips() {
    let original = "/folder/literal%20name/%done"
    let url = NafiURL.remoteURL(profileID: profileID, path: original)
    XCTAssertEqual(NafiURL.remotePath(in: url), original)
  }

  func testRemoteReservedCharactersRoundTrip() {
    let original = "/folder/a #b?/日本語"
    let url = NafiURL.remoteURL(profileID: profileID, path: original)
    XCTAssertEqual(NafiURL.remotePath(in: url), original)
  }

  func testRemoteTrailingSpacesArePreserved() {
    let original = "/folder/name  "
    let url = NafiURL.remoteURL(profileID: profileID, path: original)
    XCTAssertEqual(NafiURL.remotePath(in: url), original)
  }

  func testRemoteRootRecognizesDescendants() {
    let root = NafiURL.remoteURL(profileID: profileID, path: "/")
    let child = NafiURL.remoteURL(profileID: profileID, path: "/folder/file.txt")
    XCTAssertTrue(NafiURL.isDescendant(child, of: root))
  }

  func testDifferentProfilesAreNeverAncestors() {
    let otherID = UUID(uuidString: "0D0CF510-1D07-4DF0-BB3A-437F7F716C78")!
    let ancestor = NafiURL.remoteURL(profileID: profileID, path: "/folder")
    let candidate = NafiURL.remoteURL(profileID: otherID, path: "/folder/file.txt")
    XCTAssertFalse(NafiURL.isDescendant(candidate, of: ancestor))
  }

  func testCommandValidationRejectsLineBreaksAndNUL() {
    XCTAssertThrowsError(try RemotePath.validatedForCommand("/bad\nname"))
    XCTAssertThrowsError(try RemotePath.validatedForCommand("/bad\rname"))
    XCTAssertThrowsError(try RemotePath.validatedForCommand("/bad\0name"))
    XCTAssertNoThrow(try RemotePath.validatedForCommand("/valid name"))
  }
}
