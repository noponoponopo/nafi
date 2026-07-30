import FileProvider
import Foundation

struct FPIdentifierCodec {
  struct Decoded: Sendable {
    let path: String
    let identity: String?
  }

  private struct Payload: Codable {
    let path: String
    let identity: String?
  }

  private static let prefix = "nafi."
  private static let maximumPayloadBytes = 64 * 1024
  private static let maximumPathBytes = 32 * 1024
  private static let maximumIdentityBytes = 16 * 1024
  private static let maximumComponents = 1_024

  static func identifier(
    for path: String,
    identityToken: String? = nil
  ) throws -> NSFileProviderItemIdentifier {
    let normalized = try validatedPath(path)
    if normalized.isEmpty { return .rootContainer }
    if let identityToken, identityToken.utf8.count > maximumIdentityBytes {
      throw FPBridgeError.malformedResponse
    }
    let data = try JSONEncoder().encode(Payload(path: normalized, identity: identityToken))
    guard data.count <= maximumPayloadBytes else { throw FPBridgeError.malformedResponse }
    let encoded = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return NSFileProviderItemIdentifier(prefix + encoded)
  }

  static func decode(_ identifier: NSFileProviderItemIdentifier) throws -> Decoded {
    if identifier == .rootContainer { return Decoded(path: "", identity: nil) }
    guard identifier.rawValue.hasPrefix(prefix),
      identifier.rawValue.utf8.count <= maximumPayloadBytes * 2
    else { throw FPBridgeError.malformedResponse }

    var encoded = String(identifier.rawValue.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let data = Data(base64Encoded: encoded), data.count <= maximumPayloadBytes else {
      throw FPBridgeError.malformedResponse
    }
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let path = try validatedPath(payload.path)
    if let identity = payload.identity, identity.utf8.count > maximumIdentityBytes {
      throw FPBridgeError.malformedResponse
    }
    return Decoded(path: path, identity: payload.identity)
  }

  static func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
    try decode(identifier).path
  }

  static func parentPath(of path: String) -> String {
    guard let value = try? validatedPath(path), let index = value.lastIndex(of: "/") else {
      return ""
    }
    return String(value[..<index])
  }

  static func appending(_ name: String, to parent: String) throws -> String {
    let cleanName = try validatedName(name)
    let cleanParent = try validatedPath(parent)
    return try validatedPath(cleanParent.isEmpty ? cleanName : "\(cleanParent)/\(cleanName)")
  }

  static func validatedName(_ value: String) throws -> String {
    guard !value.isEmpty, value != ".", value != "..",
      !value.contains("/"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      value.utf8.count <= 4_096
    else { throw FPBridgeError.invalidName }
    return value
  }

  static func validatedPath(_ value: String) throws -> String {
    guard value.utf8.count <= maximumPathBytes,
      !value.hasPrefix("/"),
      !value.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw FPBridgeError.malformedResponse }

    if value.isEmpty { return "" }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count <= maximumComponents else { throw FPBridgeError.malformedResponse }
    var output: [String] = []
    output.reserveCapacity(components.count)
    for component in components {
      let item = String(component)
      guard item != ".", item != ".." else { throw FPBridgeError.malformedResponse }
      do {
        output.append(try validatedName(item))
      } catch {
        throw FPBridgeError.malformedResponse
      }
    }
    return output.joined(separator: "/")
  }

  static func normalizeTrusted(_ value: String) -> String {
    (try? validatedPath(value)) ?? ""
  }
}
