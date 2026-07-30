import Foundation

struct RemoteFileItem: Identifiable, Hashable, Sendable {
  let name: String
  let path: String
  let isDirectory: Bool
  let size: UInt64?
  let modifiedAt: Date?
  let stableID: String?
  let mimeType: String?
  let hashes: [String: String]
  let metadata: [String: String]
  let ambiguityToken: String?

  init(
    name: String,
    path: String,
    isDirectory: Bool,
    size: UInt64?,
    modifiedAt: Date?,
    stableID: String? = nil,
    mimeType: String? = nil,
    hashes: [String: String] = [:],
    metadata: [String: String] = [:],
    ambiguityToken: String? = nil
  ) {
    self.name = name
    self.path = path
    self.isDirectory = isDirectory
    self.size = size
    self.modifiedAt = modifiedAt
    self.stableID = stableID
    self.mimeType = mimeType
    self.hashes = hashes
    self.metadata = metadata
    self.ambiguityToken = ambiguityToken
  }

  var id: String { stableID.map { "id:\($0)" } ?? path }

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
