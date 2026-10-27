import Foundation

/// Apple Watch gateway contract v1 (`packages/plugin-app-custom/docs/watch.md`). JSON is camelCase, times are
/// epoch milliseconds and optional fields are omitted.

/// Result of `custom.watch` → `pair`, sent by the iPhone to the watch over WatchConnectivity and kept only in the
/// watch's Keychain.
public struct WatchPairing: Codable, Hashable, Sendable {
  public var deviceID: String
  public var deviceToken: String
  public var gatewayURL: URL
  public var access: Access
  public var voice: Voice

  public struct Access: Codable, Hashable, Sendable {
    public var clientId: String
    public var clientSecret: String
    public init(clientId: String, clientSecret: String) {
      self.clientId = clientId
      self.clientSecret = clientSecret
    }
  }

  public struct Voice: Codable, Hashable, Sendable {
    public var voiceID: String
    public init(voiceID: String) { self.voiceID = voiceID }
  }

  public init(deviceID: String, deviceToken: String, gatewayURL: URL, access: Access, voice: Voice) {
    self.deviceID = deviceID
    self.deviceToken = deviceToken
    self.gatewayURL = gatewayURL
    self.access = access
    self.voice = voice
  }

  /// WatchConnectivity carries property-list dictionaries; the pairing travels as one JSON blob.
  public static let transferKey = "opencode.watch.pairing"
  public static let revokedKey = "opencode.watch.revoked"

  public func transferPayload() throws -> [String: Any] {
    [Self.transferKey: try JSONEncoder().encode(self)]
  }

  public static func from(payload: [String: Any]) -> WatchPairing? {
    (payload[transferKey] as? Data).flatMap { try? JSONDecoder().decode(WatchPairing.self, from: $0) }
  }
}

/// One paired watch as listed by `custom.watch` → `devices`.
public struct WatchDevice: Codable, Hashable, Sendable, Identifiable {
  public var deviceID: String
  public var name: String
  public var createdAt: Double
  public var lastSeenAt: Double?
  public var id: String { deviceID }
  public var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
  public var lastSeen: Date? { lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public struct WatchPing: Decodable, Sendable {
  public var ok: Bool
  public var server: String
  public var version: String
}

public struct WatchStateSnapshot: Codable, Hashable, Sendable {
  public var state: AgentsState?
  public var host: String
  public init(state: AgentsState?, host: String) {
    self.state = state
    self.host = host
  }
}

public enum WatchRequest: Decodable, Hashable, Sendable {
  case question(Question)
  case permission(Permission)

  public struct Option: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var recommended: Bool?
  }

  public struct Field: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var options: [Option]
    public var multiple: Bool
    public var allowText: Bool
    /// Recommended options first, keeping the backend's order otherwise.
    public var orderedOptions: [Option] {
      options.filter { $0.recommended == true } + options.filter { $0.recommended != true }
    }
  }

  public struct Question: Codable, Hashable, Sendable {
    public var requestID: String
    public var sessionID: String
    public var title: String
    public var project: String
    public var since: Double
    public var questions: [Field]
  }

  public struct Permission: Codable, Hashable, Sendable {
    public var requestID: String
    public var sessionID: String
    public var title: String
    public var project: String
    public var since: Double
    public var action: String
    public var resources: [String]
    public var summary: String
  }

  private enum Keys: String, CodingKey { case kind }

  public init(from decoder: any Decoder) throws {
    let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
    switch kind {
    case "question": self = .question(try Question(from: decoder))
    case "permission": self = .permission(try Permission(from: decoder))
    default:
      throw DecodingError.dataCorrupted(.init(codingPath: [Keys.kind], debugDescription: "Unknown kind \(kind)"))
    }
  }

  public var requestID: String {
    switch self {
    case .question(let value): value.requestID
    case .permission(let value): value.requestID
    }
  }
  public var title: String {
    switch self {
    case .question(let value): value.title
    case .permission(let value): value.title
    }
  }
  public var project: String {
    switch self {
    case .question(let value): value.project
    case .permission(let value): value.project
    }
  }
  public var asked: Date {
    switch self {
    case .question(let value): Date(timeIntervalSince1970: value.since / 1000)
    case .permission(let value): Date(timeIntervalSince1970: value.since / 1000)
    }
  }
  /// An unsupported form arrives as a question with no fields: the watch offers "Abrir no iPhone".
  public var answerableOnWatch: Bool {
    if case .question(let value) = self { return !value.questions.isEmpty }
    return true
  }
}

public enum WatchReply: Encodable, Hashable, Sendable {
  case question([Answer])
  case permission(Decision)

  public struct Answer: Encodable, Hashable, Sendable {
    public var questionID: String
    public var optionIDs: [String]?
    public var text: String?
    public init(questionID: String, optionIDs: [String]? = nil, text: String? = nil) {
      self.questionID = questionID
      self.optionIDs = optionIDs
      self.text = text
    }
  }

  public enum Decision: String, Encodable, Hashable, Sendable { case once, always, reject }

  private enum Keys: String, CodingKey { case kind, answers, decision }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case .question(let answers):
      try container.encode("question", forKey: .kind)
      try container.encode(answers, forKey: .answers)
    case .permission(let decision):
      try container.encode("permission", forKey: .kind)
      try container.encode(decision, forKey: .decision)
    }
  }
}

public struct WatchVoiceCall: Decodable, Hashable, Sendable {
  public var callID: String
  public var sdp: String
  public var leaseSeconds: Double
}

public struct WatchVoiceEvent: Decodable, Hashable, Sendable {
  public var seq: Int
  public var at: Double
  public var kind: Kind

  public enum Role: String, Decodable, Hashable, Sendable { case user, assistant }

  public enum Kind: Hashable, Sendable {
    case status(String, reason: String?)
    case caption(role: Role, text: String, final: Bool)
    case master(running: Bool, text: String)
    case error(code: String, message: String)
    /// A newer backend may add event types; they are ignored, not fatal.
    case unknown(String)
  }

  private enum Keys: String, CodingKey { case seq, at, type, status, reason, role, text, final, state, code, message }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    seq = try container.decode(Int.self, forKey: .seq)
    at = try container.decode(Double.self, forKey: .at)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "status":
      kind = .status(try container.decode(String.self, forKey: .status),
        reason: try container.decodeIfPresent(String.self, forKey: .reason))
    case "caption":
      kind = .caption(role: try container.decode(Role.self, forKey: .role),
        text: try container.decode(String.self, forKey: .text), final: try container.decode(Bool.self, forKey: .final))
    case "master":
      kind = .master(running: try container.decode(String.self, forKey: .state) == "running",
        text: try container.decode(String.self, forKey: .text))
    case "error":
      kind = .error(code: try container.decode(String.self, forKey: .code),
        message: try container.decode(String.self, forKey: .message))
    default: kind = .unknown(type)
    }
  }
}

public struct WatchVoiceEvents: Decodable, Sendable {
  public var events: [WatchVoiceEvent]
  public var next: Int
  public var ended: Bool
}

/// Gateway failures, already classified for the UI.
public enum WatchGatewayError: Error, Equatable, Sendable {
  /// Unknown, revoked or malformed device token (401): the watch must be paired again.
  case unauthorized
  /// The request is no longer pending (404) or was already answered (409).
  case gone
  case rateLimited
  /// The Mac (or the tunnel) did not answer: offline, timeout, Cloudflare error page.
  case unreachable
  case server(status: Int, code: String?, message: String?)

  public var message: String {
    switch self {
    case .unauthorized: "Pareamento expirado. Abra o OpenCode no iPhone para parear de novo."
    case .gone: "Esse pedido já foi respondido."
    case .rateLimited: "Muitas requisições. Tente de novo em instantes."
    case .unreachable: "Mac indisponível."
    case .server(_, _, let message): message ?? "O servidor recusou o pedido."
    }
  }
}
