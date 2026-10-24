import Foundation

public enum TranscriptMessage: Codable, Sendable {
  case user(User)
  case assistant(Assistant)
  case unknown(type: String, created: Double)

  public struct User: Codable, Sendable {
    public let text: String
    public let files: [File]?
    public let time: Time
  }
  public struct File: Codable, Sendable { public let mime: String? }
  public struct Time: Codable, Sendable { public let created: Double }
  public struct Assistant: Codable, Sendable {
    public let content: [Part]
    public let time: Time
  }
  public enum Part: Codable, Sendable {
    case text(String)
    case tool(Tool)
    case unknown(String)

    private enum CodingKeys: String, CodingKey { case type, text }
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let type = try values.decode(String.self, forKey: .type)
      switch type {
      case "text": self = .text(try values.decode(String.self, forKey: .text))
      case "tool": self = .tool(try Tool(from: decoder))
      default: self = .unknown(type)
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .text(let text):
        try values.encode("text", forKey: .type)
        try values.encode(text, forKey: .text)
      case .tool(let tool):
        try values.encode("tool", forKey: .type)
        try tool.encode(to: encoder)
      case .unknown(let type): try values.encode(type, forKey: .type)
      }
    }
  }
  public struct Tool: Codable, Sendable {
    public let name: String
    public let state: State
    public struct State: Codable, Sendable {
      public let status: Status
      public let input: JSONValue?
      public let content: [File]?
      public enum Status: String, Codable, Sendable {
        case streaming, running, completed, error, unknown
        public init(from decoder: any Decoder) throws {
          self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
      }
    }
    public var activity: String {
      let input = state.input?.object
      if let command = input?["command"]?.string { return "rodando \(command)" }
      if let path = input?["filePath"]?.string ?? input?["path"]?.string {
        return
          "\(name == "read" ? "lendo" : "editando") \(URL(fileURLWithPath: path).lastPathComponent)"
      }
      return "usando \(name)"
    }
  }

  private enum CodingKeys: String, CodingKey { case type, time }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let type = try values.decode(String.self, forKey: .type)
    switch type {
    case "user": self = .user(try User(from: decoder))
    case "assistant": self = .assistant(try Assistant(from: decoder))
    default:
      self = .unknown(type: type, created: try values.decode(Time.self, forKey: .time).created)
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .user(let user):
      try values.encode("user", forKey: .type)
      try user.encode(to: encoder)
    case .assistant(let assistant):
      try values.encode("assistant", forKey: .type)
      try assistant.encode(to: encoder)
    case .unknown(let type, let created):
      try values.encode(type, forKey: .type)
      try values.encode(Time(created: created), forKey: .time)
    }
  }
  public var created: Double {
    switch self {
    case .user(let value): value.time.created
    case .assistant(let value): value.time.created
    case .unknown(_, let created): created
    }
  }
}

public struct TranscriptPage: Codable, Sendable {
  public let data: [TranscriptMessage]
}

public struct SessionPreview: Sendable, Equatable {
  public var text = ""
  public var image = false
  public var activity: String?
  /// The first nonblank line of `text` when the latest message with text is the assistant's;
  /// `nil` when the user wrote last. Session alerts show it verbatim, without summarizing.
  public var reply: String?

  public init(messages: [TranscriptMessage] = []) {
    let ordered = messages.sorted { $0.created > $1.created }
    for message in ordered {
      switch message {
      case .user(let value):
        if !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          text = "Você: \(value.text)"
        } else if value.files?.contains(where: { $0.mime?.hasPrefix("image/") == true }) == true {
          image = true
          text = "Imagem"
        }
      case .assistant(let value):
        text = value.content.compactMap { if case .text(let text) = $0 { text } else { nil } }
          .joined(separator: " ")
        reply = text.split(whereSeparator: \.isNewline)
          .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
          .map { String($0.prefix(240)) }
        if text.isEmpty,
          value.content.contains(where: {
            if case .tool(let tool) = $0 {
              return tool.state.content?.contains { $0.mime?.hasPrefix("image/") == true } == true
            }
            return false
          })
        {
          image = true
          text = "Imagem"
        }
      case .unknown: break
      }
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
    }
    text = String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240))
    for message in ordered {
      guard case .assistant(let value) = message else { continue }
      activity =
        value.content.reversed().compactMap {
          guard case .tool(let tool) = $0, [.running, .streaming].contains(tool.state.status) else {
            return nil
          }
          return tool.activity
        }.first
      break
    }
  }
}
