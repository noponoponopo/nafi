import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit owns row reuse, selection, disclosure, keyboard navigation and column resizing.
struct FileListView: NSViewRepresentable {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var model: FilePaneModel
  @ObservedObject private var selection: FileSelectionController

  init(model: FilePaneModel) {
    self.model = model
    _selection = ObservedObject(wrappedValue: model.selectionController)
  }

  func makeCoordinator() -> Coordinator { Coordinator(model: model, appState: appState) }

  func makeNSView(context: Context) -> NSScrollView {
    let outline = BrowserOutlineView()
    outline.delegate = context.coordinator
    outline.dataSource = context.coordinator
    outline.headerView = NSTableHeaderView()
    outline.allowsMultipleSelection = true
    outline.allowsEmptySelection = true
    outline.allowsColumnReordering = true
    outline.allowsColumnResizing = true
    outline.usesAlternatingRowBackgroundColors = true
    outline.style = .fullWidth
    outline.rowHeight = 26
    outline.indentationPerLevel = 16
    outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    outline.autosaveName = "nafi.file-list.columns"
    outline.autosaveTableColumns = true
    for (key, title, width) in [
      ("name", "名前", 300.0), ("modified", "更新日", 145.0),
      ("size", "サイズ", 90.0), ("kind", "種類", 130.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
      column.title = title
      column.width = width
      column.minWidth = key == "name" ? 140 : 65
      column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
      outline.addTableColumn(column)
    }
    outline.outlineTableColumn = outline.tableColumns.first
    outline.target = context.coordinator
    outline.doubleAction = #selector(Coordinator.openClickedItem)
    outline.registerForDraggedTypes([
      .fileURL, NSPasteboard.PasteboardType(UTType.nafiFileCollection.identifier),
    ])
    outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    outline.setDraggingSourceOperationMask(.copy, forLocal: false)
    outline.model = model
    outline.buildMenu = { [weak coordinator = context.coordinator] row in
      coordinator?.menu(for: row)
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = outline
    context.coordinator.outline = outline
    return scroll
  }

  func updateNSView(_ view: NSScrollView, context: Context) {
    context.coordinator.update(model: model)
  }

  static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
    coordinator.cancelLoads()
    coordinator.outline?.delegate = nil
    coordinator.outline?.dataSource = nil
    coordinator.outline?.buildMenu = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node: NSObject {
      var item: FileItem
      var children: [Node]?
      init(_ item: FileItem) { self.item = item }
    }
    var model: FilePaneModel
    private let appState: AppState
    weak var outline: BrowserOutlineView?
    private var roots: [Node] = []
    private var nodes: [URL: Node] = [:]
    private var snapshot: [FileItem] = []
    private var directory: URL?
    private var sortKey = ""
    private var hidden = false
    private var wasLoading = false
    private var expanded = Set<URL>()
    private var loads: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    private var updating = false
    private var generation = UUID()

    init(model: FilePaneModel, appState: AppState) {
      self.model = model
      self.appState = appState
    }

    func cancelLoads() {
      for entry in loads.values { entry.task.cancel() }
      loads.removeAll()
      generation = UUID()
    }

    func update(model: FilePaneModel) {
      guard let outline else { return }
      let newDirectory = self.model !== model || directory != model.currentURL
      self.model = model
      outline.model = model
      updating = true
      defer { updating = false }
      if newDirectory {
        cancelLoads()
        nodes.removeAll()
        roots.removeAll()
        expanded.removeAll()
        snapshot = []
        directory = model.currentURL
        outline.scroll(.zero)
      }
      let newSort = "\(model.sort.rawValue)-\(model.sortDescending)-\(model.searchText)"
      let sortChanged = newSort != sortKey
      let refreshChildren = hidden != model.showHidden || (wasLoading && !model.isLoading)
      hidden = model.showHidden
      wasLoading = model.isLoading
      sortKey = newSort
      if newDirectory || snapshot != model.displayedItems || sortChanged || refreshChildren {
        snapshot = model.displayedItems
        roots = snapshot.map(node)
        let retained = Set(roots.map { $0.item.url })
        expanded = expanded.filter { url in
          retained.contains(url) || roots.contains { NafiURL.isDescendant(url, of: $0.item.url) }
        }
        // Reorder cached children locally. Changing a sort header never re-lists a server.
        if sortChanged {
          for current in Array(nodes.values) {
            if let children = current.children {
              let ordered = FilePaneModel.arranged(
                children.map(\.item), query: "", filter: .all,
                sort: model.sort, descending: model.sortDescending)
              current.children = ordered.map(node)
            }
          }
        }
        if refreshChildren {
          cancelLoads()
          for current in nodes.values { current.children = nil }
        }
        outline.sortDescriptors = [
          NSSortDescriptor(key: model.sort.rawValue, ascending: !model.sortDescending)
        ]
        outline.reloadData()
        restoreExpansion()
        let reachable = Set(roots.flatMap(allNodes).map { $0.item.url })
        nodes = nodes.filter { reachable.contains($0.key) }
      }
      syncSelection()
    }

    private func node(_ item: FileItem) -> Node {
      if let existing = nodes[item.url] {
        existing.item = item
        return existing
      }
      let value = Node(item)
      nodes[item.url] = value
      return value
    }

    private func allNodes(_ node: Node) -> [Node] {
      [node] + (node.children ?? []).flatMap(allNodes)
    }

    private func restoreExpansion() {
      guard let outline else { return }
      for url in expanded.sorted(by: { $0.absoluteString.count < $1.absoluteString.count }) {
        guard let node = nodes[url] else { continue }
        outline.expandItem(node)
        if node.children == nil { load(node) }
      }
    }

    private func syncSelection() {
      guard let outline else { return }
      var indexes = IndexSet()
      for url in model.selectionController.selectedURLs {
        guard let node = nodes[url] else { continue }
        let row = outline.row(forItem: node)
        if row >= 0 { indexes.insert(row) }
      }
      if indexes != outline.selectedRowIndexes {
        outline.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { outline.scrollRowToVisible(first) }
      }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      (item as? Node)?.children?.count ?? (item == nil ? roots.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      if let node = item as? Node { return node.children![index] }
      return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      guard let node = item as? Node else { return false }
      return node.item.isDirectory && !node.item.isPackage
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
      guard let node = item as? Node else { return false }
      expanded.insert(node.item.url)
      load(node)
      return true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !updating, let node = notification.userInfo?["NSObject"] as? Node else { return }
      let urls = allNodes(node).map { $0.item.url }
      for url in urls {
        expanded.remove(url)
        loads.removeValue(forKey: url)?.task.cancel()
        if url != node.item.url { nodes[url] = nil }
      }
      node.children = nil
    }

    private func load(_ node: Node) {
      let url = node.item.url
      guard node.children == nil, loads[url] == nil else { return }
      let id = UUID()
      let expectedGeneration = generation
      let showHidden = model.showHidden
      let task = Task { @MainActor [weak self, weak node] in
        guard let self, let node else { return }
        defer { if self.loads[url]?.id == id { self.loads[url] = nil } }
        do {
          let items = try await UnifiedFileSystemService.contents(of: url, showHidden: showHidden)
          let arranged = await self.model.arrange(items)
          guard !Task.isCancelled, self.generation == expectedGeneration,
            self.expanded.contains(url)
          else { return }
          node.children = arranged.map(self.node)
          self.updating = true
          self.outline?.reloadItem(node, reloadChildren: true)
          self.outline?.expandItem(node)
          self.restoreExpansion()
          self.syncSelection()
          self.updating = false
        } catch {
          if !Task.isCancelled, self.generation == expectedGeneration {
            self.model.errorMessage = error.localizedDescription
            self.outline?.collapseItem(node)
          }
        }
      }
      loads[url] = (id, task)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
      -> NSView?
    {
      guard let node = item as? Node, let column = tableColumn else { return nil }
      let identifier = column.identifier
      let cell =
        (outlineView.makeView(withIdentifier: identifier, owner: self) as? BrowserFileCell)
        ?? BrowserFileCell(identifier: identifier, showsIcon: identifier.rawValue == "name")
      let value = node.item
      switch identifier.rawValue {
      case "modified": cell.textField?.stringValue = value.modifiedLabel
      case "size": cell.textField?.stringValue = value.sizeLabel
      case "kind": cell.textField?.stringValue = value.kindLabel
      default:
        cell.textField?.stringValue = value.name
        cell.imageView?.image = value.icon
      }
      cell.alphaValue = value.isHidden ? 0.6 : 1
      cell.toolTip = ([value.name] + value.tagNames).joined(separator: "\n")
      return cell
    }

    func outlineView(
      _ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any
    ) -> String? {
      (item as? Node)?.item.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let outline else { return }
      let selected = outline.selectedRowIndexes.compactMap {
        (outline.item(atRow: $0) as? Node)?.item
      }
      model.setListSelection(
        selected, primary: (outline.item(atRow: outline.selectedRow) as? Node)?.item.url)
    }

    func outlineView(
      _ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
      guard !updating, let descriptor = outlineView.sortDescriptors.first,
        let key = descriptor.key, let sort = FileSort(rawValue: key)
      else { return }
      model.sort = sort
      model.sortDescending = !descriptor.ascending
    }

    @objc func openClickedItem() {
      guard let outline, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
      model.ensureSelected(node.item)
      model.activate(node.item)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
      -> NSPasteboardWriting?
    {
      guard let node = item as? Node else { return nil }
      return DragPayloadProvider.pasteboardItem(for: FileDragPayload(urls: [node.item.url]))
    }

    func outlineView(
      _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
      proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
      let node = item as? Node
      if let node, !node.item.isDirectory || node.item.isPackage { return [] }
      outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
      return info.draggingSourceOperationMask.contains(.move)
        && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    func outlineView(
      _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
      item: Any?, childIndex index: Int
    ) -> Bool {
      let destination = (item as? Node)?.item.url ?? model.currentURL
      let pasteboardItems = info.draggingPasteboard.pasteboardItems ?? []
      guard pasteboardItems.count <= DragPayloadLimits.maximumProviders else { return false }
      let providers = pasteboardItems.map { item -> NSItemProvider in
        let provider = NSItemProvider()
        for type in [NSPasteboard.PasteboardType(UTType.nafiFileCollection.identifier), .fileURL] {
          if let data = item.data(forType: type),
            data.count <= DragPayloadLimits.maximumPayloadBytes
          {
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all)
            { completion in
              completion(data, nil)
              return nil
            }
          }
        }
        return provider
      }
      return model.acceptDrop(providers, to: destination)
    }

    func menu(for row: Int) -> NSMenu? {
      guard let outline, let node = outline.item(atRow: row) as? Node else { return nil }
      let item = node.item
      if !outline.selectedRowIndexes.contains(row) {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
      model.ensureSelected(item)
      let menu = NSMenu()
      func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        let entry = FileActionMenuItem(title: title, action: action)
        entry.isEnabled = enabled
        menu.addItem(entry)
      }
      menu.autoenablesItems = false
      add("開く") { self.model.activate(item) }
      let openWith = NSMenu()
      for app in OpenWithApplicationCache.shared.applications(for: item).prefix(18) {
        openWith.addItem(
          FileActionMenuItem(title: app.deletingPathExtension().lastPathComponent) {
            self.model.open(item, withApplicationAt: app)
          })
      }
      openWith.addItem(.separator())
      openWith.addItem(
        FileActionMenuItem(title: "その他…") { self.model.chooseApplicationAndOpen(item) })
      let parent = NSMenuItem(title: "このアプリケーションで開く", action: nil, keyEquivalent: "")
      parent.submenu = openWith
      menu.addItem(parent)
      if item.isDirectory && !item.isPackage {
        add("新しいタブで開く") { self.appState.openInNewTab(item.url) }
        add("新しいペインで開く") { self.appState.openInNewPane(item.url) }
        add("サイドバーへ追加") { self.appState.sidebarModel.add(url: item.url) }
      } else if item.isPackage {
        add("パッケージの内容を表示") { self.model.navigate(to: item.url) }
      }
      add("Quick Look") { self.model.previewSelected() }
      if NafiURL.isRemote(item.url) { add("ダウンロード…") { self.model.downloadSelection() } }
      if QuickEditSupport.isEditable(item) {
        add("クイックエディット") { self.appState.presentQuickEdit(for: item) }
      }
      menu.addItem(.separator())
      add("コピー") { self.model.copySelection() }
      add("移動用にカット") { self.model.copySelection(cut: true) }
      add("名称変更") { self.model.requestRename(item.url) }
      if model.selectedItems.count > 1 { add("一括名称変更") { self.model.requestBatchRenameSelected() } }
      add("複製") { self.model.duplicateSelection() }
      add("エイリアスを作成") { self.model.createAliasSelection() }
      add("圧縮") { self.model.compressSelection() }
      if !item.isDirectory, item.url.pathExtension.lowercased() == "zip" {
        add("ZIPを展開") { self.model.extractSelection() }
      }
      add("タグを編集") { self.model.requestTagsForSelection() }
      menu.addItem(.separator())
      add("情報を見る") { self.appState.presentInspector(for: item.url) }
      add("パスをコピー") { self.model.copySelectedPath() }
      add("Finderで表示") { self.model.revealSelection() }
      add("ここでターミナルを開く", enabled: model.canOpenTerminalHere) {
        self.model.openTerminalHere(at: item.url)
      }
      menu.addItem(.separator())
      add(NafiURL.isRemote(item.url) ? "削除" : "ゴミ箱に入れる") { self.model.trashSelection() }
      return menu
    }
  }
}

@MainActor
final class BrowserOutlineView: NSOutlineView {
  weak var model: FilePaneModel?
  var buildMenu: ((Int) -> NSMenu?)?

  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    return buildMenu?(row) ?? super.menu(for: event)
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch event.keyCode {
    case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:
      if model?.requestRenameSelected() == true { return }
    case 49 where modifiers.isEmpty:
      model?.previewSelected()
      return
    case 53 where modifiers.isEmpty:
      deselectAll(nil)
      return
    case 125 where modifiers == .command:
      if let item = model?.selectedItem { model?.activate(item) }
      return
    default: break
    }
    super.keyDown(with: event)
  }
}

@MainActor
private final class BrowserFileCell: NSTableCellView {
  init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
    super.init(frame: .zero)
    self.identifier = identifier
    let text = NSTextField(labelWithString: "")
    text.font = .systemFont(ofSize: NSFont.systemFontSize)
    text.lineBreakMode = .byTruncatingMiddle
    text.alignment = identifier.rawValue == "size" ? .right : .left
    text.translatesAutoresizingMaskIntoConstraints = false
    addSubview(text)
    textField = text
    var leading = leadingAnchor
    var padding: CGFloat = 4
    if showsIcon {
      let image = NSImageView()
      image.translatesAutoresizingMaskIntoConstraints = false
      addSubview(image)
      imageView = image
      NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        image.centerYAnchor.constraint(equalTo: centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 18),
        image.heightAnchor.constraint(equalToConstant: 18),
      ])
      leading = image.trailingAnchor
      padding = 6
    }
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: leading, constant: padding),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class FileActionMenuItem: NSMenuItem {
  private let handler: () -> Void
  init(title: String, action: @escaping () -> Void) {
    handler = action
    super.init(title: title, action: #selector(invoke), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc private func invoke() { handler() }
}
