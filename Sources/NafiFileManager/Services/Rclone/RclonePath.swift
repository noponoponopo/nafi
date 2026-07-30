import Foundation

enum RclonePath {
  static func combinedFS(_ fs: String, path: String) -> String {
    let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !clean.isEmpty else { return fs }
    if fs == "/" { return "/" + clean }
    if fs.hasSuffix(":") || fs.hasSuffix("/") { return fs + clean }
    return fs + "/" + clean
  }

  static func localRemote(_ url: URL) -> String {
    url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
