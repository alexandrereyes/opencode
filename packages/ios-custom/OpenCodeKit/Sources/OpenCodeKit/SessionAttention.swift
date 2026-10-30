import Foundation

/// The one rule of "Precisa de você", shared by Sessões, the Mac bell, Dock and Sessão mestra bar, and mirrored by
/// the server for the Live Activity and the watch (`counts` and `needs` of `custom.live-activity`). A root session
/// counts once, by its row state: a pending permission, a pending question, an unseen failure, or an answer not yet
/// read (`SessionState.unread`). A working family, a background shell included, never counts: `.running` outranks
/// failures and unread answers, and an unread failure counts only as a failure.
public enum SessionAttention {
  /// Why a root needs you, in the order of "Precisa de você".
  public enum Reason: Int, Sendable, Hashable, CaseIterable {
    case permission, question, failed, replied
  }

  public static func reason(_ row: SessionRow) -> Reason? {
    switch row.state {
    case .permission: .permission
    case .question: .question
    case .failed: .failed
    case .unread: .replied
    case .running, .stopped: nil
    }
  }

  /// The number shown by "Precisa de você", the bell and everywhere else: one per root.
  public static func count(_ rows: [SessionRow]) -> Int { rows.filter { reason($0) != nil }.count }

  /// Permissions and questions in the rows' order, then failures and unread answers, newest first. Both use
  /// `time.idle`, which opening the session (`time.viewed`) never moves, so a held row keeps its place.
  public static func ordered(_ rows: [SessionRow], held: SessionAttentionHold = SessionAttentionHold()) -> [SessionRow] {
    let of = { (reason: Reason) in rows.filter { held.reason($0) == reason } }
    let recent = { (rows: [SessionRow]) in
      rows.sorted {
        let a = $0.session.time.idle ?? 0
        let b = $1.session.time.idle ?? 0
        return a != b ? a > b : $0.session.key < $1.session.key
      }
    }
    return of(.permission) + of(.question) + recent(of(.failed)) + recent(of(.replied))
  }
}

/// Nothing jumps while you read: opening a failure or an unread answer marks it viewed, so it would leave
/// "Precisa de você" at once. A row that needed you when its conversation opened (the iPhone's stack, or any Mac
/// window's selection) keeps its reason and place, without the dot, until no open conversation shows it. It lets go
/// as soon as the session works again or finishes a new run (`time.idle` moves), and it never counts.
public struct SessionAttentionHold: Sendable, Equatable {
  private struct Entry: Sendable, Equatable {
    let reason: SessionAttention.Reason
    let members: Set<String>
    let idle: Double?
  }

  private var open: Set<String> = []
  private var entries: [String: Entry] = [:]

  public init() {}

  /// `open`: the sessions (roots or subagents) open now. Only a conversation that has just opened is captured,
  /// with the reason its row has before the server marks it viewed.
  public mutating func update(open ids: Set<String>, rows: [SessionRow]) {
    let opened = ids.subtracting(open)
    open = ids
    entries = entries.filter { !$0.value.members.isDisjoint(with: ids) }
    for row in rows where entries[row.id] == nil && !row.memberIDs.isDisjoint(with: opened) {
      guard let reason = SessionAttention.reason(row), reason == .failed || reason == .replied else { continue }
      entries[row.id] = Entry(reason: reason, members: row.memberIDs, idle: row.session.time.idle)
    }
  }

  /// The row's own reason, else the one it had when opened while it stays idle and unchanged.
  public func reason(_ row: SessionRow) -> SessionAttention.Reason? {
    if let reason = SessionAttention.reason(row) { return reason }
    guard let entry = entries[row.id], row.state == .stopped, row.session.time.idle == entry.idle else { return nil }
    return entry.reason
  }
}
