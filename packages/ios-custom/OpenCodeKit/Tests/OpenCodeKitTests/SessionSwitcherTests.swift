import Foundation
import Testing

@testable import OpenCodeKit

private func switcherEntry(
  _ id: String, title: String, project: String, directory: String, message: Double,
  parent: String? = nil, archived: Bool = false
) throws -> NavigationEntry {
  var time: [String: JSONValue] = ["created": .number(1), "updated": .number(1)]
  if archived { time["archived"] = .number(2) }
  var session: [String: JSONValue] = [
    "id": .string(id), "projectID": .string(project), "title": .string(title),
    "location": .object(["directory": .string(directory)]), "time": .object(time),
  ]
  if let parent { session["parentID"] = .string(parent) }
  return try JSONDecoder().decode(
    NavigationEntry.self,
    from: JSONEncoder().encode(["session": JSONValue.object(session), "messageAt": .number(message)]))
}

@Test func switcherListsRootsByRecentActivityAndSearchesTitleProjectAndBranch() throws {
  let projects: [Project] = try JSONDecoder().decode(
    [Project].self,
    from: Data(
      #"[{"id":"av","canonical":"/av","sandboxes":[],"name":"abacato-v2"},{"id":"oc","canonical":"/oc","sandboxes":[],"name":"opencode2"}]"#
        .utf8))
  let entries = [
    try switcherEntry("ses_old", title: "Controle de empréstimos", project: "av", directory: "/av", message: 10),
    try switcherEntry("ses_new", title: "Live activity", project: "oc", directory: "/oc-w/custom", message: 30),
    try switcherEntry("ses_mid", title: "Scroll", project: "oc", directory: "/oc-w/transcript-rewrite", message: 20),
    try switcherEntry("ses_chat", title: "Pergunta rápida", project: "global", directory: "/chats/day/a", message: 25),
    try switcherEntry("ses_child", title: "Filha", project: "av", directory: "/av", message: 99, parent: "ses_old"),
    try switcherEntry("ses_gone", title: "Arquivada", project: "av", directory: "/av", message: 98, archived: true),
  ]
  // The master is removed by the store before the rows are built, as in the Sessões tab.
  let rows = SessionList.rows(
    entries: entries, projects: projects, active: ["ses_mid"], pins: [entries[0].session.key], muted: [],
    autoApprove: false, ranks: [:], chatRoot: "/chats")
  let branches = ["/oc-w/custom": "custom", "/oc-w/transcript-rewrite": "transcript-rewrite", "/av": "main"]
  func label(_ session: Session) -> SessionDirectoryLabel? {
    session.location.directory.hasPrefix("/chats")
      ? nil : SessionDirectoryLabel(path: session.location.directory, branch: branches[session.location.directory])
  }
  // Recent activity first, even before pinned sessions; no children or archived sessions; chats included.
  #expect(SessionSwitcher.rows(rows, query: "", label: label).map(\.id) == ["ses_new", "ses_chat", "ses_mid", "ses_old"])
  // Title (accents and case folded), project, branch and Chats.
  #expect(SessionSwitcher.rows(rows, query: "emprestimos", label: label).map(\.id) == ["ses_old"])
  #expect(SessionSwitcher.rows(rows, query: "OPENCODE2", label: label).map(\.id) == ["ses_new", "ses_mid"])
  #expect(SessionSwitcher.rows(rows, query: "transcript", label: label).map(\.id) == ["ses_mid"])
  #expect(SessionSwitcher.rows(rows, query: "chats", label: label).map(\.id) == ["ses_chat"])
  #expect(SessionSwitcher.rows(rows, query: "  ", label: label).count == 4)
  #expect(SessionSwitcher.rows(rows, query: "nada", label: label).isEmpty)
  // The running state stays on the row for the green arc and "trabalhando".
  #expect(rows.first { $0.id == "ses_mid" }?.state == .running)
}
