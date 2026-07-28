import Foundation

actor RemoteFileSystemRegistry {
  static let shared = RemoteFileSystemRegistry()

  private var profiles: [UUID: ServerProfile] = [:]
  private var sessions: [UUID: any RemoteServerSession] = [:]
  private var connector: (@Sendable (UUID) async throws -> Void)?

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
    sessions[profileID] = nil
    profiles[profileID] = nil
  }

  func disconnect(profileID: UUID) {
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
    guard let connector else { throw RemoteServerError.notConnected }
    try await connector(profileID)
    guard let session = sessions[profileID] else { throw RemoteServerError.notConnected }
    return session
  }

  func session(for url: URL) async throws -> any RemoteServerSession {
    guard let id = NafiURL.profileID(in: url) else { throw RemoteServerError.notConnected }
    return try await session(for: id)
  }
}
