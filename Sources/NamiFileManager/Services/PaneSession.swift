import Foundation

@MainActor
final class PaneSession: ObservableObject, Identifiable {
  let id: UUID
  @Published private(set) var tabs: [FilePaneModel]
  @Published var activeTabID: UUID

  init(id: UUID = UUID(), initialURL: URL, showHidden: Bool, viewMode: FileViewMode) {
    self.id = id
    let model = FilePaneModel(initialURL: initialURL, showHidden: showHidden, viewMode: viewMode)
    self.tabs = [model]
    self.activeTabID = model.id
  }

  init(id: UUID = UUID(), model: FilePaneModel) {
    self.id = id
    self.tabs = [model]
    self.activeTabID = model.id
  }

  var activeModel: FilePaneModel {
    tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
  }

  func newTab(at url: URL, showHidden: Bool? = nil, viewMode: FileViewMode? = nil) {
    let source = activeModel
    let model = FilePaneModel(
      initialURL: url,
      showHidden: showHidden ?? source.showHidden,
      viewMode: viewMode ?? source.viewMode
    )
    tabs.append(model)
    activeTabID = model.id
    model.load()
  }

  func addClonedTab(from source: FilePaneModel) {
    let model = source.clone()
    tabs.append(model)
    activeTabID = model.id
    model.load()
  }

  func insertTab(_ model: FilePaneModel, before tabID: UUID? = nil) {
    if let tabID, let index = tabs.firstIndex(where: { $0.id == tabID }) {
      tabs.insert(model, at: index)
    } else {
      tabs.append(model)
    }
    activeTabID = model.id
    model.load()
  }

  func moveTab(_ tabID: UUID, before destinationTabID: UUID) {
    guard tabID != destinationTabID,
      let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
      let destinationIndex = tabs.firstIndex(where: { $0.id == destinationTabID })
    else { return }
    let model = tabs.remove(at: sourceIndex)
    let adjustedIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
    tabs.insert(model, at: max(0, adjustedIndex))
    activeTabID = model.id
  }

  func detachTab(_ tabID: UUID) -> FilePaneModel? {
    guard tabs.count > 1,
      let index = tabs.firstIndex(where: { $0.id == tabID })
    else { return nil }
    let model = tabs.remove(at: index)
    if activeTabID == tabID {
      activeTabID = tabs[min(index, tabs.count - 1)].id
    }
    return model
  }

  @discardableResult
  func closeTab(_ tabID: UUID) -> Bool {
    guard tabs.count > 1 else { return false }
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
    let wasActive = activeTabID == tabID
    tabs.remove(at: index)
    if wasActive {
      activeTabID = tabs[min(index, tabs.count - 1)].id
    }
    return true
  }

  func selectTab(_ id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    activeTabID = id
  }

  func loadAll() {
    for tab in tabs {
      tab.load()
    }
  }
}
