import Foundation

enum FileSearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
  case currentFolder
  case descendants
  case storage

  var id: String { rawValue }

  var label: String {
    switch self {
    case .currentFolder: "このフォルダ"
    case .descendants: "この階層以下"
    case .storage: "ボリューム／サーバー全体"
    }
  }

  var shortLabel: String {
    switch self {
    case .currentFolder: "現在"
    case .descendants: "配下"
    case .storage: "全体"
    }
  }

  var systemImage: String {
    switch self {
    case .currentFolder: "folder"
    case .descendants: "folder.badge.plus"
    case .storage: "externaldrive"
    }
  }

  var searchesRecursively: Bool { self != .currentFolder }
}
