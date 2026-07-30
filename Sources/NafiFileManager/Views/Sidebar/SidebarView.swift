import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var serverManager: ServerManager
  @ObservedObject var model: SidebarModel
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    List {
      if model.showsFavorites {
        SidebarFavoritesSection(
          model: model,
          workspace: workspace,
          currentURL: appState.activeModel.currentURL,
          addCurrentFolder: { model.add(url: appState.activeModel.currentURL) },
          open: { appState.activeModel.navigate(to: $0) },
          openInNewTab: { appState.openInNewTab($0) },
          openInNewPane: { appState.openInNewPane($0) }
        )
      }

      if model.showsICloud {
        SidebarICloudSection(
          cloudStorage: appState.cloudStorage,
          workspace: workspace
        )
      }

      if model.showsVolumes {
        SidebarVolumesSection(
          volumes: serverManager.mountedVolumes,
          workspace: workspace,
          open: { appState.activeModel.navigate(to: $0) }
        )
      }

      if model.showsServers {
        SidebarServersSection(
          manager: serverManager,
          openEditor: { appState.presentServerEditor(profile: $0) }
        )
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .contentMargins(.trailing, 8, for: .scrollContent)
    .background(.regularMaterial)
    .frame(minWidth: 120, idealWidth: 240)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooter {
        appState.isSidebarEditorPresented = true
      }
    }
  }
}

private struct SidebarFavoritesSection: View {
  @ObservedObject var model: SidebarModel
  @ObservedObject var workspace: WorkspaceModel
  let currentURL: URL
  let addCurrentFolder: () -> Void
  let open: (URL) -> Void
  let openInNewTab: (URL) -> Void
  let openInNewPane: (URL) -> Void

  @State private var renamingFavorite: SidebarFavorite?

  private var isCurrentFolderFavorite: Bool { model.contains(url: currentURL) }
  private var lastFavoriteID: UUID? { model.favorites.last?.id }

  var body: some View {
    Section {
      SidebarSectionHeader(
        title: "よく使う項目",
        topPadding: 10,
        actionHelp: isCurrentFolderFavorite ? "現在のフォルダは追加済みです" : "現在のフォルダを追加",
        isActionDisabled: isCurrentFolderFavorite,
        action: addCurrentFolder
      )

      ForEach(model.favorites) { favorite in
        SidebarDestinationRow(
          title: favorite.title,
          systemImage: favorite.systemImage,
          destinationURL: favorite.url,
          activeModel: workspace.activeModel,
          beforeFavoriteID: favorite.id,
          moveFavoriteBefore: { sourceID, beforeID in
            model.move(itemID: sourceID, before: beforeID)
          },
          action: { open(favorite.url) }
        )
        .modifier(
          SidebarReorderEndDropOverlay(
            model: model,
            isEnabled: favorite.id == lastFavoriteID
          )
        )
        .onDrag {
          DragPayloadProvider.sidebarFavoriteProvider(for: favorite.id)
        }
        .contextMenu {
          Button("新しいタブで開く") { openInNewTab(favorite.url) }
          Button("新しいペインで開く") { openInNewPane(favorite.url) }
          Divider()
          Button("名前を変更…") { renamingFavorite = favorite }
          if !favorite.isBuiltIn {
            Divider()
            Button("サイドバーから削除", role: .destructive) { model.remove(favorite) }
          }
        }
      }
    }
    .sheet(item: $renamingFavorite) { favorite in
      RenameFavoriteDialog(
        originalTitle: favorite.title,
        onCancel: { renamingFavorite = nil },
        onConfirm: { newTitle in
          model.rename(favorite, to: newTitle)
          renamingFavorite = nil
        }
      )
    }
  }
}

private struct SidebarICloudSection: View {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var cloudStorage: CloudStorageService
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    Section {
      SidebarSectionHeader(
        title: "iCloud",
        topPadding: 8,
        showsAction: false,
        actionHelp: "",
        action: {}
      )

      if let url = cloudStorage.iCloudDriveURL {
        SidebarDestinationRow(
          title: "iCloud Drive",
          systemImage: "icloud",
          destinationURL: url,
          activeModel: workspace.activeModel,
          action: { appState.openICloudDrive() }
        )
        .contextMenu {
          Button("新しいタブで開く") { appState.openInNewTab(url) }
          Button("新しいペインで開く") { appState.openInNewPane(url) }
          Divider()
          Button("iCloud Driveを再検出") { cloudStorage.refresh() }
          Button("場所を選び直す…") { cloudStorage.chooseICloudDriveLocation() }
          if cloudStorage.usesUserSelectedLocation {
            Button("自動検出に戻す") { cloudStorage.forgetSelectedLocation() }
          }
        }
      } else {
        SidebarDestinationRow(
          title: "iCloud Driveを設定…",
          systemImage: "icloud.slash",
          activeModel: workspace.activeModel
        ) {
          cloudStorage.chooseICloudDriveLocation()
          if cloudStorage.isAvailable { appState.openICloudDrive() }
        }
      }
    }
  }
}

private struct SidebarVolumesSection: View {
  let volumes: [MountedVolume]
  @ObservedObject var workspace: WorkspaceModel
  let open: (URL) -> Void

  var body: some View {
    Section {
      SidebarSectionHeader(
        title: "ボリューム",
        topPadding: 6,
        showsAction: false,
        actionHelp: "",
        action: {}
      )

      ForEach(volumes) { volume in
        SidebarDestinationRow(
          title: volume.name,
          systemImage: volume.isLocal ? "internaldrive" : "externaldrive.connected.to.line.below",
          destinationURL: volume.url,
          activeModel: workspace.activeModel,
          action: { open(volume.url) }
        )
      }

      if volumes.isEmpty {
        Text("ボリュームを検出中…")
          .foregroundStyle(.secondary)
          .padding(.trailing, 10)
          .listRowInsets(EdgeInsets(top: 2, leading: 13, bottom: 2, trailing: 12))
          .listRowBackground(Color.clear)
      }
    }
  }
}

private struct SidebarServersSection: View {
  @ObservedObject var manager: ServerManager
  let openEditor: (ServerProfile) -> Void

  var body: some View {
    Section {
      SidebarSectionHeader(
        title: "サーバー",
        topPadding: 6,
        actionHelp: "サーバー接続を追加",
        action: { openEditor(.blank) }
      )

      ForEach(manager.profiles) { profile in
        ServerSidebarRow(
          profile: profile,
          manager: manager,
          edit: { openEditor(profile) }
        )
      }
    }
  }
}

private struct SidebarFooter: View {
  let edit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: edit) {
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
}

private struct RenameFavoriteDialog: View {
  let originalTitle: String
  let onCancel: () -> Void
  let onConfirm: (String) -> Void

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  private var trimmed: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 14) {
      Text("名前を変更").font(.headline)
      TextField("名前", text: $text)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { confirm() }
      HStack {
        Spacer()
        Button("キャンセル", action: onCancel).keyboardShortcut(.cancelAction)
        Button("変更", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmed.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 320)
    .onAppear {
      text = originalTitle
      isFocused = true
    }
  }

  private func confirm() {
    guard !trimmed.isEmpty else { return }
    onConfirm(trimmed)
  }
}
