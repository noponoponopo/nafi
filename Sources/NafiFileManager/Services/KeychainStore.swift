import Foundation

#if canImport(Security) && canImport(CryptoKit)
  import CryptoKit
  import LocalAuthentication
  import Security
#endif

struct ServerSecrets: Codable, Equatable, Sendable {
  var password = ""
  var keyPassphrase = ""
  var sessionToken = ""

  func mergingUnchangedFields(from latest: Self, baseline: Self, passwordIsJSON: Bool) throws
    -> Self
  {
    var merged = self
    if password == baseline.password {
      merged.password = latest.password
    } else if passwordIsJSON {
      func object(_ text: String) throws -> [String: JSONValue] {
        guard !text.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
      }
      var edited = try object(password)
      let original = try object(baseline.password)
      let current = try object(latest.password)
      for key in Set(original.keys).union(current.keys) where edited[key] == original[key] {
        edited[key] = current[key]
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      merged.password = String(decoding: try encoder.encode(edited), as: UTF8.self)
    }
    if keyPassphrase == baseline.keyPassphrase { merged.keyPassphrase = latest.keyPassphrase }
    if sessionToken == baseline.sessionToken { merged.sessionToken = latest.sessionToken }
    return merged
  }
}

protocol CredentialVaultBackend: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
  func legacySecrets(for profileID: UUID) throws -> ServerSecrets
  func removeLegacySecrets(for profileID: UUID)
}

/// One serialized, lazily unlocked vault. Connections never perform Keychain I/O
/// on the main actor and a failed unlock is shared rather than prompted repeatedly.
actor KeychainStore {
  private struct Vault: Codable {
    var version = 1
    // An empty entry is also a tombstone: a deleted legacy password must not return.
    var profiles: [String: ServerSecrets] = [:]
  }

  private let backend: any CredentialVaultBackend
  private var vault: Vault?
  private var unlockError: Error?
  private var migrationErrors: [UUID: Error] = [:]

  init(backend: any CredentialVaultBackend) {
    self.backend = backend
  }

  func retryUnlock() {
    unlockError = nil
    migrationErrors.removeAll()
  }

  func prepare(profileIDs: [UUID]) throws {
    guard !profileIDs.isEmpty else { return }
    var next = try loadedVault()
    var migrated: [UUID] = []
    for id in Set(profileIDs) where next.profiles[id.uuidString] == nil {
      guard migrationErrors[id] == nil else { continue }
      do {
        next.profiles[id.uuidString] = try backend.legacySecrets(for: id)
        migrated.append(id)
      } catch {
        // Never convert a denied read into an empty password or erase the old item.
        migrationErrors[id] = error
      }
    }
    guard !migrated.isEmpty else { return }
    try commit(next)
    for id in migrated { backend.removeLegacySecrets(for: id) }
  }

  func secrets(for profileID: UUID) throws -> ServerSecrets {
    try prepare(profileIDs: [profileID])
    if let error = migrationErrors[profileID] { throw error }
    return vault?.profiles[profileID.uuidString] ?? ServerSecrets()
  }

  @discardableResult
  func save(_ secrets: ServerSecrets, for profileID: UUID) throws -> ServerSecrets? {
    var next = try loadedVault()
    let old = next.profiles[profileID.uuidString]
    if old != secrets {
      next.profiles[profileID.uuidString] = secrets
      try commit(next)
    }
    migrationErrors[profileID] = nil
    // Legacy cleanup happens after the profile transaction commits, not here.
    return old
  }

  func updatePassword(for profileID: UUID, _ transform: @Sendable (String) throws -> String) throws
  {
    var value = try secrets(for: profileID)
    value.password = try transform(value.password)
    try save(value, for: profileID)
  }

  func removeSecrets(for profileID: UUID) throws -> ServerSecrets? {
    try save(ServerSecrets(), for: profileID)
  }

  func finishMigration(for profileID: UUID) {
    backend.removeLegacySecrets(for: profileID)
  }

  func restore(_ previous: ServerSecrets?, for profileID: UUID, replacing expected: ServerSecrets)
    throws
  {
    var next = try loadedVault()
    guard next.profiles[profileID.uuidString] == expected else {
      throw CredentialVaultError.changedDuringSave
    }
    next.profiles[profileID.uuidString] = previous
    try commit(next)
  }

  private func loadedVault() throws -> Vault {
    if let vault { return vault }
    if let unlockError { throw unlockError }
    do {
      let loaded: Vault
      if let data = try backend.read() {
        guard data.count <= 16 * 1_024 * 1_024 else { throw CredentialVaultError.corrupt }
        loaded = try JSONDecoder().decode(Vault.self, from: data)
        guard loaded.version == 1, loaded.profiles.count <= 20_000 else {
          throw CredentialVaultError.corrupt
        }
      } else {
        loaded = Vault()
      }
      vault = loaded
      return loaded
    } catch {
      unlockError = error
      throw error
    }
  }

  private func commit(_ next: Vault) throws {
    let data = try JSONEncoder().encode(next)
    guard data.count <= 16 * 1_024 * 1_024, next.profiles.count <= 20_000 else {
      throw CredentialVaultError.tooLarge
    }
    try backend.write(data)
    vault = next
  }
}

enum CredentialVaultError: LocalizedError {
  case corrupt, missingKey, tooLarge, legacyApprovalRequired, changedDuringSave

  var errorDescription: String? {
    switch self {
    case .corrupt:
      "認証情報を読み取れません。保存済みの情報は上書きしていません。"
    case .missingKey:
      "認証情報の暗号化キーがキーチェーンに見つかりません。元のキーチェーンを復元してください。"
    case .tooLarge:
      "保存する認証情報が上限を超えています。"
    case .legacyApprovalRequired:
      "旧版の認証情報には個別のアクセス許可が必要です。繰り返し許可を求めないため、接続の編集画面で認証情報を再入力してください。元の情報は保持しています。"
    case .changedDuringSave:
      "保存中に認証情報が更新されたため、古い情報への復元を中止しました。接続設定を確認してください。"
    }
  }
}

#if canImport(Security) && canImport(CryptoKit)
  extension KeychainStore {
    init() { self.init(backend: EncryptedKeychainBackend()) }
  }

  /// Accessed only by KeychainStore. Only this 256-bit key is a Keychain item;
  /// all profile secrets are authenticated ciphertext, including during writes.
  private final class EncryptedKeychainBackend: CredentialVaultBackend, @unchecked Sendable {
    private let service = "app.nafi.filemanager.servers"
    private let keyAccount = "credential-vault-key-v1"
    private let associatedData = Data("app.nafi.filemanager.credentials.v1".utf8)
    private var key: SymmetricKey?
    private let url = AppStoragePaths.file(named: "credentials.encrypted")

    func read() throws -> Data? {
      let exists = FileManager.default.fileExists(atPath: url.path)
      let key = try encryptionKey(existingVault: exists)
      guard exists else { return nil }
      let ciphertext = try AppStoragePaths.readRegularFile(
        at: url, maximumBytes: 17 * 1_024 * 1_024)
      do {
        return try AES.GCM.open(
          AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: associatedData)
      } catch {
        throw CredentialVaultError.corrupt
      }
    }

    func write(_ data: Data) throws {
      let key = try encryptionKey(existingVault: FileManager.default.fileExists(atPath: url.path))
      guard
        let ciphertext = try AES.GCM.seal(data, using: key, authenticating: associatedData).combined
      else {
        throw CredentialVaultError.corrupt
      }
      try AppStoragePaths.writePrivateAtomically(ciphertext, to: url)
    }

    private func encryptionKey(existingVault: Bool) throws -> SymmetricKey {
      if let key { return key }
      if let data = try readItem(service: service, account: keyAccount, allowUI: true) {
        guard data.count == 32 else { throw CredentialVaultError.corrupt }
        let value = SymmetricKey(data: data)
        key = value
        return value
      }
      guard !existingVault else { throw CredentialVaultError.missingKey }
      let value = SymmetricKey(size: .bits256)
      var query = itemQuery(service: service, account: keyAccount)
      query[kSecValueData as String] = value.withUnsafeBytes { Data($0) }
      query[kSecAttrLabel as String] = "nafi — 接続の認証情報"
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(query as CFDictionary, nil)
      guard status == errSecSuccess else { throw KeychainError.status(status) }
      key = value
      return value
    }

    func legacySecrets(for profileID: UUID) throws -> ServerSecrets {
      func value(_ suffix: String) throws -> String {
        let accounts =
          suffix == "password"
          ? ["\(profileID.uuidString).password", profileID.uuidString]
          : ["\(profileID.uuidString).\(suffix)"]
        for account in accounts {
          for namespace in [service, "app.nami.filemanager.servers"] {
            if let data = try readItem(service: namespace, account: account, allowUI: false) {
              guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.corrupt
              }
              return value
            }
          }
        }
        return ""
      }
      return try ServerSecrets(
        password: value("password"),
        keyPassphrase: value("key-passphrase"),
        sessionToken: value("session-token")
      )
    }

    func removeLegacySecrets(for profileID: UUID) {
      let context = nonInteractiveContext()
      let accounts =
        [profileID.uuidString]
        + ["password", "key-passphrase", "session-token"].map {
          "\(profileID.uuidString).\($0)"
        }
      for account in accounts {
        for namespace in [service, "app.nami.filemanager.servers"] {
          var query = itemQuery(service: namespace, account: account)
          query[kSecUseAuthenticationContext as String] = context
          _ = SecItemDelete(query as CFDictionary)
        }
      }
    }

    private func readItem(service: String, account: String, allowUI: Bool) throws -> Data? {
      var query = itemQuery(service: service, account: account)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      if !allowUI { query[kSecUseAuthenticationContext as String] = nonInteractiveContext() }
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      if !allowUI,
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
      {
        throw CredentialVaultError.legacyApprovalRequired
      }
      guard status == errSecSuccess else { throw KeychainError.status(status) }
      guard let data = result as? Data else { throw CredentialVaultError.corrupt }
      return data
    }

    private func nonInteractiveContext() -> LAContext {
      let context = LAContext()
      context.interactionNotAllowed = true
      return context
    }

    private func itemQuery(service: String, account: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
    }
  }

  enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
      switch self {
      case .status(let status):
        return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain エラー: \(status)"
      }
    }
  }
#endif
