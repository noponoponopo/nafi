import Foundation

/// A split-pane session owns exactly one file model. Browser tabs are provided
/// exclusively by NSWindow's native tab group.
@MainActor
final class PaneSession: ObservableObject, Identifiable {
  let id: UUID
  let activeModel: FilePaneModel

  init(id: UUID = UUID(), initialURL: URL, showHidden: Bool, viewMode: FileViewMode) {
    self.id = id
    activeModel = FilePaneModel(
      initialURL: initialURL,
      showHidden: showHidden,
      viewMode: viewMode
    )
  }

  init(id: UUID = UUID(), model: FilePaneModel) {
    self.id = id
    activeModel = model
  }

  var activeTabID: UUID { activeModel.id }

  func loadAll() {
    activeModel.load()
  }
}
