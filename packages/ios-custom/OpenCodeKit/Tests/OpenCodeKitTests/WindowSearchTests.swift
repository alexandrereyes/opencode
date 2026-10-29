import Foundation
import Testing

@testable import OpenCodeKit

private func searchEntry(_ id: String, _ title: String, at: Double = 1, project: String = "p",
  directory: String = "/repo", archived: Bool = false, parent: String? = nil) throws -> NavigationEntry {
  var session: [String: JSONValue] = [
    "id": .string(id), "title": .string(title), "projectID": .string(project),
    "location": .object(["directory": .string(directory)]),
    "time": .object(["created": .number(1), "updated": .number(at)]
      .merging(archived ? ["archived": .number(at)] : [:], uniquingKeysWith: { $1 })),
  ]
  if let parent { session["parentID"] = .string(parent) }
  return try JSONDecoder().decode(NavigationEntry.self,
    from: JSONEncoder().encode(["session": JSONValue.object(session), "messageAt": .number(at)]))
}

private func searchProjects() throws -> [Project] {
  try JSONDecoder().decode([Project].self, from: Data(#"[{"id":"p","name":"Líve projeto","canonical":"/repo","sandboxes":[]},{"id":"hidden","name":"Live oculto","canonical":"/hidden","sandboxes":[]}]"#.utf8))
}

private func searchRows(_ entries: [NavigationEntry]) throws -> [SessionRow] {
  SessionList.rows(entries: entries, projects: try searchProjects(), active: [], pins: [], notify: [],
    autoApprove: false, ranks: [:], chatRoot: "/chats")
}

@Test func windowSearchGroupOrderAndOnlySelectedChips() throws {
  let projects = try searchProjects()
  let groups = WindowSearch.groups(query: "LIVE", rows: try searchRows([searchEntry("s", "Live sessão")]),
    chips: [projects[0], projects[0]], archived: [try searchEntry("a", "Live antiga", archived: true).session],
    projects: projects, label: { _ in nil })
  #expect(groups.map(\.kind) == [.projects, .sessions, .archived])
  #expect(groups[0].results.map(\.title) == ["Líve projeto"])
  #expect(groups[1].results.map(\.target) == [.session("s")])
  #expect(groups[2].results.map(\.target) == [.session("a")])
}

@Test func windowSearchRanksTitlePrefixWordThenContainsBeforeRecency() throws {
  let entries = try [
    searchEntry("contains", "Deliver", at: 500), searchEntry("word", "Uma live", at: 100),
    searchEntry("prefix-old", "Live antigo", at: 1), searchEntry("prefix-new", "Líve novo", at: 3),
    searchEntry("branch", "Outro", at: 200, project: "hidden", directory: "/other"),
  ]
  let groups = WindowSearch.groups(query: "live", rows: try searchRows(entries), chips: [], archived: [],
    projects: [], label: { .init(path: $0.location.directory, branch: "live-branch") })
  #expect(groups.first { $0.kind == .sessions }?.results.map(\.target) == [
    .session("prefix-new"), .session("prefix-old"), .session("word"), .session("contains"), .session("branch"),
  ])
}

@Test func windowSearchAccentsMetadataAndOriginalHighlightRanges() throws {
  let title = "Índice de empréstimos"
  #expect(WindowSearch.highlights(in: title, query: "EMPRESTIMOS").map { String(title[$0]) } == ["empréstimos"])
  let rows = try searchRows([searchEntry("s", title, directory: "/Users/alexandre/repo")])
  for query in ["indice", "EMPRESTIMOS", "líve", "repo", "feature", "/Users/alexandre"] {
    let groups = WindowSearch.groups(query: query, rows: rows, chips: [], archived: [], projects: [],
      label: { _ in .init(path: "~/repo", branch: "feature") })
    #expect(groups.contains { $0.kind == .sessions && $0.results.count == 1 })
  }
}

@Test func windowSearchEmptyLimitsExpansionAndRoots() throws {
  let projects = try (0..<8).map { index in
    try JSONDecoder().decode(Project.self, from: Data("{\"id\":\"p\(index)\",\"canonical\":\"/p\(index)\",\"sandboxes\":[]}".utf8))
  }
  let entries = try (0..<12).map { try searchEntry("s\($0)", "Sessão \($0)", at: Double($0)) }
    + [searchEntry("chat", "Chat", at: 20, directory: "/chats/day/a"), searchEntry("child", "Filha", at: 30, parent: "s0")]
  let archives = try (0..<7).map { try searchEntry("a\($0)", "Antiga", archived: true).session }
  let groups = WindowSearch.groups(query: "  ", rows: try searchRows(entries), chips: projects, archived: archives,
    projects: projects, label: { _ in nil })
  #expect(groups.map { $0.results.count } == [5, 8, 5])
  #expect(groups.allSatisfy { $0.hasMore })
  #expect(groups[0].results.prefix(2).map(\.title) == ["Todas", "Chats"])
  #expect(groups[1].results.first?.target == .session("chat"))
  let expanded = WindowSearch.groups(query: "", rows: try searchRows(entries), chips: projects, archived: archives,
    projects: projects, expanded: Set(WindowSearch.Kind.allCases), label: { _ in nil })
  #expect(expanded.map { $0.results.count } == [10, 13, 7])
  #expect(expanded.allSatisfy { !$0.hasMore })
}

@Test func windowSearchIndexIsBuiltOnceAndServesEveryKeystroke() throws {
  let projects = try searchProjects()
  let entries = try [
    searchEntry("word", "Uma líve", at: 100), searchEntry("prefix", "LIVE antigo", at: 1),
    searchEntry("contains", "Deliver", at: 500), searchEntry("other", "Índice", at: 50),
  ]
  var labels = 0
  let index = WindowSearch.Index(rows: try searchRows(entries), chips: [projects[0]], archived: [],
    projects: projects, label: { labels += 1; return .init(path: $0.location.directory, branch: "main") })
  #expect(labels == entries.count)
  // "Índice" still matches l…live through its project, "Líve projeto", after the title matches.
  for (query, expected) in [("l", ["prefix", "word", "contains", "other"]), ("li", ["prefix", "word", "contains", "other"]),
    ("LÍV", ["prefix", "word", "contains", "other"]), ("live", ["prefix", "word", "contains", "other"]),
    ("indi", ["other"]), ("ÍNDICE", ["other"])] {
    let sessions = index.groups(query: query).first { $0.kind == .sessions }?.results.map(\.target)
    #expect(sessions == expected.map { .session($0) }, "\(query)")
  }
  #expect(labels == entries.count)
  #expect(index.groups(query: "LÍVE").first?.results.map(\.title) == ["Líve projeto"])
}

@Test func windowSearchTodasAndChatsHaveChipSemantics() throws {
  let all = WindowSearch.projectSelection(nil, current: "p", filter: .running)
  #expect(all.project == nil && all.filter == .all)
  let chats = WindowSearch.projectSelection(WindowSearch.chats, current: "p", filter: .unread)
  #expect(chats.project == WindowSearch.chats && chats.filter == .unread)
  let toggle = WindowSearch.projectSelection(WindowSearch.chats, current: WindowSearch.chats, filter: .unread)
  #expect(toggle.project == nil && toggle.filter == .unread)
  let project = WindowSearch.projectSelection("p", current: nil, filter: .all)
  #expect(project.project == "p" && project.filter == .all)
  let groups = WindowSearch.groups(query: "CHATS", rows: [], chips: [], archived: [], projects: [], label: { _ in nil })
  #expect(groups.first?.results.first?.target == .project(WindowSearch.chats))
  #expect(WindowSearch.groups(query: "nenhum", rows: [], chips: [], archived: [], projects: [], label: { _ in nil }).isEmpty)
}
