import Foundation
#if canImport(FileProvider)
import FileProvider
#endif

enum FileProviderChangeNotifier {
  static func signal(profileID: UUID) async {
    #if canImport(FileProvider)
    let identifier = NSFileProviderDomainIdentifier(
      rawValue: "app.nafi.filemanager.remote.\(profileID.uuidString.lowercased())"
    )
    let domain = NSFileProviderDomain(identifier: identifier, displayName: "nafi")
    guard let manager = NSFileProviderManager(for: domain) else { return }
    await withTaskGroup(of: Void.self) { group in
      for container: NSFileProviderItemIdentifier in [.rootContainer, .workingSet] {
        group.addTask {
          await withCheckedContinuation { continuation in
            manager.signalEnumerator(for: container) { _ in continuation.resume() }
          }
        }
      }
    }
    #endif
  }
}
