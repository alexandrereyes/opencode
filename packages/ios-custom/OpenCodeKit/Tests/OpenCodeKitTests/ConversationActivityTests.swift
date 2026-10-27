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
  #expect(activityGroups(value).first?.label == "Atividade · Grep, Ler e Shell · 4 ferramentas")
  #expect(value.messages.map(\.id) == ["user", "first"])
  #expect(value.anchors["third"] == "first")
}

@Test func activityProductionEditShellSequenceIsOneGroup() throws {
  let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("script/fixtures/tool-groups.json")
  let sequence = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: fixture))
  let messages = sequence.enumerated().map { index, parts in
    activityMessage("m\(index)", parts.enumerated().map { offset, value in
      if value == "reasoning" { return ConversationPart(type: "reasoning", text: "Conferir") }
      let fields = value.split(separator: ":").map(String.init)
      return activityTool("t\(index)-\(offset)", fields[0], status: fields[1])
    })
  }
  let groups = activityGroups(ConversationActivity.project(messages))
  #expect(groups.count == 1)
  let group = try #require(groups.first)
  #expect(group.parts.count == 48)
  #expect(group.label == "Atividade · Patch, Shell, Ler e Grep · 33 ferramentas")
  #expect(group.parts.filter { $0.part.failed }.count == 1)
}

@Test(arguments: ["system", "skill", "agent-switched", "future-kind"])
func activityNoticesJoinContext(_ type: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a")]),
    activityMessage("notice", type: type), activityMessage("b", [activityTool("b")])])
  #expect(activityGroups(value).count == 1)
  #expect(activityGroups(value).first?.parts.map(\.id) == ["a", "notice", "b"])
}

@Test(arguments: ["question", "todowrite"])
func activityFailedHiddenToolRemainsVisible(_ name: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a"),
    activityTool("failed", name, status: "error"), activityTool("b")])])
  #expect(activityGroups(value).first?.parts.map(\.id) == ["a", "failed", "b"])
}

@Test func activityTextAndUserBreakGroups() {
  let value = ConversationActivity.project([
    activityMessage("a", [activityTool("a"), ConversationPart(type: "text", text: "Explicação"), activityTool("b")]),
    activityMessage("user", type: "user"), activityMessage("c", [activityTool("c")]),
  ])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == [.group, .text, .group, .group])
  #expect(activityGroups(value).map { $0.parts.map(\.id) } == [["a"], ["b"], ["c"]])
}

@Test(arguments: ["model-switched", "location-switched", "compaction", "shell"])
func activityVisibleNoticeBreaksGroups(_ type: String) {
  let value = ConversationActivity.project([
    activityMessage("a", [activityTool("a")]), activityMessage("notice", type: type),
    activityMessage("b", [activityTool("b")]),
  ])
  #expect(activityGroups(value).count == (type == "shell" ? 3 : 2))
  #expect(value.messages.map(\.id) == ["a", "notice", "b"])
}

@Test func activityOnlyInterruptionBreaksSteps() {
  for retry in [false, true] {
    var message = activityMessage("a", [activityTool("a")])
    if retry { message.retry = .object(["attempt": .number(1)]) }
    if !retry { message.error = .object(["message": .string("Falha de teste")]) }
    #expect(activityGroups(ConversationActivity.project([message, activityMessage("b", [activityTool("b")])])).count == 1)
  }
  var idle = activityMessage("idle", type: "idle")
  idle.outcome = "failed"
  #expect(activityGroups(ConversationActivity.project([activityMessage("a", [activityTool("a")]), idle,
    activityMessage("b", [activityTool("b")])])).count == 1)
  var interrupted = activityMessage("a", [activityTool("a")])
  interrupted.error = .object(["type": .string("InterruptedError")])
  #expect(activityGroups(ConversationActivity.project([interrupted, activityMessage("b", [activityTool("b")])])).count == 2)
}

@Test(arguments: ["subagent", "task", "question"])
func activityOnlyCompletedQuestionsStayOutsideGroup(_ name: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a"), activityTool("card", name), activityTool("b")])])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == (name == "question" ? [.group, .tool, .group] : [.group]))
}

@Test(arguments: ["edit", "write", "patch", "apply_patch"])
func activityDiffsStayInsideGroup(_ name: String) {
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a"),
    activityTool("diff", name, metadata: ["files": .array([.object(["file": .string("example.swift"), "patch": .string("+example")])])]),
    activityTool("b")])])
  #expect(value.messages.flatMap(\.rows).map(\.kind) == [.group])
  #expect(value.messages.first?.rows.first?.parts[1].part.diffs.count == 1)
}

@Test func activityEditDoesNotMoveBetweenGroupAndCardWhenItsDiffArrives() {
  let first = ConversationActivity.project([activityMessage("a", [activityTool("read"), activityTool("edit", "edit", status: "streaming")])])
  let next = ConversationActivity.project([activityMessage("a", [activityTool("read"), activityTool("edit", "edit", metadata: [
    "files": .array([.object(["file": .string("example.swift"), "patch": .string("+example")])])
  ])])], previous: first)
  #expect(first.messages.flatMap(\.rows).map(\.kind) == [.group])
  #expect(next.messages.flatMap(\.rows).map(\.id) == first.messages.flatMap(\.rows).map(\.id))
}

@Test func activityPermissionsAndPendingQuestionsDoNotDelimitWork() {
  let messages = [activityMessage("a", [activityTool("a"), activityTool("waiting", "shell", status: "running"), activityTool("b")])]
  #expect(ConversationActivity.project(messages).messages.flatMap(\.rows).map(\.kind) == [.group])
  let questions = ConversationActivity.project([activityMessage("a", [activityTool("a"), activityTool("q", "question", status: "running"), activityTool("b")])])
  #expect(activityGroups(questions).count == 1)
  #expect(questions.messages.flatMap(\.rows).flatMap(\.parts).contains { $0.id == "q" } == false)
}

@Test func activityHiddenContentDoesNotBreakAndKeepsOrdinals() {
  let value = ConversationActivity.project([
     activityMessage("a", [ConversationPart(type: "reasoning", text: " "), activityTool("removed", "todowrite"), activityTool("a"),
      ConversationPart(type: "text", text: "\n "), ConversationPart(type: "reasoning", text: "Conferir dados")]),
    activityMessage("empty"), activityMessage("idle", type: "idle"), activityMessage("b", [activityTool("b")]),
  ])
  #expect(activityGroups(value).count == 1)
  #expect(activityGroups(value).first?.parts.map(\.id) == ["a", "a:reasoning:1", "b"])
  #expect(activityGroups(value).first?.label == "Atividade · Ler · 2 ferramentas")
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
  #expect(activityGroups(one).first?.label == "Pensou 1s")
  let two = ConversationActivity.project([activityMessage("a", [thought]), activityMessage("b", [thought])])
  #expect(activityGroups(two).first?.label == "Pensou 2s")
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
  #expect(activityGroups(value).first?.label == "Atividade · Ler, Execute e Shell · 3 ferramentas")
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
    #expect(group?.label == "Atividade · Shell · 1 ferramenta")
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
  #expect(ConversationActivityHeader(parts: tools, now: 0).label == "Atividade · Ler, Grep, Glob, Shell e Habilidade · 6 ferramentas")
  #expect(ConversationActivityHeader(parts: [activityTool("w", "websearch", metadata: ["provider": .string("Provider")])], now: 0).label == "Atividade · Provider Pesquisa na web · 1 ferramenta")
  #expect(ConversationActivityHeader(parts: [], now: 0).label == "Atividade · Atualizações")
  #expect(activityTool("browser", "browser").groupTitle == "Navegador")
  for (provider, label) in [("tinyfish", "TinyFish"), ("opencode", "OpenCode"), ("exa", "Exa")] {
    #expect(activityTool("w", "websearch", metadata: ["provider": .string(provider)]).groupTitle == "\(label) Pesquisa na web")
  }
  #expect(activityTool("w", "websearch", metadata: ["provider": .string("")]).groupTitle == "Pesquisa na web")
}

@Test func activityExpandedReadsAggregateNamesButExcludeImagesLoadedInstructionsAndErrors() {
  var image = activityTool("image")
  image.state = .object(["status": .string("completed"), "input": .object(["path": .string("photo.PNG")])])
  let parts = [activityTool("a"), activityTool("b"), image,
    activityTool("loaded", metadata: ["loaded": .array([.string("AGENTS.md")])]),
    activityTool("error", status: "error"), activityTool("c")]
  let items = ConversationActivityItem.project(parts.map { ConversationActivityPart(id: $0.id!, messageID: "m", part: $0) })
  #expect(items.map(\.kind) == [.read, .part, .part, .part, .read])
  #expect(items.first?.parts.map { $0.part.readGroupName } == ["example.md", "example.md"])
}

@Test func activityExpandedFilesSkillsAndSearchesUseWebSubgroups() {
  let parts = [activityTool("e", "edit"), activityTool("w", "write"), activityTool("p", "patch"),
    activityTool("error", "patch", status: "error"), activityTool("alias", "apply_patch"),
    activityTool("s1", "skill", metadata: ["name": .string("one")]),
    activityTool("s2", "skill", metadata: ["name": .string("two")]),
    activityTool("g", "glob"), activityTool("r", "grep"), activityTool("l", "list")]
  let items = ConversationActivityItem.project(parts.map { ConversationActivityPart(id: $0.id!, messageID: "m", part: $0) })
  #expect(items.map(\.kind) == [.files, .part, .part, .skills, .search, .search, .search])
  #expect(items[0].parts.map(\.id) == ["e", "w", "p"])
  #expect(items[3].parts.compactMap { $0.part.skillName } == ["one", "two"])
}

@Test func activityExpandedSubgroupKeysSurvivePrependAndSplit() {
  let refs = ["a", "b", "c"].map { ConversationActivityPart(id: $0, messageID: "m", part: activityTool($0)) }
  let before = ConversationActivityItem.project(Array(refs.dropFirst()))
  let after = ConversationActivityItem.project(refs, previous: before)
  #expect(after.first?.id == before.first?.id)
  let split = ConversationActivityItem.project([refs[0], ConversationActivityPart(id: "s", messageID: "m", part: activityTool("s", "shell"))] + Array(refs.dropFirst()), previous: after)
  #expect(split.map(\.id) == ["a", "s", "b"])
  #expect(Set(split.map(\.id)).count == split.count)
}

@Test func activityFilesMergeCompleteChainsAndKeepPartialCounts() throws {
  func file(_ id: String, before: String, after: String, complete: Bool) -> ConversationPart {
    let header = complete ? "diff --git a/a.swift b/a.swift\n" : ""
    return activityTool(id, "patch", metadata: ["files": .array([.object([
      "file": .string("a.swift"), "status": .string("modified"), "additions": .number(1), "deletions": .number(1),
      "patch": .string(header + "--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-\(before)\n+\(after)\n")])])])
  }
  let complete = ConversationActivityFile.project([file("a", before: "old", after: "middle", complete: true), file("b", before: "middle", after: "new", complete: true)])
  #expect(complete.count == 1)
  #expect(complete.first?.additions == 1)
  #expect(complete.first?.deletions == 1)
  #expect(complete.first?.patches == ["-old\n+new"])
  let partial = ConversationActivityFile.project([file("a", before: "old", after: "middle", complete: false), file("b", before: "middle", after: "new", complete: false)])
  #expect(partial.first?.additions == 2)
  #expect(partial.first?.patches.count == 2)
}

@Test func activityEditWriteDeriveDiffsWithoutMetadataAndIgnoreNoop() {
  func tool(_ name: String, _ input: [String: JSONValue]) -> ConversationPart {
    ConversationPart(type: "tool", name: name, state: .object(["input": .object(input)]))
  }
  let edit = tool("edit", ["path": .string("a"), "oldString": .string("same\nold\n"), "newString": .string("same\nnew\n")])
  #expect(ConversationActivityFile.project([edit]).first?.additions == 1)
  #expect(ConversationActivityFile.project([edit]).first?.deletions == 1)
  let noop = tool("edit", ["path": .string("a"), "oldString": .string("same"), "newString": .string("same")])
  #expect(ConversationActivityFile.project([noop]).isEmpty)
  let write = tool("write", ["path": .string("b"), "content": .string("one\ntwo\n")])
  #expect(ConversationActivityFile.project([write]).first?.additions == 2)
}

@Test func activityStreamingInputAndAliasesMatchWeb() {
  let valid = ConversationPart(type: "tool", name: "read", state: .object([
    "status": .string("streaming"), "input": .string(#"{"path":"src/example.swift","offset":4,"limit":8}"#)]))
  #expect(valid.readGroupName == "example.swift offset=4 limit=8")
  let partial = ConversationPart(type: "tool", name: "read", state: .object([
    "status": .string("streaming"), "input": .string(#"{"path":"src/"#)]))
  #expect(partial.input.isEmpty)
  for name in ["task", "bash", "apply_patch", "mcp.search"] {
    #expect(activityTool(name, name).groupTitle == name)
  }
}

@Test func activityShellMessageGroupsItsNoticesButNotAdjacentAssistant() {
  var shell = activityMessage("shell", type: "shell")
  shell.command = "echo example"
  var notice = activityMessage("notice", type: "synthetic")
  notice.description = "Comando concluído"
  let value = ConversationActivity.project([activityMessage("a", [activityTool("a")]), shell, notice,
    activityMessage("b", [activityTool("b")])])
  #expect(activityGroups(value).map { $0.parts.map(\.id) } == [["a"], ["shell", "notice"], ["b"]])
}

@Test func activityFileSnapshotSurvivesStreamingReplacement() {
  let tool = activityTool("p", "patch", metadata: ["files": .array([.object([
    "file": .string("a"), "status": .string("modified"), "patch": .string("@@ -1 +1 @@\n-a\n+b"),
    "additions": .number(1), "deletions": .number(1)])])])
  let before = ConversationActivityItem.project([ConversationActivityPart(id: "p", messageID: "m", part: tool)])
  let after = ConversationActivityItem.project([ConversationActivityPart(id: "p", messageID: "m",
    part: activityTool("p", "patch", status: "running"))], previous: before)
  #expect(after.first?.files == before.first?.files)
  #expect(after.first?.id == before.first?.id)
}
