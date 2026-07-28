import AppKit
import Combine
import Foundation

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
          source.standardizedFileURL
            == destination.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        }

      if selfCopyOnly {
        return "\(action)に\(nameList)があります。同じ場所へコピーするため、置き換えはできません。「両方残す」を選ぶと番号を付けてコピーします。"
      }

      return
        "\(action)に\(nameList)があります。「置き換える」は既存項目を入れ替え、「両方残す」は新しい項目へ番号を付けます。この選択は今回の同名項目すべてに適用されます。"
    }

    var canReplace: Bool {
      conflictingURLs.contains { source in
        source.standardizedFileURL
          != destination.appendingPathComponent(source.lastPathComponent).standardizedFileURL
      }
    }
  }

  let id: UUID
  let selectionController = FileSelectionController()

  @Published private(set) var currentURL: URL
  @Published private(set) var displayedItems: [FileItem] = []
  @Published var showHidden: Bool
  @Published var searchText = "" {
    didSet {
      if searchText != oldValue { scheduleRebuild(debounceNanoseconds: 110_000_000) }
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
  @Published var isLoading = false
  @Published private(set) var operationLabel: String?
  @Published var errorMessage: String?
  @Published var prompt: Prompt?
  @Published var promptText = ""
  @Published var transferConflict: TransferConflictPrompt?

  private var allItems: [FileItem] = []
  private var itemLookup: [URL: FileItem] = [:]
  private var displayedIndex: [URL: Int] = [:]
  private var backStack: [URL] = []
  private var forwardStack: [URL] = []
  private var selectionAnchor: URL?
  private var selectionAnchorScope: URL?
  private var supplementalItems: [URL: FileItem] = [:]
  private var cancellables = Set<AnyCancellable>()
  private var loadTask: Task<Void, Never>?
  private var rebuildTask: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?
  private var loadToken = UUID()
  private var contentRevision = 0
  private var ignoreFileSystemNotificationsUntil = Date.distantPast
  private var pendingSelectionURL: URL?

  init(id: UUID = UUID(), initialURL: URL, showHidden: Bool = false, viewMode: FileViewMode = .list)
  {
    self.id = id
    self.currentURL = initialURL
    self.showHidden = showHidden
    self.viewMode = viewMode

    NotificationCenter.default.publisher(for: .namiFileSystemDidChange)
      .sink { [weak self] notification in
        guard let directories = notification.userInfo?["directories"] as? [URL] else { return }
        Task { @MainActor [weak self] in
          guard let self, Date() >= self.ignoreFileSystemNotificationsUntil else { return }
          let current = self.currentURL.standardizedFileURL
          guard directories.contains(where: { $0.standardizedFileURL == current }) else { return }
          self.scheduleReload()
        }
      }
      .store(in: &cancellables)
  }

  var title: String {
    currentURL.lastPathComponent.isEmpty ? currentURL.path : currentURL.lastPathComponent
  }
  var canGoBack: Bool { !backStack.isEmpty }
  var canGoForward: Bool { !forwardStack.isEmpty }
  var selectionCount: Int { selectionController.count }
  var isPerformingFileOperation: Bool { operationLabel != nil }

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
    return clone
  }

  func load() {
    loadTask?.cancel()
    rebuildTask?.cancel()

    let directory = currentURL
    let showHidden = showHidden
    let query = searchText
    let requestedSort = sort
    let descending = sortDescending
    let token = UUID()
    loadToken = token
    isLoading = true

    loadTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        do {
          let items = try FileSystemService.contents(of: directory, showHidden: showHidden)
          let displayed = Self.arranged(
            items, query: query, sort: requestedSort, descending: descending)
          return (items: items, displayed: displayed, error: Optional<String>.none)
        } catch is CancellationError {
          return (items: [FileItem](), displayed: [FileItem](), error: Optional<String>.none)
        } catch {
          return (items: [FileItem](), displayed: [FileItem](), error: error.localizedDescription)
        }
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }

      guard let self, !Task.isCancelled, self.loadToken == token,
        self.currentURL.standardizedFileURL == directory.standardizedFileURL
      else { return }

      self.isLoading = false
      if let error = result.error {
        self.allItems = []
        self.itemLookup = [:]
        self.applyDisplayedItems([])
        self.selectionController.reset()
        self.errorMessage = error
        return
      }

      self.allItems = result.items
      var lookup: [URL: FileItem] = [:]
      lookup.reserveCapacity(result.items.count)
      for item in result.items { lookup[item.url] = item }
      self.itemLookup = lookup
      self.contentRevision &+= 1

      if self.searchText == query && self.sort == requestedSort
        && self.sortDescending == descending
      {
        self.applyDisplayedItems(result.displayed)
      } else {
        self.scheduleRebuild()
      }

      let available = Set(result.items.map(\.url))
      let preserved = self.selectionController.selectedURLs.filter {
        self.supplementalItems[$0] != nil
      }
      self.selectionController.retain(available, plus: Set(preserved))
      self.supplementalItems = self.supplementalItems.filter {
        self.selectionController.contains($0.key)
      }

      if let pendingURL = self.pendingSelectionURL?.standardizedFileURL,
        let pendingItem = lookup[pendingURL]
      {
        self.selectionController.replace(with: [pendingItem.url], primary: pendingItem.url)
        self.selectionAnchor = pendingItem.url
        self.selectionAnchorScope = directory.standardizedFileURL
        self.pendingSelectionURL = nil
      }
      self.errorMessage = nil
    }
  }

  func navigate(to url: URL, recordingHistory: Bool = true) {
    let standardized = url.standardizedFileURL
    guard standardized != currentURL.standardizedFileURL else {
      load()
      return
    }
    if recordingHistory {
      backStack.append(currentURL)
      forwardStack.removeAll(keepingCapacity: true)
    }

    currentURL = standardized
    allItems.removeAll(keepingCapacity: true)
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
    } else {
      NSWorkspace.shared.open(item.url)
    }
  }

  func openSelected() {
    let items = selectedItems
    guard !items.isEmpty else { return }
    if items.count == 1, let item = items.first {
      activate(item)
    } else {
      for item in items {
        NSWorkspace.shared.open(item.url)
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
    let parent = currentURL.deletingLastPathComponent()
    guard parent.path != currentURL.path else { return }
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
    let resolvedScope = (scope ?? currentURL).standardizedFileURL

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
    selectionAnchorScope = (scope ?? currentURL).standardizedFileURL
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
      selectionAnchorScope = scope.standardizedFileURL
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
    selectionAnchorScope = currentURL.standardizedFileURL
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
    let standardized = url.standardizedFileURL
    if let item = itemLookup[standardized] ?? supplementalItems[standardized] {
      selectionController.replace(with: [item.url], primary: item.url)
      selectionAnchor = item.url
      selectionAnchorScope = currentURL.standardizedFileURL
      pendingSelectionURL = nil
      return
    }
    pendingSelectionURL = standardized
  }

  func revealExternalItem(_ url: URL) {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent().standardizedFileURL
    pendingSelectionURL = standardized
    if currentURL.standardizedFileURL == parent {
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
      runOperation(label: "ファイルを作成中") {
        [try FileSystemService.createFile(named: text, in: directory)]
      }
    case .newFolder:
      let directory = currentURL
      runOperation(label: "フォルダを作成中") {
        [try FileSystemService.createFolder(named: text, in: directory)]
      }
    case .rename(let url):
      runOperation(label: "名前を変更中") {
        [try FileSystemService.rename(url, to: text)]
      }
    case .tags(let urls):
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
    runOperation(label: "複製中") {
      try urls.map { try FileSystemService.duplicate($0) }
    }
  }

  func createAliasSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    runOperation(label: "エイリアスを作成中") {
      try urls.map { try FileSystemService.createAlias(to: $0) }
    }
  }

  func compressSelection() {
    let urls = selectedItems.map(\.url)
    let directory = currentURL
    guard !urls.isEmpty else { return }
    runOperation(label: "圧縮中") {
      [try FileSystemService.compress(urls, in: directory)]
    }
  }

  func trashSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    runOperation(label: "ゴミ箱へ移動中", selectsResults: false, clearsSelection: true) {
      for url in urls { try FileSystemService.trash(url) }
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

    let destinationURL = destination.standardizedFileURL
    let safeURLs = urls.filter { url in
      let source = url.standardizedFileURL
      guard source != destinationURL, !destinationURL.path.hasPrefix(source.path + "/") else {
        return false
      }
      if move, source.deletingLastPathComponent() == destinationURL { return false }
      return true
    }
    guard !safeURLs.isEmpty else {
      if clearPasteboardOnSuccess { NSPasteboard.general.clearContents() }
      return
    }

    let conflicts = safeURLs.filter { url in
      let candidate = destination.appendingPathComponent(url.lastPathComponent)
      return FileManager.default.fileExists(atPath: candidate.path)
    }

    if !conflicts.isEmpty {
      transferConflict = TransferConflictPrompt(
        urls: safeURLs,
        destination: destination,
        move: move,
        conflictingURLs: conflicts,
        clearPasteboardOnSuccess: clearPasteboardOnSuccess
      )
      return
    }

    performTransfer(
      safeURLs,
      to: destination,
      move: move,
      resolution: .keepBoth,
      clearPasteboardOnSuccess: clearPasteboardOnSuccess
    )
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
    let existingItemPolicy: FileSystemService.ExistingItemPolicy =
      resolution == .replace ? .replace : .keepBoth

    runOperation(
      label: move ? "移動中" : "コピー中",
      clearPasteboardOnSuccess: clearPasteboardOnSuccess
    ) {
      try urls.map { url in
        move
          ? try FileSystemService.move(
            url, to: destination, existingItemPolicy: existingItemPolicy)
          : try FileSystemService.copy(
            url, to: destination, existingItemPolicy: existingItemPolicy)
      }
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
    pasteboard.writeObjects(urls.map { $0 as NSURL })
    pasteboard.setString(
      cut ? "cut" : "copy", forType: NSPasteboard.PasteboardType("app.nami.transfer-mode"))
  }

  func paste() {
    let pasteboard = NSPasteboard.general
    guard
      let objects = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
    else { return }
    let urls = objects.compactMap { $0 as URL }
    let move =
      pasteboard.string(forType: NSPasteboard.PasteboardType("app.nami.transfer-mode")) == "cut"
    transferItems(
      urls,
      to: currentURL,
      move: move,
      clearPasteboardOnSuccess: move
    )
  }

  func previewSelected() {
    let urls = selectedItems.map(\.url)
    QuickLookService.shared.show(urls: urls, selected: selectedItem?.url)
  }

  func copySelectedPath() {
    let paths = selectedItems.map { $0.url.path }.joined(separator: "\n")
    guard !paths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths, forType: .string)
  }

  func revealSelection() {
    let urls = selectedItems.map(\.url)
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func arrange(_ items: [FileItem]) async -> [FileItem] {
    let query = searchText
    let requestedSort = sort
    let descending = sortDescending
    return await Task.detached(priority: .userInitiated) {
      Self.arranged(items, query: query, sort: requestedSort, descending: descending)
    }.value
  }

  nonisolated static func arranged(
    _ items: [FileItem], query: String, sort: FileSort, descending: Bool
  ) -> [FileItem] {
    let normalizedQuery = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "ja_JP")
    )

    var directories: [FileItem] = []
    var files: [FileItem] = []
    directories.reserveCapacity(items.count / 4)
    files.reserveCapacity(items.count)

    for item in items where normalizedQuery.isEmpty || item.normalizedName.contains(normalizedQuery)
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
    let items = allItems
    let query = searchText
    let requestedSort = sort
    let descending = sortDescending
    let revision = contentRevision

    rebuildTask = Task { [weak self] in
      if debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
      }
      guard !Task.isCancelled else { return }
      let displayed = await Task.detached(priority: .userInitiated) {
        Self.arranged(items, query: query, sort: requestedSort, descending: descending)
      }.value
      guard let self, !Task.isCancelled, self.contentRevision == revision,
        self.searchText == query, self.sort == requestedSort,
        self.sortDescending == descending
      else { return }
      self.applyDisplayedItems(displayed)
    }
  }

  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 130_000_000)
      guard let self, !Task.isCancelled else { return }
      self.load()
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
        self.selectionAnchorScope = self.currentURL.standardizedFileURL
      } else if clearsSelection {
        self.selectionController.removeAll()
        self.selectionAnchor = nil
        self.selectionAnchorScope = nil
      }
      self.load()
    }
  }
}
