import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RcloneProfileSecrets: Sendable {
  let password: String
  let keyPassphrase: String
  let sessionToken: String

  var inMemorySignature: Int {
    var hasher = Hasher()
    hasher.combine(password)
    hasher.combine(keyPassphrase)
    hasher.combine(sessionToken)
    return hasher.finalize()
  }

  func replacingOAuthToken(_ token: String) throws -> RcloneProfileSecrets {
    RcloneProfileSecrets(
      password: try RcloneConfiguration.replacingOAuthToken(token, in: password),
      keyPassphrase: keyPassphrase,
      sessionToken: sessionToken
    )
  }
}

private final class RcloneLogBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let maximumBytes = 64 * 1_024

  func append(_ incoming: Data) {
    guard !incoming.isEmpty else { return }
    lock.lock()
    data.append(incoming)
    if data.count > maximumBytes { data.removeFirst(data.count - maximumBytes) }
    lock.unlock()
  }

  func text() -> String {
    lock.lock()
    let snapshot = data
    lock.unlock()
    return String(data: snapshot, encoding: .utf8) ?? ""
  }
}

private final class RcloneURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum RcloneRuntimeError: LocalizedError, Sendable {
  case binaryMissing
  case launchFailed(String)
  case unavailable(String)
  case invalidResponse(String)
  case remoteConfiguration(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .binaryMissing:
      "rcloneが見つかりません。アプリ内のContents/Helpers/rclone、NAFI_RCLONE_PATH、Homebrewの順で検索しました。"
    case .launchFailed(let message): "rcloneを起動できません。\n\(message)"
    case .unavailable(let message): "rcloneへ接続できません。\n\(message)"
    case .invalidResponse(let message): "rcloneから不正な応答を受け取りました。\n\(message)"
    case .remoteConfiguration(let message): "rclone接続設定を作成できません。\n\(message)"
    case .timedOut: "rcloneの応答がタイムアウトしました。"
    }
  }
}

actor RcloneRuntime {
  static let shared = RcloneRuntime()

  typealias OAuthTokenUpdateHandler = @Sendable (UUID, String) async throws -> Void

  private struct State {
    let process: Process
    let baseURL: URL
    let username: String
    let password: String
    let configURL: URL
    let cacheURL: URL
    let generation: UUID
    let outputPipe: Pipe
    let errorPipe: Pipe
    let logBuffer: RcloneLogBuffer
  }

  private var state: State?
  private var startTask: Task<State, Error>?
  private var descriptorHeartbeat: Task<Void, Never>?
  private var oauthTokenMonitorTask: Task<Void, Never>?
  private var configuredProfiles: [UUID: Int] = [:]
  private var oauthProfileIDs = Set<UUID>()
  private var persistedOAuthTokens: [UUID: String] = [:]
  private var oauthTokenUpdateHandler: OAuthTokenUpdateHandler?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 120
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    session = URLSession(
      configuration: configuration,
      delegate: RcloneURLSessionDelegate(),
      delegateQueue: nil
    )
  }

  func isAvailable() -> Bool { Self.resolveBinaryURL() != nil }

  func binaryURL() -> URL? { Self.resolveBinaryURL() }

  func version() async throws -> String {
    let response = try await call("core/version")
    return response["version"]?.stringValue ?? "unknown"
  }

  func providerCatalog() async throws -> RcloneProviderCatalog {
    try await callDecodable("config/providers", timeout: 45)
  }

  func beginProviderConfiguration(
    profileID: UUID,
    backend: String,
    parameters: [String: JSONValue]
  ) async throws -> RcloneConfigResponse {
    try await prepareOAuthPort()
    configuredProfiles[profileID] = nil
    return try await providerConfigurationCall(
      profileID: profileID,
      backend: backend,
      parameters: parameters,
      continuation: nil
    )
  }

  private func prepareOAuthPort() async throws {
    guard !Self.canBindOAuthPort() else { return }
    await stop()
    try await start()
    guard Self.canBindOAuthPort() else {
      throw RcloneRuntimeError.remoteConfiguration(
        "認証用ポート53682が別のアプリで使用されています。使用中のアプリを終了してからもう一度お試しください。"
      )
    }
  }

  func continueProviderConfiguration(
    profileID: UUID,
    backend: String,
    parameters: [String: JSONValue],
    state: String,
    result: String
  ) async throws -> RcloneConfigResponse {
    try await providerConfigurationCall(
      profileID: profileID,
      backend: backend,
      parameters: parameters,
      continuation: (state, result)
    )
  }

  func providerConfiguration(profileID: UUID) async throws -> [String: JSONValue] {
    try await call(
      "config/get",
      parameters: ["name": .string(RcloneConfiguration.remoteName(for: profileID))]
    )
  }

  func setOAuthTokenUpdateHandler(_ handler: @escaping OAuthTokenUpdateHandler) {
    oauthTokenUpdateHandler = handler
    startOAuthTokenMonitor()
  }

  func start() async throws {
    _ = try await requireState()
  }

  func stop() async {
    try? await persistUpdatedOAuthTokens()
    startTask?.cancel()
    startTask = nil
    descriptorHeartbeat?.cancel()
    descriptorHeartbeat = nil
    oauthTokenMonitorTask?.cancel()
    oauthTokenMonitorTask = nil
    configuredProfiles.removeAll()
    oauthProfileIDs.removeAll()
    persistedOAuthTokens.removeAll()
    guard let current = state else { return }
    state = nil
    _ = try? await callRaw("core/quit", parameters: [:], state: current, timeout: 3)
    await Self.terminate(current.process, graceNanoseconds: 500_000_000)
    current.outputPipe.fileHandleForReading.readabilityHandler = nil
    current.errorPipe.fileHandleForReading.readabilityHandler = nil
    try? FileManager.default.removeItem(at: current.configURL.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: AppStoragePaths.sharedFile(named: "rclone-runtime.json"))
  }

  func restart() async throws {
    await stop()
    try await start()
  }

  func configure(
    profile: ServerProfile,
    secrets: RcloneProfileSecrets,
    sftpHostKeyAlgorithms: [String] = []
  ) async throws -> String? {
    var signatureHasher = Hasher()
    signatureHasher.combine(profile.rcloneConfigurationSignature)
    signatureHasher.combine(secrets.inMemorySignature)
    signatureHasher.combine(sftpHostKeyAlgorithms)
    let signature = signatureHasher.finalize()
    if configuredProfiles[profile.id] == signature { return persistedOAuthTokens[profile.id] }

    if profile.kind == .nfs || profile.kind == .afp {
      let path = RcloneConfiguration.fs(for: profile)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw RcloneRuntimeError.remoteConfiguration("NFS/AFPのマウント先が見つかりません: \(path)")
      }
      _ = try await call("operations/fsinfo", parameters: ["fs": .string(path)], timeout: 45)
      configuredProfiles[profile.id] = signature
      return nil
    }

    var configuredProfile = profile
    var configuredSecrets = secrets
    if profile.kind == .sftp,
      profile.sftpAuthentication == .privateKey,
      !secrets.keyPassphrase.isEmpty
    {
      let current = try await requireState()
      configuredProfile.privateKeyPath = try await preparePrivateKey(
        profile.privateKeyPath,
        passphrase: secrets.keyPassphrase,
        runtimeRoot: current.configURL.deletingLastPathComponent()
      )
      configuredSecrets = RcloneProfileSecrets(
        password: secrets.password,
        keyPassphrase: "",
        sessionToken: secrets.sessionToken
      )
    }
    let parameters = try RcloneConfiguration.parameters(
      for: configuredProfile,
      secrets: configuredSecrets,
      sftpHostKeyAlgorithms: sftpHostKeyAlgorithms
    )
    if profile.kind == .rclone, let token = parameters["token"]?.stringValue, !token.isEmpty {
      oauthProfileIDs.insert(profile.id)
      persistedOAuthTokens[profile.id] = token
      startOAuthTokenMonitor()
    } else {
      oauthProfileIDs.remove(profile.id)
      persistedOAuthTokens[profile.id] = nil
    }
    let remoteName = RcloneConfiguration.remoteName(for: profile.id)
    let payload: [String: JSONValue] = [
      "name": .string(remoteName),
      "type": .string(RcloneConfiguration.backendType(for: profile)),
      "parameters": .object(parameters),
      "opt": .object([
        "obscure": .bool(true),
        "nonInteractive": .bool(true),
        "noOutput": .bool(true),
      ]),
    ]

    do {
      let listed = try await call("config/listremotes", timeout: 30)
      let exists = listed["remotes"]?.arrayValue?.contains(where: {
        $0.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == remoteName
      }) == true
      _ = try await call(exists ? "config/update" : "config/create", parameters: payload, timeout: 90)
    } catch {
      throw RcloneRuntimeError.remoteConfiguration(error.localizedDescription)
    }

    _ = try await call(
      "operations/fsinfo",
      parameters: ["fs": .string(RcloneConfiguration.fs(for: profile))],
      timeout: 45
    )
    configuredProfiles[profile.id] = signature
    try await persistUpdatedOAuthTokens()
    return persistedOAuthTokens[profile.id]
  }

  func invalidateConfiguration(profileID: UUID) {
    configuredProfiles[profileID] = nil
  }

  private func preparePrivateKey(
    _ rawPath: String,
    passphrase: String,
    runtimeRoot: URL
  ) async throws -> String {
    let expandedPath = NSString(string: rawPath).expandingTildeInPath
    let sourceURL = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey]
      )
    } catch {
      throw RcloneRuntimeError.remoteConfiguration("SFTP秘密鍵を読み取れません。\n\(error.localizedDescription)")
    }
    guard values.isRegularFile == true,
      let size = values.fileSize,
      size >= 0,
      size <= 4 * 1_024 * 1_024
    else {
      throw RcloneRuntimeError.remoteConfiguration("SFTP秘密鍵を読み取れません。")
    }

    let keyDirectory = runtimeRoot.appendingPathComponent("keys", isDirectory: true)
    try FileManager.default.createDirectory(
      at: keyDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let temporaryURL = keyDirectory.appendingPathComponent(
      "private-key-\(UUID().uuidString)",
      isDirectory: false
    )
    do {
      let keyData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
      guard keyData.count <= 4 * 1_024 * 1_024 else {
        throw RcloneRuntimeError.remoteConfiguration("SFTP秘密鍵が大きすぎます。")
      }
      try keyData.write(to: temporaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
      )
      let keygenURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
      guard FileManager.default.isExecutableFile(atPath: keygenURL.path) else {
        throw RcloneRuntimeError.remoteConfiguration("ssh-keygenが見つかりません。")
      }
      let result = try await BoundedProcessRunner.run(
        executableURL: keygenURL,
        arguments: ["-p", "-f", temporaryURL.path, "-P", passphrase, "-N", ""],
        timeout: 20,
        maximumStandardOutputBytes: 64 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
      )
      guard result.terminationStatus == 0 else {
        let message = String(data: result.stderr, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        throw RcloneRuntimeError.remoteConfiguration(
          message?.isEmpty == false ? message! : "SFTP秘密鍵のパスフレーズを確認してください。"
        )
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
      )
      return temporaryURL.path
    } catch let error as RcloneRuntimeError {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw RcloneRuntimeError.remoteConfiguration(error.localizedDescription)
    }
  }

  func removeConfiguration(profileID: UUID) async {
    configuredProfiles[profileID] = nil
    oauthProfileIDs.remove(profileID)
    persistedOAuthTokens[profileID] = nil
    _ = try? await call(
      "config/delete",
      parameters: ["name": .string(RcloneConfiguration.remoteName(for: profileID))]
    )
    _ = try? await call("fscache/clear")
  }

  private func startOAuthTokenMonitor() {
    guard oauthTokenMonitorTask == nil, oauthTokenUpdateHandler != nil else { return }
    oauthTokenMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        guard !Task.isCancelled, let self else { return }
        try? await self.persistUpdatedOAuthTokens()
      }
    }
  }

  private func persistUpdatedOAuthTokens() async throws {
    guard let current = state, current.process.isRunning,
      let handler = oauthTokenUpdateHandler
    else { return }
    for profileID in oauthProfileIDs where configuredProfiles[profileID] != nil {
      let configuration = try await callRaw(
        "config/get",
        parameters: [
          "name": .string(RcloneConfiguration.remoteName(for: profileID))
        ],
        state: current,
        timeout: 15
      )
      guard let token = configuration["token"]?.stringValue, !token.isEmpty,
        token != persistedOAuthTokens[profileID]
      else { continue }
      try await handler(profileID, token)
      persistedOAuthTokens[profileID] = token
    }
  }

  func call(
    _ method: String,
    parameters: [String: JSONValue] = [:],
    timeout: TimeInterval = 45
  ) async throws -> [String: JSONValue] {
    let current = try await requireState()
    return try await callRaw(method, parameters: parameters, state: current, timeout: timeout)
  }

  func callDecodable<T: Decodable & Sendable>(
    _ method: String,
    parameters: [String: JSONValue] = [:],
    timeout: TimeInterval = 45,
    as type: T.Type = T.self
  ) async throws -> T {
    let value = try await call(method, parameters: parameters, timeout: timeout)
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
  }

  private func requireState() async throws -> State {
    if let state, state.process.isRunning { return state }
    if let task = startTask { return try await task.value }

    let task = Task<State, Error> { try await Self.launchWithRetries() }
    startTask = task
    do {
      let newState = try await task.value
      state = newState
      startTask = nil
      configuredProfiles.removeAll()
      startOAuthTokenMonitor()
      try Self.publishDescriptor(for: newState)
      descriptorHeartbeat?.cancel()
      descriptorHeartbeat = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
          guard !Task.isCancelled else { return }
          await self?.refreshDescriptor()
        }
      }
      return newState
    } catch {
      startTask = nil
      throw error
    }
  }

  private func providerConfigurationCall(
    profileID: UUID,
    backend: String,
    parameters: [String: JSONValue],
    continuation: (state: String, result: String)?
  ) async throws -> RcloneConfigResponse {
    var options: [String: JSONValue] = [
      "obscure": .bool(true),
      "nonInteractive": .bool(true),
      "noOutput": .bool(true),
    ]
    if let continuation {
      options["continue"] = .bool(true)
      options["state"] = .string(continuation.state)
      options["result"] = .string(continuation.result)
    }
    return try await callDecodable(
      "config/create",
      parameters: [
        "name": .string(RcloneConfiguration.remoteName(for: profileID)),
        "type": .string(backend),
        "parameters": .object(parameters),
        "opt": .object(options),
      ],
      timeout: 15 * 60
    )
  }

  private func callRaw(
    _ method: String,
    parameters: [String: JSONValue],
    state: State,
    timeout: TimeInterval
  ) async throws -> [String: JSONValue] {
    guard timeout.isFinite, timeout > 0, timeout <= 24 * 60 * 60 else {
      throw RcloneRuntimeError.invalidResponse("RCタイムアウト値が不正です。")
    }
    guard state.process.isRunning || method == "core/quit" else {
      self.state = nil
      descriptorHeartbeat?.cancel()
      descriptorHeartbeat = nil
      try? FileManager.default.removeItem(at: AppStoragePaths.sharedFile(named: "rclone-runtime.json"))
      throw RcloneRuntimeError.unavailable("rcloneプロセスが終了しています。")
    }

    let safeMethod = method.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !safeMethod.isEmpty, !safeMethod.contains("..") else {
      throw RcloneRuntimeError.invalidResponse("RCメソッド名が不正です。")
    }
    let url = state.baseURL.appendingPathComponent(safeMethod)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let credentials = Data("\(state.username):\(state.password)".utf8).base64EncodedString()
    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    let body = try encoder.encode(parameters)
    guard body.count <= 16 * 1_024 * 1_024 else {
      throw RcloneRuntimeError.invalidResponse("RC要求が16 MiBを超えました。")
    }
    request.httpBody = body

    do {
      let (data, response) = try await session.data(for: request)
      guard data.count <= 64 * 1_024 * 1_024 else {
        throw RcloneRuntimeError.invalidResponse("応答が64 MiBを超えました。")
      }
      guard let http = response as? HTTPURLResponse else {
        throw RcloneRuntimeError.invalidResponse("HTTP応答ではありません。")
      }
      guard Self.sameOrigin(http.url, state.baseURL) else {
        throw RcloneRuntimeError.invalidResponse("RC応答元がローカルrcloneと一致しません。")
      }
      if !(200..<300).contains(http.statusCode) {
        let object = try? decoder.decode([String: JSONValue].self, from: data)
        let message = object?["error"]?.stringValue
          ?? String(data: data.prefix(16_384), encoding: .utf8)
          ?? "HTTP \(http.statusCode)"
        throw RcloneRuntimeError.invalidResponse(message)
      }
      if data.isEmpty { return [:] }
      return try decoder.decode([String: JSONValue].self, from: data)
    } catch let error as RcloneRuntimeError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw RcloneRuntimeError.timedOut
    } catch {
      if !state.process.isRunning {
        self.state = nil
        descriptorHeartbeat?.cancel()
        descriptorHeartbeat = nil
        try? FileManager.default.removeItem(at: AppStoragePaths.sharedFile(named: "rclone-runtime.json"))
      }
      throw RcloneRuntimeError.unavailable(error.localizedDescription)
    }
  }

  private nonisolated static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
    guard let lhs else { return false }
    return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && lhs.port == rhs.port
  }

  nonisolated static func canBindOAuthPort() -> Bool {
    #if canImport(Darwin)
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(53_682).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    #else
    return true
    #endif
  }

  private nonisolated static func launchWithRetries() async throws -> State {
    var lastError: Error = RcloneRuntimeError.launchFailed("不明な起動エラー")
    for attempt in 1...3 {
      do {
        return try await launch()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        guard attempt < 3 else { break }
        try await Task.sleep(nanoseconds: UInt64(attempt) * 180_000_000)
      }
    }
    throw lastError
  }

  private nonisolated static func launch() async throws -> State {
    guard let binary = resolveBinaryURL() else { throw RcloneRuntimeError.binaryMissing }

    let fm = FileManager.default
    await shutdownPublishedRuntimeIfPresent()
    cleanupStaleRuntimeDirectories()
    let runtimeRoot = AppStoragePaths.directory(named: "Runtime/rclone-\(UUID().uuidString)")
    let cacheURL = runtimeRoot.appendingPathComponent("cache", isDirectory: true)
    let configURL = runtimeRoot.appendingPathComponent("rclone.conf")
    try fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    guard fm.createFile(
      atPath: configURL.path,
      contents: Data(),
      attributes: [.posixPermissions: 0o600]
    ) else {
      try? fm.removeItem(at: runtimeRoot)
      throw RcloneRuntimeError.launchFailed("rclone設定ファイルを安全に作成できませんでした。")
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

    let username = "nafi"
    let password = try Self.randomSecret(byteCount: 32)
    let output = Pipe()
    let errorOutput = Pipe()
    let logBuffer = RcloneLogBuffer()
    output.fileHandleForReading.readabilityHandler = { handle in logBuffer.append(handle.availableData) }
    errorOutput.fileHandleForReading.readabilityHandler = { handle in logBuffer.append(handle.availableData) }
    let process = Process()
    process.executableURL = binary
    process.arguments = [
      "rcd",
      "--rc-addr", "127.0.0.1:0",
      "--rc-user", username,
      "--rc-pass", password,
      "--rc-job-expire-duration", "24h",
      "--rc-job-expire-interval", "1m",
      "--config", configURL.path,
      "--cache-dir", cacheURL.path,
      "--log-level", "NOTICE",
      "--ask-password=false",
    ]
    process.standardOutput = output
    process.standardError = errorOutput
    var environment = ProcessInfo.processInfo.environment
    // The bundled daemon must be controlled only by explicit arguments and the
    // generated runtime config. Ignore inherited rclone settings that could
    // redirect configuration, enable password commands, or alter RC exposure.
    for key in environment.keys where key.hasPrefix("RCLONE_") {
      environment[key] = nil
    }
    environment["RCLONE_CONFIG_PASS"] = ""
    environment["LC_ALL"] = "C"
    process.environment = environment

    do {
      try process.run()
      let pidURL = runtimeRoot.appendingPathComponent("pid")
      try Data(String(process.processIdentifier).utf8).write(
        to: pidURL,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
    } catch {
      try? fm.removeItem(at: runtimeRoot)
      throw RcloneRuntimeError.launchFailed(error.localizedDescription)
    }
    process.terminationHandler = { terminated in
      removeDescriptorIfOwned(by: terminated.processIdentifier)
    }

    let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
    var discoveredBaseURL: URL?
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if Task.isCancelled {
        await terminate(process, graceNanoseconds: 150_000_000)
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil
        try? fm.removeItem(at: runtimeRoot)
        throw CancellationError()
      }
      if !process.isRunning {
        let message = logBuffer.text().isEmpty
          ? "終了コード \(process.terminationStatus)"
          : logBuffer.text()
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil
        try? fm.removeItem(at: runtimeRoot)
        throw RcloneRuntimeError.launchFailed(message)
      }
      if discoveredBaseURL == nil {
        discoveredBaseURL = loopbackBaseURL(from: logBuffer.text())
      }
      if let baseURL = discoveredBaseURL {
        var request = URLRequest(url: baseURL.appendingPathComponent("rc/noop"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        let probeSession = URLSession(
          configuration: configuration,
          delegate: RcloneURLSessionDelegate(),
          delegateQueue: nil
        )
        if let (_, response) = try? await probeSession.data(for: request),
          let http = response as? HTTPURLResponse,
          sameOrigin(http.url, baseURL),
          (200..<300).contains(http.statusCode)
        {
          do {
            try await validateVersion(
              baseURL: baseURL,
              username: username,
              password: password,
              session: probeSession
            )
          } catch {
            await terminate(process, graceNanoseconds: 150_000_000)
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            try? fm.removeItem(at: runtimeRoot)
            throw error
          }
          return State(
            process: process,
            baseURL: baseURL,
            username: username,
            password: password,
            configURL: configURL,
            cacheURL: cacheURL,
            generation: UUID(),
            outputPipe: output,
            errorPipe: errorOutput,
            logBuffer: logBuffer
          )
        }
      }
      try await Task.sleep(nanoseconds: 120_000_000)
    }

    await terminate(process, graceNanoseconds: 200_000_000)
    output.fileHandleForReading.readabilityHandler = nil
    errorOutput.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(at: runtimeRoot)
    throw RcloneRuntimeError.launchFailed("起動確認が12秒以内に完了しませんでした。")
  }

  private nonisolated static func terminate(_ process: Process, graceNanoseconds: UInt64) async {
    guard process.isRunning else { return }
    process.terminate()
    try? await Task.sleep(nanoseconds: graceNanoseconds)
    guard process.isRunning else { return }
    process.interrupt()
    try? await Task.sleep(nanoseconds: 150_000_000)
    #if canImport(Darwin)
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    #endif
  }

  private nonisolated static func publishDescriptor(for state: State) throws {
    let descriptor = RcloneRuntimeDescriptor(
      baseURL: state.baseURL,
      username: state.username,
      password: state.password,
      generation: state.generation,
      processIdentifier: state.process.processIdentifier,
      expiresAt: Date().addingTimeInterval(2 * 60 * 60)
    )
    let data = try JSONEncoder().encode(descriptor)
    let destination = AppStoragePaths.sharedFile(named: "rclone-runtime.json")
    try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  private nonisolated static func resolveBinaryURL() -> URL? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let helper = Bundle.main.url(forAuxiliaryExecutable: "rclone") { candidates.append(helper) }
    if let resource = Bundle.main.resourceURL?.appendingPathComponent("Helpers/rclone") {
      candidates.append(resource)
    }
    if let override = ProcessInfo.processInfo.environment["NAFI_RCLONE_PATH"], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override))
    }
    candidates.append(contentsOf: [
      URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
      URL(fileURLWithPath: "/usr/local/bin/rclone"),
      URL(fileURLWithPath: "/usr/bin/rclone"),
    ])
    return candidates.first { fm.isExecutableFile(atPath: $0.path) }
  }

  private func refreshDescriptor() {
    guard let state, state.process.isRunning else {
      try? FileManager.default.removeItem(at: AppStoragePaths.sharedFile(named: "rclone-runtime.json"))
      return
    }
    try? Self.publishDescriptor(for: state)
  }

  private nonisolated static func randomSecret(byteCount: Int) throws -> String {
    guard (16...4_096).contains(byteCount) else {
      throw RcloneRuntimeError.launchFailed("rclone認証情報の生成条件が不正です。")
    }
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
      throw RcloneRuntimeError.launchFailed("安全な乱数を生成できないためrcloneを起動しません。")
    }
    return Data(bytes).base64EncodedString()
  }

  private nonisolated static func validateVersion(
    baseURL: URL,
    username: String,
    password: String,
    session: URLSession
  ) async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("core/version"))
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())",
      forHTTPHeaderField: "Authorization"
    )
    request.timeoutInterval = 2
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      sameOrigin(http.url, baseURL),
      (200..<300).contains(http.statusCode),
      data.count <= 64 * 1_024,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = object["version"] as? String,
      supportedVersion(raw)
    else {
      throw RcloneRuntimeError.launchFailed(
        "このNafiはrclone 1.74以降を必要とします。アプリ同梱版を使用するか、NAFI_RCLONE_PATHを更新してください。"
      )
    }
  }

  private nonisolated static func supportedVersion(_ raw: String) -> Bool {
    let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    let parts = clean.split(separator: ".").prefix(3).compactMap { part -> Int? in
      Int(part.prefix { $0.isNumber })
    }
    guard parts.count >= 2 else { return false }
    return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 74)
  }

  private nonisolated static func shutdownPublishedRuntimeIfPresent() async {
    let descriptorURL = AppStoragePaths.sharedFile(named: "rclone-runtime.json")
    guard let descriptor = publishedDescriptor(at: descriptorURL) else {
      try? FileManager.default.removeItem(at: descriptorURL)
      return
    }
    var request = URLRequest(url: descriptor.baseURL.appendingPathComponent("core/quit"))
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = 1
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic \(Data("\(descriptor.username):\(descriptor.password)".utf8).base64EncodedString())",
      forHTTPHeaderField: "Authorization"
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1
    configuration.timeoutIntervalForResource = 2
    let session = URLSession(
      configuration: configuration,
      delegate: RcloneURLSessionDelegate(),
      delegateQueue: nil
    )
    _ = try? await session.data(for: request)
    try? FileManager.default.removeItem(at: descriptorURL)
  }

  private nonisolated static func cleanupStaleRuntimeDirectories() {
    let parent = AppStoragePaths.directory(named: "Runtime")
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for entry in entries where entry.lastPathComponent.hasPrefix("rclone-") {
      guard let values = try? entry.resourceValues(forKeys: keys),
        values.isDirectory == true,
        (values.contentModificationDate ?? .distantPast) < cutoff
      else { continue }
      let pidURL = entry.appendingPathComponent("pid")
      if let data = try? AppStoragePaths.readRegularFile(at: pidURL, maximumBytes: 32),
        let text = String(data: data, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        pid > 1,
        kill(pid, 0) == 0 || errno == EPERM
      {
        continue
      }
      try? FileManager.default.removeItem(at: entry)
    }
  }

  private nonisolated static func loopbackBaseURL(from log: String) -> URL? {
    guard let expression = try? NSRegularExpression(
      pattern: #"https?://127\.0\.0\.1:([0-9]{1,5})/"#
    ) else { return nil }
    let range = NSRange(log.startIndex..<log.endIndex, in: log)
    guard let match = expression.firstMatch(in: log, range: range),
      let matchRange = Range(match.range(at: 0), in: log),
      let portRange = Range(match.range(at: 1), in: log),
      let port = Int(log[portRange]), (1...65_535).contains(port),
      let url = URL(string: String(log[matchRange]))
    else { return nil }
    return url
  }

  private nonisolated static func removeDescriptorIfOwned(by processIdentifier: Int32) {
    let url = AppStoragePaths.sharedFile(named: "rclone-runtime.json")
    guard let descriptor = publishedDescriptor(at: url),
      descriptor.processIdentifier == processIdentifier
    else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private nonisolated static func publishedDescriptor(
    at url: URL
  ) -> RcloneRuntimeDescriptor? {
    guard let data = try? AppStoragePaths.readRegularFile(
      at: url,
      maximumBytes: 64 * 1_024
    ), !data.isEmpty,
      let descriptor = try? JSONDecoder().decode(RcloneRuntimeDescriptor.self, from: data),
      descriptor.processIdentifier > 1,
      descriptor.expiresAt.timeIntervalSinceReferenceDate.isFinite,
      descriptor.expiresAt <= Date().addingTimeInterval(3 * 60 * 60),
      descriptor.baseURL.scheme == "http",
      descriptor.baseURL.host == "127.0.0.1",
      descriptor.baseURL.port.map({ (1...65_535).contains($0) }) == true,
      descriptor.baseURL.user == nil,
      descriptor.baseURL.password == nil,
      descriptor.baseURL.path.isEmpty || descriptor.baseURL.path == "/",
      descriptor.baseURL.query == nil,
      descriptor.baseURL.fragment == nil,
      !descriptor.username.isEmpty, descriptor.username.utf8.count <= 1_024,
      !descriptor.password.isEmpty, descriptor.password.utf8.count <= 16 * 1_024
    else { return nil }
    return descriptor
  }

}
