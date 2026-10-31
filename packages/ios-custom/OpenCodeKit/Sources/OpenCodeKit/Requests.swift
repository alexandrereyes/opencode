import Foundation

public struct PermissionRequest: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let sessionID: String
  public let action: String
  public let resources: [String]
  public let metadata: [String: JSONValue]?
  public let message: String?
  public let source: Source?
  public struct Source: Codable, Sendable, Equatable {
    public let type: String
    public let messageID: String?
    public let id: String?
  }

  public var preview: String {
    let command = resources.first ?? metadata?["command"]?.string ?? message ?? action
    return "Quer rodar: \(command)"
  }
}

public struct PendingForm: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let sessionID: String
  public let title: String
  public let fields: [Field]
  public let metadata: [String: JSONValue]?

  public struct Field: Codable, Sendable, Identifiable, Equatable {
    public let key: String
    public var id: String { key }
    public let type: Kind
    public let title: String?
    public let description: String?
    public let options: [Option]?
    public let custom: Bool?
    public let required: Bool?
    public let hidden: Bool?
    public let when: [Condition]?
    public let minItems: Int?
    public let maxItems: Int?
    public struct Option: Codable, Sendable, Identifiable, Equatable {
      public let value: String
      public let label: String
      public let description: String?
      public var id: String { value }
    }
    public struct Condition: Codable, Sendable, Equatable {
      public let key: String
      public let op: String
      public let value: JSONValue
    }
    public enum Kind: String, Codable, Sendable {
      case string, number, integer, boolean, multiselect, external, unknown
      public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
      }
    }
  }
  public var preview: String { fields.first?.description ?? fields.first?.title ?? title }
}

public struct FamilySnapshot: Codable, Sendable {
  public let count: Int
  public let cost: Double?
  public let active: [Session]
  public let forms: [PendingForm]
  public let permissions: [PermissionRequest]
  /// The Progresso of each active descendant showing one, by session ID (rev. 2026-10-30); absent on older servers.
  public let progress: [String: NavigationEntry.Progress]?
}

public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let text = try? value.decode(String.self) {
      self = .string(text)
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? value.decode(Double.self) {
      self = .number(number)
    } else if let object = try? value.decode([String: JSONValue].self) {
      self = .object(object)
    } else {
      self = .array(try value.decode([JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .string(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .bool(let item): try value.encode(item)
    case .object(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .null: try value.encodeNil()
    }
  }
  public var string: String? { if case .string(let text) = self { text } else { nil } }
  public var number: Double? { if case .number(let value) = self { value } else { nil } }
  public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  public var formatted: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }
  public var object: [String: JSONValue]? {
    if case .object(let values) = self { values } else { nil }
  }
}
