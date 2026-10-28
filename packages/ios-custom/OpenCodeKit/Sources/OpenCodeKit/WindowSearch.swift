import Foundation

/// Pure projection for the desktop's global search, independent of its toolbar/palette presentation.
public enum WindowSearch {
  public static let chats = "custom.chats"

  public enum Kind: String, CaseIterable, Sendable {
    case projects = "Projetos", sessions = "Sessões", archived = "Sessões arquivadas"
    public var limit: Int { switch self { case .projects: 5; case .sessions: 8; case .archived: 5 } }
  }

  public enum Target: Hashable, Sendable {
    case project(String?)
    case session(String)
  }

  public struct Result: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let target: Target
    public let activity: Double
    let path: String
  }

  public struct Group: Identifiable, Sendable {
    public let kind: Kind
    public let results: [Result]
    public let total: Int
    public var id: Kind { kind }
    public var hasMore: Bool { results.count < total }
  }

  public static func groups(
    query: String, rows: [SessionRow], chips: [Project], archived: [Session], projects: [Project],
    expanded: Set<Kind> = [], label: (Session) -> SessionDirectoryLabel?
  ) -> [Group] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set<String>()
    let chips = chips.filter { seen.insert($0.id).inserted }
    let projectResults = [
      Result(id: "project:all", title: "Todas", detail: "Todas as sessões", target: .project(nil), activity: 0, path: ""),
      Result(id: "project:" + chats, title: "Chats", detail: "Conversas sem repositório", target: .project(chats),
        activity: rows.filter(\.chat).map(\.interactionAt).max() ?? 0, path: ""),
    ] + chips.map { project in
      Result(id: "project:" + project.id, title: project.displayName, detail: project.canonical,
        target: .project(project.id),
        activity: rows.filter { !$0.chat && $0.project?.id == project.id }.map(\.interactionAt).max() ?? 0, path: "")
    }
    let sessions = rows.filter { $0.session.parentID == nil && $0.session.time.archived == nil }.map { row in
      result(row.session, project: row.chat ? "Chats" : row.projectName, activity: row.interactionAt, label: label)
    }
    let archives = archived.filter { $0.parentID == nil }.map { session in
      result(session, project: projects.first { $0.id == session.projectID }?.displayName ?? "",
        activity: session.time.updated, label: label)
    }
    return Kind.allCases.compactMap { kind in
      let values = switch kind { case .projects: projectResults; case .sessions: sessions; case .archived: archives }
      let matches = values.enumerated().compactMap { index, item -> (Result, Int, Int)? in
        guard let score = score(title: item.title, detail: kind == .projects ? "" : item.detail + " " + item.path, query: query) else {
          return nil
        }
        return (item, score, index)
      }.sorted {
        // An empty field starts with Todas and Chats, then the saved project chips; sessions stay recent-first.
        if query.isEmpty && kind == .projects { return $0.2 < $1.2 }
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        if $0.0.activity != $1.0.activity { return $0.0.activity > $1.0.activity }
        return $0.2 < $1.2
      }.map(\.0)
      guard !matches.isEmpty else { return nil }
      return Group(kind: kind, results: Array(matches.prefix(expanded.contains(kind) ? matches.count : kind.limit)),
        total: matches.count)
    }
  }

  /// Identical to a chip click: Todas also clears the state filter; a project/Chats toggles, preserving it.
  public static func projectSelection(_ project: String?, current: String?, filter: SessionFilter)
    -> (project: String?, filter: SessionFilter) {
    guard let project else { return (nil, .all) }
    return (project == current ? nil : project, filter)
  }

  public static func highlights(in title: String, query: String) -> [Range<String.Index>] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var start = title.startIndex
    while start < title.endIndex,
      let range = title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
        range: start..<title.endIndex, locale: Locale(identifier: "pt_BR")) {
      ranges.append(range)
      start = range.upperBound
    }
    return ranges
  }

  private static func score(title: String, detail: String, query: String) -> Int? {
    guard !query.isEmpty else { return 0 }
    let ranges = highlights(in: title, query: query)
    if ranges.contains(where: { $0.lowerBound == title.startIndex }) { return 0 }
    if ranges.contains(where: {
      let previous = title[title.index(before: $0.lowerBound)]
      return !previous.isLetter && !previous.isNumber
    }) { return 1 }
    if !ranges.isEmpty || !highlights(in: detail, query: query).isEmpty { return 2 }
    return nil
  }

  private static func result(_ session: Session, project: String, activity: Double,
    label: (Session) -> SessionDirectoryLabel?) -> Result {
    let directory = label(session)
    return Result(id: "session:" + session.id, title: session.displayTitle,
      detail: [project, directory?.branch, directory?.path ?? session.location.directory]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
      target: .session(session.id), activity: activity, path: session.location.directory)
  }
}
