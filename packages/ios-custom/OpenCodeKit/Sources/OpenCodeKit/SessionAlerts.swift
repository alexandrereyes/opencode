import Foundation

public enum SessionAlertKind: String, Codable, Sendable {
  case succeeded, failed, permission, question
  public var label: String {
    switch self {
    case .succeeded: "Concluída"
    case .failed: "Falhou"
    case .permission, .question: "Precisa de você"
    }
  }
}

public struct SessionAlertSignal: Sendable {
  public let sessionID: String
  public let kind: SessionAlertKind
  public let watermark: String
  public let created: Double
  public init?(_ event: ConversationEvent) {
    guard let owner = event.data.owner, let created = event.created else { return nil }
    sessionID = owner
    self.created = created
    switch event.type {
    case "session.execution.succeeded": kind = .succeeded
    case "session.execution.failed": kind = .failed
    case "permission.asked": kind = .permission
    case "form.created":
      guard event.data.form?.object?["metadata"]?.object?["kind"]?.string == "question" else {
        return nil
      }
      kind = .question
    default: return nil
    }
    // Request identity survives repeated snapshots/envelopes; terminal timestamps are
    // the same idle watermark used by navigation, independent of local SSE sequence.
    switch kind {
    case .permission:
      guard let id = event.data.id else { return nil }
      watermark = id
    case .question:
      guard let id = event.data.form?.object?["id"]?.string else { return nil }
      watermark = id
    case .succeeded, .failed: watermark = String(created)
    }
  }
}

/// Work of a root that outlives its own execution: subagents and background shells.
public struct SessionAlertWork: Sendable, Equatable {
  public let agents: Int
  public let tasks: Int
  public init(agents: Int, tasks: Int) {
    self.agents = agents
    self.tasks = tasks
  }
  /// Counts what still runs when the root's execution ends. An agent is an active descendant
  /// whose parent is not itself active, so a running orchestrator child and its own running
  /// child count once, like the conversation header; an idle child's running child still counts.
  /// A finished root has no foreground tools, so every running shell it owns is background.
  public init(root: String, active: [Session], shells: [ShellInfo]) {
    let running = Set(active.map(\.id))
    agents = active.filter { $0.id != root && !running.contains($0.parentID ?? "") }.count
    tasks = shells.filter { $0.status == "running" && $0.metadata?["sessionID"]?.string == root }.count
  }
}

public struct SessionAlertContent: Sendable, Equatable {
  public enum Tone: Sendable { case success, neutral, error, info }
  public let kind: SessionAlertKind
  /// `nil` when the remaining work could not be read in time: the root answered, but
  /// "Concluída" is only claimed once nothing else is known to be running.
  public let work: SessionAlertWork?
  public let preview: String?
  public init(kind: SessionAlertKind, work: SessionAlertWork? = nil, preview: String? = nil) {
    self.kind = kind
    self.work = work
    self.preview = kind == .succeeded ? preview : nil
  }
  public var replied: Bool { kind == .succeeded && work.map { $0.agents + $0.tasks > 0 } != false }
  public var label: String {
    guard replied else { return kind.label }
    let running = [
      work.map(\.agents).flatMap { $0 > 0 ? "\($0) \($0 == 1 ? "agente" : "agentes")" : nil },
      work.map(\.tasks).flatMap { $0 > 0 ? "\($0) \($0 == 1 ? "tarefa" : "tarefas")" : nil },
    ].compactMap { $0 }
    guard !running.isEmpty else { return "Respondeu" }
    return "Respondeu · " + running.joined(separator: " e ") + " rodando"
  }
  public var tone: Tone {
    if replied { return .neutral }
    switch kind {
    case .succeeded: return .success
    case .failed, .permission: return .error
    case .question: return .info
    }
  }
}

/// Only live signals enter this policy. Snapshot reconciliation never creates alerts.
public struct SessionAlertPolicy: Sendable {
  public private(set) var claims: [String]
  private var connectedAt: Double?
  public init(claims: [String] = []) { self.claims = Array(claims.suffix(500)) }
  public mutating func connect(at watermark: Double) { connectedAt = watermark }
  public mutating func disconnect() { connectedAt = nil }
  public mutating func remove(_ ids: Set<String>) {
    claims.removeAll { key in
      let fields = key.components(separatedBy: "\u{0}")
      return fields.count == 4 && ids.contains(fields[1])
    }
  }
  public mutating func admit(
    _ signal: SessionAlertSignal, server: String, session: Session, root: Session,
    current: String?, muted: [String], autoApprove: Bool = false
  ) -> Bool {
    guard let connectedAt, signal.created >= connectedAt else { return false }
    let key = [server, signal.sessionID, signal.kind.rawValue, signal.watermark].joined(
      separator: "\u{0}")
    guard !claims.contains(key) else { return false }
    // Claim suppressed signals too: leaving the screen or unmuting must not replay them.
    claims.append(key)
    claims = Array(claims.suffix(500))
    guard session.id == signal.sessionID, root.parentID == nil,
      session.time.archived == nil, root.time.archived == nil,
      current != session.id, current != root.id
    else { return false }
    let silenced = Set(muted.compactMap(SessionPreferenceKey.sessionID))
    guard !silenced.contains(root.id), !silenced.contains(session.id) else { return false }
    switch signal.kind {
    case .succeeded, .failed: return session.parentID == nil
    case .permission: return !autoApprove
    case .question: return true
    }
  }
}
