import SwiftUI

struct PaneNavigationBar: View {
  @ObservedObject var model: FilePaneModel
  @State private var isEditingPath = false
  @State private var pathText = ""

  var body: some View {
    HStack(spacing: 8) {
      pathControl
        .frame(maxWidth: .infinity)

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("検索", text: $model.searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 9)
      .frame(minWidth: 130, idealWidth: 170, maxWidth: 220)
      .frame(height: 28)
      .background(
        .quaternary.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      Menu {
        Picker("並び順", selection: $model.sort) {
          ForEach(FileSort.allCases) { sort in Text(sort.label).tag(sort) }
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
    .controlSize(.small)
    .padding(.horizontal, 9)
    .frame(height: 39)
    .background(.bar)
  }

  @ViewBuilder
  private var pathControl: some View {
    if isEditingPath {
      TextField("パス", text: $pathText)
        .textFieldStyle(.plain)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
          .quaternary.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onSubmit { commitPath() }
        .onExitCommand { isEditingPath = false }
    } else {
      Button {
        pathText = model.currentURL.path
        isEditingPath = true
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "folder.fill")
            .foregroundStyle(Color.accentColor)
          Text(model.title)
            .fontWeight(.medium)
            .lineLimit(1)
          Text(model.currentURL.deletingLastPathComponent().path)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
          .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("クリックしてパスを入力")
    }
  }

  private func commitPath() {
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
