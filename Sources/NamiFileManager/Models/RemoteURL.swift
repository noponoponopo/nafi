import Foundation

enum NafiURL {
  static let remoteScheme = "nafi-remote"

  static func remoteRoot(for profile: ServerProfile) -> URL {
    remoteURL(profileID: profile.id, path: profile.path)
  }

  static func remoteURL(profileID: UUID, path: String) -> URL {
    var components = URLComponents()
    components.scheme = remoteScheme
    components.host = profileID.uuidString.lowercased()
    components.percentEncodedPath = RemotePath.normalized(path)
      .split(separator: "/", omittingEmptySubsequences: true)
      .map {
        String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
      }
      .joined(separator: "/")
    if components.percentEncodedPath.isEmpty {
      components.percentEncodedPath = "/"
    } else if !components.percentEncodedPath.hasPrefix("/") {
      components.percentEncodedPath = "/" + components.percentEncodedPath
    }
    return components.url!
  }

  static func isRemote(_ url: URL) -> Bool {
    url.scheme == remoteScheme
  }

  static func profileID(in url: URL) -> UUID? {
    guard isRemote(url), let host = url.host else { return nil }
    return UUID(uuidString: host)
  }

  static func remotePath(in url: URL) -> String? {
    guard isRemote(url) else { return nil }
    return RemotePath.normalized(url.path.removingPercentEncoding ?? url.path)
  }

  static func appending(_ name: String, to directory: URL) -> URL {
    guard let profileID = profileID(in: directory), let path = remotePath(in: directory) else {
      return directory.appendingPathComponent(name)
    }
    return remoteURL(profileID: profileID, path: RemotePath.appending(name, to: path))
  }

  static func parent(of url: URL) -> URL {
    guard let profileID = profileID(in: url), let path = remotePath(in: url) else {
      return url.deletingLastPathComponent()
    }
    return remoteURL(profileID: profileID, path: RemotePath.parent(of: path))
  }

  static func displayPath(_ url: URL, profile: ServerProfile? = nil) -> String {
    guard isRemote(url) else { return url.path }
    let path = remotePath(in: url) ?? "/"
    if let profile {
      return "\(profile.name):\(path)"
    }
    return path
  }

  static func normalized(_ url: URL) -> URL {
    guard let profileID = profileID(in: url), let path = remotePath(in: url) else {
      return url.standardizedFileURL
    }
    return remoteURL(profileID: profileID, path: path)
  }

  static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
    if isRemote(candidate) || isRemote(ancestor) {
      guard profileID(in: candidate) == profileID(in: ancestor),
        let candidatePath = remotePath(in: candidate),
        let ancestorPath = remotePath(in: ancestor)
      else { return false }
      return candidatePath != ancestorPath
        && candidatePath.hasPrefix(ancestorPath == "/" ? "/" : ancestorPath + "/")
    }
    let candidatePath = candidate.standardizedFileURL.path
    let ancestorPath = ancestor.standardizedFileURL.path
    return candidatePath != ancestorPath && candidatePath.hasPrefix(ancestorPath + "/")
  }
}
