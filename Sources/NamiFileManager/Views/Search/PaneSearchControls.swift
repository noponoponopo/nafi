import SwiftUI

private enum PaneSearchFocus: Hashable {
  case field
}

struct PaneSearchControl: View {
  @ObservedObject var model: FilePaneModel
  @State private var showsOptions = false
  @FocusState private var focus: PaneSearchFocus?

  private var isExpanded: Bool { focus != nil || model.isSearchActive }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("検索", text: $model.searchText)
        .textFieldStyle(.plain)
        .focused($focus, equals: .field)

      if model.isSearchActive {
        Button {
          model.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("検索をクリア")
      }

      Divider().frame(height: 15)

      Button {
        showsOptions.toggle()
      } label: {
        Image(systemName: model.searchScope.systemImage)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("検索範囲と種類: \(model.searchDescription)")
      .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
        FileSearchOptionsPopover(model: model)
      }
    }
    .padding(.horizontal, 9)
    .frame(
      minWidth: isExpanded ? 240 : 130,
      idealWidth: isExpanded ? 300 : 150,
      maxWidth: isExpanded ? 380 : 190
    )
    .frame(height: 28)
    .background(
      model.isRecursiveSearchActive
        ? Color.accentColor.opacity(0.10)
        : Color.secondary.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      if model.isRecursiveSearchActive {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
      }
    }
    .animation(.snappy(duration: 0.2), value: isExpanded)
  }
}

private struct FileSearchOptionsPopover: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SearchOptionSection(title: "検索範囲") {
        VStack(spacing: 5) {
          ForEach(FileSearchScope.allCases) { scope in
            SearchChoiceRow(
              title: scope.label,
              systemImage: scope.systemImage,
              isSelected: model.searchScope == scope
            ) {
              model.searchScope = scope
            }
          }
        }
      }

      Divider()

      SearchOptionSection(title: "絞り込み") {
        Picker("絞り込み", selection: $model.searchFilterMode) {
          ForEach(FileSearchFilterMode.allCases) { mode in
            Label(mode.label, systemImage: mode.systemImage).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)

        filterConfiguration
      }

      Text(model.searchDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(16)
    .frame(width: 320)
  }

  @ViewBuilder
  private var filterConfiguration: some View {
    switch model.searchFilterMode {
    case .all, .folders:
      EmptyView()
    case .kinds:
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .leading),
          GridItem(.flexible(), alignment: .leading),
        ],
        spacing: 6
      ) {
        ForEach(FileSearchKind.allCases) { kind in
          Toggle(isOn: kindBinding(kind)) {
            Label {
              Text(kind.label).lineLimit(1)
            } icon: {
              Image(systemName: kind.systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.top, 4)
    case .extensions:
      VStack(alignment: .leading, spacing: 5) {
        TextField("例: jpg, png, webp", text: $model.searchExtensionsText)
          .textFieldStyle(.roundedBorder)
        Text("空白・カンマ・セミコロン区切りで複数指定できます。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private func kindBinding(_ kind: FileSearchKind) -> Binding<Bool> {
    Binding(
      get: { model.selectedSearchKinds.contains(kind) },
      set: { isSelected in
        if isSelected {
          model.selectedSearchKinds.insert(kind)
        } else {
          model.selectedSearchKinds.remove(kind)
        }
      }
    )
  }
}

private struct SearchOptionSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
  }
}

private struct SearchChoiceRow: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage).frame(width: 18)
        Text(title)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .background(
        isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
