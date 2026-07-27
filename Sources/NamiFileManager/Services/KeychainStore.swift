import Foundation
import Security

struct KeychainStore {
  private let service = "app.nami.filemanager.servers"

  func save(password: String, for profile: ServerProfile) throws {
    guard !password.isEmpty else {
      try deletePassword(for: profile)
      return
    }
    let data = Data(password.utf8)
    let query = baseQuery(for: profile)
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

  func password(for profile: ServerProfile) throws -> String? {
    var query = baseQuery(for: profile)
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

  func deletePassword(for profile: ServerProfile) throws {
    let status = SecItemDelete(baseQuery(for: profile) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }

  private func baseQuery(for profile: ServerProfile) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: profile.id.uuidString,
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
