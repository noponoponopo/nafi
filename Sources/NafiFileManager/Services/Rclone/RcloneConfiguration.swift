import Foundation

enum RcloneConfiguration {
  static func remoteName(for profileID: UUID) -> String {
    "nafi_" + profileID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  static func fs(for profile: ServerProfile) -> String {
    if profile.kind == .nfs || profile.kind == .afp {
      return URL(fileURLWithPath: NSString(string: profile.localMountPath).expandingTildeInPath)
        .standardizedFileURL.path
    }
    if profile.kind == .sftp {
      // Nafi's historical SFTP model is rooted at the server filesystem root,
      // not the login user's home. Root the rclone Fs once and keep all item
      // paths relative so operation APIs cannot silently change that meaning.
      return "\(remoteName(for: profile.id)):/"
    }
    if profile.kind == .s3 {
      let bucket = profile.s3Bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return bucket.isEmpty ? "\(remoteName(for: profile.id)):" : "\(remoteName(for: profile.id)):\(bucket)"
    }
    return "\(remoteName(for: profile.id)):"
  }

  static func backendType(for profile: ServerProfile) -> String {
    switch profile.kind {
    case .sftp: "sftp"
    case .ftp: "ftp"
    case .s3: "s3"
    case .smb: "smb"
    case .webdav: "webdav"
    case .rclone: profile.rcloneBackend.trimmingCharacters(in: .whitespacesAndNewlines)
    case .nfs, .afp: "local"
    }
  }

  static func parameters(
    for profile: ServerProfile,
    secrets: RcloneProfileSecrets,
    sftpHostKeyAlgorithms: [String] = []
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    switch profile.kind {
    case .sftp:
      result.set("host", profile.host)
      result.set("user", profile.username)
      result.set("port", profile.port)
      result.set("known_hosts_file", AppStoragePaths.file(named: "known_hosts").path)
      result.set("host_key_algorithms", sftpHostKeyAlgorithms.joined(separator: " "))
      if let shellType = profile.sftpShellType.rcloneValue {
        result.set("shell_type", shellType)
      }
      if profile.sftpShellType == .disabled { result.set("disable_hashcheck", true) }
      switch profile.sftpAuthentication {
      case .password:
        result.set("pass", secrets.password)
      case .privateKey:
        result.set("key_file", NSString(string: profile.privateKeyPath).expandingTildeInPath)
        result.set("key_file_pass", secrets.keyPassphrase)
      case .sshAgent:
        result.set("key_use_agent", true)
        let keyPath = profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyPath.isEmpty {
          result.set("key_file", NSString(string: keyPath).expandingTildeInPath)
        }
      }

    case .ftp:
      result.set("host", profile.host)
      result.set("user", profile.username)
      result.set("pass", secrets.password)
      result.set("port", profile.port)
      result.set("tls", profile.ftpEncryption == .implicitTLS)
      result.set("explicit_tls", profile.ftpEncryption == .explicitTLS)
      result.set("no_check_certificate", !profile.verifyTLSCertificate)

    case .s3:
      result.set("provider", "Other")
      result.set("env_auth", false)
      if !profile.s3Anonymous {
        result.set("access_key_id", profile.username)
        result.set("secret_access_key", secrets.password)
        result.set("session_token", secrets.sessionToken)
      }
      result.set("region", profile.s3Region == "auto" ? "" : profile.s3Region)
      var endpoint = profile.host
      if !endpoint.contains("://") { endpoint = "\(profile.useTLS ? "https" : "http")://\(endpoint)" }
      result.set("endpoint", endpoint)
      result.set("force_path_style", profile.s3AddressingStyle != .virtualHostedStyle)
      result.set("no_check_certificate", !profile.verifyTLSCertificate)

    case .smb:
      result.set("host", profile.host)
      result.set("user", profile.username)
      result.set("pass", secrets.password)
      result.set("port", profile.port)

    case .webdav:
      var components = URLComponents()
      components.scheme = profile.useTLS ? "https" : "http"
      components.host = profile.host
      if profile.port != profile.effectiveDefaultPort { components.port = profile.port }
      guard let url = components.url?.absoluteString else {
        throw RcloneRuntimeError.remoteConfiguration("WebDAV URLを構築できません。")
      }
      result.set("url", url)
      result.set("vendor", "other")
      result.set("user", profile.username)
      result.set("pass", secrets.password)

    case .rclone:
      result = try decodeObject(profile.rcloneParametersJSON, label: "rcloneパラメータ")
      let secret = secrets.password.trimmingCharacters(in: .whitespacesAndNewlines)
      if !secret.isEmpty {
        for (key, value) in try decodeObject(secret, label: "rclone秘密パラメータ") {
          result[key] = value
        }
      }

    case .nfs, .afp:
      let path = NSString(string: profile.localMountPath).expandingTildeInPath
      guard !path.isEmpty else {
        throw RcloneRuntimeError.remoteConfiguration("NFS/AFPはmacOSでマウントしたローカルパスが必要です。")
      }
      result.set("nounc", true)
    }
    return result
  }

  static func validateParametersJSON(_ text: String) throws {
    _ = try decodeObject(text, label: "rcloneパラメータ")
  }

  static func replacingOAuthToken(_ token: String, in secretParametersJSON: String) throws -> String {
    guard !token.isEmpty, token.utf8.count <= 1_048_576,
      (try? JSONSerialization.jsonObject(with: Data(token.utf8))) is [String: Any]
    else {
      throw RcloneRuntimeError.remoteConfiguration("OAuthトークンの形式が不正です。")
    }
    var parameters = secretParametersJSON.isEmpty
      ? [:]
      : try decodeObject(secretParametersJSON, label: "rclone秘密パラメータ")
    parameters["token"] = .string(token)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(parameters), as: UTF8.self)
  }

  private static func decodeObject(_ text: String, label: String) throws -> [String: JSONValue] {
    let data = Data(text.utf8)
    guard data.count <= 1_048_576 else {
      throw RcloneRuntimeError.remoteConfiguration("\(label)は1 MiB以内にしてください。")
    }
    do {
      let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
      var nodeCount = 0
      try validate(object: object, depth: 0, nodeCount: &nodeCount, label: label)
      return object
    } catch {
      throw RcloneRuntimeError.remoteConfiguration("\(label)はJSONオブジェクトで入力してください。\n\(error.localizedDescription)")
    }
  }

  private static func validate(
    object: [String: JSONValue],
    depth: Int,
    nodeCount: inout Int,
    label: String
  ) throws {
    guard depth <= 16 else {
      throw RcloneRuntimeError.remoteConfiguration("\(label)の入れ子が深すぎます。")
    }
    for (key, value) in object {
      nodeCount += 1
      guard nodeCount <= 10_000, key.utf8.count <= 256,
        !key.hasPrefix("_"),
        !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        throw RcloneRuntimeError.remoteConfiguration(
          "\(label)に予約キー、長すぎるキー、または過剰な項目が含まれています。"
        )
      }
      try validate(value: value, depth: depth + 1, nodeCount: &nodeCount, label: label)
    }
  }

  private static func validate(
    value: JSONValue,
    depth: Int,
    nodeCount: inout Int,
    label: String
  ) throws {
    guard depth <= 16 else {
      throw RcloneRuntimeError.remoteConfiguration("\(label)の入れ子が深すぎます。")
    }
    switch value {
    case .object(let object):
      try validate(object: object, depth: depth, nodeCount: &nodeCount, label: label)
    case .array(let values):
      guard values.count <= 10_000 else {
        throw RcloneRuntimeError.remoteConfiguration("\(label)の配列が大きすぎます。")
      }
      for child in values {
        nodeCount += 1
        guard nodeCount <= 10_000 else {
          throw RcloneRuntimeError.remoteConfiguration("\(label)の項目数が多すぎます。")
        }
        try validate(value: child, depth: depth + 1, nodeCount: &nodeCount, label: label)
      }
    case .string(let text):
      guard text.utf8.count <= 1_048_576 else {
        throw RcloneRuntimeError.remoteConfiguration("\(label)の文字列が長すぎます。")
      }
    case .bool, .integer, .double, .null:
      break
    }
  }
}

extension ServerProfile {
  var rcloneConfigurationSignature: Int {
    var hasher = Hasher()
    hasher.combine(id)
    hasher.combine(kind)
    hasher.combine(host)
    hasher.combine(port)
    hasher.combine(path)
    hasher.combine(username)
    hasher.combine(useTLS)
    hasher.combine(localMountPath)
    hasher.combine(sftpAuthentication)
    hasher.combine(sftpShellType)
    hasher.combine(privateKeyPath)
    hasher.combine(ftpEncryption)
    hasher.combine(verifyTLSCertificate)
    hasher.combine(s3Bucket)
    hasher.combine(s3Region)
    hasher.combine(s3AddressingStyle)
    hasher.combine(s3Anonymous)
    hasher.combine(rcloneBackend)
    hasher.combine(rcloneParametersJSON)
    return hasher.finalize()
  }
}
