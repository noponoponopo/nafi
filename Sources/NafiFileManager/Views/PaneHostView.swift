import SwiftUI

struct PaneHostView: View {
  @ObservedObject var session: PaneSession
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      PaneNavigationBar(
        model: session.activeModel,
        canClosePane: workspace.paneCount > 1,
        onClosePane: { workspace.closePane(session.id) }
      )
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
        renameSelection: session.activeModel.requestRenameSelected,
        canGoBack: { session.activeModel.canGoBack },
        canGoForward: { session.activeModel.canGoForward },
        goBack: session.activeModel.goBack,
        goForward: session.activeModel.goForward
      )
    )
  }
}
