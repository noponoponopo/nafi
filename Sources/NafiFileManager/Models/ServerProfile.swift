import Foundation

struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
    case smb
    case webdav
    case nfs
    case afp
    case sftp
    case ftp
    case s3

    var id: String { rawValue }
    var label: String {
      switch self {
      case .s3: "S3 / R2"
      default: rawValue.uppercased()
      }
    }
    var defaultPort: Int {
      switch self {
      case .smb: 445
      case .webdav: 443
      case .nfs: 2049
      case .afp: 548
      case .sftp: 22
      case .ftp: 21
      case .s3: 443
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
      case .s3: "shippingbox"
      }
    }
  }

  enum SFTPAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }
    var label: String {
      switch self {
      case .password: "パスワード"
      case .privateKey: "秘密鍵"
      }
    }
  }

  enum FTPEncryption: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case explicitTLS
    case implicitTLS

    var id: String { rawValue }
    var label: String {
      switch self {
      case .none: "FTP（暗号化なし）"
      case .explicitTLS: "FTPS（明示 TLS / AUTH TLS）"
      case .implicitTLS: "FTPS（暗黙 TLS）"
      }
    }

    var defaultPort: Int {
      switch self {
      case .none, .explicitTLS: 21
      case .implicitTLS: 990
      }
    }

    var usesTLS: Bool { self != .none }
  }

  enum S3AddressingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case pathStyle
    case virtualHostedStyle

    var id: String { rawValue }
    var label: String {
      switch self {
      case .automatic: "自動"
      case .pathStyle: "パス形式（R2 / MinIO向け）"
      case .virtualHostedStyle: "仮想ホスト形式（AWS向け）"
      }
    }
  }

  var id: UUID
  var name: String
  var kind: Kind
  var host: String
  var port: Int
  var path: String
  var username: String
  var useTLS: Bool
  var autoConnect: Bool
  var localMountPath: String
  var sftpAuthentication: SFTPAuthentication
  var privateKeyPath: String
  var ftpEncryption: FTPEncryption
  var verifyTLSCertificate: Bool
  var s3Bucket: String
  var s3Region: String
  var s3AddressingStyle: S3AddressingStyle
  var s3Anonymous: Bool

  init(
    id: UUID = UUID(),
    name: String,
    kind: Kind,
    host: String,
    port: Int,
    path: String,
    username: String,
    useTLS: Bool,
    autoConnect: Bool,
    localMountPath: String,
    sftpAuthentication: SFTPAuthentication = .password,
    privateKeyPath: String = "",
    ftpEncryption: FTPEncryption = .none,
    verifyTLSCertificate: Bool = true,
    s3Bucket: String = "",
    s3Region: String = "auto",
    s3AddressingStyle: S3AddressingStyle = .automatic,
    s3Anonymous: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.host = host
    self.port = port
    self.path = path
    self.username = username
    self.useTLS = useTLS
    self.autoConnect = autoConnect
    self.localMountPath = localMountPath
    self.sftpAuthentication = sftpAuthentication
    self.privateKeyPath = privateKeyPath
    self.ftpEncryption = ftpEncryption
    self.verifyTLSCertificate = verifyTLSCertificate
    self.s3Bucket = s3Bucket
    self.s3Region = s3Region
    self.s3AddressingStyle = s3AddressingStyle
    self.s3Anonymous = s3Anonymous
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case kind
    case host
    case port
    case path
    case username
    case useTLS
    case autoConnect
    case localMountPath
    case sftpAuthentication
    case privateKeyPath
    case ftpEncryption
    case verifyTLSCertificate
    case s3Bucket
    case s3Region
    case s3AddressingStyle
    case s3Anonymous
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    kind = try container.decode(Kind.self, forKey: .kind)
    host = try container.decode(String.self, forKey: .host)
    port = try container.decode(Int.self, forKey: .port)
    path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
    autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
    localMountPath = try container.decodeIfPresent(String.self, forKey: .localMountPath) ?? ""
    sftpAuthentication =
      try container.decodeIfPresent(SFTPAuthentication.self, forKey: .sftpAuthentication)
      ?? .password
    privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    ftpEncryption =
      try container.decodeIfPresent(FTPEncryption.self, forKey: .ftpEncryption) ?? .none
    verifyTLSCertificate =
      try container.decodeIfPresent(Bool.self, forKey: .verifyTLSCertificate) ?? true
    s3Bucket = try container.decodeIfPresent(String.self, forKey: .s3Bucket) ?? ""
    s3Region = try container.decodeIfPresent(String.self, forKey: .s3Region) ?? "auto"
    s3AddressingStyle =
      try container.decodeIfPresent(S3AddressingStyle.self, forKey: .s3AddressingStyle)
      ?? .automatic
    s3Anonymous = try container.decodeIfPresent(Bool.self, forKey: .s3Anonymous) ?? false
  }

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

  var effectiveDefaultPort: Int {
    switch kind {
    case .ftp: ftpEncryption.defaultPort
    case .s3: useTLS ? 443 : 80
    default: kind.defaultPort
    }
  }

  var endpointDescription: String {
    if kind == .s3 {
      let scheme = useTLS ? "https" : "http"
      let endpoint = host.contains("://") ? host : "\(scheme)://\(host)"
      let bucket = s3Bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let prefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return [endpoint, bucket, prefix].filter { !$0.isEmpty }.joined(separator: "/")
    }

    let scheme: String = {
      switch kind {
      case .ftp where ftpEncryption.usesTLS: "ftps"
      case .webdav: useTLS ? "https" : "http"
      default: kind.rawValue
      }
    }()
    var value = "\(scheme)://\(host)"
    if port != effectiveDefaultPort { value += ":\(port)" }
    if !path.isEmpty { value += "/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
    return value
  }

  var connectionURL: URL? {
    var components = URLComponents()
    switch kind {
    case .webdav:
      components.scheme = useTLS ? "https" : "http"
    case .ftp:
      components.scheme = ftpEncryption.usesTLS ? "ftps" : "ftp"
    case .s3:
      if host.contains("://") { return URL(string: host) }
      components.scheme = useTLS ? "https" : "http"
    default:
      components.scheme = kind.rawValue
    }
    components.host = host
    if port != effectiveDefaultPort { components.port = port }
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
