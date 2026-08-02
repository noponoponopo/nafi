import Foundation
#if canImport(FileProvider)
import FileProvider
#endif

private let fileProviderRefreshRequestNotification = Notification.Name(
  "app.nafi.filemanager.fileprovider.refresh-request"
)

enum FileProviderChangeNotifier {
  static func signal(profileID: UUID) async {
    #if canImport(FileProvider)
    try? await signal(profileID: profileID, reportErrors: false)
    #endif
  }

  static func refreshNow(profileID: UUID) async throws {
    #if canImport(FileProvider)
    try await signal(profileID: profileID, reportErrors: true)
    #else
    throw CocoaError(.featureUnsupported)
    #endif
  }

  #if canImport(FileProvider)
  private static func signal(profileID: UUID, reportErrors: Bool) async throws {
    let identifier = NSFileProviderDomainIdentifier(
      rawValue: "app.nafi.filemanager.remote.\(profileID.uuidString.lowercased())"
    )
    let domain = NSFileProviderDomain(identifier: identifier, displayName: "nafi")
    guard let manager = NSFileProviderManager(for: domain) else {
      if reportErrors { throw CocoaError(.featureUnsupported) }
      return
    }
    // Active nested enumerators know their own opaque identifiers. Ask those
    // live enumerators to refresh too, while root/working-set signals below
    // cover startup and the normal system reconciliation path.
    DistributedNotificationCenter.default().postNotificationName(
      fileProviderRefreshRequestNotification,
      object: domain.identifier.rawValue,
      userInfo: nil,
      deliverImmediately: true
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      // Root catches remote additions/removals at the published root. The working
      // set covers items macOS is actively tracking, without a periodic poll.
      for container: NSFileProviderItemIdentifier in [.rootContainer, .workingSet] {
        group.addTask {
          try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.signalEnumerator(for: container) { error in
              if let error { continuation.resume(throwing: error) }
              else { continuation.resume() }
            }
          }
        }
      }
      try await group.waitForAll()
    }
  }
  #endif
}
