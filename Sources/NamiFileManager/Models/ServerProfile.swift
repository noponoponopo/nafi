import Foundation

struct ServerProfile: Identifiable, Codable, Hashable {
  enum Kind: String, Codable, CaseIterable, Identifiable {
    case smb
    case webdav
    case nfs
    case afp
    case sftp
    case ftp

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var defaultPort: Int {
      switch self {
      case .smb: 445
      case .webdav: 443
      case .nfs: 2049
      case .afp: 548
      case .sftp: 22
      case .ftp: 21
      }
    }
    var systemImage: String {
      switch self {
      case .smb: "externaldrive.connected.to.line.below"
      case .webdav: "cloud"
      case .nfs: "network"
      case .afp: "macpro.gen3.server"
      case .sftp: "lock.shield"
      case .ftp: "arrow.up.arrow.down.square"
      }
    }
  }

  var id: UUID = UUID()
  var name: String
  var kind: Kind
  var host: String
  var port: Int
  var path: String
  var username: String
  var useTLS: Bool
  var autoConnect: Bool
  var localMountPath: String

  static var blank: ServerProfile {
    ServerProfile(
      name: "新しいサーバー",
      kind: .smb,
      host: "",
      port: Kind.smb.defaultPort,
      path: "",
      username: "",
      useTLS: true,
      autoConnect: true,
      localMountPath: ""
    )
  }

  var endpointDescription: String {
    var value = "\(kind.rawValue)://\(host)"
    if port != kind.defaultPort { value += ":\(port)" }
    if !path.isEmpty { value += "/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
    return value
  }

  var connectionURL: URL? {
    var components = URLComponents()
    switch kind {
    case .webdav:
      components.scheme = useTLS ? "https" : "http"
    default:
      components.scheme = kind.rawValue
    }
    components.host = host
    if port != kind.defaultPort { components.port = port }
    if !username.isEmpty { components.user = username }
    let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = cleanPath.isEmpty ? "" : "/\(cleanPath)"
    return components.url
  }
}

enum ServerConnectionState: Equatable {
  case idle
  case connecting
  case connected(URL?)
  case helperRequired(String)
  case failed(String)

  var label: String {
    switch self {
    case .idle: "未接続"
    case .connecting: "接続中"
    case .connected: "接続済み"
    case .helperRequired: "補助ツールが必要"
    case .failed: "接続失敗"
    }
  }
}
