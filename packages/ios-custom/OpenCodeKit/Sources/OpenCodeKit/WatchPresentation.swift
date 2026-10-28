import Foundation

// MARK: Ring

/// The complication and dashboard ring: arcs proportional to the counts, in a fixed order, with a gap at the
/// bottom for the mascot. Unread sessions are orange (`primary`); an older backend without `unread` shows its recently
/// finished (`idle`) sessions in gray instead. With no sessions at all the ring is fully gray.
public struct WatchRing: Equatable, Sendable {
  public struct Arc: Equatable, Sendable {
    public let role: ThemeRole
    /// Fractions of the drawable sweep (0…1), in drawing order.
    public let start: Double
    public let end: Double
  }

  public let arcs: [Arc]
  /// Degrees left open at the bottom for the mascot.
  public static let gap: Double = 80

  public init(counts: AgentsState.Counts?) {
    let parts: [(ThemeRole, Int)] = counts.map {
      [(.success, $0.working), (.accent, $0.question), (.warning, $0.permission), (.error, $0.failed),
       ($0.finished.unread ? .primary : .border, $0.finished.count)]
    } ?? []
    let total = parts.reduce(0) { $0 + max($1.1, 0) }
    guard total > 0 else {
      arcs = [Arc(role: .border, start: 0, end: 1)]
      return
    }
    var start = 0.0
    var result: [Arc] = []
    for (role, count) in parts where count > 0 {
      let end = start + Double(count) / Double(total)
      result.append(Arc(role: role, start: start, end: min(end, 1)))
      start = end
    }
    arcs = result
  }

  /// Gray only: nothing working, waiting or failed (the mascot shows alone).
  public var idle: Bool { arcs.allSatisfy { $0.role == .border } }
}

// MARK: Dashboard

public enum WatchDashboardRow: Hashable, Sendable, Identifiable {
  case attention(AgentsState.Attention)
  case session(AgentsState.Row)

  public var id: String {
    switch self {
    case .attention(let item): "attention-\(item.kind.rawValue)-\(item.sessionID)"
    case .session(let row): "session-\(row.sessionID)"
    }
  }
}

public extension AgentsState {
  /// Pending requests first (oldest first, as the backend orders them), then the session rows, without
  /// repeating a session whose request is already listed above.
  var dashboardRows: [WatchDashboardRow] {
    let pending = Set(attention.map { "\($0.kind.rawValue)|\($0.sessionID)" })
    let rows = sessions.filter { row in
      guard row.status == .question || row.status == .permission else { return true }
      return !pending.contains("\(row.status.rawValue)|\(row.sessionID)")
    }
    return attention.map(WatchDashboardRow.attention) + rows.map(WatchDashboardRow.session)
  }

  /// `N ativas` / `M precisa(m) de você` for the dashboard header and the rectangular complication.
  var activeLabel: String { "\(activeTotal) \(activeTotal == 1 ? "ativa" : "ativas")" }
  var attentionLabel: String? {
    attentionTotal > 0 ? "\(attentionTotal) \(attentionTotal == 1 ? "precisa" : "precisam") de você" : nil
  }
  /// One line for `accessoryRectangular`: `4 ativas · 1 precisa de você`.
  var complicationLine: String { [activeLabel, attentionLabel].compactMap { $0 }.joined(separator: " · ") }
}

// MARK: Voice captions

/// The voice screen shows the last two captions. The gateway merges deltas, so an event replaces the open line
/// of the same role until a `final` one closes it.
public struct WatchCaptions: Equatable, Sendable {
  public struct Line: Equatable, Sendable {
    public let role: WatchVoiceEvent.Role
    public var text: String
    public var final: Bool
  }

  public private(set) var lines: [Line] = []
  public static let limit = 2

  public init() {}

  public mutating func apply(role: WatchVoiceEvent.Role, text: String, final: Bool) {
    if let index = lines.lastIndex(where: { $0.role == role && !$0.final }) {
      lines[index].text = text
      lines[index].final = final
    } else {
      lines.append(Line(role: role, text: text, final: final))
    }
    if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
  }
}

// MARK: Voice state

/// Folded state of a call's gateway events, independent of the media.
public struct WatchVoiceTimeline: Equatable, Sendable {
  public var captions = WatchCaptions()
  public var master: (running: Bool, text: String)?
  public var ended: String?
  public var error: String?
  /// The `after` cursor for the next long poll.
  public var next = 0
  private var lastSeq = Int.min

  public init() {}

  /// Events already applied (a retried poll can repeat them) are skipped by sequence.
  public mutating func apply(_ batch: WatchVoiceEvents) {
    for event in batch.events.sorted(by: { $0.seq < $1.seq }) where event.seq > lastSeq {
      lastSeq = event.seq
      switch event.kind {
      case .caption(let role, let text, let final): captions.apply(role: role, text: text, final: final)
      case .master(let running, let text): master = (running, text)
      case .status(let status, let reason): if status == "ended" { ended = reason ?? "ended" }
      case .error(_, let message): error = message
      case .unknown: break
      }
    }
    next = max(next, batch.next)
    if batch.ended, ended == nil { ended = "ended" }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.captions == rhs.captions && lhs.master?.running == rhs.master?.running && lhs.master?.text == rhs.master?.text
      && lhs.ended == rhs.ended && lhs.error == rhs.error && lhs.next == rhs.next && lhs.lastSeq == rhs.lastSeq
  }
}
