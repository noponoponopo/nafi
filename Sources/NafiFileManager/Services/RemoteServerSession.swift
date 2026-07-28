import Foundation

protocol RemoteServerSession: AnyObject, Sendable {
  func listDirectory(at path: String) async throws -> [RemoteFileItem]
  func createDirectory(at path: String) async throws
  func renameItem(at oldPath: String, to newPath: String) async throws
  func removeItem(at path: String, isDirectory: Bool) async throws
  func downloadItem(at remotePath: String, to localURL: URL) async throws
  func uploadItem(from localURL: URL, to remotePath: String) async throws
  func close() async
}

enum RemotePath {
  static func normalized(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "/" }
    var components: [String] = []
    for component in trimmed.split(separator: "/") {
      switch component {
      case ".": continue
      case "..": if !components.isEmpty { components.removeLast() }
      default: components.append(String(component))
      }
    }
    return "/" + components.joined(separator: "/")
  }

  static func appending(_ name: String, to path: String) -> String {
    let base = normalized(path)
    return normalized(base == "/" ? "/\(name)" : "\(base)/\(name)")
  }

  static func parent(of path: String) -> String {
    let normalizedPath = normalized(path)
    guard normalizedPath != "/" else { return "/" }
    let parent = (normalizedPath as NSString).deletingLastPathComponent
    return normalized(parent)
  }

  static func name(of path: String) -> String {
    (normalized(path) as NSString).lastPathComponent
  }
}

func remoteItemSort(_ lhs: RemoteFileItem, _ rhs: RemoteFileItem) -> Bool {
  if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
  return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
}
