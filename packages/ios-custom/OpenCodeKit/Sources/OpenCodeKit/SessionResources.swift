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
  /// "Simulador", for the viewer's compact status pill.
  public var short: String {
    switch self {
    case .iosSimulator: "Simulador"
    case .androidEmulator: "Android"
    case .chrome: "Chrome"
    case .unknown: "Recurso"
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
  public let workspace: String?
  public let cdp: String?
  public let targetID: String?
  public let url: String?
  public let title: String?
  public init(
    kind: String, udid: String? = nil, name: String? = nil, device: String? = nil, runtime: String? = nil,
    serial: String? = nil, avd: String? = nil, consolePort: Int? = nil, grpcPort: Int? = nil,
    session: String? = nil, workspace: String? = nil, cdp: String? = nil, targetID: String? = nil, url: String? = nil, title: String? = nil
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
    self.workspace = workspace
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

/// One agent shell command that named a resource (rev. 2026-10-30; `docs/resources.md` "Activity").
public struct ResourceActivity: Codable, Hashable, Sendable {
  /// When it started (or, for one first seen in its result, when it ended), epoch ms.
  public let at: Double
  /// The command, without leading assignments, on one line, at most 160 characters.
  public let command: String
  public let sessionID: String?
  public let agent: String?
  /// Still running: the resource stays "Agente usando" until it ends.
  public let running: Bool?
  public init(at: Double, command: String, sessionID: String? = nil, agent: String? = nil, running: Bool? = nil) {
    self.at = at
    self.command = command
    self.sessionID = sessionID
    self.agent = agent
    self.running = running
  }
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
  /// The agents' latest commands on it, newest first; absent on older servers and until one names it.
  public let activity: [ResourceActivity]?
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
    lastUsedAt: Double = 0, updatedAt: Double = 0, live: Live = .init(stream: false, input: false),
    activity: [ResourceActivity]? = nil
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
    self.activity = activity
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
  /// Chrome: follow another tab (a `tabs` entry of the viewer's `meta`).
  case selectTab(String)

  private enum Keys: String, CodingKey {
    case type, phase, x, y, pointer, dx, dy, key, modifiers, text, button, action, url, target
  }
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
    case .selectTab(let target):
      try container.encode("navigate", forKey: .type)
      try container.encode("tab", forKey: .action)
      try container.encode(target, forKey: .target)
    }
  }
  private static func unit(_ value: Double) -> Double { max(0, min(1, value)) }
}

/// Hub → client text messages on `/stream`. `features` (first, newer hubs only) says which optional client
/// messages the hub understands; `stats` reports this viewer's delivery every few seconds; `notice` is an adapter's
/// diagnosis to show discreetly.
public enum ResourceServerMessage: Decodable, Sendable, Equatable {
  case features(ack: Bool, auth: Bool, profiles: [String])
  case hello(format: String, width: Int, height: Int, scale: Double?, codec: String?)
  case pong(t: Double, hub: Double)
  case control(holder: String?, expiresAt: Double?, mine: Bool)
  case meta([String: JSONValue])
  case stats(ResourceDeliveryStats)
  case notice(String)
  case error(String)
  case end(String)
  case unknown(String)

  private enum Keys: String, CodingKey {
    case type, format, width, height, scale, codec, t, hub, holder, expiresAt, mine, value, message, reason
    case ack, auth, profiles
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Keys.self)
    let type = try values.decode(String.self, forKey: .type)
    switch type {
    case "features":
      self = .features(
        ack: try values.decodeIfPresent(Bool.self, forKey: .ack) ?? false,
        auth: try values.decodeIfPresent(Bool.self, forKey: .auth) ?? false,
        profiles: try values.decodeIfPresent([String].self, forKey: .profiles) ?? [])
    case "stats": self = .stats(try ResourceDeliveryStats(from: decoder))
    case "notice": self = .notice(try values.decodeIfPresent(String.self, forKey: .message) ?? "")
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

/// The hub's per-viewer delivery report (`stats`): frames and bytes sent, held-back frames replaced by newer ones,
/// frames dropped, frames in flight and, when the adapter reports capture times, the capture → hub age.
public struct ResourceDeliveryStats: Decodable, Sendable, Equatable {
  public struct Capture: Decodable, Sendable, Equatable {
    public let p50: Double
    public let p95: Double
  }
  public let hub: Double
  public let capture: Capture?
  public let frames: Int
  public let bytes: Int
  public let replaced: Int
  public let dropped: Int
  public let inFlight: Int?
}

/// Client → hub text messages on `/stream`. `ack`, `profile` and `auth` go only to hubs whose `features` list them.
public enum ResourceClientMessage: Encodable, Sendable, Equatable {
  case ping(t: Double)
  case input([ResourceInput])
  /// Frames received on this connection so far.
  case ack(Int)
  /// `standard` or `economy`.
  case profile(String)
  /// Swaps this socket's ticket (a control ticket after taking control) without reconnecting.
  case auth(String)

  private enum Keys: String, CodingKey { case type, t, events, n, value, ticket }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case .ping(let t):
      try container.encode("ping", forKey: .type)
      try container.encode(t, forKey: .t)
    case .input(let events):
      try container.encode("input", forKey: .type)
      try container.encode(events, forKey: .events)
    case .ack(let count):
      try container.encode("ack", forKey: .type)
      try container.encode(count, forKey: .n)
    case .profile(let value):
      try container.encode("profile", forKey: .type)
      try container.encode(value, forKey: .value)
    case .auth(let ticket):
      try container.encode("auth", forKey: .type)
      try container.encode(ticket, forKey: .ticket)
    }
  }
  public var text: String? {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
  }
}

/// What the viewer measures about its stream, with the hub's clock offset from ping/pong, so frame ages compare the
/// capture time (Mac clock) with this device's clock.
///
/// - `offset`: hub clock − device clock, from the pong with the shortest round trip (`hub` minus the round trip's
///   midpoint), which bounds the error by half that round trip.
/// - Per frame: arrival age (capture → received here, including capture → hub), decode time and presentation age
///   (capture → on screen). Ages are kept for the last `window` seconds.
public struct ResourceStreamTelemetry: Sendable, Equatable {
  public private(set) var roundTrip: Double?
  public private(set) var offset: Double?
  private var bestRoundTrip = Double.infinity
  private var samples: [Sample] = []
  public private(set) var delivery: ResourceDeliveryStats?
  public var window: Double = 2

  struct Sample: Sendable, Equatable {
    let at: Double
    let bytes: Int
    let arrival: Double?
    let decode: Double
    let presentation: Double?
  }

  public init() {}

  /// `sent` and `received` on this device's clock (epoch ms); `hub` on the hub's.
  public mutating func pong(sent: Double, hub: Double, received: Double) {
    let trip = max(0, received - sent)
    roundTrip = trip
    // The offset from a fast round trip is the most precise; refresh it when a comparably fast one arrives.
    guard trip <= bestRoundTrip * 1.5 + 5 else { return }
    bestRoundTrip = min(bestRoundTrip, trip)
    offset = hub - (sent + received) / 2
  }

  /// One frame: `captured` on the hub clock, `received`/`presented` on this device's (epoch ms).
  public mutating func frame(bytes: Int, captured: Double, received: Double, presented: Double) {
    let offset = offset
    let age = { (local: Double) in offset.map { max(0, local + $0 - captured) } }
    samples.append(
      Sample(at: presented, bytes: bytes, arrival: age(received), decode: presented - received, presentation: age(presented)))
    samples.removeAll { $0.at < presented - window * 1000 }
  }

  public mutating func report(_ stats: ResourceDeliveryStats) { delivery = stats }

  /// Median capture → on-screen age over the window, once the clock offset is known.
  public var presentationAge: Double? { Self.median(samples.compactMap(\.presentation)) }
  public var arrivalAge: Double? { Self.median(samples.compactMap(\.arrival)) }
  public var decodeTime: Double? { Self.median(samples.map(\.decode)) }
  public var framesPerSecond: Double { Double(samples.count) / window }
  public var kilobytesPerSecond: Double { Double(samples.reduce(0) { $0 + $1.bytes }) / 1024 / window }
  /// Whether a frame was presented within the window before `now` (a still screen sends none, which is fine).
  public func flowing(now: Double) -> Bool { samples.last.map { now - $0.at < window * 1000 } ?? false }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
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
