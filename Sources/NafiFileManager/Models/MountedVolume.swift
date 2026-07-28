import Foundation

struct MountedVolume: Identifiable, Hashable {
  let url: URL
  let name: String
  let isLocal: Bool
  let isReadOnly: Bool

  var id: URL { url }
}
