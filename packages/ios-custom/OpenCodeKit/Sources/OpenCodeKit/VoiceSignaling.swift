import Foundation

public struct VoiceLease: Decodable, Sendable {
  public let sessionId: UUID
  public let generation: UUID
  public let serverTime: Date
  public let leaseExpiresAt: Date
  public var remaining: TimeInterval { leaseExpiresAt.timeIntervalSince(serverTime) }
}

public struct VoiceSignaling: Sendable {
  public static let baseURL = URL(string: "http://llm-proxy-svc:8080")!
  public let sessionID: UUID
  public let generation: UUID
  public init(sessionID: UUID = UUID(), generation: UUID = UUID()) {
    self.sessionID = sessionID; self.generation = generation
  }
  public func leaseRequest(method: String) throws -> URLRequest {
    var url = Self.baseURL.appending(path: "_gpt-live/sessions/\(sessionID.uuidString)")
    if method == "DELETE" {
      url.append(queryItems: [URLQueryItem(name: "generation", value: generation.uuidString)])
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if method != "DELETE" {
      request.httpBody = try JSONEncoder().encode(["generation": generation.uuidString])
    }
    return request
  }
  public func offerRequest(sdp: String) throws -> URLRequest {
    guard sdp.hasPrefix("v=0"), sdp.utf8.count <= 256 * 1024 else { throw VoiceWireError.invalidAnswer }
    var url = Self.baseURL.appending(path: "backend-api/codex/realtime/calls")
    url.append(queryItems: [URLQueryItem(name: "intent", value: "quicksilver"),
      URLQueryItem(name: "architecture", value: "avas")])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    ["Content-Type": "application/json", "Accept": "application/sdp", "OpenAI-Alpha": "quicksilver=v2",
      "originator": "a2a-chat", "User-Agent": "OpenCode-iOS/1.0",
      "session-id": sessionID.uuidString, "thread-id": sessionID.uuidString,
      "x-session-id": sessionID.uuidString, "x-gpt-live-generation": generation.uuidString
    ].forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.httpBody = try JSONEncoder().encode(JSONValue.object([
      "sdp": .string(sdp), "session": .object([
        "model": .string("gpt-live-1-codex"), "instructions": .string(VoiceProtocol.instructions),
        "audio": .object(["output": .object(["voice": .string("cove")])]),
        "delegation": .object(["type": .string("client")]),
      ]),
    ]))
    return request
  }
  public func parseLease(_ data: Data, status: Int) throws -> VoiceLease {
    guard status == 200 else { throw VoiceWireError.unavailable(status) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: text) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: text) else { throw VoiceWireError.invalidAnswer }
      return date
    }
    let lease = try decoder.decode(VoiceLease.self, from: data)
    guard lease.sessionId == sessionID, lease.generation == generation, lease.remaining > 0 else {
      throw VoiceWireError.invalidAnswer
    }
    return lease
  }
  public static func parseAnswer(_ data: Data, response: HTTPURLResponse) throws -> String {
    guard response.statusCode == 201 else { throw VoiceWireError.unavailable(response.statusCode) }
    guard data.count <= 256 * 1024, let sdp = String(data: data, encoding: .utf8),
      sdp.hasPrefix("v=0"), sdp.contains("m=audio"), sdp.contains("m=application"),
      let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty else {
      throw VoiceWireError.invalidAnswer
    }
    return sdp
  }
}
