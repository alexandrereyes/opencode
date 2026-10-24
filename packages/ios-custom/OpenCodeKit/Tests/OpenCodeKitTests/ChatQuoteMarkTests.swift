import Foundation
import Testing
@testable import OpenCodeKit

@Test func quotationSourceOffsetsSurviveAppendButNeverRelocateAfterEditing() throws {
  let source = "Antes 😀 **trecho marcado** e depois."
  let block = try #require(MarkdownBlocks.parse(source).first)
  let quote = try #require(ChatQuote.selection(source: source, block: block,
    range: (block.text as NSString).range(of: "trecho marcado"), messageID: "m", partID: "m:text:0"))
  let expected = (source as NSString).range(of: "trecho marcado")
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: [block]) == [expected])
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: source + " Mais streaming.", blocks: MarkdownBlocks.parse(source + " Mais streaming.")) == [expected])
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: "Novo " + source, blocks: MarkdownBlocks.parse("Novo " + source)).isEmpty)
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: source.replacingOccurrences(of: "marcado", with: "editado"), blocks: []).isEmpty)
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: "", blocks: []).isEmpty)
}

@Test func quotationWebRenderedOffsetsAndLegacyUniqueMatching() throws {
  let source = "😀 **ação** e ação"
  let blocks = MarkdownBlocks.parse(source)
  let quote = ChatQuote(messageID: "m", partID: "m:text:0", text: "ação",
    anchor: .init(start: 3, end: 7, exact: "ação"))
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: blocks) == [NSRange(location: 5, length: 4)])
  let repeated = ChatQuote(messageID: "m", partID: "m:text:0", text: "ação")
  #expect(ChatQuoteAnchoring.sourceRanges(repeated, source: source, blocks: blocks).isEmpty)
  let unique = ChatQuote(messageID: "m", partID: "m:text:0", text: "ação e ação")
  #expect(!ChatQuoteAnchoring.sourceRanges(unique, source: source, blocks: blocks).isEmpty)
  let edited = "Novo " + source
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: edited, blocks: MarkdownBlocks.parse(edited)).isEmpty)
  let paragraphs = "**Antes**.\n\nTrecho marcado."
  let web = ChatQuote(messageID: "m", partID: "m:text:0", text: "Trecho",
    anchor: .init(start: 7, end: 13, exact: "Trecho"))
  #expect(ChatQuoteAnchoring.sourceRanges(web, source: paragraphs, blocks: MarkdownBlocks.parse(paragraphs)) == [(paragraphs as NSString).range(of: "Trecho")])
}

@Test func quotationReconstructionIsScopedToSourceAndReconcilesPaginationAndRevert() throws {
  let quote = ChatQuote(id: "q", messageID: "source", partID: "source:text:0", text: "Trecho", comment: "Confira")
  let metadata = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([quote]))
  let message = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(JSONValue.object([
    "id": .string("carrier"), "type": .string("user"), "text": .string("Pedido"),
    "time": .object(["created": .number(1)]), "metadata": .object(["quotes": metadata]),
  ])))
  var index = ChatQuoteIndex()
  index.update([message])
  let marks = index.marks(messageID: "source", partID: "source:text:0")
  #expect(marks.count == 1 && marks.first?.carryingMessageID == "carrier")
  #expect(index.carried(by: "carrier") == marks)
  #expect(index.marks(messageID: "another", partID: "source:text:0").isEmpty)
  #expect(index.marks(messageID: "source", partID: "source:text:1").isEmpty)
  // An unloaded source retains its annotation; paging the source needs no metadata rewrite.
  index.update([message])
  #expect(index.marks(messageID: "source", partID: "source:text:0") == marks)
  #expect(index.marks(messageID: "source", partID: "source:text:0", pending: [quote]).map(\.pending) == [false, true])
  index.update([])
  #expect(index.carried(by: "carrier").isEmpty)
  #expect(index.marks(messageID: "source", partID: "source:text:0").isEmpty)
}

@Test @MainActor func dismissedSentMarksLeaveResponsesButKeepTheCarrierRecord() throws {
  let first = ChatQuote(id: "q1", messageID: "source", partID: "source:text:0", text: "Primeiro")
  let second = ChatQuote(id: "q2", messageID: "source", partID: "source:text:0", text: "Segundo")
  let metadata = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([first, second]))
  let message = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(JSONValue.object([
    "id": .string("carrier"), "type": .string("user"), "text": .string("Pedido"),
    "time": .object(["created": .number(1)]), "metadata": .object(["quotes": metadata]),
  ])))
  var index = ChatQuoteIndex()
  index.update([message])
  let visible = index.marks(messageID: "source", partID: "source:text:0", dismissed: ["q1"])
  #expect(visible.map(\.quote.id) == ["q2"] && visible.first?.number == 2)
  // Source navigation from the bubble may still reveal a dismissed mark; drafts are never dismissed.
  #expect(index.marks(messageID: "source", partID: "source:text:0", dismissed: ["q1"], revealing: "carrier:q1").count == 2)
  #expect(index.marks(messageID: "source", partID: "source:text:0", pending: [first], dismissed: ["q1", "q2"]).map(\.pending) == [true])
  #expect(index.carried(by: "carrier").count == 2)

  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ChatQuoteDismissals(server: "http://127.0.0.1:4183", root: root, capacity: 2)
  try store.dismiss(["q1"], sessionID: "A")
  try store.dismiss(["q2"], sessionID: "A")
  try store.dismiss([], sessionID: "B")
  #expect(ChatQuoteDismissals(server: "http://127.0.0.1:4183", root: root).values("A") == ["q1", "q2"])
  #expect(ChatQuoteDismissals(server: "http://other", root: root).values("A").isEmpty)
  try store.dismiss(["q3"], sessionID: "B")
  try store.dismiss(["q4"], sessionID: "C")
  #expect(ChatQuoteDismissals(server: "http://127.0.0.1:4183", root: root).values("A").isEmpty)
  #expect(store.values("C") == ["q4"])
}

@Test func quotationAnchorAndStructuredCommentSerializationRoundTrip() throws {
  var quote = ChatQuote(messageID: "source", partID: "source:text:0", text: "Ação 😀",
    anchor: .init(start: 3, end: 10, exact: "Ação 😀", coordinate: "source"))
  quote.document = ComposerDocument(text: "$sample confira", tokens: [
    .init(start: 0, end: 7, token: .init(kind: .skill, id: "sample", text: "$sample")),
  ])
  let request = PromptRequest(document: .init(text: "Pedido"), delivery: .steer, agent: "build",
    model: .init(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low"), quotes: [quote])
  #expect(ChatQuote.read(request.metadata["quotes"]) == [quote])
  #expect(try JSONDecoder().decode(ChatQuote.self, from: JSONEncoder().encode(quote)) == quote)
  let old = Data(#"{"start":0,"end":6,"exact":"Trecho"}"#.utf8)
  #expect(try JSONDecoder().decode(ChatQuote.Anchor.self, from: old).coordinate == nil)
}

@Test func quotationMultiBlockCodeTablesAndInvalidBoundsKeepExactIdentity() throws {
  let source = "Primeiro **marcado**.\n\nSegundo marcado.\n\n```swift\nlet valor = 1\n```\n\n| Nome |\n| --- |\n| Ação |"
  let blocks = MarkdownBlocks.parse(source)
  let code = try #require(blocks.first { if case .code = $0.kind { true } else { false } })
  let quote = try #require(ChatQuote.selection(source: source, block: code.codeDisplay,
    range: (code.codeDisplay.text as NSString).range(of: "valor"), messageID: "m", partID: "m:text:0"))
  #expect(ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: blocks) == [(source as NSString).range(of: "valor")])
  for anchor in [ChatQuote.Anchor(start: -1, end: 4, exact: "valor"), .init(start: 4, end: 4, exact: ""), .init(start: 0, end: 10000, exact: source)] {
    #expect(ChatQuoteAnchoring.sourceRanges(ChatQuote(messageID: "m", partID: "m:text:0", text: "valor", anchor: anchor), source: source, blocks: blocks).isEmpty)
  }
  // Markdown syntax must not make a repeated rendered phrase look unambiguous.
  let repeated = ChatQuote(messageID: "m", partID: "m:text:0", text: "a b")
  #expect(ChatQuoteAnchoring.sourceRanges(repeated, source: "a **b** a b", blocks: MarkdownBlocks.parse("a **b** a b")).isEmpty)
}
