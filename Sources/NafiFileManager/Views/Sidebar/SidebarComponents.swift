import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarSectionHeader: View {
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
    // +ボタン中心を ServerSidebarRow の状態インジケーター中心
    // (8 + 11 + 3.5 = 22.5pt from right) に揃える。
    // listRowInsets.trailing(4) + frame(26)/2(13) を加味すると trailing は 5.5。
    .padding(.trailing, 5.5)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .center)
    .contentShape(Rectangle())
    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 1, trailing: 4))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

struct SidebarDestinationRow: View {
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
      .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
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

struct ServerSidebarRow: View {
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
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
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
      Button("削除", role: .destructive) {
        do { try manager.remove(profile) }
        catch { appState.presentationErrorMessage = error.localizedDescription }
      }
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
