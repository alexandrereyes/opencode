import Foundation
import Testing

@testable import OpenCodeKit

@Test(arguments: [
  ("Olá, ação 😀!", "ação 😀", "ação 😀"),
  ("Um **trecho forte** aqui.", "trecho forte", "trecho forte"),
  ("Um *trecho leve* aqui.", "trecho leve", "trecho leve"),
  ("Use `docker compose` agora.", "docker compose", "docker compose"),
  ("Abra [o GitHub](https://github.com) agora.", "o GitHub", "o GitHub"),
  ("- **Huly** · EPL-2.0", "Huly · EPL-2.0", "Huly** · EPL-2.0"),
  ("1. Ação com 👩🏽‍💻 e café", "Ação com 👩🏽‍💻", "Ação com 👩🏽‍💻"),
  ("Prefixo **ação** e `código` final", "ação e código", "ação** e `código"),
  ("Árvore\n\nSegundo *parágrafo* 😀", "Segundo parágrafo 😀", "Segundo *parágrafo* 😀"),
])
func selectionMapsRenderedToExactSource(_ sample: (String, String, String)) throws {
  let block = try #require(MarkdownBlocks.parse(sample.0).first { $0.text.contains(sample.1) })
  let selected = (block.text as NSString).range(of: sample.1)
  let quote = try #require(
    ChatQuote.selection(
      source: sample.0, block: block, range: selected,
      messageID: "msg_test", partID: "msg_test:text:1"))
  #expect(quote.messageID == "msg_test" && quote.partID == "msg_test:text:1")
  #expect(quote.text == sample.1)
  let anchor = try #require(quote.anchor)
  #expect(anchor.exact == sample.2)
  #expect(
    (sample.0 as NSString).substring(
      with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == sample.2)
}

@Test func selectionRejectsGeneratedMarkersAndEmptyRanges() throws {
  let block = try #require(MarkdownBlocks.parse("- Texto").first)
  #expect(
    ChatQuote.selection(
      source: "- Texto", block: block, range: .init(location: 0, length: 2), messageID: "m",
      partID: "p") == nil)
  #expect(block.sourceRange(for: .init(location: 0, length: 0)) == nil)
  #expect(block.sourceRange(for: .init(location: 0, length: 100)) == nil)
}

private let selectionModel = ModelReference(
  id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")

@Test func quotesEncodeLikeWebWithoutShiftingMainMentions() throws {
  let main = ComposerToken(kind: .file, id: "main", text: "@main.md", value: "/repo/main.md")
  let file = ComposerToken(kind: .file, id: "f", text: "@açúcar.md", value: "/repo/açúcar.md")
  let agent = ComposerToken(kind: .agent, id: "explore", text: "@Explore")
  let skill = ComposerToken(kind: .skill, id: "check", text: "$check")
  var quote = ChatQuote(id: "q", messageID: "msg_old", partID: "msg_old:text:0", text: "Ação\n😀")
  let comment = "Veja \(file.text) \(agent.text) \(skill.text)"
  quote.document = ComposerDocument(
    text: comment,
    tokens: [file, agent, skill].map { token in
      let range = (comment as NSString).range(of: token.text)
      return .init(start: range.location, end: NSMaxRange(range), token: token)
    })
  #expect(quote.document.tokens.count == 3)
  let request = PromptRequest(
    document: .init(text: main.text, tokens: [.init(start: 0, end: 8, token: main)]),
    delivery: .steer, agent: "build", model: selectionModel, quotes: [quote])
  #expect(request.metadata["displayText"] == .string("@main.md"))
  #expect(request.metadata["comments"] == .array([]))
  #expect(ChatQuote.read(request.metadata["quotes"]) == [quote])
  #expect(request.files?.count == 2 && request.agents?.count == 1 && request.skills?.count == 1)
  #expect(request.files?.first?.object?["mention"]?.object?["start"] == .number(0))
  #expect(request.files?.last?.object?["mention"] == nil)
  #expect(request.agents?.first?.object?["mention"] == nil)
  #expect(request.skills?.first?.object?["mention"] == nil)
  #expect(
    request.text
      == "@main.md\nComments on earlier assistant messages:\n\n1. Quoted from message msg_old (part msg_old:text:0):\n> Ação\n> 😀\nUser comment: \(comment)"
  )
  #expect(quote.commentPrompt?.first?.object?["type"] == .string("text"))
  #expect(quote.commentPrompt?.last?.object?["type"] == .string("skill"))
}

@Test func quoteOnlyAndSnippetCommentsHaveNoPhantomDisplayText() {
  var quote = ChatQuote(messageID: "m", partID: "p", text: "Trecho")
  quote.document = .init(
    text: "#r",
    tokens: [
      .init(
        start: 0, end: 2, token: .init(kind: .snippet, id: "r", text: "#r", value: "Explique 😀"))
    ])
  let request = PromptRequest(
    document: .init(), delivery: .queue, agent: "build", model: selectionModel, quotes: [quote])
  #expect(request.metadata["displayText"] == .string(""))
  #expect(request.text.hasPrefix("Comments on earlier assistant messages:"))
  #expect(request.text.hasSuffix("User comment: Explique 😀"))
  #expect(quote.comment == "#r")
  #expect(
    ChatQuote.format([ChatQuote(messageID: "m", partID: "p", text: "T")])
      == "Comments on earlier assistant messages:\n\n1. Quoted from message m (part p):\n> T")
}

@Test func commentSessionsReferencesAndSnippetExpansionKeepMainOffsets() throws {
  let main = ComposerToken(kind: .file, id: "main", text: "@main.md", value: "/repo/main.md")
  let reference = ComposerToken(kind: .reference, id: "docs", text: "@docs", value: "/shared/docs")
  let snippet = ComposerToken(kind: .snippet, id: "review", text: "#r", value: "Confira ação 😀")
  let session = ComposerToken(
    kind: .session, id: "ses_other", text: "@Anterior",
    detail: [
      "id": .string("ses_other"), "title": .string("Anterior"), "directory": .string("/other"),
    ])
  let comment = "\(snippet.text) \(reference.text) \(session.text)"
  var quote = ChatQuote(messageID: "old", partID: "old:text:0", text: "Trecho")
  quote.document = .init(
    text: comment,
    tokens: [snippet, reference, session].map { token in
      let range = (comment as NSString).range(of: token.text)
      return .init(start: range.location, end: NSMaxRange(range), token: token)
    })
  let request = PromptRequest(
    document: .init(
      text: "😀 \(main.text)",
      tokens: [
        .init(start: 3, end: 11, token: main)
      ]), delivery: .steer, agent: "build", model: selectionModel, quotes: [quote])
  #expect(request.metadata["displayText"] == .string("😀 @main.md"))
  #expect(request.files?.first?.object?["mention"]?.object?["start"] == .number(3))
  #expect(request.files?.first?.object?["mention"]?.object?["end"] == .number(11))
  #expect(request.files?.last?.object?["uri"] == .string("file:///shared/docs"))
  #expect(request.files?.last?.object?["mention"] == nil)
  #expect(request.text.contains("Referenced OpenCode session:"))
  #expect(request.text.contains("\"sessionID\":\"ses_other\""))
  #expect(request.text.hasSuffix("User comment: Confira ação 😀 @docs @Anterior"))
  #expect(
    request.metadata["sessions"]?.array?.first?.object?["session"]?.object?["id"]
      == .string("ses_other"))
  let restored = try #require(ChatQuote.read(request.metadata["quotes"]).first)
  #expect(restored.comment == comment)
  #expect(restored.document.validTokens.map(\.token.kind) == [.snippet, .file, .session])
  #expect(restored.document.expanded.text == "Confira ação 😀 @docs @Anterior")
}

@Test func quotesPersistAndOldDraftsStillDecode() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = DraftPersistence(server: "sandbox", sessionID: "s", root: root)
  let snapshot = DraftSnapshot(
    document: .init(text: "Comente"),
    quotes: [ChatQuote(messageID: "m", partID: "p", text: "😀", comment: "Ação")])
  try await store.save(snapshot)
  #expect(try await store.load().0 == snapshot)
  let old = Data(#"{"document":{"text":"anterior","tokens":[]},"attachments":[],"cursor":0}"#.utf8)
  #expect(try JSONDecoder().decode(DraftSnapshot.self, from: old).quotes.isEmpty)
}

@Test func quoteInlineFilesFollowMainFilesInQuoteOrderAndStagedFilesStayInTheirQuote() throws {
  func image(_ id: String) -> JSONValue {
    .object([
      "type": .string("image"), "id": .string(id), "filename": .string(id + ".png"),
      "mime": .string("image/png"), "blob": .object(["id": .string(id), "url": .string("")]),
    ])
  }
  var first = ChatQuote(id: "q1", messageID: "m", partID: "p", text: "Primeiro")
  first.commentPrompt = [image("one")]
  first.document = .init(text: "Confira")
  #expect(first.inlineIDs == ["one"])
  var second = ChatQuote(id: "q2", messageID: "m", partID: "p", text: "Segundo")
  second.commentPrompt = [image("two"), image("staged")]
  let main = DraftAttachment(id: "main", name: "main.png", mime: "image/png", size: 1)
  let one = DraftAttachment(id: "one", name: "one.png", mime: "image/png", size: 1, quoteID: "q1")
  let two = DraftAttachment(id: "two", name: "two.png", mime: "image/png", size: 1, quoteID: "q2")
  let staged = DraftAttachment(
    id: "staged", name: "staged.png", mime: "image/png", size: 1, quoteID: "q2")
  let request = PromptRequest(
    document: .init(), delivery: .steer, agent: "build", model: selectionModel,
    attachments: [
      .init(attachment: two, path: "/two.png", inline: "data:image/png;base64,Ag=="),
      .init(attachment: main, path: "/main.png", inline: "data:image/png;base64,AA=="),
      .init(attachment: staged, path: "/staged.png", inline: nil),
      .init(attachment: one, path: "/one.png", inline: "data:image/png;base64,AQ=="),
    ], quotes: [first, second])
  #expect(
    request.files?.compactMap { $0.object?["name"]?.string } == ["main.png", "one.png", "two.png"])
  #expect(request.files?.allSatisfy { $0.object?["mention"] == nil } == true)
  #expect(request.metadata["attachments"] == nil)
  let quotes = ChatQuote.read(request.metadata["quotes"])
  #expect(quotes[0].comment == "Confira")
  #expect(quotes[1].attachmentParts.last?.object?["type"] == .string("path"))
  #expect(quotes[1].attachmentParts.last?.object?["path"] == .string("/staged.png"))
  #expect(request.text.contains("Image attached to this comment: one.png"))
  #expect(request.text.contains("File attached to this comment: `/staged.png`"))
  #expect(!request.text.contains("Attached file: `/staged.png`"))
  let saved = DraftSnapshot(attachments: [one], quotes: [first])
  #expect(try JSONDecoder().decode(DraftSnapshot.self, from: JSONEncoder().encode(saved)) == saved)
}

@Test func sideQuestionsBuildExactPrefixAndBoundedLocalHistory() throws {
  let question = SideQuestionRequest.quote("Huly\nEPL-2.0") + "Permite uso comercial?"
  #expect(
    SideQuestionRequest(question: question).prompt == SideQuestionRequest.instructions + "\n\n"
      + question)
  let history = (0..<7).map {
    SideQuestionEntry(
      question: "\($0)" + String(repeating: "q", count: 1100),
      answer: String(repeating: "a", count: 3100))
  }
  let request = SideQuestionRequest(question: "Nova?", history: history)
  let json = try #require(
    request.prompt.components(separatedBy: "reference context):\n").last?.components(
      separatedBy: "\n\n"
    ).first)
  let saved = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
  #expect(saved.count == 5)
  #expect(saved.first?["question"]?.first == "2")
  #expect(
    saved.allSatisfy { $0["question"]?.utf16.count == 1000 && $0["answer"]?.utf16.count == 3000 })
  #expect(request.prompt.hasSuffix("\n\nNova?"))
  #expect(SideQuestionRequest.slashQuestion(.init(text: " /btw ação 😀 ")) == "ação 😀")
  #expect(SideQuestionRequest.slashQuestion(.init(text: "/btw")) == "")
  #expect(SideQuestionRequest.slashQuestion(.init(text: "/btw\u{00a0}ação")) == "ação")
  #expect(SideQuestionRequest.slashQuestion(.init(text: "/btwhatever")) == nil)
  #expect(SideQuestionRequest.slashQuestion(.init(text: "texto /btw")) == nil)
}

@Test func sideQuestionHTTPIsTransientGenerateOnly() async throws {
  let client = OpenCodeClient(configuration: .init(url: URL(string: "https://sandbox.invalid")!)) {
    request in
    #expect(request.url?.path == "/api/session/ses_test/generate")
    #expect(request.httpMethod == "POST")
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(body.object?.keys.sorted() == ["prompt"])
    #expect(body.object?["prompt"]?.string?.hasPrefix(SideQuestionRequest.instructions) == true)
    return (
      Data(#"{"data":{"text":" Sim. "}}"#.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
  #expect(try await client.sideQuestion(.init(question: "Sim?"), sessionID: "ses_test") == "Sim.")
}

@Test func userCopyNeverIncludesModelFacingAppendices() throws {
  var message = ConversationMessage(id: "u", type: "user", time: .init(created: 1))
  let quote = ChatQuote(messageID: "m", partID: "p", text: "Huly · EPL-2.0", comment: "Confira")
  message.text = "Confira\nComments on earlier assistant messages:\nprivate appendix"
  message.metadata = [
    "displayText": .string("Confira"),
    "quotes": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([quote])),
  ]
  #expect(message.copyText == "Confira")
  #expect(message.copyQuotes == "> Huly · EPL-2.0\n\nConfira")
  message.metadata?["displayText"] = .string("")
  #expect(message.copyText.isEmpty)
}
