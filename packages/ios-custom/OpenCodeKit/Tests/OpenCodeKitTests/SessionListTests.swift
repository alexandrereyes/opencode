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
    ], projects: [], active: ["ses_grandchild"], pins: [], muted: [], autoApprove: false,
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
    muted: [entries[1].session.key], autoApprove: false, ranks: [:], chatRoot: nil)
  #expect(rows.map(\.id) == ["ses_old", "ses_read", "ses_new"])
  #expect(rows.last?.unread == true)
  #expect(rows.last?.muted == true)
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

@Test func autoApprovalStillShowsQuestionsAndMutedAttention() throws {
  let root = try entry("ses_root", permission: true, question: true)
  let rows = SessionList.rows(
    entries: [root], projects: [], active: [root.session.id],
    pins: [], muted: [root.session.key], autoApprove: true, ranks: [:], chatRoot: nil)
  let row = try #require(rows.first)
  #expect(row.state == .question)
  #expect(SessionFilter.muted.includes(row))
  #expect(SessionFilter.attention.includes(row))
  #expect(!SessionFilter.running.includes(row))
}

@Test func managedChatsStayListedWithTheirOwnIdentity() throws {
  let chat = try entry("ses_chat", permission: true, directory: "/chats/day/session-a")
  let rows = SessionList.rows(
    entries: [chat, try entry("ses_repo")], projects: [], active: [], pins: [], muted: [],
    autoApprove: false, ranks: [:], chatRoot: "/chats")
  #expect(rows.map(\.id).sorted() == ["ses_chat", "ses_repo"])
  let row = try #require(rows.first { $0.id == "ses_chat" })
  #expect(row.chat && row.requestCount == 1 && row.projectName == "ses_chat")
  #expect(rows.first { $0.id == "ses_repo" }?.chat == false)
}

@Test func chipGroupsPutUnreadFirstKeepingManualOrderWithinEachHalf() throws {
  func project(_ id: String) throws -> Project {
    try JSONDecoder().decode(Project.self, from: Data(#"{"id":"\#(id)","canonical":"/\#(id)","sandboxes":[]}"#.utf8))
  }
  func entry(_ id: String, project: String, directory: String, unread: Bool = false, permission: Bool = false)
    throws -> NavigationEntry
  {
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
  let projects = try ["a", "b", "c", "d"].map(project)
  let entries = [
    try entry("ses_a", project: "a", directory: "/a"),
    try entry("ses_b", project: "b", directory: "/b", unread: true),
    try entry("ses_c", project: "c", directory: "/c", unread: true),
    try entry("ses_muted", project: "d", directory: "/d", unread: true, permission: true),
    try entry("ses_chat", project: "global", directory: "/chats/day/one"),
    try entry("ses_other", project: "z", directory: "/z", unread: true),
  ]
  let muted = entries[3].session.key
  let rows = SessionList.rows(
    entries: entries, projects: projects, active: ["ses_a"], pins: [], muted: [muted],
    autoApprove: false, ranks: [:], chatRoot: "/chats")
  let groups = SessionList.chipGroups(rows, manual: ["chats", "a", "c", "b", "d"], chats: "chats")
  // Muted unread rows keep the list's gray dot, so they do not mark their chip.
  #expect(groups.map(\.key) == ["c", "b", "chats", "a", "d"])
  #expect(groups.first { $0.key == "a" } == ChipGroup(key: "a", running: true))
  #expect(groups.first { $0.key == "d" } == ChipGroup(key: "d", requests: 1))
  // Reading a chat keeps the manual order of the remaining chips.
  let read = rows.filter { $0.id != "ses_b" && $0.id != "ses_c" }
  #expect(SessionList.chipGroups(read, manual: ["chats", "a", "c", "b", "d"], chats: "chats").map(\.key)
    == ["chats", "a", "c", "b", "d"])
}

@Test func missingAndArchivedAncestorsNeverBecomeRoots() throws {
  let rows = SessionList.rows(
    entries: [
      try entry("ses_orphan", parent: "missing"),
      try entry("ses_archived", archived: true),
      try entry("ses_child", parent: "ses_archived"),
    ],
    projects: [], active: [], pins: [], muted: [], autoApprove: false, ranks: [:], chatRoot: nil)
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
    PreferenceIntent.mute(session: SessionPreferenceKey.encode("ses_a"), muted: true))
  let value = try JSONDecoder().decode([String: JSONValue].self, from: data)
  #expect(value["type"] == .string("sidebar.mute"))
  #expect(value["session"] == .string("[\"http://localhost:4096\",\"ses_a\"]"))
  #expect(value["muted"] == .bool(true))
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
    muted: ["[\"other\",\"ses_a\"]"], autoApprove: false, ranks: [:], chatRoot: nil)
  #expect(rows.map(\.id) == ["ses_b", "ses_c", "ses_a"])
  #expect(rows.allSatisfy { $0.pinned })
  #expect(rows.last?.muted == true)
}
