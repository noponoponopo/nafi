import Foundation

struct FileSearchResult: Sendable {
  let items: [FileItem]
  let rootURL: URL
  let didReachLimit: Bool
}

enum FileSearchService {
  static let resultLimit = 5_000

  static func search(
    query: String,
    from currentURL: URL,
    scope: FileSearchScope,
    showHidden: Bool,
    filter: FileSearchFilter
  ) async throws -> FileSearchResult {
    let root = await searchRoot(for: currentURL, scope: scope)
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )

    guard !normalizedQuery.isEmpty else {
      return FileSearchResult(items: [], rootURL: root, didReachLimit: false)
    }

    if root.isFileURL {
      return try await Task.detached(priority: .userInitiated) {
        try searchLocal(
          query: normalizedQuery,
          root: root,
          showHidden: showHidden,
          filter: filter,
          limit: resultLimit
        )
      }.value
    }

    return try await searchRemote(
      query: normalizedQuery,
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

  private static func searchLocal(
    query: String,
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
      guard let values = try? url.resourceValues(forKeys: FileSystemService.resourceKeys) else {
        continue
      }
      let name = values.name ?? url.lastPathComponent
      if !showHidden && (values.isHidden == true || name.hasPrefix(".")) { continue }

      let normalizedName = name.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "ja_JP")
      )
      guard normalizedName.contains(query) else { continue }

      let item = FileItem(
        url: url,
        name: name,
        isDirectory: values.isDirectory == true,
        isPackage: values.isPackage == true,
        isHidden: values.isHidden == true || name.hasPrefix("."),
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
    query: String,
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
        children = try await UnifiedFileSystemService.contents(
          of: directory,
          showHidden: showHidden
        )
      } catch  where !NafiURL.sameLocation(directory, root) {
        continue
      }

      for item in children {
        if Task.isCancelled { throw CancellationError() }
        if item.normalizedName.contains(query), filter.matches(item) {
          matches.append(item)
          if matches.count >= limit {
            return FileSearchResult(items: matches, rootURL: root, didReachLimit: true)
          }
        }
        if item.isDirectory && !item.isPackage {
          let normalizedURL = NafiURL.normalized(item.url)
          if visited.insert(normalizedURL).inserted {
            pending.append(item.url)
          }
        }
      }
    }

    return FileSearchResult(items: matches, rootURL: root, didReachLimit: false)
  }
}
