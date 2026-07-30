import Combine
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

enum PaneSplitAxis: String, Codable, CaseIterable, Identifiable, Sendable {
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

  private var sessionObservers: [UUID: AnyCancellable] = [:]

  init(initialURL: URL, showHidden: Bool, viewMode: FileViewMode) {
    let session = PaneSession(initialURL: initialURL, showHidden: showHidden, viewMode: viewMode)
    sessions = [session.id: session]
    root = .pane(session.id)
    activePaneID = session.id
    bindSession(session)
  }

  init(snapshot: WorkspaceSnapshot) {
    var restored: [UUID: PaneSession] = [:]
    for pane in snapshot.panes.prefix(64) {
      let model = FilePaneModel.restore(from: pane)
      restored[pane.id] = PaneSession(id: pane.id, model: model)
    }
    if restored.isEmpty {
      let model = FilePaneModel(
        initialURL: FileManager.default.homeDirectoryForCurrentUser,
        showHidden: false,
        viewMode: .list
      )
      restored[model.id] = PaneSession(id: model.id, model: model)
    }
    sessions = restored
    let candidate = Self.restoreLayout(snapshot.root, validPaneIDs: Set(restored.keys))
    root = candidate ?? .pane(restored.keys.first!)
    activePaneID = restored[snapshot.activePaneID] == nil ? restored.keys.first! : snapshot.activePaneID
    bindAllSessions()
  }

  var activeSession: PaneSession {
    sessions[activePaneID] ?? sessions.values.first!
  }

  var activeModel: FilePaneModel { activeSession.activeModel }
  var paneCount: Int { sessions.count }
  var allModels: [FilePaneModel] { sessions.values.map(\.activeModel) }

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

  private func split(paneID: UUID, edge: PaneDropEdge, model: FilePaneModel) {
    guard sessions[paneID] != nil else { return }
    let newSession = PaneSession(model: model)
    newSession.activeModel.load()
    sessions[newSession.id] = newSession
    bindSession(newSession)

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
    sessionObservers[paneID] = nil
    root = updated
    if activePaneID == paneID {
      activePaneID = firstPaneID(in: updated) ?? sessions.keys.first!
    }
  }

  func openInNewPane(_ url: URL) {
    split(paneID: activePaneID, edge: .trailing, opening: url)
  }

  func makeSnapshot(name: String) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      name: name,
      root: Self.snapshot(root),
      activePaneID: activePaneID,
      panes: sessions.values.map { $0.activeModel.makeStateSnapshot() }
    )
  }

  func replace(with snapshot: WorkspaceSnapshot) {
    let restored = WorkspaceModel(snapshot: snapshot)
    sessionObservers.removeAll()
    sessions = restored.sessions
    bindAllSessions()
    root = restored.root
    activePaneID = restored.activePaneID
    loadAll()
  }

  private func bindAllSessions() {
    sessionObservers.removeAll(keepingCapacity: true)
    for session in sessions.values { bindSession(session) }
  }

  private func bindSession(_ session: PaneSession) {
    sessionObservers[session.id] = session.activeModel.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  private static func snapshot(_ node: PaneLayoutNode) -> PaneLayoutSnapshot {
    switch node {
    case .pane(let id): return .pane(id)
    case .split(let id, let axis, let first, let second):
      return .split(id: id, axis: axis, first: snapshot(first), second: snapshot(second))
    }
  }

  private static func restoreLayout(
    _ value: PaneLayoutSnapshot, validPaneIDs: Set<UUID>
  ) -> PaneLayoutNode? {
    switch value {
    case .pane(let id): return validPaneIDs.contains(id) ? .pane(id) : nil
    case .split(let id, let axis, let first, let second):
      let a = restoreLayout(first, validPaneIDs: validPaneIDs)
      let b = restoreLayout(second, validPaneIDs: validPaneIDs)
      switch (a, b) {
      case (nil, nil): return nil
      case (let value?, nil), (nil, let value?): return value
      case (let first?, let second?): return .split(id: id, axis: axis, first: first, second: second)
      }
    }
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
