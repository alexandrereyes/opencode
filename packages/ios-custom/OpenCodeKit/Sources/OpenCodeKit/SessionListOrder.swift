import Foundation

/// Only the placement of rows, not their data. A list keeps these IDs while being touched or decelerating;
/// labels, badges and actions still resolve from the latest rows. Real removals never leave stale actions.
public struct SessionListOrder: Sendable, Equatable {
  public struct Section: Sendable, Equatable {
    public let kind: SessionSection.Kind
    public let ids: [String]
  }
  public let sections: [Section]

  public init(_ sections: [SessionSection]) {
    self.sections = sections.map { Section(kind: $0.kind, ids: $0.rows.map(\.id)) }
  }

  private init(sections: [Section]) { self.sections = sections }

  public func updating(to desired: Self, idle: Bool, available: Set<String>? = nil) -> Self {
    guard !idle else { return desired }
    let available = available ?? Set(desired.sections.flatMap(\.ids))
    return Self(sections: sections.compactMap { section in
      let ids = section.ids.filter(available.contains)
      return ids.isEmpty ? nil : Section(kind: section.kind, ids: ids)
    })
  }

  public func resolve(_ rows: [SessionRow]) -> [SessionSection] {
    let values = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return sections.compactMap { section in
      let rows = section.ids.compactMap { values[$0] }
      return rows.isEmpty ? nil : SessionSection(kind: section.kind, rows: rows)
    }
  }

  public func visibleIDs(collapsed: SessionSectionCollapse) -> [String] {
    sections.filter { !collapsed.collapsed($0.kind) }.flatMap(\.ids)
  }
}

/// A list's local filter. The tab owns one selection; a presented picker can own another with identical rules.
public struct SessionListFilter: Sendable, Hashable {
  public static let chats = "custom.chats"
  public var project: String?
  public var state: SessionFilter
  public var query: String

  public init(project: String? = nil, state: SessionFilter = .all, query: String = "") {
    self.project = project
    self.state = state
    self.query = query
  }

  public var chats: Bool { project == Self.chats }

  public func rows(_ rows: [SessionRow], label: (Session) -> SessionDirectoryLabel?) -> [SessionRow] {
    SessionSwitcher.matching(rows.filter {
      state.includes($0) && (chats ? $0.chat : project == nil || (!$0.chat && $0.project?.id == project))
    }, query: query, label: label)
  }
}
