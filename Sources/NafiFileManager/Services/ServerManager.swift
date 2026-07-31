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
  @Published var errorMessage: String?
  @Published private(set) var hostKeyApprovalRequest: SSHHostKeyApprovalRequest?

  private let keychain = KeychainStore()
  private let persistenceURL: URL
  private var remoteSessions: [UUID: any RemoteServerSession] = [:]
  private var passwordCache: [UUID: String] = [:]
  private var keyPassphraseCache: [UUID: String] = [:]
  private var sessionTokenCache: [UUID: String] = [:]
  private var connectionTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

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

  func dismissHostKeyApproval() {
    hostKeyApprovalRequest = nil
  }

  func approveHostKey(_ request: SSHHostKeyApprovalRequest) async {
    guard hostKeyApprovalRequest == nil || hostKeyApprovalRequest?.id == request.id else { return }
    hostKeyApprovalRequest = nil
    do {
      try await SSHHostKeyService.shared.trust(request.scan)
    } catch {
      states[request.profileID] = .failed(error.localizedDescription)
      errorMessage = error.localizedDescription
      return
    }
    guard let profile = profiles.first(where: { $0.id == request.profileID }) else {
      errorMessage = "接続プロファイルが削除されています。"
      return
    }
    await connect(profile)
  }

  func destinationURL(for profile: ServerProfile) -> URL? {
    guard case .connected(let mountedURL) = state(for: profile) else { return nil }
    switch profile.kind {
    case .sftp, .ftp, .s3, .smb, .webdav, .rclone:
      return NafiURL.remoteRoot(for: profile)
    case .nfs, .afp:
      return mountedURL
    }
  }

  func save(
    profile: ServerProfile,
    password: String,
    keyPassphrase: String,
    sessionToken: String = ""
  ) throws {
    var profile = profile
    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.localMountPath = profile.localMountPath.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.privateKeyPath = profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.s3Bucket = profile.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.s3Region = profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
    try validate(profile)
    if profile.kind == .rclone {
      let secretText = password.trimmingCharacters(in: .whitespacesAndNewlines)
      if !secretText.isEmpty { try RcloneConfiguration.validateParametersJSON(secretText) }
    }
    let oldProfile = profiles.first(where: { $0.id == profile.id })
    let oldSecrets = try secretSnapshot(for: oldProfile ?? profile)
    let suppliedSecrets = SecretSnapshot(
      password: password,
      keyPassphrase: keyPassphrase,
      sessionToken: sessionToken
    )
    if let oldProfile {
      if connectionConfigurationChanged(from: oldProfile, to: profile)
        || oldSecrets != suppliedSecrets
      {
        profile.configurationRevision = UUID()
      } else {
        profile.configurationRevision = oldProfile.configurationRevision
      }
    }
    var updatedProfiles = profiles
    if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
      updatedProfiles[index] = profile
    } else {
      updatedProfiles.append(profile)
    }
    updatedProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    do {
      try keychain.save(password: password, for: profile)
      try keychain.saveKeyPassphrase(keyPassphrase, for: profile)
      try keychain.saveSessionToken(sessionToken, for: profile)
      try persistProfiles(updatedProfiles)
    } catch {
      let rollbackFailures = restoreSecrets(oldSecrets, for: oldProfile ?? profile)
      if rollbackFailures.isEmpty { throw error }
      throw RemoteServerError.invalidResponse(
        "接続設定を保存できず、Keychainの復元にも失敗しました。\n\(error.localizedDescription)\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }

    profiles = updatedProfiles
    passwordCache[profile.id] = password
    keyPassphraseCache[profile.id] = keyPassphrase
    sessionTokenCache[profile.id] = sessionToken

    let mustReconnect = oldProfile.map {
      connectionConfigurationChanged(from: $0, to: profile) || oldSecrets != suppliedSecrets
    } ?? false
    let oldSession = mustReconnect ? remoteSessions.removeValue(forKey: profile.id) : nil
    if mustReconnect {
      connectionTasks.removeValue(forKey: profile.id)?.task.cancel()
      states[profile.id] = .idle
    }
    Task {
      if let oldSession { await oldSession.close() }
      if mustReconnect {
        await RemoteFileSystemRegistry.shared.disconnect(profileID: profile.id)
        await RcloneRuntime.shared.removeConfiguration(profileID: profile.id)
      }
      await RemoteFileSystemRegistry.shared.update(profile: profile)
    }
  }

  func remove(_ profile: ServerProfile) throws {
    guard profiles.contains(where: { $0.id == profile.id }) else { return }
    let oldProfiles = profiles
    let updatedProfiles = profiles.filter { $0.id != profile.id }
    let oldSecrets = try secretSnapshot(for: profile)

    do {
      try keychain.deleteSecrets(for: profile)
      try persistProfiles(updatedProfiles)
    } catch {
      let rollbackFailures = restoreSecrets(oldSecrets, for: profile)
      if rollbackFailures.isEmpty {
        try? persistProfiles(oldProfiles)
        throw error
      }
      throw RemoteServerError.invalidResponse(
        "接続設定を削除できず、Keychainの復元にも失敗しました。\n\(error.localizedDescription)\n\(rollbackFailures.joined(separator: "\n"))"
      )
    }

    connectionTasks.removeValue(forKey: profile.id)?.task.cancel()
    let session = remoteSessions.removeValue(forKey: profile.id)
    profiles = updatedProfiles
    states[profile.id] = nil
    passwordCache[profile.id] = nil
    keyPassphraseCache[profile.id] = nil
    sessionTokenCache[profile.id] = nil
    Task {
      if let session { await session.close() }
      await RemoteFileSystemRegistry.shared.unregister(profileID: profile.id)
      await RcloneRuntime.shared.removeConfiguration(profileID: profile.id)
    }
  }

  private struct SecretSnapshot: Equatable {
    let password: String
    let keyPassphrase: String
    let sessionToken: String
  }

  private func secretSnapshot(for profile: ServerProfile) throws -> SecretSnapshot {
    SecretSnapshot(
      password: try keychain.password(for: profile) ?? "",
      keyPassphrase: try keychain.keyPassphrase(for: profile) ?? "",
      sessionToken: try keychain.sessionToken(for: profile) ?? ""
    )
  }

  private func restoreSecrets(_ snapshot: SecretSnapshot, for profile: ServerProfile) -> [String] {
    var failures: [String] = []
    do { try keychain.save(password: snapshot.password, for: profile) } catch {
      failures.append(error.localizedDescription)
    }
    do { try keychain.saveKeyPassphrase(snapshot.keyPassphrase, for: profile) } catch {
      failures.append(error.localizedDescription)
    }
    do { try keychain.saveSessionToken(snapshot.sessionToken, for: profile) } catch {
      failures.append(error.localizedDescription)
    }
    return failures
  }

  private func validate(_ profile: ServerProfile) throws {
    try validate(profile, checkExternalResources: true)
  }

  private func validate(
    _ profile: ServerProfile,
    checkExternalResources: Bool
  ) throws {
    let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 256,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw RemoteServerError.invalidResponse("接続名が空、長すぎる、または制御文字を含んでいます。")
    }
    if profile.kind != .rclone && profile.kind != .nfs && profile.kind != .afp,
      !(1...65535).contains(profile.port)
    {
      throw RemoteServerError.invalidResponse("ポート番号が不正です。")
    }

    let boundedValues: [(String, Int, String)] = [
      (profile.host, 2_048, "ホスト名"),
      (profile.path, 4_096, "開始パス"),
      (profile.username, 1_024, "ユーザー名"),
      (profile.localMountPath, 4_096, "ローカルマウント先"),
      (profile.privateKeyPath, 4_096, "秘密鍵パス"),
      (profile.s3Bucket, 255, "S3バケット名"),
      (profile.s3Region, 128, "S3リージョン"),
      (profile.rcloneBackend, 128, "rcloneバックエンド"),
      (profile.rcloneParametersJSON, 1_048_576, "rcloneパラメータ"),
    ]
    for (value, maximumBytes, label) in boundedValues {
      guard value.utf8.count <= maximumBytes,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        throw RemoteServerError.invalidResponse("\(label)が長すぎるか、制御文字を含んでいます。")
      }
    }

    switch profile.kind {
    case .sftp:
      do {
        _ = try SSHHostKeyService.validatedHost(profile.host)
        _ = try SSHHostKeyService.validatedUsername(profile.username)
        try SSHHostKeyService.validatePort(profile.port)
      } catch {
        throw RemoteServerError.invalidResponse(error.localizedDescription)
      }
      let keyPath = profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
      if profile.sftpAuthentication == .privateKey || !keyPath.isEmpty {
        guard !keyPath.isEmpty, !keyPath.hasSuffix(".pub") else {
          throw RemoteServerError.invalidResponse("SFTP秘密鍵（.pubではないファイル）を指定してください。")
        }
        if checkExternalResources {
          let expanded = NSString(string: keyPath).expandingTildeInPath
          var isDirectory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: expanded)
          else {
            throw RemoteServerError.invalidResponse("SFTP秘密鍵を読み取れません。")
          }
        }
      }

    case .s3:
      let rawEndpoint = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
      let endpointText =
        rawEndpoint.contains("://")
        ? rawEndpoint
        : "\(profile.useTLS ? "https" : "http")://\(rawEndpoint)"
      guard let components = URLComponents(string: endpointText),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil
      else {
        throw RemoteServerError.invalidResponse("S3互換エンドポイントが不正です。HTTP(S)のホスト名またはURLを入力してください。")
      }
      let bucket = profile.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !bucket.isEmpty, !bucket.contains("/"), !bucket.contains("\\") else {
        throw RemoteServerError.invalidResponse("S3バケット名が不正です。")
      }
      let region = profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !region.isEmpty, !region.contains(where: \.isWhitespace) else {
        throw RemoteServerError.invalidResponse("S3リージョンが不正です。")
      }
      if !profile.s3Anonymous {
        guard !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw RemoteServerError.invalidResponse("S3アクセスキーIDがありません。")
        }
      }

    case .rclone:
      let backend = profile.rcloneBackend.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !backend.isEmpty,
        backend.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil
      else { throw RemoteServerError.invalidResponse("rcloneバックエンド名が不正です。例: drive, onedrive, b2") }
      try RcloneConfiguration.validateParametersJSON(profile.rcloneParametersJSON)

    case .nfs, .afp:
      let mountText = profile.localMountPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !mountText.isEmpty else {
        throw RemoteServerError.invalidResponse("macOSでマウント済みのローカルパスを指定してください。")
      }
      let expanded = NSString(string: mountText).expandingTildeInPath
      let mountURL = URL(fileURLWithPath: expanded).standardizedFileURL
      guard mountURL.path.hasPrefix("/"), mountURL.path.utf8.count <= 4_096 else {
        throw RemoteServerError.invalidResponse("ローカルマウント先が不正です。")
      }
      if checkExternalResources {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          FileManager.default.isReadableFile(atPath: mountURL.path)
        else {
          throw RemoteServerError.invalidResponse("マウント先を読み取れません: \(mountURL.path)")
        }
      }

    case .ftp, .smb, .webdav:
      let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
      let invalidHostCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "/\\@"))
      guard !host.isEmpty, !host.hasPrefix("-"), !host.contains("://"),
        host.rangeOfCharacter(from: invalidHostCharacters) == nil
      else {
        throw RemoteServerError.invalidResponse("ホスト欄にはURLではなくホスト名だけを入力してください。")
      }
      guard profile.connectionURL != nil else {
        throw RemoteServerError.invalidResponse("接続URLを作成できません。")
      }
    }
  }

  private func connectionConfigurationChanged(
    from oldProfile: ServerProfile,
    to newProfile: ServerProfile
  ) -> Bool {
    oldProfile.rcloneConfigurationSignature != newProfile.rcloneConfigurationSignature
  }

  func password(for profile: ServerProfile) -> String {
    if let cached = passwordCache[profile.id] { return cached }
    let value = (try? keychain.password(for: profile)) ?? ""
    passwordCache[profile.id] = value
    return value
  }

  func keyPassphrase(for profile: ServerProfile) -> String {
    if let cached = keyPassphraseCache[profile.id] { return cached }
    let value = (try? keychain.keyPassphrase(for: profile)) ?? ""
    keyPassphraseCache[profile.id] = value
    return value
  }

  func sessionToken(for profile: ServerProfile) -> String {
    if let cached = sessionTokenCache[profile.id] { return cached }
    let value = (try? keychain.sessionToken(for: profile)) ?? ""
    sessionTokenCache[profile.id] = value
    return value
  }

  func persistOAuthToken(_ token: String, for profileID: UUID) async throws {
    guard let profile = profiles.first(where: { $0.id == profileID }), profile.kind == .rclone else {
      throw RemoteServerError.invalidResponse("OAuth接続プロファイルが見つかりません。")
    }
    let current = password(for: profile)
    let updated = try RcloneConfiguration.replacingOAuthToken(token, in: current)
    guard updated != current else { return }
    try keychain.save(password: updated, for: profile)
    passwordCache[profileID] = updated
    if let session = remoteSessions[profileID] as? RcloneRemoteSession {
      try await session.updateOAuthToken(token)
    }
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
        case .failed(let message) where RcloneRemoteSession.isHostKeyRelatedErrorMessage(message):
          // Host-key failures require explicit fingerprint confirmation in the
          // editor. Retrying cannot make an untrusted key trusted.
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

  func configureFileProviderProfiles(_ enabledIDs: Set<UUID>) async {
    for profile in profiles where enabledIDs.contains(profile.id) {
      guard states[profile.id] != .connected(nil) else { continue }
      do {
        let secrets = RcloneProfileSecrets(
          password: password(for: profile),
          keyPassphrase: keyPassphrase(for: profile),
          sessionToken: sessionToken(for: profile)
        )
        let sftpHostKeyAlgorithms: [String]
        if profile.kind == .sftp {
          sftpHostKeyAlgorithms = (try? await SSHHostKeyService.shared.prepareKnownHosts(
            host: profile.host, port: profile.port
          )) ?? []
        } else {
          sftpHostKeyAlgorithms = []
        }
        _ = try await RcloneRuntime.shared.configure(
          profile: profile,
          secrets: secrets,
          sftpHostKeyAlgorithms: sftpHostKeyAlgorithms
        )
      } catch {
        states[profile.id] = .failed(error.localizedDescription)
      }
    }
  }

  func connect(_ profile: ServerProfile) async {
    if let existing = connectionTasks[profile.id] {
      await existing.task.value
      return
    }

    let token = UUID()
    let task: Task<Void, Never> = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performConnect(profile)
    }
    connectionTasks[profile.id] = (token, task)
    await task.value
    if connectionTasks[profile.id]?.token == token {
      connectionTasks[profile.id] = nil
    }
  }

  private func performConnect(_ profile: ServerProfile) async {
    guard profiles.contains(where: { $0.id == profile.id }) else {
      states[profile.id] = .failed("接続プロファイルが削除されています。")
      return
    }
    if profile.kind != .rclone,
      profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      states[profile.id] = .failed("ホスト名がありません")
      return
    }
    guard profile.kind == .rclone || (1...65535).contains(profile.port) else {
      states[profile.id] = .failed("ポート番号が不正です。")
      return
    }

    if remoteSessions[profile.id] != nil {
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
      return
    }

    states[profile.id] = .connecting
    switch profile.kind {
    case .sftp, .ftp, .s3, .smb, .webdav, .rclone:
      await connectRclone(profile)
    case .nfs, .afp:
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
    connectionTasks.removeValue(forKey: profile.id)?.task.cancel()
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

    let errorMessage: String?
    do {
      let result = try await BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
        arguments: ["unmount", target.path],
        timeout: 120,
        maximumStandardOutputBytes: 256 * 1_024,
        maximumStandardErrorBytes: 256 * 1_024
      )
      if result.terminationStatus == 0 {
        errorMessage = nil
      } else {
        let message = String(data: result.stderr, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = message.flatMap { $0.isEmpty ? nil : $0 } ?? "アンマウントできませんでした"
      }
    } catch {
      errorMessage = error.localizedDescription
    }

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

  private func connectRclone(_ profile: ServerProfile) async {
    do {
      let secrets = RcloneProfileSecrets(
        password: password(for: profile),
        keyPassphrase: keyPassphrase(for: profile),
        sessionToken: sessionToken(for: profile)
      )
      let session = try await RcloneRemoteSession.connect(
        profile: profile,
        secrets: secrets
      )
      try Task.checkCancellation()
      guard profiles.contains(where: { $0.id == profile.id }) else {
        await session.close()
        return
      }
      remoteSessions[profile.id] = session
      await RemoteFileSystemRegistry.shared.register(profile: profile, session: session)
      states[profile.id] = .connected(NafiURL.remoteRoot(for: profile))
    } catch is CancellationError {
      states[profile.id] = .idle
    } catch RcloneRuntimeError.binaryMissing {
      states[profile.id] = .helperRequired(
        "rcloneが見つかりません。nafiに同梱するか、Homebrewでインストールしてください。"
      )
    } catch {
      if profile.kind == .sftp,
        RcloneRemoteSession.isHostKeyRelatedErrorMessage(error.localizedDescription)
      {
        do {
          try await presentHostKeyApproval(for: profile)
        } catch {
          states[profile.id] = .failed(error.localizedDescription)
          return
        }
      }
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func presentHostKeyApproval(for profile: ServerProfile) async throws {
    let existing = try await SSHHostKeyService.shared.trustedHostKeyIdentities(
      host: profile.host,
      port: profile.port
    )
    let scan = try await SSHHostKeyService.shared.scan(host: profile.host, port: profile.port)
    guard profiles.contains(where: { $0.id == profile.id }) else {
      throw RemoteServerError.invalidResponse("接続プロファイルが削除されています。")
    }
    if hostKeyApprovalRequest == nil || hostKeyApprovalRequest?.profileID == profile.id {
      hostKeyApprovalRequest = SSHHostKeyApprovalRequest(
        profileID: profile.id,
        profileName: profile.name,
        scan: scan,
        existingIdentities: existing
      )
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

    if Task.isCancelled || !profiles.contains(where: { $0.id == profile.id }) {
      if case .success(let mountedURLs) = result {
        await Task.detached(priority: .utility) {
          for mountedURL in mountedURLs {
            await Self.unmountAfterCancelledConnection(mountedURL)
          }
        }.value
      }
      states[profile.id] = .idle
      return
    }

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

  private nonisolated static func unmountAfterCancelledConnection(_ url: URL) async {
    _ = try? await BoundedProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
      arguments: ["unmount", url.path],
      timeout: 120,
      maximumStandardOutputBytes: 64 * 1_024,
      maximumStandardErrorBytes: 64 * 1_024
    )
  }

  private func findMountedURL(for profile: ServerProfile) -> URL? {
    let share = profile.path.split(separator: "/").first.map(String.init)
    return mountedVolumes.first { volume in
      if let share, volume.name.localizedCaseInsensitiveContains(share) { return true }
      return volume.name.localizedCaseInsensitiveContains(profile.host)
    }?.url
  }

  private func loadProfiles() {
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
      recoverQuarantinedProfilesIfPossible()
      return
    }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: persistenceURL,
        maximumBytes: 8 * 1_024 * 1_024
      )
      let decoded = try JSONDecoder().decode([ServerProfile].self, from: data)
      guard decoded.count <= 10_000 else { throw CocoaError(.fileReadCorruptFile) }
      var seen = Set<UUID>()
      var valid: [ServerProfile] = []
      var discarded = false
      for var profile in decoded {
        profile.transferPolicy.clamp()
        guard seen.insert(profile.id).inserted else {
          discarded = true
          continue
        }
        do {
          try validate(profile, checkExternalResources: false)
          valid.append(profile)
        } catch {
          discarded = true
        }
      }
      valid.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      profiles = valid
      if discarded {
        try persistProfiles(valid)
        errorMessage = "不正または重複した接続設定を除外しました。"
      }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: persistenceURL)
      profiles = []
      errorMessage = "接続設定が破損していたため隔離しました。\n\(error.localizedDescription)"
    }
  }

  private func recoverQuarantinedProfilesIfPossible() {
    let directory = persistenceURL.deletingLastPathComponent()
    guard let candidates = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let backups = candidates.filter {
      $0.lastPathComponent.hasPrefix("servers.corrupt-") && $0.pathExtension == "json"
    }.sorted {
      let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return lhs > rhs
    }

    for backup in backups.prefix(10) {
      guard let data = try? AppStoragePaths.readRegularFile(
        at: backup,
        maximumBytes: 8 * 1_024 * 1_024
      ), var decoded = try? JSONDecoder().decode([ServerProfile].self, from: data),
        decoded.count <= 10_000
      else { continue }
      var seen = Set<UUID>()
      let valid = decoded.indices.allSatisfy { index in
        decoded[index].transferPolicy.clamp()
        return seen.insert(decoded[index].id).inserted
          && (try? validate(decoded[index], checkExternalResources: false)) != nil
      }
      guard valid, (try? persistProfiles(decoded)) != nil else { continue }
      decoded.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      profiles = decoded
      errorMessage = "接続設定を復元しました。"
      return
    }
  }

  private func persistProfiles(_ values: [ServerProfile]) throws {
    guard values.count <= 10_000 else { throw CocoaError(.fileWriteOutOfSpace) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(values)
    guard data.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
    try data.write(
      to: persistenceURL,
      options: [.atomic, .completeFileProtectionUnlessOpen]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
  }
}
