import Foundation
import SwiftUI

@MainActor
final class SidebarModel: ObservableObject {
  @Published private(set) var favorites: [SidebarFavorite] = []
  @Published var showsFavorites = true { didSet { persistUnlessLoading() } }
  @Published var showsVolumes = true { didSet { persistUnlessLoading() } }
  @Published var showsServers = true { didSet { persistUnlessLoading() } }
  @Published var showsICloud = true { didSet { persistUnlessLoading() } }
  @Published private(set) var persistenceErrorMessage: String?

  private struct Persistence: Codable {
    var favorites: [SidebarFavorite]
    var showsFavorites: Bool
    var showsVolumes: Bool
    var showsServers: Bool
    var showsICloud: Bool?
  }

  private let persistenceURL: URL
  private var isLoading = false

  init() {
    persistenceURL = AppStoragePaths.file(named: "sidebar.json")
    load()
  }

  func contains(url: URL) -> Bool {
    favorites.contains { NafiURL.sameLocation($0.url, url) }
  }

  func add(url: URL, title: String? = nil) {
    guard favorites.count < 1_000,
      !favorites.contains(where: { NafiURL.sameLocation($0.url, url) })
    else { return }
    let fallbackTitle =
      url.lastPathComponent.isEmpty
      ? (NafiURL.remotePath(in: url) ?? url.path)
      : url.lastPathComponent
    let cleanTitle = sanitizedTitle(title ?? fallbackTitle)
    let path = NafiURL.isRemote(url) ? url.absoluteString : url.path
    guard path.utf8.count <= 8_192 else {
      reportPersistenceError("サイドバーへ追加するパスが長すぎます。")
      return
    }
    favorites.append(
      SidebarFavorite(
        id: UUID(),
        title: cleanTitle,
        systemImage: NafiURL.isRemote(url) ? "network" : "folder",
        path: path,
        isBuiltIn: false
      )
    )
    persistUnlessLoading()
  }

  func remove(_ favorite: SidebarFavorite) {
    favorites.removeAll { $0.id == favorite.id }
    persistUnlessLoading()
  }

  func move(from offsets: IndexSet, to destination: Int) {
    favorites.move(fromOffsets: offsets, toOffset: min(max(destination, 0), favorites.count))
    persistUnlessLoading()
  }

  func move(itemID: UUID, before destinationID: UUID) {
    guard itemID != destinationID,
      let sourceIndex = favorites.firstIndex(where: { $0.id == itemID }),
      let destinationIndex = favorites.firstIndex(where: { $0.id == destinationID })
    else { return }
    let item = favorites.remove(at: sourceIndex)
    let adjustedDestination =
      sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
    favorites.insert(item, at: min(max(0, adjustedDestination), favorites.count))
    persistUnlessLoading()
  }

  func moveToEnd(itemID: UUID) {
    guard let sourceIndex = favorites.firstIndex(where: { $0.id == itemID }) else { return }
    let item = favorites.remove(at: sourceIndex)
    favorites.append(item)
    persistUnlessLoading()
  }

  func rename(_ favorite: SidebarFavorite, to title: String) {
    guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
    let clean = sanitizedTitle(title)
    guard !clean.isEmpty else { return }
    favorites[index].title = clean
    persistUnlessLoading()
  }

  func reset() {
    isLoading = true
    favorites = SidebarFavorite.builtIns()
    showsFavorites = true
    showsVolumes = true
    showsServers = true
    showsICloud = true
    isLoading = false
    persistUnlessLoading()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
      favorites = SidebarFavorite.builtIns()
      return
    }

    do {
      let data = try AppStoragePaths.readRegularFile(
        at: persistenceURL,
        maximumBytes: 4 * 1_024 * 1_024
      )
      let decoded = try JSONDecoder().decode(Persistence.self, from: data)
      guard decoded.favorites.count <= 1_000 else { throw CocoaError(.fileReadCorruptFile) }

      var seen = Set<UUID>()
      var validated: [SidebarFavorite] = []
      validated.reserveCapacity(decoded.favorites.count)
      for favorite in decoded.favorites {
        guard seen.insert(favorite.id).inserted,
          favorite.title.utf8.count <= 512,
          favorite.path.utf8.count <= 8_192,
          !favorite.title.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          }),
          !favorite.path.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          })
        else { throw CocoaError(.fileReadCorruptFile) }
        validated.append(favorite)
      }

      isLoading = true
      favorites = validated.isEmpty ? SidebarFavorite.builtIns() : validated
      showsFavorites = decoded.showsFavorites
      showsVolumes = decoded.showsVolumes
      showsServers = decoded.showsServers
      showsICloud = decoded.showsICloud ?? true
      isLoading = false
      persistenceErrorMessage = nil
    } catch {
      isLoading = false
      AppStoragePaths.quarantineCorruptFile(at: persistenceURL)
      favorites = SidebarFavorite.builtIns()
      persistenceErrorMessage = "サイドバー設定が壊れていたため初期値へ戻しました。"
    }
  }

  private func persistUnlessLoading() {
    guard !isLoading else { return }
    let value = Persistence(
      favorites: favorites,
      showsFavorites: showsFavorites,
      showsVolumes: showsVolumes,
      showsServers: showsServers,
      showsICloud: showsICloud
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      guard data.count <= 4 * 1_024 * 1_024 else {
        throw CocoaError(.fileWriteOutOfSpace)
      }
      try data.write(
        to: persistenceURL,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      persistenceErrorMessage = nil
    } catch {
      reportPersistenceError("サイドバー設定を保存できませんでした: \(error.localizedDescription)")
    }
  }

  private func sanitizedTitle(_ value: String) -> String {
    String(
      value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .unicodeScalars
        .filter { !CharacterSet.controlCharacters.contains($0) }
    ).prefix(256).description
  }

  private func reportPersistenceError(_ message: String) {
    persistenceErrorMessage = message
    NotificationCenter.default.post(
      name: .nafiMaintenanceWarning,
      object: nil,
      userInfo: ["message": message]
    )
  }
}
