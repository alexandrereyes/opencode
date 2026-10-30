import Foundation

// MARK: Dashboard

public enum WatchDashboardRow: Hashable, Sendable, Identifiable {
  /// A pending request the watch can answer (it carries the request ID).
  case attention(AgentsState.Attention)
  /// A failure, an unread answer, or a request without its attention item.
  case need(AgentsState.Need)
  /// The collapsed `Trabalhando N` line.
  case working(Int)
  case session(AgentsState.Row)

  public var id: String {
    switch self {
    case .attention(let item): "attention-\(item.kind.rawValue)-\(item.sessionID)"
    case .need(let item): "need-\(item.kind.rawValue)-\(item.sessionID)"
    case .working: "working"
    case .session(let row): "session-\(row.sessionID)"
    }
  }
}

public extension AgentsState {
  /// "Precisa de você" first, in the backend's order (requests answer from the watch), then `Trabalhando N`,
  /// followed by the working sessions when it is expanded.
  func dashboardRows(working expanded: Bool = false) -> [WatchDashboardRow] {
    let requests = Dictionary(attention.map { ("\($0.kind.rawValue)|\($0.sessionID)", $0) }) { first, _ in first }
    let needs = needItems.map { need in
      requests["\(need.kind.rawValue)|\(need.sessionID)"].map(WatchDashboardRow.attention) ?? .need(need)
    }
    guard counts.working > 0 else { return needs }
    let working = expanded ? sessions.filter { $0.status == .working }.map(WatchDashboardRow.session) : []
    return needs + [.working(counts.working)] + working
  }

  /// `N para você`, or nil when nothing needs Alexandre.
  var forYouLabel: String? { forYou > 0 ? "\(forYou) para você" : nil }
  var workingLabel: String { "\(counts.working) trabalhando" }
  /// The non-zero counts behind `N para você`, then the work: `["1 pergunta", "2 não lidas", "6 trabalhando"]`. The
  /// Painel wraps between them, never inside one.
  var forYouParts: [String] {
    let part = { (count: Int, one: String, many: String) in count > 0 ? ["\(count) \(count == 1 ? one : many)"] : [] }
    return part(counts.question, "pergunta", "perguntas") + part(counts.permission, "permissão", "permissões")
      + part(counts.failed, "com erro", "com erro") + part(counts.unread ?? 0, "não lida", "não lidas")
      + part(counts.working, "trabalhando", "trabalhando")
  }
  /// `1 pergunta · 2 não lidas · 6 trabalhando`.
  var forYouDetail: String { forYouParts.joined(separator: " · ") }
  /// The rectangular complication's main line: `3 para você`, or `6 trabalhando · nada para você`.
  var complicationLine: String {
    forYouLabel ?? (counts.working > 0 ? "\(workingLabel) · nada para você" : "nada para você")
  }
  /// Its dimmed second line while something needs Alexandre.
  var complicationDetail: String? { forYou > 0 ? forYouDetail : nil }
  /// Dashboard header and accessibility: `3 para você · 1 pergunta · 2 não lidas · 6 trabalhando`.
  var summaryLabel: String { [complicationLine, complicationDetail].compactMap { $0 }.joined(separator: " · ") }
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
