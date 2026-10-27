import Foundation
import Testing

@testable import OpenCodeKit

private struct ConversationRPC<T: Decodable>: Decodable { let output: T }
private func conversationFixture<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Conversation"))
  return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
private func page(_ name: String) throws -> [ConversationMessage] {
  try conversationFixture(name, ConversationRPC<ConversationPage>.self).output.data.reversed()
}

@Test func everyConversationFixtureDecodes() throws {
  let directory = try #require(Bundle.module.resourceURL?.appending(path: "Conversation"))
  let files = try FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: nil)
  #expect(files.count == 41)
  for file in files {
    let data = try Data(contentsOf: file)
    // Full JSON decoding retains fields of later-wave catalogs without imposing invented schemas.
    _ = try JSONDecoder().decode(JSONValue.self, from: data)
    let name = file.deletingPathExtension().lastPathComponent
    if name.hasPrefix("transcript-") {
      _ = try conversationFixture(name, ConversationRPC<ConversationPage>.self)
    }
    if name.hasPrefix("session-") || name == "viewed-session" {
      _ = try conversationFixture(name, DataResponse<Session>.self)
    }
  }
  _ = try conversationFixture("context-history", DataResponse<[ConversationMessage]>.self)
  _ = try conversationFixture("message-full-tool-image", DataResponse<ConversationMessage>.self)
  _ = try conversationFixture("models", DataResponse<[ModelInfo]>.self)
  _ = try conversationFixture("agents", DataResponse<[AgentInfo]>.self)
  _ = try conversationFixture("shells", DataResponse<[ShellInfo]>.self)
  _ = try conversationFixture("family-working", ConversationRPC<FamilySnapshot>.self)
  _ = try conversationFixture("family-page", ConversationRPC<FamilyPage>.self)
  _ = try conversationFixture("permissions", DataResponse<[PermissionRequest]>.self)
  _ = try conversationFixture("forms", DataResponse<[PendingForm]>.self)
  _ = try conversationFixture("events-live-step", [ConversationEvent].self)
  let unknown = try JSONDecoder().decode(
    ConversationMessage.self,
    from: Data(
      #"{"id":"future","type":"future-kind","time":{"created":1},"text":"Notice","content":[{"type":"future-part","payload":true}]}"#
        .utf8))
  #expect(unknown.notice == "Notice")
  #expect(unknown.type == .unknown("future-kind"))
  #expect(unknown.content?.first?.type == "future-part")
}

@Test func contextUsesLatestMeasuredAssistantAndProviderPair() throws {
  let models = try conversationFixture("models", DataResponse<[ModelInfo]>.self).data
  for (name, expected) in [
    ("transcript-working", 0.42), ("transcript-permission", 0.58), ("transcript-history", 0.61),
  ] {
    let fraction = try #require(ConversationProjection.context(page(name), models: models))
    #expect(abs(fraction - expected) < 0.001)
  }
  #expect(ConversationProjection.context([], models: models) == nil)
  #expect(try ConversationProjection.context(page("transcript-history"), models: []) == nil)
}

@Test func stepsCountToolsNotReasoningAndPreserveCategories() throws {
  let messages = try page("transcript-working")
  let imported = try #require(messages.first { $0.tools.count == 5 })
  #expect(ConversationActivityHeader(parts: imported.content ?? [], now: 0).label
    == "Atividade · Ler, Agente e Editar · 5 ferramentas · 2m11s")
  #expect(ConversationActivityHeader(parts: imported.content?.filter { $0.type == "reasoning" } ?? [], now: 0).label
    == "Pensou 8s")
  #expect(imported.content?.filter { $0.type == "reasoning" }.first?.time?.completed != nil)
}

@Test func toolSummariesUseOnlyAvailableEvidence() throws {
  let tools = try page("transcript-working").flatMap(\.tools)
  #expect(tools.first { $0.name == "read" }?.summary(now: 0) == "Leu docs/infra.md · 212 linhas")
  #expect(
    tools.first { $0.name == "edit" }?.summary(now: 0) == "Editou docs/alternativas.md +48 −0")
  let history = try page("transcript-history").flatMap(\.tools)
  for tool in history { #expect(!tool.summary(now: 1_792_602_410_000).isEmpty) }
  #expect(history.first { $0.status == "error" }?.summary(now: 0).hasSuffix("falhou") == true)
  #expect(history.first { $0.name == "websearch" }?.summary(now: 0).hasPrefix("Pesquisou") == true)
  #expect(history.first { $0.name == "webfetch" }?.summary(now: 0) == "Abriu example.invalid/plane")
  #expect(history.first { $0.name == "glob" }?.summary(now: 0) == "Buscou arquivos **/*.md")
  #expect(history.first { $0.name == "grep" }?.summary(now: 0) == "Buscou \"Plane\"")
  let shell = try #require(history.first { $0.name == "shell" })
  #expect(shell.status == "completed")
  #expect(shell.metadata["exit"]?.number == 2)
  let unknown = ConversationPart(
    type: "tool", name: "future-tool", state: .object(["status": .string("completed")]))
  #expect(unknown.summary(now: 0) == "future-tool")
  var read = try #require(tools.first { $0.name == "read" })
  read.state = .object([
    "status": .string("completed"), "input": .object(["path": .string("a")]),
    "content": .array([.object(["type": .string("text"), "text": .string("No header")])]),
  ])
  #expect(read.summary(now: 0) == "Leu a")
}

@Test func footerUsesCompletionAndSuppressesDefaultEffort() throws {
  var message = try #require(page("transcript-permission").first { !$0.responseText.isEmpty })
  let models = try conversationFixture("models", DataResponse<[ModelInfo]>.self).data
  let label = ConversationProjection.footer(message, models: models)
  #expect(label.hasPrefix("Luna 6 · low · "))
  #expect(
    label.hasSuffix(ConversationProjection.date(message.time.completed!, format: "dd/MM HH:mm")))
  message.model?.variant = "default"
  message.time.completed = nil
  #expect(!ConversationProjection.footer(message, models: models).contains("default"))
  #expect(
    ConversationProjection.footer(message, models: models).hasSuffix(
      ConversationProjection.date(message.time.created, format: "dd/MM HH:mm")))
}

@Test func runningCounterExcludesForegroundAndViewedChild() throws {
  let messages = try page("transcript-working")
  let children = try conversationFixture("family-page", ConversationRPC<FamilyPage>.self).output
    .data
  let active = Set(
    try conversationFixture("active", DataResponse<[String: ActiveState]>.self).data.keys)
  let shells = try conversationFixture("shells", DataResponse<[ShellInfo]>.self).data
  let owner = try conversationFixture("session-working", DataResponse<Session>.self).data.id
  #expect(
    ConversationProjection.runningCount(
      ownerID: owner, viewedID: owner, messages: messages, children: children, active: active,
      shells: shells) == 2)
  #expect(
    ConversationProjection.runningCount(
      ownerID: owner, viewedID: children[0].id, messages: messages, children: children,
      active: active, shells: shells) == 1)
  #expect(
    ConversationProjection.runningCount(
      ownerID: owner, viewedID: owner,
      messages: messages.filter { $0.tools.allSatisfy { $0.name != "shell" } }, children: children,
      active: active, shells: shells) == 3)
  #expect(
    ConversationProjection.runningCount(
      ownerID: owner, viewedID: owner, messages: [], children: children, active: [], shells: [])
      == 0)
}

@Test func replayLiveStepMatchesAuthoritativeTextAndToolState() throws {
  let expected = try page("transcript-live-step")
  var messages = expected.filter { $0.type != "assistant" }
  let events = try conversationFixture("events-live-step", [ConversationEvent].self)
  for event in events { ConversationReducer.apply(event, to: &messages) }
  for message in expected where message.type == "assistant" {
    let actual = try #require(messages.first { $0.id == message.id })
    #expect(actual.responseText == message.responseText)
    #expect(actual.tools.map(\.status) == message.tools.map(\.status))
    #expect(actual.tools.map(\.output) == message.tools.map(\.output))
    #expect(actual.tools.map(\.input) == message.tools.map(\.input))
    #expect(actual.time.completed == message.time.completed)
  }
}

@Test func deltaOrdinalsAndMetadataReplacement() throws {
  func event(_ type: String, _ body: String) throws -> ConversationEvent {
    try JSONDecoder().decode(
      ConversationEvent.self,
      from: Data(
        "{\"type\":\"\(type)\",\"created\":3,\"data\":{\"assistantMessageID\":\"a\",\(body)}}".utf8)
    )
  }
  var messages = [ConversationMessage(id: "a", type: "assistant", time: MessageTime(created: 1))]
  for ordinal in 0...1 {
    #expect(
      try ConversationReducer.apply(
        event("session.reasoning.started", "\"ordinal\":\(ordinal)"), to: &messages))
    #expect(
      try ConversationReducer.apply(
        event("session.reasoning.delta", "\"ordinal\":\(ordinal),\"delta\":\"r\(ordinal)\""),
        to: &messages))
  }
  #expect(messages[0].content?.map(\.text) == ["r0", "r1"])
  #expect(
    try !ConversationReducer.apply(
      event("session.text.delta", "\"ordinal\":2,\"delta\":\"missing\""), to: &messages))
  _ = try ConversationReducer.apply(
    event("session.tool.input.started", "\"id\":\"tool\",\"name\":\"shell\""), to: &messages)
  _ = try ConversationReducer.apply(
    event("session.tool.progress", "\"id\":\"tool\",\"metadata\":{\"old\":true}"), to: &messages)
  _ = try ConversationReducer.apply(
    event("session.tool.progress", "\"id\":\"tool\",\"metadata\":{\"new\":true}"), to: &messages)
  #expect(messages[0].tools[0].metadata["old"] == nil)
  #expect(messages[0].tools[0].metadata["new"] == .bool(true))
}

@Test func pagingPreservesSequenceAndMergesIDs() throws {
  let tail = try page("transcript-history")
  let older = try page("transcript-history-older")
  let oldest = try page("transcript-history-oldest")
  let merged = ConversationProjection.merge(
    ConversationProjection.merge(tail, page: older, older: true), page: oldest, older: true)
  #expect(merged.count == 89)
  #expect(merged.map(\.id) == (oldest + older + tail).map(\.id))
  #expect(ConversationProjection.merge(merged, page: tail).count == 89)
}

@Test func dayUnreadAndViewedDecisions() throws {
  let messages = try page("transcript-history")
  let last = try #require(messages.last)
  let now = Date(timeIntervalSince1970: last.time.created / 1000)
  #expect(ConversationProjection.day(last.time.created, now: now) == "Hoje")
  #expect(ConversationProjection.day(last.time.created - 86_400_000, now: now) == "Ontem")
  #expect(
    ConversationProjection.viewedWatermark(idle: 20, viewed: 10, acknowledged: nil, visible: true)
      == 20)
  #expect(
    ConversationProjection.viewedWatermark(idle: 20, viewed: 10, acknowledged: 20, visible: true)
      == nil)
  #expect(
    ConversationProjection.viewedWatermark(idle: 20, viewed: 10, acknowledged: nil, visible: false)
      == nil)
  #expect(
    ConversationProjection.viewedWatermark(idle: nil, viewed: 10, acknowledged: nil, visible: true)
      == nil)
}

@Test func markdownBlocksRetainSelectionOffsetsAndStructures() throws {
  let source =
    "# Título\n\nOlá **mundo** e `código` 😀.\n\n> Citação\n\n1. Um\n   - Dois\n\n```swift\nlet x = 1\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |"
  let blocks = MarkdownBlocks.parse(source)
  #expect(blocks.contains { $0.kind == .heading(1) })
  #expect(blocks.contains { $0.kind == .quote })
  #expect(blocks.contains { $0.kind == .code("swift") })
  #expect(blocks.contains { $0.kind == .table })
  #expect(blocks.contains { $0.kind == .table && $0.text == "A  │  B" })
  #expect(blocks.contains { $0.depth == 2 })
  let paragraph = try #require(blocks.first { $0.text.contains("mundo") })
  #expect(paragraph.runs.contains { $0.strong && $0.text == "mundo" })
  #expect(paragraph.runs.contains { $0.code && $0.text == "código" })
  let selection = try #require(
    paragraph.sourceRange(for: (paragraph.text as NSString).range(of: "mundo")))
  #expect((source as NSString).substring(with: selection) == "mundo")
  let emoji = try #require(paragraph.sourceRange(for: (paragraph.text as NSString).range(of: "😀")))
  #expect(emoji.length == 2)
  #expect((source as NSString).substring(with: emoji) == "😀")
}

@Test func stablePartIDsAndDirectShellGroups() throws {
  var message = ConversationMessage(id: "m", type: "assistant", time: MessageTime(created: 1))
  message.content = [
    ConversationPart(type: "reasoning"), ConversationPart(type: "text"),
    ConversationPart(type: "tool", id: "call"), ConversationPart(type: "text"),
  ]
  #expect(message.partID(at: 0) == "m:reasoning:0")
  #expect(message.partID(at: 1) == "m:text:0")
  #expect(message.partID(at: 2) == "call")
  #expect(message.partID(at: 3) == "m:text:1")
  let shell = try JSONDecoder().decode(
    ConversationMessage.self,
    from: Data(
      #"{"id":"s","type":"shell","time":{"created":0,"completed":2000},"command":"printf OK","status":"completed","output":"OK","exit":0}"#
        .utf8))
  #expect(ConversationActivityHeader(parts: shell.tools, now: 5000).label == "Atividade · Shell · 1 ferramenta · 2s")
  #expect(shell.tools.first?.summary(now: 5000) == "Rodou printf OK · 2s")
  #expect(shell.tools.first?.output == "OK")
}

@Test func themeAgentCSSBoundary() throws {
  let short = try #require(ThemeColor(css: "#3a6"))
  #expect(short.red == 0.2)
  #expect(short.blue == 0.4)
  let rgba = try #require(ThemeColor(css: "rgba(51, 102, 153, 0.5)"))
  #expect(rgba.opacity == 0.5)
  #expect(ThemeColor(css: "not-a-color") == nil)
}

@Test func executeNestedFailureKeepsItsRealToolStatus() {
  let part = ConversationPart(
    type: "tool", name: "execute",
    state: .object([
      "status": .string("completed"), "metadata": .object(["error": .bool(true)]),
    ]))
  #expect(part.status == "completed")
  #expect(part.failed)
  #expect(part.summary(now: 0) == "execute · falhou")
}

@Test func remainingToolSummariesRetainServerFields() {
  let cases: [(String, [String: JSONValue], [String: JSONValue], String)] = [
    ("write", ["path": .string("novo.swift")], [:], "Editou novo.swift"),
    ("patch", ["patch": .string("opaque")], [:], "Editou arquivo"),
    ("skill", ["id": .string("tests")], ["name": .string("Testes")], "Skill · Testes"),
    (
      "subagent", ["agent": .string("explore"), "description": .string("Conferir licença")], [:],
      "Conferir licença"
    ),
    ("question", [:], [:], "Perguntou"),
  ]
  for (name, input, metadata, expected) in cases {
    let part = ConversationPart(
      type: "tool", name: name,
      state: .object([
        "status": .string("completed"), "input": .object(input), "metadata": .object(metadata),
      ]))
    #expect(part.summary(now: 0) == expected)
  }
}

@Test func compactToolKindsDurationsAndDetails() throws {
  let tools = try page("transcript-history").flatMap(\.tools)
  #expect(ConversationActivityHeader(parts: tools, now: 0).label.hasPrefix("Atividade · Glob, Grep, Pesquisa na web, Busca na web, Execute, Ler, Patch, Shell e Perguntas · 10 ferramentas"))
  #expect(tools.first { $0.name == "question" }?.summary(now: 0).hasPrefix("Perguntou: ") == true)
  #expect(tools.first { $0.name == "shell" }?.exitCode == 2)
  let diff = try #require(tools.first { $0.name == "patch" })
  #expect(diff.diffLines.contains { $0.hasPrefix("@@") })
  #expect(!diff.diffLines.contains { $0.hasPrefix("--- ") || $0.hasPrefix("+++ ") })
  for (milliseconds, expected) in [
    (72_000.0, "1m12s"), (4_320_000, "1h12m"), (10_800_000, "3h"), (187_200_000, "2d 4h"),
    (-1, "0s"),
  ] {
    #expect(ConversationProjection.duration(milliseconds) == expected)
  }
  let unknown = ConversationPart(
    type: "tool", name: "future-tool",
    state: .object(["input": .object(["query": .string("uma busca")])]))
  #expect(unknown.summary(now: 0) == "future-tool · query: uma busca")
  #expect(unknown.icon == "wrench.and.screwdriver")
}

@Test func runningChildUsesRuntimeStartRatherThanImportedCreation() throws {
  let children = try conversationFixture("family-page", ConversationRPC<FamilyPage>.self).output
    .data
  let shells = try conversationFixture("shells", DataResponse<[ShellInfo]>.self).data
  let child = try #require(
    children.first { child in shells.contains { $0.metadata?["sessionID"]?.string == child.id } })
  let start = ConversationProjection.workStarted(child: child, shells: shells)
  #expect(start > child.time.created)
  #expect(start == shells.first { $0.metadata?["sessionID"]?.string == child.id }?.time.started)
}

@Test func followTailSurvivesMeasurementButStopsForUserScroll() {
  #expect(ConversationProjection.followTail(current: true, interacting: false, nearBottom: false))
  #expect(!ConversationProjection.followTail(current: true, interacting: true, nearBottom: false))
  #expect(!ConversationProjection.followTail(current: false, interacting: false, nearBottom: false))
  #expect(ConversationProjection.followTail(current: false, interacting: true, nearBottom: true))
}

@Test func imageThumbnailsAreBoundedAndBadImagesFail() throws {
  let imageMessage = try #require(page("transcript-history").first { $0.files?.isEmpty == false })
  let encoded = try #require(imageMessage.files?.first?.object?["data"]?.string)
  let data = try #require(Data(base64Encoded: encoded))
  let thumbnail = try #require(AttachmentImage.thumbnail(data, maxPixelSize: 32))
  #expect(thumbnail.width == 32)
  #expect(thumbnail.height <= 32)
  let bad = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6NQAAAABJRU5ErkJggg=="
  )!
  #expect(AttachmentImage.thumbnail(bad, maxPixelSize: 32) == nil)
  #expect(AttachmentImage.thumbnail(Data("invalid".utf8), maxPixelSize: 32) == nil)
}
