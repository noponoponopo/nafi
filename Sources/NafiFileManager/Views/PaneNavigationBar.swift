import SwiftUI

struct PaneNavigationBar: View {
  @ObservedObject var model: FilePaneModel
  let canClosePane: Bool
  let onClosePane: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      PanePathControl(model: model)
        .frame(maxWidth: .infinity)

      PaneSearchControl(model: model)

      PaneDisplayOptionsMenu(model: model)

      if canClosePane {
        Button(action: onClosePane) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .help("ペインを閉じる")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 9)
    .frame(height: 39)
    .background(.bar)
  }
}

private struct PanePathControl: View {
  @ObservedObject var model: FilePaneModel
  @State private var isEditingPath = false
  @State private var pathText = ""

  var body: some View {
    Group {
      if isEditingPath {
        pathEditor
      } else {
        pathButton
      }
    }
  }

  private var pathEditor: some View {
    TextField("パス", text: $pathText)
      .textFieldStyle(.plain)
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background(
        .quaternary.opacity(0.75),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .onSubmit { commitPath() }
      .onExitCommand { isEditingPath = false }
  }

  private var pathButton: some View {
    Button {
      pathText =
        NafiURL.isRemote(model.currentURL)
        ? (NafiURL.remotePath(in: model.currentURL) ?? "/")
        : model.currentURL.path
      isEditingPath = true
    } label: {
      HStack(spacing: 7) {
        Image(systemName: NafiURL.isRemote(model.currentURL) ? "network" : "folder.fill")
          .foregroundStyle(Color.accentColor)
        Text(model.title)
          .fontWeight(.medium)
          .lineLimit(1)
        Text(parentPath)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .background(
        .quaternary.opacity(0.55),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("クリックしてパスを入力")
  }

  private var parentPath: String {
    NafiURL.isRemote(model.currentURL)
      ? (NafiURL.remotePath(in: NafiURL.parent(of: model.currentURL)) ?? "/")
      : model.currentURL.deletingLastPathComponent().path
  }

  private func commitPath() {
    if let profileID = NafiURL.profileID(in: model.currentURL) {
      model.navigate(to: NafiURL.remoteURL(profileID: profileID, path: pathText))
      isEditingPath = false
      return
    }

    let expanded = NSString(string: pathText).expandingTildeInPath
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      model.navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
    } else {
      model.errorMessage = "フォルダが見つかりません。"
    }
    isEditingPath = false
  }
}

private struct PaneDisplayOptionsMenu: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    Menu {
      Picker("並び順", selection: $model.sort) {
        ForEach(FileSort.allCases) { sort in
          Text(sort.label).tag(sort)
        }
      }
      Toggle("降順", isOn: $model.sortDescending)
      Divider()
      Toggle("隠しファイル", isOn: $model.showHidden)
        .onChange(of: model.showHidden) { _, _ in model.load() }
      if model.viewMode == .matrix {
        Divider()
        Slider(value: $model.iconSize, in: 42...112, step: 4) {
          Text("アイコンサイズ")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("表示オプション")
  }
}
