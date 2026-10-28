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
    Index(rows: rows, chips: chips, archived: archived, projects: projects, label: label)
      .groups(query: query, expanded: expanded)
  }

  /// The candidates with their titles and metadata already case/diacritic folded. Built once per data change, so a
  /// keystroke only compares folded strings; the accent-preserving highlights are computed for the visible rows.
  public struct Index: Sendable {
    struct Entry: Sendable {
      let result: Result
      let title: String
      let detail: String
    }
    let entries: [Kind: [Entry]]

    public init(rows: [SessionRow], chips: [Project], archived: [Session], projects: [Project],
      label: (Session) -> SessionDirectoryLabel?) {
      var seen = Set<String>()
      var activity: [String: Double] = [:]
      for row in rows {
        let key = row.chat ? chats : row.project?.id ?? ""
        activity[key] = max(activity[key] ?? 0, row.interactionAt)
      }
      let names = Dictionary(projects.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
      let projectResults = [
        Result(id: "project:all", title: "Todas", detail: "Todas as sessões", target: .project(nil), activity: 0, path: ""),
        Result(id: "project:" + chats, title: "Chats", detail: "Conversas sem repositório", target: .project(chats),
          activity: activity[chats] ?? 0, path: ""),
      ] + chips.filter { seen.insert($0.id).inserted }.map { project in
        Result(id: "project:" + project.id, title: project.displayName, detail: project.canonical,
          target: .project(project.id), activity: activity[project.id] ?? 0, path: "")
      }
      let sessions = rows.filter { $0.session.parentID == nil && $0.session.time.archived == nil }.map { row in
        result(row.session, project: row.chat ? "Chats" : row.projectName, activity: row.interactionAt, label: label)
      }
      let archives = archived.filter { $0.parentID == nil }.map { session in
        result(session, project: names[session.projectID] ?? "", activity: session.time.updated, label: label)
      }
      entries = [
        .projects: projectResults.map { Entry(result: $0, title: fold($0.title), detail: "") },
        .sessions: sessions.map { Entry(result: $0, title: fold($0.title), detail: fold($0.detail + " " + $0.path)) },
        .archived: archives.map { Entry(result: $0, title: fold($0.title), detail: fold($0.detail + " " + $0.path)) },
      ]
    }

    public func groups(query: String, expanded: Set<Kind> = []) -> [Group] {
      let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
      return Kind.allCases.compactMap { kind in
        let matches = (entries[kind] ?? []).enumerated().compactMap { index, entry -> (Result, Int, Int)? in
          score(entry, query: query).map { (entry.result, $0, index) }
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

    /// Title prefix, then a word start in the title, then any substring of the title or the metadata.
    private func score(_ entry: Entry, query: String) -> Int? {
      guard !query.isEmpty else { return 0 }
      let title = entry.title
      if title.hasPrefix(query) { return 0 }
      var start = title.startIndex
      var found = false
      while start < title.endIndex, let range = title.range(of: query, range: start..<title.endIndex) {
        found = true
        let previous = title[title.index(before: range.lowerBound)]
        if !previous.isLetter && !previous.isNumber { return 1 }
        start = range.upperBound
      }
      return found || entry.detail.contains(query) ? 2 : nil
    }
  }

  private static let locale = Locale(identifier: "pt_BR")
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
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
        range: start..<title.endIndex, locale: locale) {
      ranges.append(range)
      start = range.upperBound
    }
    return ranges
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
