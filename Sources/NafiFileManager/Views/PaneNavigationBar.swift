import AppKit
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
        }
        .buttonStyle(.borderless)
        .help("ペインを閉じる")
        .accessibilityLabel("ペインを閉じる")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 9)
    .frame(height: 39)
    .nafiChromeBackground(.bar)
  }
}

private struct PanePathControl: View {
  @ObservedObject var model: FilePaneModel
  @State private var isEditingPath = false
  @State private var pathText = ""
  @FocusState private var pathFocused: Bool

  var body: some View {
    Group {
      if isEditingPath {
        TextField("フォルダのパス", text: $pathText)
          .textFieldStyle(.roundedBorder)
          .focused($pathFocused)
          .onSubmit { commitPath() }
          .onExitCommand { isEditingPath = false }
          .onAppear { pathFocused = true }
      } else {
        HStack(spacing: 4) {
          if let profileID = NafiURL.profileID(in: model.currentURL) {
            Button {
              model.navigate(to: NafiURL.remoteURL(profileID: profileID, path: "/"))
            } label: {
              Image(systemName: "network")
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("接続先のルートへ移動")
            .accessibilityLabel("接続先のルートへ移動")
          }
          NativePathControl(
            url: model.currentURL, navigate: { model.navigate(to: $0) }, edit: beginEditing)
          Button(action: beginEditing) { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("パスを入力")
            .accessibilityLabel("パスを入力")
        }
      }
    }
    .onChange(of: model.currentURL) { _, _ in isEditingPath = false }
  }

  private func beginEditing() {
    pathText =
      NafiURL.isRemote(model.currentURL)
      ? (NafiURL.remotePath(in: model.currentURL) ?? "/") : model.currentURL.path
    isEditingPath = true
  }

  private func commitPath() {
    let text = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if let profileID = NafiURL.profileID(in: model.currentURL) {
      model.navigate(to: NafiURL.remoteURL(profileID: profileID, path: text))
      isEditingPath = false
      return
    }
    let expanded = NSString(string: text).expandingTildeInPath
    let startingURL = model.currentURL
    isEditingPath = false
    Task {
      let exists = await Task.detached(priority: .userInitiated) {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
          && isDirectory.boolValue
      }.value
      guard !Task.isCancelled, model.currentURL == startingURL else { return }
      if exists {
        model.navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
      } else {
        model.errorMessage = "フォルダが見つかりません。"
      }
    }
  }
}

private struct NativePathControl: NSViewRepresentable {
  let url: URL
  let navigate: (URL) -> Void
  let edit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(navigate: navigate, edit: edit) }
  func makeNSView(context: Context) -> NSPathControl {
    let view = NSPathControl()
    view.pathStyle = .standard
    view.isEditable = false
    view.controlSize = .small
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.target = context.coordinator
    view.action = #selector(Coordinator.openComponent(_:))
    view.doubleAction = #selector(Coordinator.editPath(_:))
    return view
  }
  func updateNSView(_ view: NSPathControl, context: Context) {
    context.coordinator.navigate = navigate
    context.coordinator.edit = edit
    guard context.coordinator.currentURL != url else { return }
    context.coordinator.currentURL = url
    if let profileID = NafiURL.profileID(in: url) {
      var paths: [NSPathControlItem] = []
      var path = "/"
      let root = NSPathControlItem()
      root.title = "接続先"
      var destinations = [NafiURL.remoteURL(profileID: profileID, path: path)]
      paths.append(root)
      for component in (NafiURL.remotePath(in: url) ?? "/").split(separator: "/") {
        path = RemotePath.appending(String(component), to: path)
        let item = NSPathControlItem()
        item.title = String(component)
        destinations.append(NafiURL.remoteURL(profileID: profileID, path: path))
        paths.append(item)
      }
      context.coordinator.remoteDestinations = destinations
      view.pathItems = paths
    } else {
      context.coordinator.remoteDestinations = []
      view.url = url
    }
    view.toolTip = NafiURL.isRemote(url) ? NafiURL.remotePath(in: url) : url.path
  }
  @MainActor final class Coordinator: NSObject {
    var navigate: (URL) -> Void
    var edit: () -> Void
    var currentURL: URL?
    var remoteDestinations: [URL] = []
    init(navigate: @escaping (URL) -> Void, edit: @escaping () -> Void) {
      self.navigate = navigate
      self.edit = edit
    }
    @objc func openComponent(_ sender: NSPathControl) {
      guard let clicked = sender.clickedPathItem else { return }
      let destination: URL?
      if remoteDestinations.isEmpty {
        destination = clicked.url
      } else if let index = sender.pathItems.firstIndex(of: clicked),
        remoteDestinations.indices.contains(index)
      {
        destination = remoteDestinations[index]
      } else {
        return
      }
      if let destination, destination != currentURL { navigate(destination) }
    }
    @objc func editPath(_ sender: NSPathControl) { edit() }
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
