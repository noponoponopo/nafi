import SwiftUI
import UniformTypeIdentifiers

struct DropStackView: View {
  @ObservedObject var model: DropStackModel
  @State private var selection = Set<URL>()
  @State private var isDropTargeted = false
  @State private var viewMode: FileViewMode = .list
  @State private var navigationStack: [URL] = []
  @State private var folderItems: [FileItem] = []
  @State private var isLoadingFolder = false
  @Environment(\.dismiss) private var dismiss

  private let matrixIconSize: CGFloat = 48

  private var currentFolder: URL? { navigationStack.last }
  private var isAtRoot: Bool { navigationStack.isEmpty }

  private var displayedItems: [FileItem] {
    if isAtRoot {
      return model.entries.map { fileItem(for: $0) }
    }
    return folderItems
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          if isAtRoot && isDropTargeted {
            Rectangle()
              .fill(Color.accentColor.opacity(0.12))
              .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
              .allowsHitTesting(false)
          }
        }
        .onDrop(
          of: DragPayloadProvider.fileDropTypes,
          isTargeted: Binding(
            get: { isDropTargeted },
            set: { isDropTargeted = $0 }
          )
        ) { providers in
          guard isAtRoot, !DragPayloadProvider.containsDropStackInternal(in: providers)
          else { return false }
          DragPayloadProvider.loadFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            Task { @MainActor in model.add(urls) }
          }
          return true
        }
      if isAtRoot {
        Divider()
        footer
      }
    }
    .frame(minWidth: 680, minHeight: 440)
    .alert(
      "Drop Stack",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if let folder = currentFolder {
        Button { goBack() } label: { Image(systemName: "chevron.left") }
          .help("戻る")
        Text(NafiURL.displayPath(folder))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      } else {
        Text("Optionを押しながらドロップで複製・Drop Stackから出しても項目は残ります")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Picker("", selection: $viewMode) {
        Image(systemName: "list.bullet").tag(FileViewMode.list)
        Image(systemName: "square.grid.2x2").tag(FileViewMode.matrix)
        Image(systemName: "rectangle.on.rectangle.angled").tag(FileViewMode.gallery)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 108)
      Button("完了", action: { dismiss() }).keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private var content: some View {
    if displayedItems.isEmpty {
      ContentUnavailableView(
        isAtRoot ? "Drop Stackは空です" : "このフォルダは空です",
        systemImage: "tray",
        description: Text(
          isAtRoot
            ? "ファイルをここへドロップするか、クイック操作から追加してください。"
            : "このフォルダには表示できる項目がありません。")
      )
    } else if viewMode == .list {
      listView
    } else if viewMode == .matrix {
      matrixView
    } else {
      galleryView
    }
  }

  private var listView: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("名前").frame(maxWidth: .infinity, alignment: .leading)
        Text("更新日").frame(width: 132, alignment: .leading)
        Text("サイズ").frame(width: 76, alignment: .trailing)
        Text("種類").frame(width: 110, alignment: .leading)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 13)
      .frame(height: 28)
      .background(.bar)
      Divider()
      ScrollView {
        if !isAtRoot && isLoadingFolder {
          ProgressView().padding(.vertical, 20)
        }
        LazyVStack(spacing: 0) {
          ForEach(displayedItems) { item in
            listRow(item)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func listRow(_ item: FileItem) -> some View {
    let isSelected = selection.contains(item.url)
    let canOpen = item.isDirectory && !item.isPackage
    return HStack(spacing: 8) {
      FileThumbnailView(item: item, width: 20, height: 20, cornerRadius: 3)
      Text(item.name)
        .lineLimit(1).truncationMode(.middle)
        .foregroundStyle(item.isHidden ? .secondary : .primary)
      Spacer(minLength: 0)
      Text(item.modifiedLabel).frame(width: 132, alignment: .leading).foregroundStyle(.secondary)
      Text(item.sizeLabel).frame(width: 76, alignment: .trailing).foregroundStyle(.secondary)
        .monospacedDigit()
      Text(item.kindLabel).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .font(.system(size: 13))
    .padding(.leading, 10).padding(.trailing, 10)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.19) : .clear)
        .padding(.horizontal, 3)
    )
    .contentShape(Rectangle())
    .onTapGesture { toggleSelection(item.url) }
    .highPriorityGesture(
      TapGesture(count: 2).onEnded { if canOpen { openFolder(item.url) } }
    )
    .onDrag { dragProvider(for: item) }
  }

  private var matrixView: some View {
    let cellWidth = matrixIconSize + 44
    return ScrollView {
      if !isAtRoot && isLoadingFolder {
        ProgressView().padding(.vertical, 20)
      }
      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: 8)
        ],
        alignment: .leading,
        spacing: 8
      ) {
        ForEach(displayedItems) { item in
          matrixCell(item, cellWidth: cellWidth)
        }
      }
      .padding(10)
    }
  }

  private func matrixCell(_ item: FileItem, cellWidth: CGFloat) -> some View {
    let isSelected = selection.contains(item.url)
    let canOpen = item.isDirectory && !item.isPackage
    return VStack(spacing: 5) {
      FileThumbnailView(
        item: item, width: matrixIconSize, height: matrixIconSize, contentMode: .fit, cornerRadius: 7)
      Text(item.name)
        .font(.system(size: 12.5))
        .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
        .foregroundStyle(item.isHidden ? .secondary : .primary)
    }
    .padding(.vertical, 5)
    .frame(width: cellWidth)
    .frame(minHeight: matrixIconSize + 48, alignment: .top)
    .background(
      isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .contentShape(Rectangle())
    .onTapGesture { toggleSelection(item.url) }
    .highPriorityGesture(
      TapGesture(count: 2).onEnded { if canOpen { openFolder(item.url) } }
    )
    .onDrag { dragProvider(for: item) }
  }

  private var galleryView: some View {
    let primary = displayedItems.first { selection.contains($0.url) } ?? displayedItems.first
    return VStack(spacing: 0) {
      ZStack {
        if let primary {
          EmbeddedQuickLookView(url: primary.url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView("項目を選択", systemImage: "rectangle.on.rectangle.angled")
        }
      }
      .padding(18)
      Divider()
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 6) {
          ForEach(displayedItems) { item in
            galleryThumbnail(item)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
      }
      .frame(height: 122)
      .fixedSize(horizontal: false, vertical: true)
      .background(.bar)
    }
  }

  private func galleryThumbnail(_ item: FileItem) -> some View {
    let isSelected = selection.contains(item.url)
    return VStack(spacing: 5) {
      FileThumbnailView(item: item, width: 54, height: 54, contentMode: .fit, cornerRadius: 5)
      Text(item.name)
        .font(.caption)
        .lineLimit(1).truncationMode(.middle)
        .frame(width: 88)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 4)
    .background(
      isSelected ? Color.accentColor.opacity(0.19) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .contentShape(Rectangle())
    .onTapGesture { selection = [item.url] }
    .onDrag { dragProvider(for: item) }
  }

  private var footer: some View {
    HStack {
      Button("選択を削除", role: .destructive) {
        let ids = Set(
          model.entries.filter { selection.contains($0.resolvedURL()) }.map { $0.id })
        model.remove(ids)
        selection.removeAll()
      }
      .disabled(selection.isEmpty)
      Spacer()
      Button("すべて消去", role: .destructive) {
        model.clear()
        selection.removeAll()
      }
      .disabled(model.entries.isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  private func toggleSelection(_ url: URL) {
    if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
  }

  private func dragProvider(for item: FileItem) -> NSItemProvider {
    let urls = selection.contains(item.url)
      ? displayedItems.filter { selection.contains($0.url) }.map { $0.url }
      : [item.url]
    return DragPayloadProvider.dropStackFileProvider(for: FileDragPayload(urls: urls))
  }

  private func openFolder(_ url: URL) {
    navigationStack.append(url)
    selection.removeAll()
    loadCurrentFolder()
  }

  private func goBack() {
    guard !navigationStack.isEmpty else { return }
    navigationStack.removeLast()
    selection.removeAll()
    if navigationStack.isEmpty {
      folderItems = []
      isLoadingFolder = false
    } else {
      loadCurrentFolder()
    }
  }

  private func loadCurrentFolder() {
    guard let folder = currentFolder else {
      folderItems = []
      isLoadingFolder = false
      return
    }
    isLoadingFolder = true
    let target = folder
    Task { @MainActor in
      let raw = (try? await UnifiedFileSystemService.contents(of: target, showHidden: false)) ?? []
      guard navigationStack.last == target else { return }
      folderItems = raw.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      isLoadingFolder = false
    }
  }

  private func fileItem(for entry: DropStackModel.Entry) -> FileItem {
    let url = entry.resolvedURL()
    if let local = FileItem.make(from: url) { return local }
    let name = url.lastPathComponent.isEmpty
      ? (NafiURL.remotePath(in: url)?.split(separator: "/").last.map(String.init) ?? url.host ?? url.path)
      : url.lastPathComponent
    let contentType = url.pathExtension.isEmpty
      ? nil
      : UTType(filenameExtension: url.pathExtension)?.identifier
    return FileItem(
      url: url, name: name, isDirectory: url.hasDirectoryPath, isPackage: false, isHidden: false,
      fileSize: nil, creationDate: nil, modificationDate: entry.addedAt,
      contentTypeIdentifier: contentType, tagNames: []
    )
  }
}
