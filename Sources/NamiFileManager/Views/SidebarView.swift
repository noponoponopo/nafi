import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var serverManager: ServerManager
  @ObservedObject var model: SidebarModel
  @ObservedObject var workspace: WorkspaceModel
  @State private var editingProfile: ServerProfile?

  private var isCurrentFolderFavorite: Bool {
    model.contains(url: appState.activeModel.currentURL)
  }

  private var favoriteActionHelp: String {
    isCurrentFolderFavorite ? "現在のフォルダは追加済みです" : "現在のフォルダを追加"
  }

  var body: some View {
    List {
      if model.showsFavorites {
        Section {
          SidebarSectionHeader(
            title: "よく使う項目",
            topPadding: 16,
            actionHelp: favoriteActionHelp,
            isActionDisabled: isCurrentFolderFavorite
          ) {
            model.add(url: appState.activeModel.currentURL)
          }

          ForEach(model.favorites) { favorite in
            SidebarDestinationRow(
              title: favorite.title,
              systemImage: favorite.systemImage,
              destinationURL: favorite.url,
              activeModel: workspace.activeModel
            ) {
              appState.activeModel.navigate(to: favorite.url)
            }
            .contextMenu {
              Button("新しいタブで開く") { appState.openInNewTab(favorite.url) }
              Button("新しいペインで開く") { appState.openInNewPane(favorite.url) }
              if !favorite.isBuiltIn {
                Divider()
                Button("サイドバーから削除", role: .destructive) { model.remove(favorite) }
              }
            }
          }
          .onMove(perform: model.move)
        }
      }

      if model.showsVolumes {
        Section {
          SidebarSectionHeader(
            title: "ボリューム",
            topPadding: 8,
            showsAction: false,
            actionHelp: ""
          ) {}

          ForEach(serverManager.mountedVolumes) { volume in
            SidebarDestinationRow(
              title: volume.name,
              systemImage: volume.isLocal
                ? "internaldrive" : "externaldrive.connected.to.line.below",
              destinationURL: volume.url,
              activeModel: workspace.activeModel
            ) {
              appState.activeModel.navigate(to: volume.url)
            }
          }
          if serverManager.mountedVolumes.isEmpty {
            Text("ボリュームを検出中…")
              .foregroundStyle(.secondary)
              .padding(.trailing, 10)
              .listRowInsets(EdgeInsets(top: 2, leading: 13, bottom: 2, trailing: 12))
              .listRowBackground(Color.clear)
          }
        }
      }

      if model.showsServers {
        Section {
          SidebarSectionHeader(
            title: "サーバー",
            topPadding: 8,
            actionHelp: "サーバー接続を追加"
          ) {
            appState.isServerSheetPresented = true
          }

          ForEach(serverManager.profiles) { profile in
            ServerSidebarRow(profile: profile, manager: serverManager) { editingProfile = profile }
          }
          SidebarDestinationRow(
            title: "接続先を追加",
            systemImage: "plus.circle",
            activeModel: workspace.activeModel
          ) {
            appState.isServerSheetPresented = true
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .contentMargins(.trailing, 8, for: .scrollContent)
    .background(.regularMaterial)
    .frame(minWidth: 240, idealWidth: 280)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          appState.isSidebarEditorPresented = true
        } label: {
          Label("サイドバーを編集", systemImage: "slider.horizontal.3")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Spacer()
      }
      .font(.caption)
      .padding(.horizontal, 12)
      .frame(height: 34)
      .background(.ultraThinMaterial)
    }
    .sheet(item: $editingProfile) { profile in
      ServerEditorView(serverManager: serverManager, profile: profile)
    }
  }
}

private struct SidebarSectionHeader: View {
  let title: String
  var topPadding: CGFloat = 0
  var showsAction = true
  var actionHelp: String
  var isActionDisabled = false
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      if showsAction {
        Button(action: action) {
          Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isActionDisabled)
        .help(actionHelp)
        .accessibilityLabel(actionHelp)
      }
    }
    .padding(.top, topPadding)
    .padding(.leading, 9)
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
    .contentShape(Rectangle())
    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 1, trailing: 4))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

private struct SidebarDestinationRow: View {
  let title: String
  let systemImage: String
  var destinationURL: URL? = nil
  @ObservedObject private var activeModel: FilePaneModel
  let action: () -> Void

  init(
    title: String,
    systemImage: String,
    destinationURL: URL? = nil,
    activeModel: FilePaneModel,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.destinationURL = destinationURL
    _activeModel = ObservedObject(wrappedValue: activeModel)
    self.action = action
  }

  private var isSelected: Bool {
    guard let destinationURL else { return false }
    return activeModel.currentURL.standardizedFileURL == destinationURL.standardizedFileURL
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage).frame(width: 18)
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, 8)
      .padding(.trailing, 11)
      .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      .background(
        isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

private struct ServerSidebarRow: View {
  let profile: ServerProfile
  @ObservedObject var manager: ServerManager
  let edit: () -> Void

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: profile.kind.systemImage).frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name).lineLimit(1)
        Text(profile.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      stateIndicator
    }
    .padding(.leading, 8)
    .padding(.trailing, 11)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture { Task { await manager.connect(profile) } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { Task { await manager.connect(profile) } }
    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .contextMenu {
      Button("接続") { Task { await manager.connect(profile) } }
      Button("切断") { Task { await manager.disconnect(profile) } }
      Divider()
      Button("編集", action: edit)
      Button("削除", role: .destructive) { manager.remove(profile) }
    }
    .help(helpText)
  }

  @ViewBuilder
  private var stateIndicator: some View {
    switch manager.state(for: profile) {
    case .idle: Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
    case .connecting: ProgressView().controlSize(.mini)
    case .connected: Circle().fill(.green).frame(width: 7, height: 7)
    case .helperRequired: Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
    }
  }

  private var helpText: String {
    switch manager.state(for: profile) {
    case .helperRequired(let message), .failed(let message): message
    default: profile.endpointDescription
    }
  }
}

struct SidebarCustomizationView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: SidebarModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("サイドバーを編集").font(.title3.weight(.semibold))
        Spacer()
        Button("完了") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(16)

      Divider()

      Form {
        Section("表示するセクション") {
          Toggle("よく使う項目", isOn: $model.showsFavorites)
          Toggle("ボリューム", isOn: $model.showsVolumes)
          Toggle("サーバー", isOn: $model.showsServers)
        }

        Section("よく使う項目 — ドラッグして並べ替え") {
          List {
            ForEach(model.favorites) { favorite in
              HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Image(systemName: favorite.systemImage).frame(width: 18)
                if favorite.isBuiltIn {
                  Text(favorite.title)
                } else {
                  TextField(
                    "名前",
                    text: Binding(
                      get: { favorite.title },
                      set: { model.rename(favorite, to: $0) }
                    )
                  )
                  .textFieldStyle(.plain)
                }
                Spacer()
                if !favorite.isBuiltIn {
                  Button(role: .destructive) {
                    model.remove(favorite)
                  } label: {
                    Image(systemName: "minus.circle")
                  }
                  .buttonStyle(.plain)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 28)
              .contentShape(Rectangle())
              .draggable(favorite.id.uuidString)
              .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let sourceID = UUID(uuidString: value) else {
                  return false
                }
                model.move(itemID: sourceID, before: favorite.id)
                return true
              }
            }
          }
          .frame(height: 210)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button("初期状態に戻す") { model.reset() }
        Spacer()
      }
      .padding(16)
    }
    .frame(width: 520, height: 500)
  }
}
