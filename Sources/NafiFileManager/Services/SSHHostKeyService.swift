import CryptoKit
import Foundation

private actor SSHHostKeyUpdateCoordinator {
  private var isRunning = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    while isRunning {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    isRunning = true
    defer {
      isRunning = false
      if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
    return try await operation()
  }
}

struct SSHHostKeyCandidate: Identifiable, Hashable, Sendable {
  var id: String { "\(algorithm):\(fingerprint)" }
  let algorithm: String
  let fingerprint: String
  fileprivate let encodedKey: String
}

struct SSHHostKeyScan: Hashable, Sendable {
  let host: String
  let port: Int
  let scannedAt: Date
  let keys: [SSHHostKeyCandidate]
}

struct SSHHostKeyApprovalRequest: Identifiable, Sendable {
  let id: UUID
  let profileID: UUID
  let profileName: String
  let scan: SSHHostKeyScan
  let existingIdentities: [String]

  init(
    profileID: UUID,
    profileName: String,
    scan: SSHHostKeyScan,
    existingIdentities: Set<String>
  ) {
    id = UUID()
    self.profileID = profileID
    self.profileName = profileName
    self.scan = scan
    self.existingIdentities = existingIdentities.sorted()
  }

  var isKeyChange: Bool {
    guard !existingIdentities.isEmpty else { return false }
    let scanned = Set(scan.keys.map { "\($0.algorithm) \($0.fingerprint)" })
    return Self.isKeyChange(existingIdentities: Set(existingIdentities), scannedIdentities: scanned)
  }

  static func isKeyChange(
    existingIdentities: Set<String>,
    scannedIdentities: Set<String>
  ) -> Bool {
    !existingIdentities.isEmpty && scannedIdentities.isDisjoint(with: existingIdentities)
  }
}

actor SSHHostKeyService {
  static let shared = SSHHostKeyService()

  enum ServiceError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case commandUnavailable(String)
    case scanFailed(String)
    case noKeys
    case malformedKey
    case hostKeyNotTrusted
    case staleScan
    case persistence(String)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint(let message): message
      case .commandUnavailable(let path):
        "SSHホストキー確認コマンドが見つかりません: \(path)"
      case .scanFailed(let message): "SSHホストキーを取得できませんでした。\(message)"
      case .noKeys: "サーバーから利用可能なSSHホストキーが返されませんでした。"
      case .malformedKey: "サーバーから不正なSSHホストキーが返されました。"
      case .hostKeyNotTrusted:
        "SSHホストキーが登録されていません。設定画面で指紋を確認して信頼してください。"
      case .staleScan: "確認から時間が経過したため、ホストキーをもう一度取得してください。"
      case .persistence(let message): "SSHホストキーを保存できませんでした。\(message)"
      }
    }
  }

  private let knownHostsURL = AppStoragePaths.sshKnownHostsURL
  private let keyscanURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
  private let keygenURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
  private let updateCoordinator = SSHHostKeyUpdateCoordinator()

  func prepareKnownHosts(host rawHost: String, port: Int) async throws -> [String] {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    let endpoint = Self.knownHostsEndpoint(host: host, port: port)
    let algorithms = try await updateCoordinator.run { [self] in
      try await trustedAlgorithms(endpoint: endpoint, fileURL: knownHostsURL)
    }
    guard !algorithms.isEmpty else { throw ServiceError.hostKeyNotTrusted }
    return algorithms
  }

  func scan(host rawHost: String, port: Int) async throws -> SSHHostKeyScan {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    try requireExecutable(keyscanURL)

    let result: BoundedProcessRunner.Result
    do {
      result = try await BoundedProcessRunner.run(
        executableURL: keyscanURL,
        arguments: [
          "-T", "10",
          "-p", String(port),
          "-t", "rsa,ecdsa,ed25519",
          host,
        ],
        timeout: 20,
        maximumStandardOutputBytes: 256 * 1024,
        maximumStandardErrorBytes: 64 * 1024
      )
    } catch {
      throw ServiceError.scanFailed(error.localizedDescription)
    }

    let stderr = Self.string(from: result.stderr, maximumCharacters: 2_000)
    guard result.terminationStatus == 0 else {
      throw ServiceError.scanFailed(stderr.isEmpty ? "終了コード \(result.terminationStatus)" : stderr)
    }

    let output = String(data: result.stdout, encoding: .utf8) ?? ""
    var candidates: [SSHHostKeyCandidate] = []
    var seen = Set<String>()
    for line in output.split(whereSeparator: \.isNewline) {
      let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !text.hasPrefix("#") else { continue }
      let fields = text.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count == 3 else { throw ServiceError.malformedKey }
      let algorithm = fields[1]
      let encodedKey = fields[2]
      guard Self.allowedAlgorithms.contains(algorithm),
        let keyData = Data(base64Encoded: encodedKey),
        keyData.count <= 32 * 1024,
        Self.embeddedAlgorithm(in: keyData) == algorithm
      else {
        throw ServiceError.malformedKey
      }
      let digest = SHA256.hash(data: keyData)
      let fingerprint =
        "SHA256:"
        + Data(digest).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
      let identity = "\(algorithm) \(fingerprint)"
      guard seen.insert(identity).inserted else { continue }
      candidates.append(
        SSHHostKeyCandidate(
          algorithm: algorithm,
          fingerprint: fingerprint,
          encodedKey: encodedKey
        )
      )
    }

    guard !candidates.isEmpty else {
      if !stderr.isEmpty { throw ServiceError.scanFailed(stderr) }
      throw ServiceError.noKeys
    }
    guard candidates.count <= 16 else { throw ServiceError.malformedKey }
    candidates.sort { lhs, rhs in
      Self.algorithmPreference(lhs.algorithm) < Self.algorithmPreference(rhs.algorithm)
    }
    return SSHHostKeyScan(host: host, port: port, scannedAt: Date(), keys: candidates)
  }

  func trust(_ scan: SSHHostKeyScan) async throws {
    let host = try Self.validatedHost(scan.host)
    try Self.validatePort(scan.port)
    guard Date().timeIntervalSince(scan.scannedAt) <= 10 * 60 else {
      throw ServiceError.staleScan
    }
    guard !scan.keys.isEmpty, scan.keys.count <= 16 else { throw ServiceError.malformedKey }
    for key in scan.keys {
      guard Self.allowedAlgorithms.contains(key.algorithm),
        let keyData = Data(base64Encoded: key.encodedKey),
        keyData.count <= 32 * 1024,
        Self.embeddedAlgorithm(in: keyData) == key.algorithm
      else { throw ServiceError.malformedKey }
      let fingerprint =
        "SHA256:"
        + Data(SHA256.hash(data: keyData)).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
      guard fingerprint == key.fingerprint else { throw ServiceError.malformedKey }
    }

    try await updateCoordinator.run { [self] in
      try await writeTrustedKeys(host: host, scan: scan)
    }
  }

  private func writeTrustedKeys(host: String, scan: SSHHostKeyScan) async throws {
    let endpoint = Self.knownHostsEndpoint(host: host, port: scan.port)
    try await updateKnownHostsFile { temporaryURL in
      try await removeEndpoint(endpoint, from: temporaryURL)
      var updated = try AppStoragePaths.readRegularFile(
        at: temporaryURL,
        maximumBytes: 4 * 1_024 * 1_024
      )
      if !updated.isEmpty, updated.last != 0x0A { updated.append(0x0A) }
      for key in scan.keys {
        updated.append(Data("\(endpoint) \(key.algorithm) \(key.encodedKey)\n".utf8))
      }
      guard updated.count <= 4 * 1024 * 1024 else {
        throw ServiceError.persistence("known_hostsが安全上限を超えています。")
      }
      return updated
    }
  }

  func isTrusted(host rawHost: String, port: Int) async throws -> Bool {
    let identities = try await trustedHostKeyIdentities(host: rawHost, port: port)
    return !identities.isEmpty
  }

  func trustedHostKeyIdentities(host rawHost: String, port: Int) async throws -> Set<String> {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    let endpoint = Self.knownHostsEndpoint(host: host, port: port)
    return try await updateCoordinator.run { [self] in
      try await trustedIdentities(endpoint: endpoint, fileURL: knownHostsURL)
    }
  }

  func removeTrustedKeys(host rawHost: String, port: Int) async throws {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    guard FileManager.default.fileExists(atPath: knownHostsURL.path) else { return }
    try await updateCoordinator.run { [self] in
      try await updateKnownHostsFile { temporaryURL in
        try await removeEndpoint(
          Self.knownHostsEndpoint(host: host, port: port),
          from: temporaryURL
        )
        return try AppStoragePaths.readRegularFile(
          at: temporaryURL,
          maximumBytes: 4 * 1_024 * 1_024
        )
      }
    }
  }

  private func readKnownHostsData() throws -> Data {
    try AppStoragePaths.readRegularFile(
      at: knownHostsURL,
      maximumBytes: 4 * 1_024 * 1_024
    )
  }

  private func updateKnownHostsFile(
    _ update: (URL) async throws -> Data
  ) async throws {
    try ensureKnownHostsFile()
    let current = try readKnownHostsData()
    let temporaryURL = AppStoragePaths.directory.appendingPathComponent(
      ".known-hosts-update-\(UUID().uuidString)",
      isDirectory: false
    )
    let temporaryBackupURL = URL(fileURLWithPath: temporaryURL.path + ".old")
    defer {
      try? FileManager.default.removeItem(at: temporaryURL)
      try? FileManager.default.removeItem(at: temporaryBackupURL)
    }

    do {
      try current.write(to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
      )
      let updated = try await update(temporaryURL)
      try updated.write(to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
      )
      _ = try FileManager.default.replaceItemAt(
        knownHostsURL,
        withItemAt: temporaryURL,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } catch let error as ServiceError {
      throw error
    } catch {
      throw ServiceError.persistence(error.localizedDescription)
    }
  }

  private func ensureKnownHostsFile() throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: knownHostsURL.path) {
      let values = try knownHostsURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ServiceError.persistence("known_hostsは通常のファイルではありません。")
      }
      try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
      return
    }
    let parent = knownHostsURL.deletingLastPathComponent()
    try? manager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard manager.createFile(
      atPath: knownHostsURL.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw ServiceError.persistence("known_hostsを作成できませんでした。")
    }
  }

  private func removeEndpoint(_ endpoint: String, from fileURL: URL) async throws {
    try requireExecutable(keygenURL)
    let result: BoundedProcessRunner.Result
    do {
      result = try await BoundedProcessRunner.run(
        executableURL: keygenURL,
        arguments: ["-R", endpoint, "-f", fileURL.path],
        timeout: 10,
        maximumStandardOutputBytes: 256 * 1024,
        maximumStandardErrorBytes: 64 * 1024
      )
    } catch {
      throw ServiceError.persistence(error.localizedDescription)
    }
    guard result.terminationStatus == 0 else {
      let message = Self.string(from: result.stderr, maximumCharacters: 2_000)
      throw ServiceError.persistence(message.isEmpty ? "known_hostsを更新できませんでした。" : message)
    }
  }

  private func trustedAlgorithms(endpoint: String, fileURL: URL) async throws -> [String] {
    let identities = try await trustedIdentities(endpoint: endpoint, fileURL: fileURL)
    return identities.compactMap { identity in
      identity.split(separator: " ", maxSplits: 1).first.map(String.init)
    }.sorted()
  }

  private func trustedIdentities(endpoint: String, fileURL: URL) async throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    _ = try AppStoragePaths.readRegularFile(at: fileURL, maximumBytes: 4 * 1_024 * 1_024)
    try requireExecutable(keygenURL)
    let result = try await BoundedProcessRunner.run(
      executableURL: keygenURL,
      arguments: ["-F", endpoint, "-f", fileURL.path],
      timeout: 10,
      maximumStandardOutputBytes: 256 * 1_024,
      maximumStandardErrorBytes: 64 * 1_024
    )
    guard result.terminationStatus == 0 else { return [] }
    return Self.knownHostIdentities(in: result.stdout)
  }

  private func requireExecutable(_ url: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw ServiceError.commandUnavailable(url.path)
    }
  }

  static func validatedHost(_ rawValue: String) throws -> String {
    let host = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "/\\@"))
    guard !host.isEmpty,
      host.utf8.count <= 255,
      !host.hasPrefix("-"),
      host.rangeOfCharacter(from: invalid) == nil,
      !host.contains("://")
    else {
      throw ServiceError.invalidEndpoint("SFTPホスト名が不正です。URLではなくホスト名だけを入力してください。")
    }
    return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  }

  static func validatedUsername(_ rawValue: String) throws -> String {
    let username = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "@"))
    guard !username.isEmpty,
      username.utf8.count <= 255,
      username.rangeOfCharacter(from: invalid) == nil
    else {
      throw ServiceError.invalidEndpoint("SFTPユーザー名が不正です。")
    }
    return username
  }

  static func validatePort(_ port: Int) throws {
    guard (1...65535).contains(port) else {
      throw ServiceError.invalidEndpoint("SFTPポート番号が不正です。")
    }
  }

  private static let allowedAlgorithms: Set<String> = [
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
  ]

  private static func embeddedAlgorithm(in keyData: Data) -> String? {
    guard keyData.count >= 4 else { return nil }
    let length = keyData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= 128, keyData.count >= 4 + Int(length) else { return nil }
    return String(data: keyData.subdata(in: 4..<(4 + Int(length))), encoding: .utf8)
  }

  private static func knownHostsEndpoint(host: String, port: Int) -> String {
    let unwrapped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return port == 22 ? unwrapped : "[\(unwrapped)]:\(port)"
  }

  static func knownHostIdentities(in output: Data) -> Set<String> {
    guard let text = String(data: output, encoding: .utf8) else { return [] }
    return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count == 3, allowedAlgorithms.contains(fields[1]),
        let keyData = Data(base64Encoded: fields[2]),
        keyData.count <= 32 * 1_024,
        embeddedAlgorithm(in: keyData) == fields[1]
      else { return nil }
      let fingerprint = "SHA256:" + Data(SHA256.hash(data: keyData)).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
      return "\(fields[1]) \(fingerprint)"
    })
  }

  private static func algorithmPreference(_ value: String) -> Int {
    switch value {
    case "ssh-ed25519": 0
    case "ecdsa-sha2-nistp256": 1
    case "ecdsa-sha2-nistp384": 2
    case "ecdsa-sha2-nistp521": 3
    case "ssh-rsa": 4
    default: 100
    }
  }

  private static func string(from data: Data, maximumCharacters: Int) -> String {
    String(data: data, encoding: .utf8)?
      .prefix(maximumCharacters)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
