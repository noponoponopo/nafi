import Foundation
import SwiftUI

@MainActor
final class SidebarModel: ObservableObject {
  @Published private(set) var favorites: [SidebarFavorite] = []
  @Published var showsFavorites = true { didSet { persist() } }
  @Published var showsVolumes = true { didSet { persist() } }
  @Published var showsServers = true { didSet { persist() } }

  private struct Persistence: Codable {
    var favorites: [SidebarFavorite]
    var showsFavorites: Bool
    var showsVolumes: Bool
    var showsServers: Bool
  }

  private let persistenceURL: URL

  init() {
    persistenceURL = AppStoragePaths.file(named: "sidebar.json")
    load()
  }

  func contains(url: URL) -> Bool {
    favorites.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
  }

  func add(url: URL, title: String? = nil) {
    guard !favorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
    else { return }
    favorites.append(
      SidebarFavorite(
        id: UUID(),
        title: title ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent),
        systemImage: "folder",
        path: url.path,
        isBuiltIn: false
      ))
    persist()
  }

  func remove(_ favorite: SidebarFavorite) {
    favorites.removeAll { $0.id == favorite.id }
    persist()
  }

  func move(from offsets: IndexSet, to destination: Int) {
    favorites.move(fromOffsets: offsets, toOffset: destination)
    persist()
  }

  func move(itemID: UUID, before destinationID: UUID) {
    guard itemID != destinationID,
      let sourceIndex = favorites.firstIndex(where: { $0.id == itemID }),
      let destinationIndex = favorites.firstIndex(where: { $0.id == destinationID })
    else { return }
    let item = favorites.remove(at: sourceIndex)
    let adjustedDestination =
      sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
    favorites.insert(item, at: max(0, adjustedDestination))
    persist()
  }

  func moveToEnd(itemID: UUID) {
    guard let sourceIndex = favorites.firstIndex(where: { $0.id == itemID }) else { return }
    let item = favorites.remove(at: sourceIndex)
    favorites.append(item)
    persist()
  }

  func rename(_ favorite: SidebarFavorite, to title: String) {
    guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    favorites[index].title = trimmed
    persist()
  }

  func reset() {
    favorites = SidebarFavorite.builtIns()
    showsFavorites = true
    showsVolumes = true
    showsServers = true
    persist()
  }

  private func load() {
    guard let data = try? Data(contentsOf: persistenceURL),
      let decoded = try? JSONDecoder().decode(Persistence.self, from: data)
    else {
      favorites = SidebarFavorite.builtIns()
      return
    }
    favorites = decoded.favorites
    showsFavorites = decoded.showsFavorites
    showsVolumes = decoded.showsVolumes
    showsServers = decoded.showsServers
  }

  private func persist() {
    let value = Persistence(
      favorites: favorites,
      showsFavorites: showsFavorites,
      showsVolumes: showsVolumes,
      showsServers: showsServers
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value) {
      try? data.write(to: persistenceURL, options: .atomic)
    }
  }
}
