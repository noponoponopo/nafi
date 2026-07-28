import Foundation

/// macOS標準OpenSSHのSFTPエンジンを、nafiの通常ペイン用RemoteServerSessionとして使用します。
/// GUIアプリは起動せず、秘密鍵形式・暗号方式・SSH設定の互換性をOpenSSHへ委譲します。
actor OpenSSHSFTPRemoteSession: RemoteServerSession {
  private struct CommandResult: Sendable {
    let output: String
    let errors: String
    let status: Int32
  }

  private let profile: ServerProfile
  private let keyPath: String
  private let passphrase: String
  private let knownHostsPath: String

  private init(profile: ServerProfile, keyPath: String, passphrase: String) {
    self.profile = profile
    self.keyPath = keyPath
    self.passphrase = passphrase
    self.knownHostsPath = AppStoragePaths.file(named: "known_hosts").path
  }

  static func connect(profile: ServerProfile, keyPassphrase: String) async throws
    -> OpenSSHSFTPRemoteSession
  {
    let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty else {
      throw RemoteServerError.invalidResponse("SFTP接続にはユーザー名が必要です。")
    }
    let rawPath = profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawPath.isEmpty else {
      throw RemoteServerError.invalidResponse("SFTP秘密鍵ファイルが指定されていません。")
    }
    if rawPath.hasSuffix(".pub") {
      throw RemoteServerError.invalidResponse(
        "指定されたファイルは公開鍵です。秘密鍵（.pub の付かないパス）を指定してください: \(rawPath)"
      )
    }
    let path = NSString(string: rawPath).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw RemoteServerError.invalidResponse("SFTP秘密鍵が見つかりません: \(path)")
    }

    let session = OpenSSHSFTPRemoteSession(
      profile: profile,
      keyPath: path,
      passphrase: keyPassphrase
    )
    let root = RemotePath.normalized(profile.path)
    _ = try await session.run(["cd \(Self.quote(root))", "pwd"])
    return session
  }

  func listDirectory(at path: String) async throws -> [RemoteFileItem] {
    let normalized = RemotePath.normalized(path)
    let output = try await run(["ls -lan \(Self.quote(normalized))"])
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let pattern = #"^([bcdlps-][rwxstST-]{9})\s+\S+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.*)$"#
    let regex = try NSRegularExpression(pattern: pattern)

    return lines.compactMap { line -> RemoteFileItem? in
      let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty,
        !cleaned.hasPrefix("sftp>"),
        !cleaned.hasPrefix("Connected to "),
        !cleaned.hasPrefix("total ")
      else { return nil }
      let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
      guard let match = regex.firstMatch(in: cleaned, range: range), match.numberOfRanges == 4,
        let modeRange = Range(match.range(at: 1), in: cleaned),
        let sizeRange = Range(match.range(at: 2), in: cleaned),
        let nameRange = Range(match.range(at: 3), in: cleaned)
      else { return nil }
      var name = String(cleaned[nameRange])
      if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
      if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
      guard name != ".", name != "..", !name.isEmpty else { return nil }
      let mode = String(cleaned[modeRange])
      return RemoteFileItem(
        name: name,
        path: RemotePath.appending(name, to: normalized),
        isDirectory: mode.first == "d",
        size: UInt64(cleaned[sizeRange]),
        modifiedAt: nil
      )
    }
    .sorted(by: remoteItemSort)
  }

  func createDirectory(at path: String) async throws {
    _ = try await run(["mkdir \(Self.quote(RemotePath.normalized(path)))"])
  }

  func renameItem(at oldPath: String, to newPath: String) async throws {
    _ = try await run([
      "rename \(Self.quote(RemotePath.normalized(oldPath))) \(Self.quote(RemotePath.normalized(newPath)))"
    ])
  }

  func removeItem(at path: String, isDirectory: Bool) async throws {
    let command = isDirectory ? "rmdir" : "rm"
    _ = try await run(["\(command) \(Self.quote(RemotePath.normalized(path)))"])
  }

  func downloadItem(at remotePath: String, to localURL: URL) async throws {
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try await run([
      "get -p \(Self.quote(RemotePath.normalized(remotePath))) \(Self.quote(localURL.path))"
    ])
  }

  func uploadItem(from localURL: URL, to remotePath: String) async throws {
    _ = try await run([
      "put -p \(Self.quote(localURL.path)) \(Self.quote(RemotePath.normalized(remotePath)))"
    ])
  }

  func close() async {}

  private func run(_ commands: [String]) async throws -> String {
    let result = await Self.execute(
      profile: profile,
      keyPath: keyPath,
      passphrase: passphrase,
      knownHostsPath: knownHostsPath,
      commands: commands
    )
    guard result.status == 0 else {
      throw RemoteServerError.invalidResponse(Self.readableError(result))
    }
    return result.output
  }

  private nonisolated static func execute(
    profile: ServerProfile,
    keyPath: String,
    passphrase: String,
    knownHostsPath: String,
    commands: [String]
  ) async -> CommandResult {
    await Task.detached(priority: .userInitiated) {
      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("nafi-sftp-auth-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: temporary.path)
      } catch {
        return CommandResult(output: "", errors: error.localizedDescription, status: -1)
      }
      defer { try? FileManager.default.removeItem(at: temporary) }

      let askpassURL = temporary.appendingPathComponent("askpass.sh")
      let passphraseURL = temporary.appendingPathComponent("passphrase")
      do {
        let askpass = "#!/bin/sh\nexec /bin/cat \"$NAFI_ASKPASS_FILE\"\n"
        try askpass.write(to: askpassURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: askpassURL.path)
        try Data(passphrase.utf8).write(to: passphraseURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: passphraseURL.path)
        if !FileManager.default.fileExists(atPath: knownHostsPath) {
          _ = FileManager.default.createFile(atPath: knownHostsPath, contents: nil)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: knownHostsPath)
        }
      } catch {
        return CommandResult(output: "", errors: error.localizedDescription, status: -1)
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
      let destination =
        profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
      process.arguments = [
        "-q",
        "-o", "BatchMode=no",
        "-b", "-",
        "-P", String(profile.port),
        "-i", keyPath,
        "-o", "IdentitiesOnly=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=\(knownHostsPath)",
        "-o", "ConnectTimeout=25",
        "-o", "ServerAliveInterval=15",
        destination,
      ]
      var environment = ProcessInfo.processInfo.environment
      environment["LC_ALL"] = "C"
      environment["LANG"] = "C"
      environment["SSH_ASKPASS"] = askpassURL.path
      environment["SSH_ASKPASS_REQUIRE"] = "force"
      environment["DISPLAY"] = "nafi:0"
      environment["NAFI_ASKPASS_FILE"] = passphraseURL.path
      process.environment = environment

      let input = Pipe()
      let output = Pipe()
      let errors = Pipe()
      process.standardInput = input
      process.standardOutput = output
      process.standardError = errors

      do {
        try process.run()
        let batch = commands.joined(separator: "\n") + "\n"
        let outputReader = Task.detached {
          output.fileHandleForReading.readDataToEndOfFile()
        }
        let errorReader = Task.detached {
          errors.fileHandleForReading.readDataToEndOfFile()
        }
        input.fileHandleForWriting.write(Data(batch.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let outputData = await outputReader.value
        let errorData = await errorReader.value
        return CommandResult(
          output: String(data: outputData, encoding: .utf8) ?? "",
          errors: String(data: errorData, encoding: .utf8) ?? "",
          status: process.terminationStatus
        )
      } catch {
        return CommandResult(output: "", errors: error.localizedDescription, status: -1)
      }
    }.value
  }

  private nonisolated static func readableError(_ result: CommandResult) -> String {
    let combined = (result.errors + "\n" + result.output)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = combined.lowercased()
    if lower.contains("incorrect passphrase") || lower.contains("bad passphrase") {
      return "SFTP秘密鍵のパスフレーズが正しくありません。"
    }
    if lower.contains("permission denied (publickey") {
      return "SFTPサーバーが秘密鍵を拒否しました。ユーザー名と、サーバーへ登録した公開鍵を確認してください。"
    }
    if lower.contains("invalid format") || lower.contains("error in libcrypto") {
      return "SFTP秘密鍵を読み込めません。鍵ファイルの形式または内容を確認してください。"
    }
    if lower.contains("unprotected private key file") || lower.contains("bad permissions") {
      return "SFTP秘密鍵のアクセス権が広すぎます。ターミナルで chmod 600 <秘密鍵> を実行してください。"
    }
    if lower.contains("host key verification failed")
      || lower.contains("remote host identification has changed")
    {
      return "SFTPホストキーが以前の接続時と一致しません。なりすましの可能性があるため接続を停止しました。nafiのknown_hostsを確認してください。"
    }
    if lower.contains("no such file") {
      return "SFTP上の指定されたパスが見つかりません。\(combined)"
    }
    if lower.contains("connection refused") || lower.contains("operation timed out") {
      return "SFTPサーバーへ接続できません。ホスト名・ポート・ネットワークを確認してください。\(combined)"
    }
    return combined.isEmpty ? "SFTP操作に失敗しました（終了コード \(result.status)）。" : combined
  }

  private nonisolated static func quote(_ value: String) -> String {
    "\""
      + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
