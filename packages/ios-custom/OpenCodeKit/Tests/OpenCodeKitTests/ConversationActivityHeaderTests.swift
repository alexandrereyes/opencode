import Foundation
import Testing

@testable import OpenCodeKit

private func timedTool(_ id: String, _ name: String, status: String = "completed", input: [String: JSONValue] = [:],
  created: Double, ran: Double? = nil, completed: Double? = nil, metadata: [String: JSONValue] = [:]) -> ConversationActivityPart {
  ConversationActivityPart(id: id, messageID: "m", part: ConversationPart(type: "tool", id: id, name: name, state: .object([
    "status": .string(status), "input": .object(input), "metadata": .object(metadata),
  ]), time: MessageTime(created: created, ran: ran, completed: completed)))
}
private func thought(_ id: String, created: Double, completed: Double?, thinking: Bool = false) -> ConversationActivityPart {
  ConversationActivityPart(id: id, messageID: "m", part: ConversationPart(type: "reasoning", text: "Conferir",
    time: MessageTime(created: created, completed: completed)), thinking: thinking)
}
private func message(_ id: String, _ type: String, created: Double) -> ConversationMessage {
  ConversationMessage(id: id, type: type, time: MessageTime(created: created))
}

@Test func activityHeaderJoinsTitlesCountAndWallClockSpan() {
  let parts = [
    timedTool("a", "read", input: ["path": .string("Sources/SessionsView.swift")], created: 1_000, completed: 13_000),
    thought("r", created: 13_000, completed: 20_000),
    timedTool("b", "shell", input: ["command": .string("git status")], created: 20_000, ran: 21_000, completed: 27_000),
    timedTool("c", "subagent", created: 30_000, completed: 102_000),
    timedTool("d", "edit", created: 103_000, completed: 151_000),
    timedTool("e", "read", created: 152_000, completed: 241_000),
  ]
  let header = ConversationActivityHeader(parts, now: 999_999)
  #expect(header.title == "Atividade")
  #expect(header.details == ["Ler, Shell, Agente e Editar", "5 ferramentas", "4m0s"])
  #expect(header.label == "Atividade · Ler, Shell, Agente e Editar · 5 ferramentas · 4m0s")
}

@Test func activityHeaderCountsOneToolAndOmitsAnUnknownDuration() {
  let untimed = ConversationActivityPart(id: "a", messageID: "m",
    part: ConversationPart(type: "tool", id: "a", name: "grep", state: .object(["status": .string("completed")])))
  #expect(ConversationActivityHeader([untimed], now: 5_000).label == "Atividade · Grep · 1 ferramenta")
  // A failed call without an end does not stretch the span; reasoning without tools never counts as one.
  let failed = timedTool("f", "shell", status: "error", created: 0)
  #expect(ConversationActivityHeader([failed, timedTool("g", "read", created: 2_000, completed: 5_000)], now: 60_000).details
    == ["Shell e Ler", "2 ferramentas", "3s"])
}

@Test func activityHeaderRunningSpanEndsNow() {
  let parts = [timedTool("a", "read", created: 0, completed: 4_000), timedTool("b", "shell", status: "running", created: 5_000)]
  #expect(ConversationActivityHeader(parts, now: 65_000).details.last == "1m5s")
  #expect(ConversationActivityHeader(parts, now: 125_000).details.last == "2m5s")
}

@Test func activityHeaderReasoningAloneThinksOrSaysHowLongItThought() {
  #expect(ConversationActivityHeader([thought("a", created: 0, completed: 2_400), thought("b", created: 5_000, completed: 6_300)], now: 0).label
    == "Pensou 4s")
  #expect(ConversationActivityHeader([thought("a", created: 0, completed: 2_400), thought("b", created: 5_000, completed: nil, thinking: true)], now: 0).label
    == "Pensando")
  #expect(ConversationActivityHeader([thought("a", created: 0, completed: nil)], now: 0).label == "Atividade · Raciocínio")
  #expect(ConversationActivityHeader([thought("a", created: 0, completed: nil), thought("b", created: 0, completed: nil)], now: 0).label
    == "Atividade · Raciocínios")
  var notice = ConversationActivityPart(id: "n", messageID: "n", part: ConversationPart(type: "notice"))
  notice.notice = message("n", "system", created: 0)
  #expect(ConversationActivityHeader([notice], now: 0).label == "Atividade · Atualizações")
}

@Test func activityItemDurationsAddMemberRunTimesOnlyWhenAllFinished() {
  let shell = timedTool("s", "shell", created: 20_000, ran: 21_000, completed: 27_000)
  let items = ConversationActivityItem.project([
    timedTool("a", "read", input: ["path": .string("a.swift")], created: 0, completed: 12_000),
    timedTool("b", "read", input: ["path": .string("b.swift")], created: 12_000, completed: 15_000),
    shell,
    timedTool("e", "edit", status: "running", input: ["path": .string("c.swift")], created: 30_000),
  ])
  #expect(items.map(\.kind) == [.read, .part, .files])
  #expect(items.map(\.duration) == [15_000, 6_000, nil])
  #expect(items.map(\.completed) == [true, true, false])
  let untimed = ConversationActivityItem.project([ConversationActivityPart(id: "x", messageID: "m",
    part: ConversationPart(type: "tool", id: "x", name: "grep", state: .object(["status": .string("completed")])))])
  #expect(untimed.first?.duration == nil)
  #expect(untimed.first?.completed == true)
}

@Test func activityItemFailuresAndUnfinishedReasoningAreNotCompleted() {
  let failed = ConversationActivityItem.project([timedTool("f", "shell", created: 0, completed: 1_000, metadata: ["exit": .number(2)])])
  #expect(failed.first?.completed == false)
  #expect(failed.first?.duration == 1_000)
  let thinking = ConversationActivityItem.project([thought("t", created: 0, completed: nil, thinking: true)])
  #expect(thinking.first?.completed == false)
  #expect(ConversationActivityItem.project([thought("t", created: 0, completed: 3_000)]).first?.completed == true)
}

@Test func activityTargetsNameWhatEachCallActedOn() {
  #expect(timedTool("a", "shell", input: ["command": .string("git status")], created: 0).part.activityTarget == "git status")
  #expect(timedTool("a", "read", input: ["path": .string("/x/SessionsView.swift"), "offset": .number(4)], created: 0).part.activityTarget
    == "SessionsView.swift offset=4")
  #expect(timedTool("a", "websearch", input: ["query": .string("swiftui")], created: 0).part.activityTarget == "swiftui")
  #expect(timedTool("a", "iphone_query", input: ["source": .string("health")], created: 0).part.activityTarget == "Saúde")
  #expect(timedTool("a", "iphone_status", created: 0).part.activityTarget == "estado")
  var failed = timedTool("a", "read", status: "error", created: 0).part
  failed.state = .object(["status": .string("error"), "error": .object(["message": .string("Error: File not found: /x")])])
  #expect(failed.activityTarget == "File not found")
  #expect(timedTool("a", "execute", created: 0).part.activityTarget == "")
}

@Test func executionStartsAtTheFirstStepAfterTheLatestBoundary() {
  let history = [
    message("u1", "user", created: 1_000), message("a1", "assistant", created: 2_000), message("i1", "idle", created: 3_000),
    message("u2", "user", created: 4_000), message("a2", "assistant", created: 5_000), message("a3", "assistant", created: 9_000),
  ]
  #expect(ConversationProjection.executionStarted(history, complete: false) == 5_000)
  // Without a boundary a partial page could hide the real start; a complete history cannot.
  let first = Array(history.prefix(2))
  #expect(ConversationProjection.executionStarted(first, complete: false) == nil)
  #expect(ConversationProjection.executionStarted(first, complete: true) == 2_000)
  // Admitted but no step yet.
  #expect(ConversationProjection.executionStarted(Array(history.prefix(4)), complete: true) == nil)
}
