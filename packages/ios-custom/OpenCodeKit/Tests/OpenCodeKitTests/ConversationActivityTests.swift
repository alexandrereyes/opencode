import Foundation
import Testing

@testable import OpenCodeKit

private func activityTool(_ id: String, _ name: String = "read", status: String = "completed",
  metadata: [String: JSONValue] = [:]) -> ConversationPart {
  ConversationPart(type: "tool", id: id, name: name, state: .object([
    "status": .string(status), "input": .object(["path": .string("docs/example.md")]),
    "metadata": .object(metadata),
  ]))
}
private func activityMessage(_ id: String, _ parts: [ConversationPart] = [], type: String = "assistant") -> ConversationMessage {
  var message = ConversationMessage(id: id, type: type, time: MessageTime(created: 1))
  message.content = parts
  return message
}
private func activityGroups(_ value: ConversationActivity) -> [ConversationActivityRow] {
  value.messages.flatMap(\.rows).filter { $0.kind == .group }
}

@Test func activityMergesAcrossStepsInWireOrder() {
  let value = ConversationActivity.project([
    activityMessage("user", type: "user"),
    activityMessage("first", [activityTool("a", "grep"), activityTool("b")]),
    activityMessage("second", [activityTool("c")]),
    activityMessage("third", [activityTool("d", "shell")]),
  ])
  #expect(activityGroups(value).count == 1)
  #expect(activityGroups(value).first?.parts.map(\.id) == ["a", "b", "c", "d"])
  #expect(activityGroups(value).first?.label == "Usou 4 · Grep, Ler e Shell")
  #expect(value.messages.map(\.id) == ["user", "first"])
  #expect(value.anchors["third"] == "first")
}

@Test func activityTextAndUserBreakGroups() {
  let value = ConversationActivity.project([
    activityMessage("a", [activityTool("a"), ConversationPart(type: "text", text: "Explicação"), activityTool("b")]),
    activityMessage("user", type: "user"), activityMessage("c", [activityTool("c")]),
  ])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == [.group, .text, .group, .group])
  #expect(activityGroups(value).map { $0.parts.map(\.id) } == [["a"], ["b"], ["c"]])
}

@Test(arguments: ["synthetic", "system", "skill", "agent-switched", "model-switched", "location-switched", "compaction", "shell", "future-kind"])
func activityVisibleNoticeBreaksGroups(_ type: String) {
  let value = ConversationActivity.project([
    activityMessage("a", [activityTool("a")]), activityMessage("notice", type: type),
    activityMessage("b", [activityTool("b")]),
  ])
  #expect(activityGroups(value).count == 2)
  #expect(value.messages.map(\.id) == ["a", "notice", "b"])
}

@Test func activityErrorsAndRetriesBreakGroups() {
  for retry in [false, true] {
    var message = activityMessage("a", [activityTool("a")])
    if retry { message.retry = .object(["attempt": .number(1)]) }
    if !retry { message.error = .object(["message": .string("Falha de teste")]) }
    #expect(activityGroups(ConversationActivity.project([message, activityMessage("b", [activityTool("b")])])).count == 2)
  }
  var idle = activityMessage("idle", type: "idle")
  idle.outcome = "failed"
  #expect(activityGroups(ConversationActivity.project([activityMessage("a", [activityTool("a")]), idle,
    activityMessage("b", [activityTool("b")])])).count == 2)
}

@Test(arguments: ["subagent", "task", "question"])
func activityCardsStayOutsideGroup(_ name: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a"), activityTool("card", name), activityTool("b")])])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == [.group, .tool, .group])
}

@Test(arguments: ["edit", "write", "patch", "apply_patch"])
func activityDiffsStayOutsideGroup(_ name: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a"),
    activityTool("diff", name, metadata: ["files": .array([.object(["file": .string("example.swift"), "patch": .string("+example")])])]),
    activityTool("b")])])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == [.group, .tool, .group])
  #expect(value.messages.first?.rows[1].parts.first?.part.diffs.count == 1)
}

@Test func activityEditDoesNotMoveBetweenGroupAndCardWhenItsDiffArrives() {
  let first = ConversationActivity.project([activityMessage("a", [activityTool("read"), activityTool("edit", "edit", status: "streaming")])])
  let next = ConversationActivity.project([activityMessage("a", [activityTool("read"), activityTool("edit", "edit", metadata: [
    "files": .array([.object(["file": .string("example.swift"), "patch": .string("+example")])])
  ])])], previous: first)
  #expect(first.messages.flatMap(\.rows).map(\.kind) == [.group, .tool])
  #expect(next.messages.flatMap(\.rows).map(\.id) == first.messages.flatMap(\.rows).map(\.id))
}

@Test func activityPermissionsAndPendingQuestionsDelimitWork() {
  let messages = [activityMessage("a", [activityTool("a"), activityTool("waiting", "shell", status: "running"), activityTool("b")])]
  #expect(ConversationActivity.project(messages, separateTools: ["waiting"]).messages.flatMap(\.rows).map(\.kind) == [.group, .tool, .group])
  let questions = ConversationActivity.project([activityMessage("a", [activityTool("a"), activityTool("q", "question", status: "running"), activityTool("b")])])
  #expect(activityGroups(questions).count == 2)
  #expect(questions.messages.flatMap(\.rows).flatMap(\.parts).contains { $0.id == "q" } == false)
}

@Test func activityHiddenContentDoesNotBreakAndKeepsOrdinals() {
  let value = ConversationActivity.project([
    activityMessage("a", [ConversationPart(type: "reasoning", text: " "), activityTool("removed", "todowrite", status: "error"), activityTool("a"),
      ConversationPart(type: "text", text: "\n "), ConversationPart(type: "reasoning", text: "Conferir dados")]),
    activityMessage("empty"), activityMessage("idle", type: "idle"), activityMessage("b", [activityTool("b")]),
  ])
  #expect(activityGroups(value).count == 1)
  #expect(activityGroups(value).first?.parts.map(\.id) == ["a", "a:reasoning:1", "b"])
  #expect(activityGroups(value).first?.label == "Usou 2 · Ler")
}

@Test func activityInvisiblePartsDoNotCreateFinalAnswerBoundaries() {
  var message = activityMessage("a", [ConversationPart(type: "reasoning", text: " "),
    ConversationPart(type: "text", text: "\n"), ConversationPart(type: "text", text: "Resposta")])
  message.finish = "stop"
  message.time.completed = 2
  #expect(ConversationProjection.finalAnswerDividers([message]).isEmpty)
  #expect(ConversationActivity.project([message]).messages.first?.rows.first?.parts.first?.id == "a:text:1")
}

@Test func activityReasoningCountAndPluralAreIndependentOfTools() {
  let thought = ConversationPart(type: "reasoning", text: "Conferir", time: MessageTime(created: 100, completed: 900))
  let one = ConversationActivity.project([activityMessage("a", [thought])])
  #expect(activityGroups(one).first?.label == "Usou 1 · Raciocínio")
  let two = ConversationActivity.project([activityMessage("a", [thought]), activityMessage("b", [thought])])
  #expect(activityGroups(two).first?.label == "Usou 2 · Raciocínios")
  #expect(activityGroups(two).first?.parts.map(\.id) == ["a:reasoning:0", "b:reasoning:0"])
  #expect(activityGroups(two).first?.parts.first?.part.time?.completed == 900)
  #expect(activityGroups(two).first?.parts.first?.reasoningLabel == "Pensou 1s")
  #expect(ConversationActivityPart(id: "r", messageID: "a", part: ConversationPart(type: "reasoning"), thinking: true).reasoningLabel == "Pensando")
  #expect(ConversationActivityPart(id: "r", messageID: "a", part: ConversationPart(type: "reasoning")).reasoningLabel == "Pensou")
}

@Test func activityRunningAndFailedToolsKeepOrderAndCount() {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("running", status: "running"),
    activityTool("failed", "execute", status: "error"), activityTool("streaming", "shell", status: "streaming")])])
  #expect(activityGroups(value).first?.pending == true)
  #expect(activityGroups(value).first?.label == "Usou 3 · Ler, Execute e Shell")
  #expect(activityGroups(value).first?.parts.map { $0.part.status } == ["running", "error", "streaming"])
  #expect(activityGroups(value).first?.parts[1].part.failed == true)
}

@Test func activityShellProcessFailureDoesNotRewriteItsCompletedWireStatus() {
  for metadata in [["exit": JSONValue.number(2)], ["timeout": .bool(true)]] {
    let part = activityTool("shell", "shell", metadata: metadata)
    let group = activityGroups(ConversationActivity.project([activityMessage("a", [part])])).first
    #expect(group?.parts.first?.part.status == "completed")
    #expect(group?.parts.first?.part.failed == true)
    #expect(group?.pending == false)
    #expect(group?.label == "Usou 1 · Shell")
  }
}

@Test func activityOnlyTheCurrentUnfinishedReasoningIsThinking() {
  let thought = ConversationPart(type: "reasoning", text: "Conferir")
  let messages = [activityMessage("old", [thought]), activityMessage("new", [thought])]
  let value = ConversationActivity.project(messages, executing: true)
  #expect(activityGroups(value).first?.parts.map(\.thinking) == [false, true])
  #expect(activityGroups(value).first?.pending == true)
  #expect(activityGroups(ConversationActivity.project(messages)).first?.parts.map(\.thinking) == [false, false])
  let waiting = ConversationActivity.project(messages + [activityMessage("user", type: "user"), activityMessage("empty")], executing: true)
  #expect(activityGroups(waiting).first?.pending == false)
  #expect(activityGroups(waiting).first?.parts.map(\.thinking) == [false, false])
}

@Test func activityStreamingPreservesIdentityAndAnchor() throws {
  let messages = [activityMessage("a", [activityTool("a")])]
  let first = ConversationActivity.project(messages)
  let next = ConversationActivity.project(messages + [activityMessage("b", [activityTool("b", "shell", status: "streaming")])], previous: first)
  #expect(activityGroups(first).first?.id == activityGroups(next).first?.id)
  #expect(next.messages.first?.id == first.messages.first?.id)
  var ended = activityMessage("b", [activityTool("b", "shell")])
  ended.time.completed = 100
  let finished = ConversationActivity.project(messages + [ended], previous: next)
  #expect(activityGroups(finished).first?.id == activityGroups(first).first?.id)
  #expect(activityGroups(finished).first?.pending == false)
}

@Test func activityPaginationPreservesGroupAndDisclosureKeys() throws {
  let tail = [activityMessage("middle", [activityTool("middle")]), activityMessage("end", [activityTool("end")])]
  let first = ConversationActivity.project(tail)
  let id = try #require(activityGroups(first).first?.id)
  let open = [id: true, "activity:detail:middle": true]
  let next = ConversationActivity.project([activityMessage("user", type: "user"), activityMessage("start", [activityTool("start")])] + tail, previous: first)
  #expect(activityGroups(next).first?.id == id)
  #expect(activityGroups(next).first?.parts.map(\.id) == ["start", "middle", "end"])
  #expect(next.anchors["start"] == "middle")
  #expect(next.messages.map(\.id) == ["user", "middle"])
  #expect(open[activityGroups(next).first!.id] == true)
  #expect(open["activity:detail:\(activityGroups(next).first!.parts[1].id)"] == true)
}

@Test func activitySplitReservesOldIdentityForItsNaturalOwner() {
  let first = ConversationActivity.project([activityMessage("a", [activityTool("a"), activityTool("b"), activityTool("c")])])
  let next = ConversationActivity.project([activityMessage("a", [activityTool("a"), ConversationPart(type: "text", text: "Novo texto"), activityTool("b"), activityTool("c")])], previous: first)
  #expect(activityGroups(next).count == 2)
  #expect(activityGroups(next).first?.id == activityGroups(first).first?.id)
  #expect(Set(activityGroups(next).map(\.id)).count == 2)
}

@Test func activityMergeKeepsTheEarliestSurvivingDisclosure() {
  let first = ConversationActivity.project([activityMessage("a", [activityTool("a"),
    ConversationPart(type: "text", text: "Separação"), activityTool("b")])])
  let next = ConversationActivity.project([activityMessage("a", [activityTool("a"),
    ConversationPart(type: "text", text: " "), activityTool("b")])], previous: first)
  #expect(activityGroups(next).count == 1)
  #expect(activityGroups(next).first?.id == activityGroups(first).first?.id)
  #expect(activityGroups(next).first?.parts.map(\.id) == ["a", "b"])
}

@Test func activityLabelsUseAllDistinctLocalizedNamesInFirstAppearanceOrder() {
  let tools = [activityTool("1", "read"), activityTool("2", "grep"), activityTool("3", "glob"), activityTool("4", "shell"), activityTool("5", "skill"), activityTool("6", "read")]
  #expect(ConversationProjection.stepLabel(tools) == "Usou 6 · Ler, Grep, Glob, Shell e Habilidade")
  #expect(ConversationProjection.stepLabel([activityTool("w", "websearch", metadata: ["provider": .string("Provider")])]) == "Usou 1 · Provider Pesquisa na web")
  for (provider, label) in [("tinyfish", "TinyFish"), ("opencode", "OpenCode"), ("exa", "Exa")] {
    #expect(activityTool("w", "websearch", metadata: ["provider": .string(provider)]).groupTitle == "\(label) Pesquisa na web")
  }
  #expect(activityTool("w", "websearch", metadata: ["provider": .string("")]).groupTitle == "Pesquisa na web")
}
