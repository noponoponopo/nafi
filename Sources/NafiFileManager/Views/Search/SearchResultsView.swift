import SwiftUI

struct SearchResultsView: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    GeometryReader { proxy in
      let showsLocationColumn = proxy.size.width >= 540
      let showsMetadata = proxy.size.width >= 820

      VStack(spacing: 0) {
        SearchResultsHeader(
          model: model,
          showsLocationColumn: showsLocationColumn,
          showsMetadata: showsMetadata
        )
        Divider()
        FileSelectionSurface(
          model: model,
          scopeURL: model.searchRootURL ?? model.currentURL,
          onSelect: { item, modifiers in
            model.select(item, modifiers: modifiers)
          },
          itemForURL: { model.item(for: $0) },
          content: { coordinateSpace in
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(model.displayedItems) { item in
                  SearchResultRow(
                    model: model,
                    item: item,
                    showsLocationColumn: showsLocationColumn,
                    showsMetadata: showsMetadata,
                    selection: model.selectionFlag(for: item.url)
                  )
                  .fileSelectionHitTarget(item.url, in: coordinateSpace)
                }
              }
              .padding(.vertical, 2)
            }
            .contentShape(Rectangle())
          }
        )
      }
    }
  }
}

private struct SearchResultsHeader: View {
  @ObservedObject var model: FilePaneModel
  let showsLocationColumn: Bool
  let showsMetadata: Bool

  var body: some View {
    HStack(spacing: 10) {
      sortButton("名前", sort: .name)
        .frame(width: showsLocationColumn ? 280 : nil, alignment: .leading)
        .frame(maxWidth: showsLocationColumn ? nil : .infinity, alignment: .leading)

      if showsLocationColumn {
        Text("場所")
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showsMetadata {
        sortButton("更新日", sort: .modified)
          .frame(width: 132, alignment: .leading)
        sortButton("サイズ", sort: .size)
          .frame(width: 76, alignment: .trailing)
        sortButton("種類", sort: .kind)
          .frame(width: 110, alignment: .leading)
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

private struct SearchResultRow: View {
  let model: FilePaneModel
  let item: FileItem
  let showsLocationColumn: Bool
  let showsMetadata: Bool
  @ObservedObject var selection: SelectionFlag

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        FileThumbnailView(item: item, width: 20, height: 20, cornerRadius: 3)

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 5) {
            Text(item.name)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(item.isHidden ? .secondary : .primary)
            if !item.tagNames.isEmpty {
              Image(systemName: "tag.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(item.tagNames.joined(separator: ", "))
            }
          }

          if !showsLocationColumn {
            Text(model.searchLocationLabel(for: item))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .frame(width: showsLocationColumn ? 280 : nil, alignment: .leading)
      .frame(maxWidth: showsLocationColumn ? nil : .infinity, alignment: .leading)

      if showsLocationColumn {
        Text(model.searchLocationLabel(for: item))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showsMetadata {
        Text(item.modifiedLabel)
          .frame(width: 132, alignment: .leading)
          .foregroundStyle(.secondary)
        Text(item.sizeLabel)
          .frame(width: 76, alignment: .trailing)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Text(item.kindLabel)
          .frame(width: 110, alignment: .leading)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 10)
    .frame(height: showsLocationColumn ? 30 : 40)
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(selection.isSelected ? Color.accentColor.opacity(0.19) : .clear)
        .padding(.horizontal, 3)
    }
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
    .help(model.searchLocationLabel(for: item))
  }
}
