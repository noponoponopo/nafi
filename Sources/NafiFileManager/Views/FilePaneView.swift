import AppKit
import QuickLookUI
import SwiftUI

struct FilePaneView: View {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var model: FilePaneModel
  @State private var paneDropTargeted = false

  var body: some View {
    VStack(spacing: 0) {
      content
      Divider()
      FilePaneStatusBar(model: model)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .overlay {
      if paneDropTargeted {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          }
          .overlay {
            Label("このフォルダへ移動（Optionでコピー）", systemImage: "arrow.down.to.line")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.regularMaterial, in: Capsule())
          }
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .onDrop(
      of: DragPayloadProvider.fileDropTypes,
      isTargeted: $paneDropTargeted
    ) { providers in
      model.acceptDrop(providers, to: model.currentURL)
    }
    .contextMenu { backgroundContextMenu }
    .alert(
      model.prompt?.title ?? "",
      isPresented: Binding(
        get: { model.prompt != nil },
        set: { if !$0 { model.prompt = nil } }
      )
    ) {
      TextField(model.prompt?.placeholder ?? "名前", text: $model.promptText)
      Button("キャンセル", role: .cancel) { model.prompt = nil }
      Button("実行") { model.commitPrompt() }
        .keyboardShortcut(.defaultAction)
    }
    .alert(
      model.transferConflict?.title ?? "同じ名前の項目があります",
      isPresented: Binding(
        get: { model.transferConflict != nil },
        set: { if !$0 { model.cancelTransferConflict() } }
      )
    ) {
      Button("キャンセル", role: .cancel) { model.cancelTransferConflict() }
      Button("両方残す") { model.resolveTransferConflict(.keepBoth) }
        .keyboardShortcut(.defaultAction)
      if model.transferConflict?.canReplace == true {
        Button("置き換える", role: .destructive) {
          model.resolveTransferConflict(.replace)
        }
      }
    } message: {
      Text(model.transferConflict?.message ?? "")
    }
    .alert(
      "ファイル操作エラー",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var content: some View {
    ZStack {
      if model.isRecursiveSearchActive {
        SearchResultsView(model: model)
      } else {
        switch model.viewMode {
        case .list:
          FileListView(model: model)
        case .matrix:
          FileMatrixView(model: model)
        case .columns:
          FileColumnBrowserView(model: model)
        case .gallery:
          FileGalleryView(model: model)
        }
      }

      if model.displayedItems.isEmpty, !model.isLoading {
        ContentUnavailableView(
          model.searchText.isEmpty ? "このフォルダは空です" : "一致する項目がありません",
          systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .topTrailing) {
      if model.isLoading {
        ProgressView()
          .controlSize(.small)
          .padding(9)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .padding(10)
          .allowsHitTesting(false)
      }
    }
  }

  @ViewBuilder
  private var backgroundContextMenu: some View {
    Button("新規ファイル") { model.requestNewFile() }
    Button("新規フォルダ") { model.requestNewFolder() }
    Divider()
    Button("ペースト") { model.paste() }
      .disabled(model.isPerformingFileOperation)
    Button("すべてを選択") { model.selectAll() }
    Divider()
    Button("再読み込み") { model.load() }
    Button("ここでターミナルを開く") { model.openTerminalHere() }
      .disabled(!model.canOpenTerminalHere)
    Button("サイドバーへ追加") { appState.sidebarModel.add(url: model.currentURL) }
  }
}

private struct FilePaneStatusBar: View {
  @ObservedObject var model: FilePaneModel
  @ObservedObject private var selection: FileSelectionController

  init(model: FilePaneModel) {
    self.model = model
    _selection = ObservedObject(wrappedValue: model.selectionController)
  }

  var body: some View {
    HStack(spacing: 6) {
      Text("\(model.displayedItems.count)項目")
      if model.isSearchActive {
        Text("·")
        Text(model.searchDescription)
        if model.searchDidReachLimit {
          Text("·")
          Label("上限 \(FileSearchService.resultLimit) 件", systemImage: "exclamationmark.triangle")
        }
      }
      if selection.count > 0 {
        Text("·")
        Text("\(selection.count)項目を選択")
      }
      if let operation = model.operationLabel {
        Text("·")
        ProgressView().controlSize(.mini)
        Text(operation)
      }
      Spacer(minLength: 12)
      Text(model.displayPath)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background(.bar)
  }
}

struct FileListView: View {
  @ObservedObject var model: FilePaneModel
  @State private var expandedURLs: Set<URL> = []
  @State private var childItems: [URL: [FileItem]] = [:]
  @State private var loadingURLs: Set<URL> = []

  var body: some View {
    GeometryReader { proxy in
      let showsDetails = proxy.size.width >= 610
      VStack(spacing: 0) {
        FileListHeader(model: model, showsDetails: showsDetails)
        Divider()
        FileSelectionSurface(
          model: model,
          scopeURL: model.currentURL,
          onSelect: { item, modifiers in
            model.select(item, modifiers: modifiers)
          },
          itemForURL: { url in itemForURL(url) },
          content: { coordinateSpace in
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(treeRows) { row in
                  TreeListRow(
                    model: model,
                    row: row,
                    showsDetails: showsDetails,
                    isLoading: loadingURLs.contains(row.item.url),
                    onToggle: { toggleExpansion(of: row.item.url) },
                    selection: model.selectionFlag(for: row.item.url)
                  )
                  .fileSelectionHitTarget(row.item.url, in: coordinateSpace)
                }
              }
              .padding(.vertical, 2)
            }
            .contentShape(Rectangle())
          }
        )
      }
      .onChange(of: model.displayedItems) { _, _ in reloadExpandedDescendants() }
      .onChange(of: model.sort) { _, _ in reloadExpandedDescendants() }
      .onChange(of: model.sortDescending) { _, _ in reloadExpandedDescendants() }
      .onChange(of: model.searchText) { _, newValue in
        if newValue.isEmpty { reloadExpandedDescendants() }
      }
      .onChange(of: model.currentURL) { _, _ in resetExpansionState() }
    }
  }

  private var treeRows: [TreeRow] {
    var rows: [TreeRow] = []
    appendRows(model.displayedItems, depth: 0, into: &rows)
    return rows
  }

  private func appendRows(_ items: [FileItem], depth: Int, into rows: inout [TreeRow]) {
    for item in items {
      let canExpand = item.isDirectory && !item.isPackage
      let isExpanded = expandedURLs.contains(item.url)
      rows.append(TreeRow(item: item, depth: depth, isExpanded: isExpanded, canExpand: canExpand))
      if isExpanded, let children = childItems[item.url] {
        appendRows(children, depth: depth + 1, into: &rows)
      }
    }
  }

  private func itemForURL(_ url: URL) -> FileItem? {
    if let item = model.item(for: url) { return item }
    for (_, items) in childItems {
      if let item = items.first(where: { $0.url == url }) { return item }
    }
    return nil
  }

  private func toggleExpansion(of url: URL) {
    if expandedURLs.contains(url) {
      collapse(url)
    } else {
      expandedURLs.insert(url)
      loadChildren(of: url)
    }
  }

  private func collapse(_ url: URL) {
    for descendant in expandedURLs where NafiURL.isDescendant(descendant, of: url) {
      expandedURLs.remove(descendant)
      childItems[descendant] = nil
    }
    expandedURLs.remove(url)
    childItems[url] = nil
  }

  private func loadChildren(of url: URL) {
    guard childItems[url] == nil, !loadingURLs.contains(url) else { return }
    loadingURLs.insert(url)
    let showHidden = model.showHidden
    Task { @MainActor in
      let raw =
        (try? await UnifiedFileSystemService.contents(of: url, showHidden: showHidden)) ?? []
      let arranged = await model.arrange(raw)
      loadingURLs.remove(url)
      guard expandedURLs.contains(url) else { return }
      childItems[url] = arranged
    }
  }

  private func reloadExpandedDescendants() {
    for url in expandedURLs {
      childItems[url] = nil
      loadChildren(of: url)
    }
  }

  private func resetExpansionState() {
    expandedURLs.removeAll()
    childItems.removeAll()
    loadingURLs.removeAll()
  }
}

private struct TreeRow: Identifiable {
  let item: FileItem
  let depth: Int
  let isExpanded: Bool
  let canExpand: Bool
  var id: URL { item.url }
}

private struct FileListHeader: View {
  @ObservedObject var model: FilePaneModel
  let showsDetails: Bool

  var body: some View {
    HStack(spacing: 10) {
      sortButton("名前", sort: .name).frame(maxWidth: .infinity, alignment: .leading)
      if showsDetails {
        sortButton("更新日", sort: .modified).frame(width: 132, alignment: .leading)
        sortButton("サイズ", sort: .size).frame(width: 76, alignment: .trailing)
        sortButton("種類", sort: .kind).frame(width: 110, alignment: .leading)
      }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 13)
    .frame(height: 28)
    .background(.bar)
  }

  private func sortButton(_ title: String, sort: FileSort) -> some View {
    Button {
      if model.sort == sort {
        model.sortDescending.toggle()
      } else {
        model.sort = sort
        model.sortDescending = false
      }
    } label: {
      HStack(spacing: 3) {
        Text(title)
        if model.sort == sort {
          Image(systemName: model.sortDescending ? "chevron.down" : "chevron.up")
            .font(.system(size: 8, weight: .bold))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct TreeListRow: View {
  let model: FilePaneModel
  let row: TreeRow
  let showsDetails: Bool
  let isLoading: Bool
  let onToggle: () -> Void
  @ObservedObject var selection: SelectionFlag

  var body: some View {
    HStack(spacing: 6) {
      disclosure
      HStack(spacing: 8) {
        FileThumbnailView(item: row.item, width: 20, height: 20, cornerRadius: 3)
        Text(row.item.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(row.item.isHidden ? .secondary : .primary)
        if !row.item.tagNames.isEmpty {
          Image(systemName: "tag.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(row.item.tagNames.joined(separator: ", "))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if showsDetails {
        Text(row.item.modifiedLabel).frame(width: 132, alignment: .leading).foregroundStyle(
          .secondary)
        Text(row.item.sizeLabel).frame(width: 76, alignment: .trailing).foregroundStyle(.secondary)
          .monospacedDigit()
        Text(row.item.kindLabel).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .font(.system(size: 13))
    .padding(.leading, CGFloat(row.depth) * 16 + 10)
    .padding(.trailing, 10)
    .frame(height: 28)
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(selection.isSelected ? Color.accentColor.opacity(0.19) : .clear)
        .padding(.horizontal, 3)
    }
    .contentShape(Rectangle())
    .highPriorityGesture(
      TapGesture(count: 2).onEnded {
        model.ensureSelected(row.item)
        model.activate(row.item)
      }
    )
    .onDrag {
      DragPayloadProvider.fileProvider(for: model.dragPayload(for: row.item))
    }
    .modifier(
      FileFolderDropModifier(
        model: model,
        destination: row.item.isDirectory && !row.item.isPackage ? row.item.url : nil,
        open: { model.navigate(to: row.item.url) }
      )
    )
    .contextMenu { FileItemContextMenu(model: model, item: row.item) }
  }

  @ViewBuilder
  private var disclosure: some View {
    if row.canExpand {
      Button(action: onToggle) {
        ZStack {
          if isLoading {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(row.isExpanded ? "折りたたむ" : "展開")
    } else {
      Color.clear.frame(width: 16, height: 16)
    }
  }
}

struct FileMatrixView: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    let cellWidth = model.iconSize + 44

    FileSelectionSurface(
      model: model,
      scopeURL: model.currentURL,
      onSelect: { item, modifiers in
        model.select(item, modifiers: modifiers)
      },
      itemForURL: { model.item(for: $0) },
      content: { coordinateSpace in
        ScrollView {
          LazyVGrid(
            columns: [
              GridItem(
                .adaptive(minimum: cellWidth, maximum: cellWidth), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
          ) {
            ForEach(model.displayedItems) { item in
              MatrixCell(
                model: model,
                item: item,
                iconSize: model.iconSize,
                cellWidth: cellWidth,
                selection: model.selectionFlag(for: item.url)
              )
              .fileSelectionHitTarget(item.url, in: coordinateSpace)
            }
          }
          .padding(10)
        }
        .contentShape(Rectangle())
      }
    )
  }
}

private struct MatrixCell: View {
  let model: FilePaneModel
  let item: FileItem
  let iconSize: Double
  let cellWidth: Double
  @ObservedObject var selection: SelectionFlag

  var body: some View {
    VStack(spacing: 5) {
      FileThumbnailView(
        item: item,
        width: iconSize,
        height: iconSize,
        contentMode: .fit,
        cornerRadius: 7
      )
      Text(item.name)
        .font(.system(size: 12.5))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .truncationMode(.middle)
        .foregroundStyle(item.isHidden ? .secondary : .primary)
      if !item.tagNames.isEmpty {
        Label(item.tagNames.joined(separator: ", "), systemImage: "tag.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 5)
    .frame(width: cellWidth)
    .frame(minHeight: iconSize + 48, alignment: .top)
    .background(
      selection.isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .contentShape(Rectangle())
    .highPriorityGesture(
      TapGesture(count: 2).onEnded {
        model.ensureSelected(item)
        model.activate(item)
      }
    )
    .onDrag {
      DragPayloadProvider.fileProvider(for: model.dragPayload(for: item))
    }
    .modifier(
      FileFolderDropModifier(
        model: model,
        destination: item.isDirectory && !item.isPackage ? item.url : nil,
        open: { model.navigate(to: item.url) }
      )
    )
    .contextMenu { FileItemContextMenu(model: model, item: item) }
  }
}

struct FileGalleryView: View {
  @ObservedObject var model: FilePaneModel
  @ObservedObject private var selection: FileSelectionController

  init(model: FilePaneModel) {
    self.model = model
    _selection = ObservedObject(wrappedValue: model.selectionController)
  }

  var body: some View {
    VStack(spacing: 0) {
      GalleryPreview(model: model, selectedURL: selection.primaryURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipped()

      GalleryFilmstrip(model: model, selectedURL: selection.primaryURL)
        .frame(minHeight: 122, idealHeight: 122, maxHeight: 122)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct GalleryPreview: View {
  @EnvironmentObject private var appState: AppState
  let model: FilePaneModel
  let selectedURL: URL?

  var body: some View {
    ZStack {
      if let selected = model.item(for: selectedURL) {
        VStack(spacing: 0) {
          EmbeddedQuickLookView(url: selected.url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          if QuickEditSupport.isEditable(selected) {
            Divider()
            HStack {
              Spacer()
              Button {
                appState.presentQuickEdit(for: selected)
              } label: {
                Label("クイックエディット", systemImage: "square.and.pencil")
              }
              .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.bar)
          }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(18)
      } else {
        ContentUnavailableView("項目を選択", systemImage: "rectangle.on.rectangle.angled")
      }
    }
  }
}

private struct GalleryFilmstrip: View {
  let model: FilePaneModel
  let selectedURL: URL?

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      ScrollViewReader { proxy in
        FileSelectionSurface(
          model: model,
          scopeURL: model.currentURL,
          onSelect: { item, modifiers in
            model.select(item, modifiers: modifiers)
          },
          itemForURL: { model.item(for: $0) },
          content: { coordinateSpace in
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(spacing: 6) {
                ForEach(model.displayedItems) { item in
                  GalleryThumbnail(
                    model: model,
                    item: item,
                    selection: model.selectionFlag(for: item.url)
                  )
                  .fileSelectionHitTarget(item.url, in: coordinateSpace)
                  .id(item.url)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
            }
          }
        )
        .onChange(of: selectedURL) { _, newValue in
          guard let newValue else { return }
          withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(newValue, anchor: .center)
          }
        }
      }
    }
    .background(.bar)
  }
}

private struct GalleryThumbnail: View {
  let model: FilePaneModel
  let item: FileItem
  @ObservedObject var selection: SelectionFlag

  var body: some View {
    VStack(spacing: 5) {
      FileThumbnailView(
        item: item,
        width: 54,
        height: 54,
        contentMode: .fit,
        cornerRadius: 5
      )
      Text(item.name)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 88)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 4)
    .background(
      selection.isSelected ? Color.accentColor.opacity(0.19) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .contentShape(Rectangle())
    .highPriorityGesture(TapGesture(count: 2).onEnded { model.activate(item) })
    .onDrag {
      DragPayloadProvider.fileProvider(for: model.dragPayload(for: item))
    }
    .modifier(
      FileFolderDropModifier(
        model: model,
        destination: item.isDirectory && !item.isPackage ? item.url : nil,
        open: { model.navigate(to: item.url) }
      )
    )
    .contextMenu { FileItemContextMenu(model: model, item: item) }
  }
}

final class EmbeddedQuickLookContainer: NSView {
  let previewView: QLPreviewView?

  override init(frame frameRect: NSRect) {
    let preview = QLPreviewView(frame: frameRect, style: .normal)
    previewView = preview
    super.init(frame: frameRect)

    guard let preview else { return }
    preview.autostarts = true
    preview.wantsLayer = true
    preview.layer?.masksToBounds = true
    preview.autoresizingMask = [.width, .height]
    preview.frame = bounds
    preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
    preview.setContentHuggingPriority(.defaultLow, for: .vertical)
    preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    addSubview(preview)
  }

  required init?(coder: NSCoder) { nil }
}

struct EmbeddedQuickLookView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> EmbeddedQuickLookContainer {
    EmbeddedQuickLookContainer(frame: .zero)
  }

  func updateNSView(_ nsView: EmbeddedQuickLookContainer, context: Context) {
    guard let preview = nsView.previewView else { return }
    let current = (preview.previewItem as? NSURL).map { $0 as URL }
    guard current != url else { return }
    preview.previewItem = nil
    preview.previewItem = url as NSURL
  }

  static func dismantleNSView(_ nsView: EmbeddedQuickLookContainer, coordinator: Void) {
    nsView.previewView?.previewItem = nil
  }
}

struct FileColumnBrowserView: View {
  @ObservedObject var model: FilePaneModel
  @State private var columns: [ColumnData] = []
  @State private var loadTask: Task<Void, Never>?

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
          ColumnView(
            model: model,
            data: column,
            select: { item, modifiers in
              select(item, modifiers: modifiers, in: index)
            },
            openOnHover: { item in
              select(item, modifiers: [], in: index)
            }
          )
          Divider()
        }
      }
    }
    .onAppear { resetFromModel() }
    .onChange(of: model.currentURL) { _, _ in resetFromModel() }
    .onChange(of: model.displayedItems) { _, _ in refreshRootColumn() }
    .onDisappear { loadTask?.cancel() }
  }

  private func resetFromModel() {
    loadTask?.cancel()
    columns = [
      ColumnData(url: model.currentURL, items: model.displayedItems, isLoading: model.isLoading)
    ]
  }

  private func refreshRootColumn() {
    guard !columns.isEmpty else {
      resetFromModel()
      return
    }
    columns[0] = ColumnData(
      url: model.currentURL, items: model.displayedItems, isLoading: model.isLoading)
  }

  private func select(
    _ item: FileItem,
    modifiers: NSEvent.ModifierFlags,
    in index: Int
  ) {
    let column = columns[index]
    model.select(
      item,
      modifiers: modifiers,
      orderedItems: column.items,
      scope: column.url
    )
    loadTask?.cancel()
    columns = Array(columns.prefix(index + 1))
    guard item.isDirectory, !item.isPackage else { return }

    columns.append(ColumnData(url: item.url, items: [], isLoading: true))
    let targetURL = item.url
    let showHidden = model.showHidden
    loadTask = Task {
      let raw =
        (try? await UnifiedFileSystemService.contents(of: targetURL, showHidden: showHidden)) ?? []
      guard !Task.isCancelled else { return }
      let arranged = await model.arrange(raw)
      guard !Task.isCancelled, columns.last?.url == targetURL else { return }
      columns[columns.count - 1] = ColumnData(url: targetURL, items: arranged, isLoading: false)
    }
  }
}

private struct ColumnData: Identifiable {
  var id: URL { url }
  let url: URL
  let items: [FileItem]
  let itemLookup: [URL: FileItem]
  let isLoading: Bool

  init(url: URL, items: [FileItem], isLoading: Bool) {
    self.url = url
    self.items = items
    self.itemLookup = items.reduce(into: [:]) { lookup, item in
      lookup[item.url] = item
    }
    self.isLoading = isLoading
  }
}

private struct ColumnView: View {
  let model: FilePaneModel
  let data: ColumnData
  let select: (FileItem, NSEvent.ModifierFlags) -> Void
  let openOnHover: (FileItem) -> Void

  var body: some View {
    FileSelectionSurface(
      model: model,
      scopeURL: data.url,
      onSelect: select,
      itemForURL: { data.itemLookup[$0] },
      content: { coordinateSpace in
        ZStack(alignment: .top) {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(data.items) { item in
                ColumnItemRow(
                  model: model,
                  item: item,
                  selection: model.selectionFlag(for: item.url),
                  openOnHover: { openOnHover(item) }
                )
                .fileSelectionHitTarget(item.url, in: coordinateSpace)
              }
            }
            .padding(.vertical, 2)
          }
          if data.isLoading {
            ProgressView().controlSize(.small).padding(.top, 12)
          }
        }
      }
    )
    .frame(width: 245)
  }
}

private struct ColumnItemRow: View {
  let model: FilePaneModel
  let item: FileItem
  @ObservedObject var selection: SelectionFlag
  let openOnHover: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      FileThumbnailView(item: item, width: 18, height: 18, cornerRadius: 3)
      Text(item.name).lineLimit(1).truncationMode(.middle)
      Spacer()
      if item.isDirectory && !item.isPackage {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .font(.system(size: 12.5))
    .padding(.horizontal, 7)
    .frame(height: 26)
    .background {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(selection.isSelected ? Color.accentColor.opacity(0.19) : .clear)
        .padding(.horizontal, 2)
    }
    .contentShape(Rectangle())
    .highPriorityGesture(TapGesture(count: 2).onEnded { model.activate(item) })
    .onDrag {
      DragPayloadProvider.fileProvider(for: model.dragPayload(for: item))
    }
    .modifier(
      FileFolderDropModifier(
        model: model,
        destination: item.isDirectory && !item.isPackage ? item.url : nil,
        open: openOnHover
      )
    )
    .contextMenu { FileItemContextMenu(model: model, item: item) }
  }
}

struct FileFolderDropModifier: ViewModifier {
  @ObservedObject var model: FilePaneModel
  let destination: URL?
  let open: () -> Void

  @State private var targeted = false
  @State private var focusTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .overlay {
        if targeted {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .topTrailing) {
        if targeted {
          Image(systemName: "arrow.down.to.line")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(5)
            .background(.regularMaterial, in: Circle())
            .padding(4)
            .allowsHitTesting(false)
        }
      }
      .onDrop(
        of: DragPayloadProvider.fileDropTypes,
        isTargeted: Binding(
          get: { targeted },
          set: { updateTargeted($0 && destination != nil) }
        )
      ) { providers in
        guard let destination else { return false }
        cancelFocusTask()
        return model.acceptDrop(providers, to: destination)
      }
      .onDisappear { cancelFocusTask() }
  }

  private func updateTargeted(_ isTargeted: Bool) {
    targeted = isTargeted
    cancelFocusTask()
    guard isTargeted else { return }
    focusTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 850_000_000)
      guard !Task.isCancelled, targeted else { return }
      open()
    }
  }

  private func cancelFocusTask() {
    focusTask?.cancel()
    focusTask = nil
  }
}

struct FileItemContextMenu: View {
  @EnvironmentObject private var appState: AppState
  let model: FilePaneModel
  let item: FileItem

  var body: some View {
    Button(item.isDirectory && !item.isPackage ? "開く" : "デフォルトアプリで開く") {
      model.ensureSelected(item)
      model.activate(item)
    }

    Menu("このアプリケーションで開く") {
      ForEach(Array(applications.prefix(18)), id: \.self) { applicationURL in
        Button {
          model.open(item, withApplicationAt: applicationURL)
        } label: {
          Text(applicationURL.deletingPathExtension().lastPathComponent)
        }
      }
      Divider()
      Button("その他…") {
        model.chooseApplicationAndOpen(item)
      }
    }

    if item.isDirectory && !item.isPackage {
      Button("新しいタブで開く") {
        model.ensureSelected(item)
        appState.openInNewTab(item.url)
      }
      Button("新しいペインで開く") {
        model.ensureSelected(item)
        appState.openInNewPane(item.url)
      }
      Button("サイドバーへ追加") { appState.sidebarModel.add(url: item.url) }
    } else if item.isPackage {
      Button("パッケージの内容を表示") {
        model.ensureSelected(item)
        model.navigate(to: item.url)
      }
    }

    Button("Quick Look") {
      model.ensureSelected(item)
      model.previewSelected()
    }
    if NafiURL.isRemote(item.url) {
      Button("ダウンロード…") {
        model.ensureSelected(item)
        model.downloadSelection()
      }
    }
    if QuickEditSupport.isEditable(item) {
      Button("クイックエディット") {
        model.ensureSelected(item)
        appState.presentQuickEdit(for: item)
      }
    }
    Divider()
    Button("コピー") {
      model.ensureSelected(item)
      model.copySelection()
    }
    Button("移動用にカット") {
      model.ensureSelected(item)
      model.copySelection(cut: true)
    }
    Button("名称変更") {
      model.ensureSelected(item)
      model.requestRename(item.url)
    }
    if model.selectedItems.count > 1 {
      Button("一括名称変更") {
        model.ensureSelected(item)
        model.requestBatchRenameSelected()
      }
    }
    Button("複製") {
      model.ensureSelected(item)
      model.duplicateSelection()
    }
    Button("エイリアスを作成") {
      model.ensureSelected(item)
      model.createAliasSelection()
    }
    Button("圧縮") {
      model.ensureSelected(item)
      model.compressSelection()
    }
    if !item.isDirectory,
      item.url.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame
    {
      Button("ZIPを展開") {
        model.ensureSelected(item)
        model.extractSelection()
      }
    }
    Button("タグを編集") {
      model.ensureSelected(item)
      model.requestTagsForSelection()
    }
    Divider()
    Button("情報を見る") {
      model.ensureSelected(item)
      appState.presentInspector(for: item.url)
    }
    Button("パスをコピー") {
      model.ensureSelected(item)
      model.copySelectedPath()
    }
    Button("Finderで表示") {
      model.ensureSelected(item)
      model.revealSelection()
    }
    Button("ここでターミナルを開く") { model.openTerminalHere(at: item.url) }
      .disabled(!model.canOpenTerminalHere)
    Divider()
    Button(NafiURL.isRemote(item.url) ? "削除" : "ゴミ箱に入れる", role: .destructive) {
      model.ensureSelected(item)
      model.trashSelection()
    }
  }

  private var applications: [URL] {
    OpenWithApplicationCache.shared.applications(for: item)
  }
}
