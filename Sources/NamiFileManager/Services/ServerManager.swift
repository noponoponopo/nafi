import AppKit
import Combine
import Foundation
import NetFS
import Security

private enum NetworkMountResult: Sendable {
  case success([URL])
  case failure(String)
}

@MainActor
final class ServerManager: ObservableObject {
  @Published private(set) var profiles: [ServerProfile] = []
  @Published private(set) var states: [UUID: ServerConnectionState] = [:]
  @Published private(set) var mountedVolumes: [MountedVolume] = []

  private let keychain = KeychainStore()
  private let persistenceURL: URL
  private var remoteSessions: [UUID: any RemoteServerSession] = [:]

  init() {
    persistenceURL = AppStoragePaths.file(named: "servers.json")
    loadProfiles()
    Task { [weak self] in
      guard let self else { return }
      await RemoteFileSystemRegistry.shared.registerProfiles(self.profiles)
      await RemoteFileSystemRegistry.shared.configureConnector { [weak self] profileID in
        guard let self else { throw RemoteServerError.notConnected }
        try await self.connectProfileForFileSystem(profileID)
      }
    }

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

  func destinationURL(for profile: ServerProfile) -> URL? {
    guard case .connected(let mountedURL) = state(for: profile) else { return nil }
    switch profile.kind {
    case .sftp, .ftp, .s3:
      return NafiURL.remoteRoot(for: profile)
    case .smb, .webdav, .nfs, .afp:
      return mountedURL
    }
  }

  func save(
    profile: ServerProfile,
    password: String,
    keyPassphrase: String,
    sessionToken: String = ""
  ) throws {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try keychain.save(password: password, for: profile)
    try keychain.saveKeyPassphrase(keyPassphrase, for: profile)
    try keychain.saveSessionToken(sessionToken, for: profile)
    try persistProfiles()
    Task { await RemoteFileSystemRegistry.shared.update(profile: profile) }
  }

  func remove(_ profile: ServerProfile) {
    if let session = remoteSessions.removeValue(forKey: profile.id) {
      Task { await session.close() }
    }
    profiles.removeAll { $0.id == profile.id }
    states[profile.id] = nil
    try? keychain.deleteSecrets(for: profile)
    try? persistProfiles()
    Task { await RemoteFileSystemRegistry.shared.unregister(profileID: profile.id) }
  }

  func password(for profile: ServerProfile) -> String {
    (try? keychain.password(for: profile)) ?? ""
  }

  func keyPassphrase(for profile: ServerProfile) -> String {
    (try? keychain.keyPassphrase(for: profile)) ?? ""
  }

  func sessionToken(for profile: ServerProfile) -> String {
    (try? keychain.sessionToken(for: profile)) ?? ""
  }

  private func connectProfileForFileSystem(_ profileID: UUID) async throws {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      throw RemoteServerError.invalidResponse("接続プロファイルが見つかりません。")
    }
    await connect(profile)
    switch state(for: profile) {
    case .connected:
      return
    case .failed(let message), .helperRequired(let message):
      throw RemoteServerError.invalidResponse(message)
    case .idle, .connecting:
      throw RemoteServerError.notConnected
    }
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

    if remoteSessions[profile.id] != nil {
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
      return
    }
    if case .connecting = state(for: profile) {
      for _ in 0..<120 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if case .connecting = state(for: profile) { continue }
        return
      }
      states[profile.id] = .failed("接続がタイムアウトしました。")
      return
    }

    states[profile.id] = .connecting
    switch profile.kind {
    case .sftp:
      await connectSFTP(profile)
    case .ftp:
      await connectFTP(profile)
    case .s3:
      await connectS3(profile)
    case .smb, .webdav, .nfs, .afp:
      await connectUsingNetFS(profile)
    }
  }

  func activate(_ profile: ServerProfile) async -> URL? {
    switch state(for: profile) {
    case .connected(let url):
      if remoteSessions[profile.id] != nil { return NafiURL.remoteRoot(for: profile) }
      return url
    case .connecting:
      return nil
    case .idle, .helperRequired, .failed:
      await connect(profile)
      if case .connected(let url) = state(for: profile) {
        return remoteSessions[profile.id] != nil ? NafiURL.remoteRoot(for: profile) : url
      }
      return nil
    }
  }

  func disconnect(_ profile: ServerProfile) async {
    if let session = remoteSessions.removeValue(forKey: profile.id) {
      await session.close()
      await RemoteFileSystemRegistry.shared.disconnect(profileID: profile.id)
      states[profile.id] = .idle
      return
    }

    let target: URL? = {
      if case .connected(let url) = state(for: profile), let url { return url }
      if !profile.localMountPath.isEmpty {
        return URL(fileURLWithPath: NSString(string: profile.localMountPath).expandingTildeInPath)
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

    let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
      process.arguments = ["unmount", target.path]
      let pipe = Pipe()
      process.standardError = pipe
      do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "アンマウントできませんでした"
      } catch {
        return error.localizedDescription
      }
    }.value

    if let errorMessage {
      states[profile.id] = .failed(errorMessage)
    } else {
      states[profile.id] = .idle
      refreshMountedVolumes()
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

  private func connectSFTP(_ profile: ServerProfile) async {
    do {
      let session: any RemoteServerSession
      switch profile.sftpAuthentication {
      case .password:
        session = try await SFTPRemoteSession.connect(
          profile: profile,
          password: password(for: profile),
          keyPassphrase: ""
        )
      case .privateKey:
        session = try await OpenSSHSFTPRemoteSession.connect(
          profile: profile,
          keyPassphrase: keyPassphrase(for: profile)
        )
      }
      remoteSessions[profile.id] = session
      await RemoteFileSystemRegistry.shared.register(profile: profile, session: session)
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func connectFTP(_ profile: ServerProfile) async {
    do {
      let session = try await FTPRemoteSession.connect(
        profile: profile,
        password: password(for: profile)
      )
      remoteSessions[profile.id] = session
      await RemoteFileSystemRegistry.shared.register(profile: profile, session: session)
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func connectS3(_ profile: ServerProfile) async {
    do {
      let session = try await S3RemoteSession.connect(
        profile: profile,
        secretAccessKey: password(for: profile),
        sessionToken: sessionToken(for: profile)
      )
      remoteSessions[profile.id] = session
      await RemoteFileSystemRegistry.shared.register(profile: profile, session: session)
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func connectUsingNetFS(_ profile: ServerProfile) async {
    guard let url = profile.connectionURL else {
      states[profile.id] = .failed("接続URLを作成できません")
      return
    }

    let username = profile.username
    let password = password(for: profile)
    let mountPath: URL? = {
      guard !profile.localMountPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return URL(
        fileURLWithPath: NSString(string: profile.localMountPath).expandingTildeInPath,
        isDirectory: true
      )
    }()

    let result = await Task.detached(priority: .userInitiated) {
      Self.mountUsingNetFS(
        url: url,
        mountPath: mountPath,
        username: username,
        password: password
      )
    }.value

    switch result {
    case .success(let mountedURLs):
      refreshMountedVolumes()
      let destination = mountedURLs.first ?? findMountedURL(for: profile)
      states[profile.id] = .connected(destination)
    case .failure(let message):
      states[profile.id] = .failed(message)
    }
  }

  private nonisolated static func mountUsingNetFS(
    url: URL,
    mountPath: URL?,
    username: String,
    password: String
  ) -> NetworkMountResult {
    if let mountPath {
      do {
        try FileManager.default.createDirectory(at: mountPath, withIntermediateDirectories: true)
      } catch {
        return .failure(error.localizedDescription)
      }
    }

    let mountURL: CFURL? = mountPath.map { $0 as CFURL }
    let user: CFString? = username.isEmpty ? nil : username as CFString
    let secret: CFString? = password.isEmpty ? nil : password as CFString
    var mounted: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(
      url as CFURL,
      mountURL,
      user,
      secret,
      nil,
      nil,
      &mounted
    )
    guard status == 0 else {
      let systemMessage = SecCopyErrorMessageString(status, nil) as String?
      let prefix = url.scheme?.uppercased() ?? "サーバー"
      return .failure(systemMessage ?? "\(prefix)接続に失敗しました（\(status)）")
    }

    guard let array = mounted?.takeRetainedValue() else {
      return .success(mountPath.map { [$0] } ?? [])
    }
    let urls = (array as NSArray).compactMap { value -> URL? in
      if let url = value as? URL { return url }
      if let string = value as? String { return URL(fileURLWithPath: string) }
      return nil
    }
    return .success(urls)
  }

  private func findMountedURL(for profile: ServerProfile) -> URL? {
    let share = profile.path.split(separator: "/").first.map(String.init)
    return mountedVolumes.first { volume in
      if let share, volume.name.localizedCaseInsensitiveContains(share) { return true }
      return volume.name.localizedCaseInsensitiveContains(profile.host)
    }?.url
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
}
