import Foundation

enum AppStoragePaths {
  private static let directoryName = "nafi"
  private static let legacyDirectoryName = "Nami"

  private static let applicationSupportDirectory: URL = {
    if let standard = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first {
      return standard
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
  }()

  static let directory: URL = {
    let url = applicationSupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    } catch {
      // Return the canonical path even when creation fails. Callers will receive the original
      // filesystem error from their read/write operation instead of crashing during app startup.
    }
    return url
  }()

  static let sshKnownHostsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".ssh/known_hosts", isDirectory: false)

  static func directory(named relativePath: String) -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
    precondition(!components.isEmpty, "App storage directory name must not be empty")
    var destination = directory
    for component in components {
      let safe = (String(component) as NSString).lastPathComponent
      precondition(safe == component, "App storage directory components must be simple names")
      destination.appendPathComponent(safe, isDirectory: true)
    }
    do {
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    } catch {
      // The eventual caller receives the concrete read/write error.
    }
    return destination
  }

  static var sharedDirectory: URL {
    let value = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/app.nafi.filemanager.fileprovider/Data", isDirectory: true)
      .appendingPathComponent("Library/Application Support/nafi", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: value,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: value.path)
    return value
  }

  static var legacyAppGroupDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Group Containers/group.app.nafi.filemanager", isDirectory: true)
      .appendingPathComponent("Library/Application Support/nafi", isDirectory: true)
  }

  static func sharedFile(named name: String) -> URL {
    let safe = (name as NSString).lastPathComponent
    precondition(safe == name && !name.isEmpty)
    return sharedDirectory.appendingPathComponent(safe)
  }

  static func file(named name: String) -> URL {
    let safeName = (name as NSString).lastPathComponent
    precondition(
      safeName == name && !name.isEmpty,
      "App storage filenames must not contain path separators"
    )
    let destination = directory.appendingPathComponent(safeName, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      return destination
    }

    let legacy = applicationSupportDirectory
      .appendingPathComponent(legacyDirectoryName, isDirectory: true)
      .appendingPathComponent(safeName, isDirectory: false)
    migrateLegacyFileIfNeeded(from: legacy, to: destination)
    return destination
  }

  static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    for attempt in 0..<2 {
      let values = try url.resourceValues(forKeys: keys)
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size >= 0, size <= maximumBytes
      else { throw CocoaError(.fileReadCorruptFile) }
      let handle = try FileHandle(forReadingFrom: url)
      let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
      try? handle.close()
      if data.count == size { return data }
      if attempt == 0 { continue }
    }
    throw CocoaError(.fileReadCorruptFile)
  }

  static func quarantineCorruptFile(at url: URL, label: String = "corrupt") {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let formatter = ISO8601DateFormatter()
    let suffix = formatter.string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    let name = ext.isEmpty
      ? "\(base).\(label)-\(suffix)"
      : "\(base).\(label)-\(suffix).\(ext)"
    let destination = uniqueURL(named: name, in: url.deletingLastPathComponent())
    try? FileManager.default.moveItem(at: url, to: destination)
  }

  private static func migrateLegacyFileIfNeeded(from legacy: URL, to destination: URL) {
    guard FileManager.default.fileExists(atPath: legacy.path),
      !FileManager.default.fileExists(atPath: destination.path)
    else { return }

    let temporary = directory.appendingPathComponent(
      ".nafi-migration-\(UUID().uuidString)",
      isDirectory: false
    )
    do {
      let data = try readRegularFile(at: legacy, maximumBytes: 64 * 1_024 * 1_024)
      try data.write(to: temporary, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
    }
  }

  private static func uniqueURL(named name: String, in directory: URL) -> URL {
    var candidate = directory.appendingPathComponent(name)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(name).\(index)")
      index += 1
    }
    return candidate
  }
}
