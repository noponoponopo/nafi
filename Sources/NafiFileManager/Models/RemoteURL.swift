import Foundation

enum NafiURL {
  static let remoteScheme = "nafi-remote"

  private static let remotePathSegmentAllowed: CharacterSet = {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/%?#")
    return allowed
  }()

  static func remoteRoot(for profile: ServerProfile) -> URL {
    remoteURL(profileID: profile.id, path: profile.path)
  }

  static func remoteURL(profileID: UUID, path: String, identityToken: String? = nil) -> URL {
    var components = URLComponents()
    components.scheme = remoteScheme
    components.host = profileID.uuidString.lowercased()

    let encodedComponents = RemotePath.normalized(path)
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { component in
        String(component).addingPercentEncoding(withAllowedCharacters: remotePathSegmentAllowed)
          ?? String(component).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
          ?? ""
      }
    components.percentEncodedPath = encodedComponents.isEmpty ? "/" : "/" + encodedComponents.joined(separator: "/")
    if let identityToken, !identityToken.isEmpty {
      components.queryItems = [URLQueryItem(name: "identity", value: identityToken)]
    }

    // The scheme, UUID host, and individually percent-encoded path components are all valid URL
    // components. Keep a deterministic root fallback rather than crashing if Foundation rejects an
    // otherwise valid value on a future OS release.
    if let url = components.url { return url }

    var fallback = URLComponents()
    fallback.scheme = remoteScheme
    fallback.host = profileID.uuidString.lowercased()
    fallback.path = "/"
    guard let root = fallback.url else {
      preconditionFailure("Foundation rejected a remote URL made only from a fixed scheme and UUID")
    }
    return root
  }

  static func isRemote(_ url: URL) -> Bool {
    url.scheme?.localizedCaseInsensitiveCompare(remoteScheme) == .orderedSame
  }

  static func remoteIdentity(in url: URL) -> String? {
    guard isRemote(url) else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "identity" })?.value
  }

  static func isAmbiguousRemoteItem(_ url: URL) -> Bool {
    remoteIdentity(in: url) != nil
  }

  static func profileID(in url: URL) -> UUID? {
    guard isRemote(url), let host = url.host else { return nil }
    return UUID(uuidString: host)
  }

  static func remotePath(in url: URL) -> String? {
    guard isRemote(url) else { return nil }
    // URL.path has already performed exactly one percent-decoding pass. Decoding it again would
    // incorrectly turn a literal filename such as "%20" into a space.
    return RemotePath.normalized(url.path)
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
    return remoteURL(profileID: profileID, path: path, identityToken: remoteIdentity(in: url))
  }

  static func locationKey(_ url: URL) -> String? {
    if url.isFileURL { return "file:\(canonicalLocalURL(url).path)" }
    guard isRemote(url), profileID(in: url) != nil, remotePath(in: url) != nil else { return nil }
    return "remote:\(normalized(url).absoluteString)"
  }

  static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
    if lhs.isFileURL, rhs.isFileURL {
      return canonicalLocalURL(lhs).path == canonicalLocalURL(rhs).path
    }
    return normalized(lhs) == normalized(rhs)
  }

  static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
    if isRemote(candidate) || isRemote(ancestor) {
      guard profileID(in: candidate) == profileID(in: ancestor),
        let candidatePath = remotePath(in: candidate),
        let ancestorPath = remotePath(in: ancestor)
      else { return false }
      let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
      return candidatePath != ancestorPath && candidatePath.hasPrefix(prefix)
    }

    return localRelativePath(of: candidate, under: ancestor).map { !$0.isEmpty } ?? false
  }

  static func localRelativePath(of candidate: URL, under ancestor: URL) -> String? {
    guard candidate.isFileURL, ancestor.isFileURL else { return nil }
    let candidatePath = canonicalLocalURL(candidate).path
    let ancestorPath = canonicalLocalURL(ancestor).path
    if candidatePath == ancestorPath { return "" }
    let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
    guard candidatePath.hasPrefix(prefix) else { return nil }
    return String(candidatePath.dropFirst(prefix.count))
  }

  private static func canonicalLocalURL(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    let fileManager = FileManager.default
    var existingPrefix = standardized
    var missingComponents: [String] = []

    // `resolvingSymlinksInPath()` does not reliably resolve a symlinked parent when the final
    // component does not exist. Resolve the longest existing prefix first, then append the missing
    // suffix. This keeps containment checks correct for create/copy destinations as well as files
    // that already exist.
    while !fileManager.fileExists(atPath: existingPrefix.path) {
      let component = existingPrefix.lastPathComponent
      let parent = existingPrefix.deletingLastPathComponent()
      guard !component.isEmpty, parent.path != existingPrefix.path else { break }
      missingComponents.append(component)
      existingPrefix = parent
    }

    var resolved = existingPrefix.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }
}
