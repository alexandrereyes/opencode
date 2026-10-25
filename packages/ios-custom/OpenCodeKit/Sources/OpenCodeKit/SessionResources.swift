import Foundation

/// Simulators, emulators and browsers that agents use on the Mac, mirrored from the plugin contract
/// (`packages/plugin-app-custom/src/resources/rpc.ts` and `protocol.ts`; specification in
/// `packages/plugin-app-custom/docs/resources.md`). Unknown kinds and states decode instead of failing the list.
public enum ResourceKind: Codable, Hashable, Sendable {
  case iosSimulator, androidEmulator, chrome
  case unknown(String)
  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = switch value {
    case "ios-simulator": .iosSimulator
    case "android-emulator": .androidEmulator
    case "chrome": .chrome
    default: .unknown(value)
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
  public var rawValue: String {
    switch self {
    case .iosSimulator: "ios-simulator"
    case .androidEmulator: "android-emulator"
    case .chrome: "chrome"
    case .unknown(let value): value
    }
  }
  /// "Simulador iOS", as the lists caption it.
  public var title: String {
    switch self {
    case .iosSimulator: "Simulador iOS"
    case .androidEmulator: "Emulador Android"
    case .chrome: "Chrome"
    case .unknown: "Recurso"
    }
  }
}

public enum ResourceState: String, Codable, Hashable, Sendable {
  case user, agent, live, idle, stopped, gone
  public init(from decoder: any Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
  }
  public var label: String {
    switch self {
    case .user: "Você no controle"
    case .agent: "Agente usando"
    case .live: "Ao vivo"
    case .idle: "Livre"
    case .stopped: "Desligado"
    case .gone: "Encerrado"
    }
  }
  public var running: Bool { self != .stopped && self != .gone }
}

public struct ResourceOwner: Codable, Hashable, Sendable {
  public let sessionID: String
  public let rootSessionID: String
  public let agent: String?
  public init(sessionID: String, rootSessionID: String, agent: String? = nil) {
    self.sessionID = sessionID
    self.rootSessionID = rootSessionID
    self.agent = agent
  }
}

public struct ResourceMeta: Codable, Hashable, Sendable {
  public let kind: String
  /// iOS Simulator.
  public let udid: String?
  public let name: String?
  public let device: String?
  public let runtime: String?
  /// Android Emulator.
  public let serial: String?
  public let avd: String?
  public let consolePort: Int?
  public let grpcPort: Int?
  /// Chrome.
  public let session: String?
  public let cdp: String?
  public let targetID: String?
  public let url: String?
  public let title: String?
  public init(
    kind: String, udid: String? = nil, name: String? = nil, device: String? = nil, runtime: String? = nil,
    serial: String? = nil, avd: String? = nil, consolePort: Int? = nil, grpcPort: Int? = nil,
    session: String? = nil, cdp: String? = nil, targetID: String? = nil, url: String? = nil, title: String? = nil
  ) {
    self.kind = kind
    self.udid = udid
    self.name = name
    self.device = device
    self.runtime = runtime
    self.serial = serial
    self.avd = avd
    self.consolePort = consolePort
    self.grpcPort = grpcPort
    self.session = session
    self.cdp = cdp
    self.targetID = targetID
    self.url = url
    self.title = title
  }
}

public struct ResourceControl: Codable, Hashable, Sendable {
  public let holder: String
  public let since: Double
  public let expiresAt: Double
}

public struct SessionResource: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let kind: ResourceKind
  public let label: String
  public let purpose: String?
  public let owner: ResourceOwner?
  public let state: ResourceState
  public let control: ResourceControl?
  public let meta: ResourceMeta
  public let discoveredAt: Double
  public let lastUsedAt: Double
  public let updatedAt: Double
  public let live: Live
  public struct Live: Codable, Hashable, Sendable {
    public let stream: Bool
    public let input: Bool
    public init(stream: Bool, input: Bool) {
      self.stream = stream
      self.input = input
    }
  }
  public init(
    id: String, kind: ResourceKind, label: String, purpose: String? = nil, owner: ResourceOwner? = nil,
    state: ResourceState, control: ResourceControl? = nil, meta: ResourceMeta, discoveredAt: Double = 0,
    lastUsedAt: Double = 0, updatedAt: Double = 0, live: Live = .init(stream: false, input: false)
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.purpose = purpose
    self.owner = owner
    self.state = state
    self.control = control
    self.meta = meta
    self.discoveredAt = discoveredAt
    self.lastUsedAt = lastUsedAt
    self.updatedAt = updatedAt
    self.live = live
  }
  /// The subagent session that used it, when it is not the family's root.
  public var via: String? {
    guard let owner, owner.sessionID != owner.rootSessionID else { return nil }
    return owner.sessionID
  }
}

public struct ResourceTicket: Codable, Hashable, Sendable {
  public let ticket: String
  public let expiresAt: Double
  /// `/resources/<encoded id>` relative to the hub origin.
  public let path: String
  public let loopbackPort: Int
}

public struct ResourceSnapshot: Codable, Hashable, Sendable {
  public let mime: String
  public let data: String
  public let takenAt: Double
  public let width: Int?
  public let height: Int?
  public var image: Data? { Data(base64Encoded: data) }
}

/// Input events, normalized to the streamed frame (0…1, origin top left). Text is never logged.
public enum ResourceInput: Encodable, Hashable, Sendable {
  public enum Phase: String, Encodable, Sendable { case began, moved, ended, cancelled }
  case touch(Phase, x: Double, y: Double, pointer: Int = 0)
  case scroll(x: Double, y: Double, dx: Double, dy: Double)
  case key(String, modifiers: [String] = [])
  case text(String)
  case button(String)
  case navigate(String, url: String? = nil)

  private enum Keys: String, CodingKey { case type, phase, x, y, pointer, dx, dy, key, modifiers, text, button, action, url }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case .touch(let phase, let x, let y, let pointer):
      try container.encode("touch", forKey: .type)
      try container.encode(phase, forKey: .phase)
      try container.encode(Self.unit(x), forKey: .x)
      try container.encode(Self.unit(y), forKey: .y)
      if pointer != 0 { try container.encode(pointer, forKey: .pointer) }
    case .scroll(let x, let y, let dx, let dy):
      try container.encode("scroll", forKey: .type)
      try container.encode(Self.unit(x), forKey: .x)
      try container.encode(Self.unit(y), forKey: .y)
      try container.encode(max(-10, min(10, dx)), forKey: .dx)
      try container.encode(max(-10, min(10, dy)), forKey: .dy)
    case .key(let key, let modifiers):
      try container.encode("key", forKey: .type)
      try container.encode(key, forKey: .key)
      if !modifiers.isEmpty { try container.encode(modifiers, forKey: .modifiers) }
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .button(let button):
      try container.encode("button", forKey: .type)
      try container.encode(button, forKey: .button)
    case .navigate(let action, let url):
      try container.encode("navigate", forKey: .type)
      try container.encode(action, forKey: .action)
      try container.encodeIfPresent(url, forKey: .url)
    }
  }
  private static func unit(_ value: Double) -> Double { max(0, min(1, value)) }
}

/// Hub → client text messages on `/stream`.
public enum ResourceServerMessage: Decodable, Sendable, Equatable {
  case hello(format: String, width: Int, height: Int, scale: Double?, codec: String?)
  case pong(t: Double, hub: Double)
  case control(holder: String?, expiresAt: Double?, mine: Bool)
  case meta([String: JSONValue])
  case error(String)
  case end(String)
  case unknown(String)

  private enum Keys: String, CodingKey {
    case type, format, width, height, scale, codec, t, hub, holder, expiresAt, mine, value, message, reason
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Keys.self)
    let type = try values.decode(String.self, forKey: .type)
    switch type {
    case "hello":
      self = .hello(
        format: try values.decode(String.self, forKey: .format), width: try values.decode(Int.self, forKey: .width),
        height: try values.decode(Int.self, forKey: .height),
        scale: try values.decodeIfPresent(Double.self, forKey: .scale),
        codec: try values.decodeIfPresent(String.self, forKey: .codec))
    case "pong": self = .pong(t: try values.decode(Double.self, forKey: .t), hub: try values.decode(Double.self, forKey: .hub))
    case "control":
      self = .control(
        holder: try values.decodeIfPresent(String.self, forKey: .holder),
        expiresAt: try values.decodeIfPresent(Double.self, forKey: .expiresAt),
        mine: try values.decodeIfPresent(Bool.self, forKey: .mine) ?? false)
    case "meta": self = .meta(try values.decodeIfPresent([String: JSONValue].self, forKey: .value) ?? [:])
    case "error": self = .error(try values.decodeIfPresent(String.self, forKey: .message) ?? "")
    case "end": self = .end(try values.decodeIfPresent(String.self, forKey: .reason) ?? "")
    default: self = .unknown(type)
    }
  }
}

/// Binary stream frame: u8 version (1), u8 flags (bit 0 keyframe), f64 big-endian capture time (epoch ms), payload.
public struct ResourceFrame: Sendable, Equatable {
  public let keyframe: Bool
  public let capturedAt: Double
  public let payload: Data
  public static let headerBytes = 10
  public init?(_ data: Data) {
    guard data.count >= Self.headerBytes else { return nil }
    let bytes = [UInt8](data.prefix(Self.headerBytes))
    guard bytes[0] == 1 else { return nil }
    keyframe = bytes[1] & 1 == 1
    capturedAt = Double(bitPattern: bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    payload = data.dropFirst(Self.headerBytes)
  }
}

/// `opencode-resource:<id>` links that the plugin appends to tool results.
public enum ResourceLink {
  public static let scheme = "opencode-resource"
  public static func url(for id: String) -> URL? {
    URL(string: "\(scheme):\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id)")
  }
  public static func id(from url: URL) -> String? {
    guard url.scheme == scheme else { return nil }
    let raw = url.absoluteString.dropFirst(scheme.count + 1)
    let id = String(raw).removingPercentEncoding ?? String(raw)
    return id.isEmpty ? nil : id
  }
}

public enum ResourceControlAction: String, Encodable, Sendable { case take, renew, release }

extension OpenCodeClient {
  public static let resourcesChangedEvent = "rpc.custom.resources.changed"

  /// Resources of one session family (`sessionID` is its root), or all of them.
  public func resources(sessionID: String? = nil) async throws -> [SessionResource] {
    struct Input: Encodable { let sessionID: String? }
    struct Output: Decodable { let resources: [SessionResource] }
    let output: Output = try await rpc("custom.resources", "list", input: Input(sessionID: sessionID))
    return output.resources
  }
  public func resource(_ id: String) async throws -> SessionResource {
    struct Input: Encodable { let id: String }
    return try await rpc("custom.resources", "get", input: Input(id: id))
  }
  public func resourceSnapshot(_ id: String, maxWidth: Int? = nil) async throws -> ResourceSnapshot {
    struct Input: Encodable { let id: String; let maxWidth: Int? }
    return try await rpc("custom.resources", "snapshot", input: Input(id: id, maxWidth: maxWidth), timeout: 20)
  }
  public func resourceTicket(_ id: String) async throws -> ResourceTicket {
    struct Input: Encodable { let id: String }
    return try await rpc("custom.resources", "ticket", input: Input(id: id))
  }
  public func resourceControl(_ id: String, _ action: ResourceControlAction) async throws
    -> (resource: SessionResource, ticket: ResourceTicket?)
  {
    struct Input: Encodable { let id: String; let action: ResourceControlAction }
    struct Output: Decodable { let resource: SessionResource; let ticket: ResourceTicket? }
    let output: Output = try await rpc("custom.resources", "control", input: Input(id: id, action: action))
    return (output.resource, output.ticket)
  }
  public func dismissResource(_ id: String) async throws {
    struct Input: Encodable { let id: String }
    let _: Empty = try await rpc("custom.resources", "dismiss", input: Input(id: id))
  }

  /// Hub URL for a ticket: the server's own origin (the Mac's 4096 proxy forwards `/resources/*`), or the hub's
  /// loopback port when the server itself is on loopback (simulators and tests against a sandbox).
  public func resourceURL(_ ticket: ResourceTicket, _ action: String, websocket: Bool = false) -> URL? {
    guard var components = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false) else { return nil }
    if Self.loopback(components.host), ticket.loopbackPort > 0 {
      components.host = "127.0.0.1"
      components.port = ticket.loopbackPort
      components.percentEncodedPath = ""
    }
    let secure = components.scheme == "https"
    if websocket { components.scheme = secure ? "wss" : "ws" }
    let base = components.percentEncodedPath.hasSuffix("/")
      ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
    components.percentEncodedPath = base + ticket.path + "/" + action
    components.queryItems = [URLQueryItem(name: "ticket", value: ticket.ticket)]
    return components.url
  }
  static func loopback(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
  }
}
