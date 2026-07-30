import AppKit
import Foundation

struct QuickOpenResult: Identifiable, Hashable, Sendable {
  enum Kind: String, Sendable { case location, favorite, server, workspace, spotlight }
  enum Action: Hashable, Sendable {
    case open(URL)
    case restoreWorkspace(UUID)
  }

  let id: String
  let title: String
  let subtitle: String
  let action: Action
  let kind: Kind
  let systemImage: String

  var url: URL? {
    guard case .open(let value) = action else { return nil }
    return value
  }
}

@MainActor
final class QuickOpenModel: ObservableObject {
  @Published var query = "" { didSet { scheduleSearch() } }
  @Published private(set) var results: [QuickOpenResult] = []
  @Published private(set) var isSearching = false
  @Published var errorMessage: String?

  private var baseResults: [QuickOpenResult] = []
  private var searchTask: Task<Void, Never>?

  func prepare(
    currentURL: URL,
    favorites: [SidebarFavorite],
    servers: [ServerProfile],
    workspaces: [WorkspaceSnapshot]
  ) {
    var values: [QuickOpenResult] = [
      result(title: "現在の場所", url: currentURL, kind: .location, image: "location"),
      result(title: "ホーム", url: FileManager.default.homeDirectoryForCurrentUser, kind: .location, image: "house"),
    ]
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    if let downloads { values.append(result(title: "ダウンロード", url: downloads, kind: .location, image: "arrow.down.circle")) }
    values.append(contentsOf: favorites.compactMap { favorite in
      result(title: favorite.title, url: favorite.url, kind: .favorite, image: favorite.systemImage)
    })
    values.append(contentsOf: servers.map {
      result(title: $0.name, url: NafiURL.remoteRoot(for: $0), kind: .server, image: $0.kind.systemImage)
    })
    values.append(contentsOf: workspaces.compactMap { snapshot in
      guard let active = snapshot.panes.first(where: { $0.id == snapshot.activePaneID }) ?? snapshot.panes.first else { return nil }
      return QuickOpenResult(
        id: "workspace:\(snapshot.id.uuidString)",
        title: snapshot.name,
        subtitle: NafiURL.displayPath(active.currentURL),
        action: .restoreWorkspace(snapshot.id),
        kind: .workspace,
        systemImage: "rectangle.3.group"
      )
    })
    var seen = Set<String>()
    baseResults = values.filter { seen.insert($0.id).inserted }
    scheduleSearch(immediate: true)
  }

  func clear() {
    query = ""
    results = baseResults
  }

  private func result(title: String, url: URL, kind: QuickOpenResult.Kind, image: String) -> QuickOpenResult {
    QuickOpenResult(
      id: "\(kind.rawValue):\(NafiURL.normalized(url).absoluteString)",
      title: title,
      subtitle: NafiURL.displayPath(url),
      action: .open(url),
      kind: kind,
      systemImage: image
    )
  }

  private func scheduleSearch(immediate: Bool = false) {
    searchTask?.cancel()
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    searchTask = Task { [weak self] in
      if !immediate { try? await Task.sleep(nanoseconds: 160_000_000) }
      guard !Task.isCancelled, let self else { return }
      await self.performSearch(query)
    }
  }

  private func performSearch(_ query: String) async {
    if query.isEmpty {
      results = baseResults
      isSearching = false
      return
    }
    let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    let matchingBase = baseResults.filter {
      ($0.title + " " + $0.subtitle)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .contains(folded)
    }
    isSearching = true
    let spotlight = await SpotlightSearchService.search(nameContaining: query, limit: 250)
    guard !Task.isCancelled else { return }
    var seen = Set(matchingBase.map(\.id))
    results = matchingBase + spotlight.filter { seen.insert($0.id).inserted }
    isSearching = false
  }
}

@MainActor
private enum SpotlightSearchService {
  static func search(nameContaining text: String, limit: Int) async -> [QuickOpenResult] {
    guard !text.isEmpty else { return [] }
    let context = SpotlightQueryContext(text: text, limit: min(max(limit, 1), 2_000))
    return await withTaskCancellationHandler {
      await context.run()
    } onCancel: {
      Task { @MainActor in context.cancel() }
    }
  }
}

@MainActor
private final class SpotlightQueryContext {
  private let query = NSMetadataQuery()
  private let limit: Int
  private var continuation: CheckedContinuation<[QuickOpenResult], Never>?
  private var token: NSObjectProtocol?
  private var timeoutTask: Task<Void, Never>?
  private var finished = false

  init(text: String, limit: Int) {
    self.limit = limit
    query.searchScopes = [NSMetadataQueryUserHomeScope]
    query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
    query.sortDescriptors = [
      NSSortDescriptor(
        key: NSMetadataItemFSNameKey,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare(_:))
      )
    ]
  }

  func run() async -> [QuickOpenResult] {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      token = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering,
        object: query,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.finishWithCurrentResults() }
      }
      guard query.start() else {
        finish([])
        return
      }
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.finishWithCurrentResults() }
      }
    }
  }

  func cancel() { finish([]) }

  private func finishWithCurrentResults() {
    query.disableUpdates()
    let values = query.results.prefix(limit).compactMap { object -> QuickOpenResult? in
      guard let item = object as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
      else { return nil }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
      return QuickOpenResult(
        id: "spotlight:\(url.path)",
        title: name,
        subtitle: url.deletingLastPathComponent().path,
        action: .open(url),
        kind: .spotlight,
        systemImage: "magnifyingglass"
      )
    }
    finish(values)
  }

  private func finish(_ values: [QuickOpenResult]) {
    guard !finished else { return }
    finished = true
    timeoutTask?.cancel()
    timeoutTask = nil
    query.stop()
    if let token { NotificationCenter.default.removeObserver(token) }
    token = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: values)
  }
}
