import Foundation
import Security

struct KeychainStore {
  private enum SecretKind: String {
    case password
    case keyPassphrase = "key-passphrase"
    case sessionToken = "session-token"
  }

  private let service = "app.nafi.filemanager.servers"
  private let legacyService = "app.nami.filemanager.servers"

  func save(password: String, for profile: ServerProfile) throws {
    try save(secret: password, kind: .password, for: profile)
    // v0.6.0以前の保存場所（UUIDのみのアカウント名）を削除します。
    try? delete(service: service, account: profile.id.uuidString)
    try? delete(service: legacyService, account: profile.id.uuidString)
  }

  func password(for profile: ServerProfile) throws -> String? {
    if let password = try secret(kind: .password, for: profile) {
      return password
    }
    // 旧版はUUIDだけをアカウント名としていました。
    return try migratedValue(account: profile.id.uuidString)
  }

  func saveKeyPassphrase(_ passphrase: String, for profile: ServerProfile) throws {
    try save(secret: passphrase, kind: .keyPassphrase, for: profile)
  }

  func keyPassphrase(for profile: ServerProfile) throws -> String? {
    try secret(kind: .keyPassphrase, for: profile)
  }

  func saveSessionToken(_ token: String, for profile: ServerProfile) throws {
    try save(secret: token, kind: .sessionToken, for: profile)
  }

  func sessionToken(for profile: ServerProfile) throws -> String? {
    try secret(kind: .sessionToken, for: profile)
  }

  func deleteSecrets(for profile: ServerProfile) throws {
    var firstError: Error?
    var accounts = [String]()
    for kind in [SecretKind.password, .keyPassphrase, .sessionToken] {
      accounts.append(account(for: profile, kind: kind))
    }
    // Very old versions used only the UUID as the account in both service namespaces.
    accounts.append(profile.id.uuidString)

    for account in accounts {
      for namespace in [service, legacyService] {
        do { try delete(service: namespace, account: account) }
        catch { if firstError == nil { firstError = error } }
      }
    }
    if let firstError { throw firstError }
  }

  private func save(secret: String, kind: SecretKind, for profile: ServerProfile) throws {
    let account = account(for: profile, kind: kind)
    guard !secret.isEmpty else {
      try delete(service: service, account: account)
      try? delete(service: legacyService, account: account)
      return
    }
    try write(service: service, account: account, value: secret)
  }

  private func secret(kind: SecretKind, for profile: ServerProfile) throws -> String? {
    try migratedValue(account: account(for: profile, kind: kind))
  }

  private func migratedValue(account: String) throws -> String? {
    if let value = try read(service: service, account: account) { return value }
    // 旧サービス名（app.nami...）からの移行: 読み込めたら新サービスへ保存し直して旧エントリを削除します。
    if let value = try read(service: legacyService, account: account) {
      try? write(service: service, account: account, value: value)
      try? delete(service: legacyService, account: account)
      return value
    }
    return nil
  }

  private func read(service: String, account: String) throws -> String? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError.status(status)
    }
    return String(data: data, encoding: .utf8)
  }

  private func write(service: String, account: String, value: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError.status(status)
    }
  }

  private func delete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }

  private func account(for profile: ServerProfile, kind: SecretKind) -> String {
    "\(profile.id.uuidString).\(kind.rawValue)"
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
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
