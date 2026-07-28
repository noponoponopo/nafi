import Foundation

indirect enum PaneLayoutNode: Identifiable {
  case pane(UUID)
  case split(id: UUID, axis: PaneSplitAxis, first: PaneLayoutNode, second: PaneLayoutNode)

  var id: UUID {
    switch self {
    case .pane(let id): id
    case .split(let id, _, _, _): id
    }
  }
}

enum PaneSplitAxis: String, CaseIterable, Identifiable {
  case horizontal
  case vertical

  var id: String { rawValue }
  var label: String { self == .horizontal ? "左右" : "上下" }
  var systemImage: String { self == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

enum PaneDropEdge {
  case leading
  case trailing
  case top
  case bottom

  var axis: PaneSplitAxis {
    switch self {
    case .leading, .trailing: .horizontal
    case .top, .bottom: .vertical
    }
  }

  var insertsBefore: Bool {
    self == .leading || self == .top
  }
}

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published private(set) var root: PaneLayoutNode
  @Published private(set) var sessions: [UUID: PaneSession]
  @Published var activePaneID: UUID

  init(initialURL: URL, showHidden: Bool, viewMode: FileViewMode) {
    let session = PaneSession(initialURL: initialURL, showHidden: showHidden, viewMode: viewMode)
    self.sessions = [session.id: session]
    self.root = .pane(session.id)
    self.activePaneID = session.id
  }

  var activeSession: PaneSession {
    sessions[activePaneID] ?? sessions.values.first!
  }

  var activeModel: FilePaneModel { activeSession.activeModel }
  var paneCount: Int { sessions.count }
  var allModels: [FilePaneModel] { sessions.values.flatMap(\.tabs) }

  func session(for id: UUID) -> PaneSession? { sessions[id] }

  func focus(_ paneID: UUID) {
    guard sessions[paneID] != nil else { return }
    activePaneID = paneID
  }

  func loadAll() {
    for session in sessions.values {
      session.loadAll()
    }
  }

  @discardableResult
  func newTab(in paneID: UUID? = nil, at url: URL? = nil) -> FilePaneModel? {
    let targetID = paneID ?? activePaneID
    guard let session = sessions[targetID] else { return nil }
    focus(targetID)
    return session.newTab(at: url ?? session.activeModel.currentURL)
  }

  func closeActiveTab() {
    let session = activeSession
    if !session.closeTab(session.activeTabID), paneCount > 1 {
      closePane(session.id)
    }
  }

  func splitActive(axis: PaneSplitAxis) {
    let edge: PaneDropEdge = axis == .horizontal ? .trailing : .bottom
    split(paneID: activePaneID, edge: edge, opening: activeModel.currentURL)
  }

  func split(paneID: UUID, edge: PaneDropEdge, opening url: URL) {
    guard let source = sessions[paneID] else { return }
    let model = FilePaneModel(
      initialURL: url,
      showHidden: source.activeModel.showHidden,
      viewMode: source.activeModel.viewMode
    )
    split(paneID: paneID, edge: edge, model: model)
  }

  func placeTabPayload(_ payload: PaneDragPayload, in paneID: UUID, before tabID: UUID? = nil) {
    guard let target = sessions[paneID] else { return }
    if payload.sourcePaneID == paneID {
      if let tabID {
        target.moveTab(payload.sourceTabID, before: tabID)
      } else {
        target.moveTabToEnd(payload.sourceTabID)
      }
      focus(paneID)
      return
    }

    let model = movableModel(for: payload)
    target.insertTab(model, before: tabID)
    focus(paneID)
  }

  func splitTabPayload(_ payload: PaneDragPayload, targetPaneID: UUID, edge: PaneDropEdge) {
    let model = movableModel(for: payload)
    split(paneID: targetPaneID, edge: edge, model: model)
  }

  private func movableModel(for payload: PaneDragPayload) -> FilePaneModel {
    guard let source = sessions[payload.sourcePaneID],
      let original = source.tabs.first(where: { $0.id == payload.sourceTabID })
    else {
      return FilePaneModel(initialURL: payload.url)
    }

    if let detached = source.detachTab(payload.sourceTabID) {
      return detached
    }
    return original.clone()
  }

  private func split(paneID: UUID, edge: PaneDropEdge, model: FilePaneModel) {
    guard sessions[paneID] != nil else { return }
    let newSession = PaneSession(model: model)
    newSession.activeModel.load()
    sessions[newSession.id] = newSession

    let oldNode = PaneLayoutNode.pane(paneID)
    let newNode = PaneLayoutNode.pane(newSession.id)
    let replacement: PaneLayoutNode
    if edge.insertsBefore {
      replacement = .split(id: UUID(), axis: edge.axis, first: newNode, second: oldNode)
    } else {
      replacement = .split(id: UUID(), axis: edge.axis, first: oldNode, second: newNode)
    }
    root = replacingPane(in: root, paneID: paneID, with: replacement)
    activePaneID = newSession.id
  }

  func closePane(_ paneID: UUID) {
    guard sessions.count > 1 else { return }
    guard let updated = removingPane(from: root, paneID: paneID) else { return }
    sessions[paneID] = nil
    root = updated
    if activePaneID == paneID {
      activePaneID = firstPaneID(in: updated) ?? sessions.keys.first!
    }
  }

  func openInNewPane(_ url: URL) {
    split(paneID: activePaneID, edge: .trailing, opening: url)
  }

  private func replacingPane(
    in node: PaneLayoutNode, paneID: UUID, with replacement: PaneLayoutNode
  ) -> PaneLayoutNode {
    switch node {
    case .pane(let id):
      return id == paneID ? replacement : node
    case .split(let id, let axis, let first, let second):
      return .split(
        id: id,
        axis: axis,
        first: replacingPane(in: first, paneID: paneID, with: replacement),
        second: replacingPane(in: second, paneID: paneID, with: replacement)
      )
    }
  }

  private func removingPane(from node: PaneLayoutNode, paneID: UUID) -> PaneLayoutNode? {
    switch node {
    case .pane(let id):
      return id == paneID ? nil : node
    case .split(let id, let axis, let first, let second):
      let newFirst = removingPane(from: first, paneID: paneID)
      let newSecond = removingPane(from: second, paneID: paneID)
      switch (newFirst, newSecond) {
      case (nil, nil): return nil
      case (let remaining?, nil), (nil, let remaining?): return remaining
      case (let first?, let second?):
        return .split(id: id, axis: axis, first: first, second: second)
      }
    }
  }

  private func firstPaneID(in node: PaneLayoutNode) -> UUID? {
    switch node {
    case .pane(let id): return id
    case .split(_, _, let first, _): return firstPaneID(in: first)
    }
  }
}
