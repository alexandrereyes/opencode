import Foundation

public enum ConversationMessageKind: Codable, Sendable, Equatable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  case user, assistant, synthetic, system, skill, agentSwitched, modelSwitched, locationSwitched,
    shell, compaction, idle
  case unknown(String)

  public init(stringLiteral value: String) { self.init(value) }
  public init(_ value: String) {
    switch value {
    case "user": self = .user
    case "assistant": self = .assistant
    case "synthetic": self = .synthetic
    case "system": self = .system
    case "skill": self = .skill
    case "agent-switched": self = .agentSwitched
    case "model-switched": self = .modelSwitched
    case "location-switched": self = .locationSwitched
    case "shell": self = .shell
    case "compaction": self = .compaction
    case "idle": self = .idle
    default: self = .unknown(value)
    }
  }
  public var description: String {
    switch self {
    case .user: "user"
    case .assistant: "assistant"
    case .synthetic: "synthetic"
    case .system: "system"
    case .skill: "skill"
    case .agentSwitched: "agent-switched"
    case .modelSwitched: "model-switched"
    case .locationSwitched: "location-switched"
    case .shell: "shell"
    case .compaction: "compaction"
    case .idle: "idle"
    case .unknown(let value): value
    }
  }
  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(description)
  }
}

public enum ConversationPartKind: Codable, Sendable, Equatable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  case text, reasoning, tool
  case unknown(String)

  public init(stringLiteral value: String) { self.init(value) }
  public init(_ value: String) {
    switch value {
    case "text": self = .text
    case "reasoning": self = .reasoning
    case "tool": self = .tool
    default: self = .unknown(value)
    }
  }
  public var description: String {
    switch self {
    case .text: "text"
    case .reasoning: "reasoning"
    case .tool: "tool"
    case .unknown(let value): value
    }
  }
  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(description)
  }
}
