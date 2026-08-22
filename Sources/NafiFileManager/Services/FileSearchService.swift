import Foundation

struct FileSearchResult: Sendable {
  let items: [FileItem]
  let rootURL: URL
  let didReachLimit: Bool
}

enum FileSearchService {
  static let resultLimit = 5_000
  private static let searchLocale = Locale(identifier: "ja_JP")

  static func search(
    query: String,
    from currentURL: URL,
    scope: FileSearchScope,
    showHidden: Bool,
    filter: FileSearchFilter
  ) async throws -> FileSearchResult {
    let root = await searchRoot(for: currentURL, scope: scope)
    let searchTerms = FileNameSearchMatcher.terms(query)

    guard !searchTerms.isEmpty else {
      return FileSearchResult(items: [], rootURL: root, didReachLimit: false)
    }

    if root.isFileURL {
      let spotlightText = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if let candidateURLs = await FileSpotlightSearchService.matchingURLs(text: spotlightText, root: root) {
        return try await Task.detached(priority: .userInitiated) {
          try searchLocalCandidates(
            candidateURLs,
            terms: searchTerms,
            root: root,
            showHidden: showHidden,
            filter: filter,
            limit: resultLimit
          )
        }.value
      }

      try Task.checkCancellation()
      // Spotlight can be unavailable on explicitly unindexed/removable volumes.
      // Preserve correctness there, but only pay for a full walk when the indexed
      // query could not complete.
      return try await Task.detached(priority: .userInitiated) {
        try searchLocal(
          terms: searchTerms,
          root: root,
          showHidden: showHidden,
          filter: filter,
          limit: resultLimit
        )
      }.value
    }

    return try await searchRemote(
      terms: searchTerms,
      root: root,
      showHidden: showHidden,
      filter: filter,
      limit: resultLimit
    )
  }

  static func searchRoot(for currentURL: URL, scope: FileSearchScope) async -> URL {
    guard scope == .storage else { return currentURL }

    if let profile = await RemoteFileSystemRegistry.shared.profile(for: currentURL) {
      return NafiURL.remoteRoot(for: profile)
    }

    let current = currentURL.standardizedFileURL
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil,
        options: [.skipHiddenVolumes]
      ) ?? []
    return
      volumes
      .filter { volume in
        NafiURL.sameLocation(current, volume) || NafiURL.isDescendant(current, of: volume)
      }
      .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
      ?? URL(fileURLWithPath: "/", isDirectory: true)
  }

  private static func searchLocalCandidates(
    _ urls: [URL],
    terms: [String],
    root: URL,
    showHidden: Bool,
    filter: FileSearchFilter,
    limit: Int
  ) throws -> FileSearchResult {
    let normalizedRoot = root.standardizedFileURL
    var matches: [FileItem] = []
    matches.reserveCapacity(min(limit, 512))

    for url in urls {
      if Task.isCancelled { throw CancellationError() }
      let normalizedURL = url.standardizedFileURL
      guard !NafiURL.sameLocation(normalizedURL, normalizedRoot),
        NafiURL.isDescendant(normalizedURL, of: normalizedRoot)
      else { continue }

      let name = normalizedURL.lastPathComponent
      let normalizedName = name.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: searchLocale
      )
      // Spotlight is the candidate generator; Nafi remains the source of truth
      // for width-insensitive matching and application-specific filters.
      guard FileNameSearchMatcher.matches(normalizedCandidate: normalizedName, terms: terms) else { continue }

      if !showHidden {
        let relative = normalizedURL.path.dropFirst(normalizedRoot.path.count)
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      }

      guard let values = try? normalizedURL.resourceValues(forKeys: FileSystemService.resourceKeys) else {
        continue
      }
      let resolvedName = values.name ?? name
      if !showHidden && (values.isHidden == true || resolvedName.hasPrefix(".")) { continue }

      let item = FileItem(
        url: normalizedURL,
        name: resolvedName,
        isDirectory: values.isDirectory == true,
        isPackage: values.isPackage == true,
        isHidden: values.isHidden == true || resolvedName.hasPrefix("."),
        fileSize: values.fileSize.map(Int64.init),
        creationDate: values.creationDate,
        modificationDate: values.contentModificationDate,
        contentTypeIdentifier: values.contentType?.identifier,
        tagNames: values.tagNames ?? []
      )
      guard filter.matches(item) else { continue }
      matches.append(item)
      if matches.count >= limit {
        return FileSearchResult(items: matches, rootURL: root, didReachLimit: true)
      }
    }

    return FileSearchResult(items: matches, rootURL: root, didReachLimit: false)
  }

  private static func searchLocal(
    terms: [String],
    root: URL,
    showHidden: Bool,
    filter: FileSearchFilter,
    limit: Int
  ) throws -> FileSearchResult {
    var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
    if !showHidden { options.insert(.skipsHiddenFiles) }

    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(FileSystemService.resourceKeys),
        options: options,
        errorHandler: { _, _ in true }
      )
    else {
      return FileSearchResult(items: [], rootURL: root, didReachLimit: false)
    }

    var matches: [FileItem] = []
    matches.reserveCapacity(min(limit, 512))

    for case let url as URL in enumerator {
      if Task.isCancelled { throw CancellationError() }
      // Name matching is intentionally performed before requesting resource
      // values. Recursive searches can walk hundreds of thousands of entries;
      // fetching content type, tags and dates for every non-match is expensive
      // on both local disks and network-backed volumes. The enumerator already
      // applies .skipsHiddenFiles when hidden files are disabled.
      let name = url.lastPathComponent
      let normalizedName = name.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: searchLocale
      )
      guard FileNameSearchMatcher.matches(normalizedCandidate: normalizedName, terms: terms) else { continue }

      guard let values = try? url.resourceValues(forKeys: FileSystemService.resourceKeys) else {
        continue
      }
      let resolvedName = values.name ?? name
      if !showHidden && (values.isHidden == true || resolvedName.hasPrefix(".")) { continue }

      let item = FileItem(
        url: url,
        name: resolvedName,
        isDirectory: values.isDirectory == true,
        isPackage: values.isPackage == true,
        isHidden: values.isHidden == true || resolvedName.hasPrefix("."),
        fileSize: values.fileSize.map(Int64.init),
        creationDate: values.creationDate,
        modificationDate: values.contentModificationDate,
        contentTypeIdentifier: values.contentType?.identifier,
        tagNames: values.tagNames ?? []
      )
      guard filter.matches(item) else { continue }
      matches.append(item)

      if matches.count >= limit {
        return FileSearchResult(items: matches, rootURL: root, didReachLimit: true)
      }
    }

    return FileSearchResult(items: matches, rootURL: root, didReachLimit: false)
  }

  private static func searchRemote(
    terms: [String],
    root: URL,
    showHidden: Bool,
    filter: FileSearchFilter,
    limit: Int
  ) async throws -> FileSearchResult {
    guard let profileID = NafiURL.profileID(in: root) else {
      throw RemoteServerError.notConnected
    }
    let session = try await RemoteFileSystemRegistry.shared.session(for: profileID)
    let rootPath = NafiURL.remotePath(in: root) ?? "/"

    do {
      let catalog = try await session.recursiveCatalog(at: rootPath)
      var matches: [FileItem] = []
      matches.reserveCapacity(min(limit, 512))
      for remoteItem in catalog {
        if Task.isCancelled { throw CancellationError() }
        if !showHidden && Self.remotePathContainsHiddenComponent(remoteItem.path, under: rootPath) {
          continue
        }
        // The recursive catalog stores this normalized form once. Avoid
        // constructing FileItem/UTType/formatters for every non-match on each
        // keystroke; only matching candidates pay that richer conversion cost.
        guard FileNameSearchMatcher.matches(normalizedCandidate: remoteItem.normalizedName, terms: terms) else {
          continue
        }
        let item = FileItem(remote: remoteItem, profileID: profileID)
        guard filter.matches(item) else { continue }
        matches.append(item)
        if matches.count >= limit {
          return FileSearchResult(items: matches, rootURL: root, didReachLimit: true)
        }
      }
      return FileSearchResult(items: matches, rootURL: root, didReachLimit: false)
    } catch let error as RcloneRuntimeError {
      // A compact recursive catalog is the fast path. The RC transport has a
      // deliberately bounded response size; if an exceptionally large remote
      // exceeds it, retain correctness with the older directory walk rather
      // than silently returning partial results.
      guard case .invalidResponse(let message) = error, message.contains("64 MiB") else { throw error }
      return try await searchRemoteByWalking(
        terms: terms, root: root, showHidden: showHidden, filter: filter, limit: limit
      )
    }
  }

  private static func remotePathContainsHiddenComponent(_ path: String, under root: String) -> Bool {
    let normalizedRoot = RemotePath.normalized(root)
    let normalizedPath = RemotePath.normalized(path)
    var relative = normalizedPath
    if normalizedRoot != "/", Self.remotePath(normalizedRoot, contains: normalizedPath) {
      relative = String(normalizedPath.dropFirst(normalizedRoot.count))
    }
    return relative.split(separator: "/").contains { $0.hasPrefix(".") }
  }

  private static func remotePath(_ ancestor: String, contains descendant: String) -> Bool {
    let parent = RemotePath.normalized(ancestor)
    let child = RemotePath.normalized(descendant)
    return parent == "/" || child == parent || child.hasPrefix(parent + "/")
  }

  private static func searchRemoteByWalking(
    terms: [String],
    root: URL,
    showHidden: Bool,
    filter: FileSearchFilter,
    limit: Int
  ) async throws -> FileSearchResult {
    var pending = [root]
    var visited: Set<URL> = [NafiURL.normalized(root)]
    var index = 0
    var matches: [FileItem] = []
    matches.reserveCapacity(min(limit, 512))

    while index < pending.count {
      if Task.isCancelled { throw CancellationError() }
      let directory = pending[index]
      index += 1

      let children: [FileItem]
      do {
        children = try await UnifiedFileSystemService.contents(of: directory, showHidden: showHidden)
      } catch where !NafiURL.sameLocation(directory, root) {
        continue
      }

      for item in children {
        if Task.isCancelled { throw CancellationError() }
        if FileNameSearchMatcher.matches(normalizedCandidate: item.normalizedName, terms: terms), filter.matches(item) {
          matches.append(item)
          if matches.count >= limit {
            return FileSearchResult(items: matches, rootURL: root, didReachLimit: true)
          }
        }
        if item.isDirectory && !item.isPackage {
          let normalizedURL = NafiURL.normalized(item.url)
          if visited.insert(normalizedURL).inserted { pending.append(item.url) }
        }
      }
    }
    return FileSearchResult(items: matches, rootURL: root, didReachLimit: false)
  }

}
