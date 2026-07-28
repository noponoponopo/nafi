import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FilePaneModel: ObservableObject, Identifiable {
  enum Prompt: Identifiable {
    case newFile
    case newFolder
    case rename(URL)
    case tags([URL])

    var id: String {
      switch self {
      case .newFile: "newFile"
      case .newFolder: "newFolder"
      case .rename(let url): "rename-\(url.path)"
      case .tags(let urls): "tags-\(urls.map(\.path).joined(separator: "|"))"
      }
    }

    var title: String {
      switch self {
      case .newFile: "新規ファイル"
      case .newFolder: "新規フォルダ"
      case .rename: "名前を変更"
      case .tags: "タグを編集"
      }
    }

    var placeholder: String {
      switch self {
      case .tags: "タグをカンマ区切りで入力"
      default: "名前"
      }
    }
  }

  enum TransferConflictResolution: Equatable {
    case keepBoth
    case replace
  }

  struct TransferConflictPrompt: Identifiable {
    let id = UUID()
    let urls: [URL]
    let destination: URL
    let move: Bool
    let conflictingURLs: [URL]
    let clearPasteboardOnSuccess: Bool

    var title: String {
      conflictingURLs.count == 1
        ? "同じ名前の項目があります"
        : "同じ名前の項目が \(conflictingURLs.count) 件あります"
    }

    var message: String {
      let names = conflictingURLs.prefix(3).map { "「\($0.lastPathComponent)」" }
      let remainder = conflictingURLs.count - names.count
      let nameList = names.joined(separator: "、") + (remainder > 0 ? " ほか \(remainder) 件" : "")
      let action = move ? "移動先" : "コピー先"
      let selfCopyOnly =
        !move
        && conflictingURLs.allSatisfy { source in
          NafiURL.sameLocation(
            source,
            NafiURL.isRemote(destination)
              ? NafiURL.appending(source.lastPathComponent, to: destination)
              : destination.appendingPathComponent(source.lastPathComponent)
          )
        }

      if selfCopyOnly {
        return "\(action)に\(nameList)があります。同じ場所へコピーするため、置き換えはできません。「両方残す」を選ぶと番号を付けてコピーします。"
      }

      return
        "\(action)に\(nameList)があります。「置き換える」は既存項目を入れ替え、「両方残す」は新しい項目へ番号を付けます。この選択は今回の同名項目すべてに適用されます。"
    }

    var canReplace: Bool {
      conflictingURLs.contains { source in
        !NafiURL.sameLocation(
          source,
          NafiURL.isRemote(destination)
            ? NafiURL.appending(source.lastPathComponent, to: destination)
            : destination.appendingPathComponent(source.lastPathComponent)
        )
      }
    }
  }

  let id: UUID
  let selectionController = FileSelectionController()

  @Published private(set) var currentURL: URL
  @Published private(set) var displayedItems: [FileItem] = []
  @Published private(set) var remoteProfileName: String?
  @Published private(set) var remoteProfileKind: ServerProfile.Kind?
  @Published var showHidden: Bool
  @Published var searchText = "" {
    didSet {
      if searchText != oldValue { scheduleSearch(debounceNanoseconds: 180_000_000) }
    }
  }
  @Published var searchScope: FileSearchScope = .currentFolder {
    didSet {
      if searchScope != oldValue { scheduleSearch() }
    }
  }
  @Published var searchFilterMode: FileSearchFilterMode = .all {
    didSet {
      if searchFilterMode != oldValue { scheduleSearch() }
    }
  }
  @Published var selectedSearchKinds: Set<FileSearchKind> = [] {
    didSet {
      if selectedSearchKinds != oldValue { scheduleSearch() }
    }
  }
  @Published var searchExtensionsText = "" {
    didSet {
      if searchExtensionsText != oldValue { scheduleSearch(debounceNanoseconds: 180_000_000) }
    }
  }
  @Published var sort: FileSort = .name {
    didSet {
      if sort != oldValue { scheduleRebuild() }
    }
  }
  @Published var sortDescending = false {
    didSet {
      if sortDescending != oldValue { scheduleRebuild() }
    }
  }
  @Published var viewMode: FileViewMode
  @Published var iconSize: Double = 64
  @Published private(set) var isLoading = false
  @Published private(set) var searchRootURL: URL?
  @Published private(set) var searchDidReachLimit = false
  @Published private(set) var operationLabel: String?
  @Published var errorMessage: String?
  @Published var prompt: Prompt?
  @Published var promptText = ""
  @Published var transferConflict: TransferConflictPrompt?

  private var allItems: [FileItem] = []
  private var searchItems: [FileItem] = []
  private var itemLookup: [URL: FileItem] = [:]
  private var displayedIndex: [URL: Int] = [:]
  private var backStack: [URL] = []
  private var forwardStack: [URL] = []
  private var selectionAnchor: URL?
  private var selectionAnchorScope: URL?
  private var supplementalItems: [URL: FileItem] = [:]
  private var cancellables = Set<AnyCancellable>()
  private var loadTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var rebuildTask: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?
  private var loadToken = UUID()
  private var searchToken = UUID()
  private var isDirectoryLoading = false
  private var isSearchLoading = false
  private var contentRevision = 0
  private var ignoreFileSystemNotificationsUntil = Date.distantPast
  private var pendingSelectionURL: URL?

  init(id: UUID = UUID(), initialURL: URL, showHidden: Bool = false, viewMode: FileViewMode = .list)
  {
    self.id = id
    self.currentURL = initialURL
    self.showHidden = showHidden
    self.viewMode = viewMode

    NotificationCenter.default.publisher(for: .nafiFileSystemDidChange)
      .sink { [weak self] notification in
        guard let directories = notification.userInfo?["directories"] as? [URL] else { return }
        Task { @MainActor [weak self] in
          guard let self, Date() >= self.ignoreFileSystemNotificationsUntil else { return }
          if self.isRecursiveSearchActive, let root = self.searchRootURL,
            directories.contains(where: {
              NafiURL.sameLocation($0, root) || NafiURL.isDescendant($0, of: root)
                || NafiURL.isDescendant(root, of: $0)
            })
          {
            self.scheduleSearch(debounceNanoseconds: 130_000_000)
            return
          }
          let current = NafiURL.normalized(self.currentURL)
          guard directories.contains(where: { NafiURL.sameLocation($0, current) }) else { return }
          self.scheduleReload()
        }
      }
      .store(in: &cancellables)
  }

  var title: String {
    if NafiURL.isRemote(currentURL) {
      let path = NafiURL.remotePath(in: currentURL) ?? "/"
      return path == "/" ? (remoteProfileName ?? "サーバー") : RemotePath.name(of: path)
    }
    return currentURL.lastPathComponent.isEmpty ? currentURL.path : currentURL.lastPathComponent
  }
  var isRemote: Bool { NafiURL.isRemote(currentURL) }
  var canOpenTerminalHere: Bool { !isRemote || remoteProfileKind == .sftp }
  var displayPath: String {
    guard isRemote else { return currentURL.path }
    let path = NafiURL.remotePath(in: currentURL) ?? "/"
    return remoteProfileName.map { "\($0):\(path)" } ?? path
  }
  var canGoBack: Bool { !backStack.isEmpty }
  var canGoForward: Bool { !forwardStack.isEmpty }
  var selectionCount: Int { selectionController.count }
  var isPerformingFileOperation: Bool { operationLabel != nil }
  var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var isRecursiveSearchActive: Bool { isSearchActive && searchScope.searchesRecursively }

  var searchFilter: FileSearchFilter {
    FileSearchFilter(
      mode: searchFilterMode,
      kinds: selectedSearchKinds,
      extensions: FileSearchFilter.parseExtensions(searchExtensionsText)
    )
  }

  var searchDescription: String {
    "\(searchScope.label)・\(searchFilter.summary)"
  }

  func searchLocationLabel(for item: FileItem) -> String {
    let parent = NafiURL.parent(of: item.url)
    if NafiURL.isRemote(parent) {
      let path = NafiURL.remotePath(in: parent) ?? "/"
      return remoteProfileName.map { "\($0):\(path)" } ?? path
    }
    return parent.path
  }

  var selectedItem: FileItem? {
    guard let url = selectionController.primaryURL else { return nil }
    return itemLookup[url] ?? supplementalItems[url]
  }

  var selectedItems: [FileItem] {
    selectionController.dragURLs.compactMap { itemLookup[$0] ?? supplementalItems[$0] }
  }

  func selectionFlag(for url: URL) -> SelectionFlag {
    selectionController.flag(for: url)
  }

  func item(for url: URL?) -> FileItem? {
    guard let url else { return nil }
    return itemLookup[url] ?? supplementalItems[url]
  }

  func clone() -> FilePaneModel {
    let clone = FilePaneModel(initialURL: currentURL, showHidden: showHidden, viewMode: viewMode)
    clone.sort = sort
    clone.sortDescending = sortDescending
    clone.iconSize = iconSize
    clone.searchScope = searchScope
    clone.searchFilterMode = searchFilterMode
    clone.selectedSearchKinds = selectedSearchKinds
    clone.searchExtensionsText = searchExtensionsText
    return clone
  }

  func load() {
    loadTask?.cancel()
    rebuildTask?.cancel()

    let directory = currentURL
    let showHidden = showHidden
    let recursiveSearch = isRecursiveSearchActive
    let query = recursiveSearch ? "" : searchText
    let filter = recursiveSearch ? FileSearchFilter.all : searchFilter
    let requestedSort = sort
    let descending = sortDescending
    let token = UUID()
    loadToken = token
    isDirectoryLoading = true
    updateLoadingState()

    loadTask = Task { [weak self] in
      let remoteProfile: ServerProfile?
      if let profileID = NafiURL.profileID(in: directory) {
        remoteProfile = await RemoteFileSystemRegistry.shared.profile(for: profileID)
      } else {
        remoteProfile = nil
      }
      let result: (items: [FileItem], displayed: [FileItem], error: String?)
      do {
        let items = try await UnifiedFileSystemService.contents(
          of: directory, showHidden: showHidden)
        let displayed = Self.arranged(
          items,
          query: query,
          filter: filter,
          sort: requestedSort,
          descending: descending
        )
        result = (items, displayed, nil)
      } catch is CancellationError {
        result = ([], [], nil)
      } catch {
        result = ([], [], error.localizedDescription)
      }

      guard let self, !Task.isCancelled, self.loadToken == token,
        NafiURL.sameLocation(self.currentURL, directory)
      else { return }

      self.isDirectoryLoading = false
      self.updateLoadingState()
      self.remoteProfileName = remoteProfile?.name
      self.remoteProfileKind = remoteProfile?.kind
      if let error = result.error {
        self.allItems = []
        self.itemLookup = [:]
        self.applyDisplayedItems([])
        self.selectionController.reset()
        self.errorMessage = error
        return
      }

      self.allItems = result.items
      self.rebuildItemLookup(using: self.isRecursiveSearchActive ? self.searchItems : result.items)
      self.contentRevision &+= 1

      if !recursiveSearch, !self.isRecursiveSearchActive, self.searchText == query,
        self.searchFilter == filter, self.sort == requestedSort,
        self.sortDescending == descending
      {
        self.applyDisplayedItems(result.displayed)
      } else if self.isRecursiveSearchActive {
        self.scheduleSearch()
      } else {
        self.scheduleRebuild()
      }

      let available = Set(
        (self.isRecursiveSearchActive ? self.searchItems : result.items).map(\.url)
      )
      let preserved = self.selectionController.selectedURLs.filter {
        self.supplementalItems[$0] != nil
      }
      self.selectionController.retain(available, plus: Set(preserved))
      self.supplementalItems = self.supplementalItems.filter {
        self.selectionController.contains($0.key)
      }

      if let pendingURL = self.pendingSelectionURL.map(NafiURL.normalized),
        let pendingItem = self.itemLookup[pendingURL]
      {
        self.selectionController.replace(with: [pendingItem.url], primary: pendingItem.url)
        self.selectionAnchor = pendingItem.url
        self.selectionAnchorScope = NafiURL.normalized(directory)
        self.pendingSelectionURL = nil
      }
      self.errorMessage = nil
    }
  }

  func navigate(to url: URL, recordingHistory: Bool = true) {
    let standardized = NafiURL.normalized(url)
    guard !NafiURL.sameLocation(standardized, currentURL) else {
      load()
      return
    }
    if recordingHistory {
      backStack.append(currentURL)
      forwardStack.removeAll(keepingCapacity: true)
    }

    currentURL = standardized
    searchTask?.cancel()
    allItems.removeAll(keepingCapacity: true)
    searchItems.removeAll(keepingCapacity: true)
    searchRootURL = nil
    searchDidReachLimit = false
    itemLookup.removeAll(keepingCapacity: true)
    applyDisplayedItems([])
    selectionController.reset()
    supplementalItems.removeAll(keepingCapacity: true)
    selectionAnchor = nil
    selectionAnchorScope = nil
    searchText = ""
    load()
  }

  func activate(_ item: FileItem) {
    if item.isDirectory && !item.isPackage {
      navigate(to: item.url)
      return
    }
    Task { [weak self] in
      do {
        let localURL = try await UnifiedFileSystemService.prepareLocalCopy(of: item.url)
        NSWorkspace.shared.open(localURL)
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func open(_ item: FileItem, withApplicationAt applicationURL: URL) {
    Task { [weak self] in
      do {
        let localURL = try await UnifiedFileSystemService.prepareLocalCopy(of: item.url)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
          [localURL],
          withApplicationAt: applicationURL,
          configuration: configuration,
          completionHandler: nil
        )
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func chooseApplicationAndOpen(_ item: FileItem) {
    guard let applicationURL = OpenWithApplicationCache.shared.chooseApplication() else { return }
    open(item, withApplicationAt: applicationURL)
  }

  func openSelected() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    if items.count == 1, let item = items.first {
      activate(item)
    } else {
      Task { [weak self] in
        do {
          for item in items {
            let localURL = try await UnifiedFileSystemService.prepareLocalCopy(of: item.url)
            NSWorkspace.shared.open(localURL)
          }
        } catch {
          self?.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func goBack() {
    guard let destination = backStack.popLast() else { return }
    forwardStack.append(currentURL)
    navigate(to: destination, recordingHistory: false)
  }

  func goForward() {
    guard let destination = forwardStack.popLast() else { return }
    backStack.append(currentURL)
    navigate(to: destination, recordingHistory: false)
  }

  func goUp() {
    let parent =
      NafiURL.isRemote(currentURL)
      ? NafiURL.parent(of: currentURL)
      : currentURL.deletingLastPathComponent()
    guard !NafiURL.sameLocation(parent, currentURL) else { return }
    navigate(to: parent)
  }

  var currentSelectionURLs: Set<URL> {
    selectionController.selectedURLs
  }

  func select(
    _ item: FileItem,
    modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
    orderedItems: [FileItem]? = nil,
    scope: URL? = nil
  ) {
    supplementalItems[item.url] = item
    let modifiers = modifiers.intersection([.command, .shift])
    let resolvedScope = NafiURL.normalized(scope ?? currentURL)

    if modifiers.contains(.shift) {
      let ordered = orderedItems ?? displayedItems
      let anchor = rangeAnchor(
        in: ordered,
        scope: resolvedScope,
        usesDisplayedIndex: orderedItems == nil
      )

      if let anchor,
        let anchorIndex = index(of: anchor, in: ordered, usesDisplayedIndex: orderedItems == nil),
        let itemIndex = index(of: item.url, in: ordered, usesDisplayedIndex: orderedItems == nil)
      {
        let lower = min(anchorIndex, itemIndex)
        let upper = max(anchorIndex, itemIndex)
        let rangeItems = Array(ordered[lower...upper])
        let ranged = Set(rangeItems.map(\.url))
        for rangeItem in rangeItems {
          supplementalItems[rangeItem.url] = rangeItem
        }

        if modifiers.contains(.command) {
          selectionController.formUnion(ranged, primary: item.url)
        } else {
          selectionController.replace(with: ranged, primary: item.url)
        }
      } else {
        selectionController.replace(with: [item.url], primary: item.url)
      }

      if selectionAnchorScope != resolvedScope || selectionAnchor == nil
        || anchor != selectionAnchor
      {
        selectionAnchor = anchor ?? item.url
        selectionAnchorScope = resolvedScope
      }
      pruneSupplementalSelection()
      return
    }

    if modifiers.contains(.command) {
      if selectionController.contains(item.url) {
        var next = selectionController.selectedURLs
        next.remove(item.url)
        let ordered = orderedItems ?? displayedItems
        let primary =
          selectionController.primaryURL.flatMap {
            $0 != item.url && next.contains($0) ? $0 : nil
          } ?? nearestSelectedURL(to: item.url, in: ordered, selected: next)
        selectionController.replace(with: next, primary: primary)
        supplementalItems[item.url] = nil
      } else {
        selectionController.formUnion([item.url], primary: item.url)
      }
      selectionAnchor = item.url
      selectionAnchorScope = resolvedScope
      pruneSupplementalSelection()
      return
    }

    selectionController.replace(with: [item.url], primary: item.url)
    selectionAnchor = item.url
    selectionAnchorScope = resolvedScope
    pruneSupplementalSelection()
  }

  func prepareContextMenu(for item: FileItem, scope: URL? = nil) {
    supplementalItems[item.url] = item
    if selectionController.contains(item.url) {
      selectionController.replace(
        with: selectionController.selectedURLs,
        primary: item.url
      )
      return
    }

    selectionController.replace(with: [item.url], primary: item.url)
    selectionAnchor = item.url
    selectionAnchorScope = NafiURL.normalized(scope ?? currentURL)
    pruneSupplementalSelection()
  }

  func ensureSelected(_ item: FileItem) {
    prepareContextMenu(for: item)
  }

  func updateMarqueeSelection(
    _ intersecting: Set<URL>,
    intersectingItems: [FileItem],
    baseSelection: Set<URL>,
    modifiers: NSEvent.ModifierFlags,
    primary: URL?
  ) {
    let modifiers = modifiers.intersection([.command, .shift])
    let next: Set<URL>

    if modifiers.contains(.command), !modifiers.contains(.shift) {
      next = baseSelection.symmetricDifference(intersecting)
    } else if modifiers.contains(.command) || modifiers.contains(.shift) {
      next = baseSelection.union(intersecting)
    } else {
      next = intersecting
    }

    for item in intersectingItems where next.contains(item.url) {
      supplementalItems[item.url] = item
    }

    let resolvedPrimary =
      primary.flatMap { next.contains($0) ? $0 : nil }
      ?? selectionController.primaryURL.flatMap { next.contains($0) ? $0 : nil }
      ?? next.first
    selectionController.replace(with: next, primary: resolvedPrimary)
    pruneSupplementalSelection()
  }

  func finishMarqueeSelection(anchor: URL?, scope: URL) {
    if let anchor {
      selectionAnchor = anchor
      selectionAnchorScope = NafiURL.normalized(scope)
    } else if selectionController.count == 0 {
      selectionAnchor = nil
      selectionAnchorScope = nil
    }
  }

  func clearSelection() {
    selectionController.removeAll()
    supplementalItems.removeAll(keepingCapacity: true)
    selectionAnchor = nil
    selectionAnchorScope = nil
  }

  func selectAll() {
    let urls = Set(displayedItems.map(\.url))
    selectionController.replace(with: urls, primary: displayedItems.first?.url)
    selectionAnchor = displayedItems.first?.url
    selectionAnchorScope = NafiURL.normalized(currentURL)
  }

  func moveSelection(by offset: Int) {
    guard !displayedItems.isEmpty else { return }
    let currentIndex = selectionController.primaryURL.flatMap { displayedIndex[$0] }
    let destinationIndex: Int
    if let currentIndex {
      destinationIndex = min(max(currentIndex + offset, 0), displayedItems.count - 1)
    } else {
      destinationIndex = offset >= 0 ? 0 : displayedItems.count - 1
    }

    let modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags.contains(.shift) ? [.shift] : []
    select(displayedItems[destinationIndex], modifiers: modifiers)
  }

  private func rangeAnchor(
    in orderedItems: [FileItem],
    scope: URL,
    usesDisplayedIndex: Bool
  ) -> URL? {
    if selectionAnchorScope == scope, let selectionAnchor {
      let exists =
        usesDisplayedIndex
        ? displayedIndex[selectionAnchor] != nil
        : orderedItems.contains(where: { $0.url == selectionAnchor })
      if exists { return selectionAnchor }
    }

    if let primary = selectionController.primaryURL {
      let exists =
        usesDisplayedIndex
        ? displayedIndex[primary] != nil
        : orderedItems.contains(where: { $0.url == primary })
      if exists { return primary }
    }

    return nil
  }

  private func index(of url: URL, in items: [FileItem], usesDisplayedIndex: Bool) -> Int? {
    if usesDisplayedIndex {
      return displayedIndex[url]
    }
    return items.firstIndex(where: { $0.url == url })
  }

  private func nearestSelectedURL(
    to url: URL,
    in orderedItems: [FileItem],
    selected: Set<URL>
  ) -> URL? {
    guard let index = orderedItems.firstIndex(where: { $0.url == url }) else {
      return selected.first
    }

    for distance in 1..<orderedItems.count {
      let after = index + distance
      if after < orderedItems.count, selected.contains(orderedItems[after].url) {
        return orderedItems[after].url
      }

      let before = index - distance
      if before >= 0, selected.contains(orderedItems[before].url) {
        return orderedItems[before].url
      }
    }

    return selected.first
  }

  private func pruneSupplementalSelection() {
    supplementalItems = supplementalItems.filter { url, _ in
      selectionController.contains(url) && itemLookup[url] == nil
    }
  }

  func requestNewFile() {
    promptText = "名称未設定.txt"
    prompt = .newFile
  }

  func requestNewFolder() {
    promptText = "名称未設定フォルダ"
    prompt = .newFolder
  }

  func requestRename(_ url: URL) {
    promptText = url.lastPathComponent
    prompt = .rename(url)
  }

  @discardableResult
  func requestRenameSelected() -> Bool {
    guard let url = selectedItem?.url else { return false }
    requestRename(url)
    return true
  }

  func selectAfterNextLoad(_ url: URL) {
    let standardized = NafiURL.normalized(url)
    if let item = itemLookup[standardized] ?? supplementalItems[standardized] {
      selectionController.replace(with: [item.url], primary: item.url)
      selectionAnchor = item.url
      selectionAnchorScope = NafiURL.normalized(currentURL)
      pendingSelectionURL = nil
      return
    }
    pendingSelectionURL = standardized
  }

  func revealExternalItem(_ url: URL) {
    let standardized = NafiURL.normalized(url)
    let parent =
      NafiURL.isRemote(standardized)
      ? NafiURL.parent(of: standardized)
      : standardized.deletingLastPathComponent().standardizedFileURL
    pendingSelectionURL = standardized
    if NafiURL.normalized(currentURL) == parent {
      load()
    } else {
      navigate(to: parent)
    }
  }

  func requestTagsForSelection() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    let commonTags = items.dropFirst().reduce(Set(items[0].tagNames)) { partial, item in
      partial.intersection(Set(item.tagNames))
    }
    promptText = commonTags.sorted().joined(separator: ", ")
    prompt = .tags(items.map(\.url))
  }

  func commitPrompt() {
    guard let prompt else { return }
    self.prompt = nil
    let text = promptText

    switch prompt {
    case .newFile:
      let directory = currentURL
      runAsyncOperation(label: "ファイルを作成中") {
        [try await UnifiedFileSystemService.createFile(named: text, in: directory)]
      }
    case .newFolder:
      let directory = currentURL
      runAsyncOperation(label: "フォルダを作成中") {
        [try await UnifiedFileSystemService.createFolder(named: text, in: directory)]
      }
    case .rename(let url):
      runAsyncOperation(label: "名前を変更中") {
        [try await UnifiedFileSystemService.rename(url, to: text)]
      }
    case .tags(let urls):
      guard urls.allSatisfy(\.isFileURL) else {
        errorMessage = "サーバー上のタグは接続先のファイルシステムでサポートされていません。"
        return
      }
      let tags = text.replacingOccurrences(of: "、", with: ",")
        .split(separator: ",").map(String.init)
      runOperation(label: "タグを更新中", selectsResults: false) {
        try FileSystemService.setTags(tags, for: urls)
        return []
      }
    }
  }

  func duplicateSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    runAsyncOperation(label: "複製中") {
      var results: [URL] = []
      for url in urls { results.append(try await UnifiedFileSystemService.duplicate(url)) }
      return results
    }
  }

  func createAliasSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    guard urls.allSatisfy(\.isFileURL) else {
      errorMessage = "サーバー上ではmacOSエイリアスを作成できません。"
      return
    }
    runOperation(label: "エイリアスを作成中") {
      try urls.map { try FileSystemService.createAlias(to: $0) }
    }
  }

  func compressSelection() {
    let urls = selectedItems.map(\.url)
    let directory = currentURL
    guard !urls.isEmpty else { return }
    runAsyncOperation(label: "圧縮中") {
      [try await UnifiedFileSystemService.compress(urls, in: directory)]
    }
  }

  func trashSelection() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    runAsyncOperation(label: "削除中", selectsResults: false, clearsSelection: true) {
      for item in items {
        try await UnifiedFileSystemService.remove(item.url, isDirectory: item.isDirectory)
      }
      return []
    }
  }

  func transferItems(
    _ urls: [URL],
    to destination: URL,
    move: Bool,
    clearPasteboardOnSuccess: Bool = false
  ) {
    guard operationLabel == nil else {
      errorMessage = "別のファイル操作が進行中です。"
      return
    }

    let destinationURL = NafiURL.normalized(destination)
    let safeURLs = urls.filter { url in
      let source = NafiURL.normalized(url)
      guard !NafiURL.sameLocation(source, destinationURL),
        !NafiURL.isDescendant(destinationURL, of: source)
      else { return false }
      let parent =
        NafiURL.isRemote(source)
        ? NafiURL.parent(of: source)
        : source.deletingLastPathComponent()
      if move, NafiURL.sameLocation(parent, destinationURL) { return false }
      return true
    }
    guard !safeURLs.isEmpty else {
      if clearPasteboardOnSuccess { NSPasteboard.general.clearContents() }
      return
    }

    Task { [weak self] in
      let conflicts = await UnifiedFileSystemService.conflictingItems(
        safeURLs, in: destinationURL)
      guard let self else { return }
      if !conflicts.isEmpty {
        self.transferConflict = TransferConflictPrompt(
          urls: safeURLs,
          destination: destinationURL,
          move: move,
          conflictingURLs: conflicts,
          clearPasteboardOnSuccess: clearPasteboardOnSuccess
        )
        return
      }
      self.performTransfer(
        safeURLs,
        to: destinationURL,
        move: move,
        resolution: .keepBoth,
        clearPasteboardOnSuccess: clearPasteboardOnSuccess
      )
    }
  }

  func resolveTransferConflict(_ resolution: TransferConflictResolution) {
    guard let conflict = transferConflict else { return }
    transferConflict = nil
    performTransfer(
      conflict.urls,
      to: conflict.destination,
      move: conflict.move,
      resolution: resolution,
      clearPasteboardOnSuccess: conflict.clearPasteboardOnSuccess
    )
  }

  func cancelTransferConflict() {
    transferConflict = nil
  }

  private func performTransfer(
    _ urls: [URL],
    to destination: URL,
    move: Bool,
    resolution: TransferConflictResolution,
    clearPasteboardOnSuccess: Bool
  ) {
    let existingItemPolicy: UnifiedFileSystemService.ExistingItemPolicy =
      resolution == .replace ? .replace : .keepBoth

    runAsyncOperation(
      label: move ? "移動中" : "コピー中",
      clearPasteboardOnSuccess: clearPasteboardOnSuccess
    ) {
      try await UnifiedFileSystemService.transfer(
        urls, to: destination, move: move, policy: existingItemPolicy)
    }
  }

  func acceptDrop(_ providers: [NSItemProvider], to destination: URL) -> Bool {
    guard DragPayloadProvider.canLoadFileURLs(from: providers) else { return false }

    // Internal and Finder drags move by default. Hold Option while dropping to copy instead.
    let move = !NSEvent.modifierFlags.contains(.option)
    DragPayloadProvider.loadFileURLs(from: providers) { [weak self] urls in
      guard !urls.isEmpty else { return }
      Task { @MainActor [weak self] in
        self?.transferItems(urls, to: destination, move: move)
      }
    }
    return true
  }

  func dragPayload(for item: FileItem) -> FileDragPayload {
    FileDragPayload(
      urls: selectionController.contains(item.url) ? selectionController.dragURLs : [item.url])
  }

  func copySelection(cut: Bool = false) {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let localURLs = urls.filter(\.isFileURL)
    if !localURLs.isEmpty { pasteboard.writeObjects(localURLs.map { $0 as NSURL }) }
    if let data = try? JSONEncoder().encode(FileDragPayload(urls: urls)) {
      pasteboard.setData(
        data,
        forType: NSPasteboard.PasteboardType(UTType.nafiFileCollection.identifier)
      )
    }
    pasteboard.setString(
      cut ? "cut" : "copy", forType: NSPasteboard.PasteboardType("app.nafi.transfer-mode"))
  }

  func paste() {
    let pasteboard = NSPasteboard.general
    let urls: [URL]
    if let data = pasteboard.data(
      forType: NSPasteboard.PasteboardType(UTType.nafiFileCollection.identifier)),
      let payload = try? JSONDecoder().decode(FileDragPayload.self, from: data)
    {
      urls = payload.urls
    } else if let objects = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
    {
      urls = objects.map { $0 as URL }
    } else {
      return
    }
    let move =
      pasteboard.string(forType: NSPasteboard.PasteboardType("app.nafi.transfer-mode")) == "cut"
    transferItems(
      urls,
      to: currentURL,
      move: move,
      clearPasteboardOnSuccess: move
    )
  }

  func previewSelected() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    Task { [weak self] in
      do {
        var localURLs: [URL] = []
        for item in items {
          localURLs.append(try await UnifiedFileSystemService.prepareLocalCopy(of: item.url))
        }
        QuickLookService.shared.show(urls: localURLs, selected: localURLs.first)
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func openTerminalHere(at location: URL? = nil) {
    let requested = location ?? currentURL
    let target: URL
    if let item = item(for: requested), !item.isDirectory {
      target =
        NafiURL.isRemote(requested)
        ? NafiURL.parent(of: requested)
        : requested.deletingLastPathComponent()
    } else {
      target = requested
    }
    Task { [weak self] in
      do {
        try await TerminalApplicationService.open(at: target)
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func copySelectedPath() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    Task {
      var paths: [String] = []
      for item in items {
        paths.append(await UnifiedFileSystemService.displayPath(for: item.url))
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
  }

  func revealSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    guard urls.allSatisfy(\.isFileURL) else {
      errorMessage = "リモート項目はnafi内の現在位置に表示されています。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func arrange(_ items: [FileItem]) async -> [FileItem] {
    let query = isRecursiveSearchActive ? "" : searchText
    let filter = isRecursiveSearchActive ? FileSearchFilter.all : searchFilter
    let requestedSort = sort
    let descending = sortDescending
    return await Task.detached(priority: .userInitiated) {
      Self.arranged(
        items,
        query: query,
        filter: filter,
        sort: requestedSort,
        descending: descending
      )
    }.value
  }

  nonisolated static func arranged(
    _ items: [FileItem],
    query: String,
    filter: FileSearchFilter,
    sort: FileSort,
    descending: Bool
  ) -> [FileItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )

    var directories: [FileItem] = []
    var files: [FileItem] = []
    directories.reserveCapacity(items.count / 4)
    files.reserveCapacity(items.count)

    for item in items
    where (normalizedQuery.isEmpty || item.normalizedName.contains(normalizedQuery))
      && (normalizedQuery.isEmpty || filter.matches(item))
    {
      if item.isDirectory {
        directories.append(item)
      } else {
        files.append(item)
      }
    }

    @Sendable func comesBefore(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
      let comparison: ComparisonResult
      switch sort {
      case .name:
        comparison = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
      case .modified:
        let left = lhs.modificationDate ?? .distantPast
        let right = rhs.modificationDate ?? .distantPast
        comparison =
          left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
      case .size:
        let left = lhs.fileSize ?? 0
        let right = rhs.fileSize ?? 0
        comparison =
          left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
      case .kind:
        comparison = lhs.normalizedKind.localizedStandardCompare(rhs.normalizedKind)
      }

      if comparison == .orderedSame {
        return lhs.normalizedName.localizedStandardCompare(rhs.normalizedName) == .orderedAscending
      }
      return descending ? comparison == .orderedDescending : comparison == .orderedAscending
    }

    directories.sort(by: comesBefore)
    files.sort(by: comesBefore)
    directories.append(contentsOf: files)
    return directories
  }

  private func applyDisplayedItems(_ items: [FileItem]) {
    var index: [URL: Int] = [:]
    index.reserveCapacity(items.count)
    for (offset, item) in items.enumerated() { index[item.url] = offset }
    displayedIndex = index
    displayedItems = items
  }

  private func scheduleRebuild(debounceNanoseconds: UInt64 = 0) {
    rebuildTask?.cancel()
    let recursiveSearch = isRecursiveSearchActive
    let items = recursiveSearch ? searchItems : allItems
    let query = recursiveSearch ? "" : searchText
    let filter = recursiveSearch ? FileSearchFilter.all : searchFilter
    let requestedSort = sort
    let descending = sortDescending
    let revision = contentRevision

    rebuildTask = Task { [weak self] in
      if debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
      }
      guard !Task.isCancelled else { return }
      let displayed = await Task.detached(priority: .userInitiated) {
        Self.arranged(
          items,
          query: query,
          filter: filter,
          sort: requestedSort,
          descending: descending
        )
      }.value
      guard let self, !Task.isCancelled, self.contentRevision == revision,
        self.isRecursiveSearchActive == recursiveSearch,
        recursiveSearch || self.searchText == query,
        recursiveSearch || self.searchFilter == filter, self.sort == requestedSort,
        self.sortDescending == descending
      else { return }
      self.applyDisplayedItems(displayed)
    }
  }

  private func scheduleSearch(debounceNanoseconds: UInt64 = 0) {
    searchTask?.cancel()
    rebuildTask?.cancel()

    guard isSearchActive else {
      isSearchLoading = false
      updateLoadingState()
      searchItems.removeAll(keepingCapacity: true)
      searchRootURL = nil
      searchDidReachLimit = false
      rebuildItemLookup(using: allItems)
      contentRevision &+= 1
      scheduleRebuild()
      return
    }

    guard isRecursiveSearchActive else {
      isSearchLoading = false
      updateLoadingState()
      searchItems.removeAll(keepingCapacity: true)
      searchRootURL = nil
      searchDidReachLimit = false
      rebuildItemLookup(using: allItems)
      contentRevision &+= 1
      scheduleRebuild(debounceNanoseconds: debounceNanoseconds)
      return
    }

    let query = searchText
    let directory = currentURL
    let scope = searchScope
    let showHidden = showHidden
    let filter = searchFilter
    let token = UUID()
    searchToken = token
    isSearchLoading = true
    updateLoadingState()

    searchTask = Task { [weak self] in
      if debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
      }
      guard !Task.isCancelled else { return }

      let result: Result<FileSearchResult, Error>
      do {
        result = .success(
          try await FileSearchService.search(
            query: query,
            from: directory,
            scope: scope,
            showHidden: showHidden,
            filter: filter
          )
        )
      } catch {
        result = .failure(error)
      }

      guard let self, !Task.isCancelled, self.searchToken == token,
        NafiURL.sameLocation(self.currentURL, directory), self.searchText == query,
        self.searchScope == scope, self.showHidden == showHidden, self.searchFilter == filter
      else { return }

      self.isSearchLoading = false
      self.updateLoadingState()
      switch result {
      case .failure(let error):
        if error is CancellationError { return }
        self.searchItems = []
        self.searchRootURL = nil
        self.searchDidReachLimit = false
        self.rebuildItemLookup(using: [])
        self.applyDisplayedItems([])
        self.selectionController.reset()
        self.errorMessage = error.localizedDescription
      case .success(let searchResult):
        self.searchItems = searchResult.items
        self.searchRootURL = searchResult.rootURL
        self.searchDidReachLimit = searchResult.didReachLimit
        self.rebuildItemLookup(using: searchResult.items)
        self.contentRevision &+= 1
        self.scheduleRebuild()
        self.selectionController.retain(Set(searchResult.items.map(\.url)))
        self.errorMessage = nil
      }
    }
  }

  private func rebuildItemLookup(using items: [FileItem]) {
    var lookup: [URL: FileItem] = [:]
    lookup.reserveCapacity(items.count)
    for item in items { lookup[item.url] = item }
    itemLookup = lookup
  }

  private func updateLoadingState() {
    isLoading = isDirectoryLoading || isSearchLoading
  }

  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 130_000_000)
      guard let self, !Task.isCancelled else { return }
      self.load()
    }
  }

  private func runAsyncOperation(
    label: String,
    selectsResults: Bool = true,
    clearsSelection: Bool = false,
    clearPasteboardOnSuccess: Bool = false,
    operation: @escaping @Sendable () async throws -> [URL]
  ) {
    guard operationLabel == nil else {
      errorMessage = "別のファイル操作が進行中です。"
      return
    }

    operationLabel = label
    Task { [weak self] in
      let result: Result<[URL], Error>
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }

      guard let self else { return }
      self.operationLabel = nil
      switch result {
      case .failure(let error):
        self.errorMessage = error.localizedDescription
      case .success(let urls):
        self.ignoreFileSystemNotificationsUntil = Date().addingTimeInterval(0.55)
        if clearPasteboardOnSuccess { NSPasteboard.general.clearContents() }
        if selectsResults {
          self.selectionController.replace(with: Set(urls), primary: urls.first)
          self.selectionAnchor = urls.first
          self.selectionAnchorScope = NafiURL.normalized(self.currentURL)
        } else if clearsSelection {
          self.selectionController.removeAll()
          self.selectionAnchor = nil
          self.selectionAnchorScope = nil
        }
        self.load()
      }
    }
  }

  private func runOperation(
    label: String,
    selectsResults: Bool = true,
    clearsSelection: Bool = false,
    clearPasteboardOnSuccess: Bool = false,
    operation: @escaping @Sendable () throws -> [URL]
  ) {
    guard operationLabel == nil else {
      errorMessage = "別のファイル操作が進行中です。"
      return
    }

    operationLabel = label
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        do {
          return (urls: try operation(), error: Optional<String>.none)
        } catch {
          return (urls: [URL](), error: error.localizedDescription)
        }
      }.value

      guard let self else { return }
      self.operationLabel = nil
      if let error = result.error {
        self.errorMessage = error
        return
      }

      self.ignoreFileSystemNotificationsUntil = Date().addingTimeInterval(0.55)
      if clearPasteboardOnSuccess {
        NSPasteboard.general.clearContents()
      }
      if selectsResults {
        self.selectionController.replace(with: Set(result.urls), primary: result.urls.first)
        self.selectionAnchor = result.urls.first
        self.selectionAnchorScope = NafiURL.normalized(self.currentURL)
      } else if clearsSelection {
        self.selectionController.removeAll()
        self.selectionAnchor = nil
        self.selectionAnchorScope = nil
      }
      self.load()
    }
  }
}
