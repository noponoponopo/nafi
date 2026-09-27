import Foundation

actor RemoteFileSystemRegistry {
  static let shared = RemoteFileSystemRegistry()

  private var profiles: [UUID: ServerProfile] = [:]
  private var generations: [UUID: UUID] = [:]
  private var sessions: [UUID: any RemoteServerSession] = [:]
  private var connector: (@Sendable (UUID) async throws -> Void)?
  private var connectionTasks: [UUID: (id: UUID, task: Task<Void, Error>)] = [:]

  func configureConnector(_ connector: @escaping @Sendable (UUID) async throws -> Void) {
    self.connector = connector
  }

  func registerProfiles(_ values: [ServerProfile]) {
    for profile in values { update(profile: profile) }
  }

  func connectionGeneration(for profileID: UUID) -> UUID {
    if let generation = generations[profileID] { return generation }
    let generation = UUID()
    generations[profileID] = generation
    return generation
  }

  @discardableResult
  func register(profile: ServerProfile, session: any RemoteServerSession, generation: UUID) -> Bool
  {
    guard generations[profile.id] == generation, let current = profiles[profile.id],
      current.configurationRevision == profile.configurationRevision
    else { return false }
    sessions[profile.id] = session
    return true
  }

  func update(profile: ServerProfile) {
    if let current = profiles[profile.id],
      current.configurationRevision != profile.configurationRevision
    {
      disconnect(profileID: profile.id)
    }
    profiles[profile.id] = profile
  }

  func unregister(profileID: UUID) {
    connectionTasks.removeValue(forKey: profileID)?.task.cancel()
    sessions[profileID] = nil
    profiles[profileID] = nil
    generations[profileID] = nil
  }

  func disconnect(profileID: UUID) {
    generations[profileID] = UUID()
    connectionTasks.removeValue(forKey: profileID)?.task.cancel()
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

    let entry: (id: UUID, task: Task<Void, Error>)
    if let existing = connectionTasks[profileID] {
      entry = existing
    } else {
      entry = (
        UUID(),
        Task {
          try Task.checkCancellation()
          try await connector(profileID)
        }
      )
      connectionTasks[profileID] = entry
    }
    defer {
      if connectionTasks[profileID]?.id == entry.id { connectionTasks[profileID] = nil }
    }
    try await entry.task.value
    try Task.checkCancellation()

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
