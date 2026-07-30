import Foundation

struct RcloneProviderCatalog: Decodable, Sendable {
  let providers: [RcloneProviderDefinition]
}

struct RcloneProviderDefinition: Decodable, Identifiable, Sendable {
  let name: String
  let description: String
  let prefix: String
  let options: [RcloneProviderOption]

  var id: String { name }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case description = "Description"
    case prefix = "Prefix"
    case options = "Options"
  }
}

struct RcloneProviderOption: Decodable, Identifiable, Sendable {
  struct Example: Decodable, Identifiable, Sendable {
    let value: String
    let help: String
    var id: String { value }

    private enum CodingKeys: String, CodingKey {
      case value = "Value"
      case help = "Help"
    }
  }

  let name: String
  let help: String
  let provider: String?
  let defaultValue: JSONValue
  let defaultText: String
  let examples: [Example]
  let hide: Int
  let required: Bool
  let isPassword: Bool
  let advanced: Bool
  let exclusive: Bool
  let sensitive: Bool
  let type: String

  var id: String { name }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case help = "Help"
    case provider = "Provider"
    case defaultValue = "Default"
    case defaultText = "DefaultStr"
    case examples = "Examples"
    case hide = "Hide"
    case required = "Required"
    case isPassword = "IsPassword"
    case advanced = "Advanced"
    case exclusive = "Exclusive"
    case sensitive = "Sensitive"
    case type = "Type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    help = try container.decodeIfPresent(String.self, forKey: .help) ?? ""
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    defaultValue = try container.decodeIfPresent(JSONValue.self, forKey: .defaultValue) ?? .null
    defaultText = try container.decodeIfPresent(String.self, forKey: .defaultText) ?? ""
    examples = try container.decodeIfPresent([Example].self, forKey: .examples) ?? []
    hide = try container.decodeIfPresent(Int.self, forKey: .hide) ?? 0
    required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    isPassword = try container.decodeIfPresent(Bool.self, forKey: .isPassword) ?? false
    advanced = try container.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
    exclusive = try container.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
    sensitive = try container.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
  }
}

struct RcloneConfigResponse: Decodable, Sendable {
  let state: String
  let result: String
  let error: String
  let option: RcloneProviderOption?

  private enum CodingKeys: String, CodingKey {
    case state = "State"
    case result = "Result"
    case error = "Error"
    case option = "Option"
  }
}

enum RemoteValue<Value: Hashable & Sendable>: Hashable, Sendable {
  case available(Value)
  case notRequested
  case unsupported
  case unknown
  case failed(String)

  var value: Value? {
    guard case .available(let value) = self else { return nil }
    return value
  }
}

struct RcloneRemoteCapabilities: Codable, Hashable, Sendable {
  var caseInsensitive = false
  var canHaveEmptyDirectories = false
  var changeNotify = false
  var copy = false
  var dirMove = false
  var duplicateFiles = false
  var listR = false
  var move = false
  var purge = false
  var readMetadata = false
  var readMimeType = false
  var serverSideAcrossConfigs = false
  var slowHash = false
  var slowModTime = false
  var userMetadata = false
  var writeMetadata = false
  var hashes: Set<String> = []
  var precisionNanoseconds: Int64?

  init(response: [String: JSONValue]) {
    let features = response["Features"]?.objectValue ?? [:]
    func feature(_ name: String) -> Bool { features[name]?.boolValue ?? false }
    caseInsensitive = feature("CaseInsensitive")
    canHaveEmptyDirectories = feature("CanHaveEmptyDirectories")
    changeNotify = feature("ChangeNotify")
    copy = feature("Copy")
    dirMove = feature("DirMove")
    duplicateFiles = feature("DuplicateFiles")
    listR = feature("ListR")
    move = feature("Move")
    purge = feature("Purge")
    readMetadata = feature("ReadMetadata")
    readMimeType = feature("ReadMimeType")
    serverSideAcrossConfigs = feature("ServerSideAcrossConfigs")
    slowHash = feature("SlowHash")
    slowModTime = feature("SlowModTime")
    userMetadata = feature("UserMetadata")
    writeMetadata = feature("WriteMetadata")
    hashes = Set(response["Hashes"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    precisionNanoseconds = response["Precision"]?.intValue
  }

  init() {}
}

struct RcloneListEntry: Codable, Hashable, Sendable {
  let path: String
  let name: String
  let size: Int64?
  let mimeType: String?
  let modTime: Date?
  let isDir: Bool
  let id: String?
  let tier: String?
  let hashes: [String: String]
  let metadata: [String: String]

  private enum CodingKeys: String, CodingKey {
    case path = "Path"
    case name = "Name"
    case size = "Size"
    case mimeType = "MimeType"
    case modTime = "ModTime"
    case isDir = "IsDir"
    case id = "ID"
    case tier = "Tier"
    case hashes = "Hashes"
    case metadata = "Metadata"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
    size = try container.decodeIfPresent(Int64.self, forKey: .size)
    mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    isDir = try container.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
    id = try container.decodeIfPresent(String.self, forKey: .id)
    tier = try container.decodeIfPresent(String.self, forKey: .tier)
    hashes = try container.decodeIfPresent([String: String].self, forKey: .hashes) ?? [:]
    metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]

    if let text = try container.decodeIfPresent(String.self, forKey: .modTime),
      text != "2000-01-01T00:00:00Z"
    {
      modTime = RcloneDateParser.date(from: text)
    } else {
      modTime = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(size, forKey: .size)
    try container.encodeIfPresent(mimeType, forKey: .mimeType)
    try container.encodeIfPresent(modTime.map(RcloneDateParser.string), forKey: .modTime)
    try container.encode(isDir, forKey: .isDir)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(tier, forKey: .tier)
    try container.encode(hashes, forKey: .hashes)
    try container.encode(metadata, forKey: .metadata)
  }
}

private enum RcloneDateParser {
  static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static let normal = ISO8601DateFormatter()

  static func date(from value: String) -> Date? {
    fractional.date(from: value) ?? normal.date(from: value)
  }

  static func string(from value: Date) -> String { fractional.string(from: value) }
}

struct RcloneJobReference: Codable, Hashable, Sendable {
  let jobID: Int64
  let executeID: String

  private enum CodingKeys: String, CodingKey {
    case jobID = "jobid"
    case executeID = "executeId"
  }

  init(jobID: Int64, executeID: String) {
    self.jobID = jobID
    self.executeID = executeID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let jobID = try container.decode(Int64.self, forKey: .jobID)
    let executeID = try container.decode(String.self, forKey: .executeID)
    guard jobID >= 0, Self.validExecuteID(executeID) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid rclone job reference")
      )
    }
    self.jobID = jobID
    self.executeID = executeID
  }

  private static func validExecuteID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }
}

struct RcloneJobStatus: Codable, Hashable, Sendable {
  let finished: Bool
  let success: Bool?
  let error: String
  let duration: Double?
  let executeID: String?

  private enum CodingKeys: String, CodingKey {
    case finished
    case success
    case error
    case duration
    case executeID = "executeId"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    finished = try container.decode(Bool.self, forKey: .finished)
    success = try container.decodeIfPresent(Bool.self, forKey: .success)
    error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    duration = try container.decodeIfPresent(Double.self, forKey: .duration)
    executeID = try container.decodeIfPresent(String.self, forKey: .executeID)

    guard error.utf8.count <= 1 * 1_024 * 1_024,
      !error.unicodeScalars.contains(where: { $0.value == 0 }),
      duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
      executeID.map({
        !$0.isEmpty && $0.utf8.count <= 4_096
          && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      }) ?? true,
      !finished || success != nil
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid rclone job status")
      )
    }
  }
}

struct RcloneTransferStats: Codable, Hashable, Sendable {
  struct ActiveTransfer: Codable, Hashable, Sendable {
    let name: String
    let size: Int64?
    let bytes: Int64
    let percentage: Double?
    let speed: Double?
    let speedAvg: Double?
    let eta: Double?
  }

  let bytes: Int64
  let totalBytes: Int64
  let speed: Double
  let eta: Double?
  let checks: Int64
  let transfers: Int64
  let errors: Int64
  let lastError: String?
  let transferring: [ActiveTransfer]

  init(
    bytes: Int64 = 0,
    totalBytes: Int64 = 0,
    speed: Double = 0,
    eta: Double? = nil,
    checks: Int64 = 0,
    transfers: Int64 = 0,
    errors: Int64 = 0,
    lastError: String? = nil,
    transferring: [ActiveTransfer] = []
  ) {
    self.bytes = bytes
    self.totalBytes = totalBytes
    self.speed = speed
    self.eta = eta
    self.checks = checks
    self.transfers = transfers
    self.errors = errors
    self.lastError = lastError
    self.transferring = transferring
  }
}


struct RcloneRuntimeDescriptor: Codable, Hashable, Sendable {
  let baseURL: URL
  let username: String
  let password: String
  let generation: UUID
  let processIdentifier: Int32
  let expiresAt: Date

  var isUsable: Bool { expiresAt > Date() }
}
