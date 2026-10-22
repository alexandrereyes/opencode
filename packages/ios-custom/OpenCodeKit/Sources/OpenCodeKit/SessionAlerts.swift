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

/// Only live signals enter this policy. Snapshot reconciliation never creates alerts.
public struct SessionAlertPolicy: Sendable {
  public private(set) var claims: [String]
  private var connectedAt: Double?
  public init(claims: [String] = []) { self.claims = Array(claims.suffix(500)) }
  public mutating func connect(at watermark: Double) { connectedAt = watermark }
  public mutating func disconnect() { connectedAt = nil }
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
