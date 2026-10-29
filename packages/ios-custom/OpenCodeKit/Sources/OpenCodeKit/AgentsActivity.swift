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
  /// Everything that needs Alexandre, in order (rev. 2026-10-29); absent from older backends (see `needItems`).
  public var needs: [Need]?

  public struct Counts: Codable, Hashable, Sendable {
    public var working: Int
    public var question: Int
    public var permission: Int
    public var failed: Int
    /// Finished successfully in the last 30 minutes; only shown when `unread` is absent (older backends).
    public var idle: Int
    /// Finished with output not yet viewed (rev. 2026-10-28); absent from older backends.
    public var unread: Int?
    public init(working: Int, question: Int, permission: Int, failed: Int, idle: Int, unread: Int? = nil) {
      self.working = working
      self.question = question
      self.permission = permission
      self.failed = failed
      self.idle = idle
      self.unread = unread
    }

    /// The fifth count of rings and counters: unread sessions (orange `primary`), or, from an older backend
    /// without `unread`, the recently finished ones (gray).
    public var finished: Finished {
      unread.map { Finished(count: $0, unread: true) } ?? Finished(count: idle, unread: false)
    }

    /// "N para você": the sessions that need Alexandre, one each by the backend's precedence, the same rule as
    /// Sessões' "Precisa de você" (`SessionAttention`). Older backends without `unread` count requests and failures.
    public var forYou: Int { question + permission + failed + (unread ?? 0) }
  }

  public struct Finished: Equatable, Sendable {
    public let count: Int
    /// `true` for unread sessions; `false` for the `idle` fallback.
    public let unread: Bool
    public var role: ThemeRole { unread ? .primary : .textSecondary }
    public var label: String {
      unread ? (count == 1 ? "não lida" : "não lidas") : (count == 1 ? "concluída há pouco" : "concluídas há pouco")
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
    /// Watch gateway only (not in the Live Activity contract): the oldest pending request of this kind, which
    /// the watch opens with `/watch/v1/requests/:requestID`. Absent from Live Activity pushes.
    public var requestID: String?
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

  public enum NeedKind: String, Codable, Hashable, Sendable {
    case question, permission, failed, unread, unknown
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  /// One session that needs Alexandre: a pending request, a failure or an unread answer.
  public struct Need: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String
    public var project: String
    public var directory: String
    public var kind: NeedKind
    /// When it started needing him (asked, failed, answered); nil when built from an older backend's rows.
    public var since: Double?
    public var date: Date? { since.map { Date(timeIntervalSince1970: $0 / 1000) } }
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

/// One counter line of the Lock Screen card: coloured dot, number and label.
public struct AgentsCounter: Equatable, Sendable {
  public let count: Int
  public let label: String
  public let role: ThemeRole
  /// Recently finished sessions use plain secondary text; the others a bold number and label.
  public let emphasized: Bool
}

/// One arc of the Lock Screen ring, as fractions of the circle clockwise from 12 o'clock.
public struct AgentsGaugeArc: Equatable, Sendable {
  public let role: ThemeRole
  /// Recently finished sessions draw at reduced opacity.
  public let dim: Bool
  public let from: Double
  public let to: Double
}

/// The Lock Screen card's bottom line: the first session that needs Alexandre and how many others do.
public struct AgentsAttentionLine: Equatable, Sendable {
  public let role: ThemeRole
  public let title: String
  /// `pergunta`, `permissão`, `erro` or `respondeu`.
  public let kind: String
  /// Nil from an older backend's failed or unread rows, which carry no time.
  public let since: Date?
  /// `+K`: the others that need him, when there are any.
  public let more: Int?
}

public extension AgentsState.NeedKind {
  var role: ThemeRole {
    switch self {
    case .question: .accent
    case .permission: .warning
    case .failed: .error
    case .unread: .primary
    case .unknown: .textSecondary
    }
  }
  /// The list's words: `pergunta`, `permissão`, `erro`, `respondeu`.
  var label: String {
    switch self {
    case .question: "pergunta"
    case .permission: "permissão"
    case .failed: "erro"
    case .unread: "respondeu"
    case .unknown: ""
    }
  }
  /// The matching row status, for the views that draw rows.
  var status: AgentsState.Status {
    switch self {
    case .question: .question
    case .permission: .permission
    case .failed: .failed
    case .unread: .idle
    case .unknown: .unknown
    }
  }
}

public extension AgentsState {
  /// Option A (29/10): attention first. `counts.forYou`, the same number as Sessões' "Precisa de você".
  var forYou: Int { counts.forYou }

  /// What needs Alexandre, in order: the backend's `needs`, or from an older one its requests (oldest first), then
  /// the other rows that need him (requests without an attention item, failures, unread answers), without times.
  var needItems: [Need] {
    if let needs { return needs }
    let requests = attention.map {
      Need(sessionID: $0.sessionID, title: $0.title, project: $0.project, directory: $0.directory,
        kind: $0.kind == .permission ? .permission : .question, since: $0.since)
    }
    let listed = Set(requests.map { "\($0.kind.rawValue)|\($0.sessionID)" })
    let rows = sessions.compactMap { row -> Need? in
      let kind: NeedKind? =
        switch row.status {
        case .question: .question
        case .permission: .permission
        case .failed: .failed
        case .idle: counts.unread == nil ? nil : .unread
        case .working, .unknown: nil
        }
      guard let kind, !listed.contains("\(kind.rawValue)|\(row.sessionID)") else { return nil }
      return Need(sessionID: row.sessionID, title: row.title, project: row.project, directory: row.directory, kind: kind)
    }
    return requests + rows
  }

  var minimal: AgentsMinimal {
    if counts.failed > 0 { return .failed(counts.failed) }
    if counts.question > 0 { return .question(counts.question) }
    if counts.permission > 0 { return .permission(counts.permission) }
    return .mascot
  }

  /// Compact trailing: `forYou` while something needs Alexandre (the view fills a pill with its role), otherwise
  /// `activeTotal`.
  var compact: [AgentsSegment] {
    forYou > 0 ? [AgentsSegment("\(forYou)", .primary)] : [AgentsSegment("\(activeTotal)", .success)]
  }

  /// Expanded island header: `4 para você · 6 trabalhando`, or `4 ativas` when nothing needs Alexandre.
  var header: [AgentsSegment] {
    guard forYou > 0 else { return [AgentsSegment("\(activeTotal) \(activeTotal == 1 ? "ativa" : "ativas")", .textStrong)] }
    var parts = [AgentsSegment("\(forYou) para você", .primary)]
    if counts.working > 0 {
      parts.append(AgentsSegment(" · \(counts.working) trabalhando", .textSecondary))
    }
    return parts
  }

  /// The ring's arcs, proportional to the counts, with `gap` (a fraction of the circle) between them. While
  /// something needs Alexandre only those counts draw (question, permission, failed, unread); otherwise the contract
  /// order (working, then the `idle` fallback of older backends). A single non-zero count closes the circle; none
  /// draws no arc (the view shows only the track).
  func gauge(gap: Double) -> [AgentsGaugeArc] {
    let attention: [(Int, ThemeRole, Bool)] = [
      (counts.question, .accent, false), (counts.permission, .warning, false), (counts.failed, .error, false),
      (counts.unread ?? 0, .primary, false),
    ]
    let parts = (forYou > 0 ? attention : [
      (counts.working, .success, false), (counts.question, .accent, false), (counts.permission, .warning, false),
      (counts.failed, .error, false), (counts.finished.count, counts.finished.role, !counts.finished.unread),
    ]).filter { $0.0 > 0 }
    let total = Double(parts.reduce(0) { $0 + $1.0 })
    guard total > 0 else { return [] }
    if parts.count == 1 { return [AgentsGaugeArc(role: parts[0].1, dim: parts[0].2, from: 0, to: 1)] }
    var start = 0.0
    return parts.map { count, role, dim in
      let end = start + Double(count) / total
      defer { start = end }
      let from = start + gap / 2
      return AgentsGaugeArc(role: role, dim: dim, from: from, to: max(from, end - gap / 2))
    }
  }

  /// The ring's centre: `N para você` while something needs Alexandre, otherwise `N ativas`.
  var gaugeNumber: Int { forYou > 0 ? forYou : activeTotal }
  var gaugeLabel: String { forYou > 0 ? "para você" : activeTotal == 1 ? "ativa" : "ativas" }

  /// One line per non-zero count, at most `AgentsLayout.lockMaxCounters`. While something needs Alexandre those
  /// lines come first and `trabalhando` follows in gray, dropped first when they do not fit; otherwise the contract
  /// order, where `não lidas` (or the `concluídas há pouco` fallback) is dropped first.
  var counters: [AgentsCounter] {
    let question = AgentsCounter(count: counts.question, label: counts.question == 1 ? "pergunta" : "perguntas",
      role: .accent, emphasized: true)
    let permission = AgentsCounter(count: counts.permission,
      label: counts.permission == 1 ? "permissão" : "permissões", role: .warning, emphasized: true)
    let failed = AgentsCounter(count: counts.failed, label: "com erro", role: .error, emphasized: true)
    let finished = AgentsCounter(count: counts.finished.count, label: counts.finished.label,
      role: counts.finished.role, emphasized: forYou > 0 && counts.finished.unread)
    guard forYou > 0 else {
      let all = [
        AgentsCounter(count: counts.working, label: "trabalhando", role: .success, emphasized: true), question,
        permission, failed, finished,
      ].filter { $0.count > 0 }
      return all.count > AgentsLayout.lockMaxCounters ? all.filter(\.emphasized) : all
    }
    let working = AgentsCounter(count: counts.working, label: "trabalhando", role: .textSecondary, emphasized: false)
    let lines = counts.finished.unread
      ? [question, permission, failed, finished, working] : [question, permission, failed, working, finished]
    return Array(lines.filter { $0.count > 0 }.prefix(AgentsLayout.lockMaxCounters))
  }

  /// The first session that needs Alexandre, with `+K` for the others; none when nothing does.
  var attentionLine: AgentsAttentionLine? {
    let items = needItems
    guard let first = items.first else { return nil }
    let others = max(forYou, items.count) - 1
    return AgentsAttentionLine(role: first.kind.role, title: first.title, kind: first.kind.label, since: first.date,
      more: others > 0 ? others : nil)
  }

  /// Session opened by tapping the Lock Screen card: the first that needs Alexandre, else the focus, else none
  /// (the Sessões list).
  var tapTarget: (sessionID: String, directory: String)? {
    if let first = needItems.first { return (first.sessionID, first.directory) }
    if let focus { return (focus.sessionID, focus.directory) }
    return nil
  }

  /// The expanded island's rows: the first two that need Alexandre, or the sessions when nothing does.
  var islandRows: [Row] {
    let items = needItems
    return forYou > 0 && !items.isEmpty ? items.prefix(2).map(\.row) : sessions
  }

  /// What the island's rows stand for, so its `+N` counts the ones they leave out.
  var islandTotal: Int {
    let items = needItems
    return forYou > 0 && !items.isEmpty ? max(forYou, items.count) : sessions.count
  }
}

public extension AgentsState.Need {
  var row: AgentsState.Row {
    AgentsState.Row(sessionID: sessionID, title: title, project: project, directory: directory, status: kind.status)
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

public extension AgentsState {
  /// Row status text and colour. `idle` rows are unread sessions on backends that send `counts.unread`.
  func statusLabel(_ row: Row) -> String { row.statusLabel(unread: counts.unread != nil) }
  func statusRole(_ row: Row) -> ThemeRole { row.statusRole(unread: counts.unread != nil) }
}

public extension AgentsState.Row {
  /// `unread`: the backend sends `counts.unread`, so `idle` rows are unread sessions (`Não lida`, `primary`);
  /// otherwise they are recently finished (`Concluída`, gray).
  func statusLabel(unread: Bool) -> String {
    switch status {
    case .question: "Pergunta"
    case .permission: "Permissão"
    case .failed: "Erro"
    case .working: progress.map { "Trabalhando · \($0.done)/\($0.total)" } ?? "Trabalhando"
    case .idle: unread ? "Não lida" : "Concluída"
    case .unknown: ""
    }
  }
  func statusRole(unread: Bool) -> ThemeRole {
    switch status {
    case .question: .accent
    case .permission: .warning
    case .failed: .error
    case .working: .success
    case .idle: unread ? .primary : .textSecondary
    case .unknown: .textSecondary
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

  /// The watch shows two rows, what needs Alexandre first, then the sessions; those that need him add `há N min`.
  var watchRows: [AgentsState.Row] {
    let first = needItems.map(\.row)
    let listed = Set(first.map(\.sessionID))
    return Array((first + sessions.filter { !listed.contains($0.sessionID) }).prefix(2))
  }

  func asked(_ row: AgentsState.Row) -> Date? {
    if let need = needs?.first(where: { $0.sessionID == row.sessionID && $0.kind.status == row.status }) {
      return need.date
    }
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
