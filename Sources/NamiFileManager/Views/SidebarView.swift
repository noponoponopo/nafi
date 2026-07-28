import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
              activeModel: workspace.activeModel,
              beforeFavoriteID: favorite.id,
              moveFavoriteBefore: { sourceID, beforeID in
                model.move(itemID: sourceID, before: beforeID)
              }
            ) {
              appState.activeModel.navigate(to: favorite.url)
            }
            .onDrag {
              DragPayloadProvider.sidebarFavoriteProvider(for: favorite.id)
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

          SidebarReorderEndTarget(model: model)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      }

      ICloudSidebarSection(
        cloudStorage: appState.cloudStorage,
        workspace: workspace
      )

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
    .frame(minWidth: 180, idealWidth: 240)
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

private struct ICloudSidebarSection: View {
  @EnvironmentObject private var appState: AppState
  @ObservedObject var cloudStorage: CloudStorageService
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    Section {
      SidebarSectionHeader(
        title: "iCloud",
        topPadding: 8,
        actionHelp: cloudStorage.isAvailable ? "iCloud Driveを再検出" : "iCloud Driveの場所を選択"
      ) {
        if cloudStorage.isAvailable {
          cloudStorage.refresh()
        } else {
          cloudStorage.chooseICloudDriveLocation()
        }
      }

      if let url = cloudStorage.iCloudDriveURL {
        SidebarDestinationRow(
          title: "iCloud Drive",
          systemImage: "icloud",
          destinationURL: url,
          activeModel: workspace.activeModel
        ) {
          appState.openICloudDrive()
        }
        .contextMenu {
          Button("新しいタブで開く") { appState.openInNewTab(url) }
          Button("新しいペインで開く") { appState.openInNewPane(url) }
          Divider()
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
  var beforeFavoriteID: UUID? = nil
  var moveFavoriteBefore: ((UUID, UUID) -> Void)? = nil
  let action: () -> Void

  @State private var isFileDropTargeted = false
  @State private var isReorderDropTargeted = false
  @State private var focusTask: Task<Void, Never>?

  init(
    title: String,
    systemImage: String,
    destinationURL: URL? = nil,
    activeModel: FilePaneModel,
    beforeFavoriteID: UUID? = nil,
    moveFavoriteBefore: ((UUID, UUID) -> Void)? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.destinationURL = destinationURL
    _activeModel = ObservedObject(wrappedValue: activeModel)
    self.beforeFavoriteID = beforeFavoriteID
    self.moveFavoriteBefore = moveFavoriteBefore
    self.action = action
  }

  private var isSelected: Bool {
    guard let destinationURL else { return false }
    return NafiURL.sameLocation(activeModel.currentURL, destinationURL)
  }

  private var acceptedDropTypes: [UTType] {
    beforeFavoriteID == nil
      ? DragPayloadProvider.fileDropTypes
      : DragPayloadProvider.favoriteDropTypes
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage).frame(width: 18)
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
        if isFileDropTargeted {
          Image(systemName: "arrow.down.to.line")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.leading, 8)
      .padding(.trailing, 11)
      .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      .background(
        isFileDropTargeted
          ? Color.accentColor.opacity(0.22)
          : (isSelected ? Color.accentColor.opacity(0.16) : Color.clear),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        if isFileDropTargeted {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
        }
      }
      .overlay(alignment: .top) {
        if isReorderDropTargeted {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 6)
            .offset(y: -2)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .onDrop(
      of: acceptedDropTypes,
      isTargeted: Binding(
        get: { isFileDropTargeted || isReorderDropTargeted },
        set: { updateDropTarget($0) }
      )
    ) { providers in
      cancelFocusTask()

      if let beforeFavoriteID, let moveFavoriteBefore,
        DragPayloadProvider.containsSidebarFavoritePayload(in: providers)
      {
        DragPayloadProvider.loadSidebarFavoritePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            moveFavoriteBefore(payload.favoriteID, beforeFavoriteID)
          }
        }
        return true
      }

      guard let destinationURL else { return false }
      return activeModel.acceptDrop(providers, to: destinationURL)
    }
    .onDisappear { cancelFocusTask() }
  }

  private func updateDropTarget(_ targeted: Bool) {
    cancelFocusTask()
    guard targeted else {
      isFileDropTargeted = false
      isReorderDropTargeted = false
      return
    }

    let isReorder =
      beforeFavoriteID != nil
      && DragPayloadProvider.draggingPasteboardContains(.nafiSidebarFavorite)
    isReorderDropTargeted = isReorder
    isFileDropTargeted = !isReorder && destinationURL != nil

    guard isFileDropTargeted else { return }
    focusTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 850_000_000)
      guard !Task.isCancelled, isFileDropTargeted else { return }
      action()
    }
  }

  private func cancelFocusTask() {
    focusTask?.cancel()
    focusTask = nil
  }
}

private struct SidebarReorderDropModifier: ViewModifier {
  @ObservedObject var model: SidebarModel
  let beforeID: UUID
  @State private var targeted = false

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if targeted {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
            .offset(y: -2)
            .allowsHitTesting(false)
        }
      }
      .onDrop(of: [.nafiSidebarFavorite], isTargeted: $targeted) { providers in
        guard DragPayloadProvider.containsSidebarFavoritePayload(in: providers) else {
          return false
        }
        DragPayloadProvider.loadSidebarFavoritePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            model.move(itemID: payload.favoriteID, before: beforeID)
          }
        }
        return true
      }
  }
}

private struct SidebarReorderEndTarget: View {
  @ObservedObject var model: SidebarModel
  @State private var targeted = false

  var body: some View {
    Rectangle()
      .fill(Color.clear)
      .frame(height: 10)
      .overlay(alignment: .top) {
        if targeted {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
        }
      }
      .contentShape(Rectangle())
      .onDrop(of: [.nafiSidebarFavorite], isTargeted: $targeted) { providers in
        guard DragPayloadProvider.containsSidebarFavoritePayload(in: providers) else {
          return false
        }
        DragPayloadProvider.loadSidebarFavoritePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            model.moveToEnd(itemID: payload.favoriteID)
          }
        }
        return true
      }
  }
}

private struct ServerSidebarRow: View {
  @EnvironmentObject private var appState: AppState
  let profile: ServerProfile
  @ObservedObject var manager: ServerManager
  let edit: () -> Void

  @State private var isDropTargeted = false
  @State private var focusTask: Task<Void, Never>?

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: profile.kind.systemImage).frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name).lineLimit(1)
        Text(profile.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if isDropTargeted {
        Image(systemName: "arrow.down.to.line")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
      } else {
        stateIndicator
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, 11)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .background(
      isDropTargeted ? Color.accentColor.opacity(0.22) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: 1.5)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { activate() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { activate() }
    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .onDrop(
      of: DragPayloadProvider.fileDropTypes,
      isTargeted: Binding(
        get: { isDropTargeted },
        set: { updateDropTarget($0) }
      )
    ) { providers in
      focusTask?.cancel()
      let move = !NSEvent.modifierFlags.contains(.option)
      DragPayloadProvider.loadFileURLs(from: providers) { urls in
        guard !urls.isEmpty else { return }
        Task { @MainActor in
          guard let destination = await manager.activate(profile) else { return }
          appState.activeModel.transferItems(urls, to: destination, move: move)
        }
      }
      return true
    }
    .contextMenu {
      Button(manager.state(for: profile) == .idle ? "接続" : "開く") { activate() }
      Button("新しいタブで開く") {
        Task {
          if let url = await manager.activate(profile) { appState.openInNewTab(url) }
        }
      }
      Button("新しいペインで開く") {
        Task {
          if let url = await manager.activate(profile) { appState.openInNewPane(url) }
        }
      }
      if profile.kind == .sftp {
        Button("ここでターミナルを開く") {
          Task {
            guard let url = await manager.activate(profile) else { return }
            do {
              try await TerminalApplicationService.open(at: url)
            } catch {
              appState.presentationErrorMessage = error.localizedDescription
            }
          }
        }
      }
      Button("切断") { Task { await manager.disconnect(profile) } }
      Divider()
      Button("編集", action: edit)
      Button("削除", role: .destructive) { manager.remove(profile) }
    }
    .help(helpText)
    .onDisappear { focusTask?.cancel() }
  }

  private func activate() {
    Task {
      if let url = await manager.activate(profile) {
        appState.activeModel.navigate(to: url)
      } else if case .failed(let message) = manager.state(for: profile) {
        appState.presentationErrorMessage = message
      } else if case .helperRequired(let message) = manager.state(for: profile) {
        appState.presentationErrorMessage = message
      }
    }
  }

  private func updateDropTarget(_ targeted: Bool) {
    focusTask?.cancel()
    isDropTargeted = targeted
    guard targeted else { return }
    focusTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 850_000_000)
      guard !Task.isCancelled, isDropTargeted else { return }
      activate()
    }
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

        Section("よく使う項目 — ハンドルをドラッグして並べ替え") {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.favorites) { favorite in
                SidebarCustomizationRow(favorite: favorite, model: model)
                  .modifier(SidebarReorderDropModifier(model: model, beforeID: favorite.id))
              }
              SidebarReorderEndTarget(model: model)
            }
            .padding(.vertical, 4)
          }
          .frame(minHeight: 210, maxHeight: 250)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
          }
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
    .frame(width: 520, height: 530)
  }
}

private struct SidebarCustomizationRow: View {
  let favorite: SidebarFavorite
  @ObservedObject var model: SidebarModel

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .frame(width: 20, height: 28)
        .contentShape(Rectangle())
        .onDrag {
          DragPayloadProvider.sidebarFavoriteProvider(for: favorite.id)
        }
        .help("ドラッグして並べ替え")

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
      Spacer(minLength: 8)
      if !favorite.isBuiltIn {
        Button(role: .destructive) {
          model.remove(favorite)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 36)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      Divider().padding(.leading, 48)
    }
  }
}
