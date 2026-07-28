import Foundation
import Security

struct KeychainStore {
  private enum SecretKind: String {
    case password
    case keyPassphrase = "key-passphrase"
    case sessionToken = "session-token"
  }

  private let service = "app.nami.filemanager.servers"

  func save(password: String, for profile: ServerProfile) throws {
    try save(secret: password, kind: .password, for: profile)
    // v0.6.0以前の保存場所を削除します。読み込み時は引き続き移行できます。
    try? delete(account: profile.id.uuidString)
  }

  func password(for profile: ServerProfile) throws -> String? {
    if let password = try secret(kind: .password, for: profile) {
      return password
    }
    // 旧版はUUIDだけをアカウント名としていました。
    return try read(account: profile.id.uuidString)
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
    try delete(account: account(for: profile, kind: .password))
    try delete(account: account(for: profile, kind: .keyPassphrase))
    try delete(account: account(for: profile, kind: .sessionToken))
    try delete(account: profile.id.uuidString)
  }

  private func save(secret: String, kind: SecretKind, for profile: ServerProfile) throws {
    let account = account(for: profile, kind: kind)
    guard !secret.isEmpty else {
      try delete(account: account)
      return
    }

    let data = Data(secret.utf8)
    let query = baseQuery(account: account)
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

  private func secret(kind: SecretKind, for profile: ServerProfile) throws -> String? {
    try read(account: account(for: profile, kind: kind))
  }

  private func read(account: String) throws -> String? {
    var query = baseQuery(account: account)
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

  private func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }

  private func account(for profile: ServerProfile, kind: SecretKind) -> String {
    "\(profile.id.uuidString).\(kind.rawValue)"
  }

  private func baseQuery(account: String) -> [String: Any] {
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
