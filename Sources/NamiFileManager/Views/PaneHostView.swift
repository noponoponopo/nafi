import SwiftUI
import UniformTypeIdentifiers

struct PaneHostView: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      if session.tabs.count > 1 {
        PaneTabStripView(session: session, workspace: workspace)
      }
      PaneNavigationBar(model: session.activeModel)
      FilePaneView(model: session.activeModel, splitDropTargetPaneID: session.id)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .background(
      PaneInputMonitor(
        isActive: workspace.activePaneID == session.id,
        activate: { workspace.focus(session.id) },
        moveSelection: session.activeModel.moveSelection,
        clearSelection: session.activeModel.clearSelection,
        previewSelection: session.activeModel.previewSelected,
        renameSelection: session.activeModel.requestRenameSelected,
        canGoBack: { session.activeModel.canGoBack },
        canGoForward: { session.activeModel.canGoForward },
        goBack: session.activeModel.goBack,
        goForward: session.activeModel.goForward
      )
    )
  }
}

private struct PaneTabStripView: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
          ForEach(session.tabs) { tab in
            PaneTabButton(
              model: tab,
              isActive: tab.id == session.activeTabID,
              canClose: session.tabs.count > 1 || workspace.paneCount > 1,
              select: {
                workspace.focus(session.id)
                session.selectTab(tab.id)
              },
              close: {
                if !session.closeTab(tab.id) {
                  workspace.closePane(session.id)
                }
              }
            )
            .onDrag {
              DragPayloadProvider.paneProvider(
                for: PaneDragPayload(
                  sourcePaneID: session.id,
                  sourceTabID: tab.id,
                  url: tab.currentURL
                )
              )
            }
            .modifier(
              TabDestinationDropModifier(
                session: session,
                workspace: workspace,
                model: tab,
                tabID: tab.id
              )
            )
          }

          TabAppendDropTarget(session: session, workspace: workspace)
        }
        .padding(.horizontal, 6)
      }

      Divider().frame(height: 18)

      Button {
        workspace.newTab(in: session.id)
      } label: {
        Image(systemName: "plus")
          .frame(width: 30, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("新規タブ")
    }
    .frame(height: 35)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

private struct TabDestinationDropModifier: ViewModifier {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel
  @ObservedObject var model: FilePaneModel
  let tabID: UUID

  @State private var fileTargeted = false
  @State private var reorderTargeted = false
  @State private var focusTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .overlay {
        if fileTargeted {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .trailing) {
        if fileTargeted {
          Image(systemName: "arrow.down.to.line")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.trailing, 7)
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .leading) {
        if reorderTargeted {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 4, height: 24)
            .offset(x: -3)
            .shadow(radius: 1)
            .allowsHitTesting(false)
        }
      }
      .onDrop(
        of: DragPayloadProvider.tabDropTypes,
        isTargeted: Binding(
          get: { fileTargeted || reorderTargeted },
          set: { updateTargeted($0) }
        )
      ) { providers in
        cancelFocusTask()

        if DragPayloadProvider.containsPanePayload(in: providers) {
          DragPayloadProvider.loadPanePayload(from: providers) { payload in
            guard let payload else { return }
            Task { @MainActor in
              workspace.placeTabPayload(payload, in: session.id, before: tabID)
            }
          }
          return true
        }

        guard DragPayloadProvider.canLoadFileURLs(from: providers) else { return false }
        workspace.focus(session.id)
        session.selectTab(tabID)
        return model.acceptDrop(providers, to: model.currentURL)
      }
      .onDisappear { cancelFocusTask() }
  }

  private func updateTargeted(_ isTargeted: Bool) {
    cancelFocusTask()
    guard isTargeted else {
      fileTargeted = false
      reorderTargeted = false
      return
    }

    let isTabReorder = DragPayloadProvider.draggingPasteboardContains(.nafiPaneTab)
    reorderTargeted = isTabReorder
    fileTargeted = !isTabReorder

    focusTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard !Task.isCancelled, fileTargeted || reorderTargeted else { return }
      workspace.focus(session.id)
      session.selectTab(tabID)
    }
  }

  private func cancelFocusTask() {
    focusTask?.cancel()
    focusTask = nil
  }
}

private struct TabAppendDropTarget: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel
  @State private var targeted = false

  var body: some View {
    Rectangle()
      .fill(targeted ? Color.accentColor.opacity(0.1) : Color.clear)
      .frame(width: 28, height: 28)
      .overlay(alignment: .leading) {
        if targeted {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 4, height: 24)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .onDrop(of: [.nafiPaneTab], isTargeted: $targeted) { providers in
        guard DragPayloadProvider.containsPanePayload(in: providers) else { return false }
        DragPayloadProvider.loadPanePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            workspace.placeTabPayload(payload, in: session.id)
          }
        }
        return true
      }
      .help("ここへ移動")
  }
}

private struct PaneTabButton: View {
  @ObservedObject var model: FilePaneModel
  let isActive: Bool
  let canClose: Bool
  let select: () -> Void
  let close: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: model.isRemote ? "network" : "folder.fill")
        .font(.caption)
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
      Text(model.title)
        .lineLimit(1)
        .truncationMode(.middle)
      if canClose {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isActive ? 1 : 0.55)
      }
    }
    .font(.system(size: 12.5))
    .padding(.horizontal, 10)
    .frame(height: 28)
    .frame(minWidth: 92, maxWidth: 200)
    .background(
      isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .contextMenu {
      Button("タブを閉じる", action: close)
    }
  }
}

struct PaneSplitDropOverlay: View {
  let targetPaneID: UUID
  @ObservedObject var workspace: WorkspaceModel
  let topInset: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let contentHeight = max(0, proxy.size.height - topInset)

      ZStack {
        edgeZone(
          .leading,
          frame: CGRect(x: 0, y: topInset, width: 24, height: contentHeight)
        )
        edgeZone(
          .trailing,
          frame: CGRect(
            x: proxy.size.width - 24,
            y: topInset,
            width: 24,
            height: contentHeight
          )
        )
        edgeZone(
          .top,
          frame: CGRect(
            x: 24,
            y: topInset,
            width: max(0, proxy.size.width - 48),
            height: min(24, contentHeight)
          )
        )
        edgeZone(
          .bottom,
          frame: CGRect(
            x: 24,
            y: max(topInset, proxy.size.height - 24),
            width: max(0, proxy.size.width - 48),
            height: min(24, contentHeight)
          )
        )
      }
    }
  }

  private func edgeZone(_ edge: PaneDropEdge, frame: CGRect) -> some View {
    PaneEdgeDropZone(edge: edge, targetPaneID: targetPaneID, workspace: workspace)
      .frame(width: frame.width, height: frame.height)
      .position(x: frame.midX, y: frame.midY)
  }
}

struct PaneEdgeDropZone: View {
  let edge: PaneDropEdge
  let targetPaneID: UUID
  @ObservedObject var workspace: WorkspaceModel
  @State private var targeted = false

  var body: some View {
    Rectangle()
      .fill(targeted ? Color.accentColor.opacity(0.3) : Color.clear)
      .overlay {
        if targeted {
          Image(
            systemName: edge.axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"
          )
          .font(.title2)
          .foregroundStyle(Color.accentColor)
        }
      }
      .overlay {
        if targeted {
          Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
        }
      }
      .onDrop(of: [.nafiPaneTab], isTargeted: $targeted) { providers in
        guard DragPayloadProvider.containsPanePayload(in: providers) else { return false }
        DragPayloadProvider.loadPanePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            workspace.splitTabPayload(payload, targetPaneID: targetPaneID, edge: edge)
          }
        }
        return true
      }
  }
}
