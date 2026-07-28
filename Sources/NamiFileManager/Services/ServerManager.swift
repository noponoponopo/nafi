import AppKit
import Combine
import Foundation

@MainActor
final class ServerManager: ObservableObject {
  @Published private(set) var profiles: [ServerProfile] = []
  @Published private(set) var states: [UUID: ServerConnectionState] = [:]
  @Published private(set) var mountedVolumes: [MountedVolume] = []

  private let keychain = KeychainStore()
  private let persistenceURL: URL

  init() {
    persistenceURL = AppStoragePaths.file(named: "servers.json")
    loadProfiles()

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshMountedVolumes() }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didUnmountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshMountedVolumes() }
    }
  }

  func state(for profile: ServerProfile) -> ServerConnectionState {
    states[profile.id] ?? .idle
  }

  func save(profile: ServerProfile, password: String) throws {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try keychain.save(password: password, for: profile)
    try persistProfiles()
  }

  func remove(_ profile: ServerProfile) {
    profiles.removeAll { $0.id == profile.id }
    states[profile.id] = nil
    try? keychain.deletePassword(for: profile)
    try? persistProfiles()
  }

  func password(for profile: ServerProfile) -> String {
    (try? keychain.password(for: profile)) ?? ""
  }

  func connectAutoProfiles() async {
    for profile in profiles where profile.autoConnect {
      for attempt in 0..<3 {
        await connect(profile)
        switch state(for: profile) {
        case .connected, .helperRequired:
          break
        case .idle, .connecting, .failed:
          if attempt < 2 {
            let delay = UInt64(1 << attempt) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            continue
          }
        }
        break
      }
    }
  }

  func connect(_ profile: ServerProfile) async {
    guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      states[profile.id] = .failed("ホスト名がありません")
      return
    }
    states[profile.id] = .connecting

    switch profile.kind {
    case .sftp:
      await connectSFTP(profile)
    default:
      connectUsingSystem(profile)
    }
  }

  func disconnect(_ profile: ServerProfile) async {
    refreshMountedVolumes()
    let target: URL? = {
      if !profile.localMountPath.isEmpty {
        return URL(fileURLWithPath: profile.localMountPath)
      }
      let share = profile.path.split(separator: "/").last.map(String.init)
      return mountedVolumes.first { volume in
        guard let share else { return volume.name.localizedCaseInsensitiveContains(profile.host) }
        return volume.name.localizedCaseInsensitiveContains(share)
      }?.url
    }()

    guard let target else {
      states[profile.id] = .idle
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["unmount", target.path]
    do {
      try process.run()
      process.waitUntilExit()
      states[profile.id] = process.terminationStatus == 0 ? .idle : .failed("アンマウントできませんでした")
      refreshMountedVolumes()
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  func refreshMountedVolumes() {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys,
        options: [.skipHiddenVolumes]
      ) ?? []

    mountedVolumes = urls.compactMap { url in
      let values = try? url.resourceValues(forKeys: Set(keys))
      return MountedVolume(
        url: url,
        name: values?.volumeName ?? url.lastPathComponent,
        isLocal: values?.volumeIsLocal ?? true,
        isReadOnly: values?.volumeIsReadOnly ?? false
      )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func connectUsingSystem(_ profile: ServerProfile) {
    guard let url = profile.connectionURL else {
      states[profile.id] = .failed("URLを作成できません")
      return
    }

    let password = password(for: profile)
    let escapedURL = appleScriptQuoted(url.absoluteString)
    let escapedUser = appleScriptQuoted(profile.username)
    let escapedPassword = appleScriptQuoted(password)

    var command = "mount volume \"\(escapedURL)\""
    if !profile.username.isEmpty {
      command += " as user name \"\(escapedUser)\""
      if !password.isEmpty { command += " with password \"\(escapedPassword)\"" }
    }

    var errorInfo: NSDictionary?
    let result = NSAppleScript(source: command)?.executeAndReturnError(&errorInfo)
    if result != nil {
      states[profile.id] = .connected(nil)
      refreshMountedVolumes()
    } else {
      // Some URL handlers do not implement AppleScript mounting; defer to the system.
      NSWorkspace.shared.open(url)
      if let message = errorInfo?[NSAppleScript.errorMessage] as? String,
        !message.localizedCaseInsensitiveContains("already mounted")
      {
        states[profile.id] = .failed(message)
      } else {
        states[profile.id] = .connected(nil)
      }
    }
  }

  private func connectSFTP(_ profile: ServerProfile) async {
    guard let sshfs = findSSHFS() else {
      states[profile.id] = .helperRequired("SFTP 自動マウントには macFUSE と sshfs が必要です。SSH 鍵認証を推奨します。")
      if let url = profile.connectionURL { NSWorkspace.shared.open(url) }
      return
    }

    let mountPath: String
    if profile.localMountPath.isEmpty {
      mountPath =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("nafi Mounts", isDirectory: true)
        .appendingPathComponent(profile.name, isDirectory: true).path
    } else {
      mountPath = NSString(string: profile.localMountPath).expandingTildeInPath
    }

    do {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: mountPath),
        withIntermediateDirectories: true
      )

      let remoteUser =
        profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
      let remotePath =
        profile.path.isEmpty
        ? "/" : "/\(profile.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: sshfs)
      process.arguments = [
        "\(remoteUser):\(remotePath)", mountPath,
        "-p", String(profile.port),
        "-o", "reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,volname=\(profile.name)",
      ]
      let errorPipe = Pipe()
      process.standardError = errorPipe
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        states[profile.id] = .connected(URL(fileURLWithPath: mountPath))
        refreshMountedVolumes()
      } else {
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8) ?? "sshfs の接続に失敗しました"
        states[profile.id] = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func findSSHFS() -> String? {
    ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs", "/usr/bin/sshfs"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func loadProfiles() {
    guard let data = try? Data(contentsOf: persistenceURL),
      let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data)
    else { return }
    profiles = decoded
  }

  private func persistProfiles() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(profiles).write(to: persistenceURL, options: .atomic)
  }

  private func appleScriptQuoted(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
