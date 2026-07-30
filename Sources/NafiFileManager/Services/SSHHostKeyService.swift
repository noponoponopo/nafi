import CryptoKit
import Foundation

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

actor SSHHostKeyService {
  static let shared = SSHHostKeyService()

  enum ServiceError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case commandUnavailable(String)
    case scanFailed(String)
    case noKeys
    case malformedKey
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
      case .staleScan: "確認から時間が経過したため、ホストキーをもう一度取得してください。"
      case .persistence(let message): "SSHホストキーを保存できませんでした。\(message)"
      }
    }
  }

  private let knownHostsURL = AppStoragePaths.file(named: "known_hosts")
  private let openSSHKnownHostsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".ssh/known_hosts")
  private let keyscanURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
  private let keygenURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")

  func prepareKnownHosts(host rawHost: String, port: Int) async throws -> [String] {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    let endpoint = Self.knownHostsEndpoint(host: host, port: port)
    if try await isTrusted(host: host, port: port) {
      return try await trustedAlgorithms(endpoint: endpoint, fileURL: knownHostsURL)
    }

    // Check ~/.ssh/known_hosts for a matching key from OpenSSH usage.
    if FileManager.default.fileExists(atPath: openSSHKnownHostsURL.path) {
      _ = try? AppStoragePaths.readRegularFile(
        at: openSSHKnownHostsURL,
        maximumBytes: 16 * 1_024 * 1_024
      )
      try requireExecutable(keygenURL)
      let result = try await BoundedProcessRunner.run(
        executableURL: keygenURL,
        arguments: ["-F", endpoint, "-f", openSSHKnownHostsURL.path],
        timeout: 10,
        maximumStandardOutputBytes: 256 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
      )
      if result.terminationStatus == 0 {
        let trustedIdentities = Self.knownHostIdentities(in: result.stdout)
        if !trustedIdentities.isEmpty {
          let scan = try await scan(host: host, port: port)
          let matchedKeys = scan.keys.filter {
            trustedIdentities.contains("\($0.algorithm) \($0.fingerprint)")
          }
          if !matchedKeys.isEmpty {
            try await trust(
              SSHHostKeyScan(host: scan.host, port: scan.port, scannedAt: scan.scannedAt, keys: matchedKeys)
            )
            return matchedKeys.map(\.algorithm)
          }
        }
      }
    }

    // Trust on first use: scan and register the server's keys automatically.
    let scan = try await scan(host: host, port: port)
    try await trust(scan)
    return scan.keys.map(\.algorithm)
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

    try ensureKnownHostsFile()
    let endpoint = Self.knownHostsEndpoint(host: host, port: scan.port)
    let temporaryURL = AppStoragePaths.directory.appendingPathComponent(
      ".known-hosts-update-\(UUID().uuidString)",
      isDirectory: false
    )
    let oldBackupURL = URL(fileURLWithPath: temporaryURL.path + ".old")
    defer {
      try? FileManager.default.removeItem(at: temporaryURL)
      try? FileManager.default.removeItem(at: oldBackupURL)
    }

    do {
      let current = try loadKnownHostsData()
      try current.write(to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
      )
      try await removeEndpoint(endpoint, from: temporaryURL)

      let updated: Data
      do {
        updated = try AppStoragePaths.readRegularFile(
          at: temporaryURL,
          maximumBytes: 4 * 1_024 * 1_024
        )
      } catch {
        throw ServiceError.persistence("known_hostsの更新結果を読み込めませんでした。")
      }
      guard let decoded = String(data: updated, encoding: .utf8) else {
        throw ServiceError.persistence("known_hostsをUTF-8として読み込めませんでした。")
      }
      var text = decoded
      if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
      for key in scan.keys {
        text += "\(endpoint) \(key.algorithm) \(key.encodedKey)\n"
      }
      guard text.utf8.count <= 4 * 1024 * 1024 else {
        throw ServiceError.persistence("known_hostsが安全上限を超えています。")
      }
      try Data(text.utf8).write(
        to: knownHostsURL,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: knownHostsURL.path
      )
    } catch let error as ServiceError {
      throw error
    } catch {
      throw ServiceError.persistence(error.localizedDescription)
    }
  }

  func isTrusted(host rawHost: String, port: Int) async throws -> Bool {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    _ = try loadKnownHostsData()
    try requireExecutable(keygenURL)
    let endpoint = Self.knownHostsEndpoint(host: host, port: port)
    do {
      let result = try await BoundedProcessRunner.run(
        executableURL: keygenURL,
        arguments: ["-F", endpoint, "-f", knownHostsURL.path],
        timeout: 10,
        maximumStandardOutputBytes: 256 * 1024,
        maximumStandardErrorBytes: 64 * 1024
      )
      return result.terminationStatus == 0 && !result.stdout.isEmpty
    } catch {
      throw ServiceError.persistence(error.localizedDescription)
    }
  }

  func removeTrustedKeys(host rawHost: String, port: Int) async throws {
    let host = try Self.validatedHost(rawHost)
    try Self.validatePort(port)
    guard FileManager.default.fileExists(atPath: knownHostsURL.path) else { return }
    try requireExecutable(keygenURL)

    let temporaryURL = AppStoragePaths.directory.appendingPathComponent(
      ".known-hosts-remove-\(UUID().uuidString)",
      isDirectory: false
    )
    let oldBackupURL = URL(fileURLWithPath: temporaryURL.path + ".old")
    defer {
      try? FileManager.default.removeItem(at: temporaryURL)
      try? FileManager.default.removeItem(at: oldBackupURL)
    }

    do {
      let current = try loadKnownHostsData()
      try current.write(to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try await removeEndpoint(Self.knownHostsEndpoint(host: host, port: port), from: temporaryURL)
      let updated: Data
      do {
        updated = try AppStoragePaths.readRegularFile(
          at: temporaryURL,
          maximumBytes: 4 * 1_024 * 1_024
        )
      } catch {
        throw ServiceError.persistence("known_hostsの更新結果を読み込めませんでした。")
      }
      try updated.write(to: knownHostsURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: knownHostsURL.path
      )
    } catch let error as ServiceError {
      throw error
    } catch {
      throw ServiceError.persistence(error.localizedDescription)
    }
  }

  private func loadKnownHostsData() throws -> Data {
    try ensureKnownHostsFile()
    do {
      return try AppStoragePaths.readRegularFile(
        at: knownHostsURL,
        maximumBytes: 4 * 1_024 * 1_024
      )
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: knownHostsURL, label: "unreadable-known-hosts")
      try ensureKnownHostsFile()
      return Data()
    }
  }

  private func ensureKnownHostsFile() throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: knownHostsURL.path) {
      let values = try knownHostsURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isRegularFile == true, values.isSymbolicLink != true {
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        return
      }
      AppStoragePaths.quarantineCorruptFile(at: knownHostsURL, label: "invalid-known-hosts")
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
    try requireExecutable(keygenURL)
    let result = try await BoundedProcessRunner.run(
      executableURL: keygenURL,
      arguments: ["-F", endpoint, "-f", fileURL.path],
      timeout: 10,
      maximumStandardOutputBytes: 256 * 1_024,
      maximumStandardErrorBytes: 64 * 1_024
    )
    guard result.terminationStatus == 0 else { return [] }
    return Self.knownHostIdentities(in: result.stdout).compactMap { identity in
      identity.split(separator: " ", maxSplits: 1).first.map(String.init)
    }.sorted()
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
