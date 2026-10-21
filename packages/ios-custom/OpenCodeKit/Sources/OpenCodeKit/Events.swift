import Foundation

public enum ServerEvent: Sendable {
  case connected
  case update(ConversationEvent)
}

public struct ConversationEvent: Codable, Sendable {
  public let type: String
  public let created: Double?
  public let data: Payload
  public struct Payload: Codable, Sendable {
    public let sessionID: String?
    public let assistantMessageID: String?
    public let id: String?
    public let ordinal: Int?
    public let delta: JSONValue?
    public let text: String?
    public let name: String?
    public let agent: String?
    public let model: ModelReference?
    public let started: Double?
    public let finish: String?
    public let tokens: TokenUsage?
    public let input: JSONValue?
    public let metadata: JSONValue?
    public let state: JSONValue?
    public let content: JSONValue?
    public let error: JSONValue?
    public let form: JSONValue?
    public var owner: String? { sessionID ?? form?.object?["sessionID"]?.string }
  }
}

public struct EventParser: Sendable {
  private var payload: [String] = []
  private var buffer: [UInt8] = []
  public init() {}
  public mutating func consume(_ byte: UInt8) -> ServerEvent? {
    guard byte == 10 else {
      buffer.append(byte)
      return nil
    }
    if buffer.last == 13 { buffer.removeLast() }
    let text = String(decoding: buffer, as: UTF8.self)
    buffer.removeAll(keepingCapacity: true)
    return line(text)
  }
  public mutating func line(_ line: String) -> ServerEvent? {
    if line.hasPrefix(":") { return nil }
    if line.hasPrefix("data:") {
      payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
      return nil
    }
    guard line.isEmpty, !payload.isEmpty else { return nil }
    defer { payload.removeAll(keepingCapacity: true) }
    guard
      let event = try? JSONDecoder().decode(
        ConversationEvent.self, from: Data(payload.joined(separator: "\n").utf8))
    else { return nil }
    if event.type == "server.connected" { return nil }
    return .update(event)
  }
}
