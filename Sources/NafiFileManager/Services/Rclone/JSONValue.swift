import Foundation

enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(Double.self) { self = .double(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var intValue: Int64? {
    switch self {
    case .integer(let value): value
    case .double(let value): Int64(value)
    default: nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }

  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  mutating func set(_ key: String, _ value: String?) {
    guard let value, !value.isEmpty else { return }
    self[key] = .string(value)
  }

  mutating func set(_ key: String, _ value: Bool) {
    self[key] = .bool(value)
  }

  mutating func set(_ key: String, _ value: Int) {
    self[key] = .integer(Int64(value))
  }
}
