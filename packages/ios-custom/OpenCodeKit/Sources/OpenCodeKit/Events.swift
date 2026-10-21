import Foundation

public enum ServerEvent: Sendable {
  case connected
  case update(type: String, sessionID: String?)
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
    struct Envelope: Decodable {
      let type: String
      let data: [String: JSONValue]?
    }
    guard
      let event = try? JSONDecoder().decode(
        Envelope.self, from: Data(payload.joined(separator: "\n").utf8))
    else { return nil }
    if event.type == "server.connected" { return nil }
    return .update(type: event.type, sessionID: event.data?["sessionID"]?.string)
  }
}
