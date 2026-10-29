import Foundation
import Testing

@testable import OpenCodeKit

private let zone = TimeZone(identifier: "America/Sao_Paulo")!
private var calendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  return calendar
}
/// Tuesday, 27 October 2026, 10:00 in São Paulo.
private let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10))!
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
  calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    .timeIntervalSince1970 * 1000
}

private func entry(
  _ id: String, message: Double, outcome: String? = nil, idle: Double? = nil, viewed: Double? = nil,
  permission: Bool = false, question: Bool = false, directory: String = "/repo", archived: Double? = nil
) throws -> NavigationEntry {
  var time: [String: JSONValue] = ["created": .number(message), "updated": .number(message)]
  if let archived { time["archived"] = .number(archived) }
  if let idle { time["idle"] = .number(idle) }
  if let viewed { time["viewed"] = .number(viewed) }
  var session: [String: JSONValue] = [
    "id": .string(id), "projectID": .string("project"), "title": .string(id),
    "location": .object(["directory": .string(directory)]), "time": .object(time),
  ]
  if let outcome { session["outcome"] = .string(outcome) }
  var row: [String: JSONValue] = ["session": .object(session), "messageAt": .number(message)]
  if permission { row["permissionAt"] = .number(message) }
  if question { row["questionAt"] = .number(message) }
  return try JSONDecoder().decode(NavigationEntry.self, from: JSONEncoder().encode(row))
}

private func rows(
  _ entries: [NavigationEntry], active: Set<String> = [], pins: [String] = [], chatRoot: String? = nil
) -> [SessionRow] {
  SessionList.rows(
    entries: entries, projects: [], active: active, pins: pins.map(SessionPreferenceKey.encode), notify: [],
    autoApprove: false, ranks: [:], chatRoot: chatRoot)
}

@Test func failureIsUnseenFailedOutcomeAndRanksBelowRunning() throws {
  let failed = try entry("ses_failed", message: at(27, 9), outcome: "failed", idle: at(27, 9), viewed: at(27, 8))
  let seen = try entry("ses_seen", message: at(27, 9), outcome: "failed", idle: at(27, 9), viewed: at(27, 9, 1))
  let interrupted = try entry("ses_stop", message: at(27, 9), outcome: "interrupted", idle: at(27, 9))
  let rerun = try entry("ses_rerun", message: at(27, 9), outcome: "failed", idle: at(27, 9))
  let asking = try entry(
    "ses_ask", message: at(27, 9), outcome: "failed", idle: at(27, 9), question: true)
  let states = Dictionary(
    uniqueKeysWithValues: rows([failed, seen, interrupted, rerun, asking], active: ["ses_rerun"])
      .map { ($0.id, $0.state) })
  #expect(states["ses_failed"] == .failed)
  #expect(states["ses_seen"] == .stopped)
  #expect(states["ses_stop"] == .stopped)
  #expect(states["ses_rerun"] == .running)
  #expect(states["ses_ask"] == .question)
  // Precedence follows the raw order: permission > question > running > failed > unread > stopped.
  #expect(
    [SessionState.permission, .question, .running, .failed, .unread, .stopped].map(\.rawValue)
      == [5, 4, 3, 2, 1, 0])
  let row = try #require(rows([failed]).first)
  #expect(row.needsYou && SessionFilter.attention.includes(row))
}

@Test func sectionsFollowPriorityPinsAndLocalDays() throws {
  let entries = [
    try entry("ses_question", message: at(27, 9, 58), question: true),
    try entry("ses_failed_old", message: at(27, 8), outcome: "failed", idle: at(27, 8)),
    try entry("ses_permission", message: at(27, 9, 50), permission: true),
    try entry("ses_failed_new", message: at(27, 9), outcome: "failed", idle: at(27, 9, 48)),
    try entry("ses_running", message: at(27, 9, 55)),
    try entry("ses_running_pinned", message: at(27, 9, 54)),
    try entry("ses_pinned", message: at(10, 9)),
    try entry("ses_today", message: at(27, 0, 1)),
    try entry("ses_future", message: at(27, 11)),
    try entry("ses_yesterday", message: at(26, 23, 59)),
    try entry("ses_two_days", message: at(25, 23)),
    try entry("ses_six_days", message: at(21, 0)),
    try entry("ses_older", message: at(20, 23, 59)),
  ]
  let list = rows(entries, active: ["ses_running", "ses_running_pinned"], pins: ["ses_running_pinned", "ses_pinned"])
  let sections = SessionSections.group(list, now: now, calendar: calendar)
  #expect(sections.map(\.kind) == [.attention, .running, .pinned, .today, .yesterday, .week, .older])
  #expect(
    sections[0].rows.map(\.id) == ["ses_permission", "ses_question", "ses_failed_new", "ses_failed_old"])
  // A running pinned session stays in Trabalhando, in the rows' (pinned-first) order.
  #expect(sections[1].rows.map(\.id) == ["ses_running_pinned", "ses_running"])
  #expect(sections[2].rows.map(\.id) == ["ses_pinned"])
  #expect(Set(sections[3].rows.map(\.id)) == ["ses_today", "ses_future"])
  #expect(sections[4].rows.map(\.id) == ["ses_yesterday"])
  // "Esta semana" completes the seven local days: two to six days ago, in the rows' order.
  #expect(sections[5].rows.map(\.id) == ["ses_two_days", "ses_six_days"])
  #expect(sections[6].rows.map(\.id) == ["ses_older"])
  #expect(sections.map(\.title)
    == ["Precisa de você", "Trabalhando", "Fixadas", "Hoje", "Ontem", "Esta semana", "Anteriores"])
}

@Test func localDaysFollowTheCalendarAcrossDaylightSavingChanges() throws {
  // Santiago moved its clocks forward at midnight on 6 September 2026; that day has no 00:00.
  var chile = Calendar(identifier: .gregorian)
  chile.timeZone = TimeZone(identifier: "America/Santiago")!
  let date = { (day: Int, hour: Int) in
    chile.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!.timeIntervalSince1970 * 1000
  }
  let list = rows([
    try entry("ses_yesterday", message: date(6, 1)),
    try entry("ses_week", message: date(1, 12)),
    try entry("ses_older", message: date(1, 0) - 3_600_000),
  ])
  let now = chile.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9))!
  let sections = SessionSections.group(list, now: now, calendar: chile)
  #expect(sections.map(\.kind) == [.yesterday, .week, .older])
}

@Test func allMixesEveryChatWithRepositorySessionsUnderTheSameSections() throws {
  let entries = [
    try entry("ses_chat_ask", message: at(27, 9), permission: true, directory: "/chats/a"),
    try entry("ses_chat_run", message: at(27, 9, 30), directory: "/chats/c"),
    try entry("ses_chat_pin", message: at(20, 9), directory: "/chats/d"),
    try entry("ses_chat", message: at(27, 9), directory: "/chats/b"),
    try entry("ses_chat_old", message: at(26, 9), directory: "/chats/e"),
    try entry("ses_repo", message: at(27, 8)),
    // Archived chats stay out (the store also drops the Sessão mestra by ID before building rows).
    try entry("ses_chat_archived", message: at(27, 9), directory: "/chats/f", archived: at(27, 9, 1)),
  ]
  let list = rows(entries, active: ["ses_chat_run"], pins: ["ses_chat_pin"], chatRoot: "/chats")
  // "Todas": chats join every section like repository sessions.
  let all = SessionSections.group(list, now: now, calendar: calendar)
  #expect(all.map(\.kind) == [.attention, .running, .pinned, .today, .yesterday])
  #expect(all.map { $0.rows.map(\.id) }
    == [["ses_chat_ask"], ["ses_chat_run"], ["ses_chat_pin"], ["ses_chat", "ses_repo"], ["ses_chat_old"]])
  // Mixed, every chat shares the chat avatar; under the Chats filter none does, and repositories never do.
  #expect(list.filter { $0.sharesChatAvatar(mixed: true) }.map(\.id).sorted()
    == ["ses_chat", "ses_chat_ask", "ses_chat_old", "ses_chat_pin", "ses_chat_run"])
  #expect(!list.contains { $0.sharesChatAvatar(mixed: false) })
  // The Chats chip passes only chats; a repository chip none (the store narrows the rows before grouping).
  let chats = SessionSections.group(list.filter(\.chat), now: now, calendar: calendar)
  #expect(chats.flatMap { $0.rows.map(\.id) }.sorted()
    == ["ses_chat", "ses_chat_ask", "ses_chat_old", "ses_chat_pin", "ses_chat_run"])
  #expect(SessionSections.group(list.filter { !$0.chat }, now: now, calendar: calendar)
    .flatMap { $0.rows.map(\.id) } == ["ses_repo"])
  #expect(SessionDirectoryLabel.chats.accessibilityLabel == "Chats")
}

@Test func attentionDetailsAndElapsedTime() throws {
  let list = rows([
    try entry("ses_p", message: at(27, 9), permission: true),
    try entry("ses_q", message: at(27, 9), question: true),
    try entry("ses_f", message: at(27, 9), outcome: "failed", idle: at(27, 9, 48)),
  ])
  let row = { (id: String) in list.first { $0.id == id }! }
  #expect(SessionSections.detail(row("ses_p"), permission: "Quer rodar: git push", question: nil, failure: nil)
    == "permissão · Quer rodar: git push")
  #expect(SessionSections.detail(row("ses_q"), permission: nil, question: "Qual banco?", failure: nil)
    == "pergunta · Qual banco?")
  #expect(SessionSections.detail(row("ses_f"), permission: nil, question: nil, failure: "bun test falhou", now: now)
    == "erro · bun test falhou · há 12 min")
  #expect(SessionSections.detail(row("ses_f"), permission: nil, question: nil, failure: nil, now: now)
    == "erro · parou com erro · há 12 min")
  #expect(SessionSections.elapsed(at(27, 9, 59) + 30_000, now: now) == "agora")
  #expect(SessionSections.elapsed(at(27, 7), now: now) == "há 3 h")
  #expect(SessionSections.elapsed(at(25, 9), now: now) == "há 2 d")
}

@Test func collapseStateDefaultsAndPersistsOnlyChanges() {
  var collapse = SessionSectionCollapse()
  #expect(collapse.collapsed(.older) && !collapse.collapsed(.attention))
  collapse.toggle(.older)
  collapse.toggle(.today)
  #expect(!collapse.collapsed(.older) && collapse.collapsed(.today))
  let restored = SessionSectionCollapse(rawValue: collapse.rawValue)
  #expect(restored == collapse)
  #expect(collapse.rawValue == #"{"older":false,"today":true}"#)
  collapse.toggle(.older)
  collapse.toggle(.today)
  #expect(collapse.rawValue == "{}")
  #expect(SessionSectionCollapse(rawValue: "broken") == SessionSectionCollapse())
}

@Test func idleMessagesDecodeAndExposeTheLatestFailure() throws {
  let data = Data(
    """
    {"data":[{"type":"idle","outcome":"failed","time":{"created":40},
      "error":{"type":"provider","message":"bun test\\n  falhou"}},
      {"type":"assistant","time":{"created":30},"content":[{"type":"text","text":"Rodando testes"}]}]}
    """.utf8)
  let messages = try JSONDecoder().decode(TranscriptPage.self, from: data).data
  guard case .idle(let idle) = messages[0] else {
    Issue.record("Expected an idle message")
    return
  }
  #expect(idle.outcome == .failed && idle.error?.message == "bun test\n  falhou" && messages[0].created == 40)
  let preview = SessionPreview(messages: messages)
  #expect(preview.failure == "bun test falhou")
  #expect(preview.text == "Rodando testes")
  let encoded = try JSONDecoder().decode(
    TranscriptMessage.self, from: JSONEncoder().encode(messages[0]))
  guard case .idle(let roundTrip) = encoded else {
    Issue.record("Expected an encoded idle message")
    return
  }
  #expect(roundTrip.outcome == .failed)

  let later = Data(
    """
    [{"type":"user","time":{"created":50},"text":"De novo"},
     {"type":"idle","outcome":"failed","time":{"created":40},"error":{"type":"x","message":"falhou"}}]
    """.utf8)
  #expect(SessionPreview(messages: try JSONDecoder().decode([TranscriptMessage].self, from: later)).failure == nil)
  let success = Data(#"[{"type":"idle","outcome":"succeeded","time":{"created":40}}]"#.utf8)
  #expect(SessionPreview(messages: try JSONDecoder().decode([TranscriptMessage].self, from: success)).failure == nil)
  let silent = Data(#"[{"type":"idle","outcome":"failed","time":{"created":40}}]"#.utf8)
  #expect(SessionPreview(messages: try JSONDecoder().decode([TranscriptMessage].self, from: silent)).failure == nil)
}

@Test func precisaDeVoceListsUnreadAnswersAfterFailuresNewestFirst() throws {
  let list = rows([
    try entry("ses_reply_old", message: at(27, 9, 10), outcome: "succeeded", idle: at(27, 9, 10)),
    try entry("ses_question", message: at(27, 9), question: true),
    try entry("ses_failed", message: at(27, 9), outcome: "failed", idle: at(27, 9)),
    try entry("ses_reply_new", message: at(27, 9, 30), outcome: "succeeded", idle: at(27, 9, 30)),
    try entry("ses_permission", message: at(27, 8), permission: true),
    try entry("ses_pinned_reply", message: at(27, 9, 20), outcome: "succeeded", idle: at(27, 9, 20)),
    // Working (a new run, or a background shell) outranks the unread answer.
    try entry("ses_running_unread", message: at(27, 9, 40), outcome: "succeeded", idle: at(27, 9, 40)),
    try entry("ses_read", message: at(27, 9), outcome: "succeeded", idle: at(27, 9), viewed: at(27, 9)),
  ], active: ["ses_running_unread"], pins: ["ses_pinned_reply"])
  let sections = SessionSections.group(list, now: now, calendar: calendar)
  #expect(sections.map(\.kind) == [.attention, .running, .today])
  #expect(sections[0].rows.map(\.id) == [
    "ses_permission", "ses_question", "ses_failed", "ses_reply_new", "ses_pinned_reply", "ses_reply_old",
  ])
  #expect(sections[1].rows.map(\.id) == ["ses_running_unread"])
  #expect(sections[2].rows.map(\.id) == ["ses_read"])
  // One per root: the unread failure counts once, the working unread session not at all.
  let failed = try #require(list.first { $0.id == "ses_failed" })
  #expect(failed.unread && SessionAttention.reason(failed) == .failed)
  #expect(SessionAttention.count(list) == 6 && SessionAttention.ordered(list).map(\.id) == sections[0].rows.map(\.id))
  #expect(list.filter(SessionFilter.attention.includes).count == 6)
  let reply = try #require(list.first { $0.id == "ses_reply_new" })
  #expect(SessionSections.detail(reply, permission: nil, question: nil, failure: nil, reply: "Os testes passaram")
    == "respondeu · Os testes passaram")
  #expect(SessionSections.detail(reply, permission: nil, question: nil, failure: nil, reply: "") == "respondeu")
}

@Test func anOpenAnswerKeepsItsPlaceUntilItsConversationCloses() throws {
  let failed = try entry("ses_failed", message: at(27, 9), outcome: "failed", idle: at(27, 9))
  let read = try entry("ses_read", message: at(27, 8), outcome: "succeeded", idle: at(27, 8), viewed: at(27, 8))
  let replyA = { (viewed: Double?) in
    try entry("ses_a", message: at(27, 9, 30), outcome: "succeeded", idle: at(27, 9, 30), viewed: viewed)
  }
  let replyB = { (idle: Double, viewed: Double?) in
    try entry("ses_b", message: idle, outcome: "succeeded", idle: idle, viewed: viewed)
  }
  let before = rows([failed, try replyA(nil), try replyB(at(27, 9, 10), nil), read])
  var hold = SessionAttentionHold()
  hold.update(open: ["ses_a"], rows: before)
  // Opening marks it viewed: without the dot it stays where it was, and no longer counts.
  let reading = rows([failed, try replyA(at(27, 9, 30)), try replyB(at(27, 9, 10), nil), read])
  let a = try #require(reading.first { $0.id == "ses_a" })
  #expect(!a.unread && a.state == .stopped && hold.reason(a) == .replied)
  let held = SessionSections.group(reading, now: now, held: hold, calendar: calendar)
  #expect(held.map(\.kind) == [.attention, .today])
  #expect(held[0].rows.map(\.id) == ["ses_failed", "ses_a", "ses_b"])
  #expect(SessionAttention.count(held[0].rows) == 2)
  #expect(SessionSections.detail(a, reason: hold.reason(a), permission: nil, question: nil, failure: nil, reply: "Pronto")
    == "respondeu · Pronto")
  // Without the hold (another list, or after closing) it follows the normal flow.
  #expect(SessionSections.group(reading, now: now, calendar: calendar)[0].rows.map(\.id) == ["ses_failed", "ses_b"])
  // Opening another conversation lets it go; the new one is held. A read row opened from Hoje is never held.
  hold.update(open: ["ses_b", "ses_read"], rows: reading)
  let switched = rows([failed, try replyA(at(27, 9, 30)), try replyB(at(27, 9, 10), at(27, 9, 10)), read])
  let sections = SessionSections.group(switched, now: now, held: hold, calendar: calendar)
  #expect(sections[0].rows.map(\.id) == ["ses_failed", "ses_b"])
  #expect(Set(sections[1].rows.map(\.id)) == ["ses_a", "ses_read"])
  // Running again releases it, and a newer run that finishes while it is open is read, not held.
  #expect(SessionSections.group(rows([failed, try replyB(at(27, 9, 10), at(27, 9, 10))], active: ["ses_b"]),
    now: now, held: hold, calendar: calendar).map(\.kind) == [.attention, .running])
  let rerun = rows([failed, try replyB(at(27, 9, 50), at(27, 9, 50))])
  #expect(SessionSections.group(rerun, now: now, held: hold, calendar: calendar)[0].rows.map(\.id) == ["ses_failed"])
  // Closing every conversation lets everything go.
  hold.update(open: [], rows: switched)
  #expect(hold == SessionAttentionHold())
}
