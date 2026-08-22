import FileProvider
import Foundation
import UniformTypeIdentifiers

final class NafiFileProviderItem: NSObject, NSFileProviderItem {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType
  let capabilities: NSFileProviderItemCapabilities
  let contentPolicy: NSFileProviderContentPolicy = .downloadLazily
  let documentSize: NSNumber?
  let contentModificationDate: Date?
  let creationDate: Date?
  let itemVersion: NSFileProviderItemVersion
  let path: String
  let isDirectory: Bool
  let identityToken: String?
  let contentFingerprint: String
  var lastUsedDate: Date? { nil }

  init(
    path: String,
    name: String,
    isDirectory: Bool,
    size: Int64?,
    modTime: Date?,
    readOnly: Bool = false,
    unavailable: Bool = false,
    identityToken: String? = nil,
    contentFingerprint: String? = nil,
    versionFingerprint: String? = nil,
    isRoot: Bool = false
  ) throws {
    let normalizedPath = try FPIdentifierCodec.validatedPath(path)
    let validatedName = try FPIdentifierCodec.validatedName(name)
    self.path = normalizedPath
    self.isDirectory = isDirectory
    self.identityToken = identityToken
    itemIdentifier = try FPIdentifierCodec.identifier(for: normalizedPath, identityToken: identityToken)
    parentItemIdentifier = try FPIdentifierCodec.identifier(for: FPIdentifierCodec.parentPath(of: normalizedPath))
    filename = validatedName
    contentType = isDirectory
      ? .folder
      : (UTType(filenameExtension: (validatedName as NSString).pathExtension) ?? .data)
    documentSize = size.flatMap { $0 >= 0 ? NSNumber(value: $0) : nil }
    if let modTime {
      let value = modTime.timeIntervalSinceReferenceDate
      guard value.isFinite, value > -10_000_000_000, value < 10_000_000_000 else {
        throw FPBridgeError.malformedResponse
      }
    }
    contentModificationDate = modTime
    creationDate = nil

    var allowed: NSFileProviderItemCapabilities = unavailable ? [] : [.allowsReading]
    if isRoot && !unavailable {
      allowed = [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating]
    } else if !readOnly && !unavailable {
      allowed.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing])
      if isDirectory {
        allowed.formUnion([.allowsAddingSubItems, .allowsContentEnumerating])
      }
    } else if isDirectory && !unavailable {
      // Read-only folders still need to advertise that Finder may enumerate
      // their contents. Omitting this creates contradictory metadata.
      allowed.insert(.allowsContentEnumerating)
    }
    capabilities = allowed

    let contentToken = contentFingerprint
      ?? "\(identityToken ?? "")|\(size ?? -1)|\(modTime?.timeIntervalSince1970 ?? -1)|\(isDirectory)"
    let versionToken = versionFingerprint ?? contentToken
    guard contentToken.utf8.count <= 64 * 1_024, versionToken.utf8.count <= 64 * 1_024 else {
      throw FPBridgeError.malformedResponse
    }
    self.contentFingerprint = contentToken
    let metadataToken = "\(normalizedPath)|\(validatedName)|\(isDirectory)|\(readOnly)|\(unavailable)"
    itemVersion = NSFileProviderItemVersion(
      contentVersion: Data(versionToken.utf8),
      metadataVersion: Data(metadataToken.utf8)
    )
    super.init()
  }

  convenience init(snapshot item: FPSnapshotItem) throws {
    try self.init(
      path: item.path,
      name: item.filename,
      isDirectory: item.isDirectory,
      size: item.size,
      modTime: item.modification,
      readOnly: item.readOnly,
      unavailable: item.unavailable,
      identityToken: item.identityToken,
      contentFingerprint: item.contentFingerprint
    )
  }

  static func root(displayName: String) throws -> NafiFileProviderItem {
    var safeName = String(displayName.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
    }).replacingOccurrences(of: "/", with: "／")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if safeName.isEmpty || safeName == "." || safeName == ".." { safeName = "Nafi Remote" }
    if safeName.utf8.count > 4_096 {
      safeName = String(safeName.prefix(1_024))
    }
    let item = try NafiFileProviderItem(
      path: "",
      name: safeName,
      isDirectory: true,
      size: nil,
      modTime: nil,
      readOnly: true,
      contentFingerprint: "root",
      isRoot: true
    )
    return item
  }
}
#if compiler(>=6.2)
@available(macOS 26.0, *)
extension NafiFileProviderItem: NSFileProviderSearchResult {}
#endif
