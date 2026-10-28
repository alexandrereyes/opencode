import Foundation
import Testing

@testable import OpenCodeKit

private func entry(
  _ id: String, parent: String? = nil, updated: Double = 100,
  idle: Double? = nil, viewed: Double? = nil, permission: Bool = false,
  question: Bool = false, archived: Bool = false, directory: String = "/repo"
) throws -> NavigationEntry {
  var session: [String: JSONValue] = [
    "id": .string(id), "projectID": .string("project"), "title": .string(id),
    "location": .object(["directory": .string(directory)]),
    "time": .object(["created": .number(100), "updated": .number(updated)]),
  ]
  var time = session["time"]!.object!
  if let idle {
    time["idle"] = .number(idle)
    session["outcome"] = .string("succeeded")
  }
  if let viewed { time["viewed"] = .number(viewed) }
  if archived { time["archived"] = .number(200) }
  session["time"] = .object(time)
  if let parent { session["parentID"] = .string(parent) }
  var row: [String: JSONValue] = ["session": .object(session)]
  if permission { row["permissionAt"] = .number(300) }
  if question { row["questionAt"] = .number(300) }
  return try JSONDecoder().decode(NavigationEntry.self, from: JSONEncoder().encode(row))
}

@Test func monograms() {
  #expect(SessionList.monogram("abacato-v2") == "AV")
  #expect(SessionList.monogram("opencode2") == "OP")
  #expect(SessionList.monogram("abacato-site") == "AS")
  #expect(SessionList.monogram("Olá mundo") == "OM")
}

@Test func avatarFallbackIsStableAcrossLaunches() {
  #expect(
    SessionList.avatarColor(nil, fallback: "b887b100db86ae19c5e370efc5172cfacd06a64c") == "lime")
  #expect(
    SessionList.avatarColor(nil, fallback: "85da54af6034664de0c3eb787bc804d585e0c7cb") == "orange")
  #expect(
    SessionList.avatarColor(nil, fallback: "4acc48746b4071d3a9458537fd353d3939b6f078") == "purple")
}

@Test func rootsRollUpRequestsButNotChildCompletions() throws {
  let rows = SessionList.rows(
    entries: [
      try entry("ses_root"),
      try entry("ses_child", parent: "ses_root", idle: 500, permission: true),
      try entry("ses_grandchild", parent: "ses_child", question: true),
      try entry("ses_archived", archived: true),
    ], projects: [], active: ["ses_grandchild"], pins: [], notify: [], autoApprove: false,
    ranks: [:], chatRoot: nil)
  #expect(rows.count == 1)
  #expect(rows.first?.state == .permission)
  #expect(rows.first?.requestCount == 2)
  #expect(rows.first?.unread == false)
  #expect(rows.first?.activeChildren == 1)
}

@Test func pinsThenActivityAndViewedWatermark() throws {
  let entries = [
    try entry("ses_old", updated: 101), try entry("ses_new", updated: 200, idle: 200),
    try entry("ses_read", updated: 300, idle: 300, viewed: 300),
  ]
  let rows = SessionList.rows(
    entries: entries, projects: [], active: [], pins: [entries[0].session.key],
    notify: [entries[1].session.key], autoApprove: false, ranks: [:], chatRoot: nil)
  #expect(rows.map(\.id) == ["ses_old", "ses_read", "ses_new"])
  #expect(rows.last?.unread == true)
  #expect(rows.last?.notify == true)
  #expect(rows[1].unread == false)
}

@Test func activityTransitionsShareSnapshotRank() throws {
  let entries = [try entry("ses_a"), try entry("ses_b", updated: 200)]
  var order = RecentOrder()
  order.snapshot(entries, active: [], now: 1000)
  #expect(order.ranks["ses_a"] == 100)
  order.snapshot(entries, active: ["ses_a", "ses_b"], now: 2000)
  #expect(order.ranks["ses_a"] == 2000)
  #expect(order.ranks["ses_b"] == 2000)
  order.snapshot(entries, active: ["ses_a"], now: 3000)
  #expect(order.ranks["ses_a"] == 2000)
  #expect(order.ranks["ses_b"] == 3000)
}

@Test func liveActivityObservationsDoNotPromoteTwice() throws {
  var order = RecentOrder()
  order.snapshot([try entry("ses_a")], active: [], now: 1000)
  order.observe("ses_a", running: true, now: 2000)
  order.observe("ses_a", running: true, now: 3000)
  #expect(order.ranks["ses_a"] == 2000)
  order.observe("ses_a", running: false, now: 4000)
  order.snapshot([try entry("ses_a")], active: [], now: 5000)
  #expect(order.ranks["ses_a"] == 4000)
}

@Test func autoApprovalStillShowsQuestionsAndBellAttention() throws {
  let root = try entry("ses_root", permission: true, question: true)
  let rows = SessionList.rows(
    entries: [root], projects: [], active: [root.session.id],
    pins: [], notify: [root.session.key], autoApprove: true, ranks: [:], chatRoot: nil)
  let row = try #require(rows.first)
  #expect(row.state == .question)
  #expect(row.notify)
  #expect(!SessionFilter.allCases.map(\.rawValue).contains("Silenciadas"))
  #expect(SessionFilter.attention.includes(row))
  #expect(!SessionFilter.running.includes(row))
}

@Test func managedChatsStayListedWithTheirOwnIdentity() throws {
  let chat = try entry("ses_chat", permission: true, directory: "/chats/day/session-a")
  let rows = SessionList.rows(
    entries: [chat, try entry("ses_repo")], projects: [], active: [], pins: [], notify: [],
    autoApprove: false, ranks: [:], chatRoot: "/chats")
  #expect(rows.map(\.id).sorted() == ["ses_chat", "ses_repo"])
  let row = try #require(rows.first { $0.id == "ses_chat" })
  #expect(row.chat && row.requestCount == 1 && row.projectName == "ses_chat")
  #expect(rows.first { $0.id == "ses_repo" }?.chat == false)
}

private func chipProject(_ id: String) throws -> Project {
  try JSONDecoder().decode(Project.self, from: Data(#"{"id":"\#(id)","canonical":"/\#(id)","sandboxes":[]}"#.utf8))
}
private func chipEntry(
  _ id: String, project: String, directory: String, unread: Bool = false, permission: Bool = false
) throws -> NavigationEntry {
  var row: [String: JSONValue] = [
    "session": .object([
      "id": .string(id), "projectID": .string(project), "title": .string(id),
      "location": .object(["directory": .string(directory)]),
      "time": .object(["created": .number(100), "updated": .number(100), "viewed": .number(100)]),
    ])
  ]
  if unread { row["unreadAt"] = .number(200) }
  if permission { row["permissionAt"] = .number(300) }
  return try JSONDecoder().decode(NavigationEntry.self, from: JSONEncoder().encode(row))
}

/// Builds rows for chips "a"…"h": `running`/`unread` name the projects with such a session.
private func chipRows(running: Set<String>, unread: Set<String>, notify: Set<String> = []) throws -> [SessionRow] {
  let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
  var entries = try ids.map {
    try chipEntry("ses_" + $0, project: $0, directory: "/" + $0, unread: unread.contains($0))
  }
  entries.append(try chipEntry("ses_chat", project: "global", directory: "/chats/day/one", unread: unread.contains("chats")))
  let notifyKeys = entries.filter { notify.contains(String($0.session.id.dropFirst(4))) }.map(\.session.key)
  return SessionList.rows(
    entries: entries, projects: try ids.map(chipProject),
    active: Set(running.map { $0 == "chats" ? "ses_chat" : "ses_" + $0 }), pins: [], notify: notifyKeys,
    autoApprove: false, ranks: [:], chatRoot: "/chats")
}

@Test func chipGroupsOrderRunningThenUnreadThenManualThenName() throws {
  // Manual order c, a, b, d; e–h are new projects without a position (alphabetical), and Chats has none either.
  let chips = [
    ChipEntry(key: "chats", name: "Chats", position: nil),
    ChipEntry(key: "c", name: "c", position: 0), ChipEntry(key: "a", name: "a", position: 1),
    ChipEntry(key: "b", name: "b", position: 2), ChipEntry(key: "d", name: "d", position: 3),
    ChipEntry(key: "e", name: "Ônibus", position: nil), ChipEntry(key: "f", name: "app10", position: nil),
    ChipEntry(key: "g", name: "app9", position: nil), ChipEntry(key: "h", name: "Beta", position: nil),
  ]
  func order(running: Set<String> = [], unread: Set<String> = [], notify: Set<String> = []) throws -> [String] {
    SessionList.chipGroups(try chipRows(running: running, unread: unread, notify: notify), chips: chips, chats: "chats")
      .map(\.key)
  }
  // Level 3 then 4: manual positions, then natural case/accent-insensitive names (app9 < app10 < Beta < Chats < Ônibus).
  #expect(try order() == ["c", "a", "b", "d", "g", "f", "h", "chats", "e"])
  // Level 2: unread first, keeping manual/alphabetical order inside; a bell never hides unread (muting is gone).
  #expect(try order(unread: ["d", "h", "a"], notify: ["a"]) == ["a", "d", "h", "c", "b", "g", "f", "chats", "e"])
  // Level 1: running first; within it running + unread precede running only, then manual, then name.
  #expect(
    try order(running: ["b", "e", "d", "chats"], unread: ["e", "c"])
      == ["e", "b", "d", "chats", "c", "a", "g", "f", "h"])
  // Chats has no fixed place: it rises only by its own state.
  #expect(try order(running: ["chats"]).first == "chats")
  #expect(try order(unread: ["chats"]).first == "chats")
  // Finishing (running → unread) moves a chip from the first block into the unread block.
  #expect(try order(unread: ["b", "a"]) == ["a", "b", "c", "d", "g", "f", "h", "chats", "e"])
  // Counts are kept per chip.
  let groups = SessionList.chipGroups(try chipRows(running: ["a"], unread: []), chips: chips, chats: "chats")
  #expect(groups.first == ChipGroup(key: "a", running: true))
}

@Test func missingAndArchivedAncestorsNeverBecomeRoots() throws {
  let rows = SessionList.rows(
    entries: [
      try entry("ses_orphan", parent: "missing"),
      try entry("ses_archived", archived: true),
      try entry("ses_child", parent: "ses_archived"),
    ],
    projects: [], active: [], pins: [], notify: [], autoApprove: false, ranks: [:], chatRoot: nil)
  #expect(rows.isEmpty)
}

@Test func previewPrefersLatestVisibleMessageAndUsesToolActivity() throws {
  let data = Data(
    """
    {"data":[{"type":"idle","time":{"created":40}},
      {"type":"assistant","time":{"created":30},"content":[{"type":"text","text":"Concluído"},
      {"type":"tool","name":"shell","state":{"status":"running","input":{"command":"bun test"}}}]},
      {"type":"user","time":{"created":20},"text":"Teste"}]}
    """.utf8)
  let preview = SessionPreview(
    messages: try JSONDecoder().decode(TranscriptPage.self, from: data).data)
  #expect(preview.text == "Concluído")
  #expect(preview.activity == "rodando bun test")
}

@Test func unknownMessageDoesNotBreakTranscript() throws {
  let url = try #require(Bundle.module.url(forResource: "unknown-message", withExtension: "json"))
  let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(contentsOf: url))
  guard case .unknown(let type, _) = message else {
    Issue.record("Expected unknown message")
    return
  }
  #expect(type == "future-message")
}

@Test func sseCommentsAndMultilineData() {
  var parser = EventParser()
  #expect(parser.line(": heartbeat") == nil)
  #expect(parser.line("data: {\"type\":\"session.viewed\",") == nil)
  #expect(parser.line("data: \"data\":{\"sessionID\":\"ses_a\"}}") == nil)
  guard case .update(let event) = parser.line("") else {
    Issue.record("Expected event")
    return
  }
  #expect(event.type == "session.viewed")
  #expect(event.data.owner == "ses_a")
}

@Test func sseByteFramingPreservesEmptyLinesAndUTF8() {
  var parser = EventParser()
  let frame =
    ": heartbeat\r\n\r\ndata: {\"type\":\"rpc.custom.preferences.updated\",\"data\":{\"name\":\"Sessões\"}}\r\n\r\n"
  let events = frame.utf8.compactMap { parser.consume($0) }
  #expect(events.count == 1)
  guard case .update(let event) = events.first else {
    Issue.record("Expected a framed event")
    return
  }
  #expect(event.type == "rpc.custom.preferences.updated")
}

@Test func preferenceIntentUsesWebSessionKey() throws {
  let data = try JSONEncoder().encode(
    PreferenceIntent.notify(session: SessionPreferenceKey.encode("ses_a"), notify: true))
  let value = try JSONDecoder().decode([String: JSONValue].self, from: data)
  #expect(value["type"] == .string("sidebar.notify"))
  #expect(value["session"] == .string("[\"http://localhost:4096\",\"ses_a\"]"))
  #expect(value["notify"] == .bool(true))
}

@Test func sessionPreferencesMatchEveryServerAndLegacyBareIDs() {
  let keys = [
    "[\"http://localhost:4096\",\"ses_a\"]",
    "[\"https://another.example\",\"ses_a\"]",
    "[\"local\",\"ses_a\"]",
    "ses_a",
    "[\"local\",\"ses_b\"]",
    "[\"ses_a\"]", "[42,\"ses_a\"]", "broken JSON",
  ]
  #expect(SessionPreferenceKey.matching("ses_a", in: keys) == Array(keys.prefix(4)))
  #expect(SessionPreferenceKey.encode("ses_a") == "[\"http://localhost:4096\",\"ses_a\"]")
  #expect(SessionPreferenceKey.encode("ses_a/b").contains("ses_a/b"))
}

@Test func pinOrderUsesFirstMatchingStoredEntryAcrossServers() throws {
  let rows = SessionList.rows(
    entries: [
      try entry("ses_a", updated: 300), try entry("ses_b", updated: 200), try entry("ses_c"),
    ],
    projects: [], active: [],
    pins: ["[\"other\",\"ses_b\"]", "ses_c", "[\"local\",\"ses_a\"]", "[\"third\",\"ses_b\"]"],
    notify: ["[\"other\",\"ses_a\"]"], autoApprove: false, ranks: [:], chatRoot: nil)
  #expect(rows.map(\.id) == ["ses_b", "ses_c", "ses_a"])
  #expect(rows.allSatisfy { $0.pinned })
  #expect(rows.last?.notify == true)
}

@Test func chipManualOrderPlacesChatsAndMovesThroughOneIntent() throws {
  let projects = [(id: "a", directory: "/a"), (id: "b", directory: "/b"), (id: "c", directory: "/c")]
  func intent(_ value: PreferenceIntent?) throws -> JSONValue? {
    try value.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
  }
  // Without a saved position (older servers or profiles) Chats is first; a saved index is clamped.
  #expect(ChipManualOrder(projects: projects, chatsIndex: nil, showsChats: true).keys == ["custom.chats", "a", "b", "c"])
  #expect(ChipManualOrder(projects: projects, chatsIndex: 2, showsChats: true).keys == ["a", "b", "custom.chats", "c"])
  #expect(ChipManualOrder(projects: projects, chatsIndex: 9, showsChats: true).keys == ["a", "b", "c", "custom.chats"])
  #expect(ChipManualOrder(projects: projects, chatsIndex: 1, showsChats: false).keys == ["a", "b", "c"])
  let order = ChipManualOrder(projects: projects, chatsIndex: 1, showsChats: true)  // a, Chats, b, c
  let chats: JSONValue = .object(["type": .string("chats.move"), "server": .string("local"), "toIndex": .number(0)])
  #expect(try intent(order.move("custom.chats", by: -1)) == chats)
  #expect(try intent(order.move("custom.chats", by: 1))?.object?["toIndex"] == .number(2))
  // A repository passing Chats moves Chats the other way, keeping the repositories' saved order.
  #expect(try intent(order.move("a", by: 1)) == chats)
  #expect(try intent(order.move("b", by: -1))?.object?["toIndex"] == .number(2))
  #expect(
    try intent(order.move("b", by: 1))
      == .object([
        "type": .string("project.move"), "server": .string("local"), "directory": .string("/b"),
        "toIndex": .number(2),
      ]))
  #expect(order.move("a", by: -1) == nil)
  #expect(order.move("c", by: 1) == nil)
  #expect(ChipManualOrder(projects: projects, chatsIndex: nil, showsChats: true).move("custom.chats", by: -1) == nil)
  // Profiles saved before the Chats position still decode.
  let saved: Preferences = try JSONDecoder().decode(
    Preferences.self,
    from: Data(
      #"{"revision":1,"data":{"projects":{"local":{"projects":[{"worktree":"/a","expanded":true}]}},"pinnedSessions":[],"settings":{"autoApprove":false}}}"#
        .utf8))
  #expect(saved.data.projects["local"]?.chatsIndex == nil)
}
