import Foundation

struct RemoteFileItem: Identifiable, Hashable, Sendable {
  let name: String
  let path: String
  let isDirectory: Bool
  let size: UInt64?
  let modifiedAt: Date?

  var id: String { path }

  var displaySize: String {
    guard !isDirectory, let size else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
  }
}

enum RemoteServerError: LocalizedError {
  case invalidResponse(String)
  case unsupported(String)
  case notConnected
  case invalidName

  var errorDescription: String? {
    switch self {
    case .invalidResponse(let message): message
    case .unsupported(let message): message
    case .notConnected: "サーバーへ接続されていません。"
    case .invalidName: "使用できない名前です。"
    }
  }
}
