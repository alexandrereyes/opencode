import Foundation

/// One section of the Sessões column ("D · Precisa de você"), shared by the iOS and future Mac apps.
public struct SessionSection: Sendable, Identifiable {
  public enum Kind: String, Sendable, Hashable, CaseIterable {
    case attention, running, pinned, today, yesterday
    /// Two to six local days ago, completing the seven local days.
    case week
    case older

    public var key: String { rawValue }
    public var collapsedByDefault: Bool { self == .older }
    public var title: String {
      switch self {
      case .attention: "Precisa de você"
      case .running: "Trabalhando"
      case .pinned: "Fixadas"
      case .today: "Hoje"
      case .yesterday: "Ontem"
      case .week: "Esta semana"
      case .older: "Anteriores"
      }
    }
  }

  public let kind: Kind
  public let rows: [SessionRow]
  public var id: String { kind.key }
  public var title: String { kind.title }
}

public enum SessionSections {
  public static let days = 7

  /// Groups rows already narrowed by the state filter and chip, so "Todas" mixes chats with repository sessions
  /// under the same rules, a repository chip lists none and the Chats chip only chats. "Precisa de você" lists
  /// permissions, then questions, then failures, then unread answers (`SessionAttention.ordered`), plus the rows
  /// `held` open in their place; the other sections keep the rows' order.
  /// The remaining rows fall into the web's seven local days (`localDays`) by `interactionAt`: today, yesterday
  /// and "Esta semana" (two to six days ago); older ones go to "Anteriores". Empty sections are omitted.
  public static func group(
    _ rows: [SessionRow], now: Date, held: SessionAttentionHold = SessionAttentionHold(),
    calendar: Calendar = .current
  ) -> [SessionSection] {
    let attention = SessionAttention.ordered(rows, held: held)
    let listed = rows.filter { held.reason($0) == nil }
    let today = calendar.startOfDay(for: now)
    let start = { (days: Int) in
      calendar.date(byAdding: .day, value: -days, to: today).map(calendar.startOfDay) ?? today
    }
    let yesterday = start(1)
    let week = start(days - 1)
    // A timestamp after now (clock skew) still counts as today.
    let day = { (row: SessionRow) -> SessionSection.Kind in
      let date = Date(timeIntervalSince1970: row.interactionAt / 1000)
      return date >= today ? .today : date >= yesterday ? .yesterday : date >= week ? .week : .older
    }
    let history = listed.filter { $0.state != .running && !$0.pinned }
    let sections =
      [
        SessionSection(kind: .attention, rows: attention),
        SessionSection(kind: .running, rows: listed.filter { $0.state == .running }),
        SessionSection(kind: .pinned, rows: listed.filter { $0.state != .running && $0.pinned }),
      ]
      + [SessionSection.Kind.today, .yesterday, .week, .older].map { kind in
        SessionSection(kind: kind, rows: history.filter { day($0) == kind })
      }
    return sections.filter { !$0.rows.isEmpty }
  }

  /// The colored third line of a "Precisa de você" row, for `reason` (by default the row's own; a held row passes
  /// the one it had when opened). `reply` is the first line of the latest answer.
  public static func detail(
    _ row: SessionRow, reason: SessionAttention.Reason? = nil, permission: String?, question: String?,
    failure: String?, reply: String? = nil, now: Date = .now
  ) -> String {
    switch reason ?? SessionAttention.reason(row) {
    case .permission: "permissão · " + (permission ?? "Permissão pendente")
    case .question: "pergunta · " + (question ?? "Uma pergunta aguarda sua resposta")
    case .failed:
      "erro · " + (failure ?? "parou com erro") + " · "
        + elapsed(row.session.time.idle ?? row.interactionAt, now: now)
    case .replied: reply.flatMap { $0.isEmpty ? nil : "respondeu · " + $0 } ?? "respondeu"
    case nil: ""
    }
  }

  /// "há 12 min", "há 3 h", "há 2 d"; under a minute, "agora".
  public static func elapsed(_ milliseconds: Double, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince1970 - milliseconds / 1000)
    if seconds < 60 { return "agora" }
    if seconds < 3600 { return "há \(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "há \(Int(seconds / 3600)) h" }
    return "há \(Int(seconds / 86_400)) d"
  }
}

/// Collapsed sections, saved on the device. Only choices that differ from the default are stored.
public struct SessionSectionCollapse: Sendable, Equatable, RawRepresentable {
  private var overrides: [String: Bool]

  public init() { overrides = [:] }
  public init?(rawValue: String) {
    overrides = (try? JSONDecoder().decode([String: Bool].self, from: Data(rawValue.utf8))) ?? [:]
  }
  public var rawValue: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(overrides)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  public func collapsed(_ kind: SessionSection.Kind) -> Bool { overrides[kind.key] ?? kind.collapsedByDefault }
  public mutating func toggle(_ kind: SessionSection.Kind) {
    let value = !collapsed(kind)
    overrides[kind.key] = value == kind.collapsedByDefault ? nil : value
  }
}
