import Foundation

indirect enum PaneLayoutSnapshot: Codable, Hashable, Sendable {
  case pane(UUID)
  case split(id: UUID, axis: PaneSplitAxis, first: PaneLayoutSnapshot, second: PaneLayoutSnapshot)

  private enum CodingKeys: String, CodingKey { case kind, id, axis, first, second }
  private enum Kind: String, Codable { case pane, split }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pane:
      self = .pane(try container.decode(UUID.self, forKey: .id))
    case .split:
      self = .split(
        id: try container.decode(UUID.self, forKey: .id),
        axis: try container.decode(PaneSplitAxis.self, forKey: .axis),
        first: try container.decode(PaneLayoutSnapshot.self, forKey: .first),
        second: try container.decode(PaneLayoutSnapshot.self, forKey: .second)
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let id):
      try container.encode(Kind.pane, forKey: .kind)
      try container.encode(id, forKey: .id)
    case .split(let id, let axis, let first, let second):
      try container.encode(Kind.split, forKey: .kind)
      try container.encode(id, forKey: .id)
      try container.encode(axis, forKey: .axis)
      try container.encode(first, forKey: .first)
      try container.encode(second, forKey: .second)
    }
  }
}

struct WorkspaceSnapshot: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var updatedAt = Date()
  var root: PaneLayoutSnapshot
  var activePaneID: UUID
  var panes: [FilePaneModel.StateSnapshot]
}

@MainActor
final class WorkspaceLibrary: ObservableObject {
  static let shared = WorkspaceLibrary()

  @Published private(set) var named: [WorkspaceSnapshot] = []
  @Published var errorMessage: String?

  private struct Storage: Codable {
    var version = 1
    var named: [WorkspaceSnapshot]
    var lastSession: [WorkspaceSnapshot]
  }

  private let fileURL = AppStoragePaths.file(named: "workspaces.json")
  private var lastSession: [WorkspaceSnapshot] = []
  private var didConsumeInitial = false
  private var didConsumeRemaining = false

  private init() { load() }

  func saveNamed(name: String, workspace: WorkspaceModel) {
    let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    guard !clean.isEmpty else { errorMessage = "ワークスペース名を入力してください。"; return }
    var snapshot = workspace.makeSnapshot(name: clean)
    let previous = named
    if let existing = named.firstIndex(where: {
      $0.name.compare(clean, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }) {
      snapshot.id = named[existing].id
      named[existing] = snapshot
    } else {
      named.append(snapshot)
    }
    named.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if !persist() { named = previous }
  }

  func remove(_ snapshot: WorkspaceSnapshot) {
    let previous = named
    named.removeAll { $0.id == snapshot.id }
    if !persist() { named = previous }
  }

  func saveLastSession(_ workspaces: [WorkspaceModel]) {
    let previous = lastSession
    lastSession = Array(workspaces.prefix(64).map { $0.makeSnapshot(name: "前回のセッション") })
    if !persist() { lastSession = previous }
  }

  func consumeInitialRestoration() -> WorkspaceSnapshot? {
    guard !didConsumeInitial else { return nil }
    didConsumeInitial = true
    return lastSession.first
  }

  func consumeRemainingRestoration() -> [WorkspaceSnapshot] {
    guard !didConsumeRemaining else { return [] }
    didConsumeRemaining = true
    return Array(lastSession.dropFirst().prefix(63))
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: fileURL,
        maximumBytes: 32 * 1_024 * 1_024
      )
      let storage = try JSONDecoder().decode(Storage.self, from: data)
      guard storage.version == 1,
        storage.named.count <= 10_000, storage.lastSession.count <= 64
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let validNamed = storage.named.compactMap(Self.validated)
      let validSession = storage.lastSession.compactMap(Self.validated)
      named = Self.deduplicated(validNamed, maximum: 10_000)
      lastSession = Array(Self.deduplicated(validSession, maximum: 64).prefix(64))
      if named.count != storage.named.count || lastSession.count != storage.lastSession.count {
        errorMessage = "壊れたワークスペース項目を除外しました。正常な項目は保持されています。"
        persist()
      }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: fileURL)
      errorMessage = "ワークスペース設定を隔離しました。\n\(error.localizedDescription)"
    }
  }

  private static func validated(_ input: WorkspaceSnapshot) -> WorkspaceSnapshot? {
    guard !input.name.isEmpty, input.name.utf8.count <= 1_024,
      input.panes.count > 0, input.panes.count <= 64
    else { return nil }

    var paneIDs = Set<UUID>()
    var panes: [FilePaneModel.StateSnapshot] = []
    panes.reserveCapacity(input.panes.count)
    for var pane in input.panes {
      guard paneIDs.insert(pane.id).inserted, validURL(pane.currentURL) else { return nil }
      pane.searchText = String(pane.searchText.prefix(1_024))
      pane.searchExtensionsText = String(pane.searchExtensionsText.prefix(4_096))
      pane.backStack = Array(pane.backStack.filter(validURL).suffix(200))
      pane.forwardStack = Array(pane.forwardStack.filter(validURL).suffix(200))
      pane.iconSize = min(max(pane.iconSize.isFinite ? pane.iconSize : 64, 24), 256)
      panes.append(pane)
    }

    var referenced = Set<UUID>()
    var layoutIDs = Set<UUID>()
    guard validateLayout(
      input.root,
      paneIDs: paneIDs,
      referenced: &referenced,
      layoutIDs: &layoutIDs,
      depth: 0
    ),
      referenced == paneIDs
    else { return nil }

    var result = input
    result.name = String(input.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    guard !result.name.isEmpty else { return nil }
    result.panes = panes
    if !paneIDs.contains(result.activePaneID) { result.activePaneID = panes[0].id }
    if result.updatedAt > Date().addingTimeInterval(24 * 60 * 60) { result.updatedAt = Date() }
    return result
  }

  private static func validateLayout(
    _ value: PaneLayoutSnapshot,
    paneIDs: Set<UUID>,
    referenced: inout Set<UUID>,
    layoutIDs: inout Set<UUID>,
    depth: Int
  ) -> Bool {
    guard depth <= 64 else { return false }
    switch value {
    case .pane(let id):
      return paneIDs.contains(id) && referenced.insert(id).inserted
    case .split(let id, _, let first, let second):
      guard layoutIDs.insert(id).inserted, !paneIDs.contains(id) else { return false }
      return validateLayout(
        first,
        paneIDs: paneIDs,
        referenced: &referenced,
        layoutIDs: &layoutIDs,
        depth: depth + 1
      ) && validateLayout(
        second,
        paneIDs: paneIDs,
        referenced: &referenced,
        layoutIDs: &layoutIDs,
        depth: depth + 1
      )
    }
  }

  private static func validURL(_ url: URL) -> Bool {
    guard url.absoluteString.utf8.count <= 16_384, url.user == nil, url.password == nil else { return false }
    if url.isFileURL { return url.path.utf8.count <= 8_192 }
    return NafiURL.isRemote(url) && NafiURL.profileID(in: url) != nil
      && (NafiURL.remotePath(in: url)?.utf8.count ?? Int.max) <= 8_192
  }

  private static func deduplicated(
    _ values: [WorkspaceSnapshot], maximum: Int
  ) -> [WorkspaceSnapshot] {
    var seenIDs = Set<UUID>()
    var seenNames = Set<String>()
    return values.filter {
      let nameKey = $0.name.folding(
        options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
        locale: .current
      )
      return seenIDs.insert($0.id).inserted && seenNames.insert(nameKey).inserted
    }.prefix(maximum).map { $0 }
  }

  @discardableResult
  private func persist() -> Bool {
    do {
      let data = try JSONEncoder().encode(Storage(named: named, lastSession: lastSession))
      guard data.count <= 32 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
      try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path
      )
      errorMessage = nil
      return true
    } catch {
      errorMessage = "ワークスペースを保存できません。\n\(error.localizedDescription)"
      return false
    }
  }
}
