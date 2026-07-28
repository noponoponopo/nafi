import AppKit
import Foundation

@MainActor
enum TerminalApplicationService {
  static func open(at location: URL) async throws {
    let command: String
    if NafiURL.isRemote(location) {
      guard let profile = await UnifiedFileSystemService.profile(for: location) else {
        throw RemoteServerError.notConnected
      }
      guard profile.kind == .sftp else {
        throw RemoteServerError.unsupported(
          "この接続方式には対話シェルがありません。「ここでターミナルを開く」はSFTP/SSH接続で利用できます。")
      }
      command = sshCommand(profile: profile, path: NafiURL.remotePath(in: location) ?? "/")
    } else {
      command = "cd -- \(shellQuote(location.path))\nexec \"${SHELL:-/bin/zsh}\" -l"
    }

    let scriptURL = try makeCommandFile(command: command)
    try await openUsingDefaultTerminal(scriptURL)
  }

  private static func sshCommand(profile: ServerProfile, path: String) -> String {
    var arguments = ["/usr/bin/ssh", "-t", "-p", String(profile.port)]
    if profile.sftpAuthentication == .privateKey,
      !profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let keyPath = NSString(string: profile.privateKeyPath).expandingTildeInPath
      arguments += ["-i", keyPath]
    }
    let destination =
      profile.username.isEmpty
      ? profile.host
      : "\(profile.username)@\(profile.host)"
    arguments.append(destination)
    let remoteCommand = "cd -- \(shellQuote(path)) && exec \"${SHELL:-/bin/sh}\" -l"
    arguments.append(remoteCommand)
    return "exec " + arguments.map(shellQuote).joined(separator: " ")
  }

  private static func makeCommandFile(command: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nafi-terminal", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("nafi-\(UUID().uuidString).command")
    let script = """
      #!/bin/zsh
      trap 'rm -f -- "$0"' EXIT
      \(command)
      """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private static func openUsingDefaultTerminal(_ scriptURL: URL) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(scriptURL, configuration: configuration) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
