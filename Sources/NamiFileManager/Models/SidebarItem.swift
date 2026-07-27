import Foundation

struct SidebarFavorite: Identifiable, Codable, Hashable {
  var id: UUID
  var title: String
  var systemImage: String
  var path: String
  var isBuiltIn: Bool

  var url: URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
  }

  static func builtIns() -> [SidebarFavorite] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      SidebarFavorite(
        id: UUID(), title: "ホーム", systemImage: "house", path: home.path, isBuiltIn: true),
      SidebarFavorite(
        id: UUID(), title: "デスクトップ", systemImage: "menubar.dock.rectangle",
        path: home.appendingPathComponent("Desktop", isDirectory: true).path, isBuiltIn: true),
      SidebarFavorite(
        id: UUID(), title: "書類", systemImage: "doc",
        path: home.appendingPathComponent("Documents", isDirectory: true).path, isBuiltIn: true),
      SidebarFavorite(
        id: UUID(), title: "ダウンロード", systemImage: "arrow.down.circle",
        path: home.appendingPathComponent("Downloads", isDirectory: true).path, isBuiltIn: true),
      SidebarFavorite(
        id: UUID(), title: "アプリケーション", systemImage: "square.grid.2x2", path: "/Applications",
        isBuiltIn: true),
    ]
  }
}
