import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    PaneTreeView(node: workspace.root, workspace: workspace)
      .animation(.snappy(duration: 0.2), value: workspace.root.id)
  }
}

private struct PaneTreeView: View {
  let node: PaneLayoutNode
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    switch node {
    case .pane(let paneID):
      if let session = workspace.session(for: paneID) {
        PaneHostView(session: session, workspace: workspace)
          .frame(minWidth: 220, minHeight: 160)
      }
    case .split(_, let axis, let first, let second):
      if axis == .horizontal {
        HSplitView {
          PaneTreeView(node: first, workspace: workspace)
          PaneTreeView(node: second, workspace: workspace)
        }
      } else {
        VSplitView {
          PaneTreeView(node: first, workspace: workspace)
          PaneTreeView(node: second, workspace: workspace)
        }
      }
    }
  }
}
