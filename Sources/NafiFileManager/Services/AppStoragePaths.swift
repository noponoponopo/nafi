import Foundation

enum AppStoragePaths {
  private static let directoryName = "nafi"
  private static let legacyDirectoryName = "Nami"

  static let directory: URL = {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let url = base.appendingPathComponent(directoryName, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static func file(named name: String) -> URL {
    let destination = directory.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      return destination
    }

    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let legacy =
      base
      .appendingPathComponent(legacyDirectoryName, isDirectory: true)
      .appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: legacy.path) {
      try? FileManager.default.copyItem(at: legacy, to: destination)
    }
    return destination
  }
}
