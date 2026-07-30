import Foundation

struct FileProviderDomainRecord: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  var displayName: String
  var fs: String
  var rootPath: String
  var updatedAt: Date
  var configurationRevision: UUID?

  init(profile: ServerProfile) {
    id = profile.id
    displayName = profile.name
    fs = RcloneConfiguration.fs(for: profile)
    rootPath = RemotePath.normalized(profile.path)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    updatedAt = Date()
    configurationRevision = profile.configurationRevision
  }
}
