import SwiftUI

struct PaneHostView: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      PaneTabStripView(session: session, workspace: workspace)
      PaneNavigationBar(model: session.activeModel)
      FilePaneView(model: session.activeModel)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .background(
      PaneInputMonitor(
        isActive: workspace.activePaneID == session.id,
        activate: { workspace.focus(session.id) },
        moveSelection: session.activeModel.moveSelection,
        clearSelection: session.activeModel.clearSelection,
        previewSelection: session.activeModel.previewSelected,
        canGoBack: { session.activeModel.canGoBack },
        canGoForward: { session.activeModel.canGoForward },
        goBack: session.activeModel.goBack,
        goForward: session.activeModel.goForward
      )
    )
    .overlay { PaneSplitDropOverlay(targetPaneID: session.id, workspace: workspace) }
  }
}

private struct PaneTabStripView: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel
  @State private var tabDropTargeted = false

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
            .draggable(
              PaneDragPayload(sourcePaneID: session.id, sourceTabID: tab.id, url: tab.currentURL)
            )
            .dropDestination(for: PaneDragPayload.self) { payloads, _ in
              guard let payload = payloads.first else { return false }
              workspace.placeTabPayload(payload, in: session.id, before: tab.id)
              return true
            }
          }
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
    .background(tabDropTargeted ? Color.accentColor.opacity(0.11) : Color.clear)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .dropDestination(for: PaneDragPayload.self) { payloads, _ in
      guard let payload = payloads.first else { return false }
      workspace.placeTabPayload(payload, in: session.id)
      return true
    } isTargeted: {
      tabDropTargeted = $0
    }
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
      Image(systemName: "folder.fill")
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
    .frame(minWidth: 104, maxWidth: 200)
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

private struct PaneSplitDropOverlay: View {
  let targetPaneID: UUID
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        edgeZone(.leading, frame: CGRect(x: 0, y: 0, width: 12, height: proxy.size.height))
        edgeZone(
          .trailing,
          frame: CGRect(x: proxy.size.width - 12, y: 0, width: 12, height: proxy.size.height))
        edgeZone(.top, frame: CGRect(x: 12, y: 0, width: max(0, proxy.size.width - 24), height: 12))
        edgeZone(
          .bottom,
          frame: CGRect(
            x: 12, y: proxy.size.height - 12, width: max(0, proxy.size.width - 24), height: 12))
      }
    }
  }

  private func edgeZone(_ edge: PaneDropEdge, frame: CGRect) -> some View {
    PaneEdgeDropZone(edge: edge, targetPaneID: targetPaneID, workspace: workspace)
      .frame(width: frame.width, height: frame.height)
      .position(x: frame.midX, y: frame.midY)
  }
}

private struct PaneEdgeDropZone: View {
  let edge: PaneDropEdge
  let targetPaneID: UUID
  @ObservedObject var workspace: WorkspaceModel
  @State private var targeted = false

  var body: some View {
    Rectangle()
      .fill(targeted ? Color.accentColor.opacity(0.28) : Color.clear)
      .overlay {
        if targeted {
          Image(
            systemName: edge.axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"
          )
          .font(.title2)
          .foregroundStyle(Color.accentColor)
        }
      }
      .dropDestination(for: PaneDragPayload.self) { payloads, _ in
        guard let payload = payloads.first else { return false }
        workspace.splitTabPayload(payload, targetPaneID: targetPaneID, edge: edge)
        return true
      } isTargeted: {
        targeted = $0
      }
  }
}
