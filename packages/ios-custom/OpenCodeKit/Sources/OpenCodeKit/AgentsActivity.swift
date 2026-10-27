import Foundation

/// Content state of the "Agentes" Live Activity, contract v1 of `custom.live-activity`
/// (`packages/plugin-app-custom/docs/live-activity.md`). Times are epoch milliseconds: ActivityKit decodes push
/// `Date`s with its own reference date, so they stay numbers on the wire and become `Date`s only here.
public struct AgentsState: Codable, Hashable, Sendable {
  public var v: Int
  public var updatedAt: Double
  public var host: String
  public var counts: Counts
  public var activeTotal: Int
  public var focus: Focus?
  public var attention: [Attention]
  public var attentionTotal: Int
  public var sessions: [Row]

  public struct Counts: Codable, Hashable, Sendable {
    public var working: Int
    public var question: Int
    public var permission: Int
    public var failed: Int
    public var idle: Int
    public init(working: Int, question: Int, permission: Int, failed: Int, idle: Int) {
      self.working = working
      self.question = question
      self.permission = permission
      self.failed = failed
      self.idle = idle
    }
  }

  public struct Progress: Codable, Hashable, Sendable {
    public var done: Int
    public var total: Int
    /// `subagents` today; a future unit (such as `tasks`) renders as a bare `done/total`.
    public var unit: String
  }

  public struct Focus: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String
    public var project: String
    public var directory: String
    public var startedAt: Double
    public var activity: String?
    public var progress: Progress?
    public var started: Date { Date(timeIntervalSince1970: startedAt / 1000) }
  }

  public enum Kind: String, Codable, Hashable, Sendable {
    case question, permission, unknown
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  public struct Attention: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String
    public var project: String
    public var directory: String
    public var kind: Kind
    public var since: Double
    public var text: String?
    public var asked: Date { Date(timeIntervalSince1970: since / 1000) }
  }

  public enum Status: String, Codable, Hashable, Sendable {
    case question, permission, failed, working, idle, unknown
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  public struct Row: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String
    public var project: String
    public var directory: String
    public var status: Status
    public var progress: Progress?
  }

  public var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

/// Static attributes of the activity (`AgentsActivityAttributes` in the app and the widget extension).
public enum AgentsTheme {
  /// Roles sent in `attributes.theme`: the contract's required ones plus `info` for avatars.
  public static let roles: [ThemeRole] = [
    .background, .surface, .border, .textStrong, .text, .textSecondary, .textWeak, .primary, .success, .warning,
    .error, .accent, .info,
  ]
  public static func snapshot(_ color: (ThemeRole) -> ThemeColor) -> [String: String] {
    Dictionary(uniqueKeysWithValues: roles.map { ($0.name, hex(color($0))) })
  }
  public static func hex(_ color: ThemeColor) -> String {
    "#" + [color.red, color.green, color.blue, color.opacity]
      .map { String(format: "%02x", Int(($0 * 255).rounded()).clamped(0, 255)) }.joined()
  }
  public static func color(_ theme: [String: String], _ role: ThemeRole) -> ThemeColor? {
    theme[role.name].flatMap(ThemeColor.init(css:))
  }
  /// Stable avatar role per project, so a repository keeps its color across updates and activities.
  public static func avatar(_ project: String) -> ThemeRole {
    let palette: [ThemeRole] = [.primary, .info, .accent, .success, .warning]
    let hash = project.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    return palette[Int(hash % UInt64(palette.count))]
  }
}

extension Int {
  fileprivate func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

// MARK: Presentation

/// What the Dynamic Island's minimal presentation shows; the first match wins.
public enum AgentsMinimal: Equatable, Sendable {
  case failed(Int), question(Int), permission(Int), mascot
  public var role: ThemeRole {
    switch self {
    case .failed: .error
    case .question: .accent
    case .permission: .warning
    case .mascot: .success
    }
  }
  public var symbol: String? {
    switch self {
    case .failed: "exclamationmark"
    case .question: "questionmark"
    case .permission: "hand.raised.fill"
    case .mascot: nil
    }
  }
  public var count: Int? {
    switch self {
    case .failed(let count), .question(let count), .permission(let count): count
    case .mascot: nil
    }
  }
}

/// A run of text in one theme role, for headers and footers built from several colored parts.
public struct AgentsSegment: Equatable, Sendable {
  public let text: String
  public let role: ThemeRole
  public init(_ text: String, _ role: ThemeRole) {
    self.text = text
    self.role = role
  }
}

public struct AgentsFooterItem: Equatable, Sendable {
  public let count: Int
  public let label: String
  public let role: ThemeRole
  /// Idle sessions have no dot and use the secondary color throughout.
  public let dot: Bool
}

public extension AgentsState {
  var minimal: AgentsMinimal {
    if counts.failed > 0 { return .failed(counts.failed) }
    if counts.question > 0 { return .question(counts.question) }
    if counts.permission > 0 { return .permission(counts.permission) }
    return .mascot
  }

  /// Compact trailing: `attentionTotal/activeTotal` while something needs Alexandre, otherwise `activeTotal`.
  var compact: [AgentsSegment] {
    attentionTotal > 0
      ? [AgentsSegment("\(attentionTotal)", .warning), AgentsSegment("/\(activeTotal)", .textSecondary)]
      : [AgentsSegment("\(activeTotal)", .success)]
  }

  /// Expanded island header: `4 ativas · 1 precisa de você · 2 com erro`.
  var header: [AgentsSegment] {
    var parts = [AgentsSegment("\(activeTotal) \(activeTotal == 1 ? "ativa" : "ativas")", .textStrong)]
    if attentionTotal > 0 {
      parts.append(AgentsSegment(" · ", .textSecondary))
      parts.append(AgentsSegment("\(attentionTotal) \(attentionTotal == 1 ? "precisa" : "precisam") de você", .warning))
    }
    if counts.failed > 0 {
      parts.append(AgentsSegment(" · ", .textSecondary))
      parts.append(AgentsSegment("\(counts.failed) com erro", .error))
    }
    return parts
  }

  var footer: [AgentsFooterItem] {
    [
      AgentsFooterItem(count: counts.working, label: "trabalhando", role: .success, dot: true),
      AgentsFooterItem(count: counts.question, label: counts.question == 1 ? "pergunta" : "perguntas",
        role: .accent, dot: true),
      AgentsFooterItem(count: counts.permission, label: counts.permission == 1 ? "permissão" : "permissões",
        role: .warning, dot: true),
      AgentsFooterItem(count: counts.failed, label: "com erro", role: .error, dot: true),
      AgentsFooterItem(count: counts.idle, label: counts.idle == 1 ? "ociosa" : "ociosas",
        role: .textSecondary, dot: false),
    ].filter { $0.count > 0 }
  }

  /// The pending block uses the list layout when more than one request waits, even if the backend trimmed
  /// `attention` to a single item.
  var pendingList: Bool { attentionTotal > 1 || attention.count > 1 }

  var pendingTitle: String {
    if !pendingList {
      return attention.first?.kind == .permission ? "PERMISSÃO PENDENTE" : "PERGUNTA PENDENTE"
    }
    let total = max(attentionTotal, attention.count)
    let kinds = Set(attention.map(\.kind))
    if counts.question > 0 && counts.permission > 0 || kinds.count > 1 { return "\(total) PENDÊNCIAS" }
    return kinds == [.permission] ? "\(total) PERMISSÕES PENDENTES" : "\(total) PERGUNTAS PENDENTES"
  }

  /// Questions use `accent`; permissions and mixed lists use `warning`.
  var pendingRole: ThemeRole { Set(attention.map(\.kind)) == [.question] ? .accent : .warning }

  /// Session opened by tapping the Lock Screen card: the first attention item, else the focus, else none
  /// (the Sessões list).
  var tapTarget: (sessionID: String, directory: String)? {
    if let first = attention.first { return (first.sessionID, first.directory) }
    if let focus { return (focus.sessionID, focus.directory) }
    return nil
  }
}

public extension AgentsState.Kind {
  var role: ThemeRole { self == .permission ? .warning : .accent }
}

public extension AgentsState.Progress {
  /// `2/3 subagentes`; unknown units render as a bare `2/3`.
  var label: String { unit == "subagents" ? "\(done)/\(total) subagentes" : "\(done)/\(total)" }
  var fraction: Double { total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0 }
}

public extension AgentsState.Row {
  var statusLabel: String {
    switch status {
    case .question: "Pergunta"
    case .permission: "Permissão"
    case .failed: "Erro"
    case .working: progress.map { "Trabalhando · \($0.done)/\($0.total)" } ?? "Trabalhando"
    case .idle: "Concluída"
    case .unknown: ""
    }
  }
  var statusRole: ThemeRole {
    switch status {
    case .question: .accent
    case .permission: .warning
    case .failed: .error
    case .working: .success
    case .idle, .unknown: .textSecondary
    }
  }
}

/// The Apple Watch card's progress ring around the mascot.
public enum AgentsRing: Equatable, Sendable {
  /// One arc per subagent, the first `done` in `success` (at most `segmentLimit`).
  case segments(done: Int, total: Int)
  /// Above the segment limit: one continuous arc filled `done/total`.
  case continuous(Double)
  /// Working without subagent progress.
  case full
  /// Nothing working.
  case track

  public static let segmentLimit = 8
}

public extension AgentsState {
  var ring: AgentsRing {
    if let progress = focus?.progress, progress.total > 0 {
      return progress.total <= AgentsRing.segmentLimit
        ? .segments(done: min(max(progress.done, 0), progress.total), total: progress.total)
        : .continuous(progress.fraction)
    }
    return counts.working > 0 ? .full : .track
  }

  /// Badge below the ring: the minimal island's priority, none without attention or failure.
  var watchBadge: AgentsMinimal? { minimal == .mascot ? nil : minimal }

  /// The watch shows the first two rows; questions and permissions add `há N min` from their attention item.
  var watchRows: [AgentsState.Row] { Array(sessions.prefix(2)) }

  func asked(_ row: AgentsState.Row) -> Date? {
    guard row.status == .question || row.status == .permission else { return nil }
    let kind: Kind = row.status == .question ? .question : .permission
    return attention.first { $0.sessionID == row.sessionID && $0.kind == kind }?.asked
  }
}

public enum AgentsText {
  /// `há 3 min.` for a request asked at `since`, as a system style that keeps itself current without updates.
  public static func ago(since: Date) -> Date.AnchoredRelativeFormatStyle {
    Date.AnchoredRelativeFormatStyle(anchor: since, allowedFields: [.minute, .hour, .day], presentation: .named,
      unitsStyle: .abbreviated, locale: Locale(identifier: "pt_BR"))
  }
}

// MARK: Deep links

/// Links from the Live Activity into the app: one session, or the Sessões list, of the server identified by
/// `serverKey`.
public enum AgentsDeepLink: Equatable, Sendable {
  case session(serverKey: String, sessionID: String, directory: String)
  case sessions(serverKey: String)

  public static let scheme = "br.com.alexandrem.opencode"

  public var serverKey: String {
    switch self {
    case .session(let serverKey, _, _), .sessions(let serverKey): serverKey
    }
  }

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    switch self {
    case .session(let serverKey, let sessionID, let directory):
      components.host = "session"
      components.queryItems = [
        URLQueryItem(name: "server", value: serverKey), URLQueryItem(name: "id", value: sessionID),
        URLQueryItem(name: "directory", value: directory),
      ]
    case .sessions(let serverKey):
      components.host = "sessions"
      components.queryItems = [URLQueryItem(name: "server", value: serverKey)]
    }
    return components.url!
  }

  public init?(url: URL) {
    guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    guard let server = query["server"], !server.isEmpty else { return nil }
    switch components.host {
    case "session":
      guard let id = query["id"], !id.isEmpty else { return nil }
      self = .session(serverKey: server, sessionID: id, directory: query["directory"] ?? "")
    case "sessions": self = .sessions(serverKey: server)
    default: return nil
    }
  }

  public static func card(_ state: AgentsState, serverKey: String) -> AgentsDeepLink {
    state.tapTarget.map { .session(serverKey: serverKey, sessionID: $0.sessionID, directory: $0.directory) }
      ?? .sessions(serverKey: serverKey)
  }
}

// MARK: Duplicates

/// At most one activity per `serverKey` on screen, in any state (contract rev. 2026-10-27).
public enum AgentsDuplicates {
  public struct Candidate: Equatable, Sendable {
    public let id: String
    public let serverKey: String
    /// Active or stale; ended and dismissed activities are never kept.
    public let alive: Bool
    public let updatedAt: Double
    /// Order in which this process first saw the activity, as a tie breaker.
    public let sequence: Int
    public init(id: String, serverKey: String, alive: Bool, updatedAt: Double, sequence: Int) {
      self.id = id
      self.serverKey = serverKey
      self.alive = alive
      self.updatedAt = updatedAt
      self.sequence = sequence
    }
  }

  /// IDs to end with immediate dismissal: per server, every activity except the newest live one (latest
  /// `updatedAt`, then latest seen). Ended activities still on screen are always removed.
  public static func toEnd(_ candidates: [Candidate]) -> [String] {
    let keep = Dictionary(grouping: candidates.filter(\.alive), by: \.serverKey).compactMapValues { group in
      group.max { ($0.updatedAt, $0.sequence) < ($1.updatedAt, $1.sequence) }?.id
    }
    return candidates.filter { keep[$0.serverKey] != $0.id }.map(\.id)
  }
}

// MARK: Registration

/// APNs environment stored with the tokens: builds signed with a development profile (installed from Xcode) talk
/// to the sandbox; App Store Connect builds (TestFlight) have no embedded profile and use production.
public enum PushEnvironment: String, Codable, Sendable {
  case sandbox, production

  public static func resolve(profile: Data?, simulator: Bool) -> Self {
    if simulator { return .sandbox }
    guard let profile else { return .production }
    guard let start = profile.range(of: Data("<?xml".utf8)), let end = profile.range(of: Data("</plist>".utf8)),
      start.lowerBound < end.upperBound,
      let plist = try? PropertyListSerialization.propertyList(
        from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
    else { return .production }
    let entitlements = plist["Entitlements"] as? [String: Any]
    if let aps = entitlements?["aps-environment"] as? String { return aps == "development" ? .sandbox : .production }
    return entitlements?["get-task-allow"] as? Bool == true ? .sandbox : .production
  }
}

public struct AgentsRegistration: Encodable, Equatable, Sendable {
  public var deviceID: String
  public var serverKey: String
  public var environment: PushEnvironment
  public var theme: [String: String]
  public var pushToStartToken: String?
  public init(deviceID: String, serverKey: String, environment: PushEnvironment, theme: [String: String],
    pushToStartToken: String?)
  {
    self.deviceID = deviceID
    self.serverKey = serverKey
    self.environment = environment
    self.theme = theme
    self.pushToStartToken = pushToStartToken
  }
}

public enum AgentsPush: String, Decodable, Sendable { case configured, unconfigured }
public enum AgentsEndReason: String, Encodable, Sendable { case ended, dismissed }

/// `rpc.custom.live-activity.changed`: `state` is nil when nothing is working, waiting or failed.
public struct AgentsChange: Sendable, Equatable {
  public let state: AgentsState?
  public static let eventType = "rpc.custom.live-activity.changed"
  public static func decode(_ event: ConversationEvent) -> AgentsChange? {
    guard event.type == eventType else { return nil }
    guard let value = event.data.state, value != .null else { return AgentsChange(state: nil) }
    guard let state = try? value.decoded(as: AgentsState.self) else { return nil }
    return AgentsChange(state: state)
  }
}

public extension Data {
  /// APNs tokens travel as lowercase hex.
  var hexToken: String { map { String(format: "%02x", $0) }.joined() }
}

public extension OpenCodeClient {
  func liveActivityRegister(_ registration: AgentsRegistration) async throws -> AgentsPush {
    struct Output: Decodable { let push: AgentsPush }
    let output: Output = try await rpc("custom.live-activity", "register", input: registration, timeout: 8)
    return output.push
  }
  func liveActivityToken(deviceID: String, activityID: String, pushToken: String) async throws {
    struct Input: Encodable {
      let deviceID: String
      let activityID: String
      let pushToken: String
    }
    let _: JSONValue = try await rpc("custom.live-activity", "activity",
      input: Input(deviceID: deviceID, activityID: activityID, pushToken: pushToken), timeout: 8)
  }
  func liveActivityEnded(deviceID: String, activityID: String, reason: AgentsEndReason) async throws {
    struct Input: Encodable {
      let deviceID: String
      let activityID: String
      let reason: AgentsEndReason
    }
    let _: JSONValue = try await rpc("custom.live-activity", "ended",
      input: Input(deviceID: deviceID, activityID: activityID, reason: reason), timeout: 8)
  }
  func liveActivityUnregister(deviceID: String) async throws {
    struct Input: Encodable { let deviceID: String }
    let _: JSONValue = try await rpc("custom.live-activity", "unregister", input: Input(deviceID: deviceID), timeout: 8)
  }
  func liveActivitySnapshot() async throws -> AgentsState? {
    struct Output: Decodable { let state: AgentsState? }
    let output: Output = try await rpc("custom.live-activity", "snapshot", input: Empty(), timeout: 8)
    return output.state
  }
}

public enum AgentsSupport {
  /// A server without the RPC (before `custom:update`) answers one of these; the app then stays silent.
  public static func unsupported(_ error: any Error) -> Bool {
    if case ClientError.rpc(let type) = error, ["rpc.unavailable", "rpc.method_not_found"].contains(type) {
      return true
    }
    if case ClientError.http(404) = error { return true }
    return false
  }
}
