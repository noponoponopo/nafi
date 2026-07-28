import Foundation

enum PreferenceMigration {
  private static var hasRun = false

  static func run() {
    guard !hasRun else { return }
    hasRun = true

    let defaults = UserDefaults.standard
    let keys = [
      ("Nami.defaultShowHidden", "Nafi.defaultShowHidden"),
      ("Nami.defaultViewMode", "Nafi.defaultViewMode"),
      ("Nami.thumbnails.localImages", "Nafi.thumbnails.localImages"),
      ("Nami.thumbnails.localVideos", "Nafi.thumbnails.localVideos"),
      ("Nami.thumbnails.remoteImages", "Nafi.thumbnails.remoteImages"),
      ("Nami.thumbnails.remoteVideos", "Nafi.thumbnails.remoteVideos"),
    ]

    for (legacyKey, currentKey) in keys where defaults.object(forKey: currentKey) == nil {
      if let value = defaults.object(forKey: legacyKey) {
        defaults.set(value, forKey: currentKey)
      }
    }
  }
}
