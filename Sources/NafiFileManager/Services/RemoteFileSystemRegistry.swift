import Foundation

actor RemoteFileSystemRegistry {
  static let shared = RemoteFileSystemRegistry()

  private var profiles: [UUID: ServerProfile] = [:]
  private var sessions: [UUID: any RemoteServerSession] = [:]
  private var connector: (@Sendable (UUID) async throws -> Void)?
  private var connectionTasks: [UUID: Task<Void, Error>] = [:]

  func configureConnector(_ connector: @escaping @Sendable (UUID) async throws -> Void) {
    self.connector = connector
  }

  func registerProfiles(_ values: [ServerProfile]) {
    for profile in values { profiles[profile.id] = profile }
  }

  func register(profile: ServerProfile, session: any RemoteServerSession) {
    profiles[profile.id] = profile
    sessions[profile.id] = session
  }

  func update(profile: ServerProfile) {
    profiles[profile.id] = profile
  }

  func unregister(profileID: UUID) {
    connectionTasks.removeValue(forKey: profileID)?.cancel()
    sessions[profileID] = nil
    profiles[profileID] = nil
  }

  func disconnect(profileID: UUID) {
    connectionTasks.removeValue(forKey: profileID)?.cancel()
    sessions[profileID] = nil
  }

  func profile(for profileID: UUID) -> ServerProfile? {
    profiles[profileID]
  }

  func profile(for url: URL) -> ServerProfile? {
    guard let id = NafiURL.profileID(in: url) else { return nil }
    return profiles[id]
  }

  func session(for profileID: UUID) async throws -> any RemoteServerSession {
    if let session = sessions[profileID] { return session }
    guard profiles[profileID] != nil else { throw RemoteServerError.notConnected }
    guard let connector else { throw RemoteServerError.notConnected }

    let task: Task<Void, Error>
    if let existing = connectionTasks[profileID] {
      task = existing
    } else {
      let created = Task {
        try Task.checkCancellation()
        try await connector(profileID)
      }
      connectionTasks[profileID] = created
      task = created
    }

    do {
      try await task.value
      connectionTasks[profileID] = nil
    } catch {
      connectionTasks[profileID] = nil
      throw error
    }

    guard let session = sessions[profileID] else { throw RemoteServerError.notConnected }
    return session
  }

  func session(for url: URL) async throws -> any RemoteServerSession {
    if NafiURL.isAmbiguousRemoteItem(url) {
      throw RemoteServerError.unsupported(
        "接続先に同名項目が複数あり、rcloneの汎用パスAPIでは安全に一意指定できません。接続先側で名前を一意にしてから操作してください。"
      )
    }
    guard let id = NafiURL.profileID(in: url) else { throw RemoteServerError.notConnected }
    return try await session(for: id)
  }
}
