import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// A minimal in-memory `custom.quotes` over the client's real HTTP encoding, following `docs/quotes.md`.
private final class FakeQuotes: Sendable {
  struct Store {
    var revision: Double = 0
    var quotes: [[String: JSONValue]] = []
    var attachments: [String: (mime: String, size: Int, data: String)] = [:]
    var sent: Set<String> = []
    var dismissed: [String] = []
    var calls: [String] = []
    var failImport = 0
    var unavailable = false
  }
  let store = Mutex(Store())
  var client: OpenCodeClient {
    OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4183")!)) { [self] request in
      let method = request.url!.lastPathComponent
      let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("{}".utf8)).object?["input"]?.object ?? [:]
      #expect(request.url!.query?.contains("location%5Bdirectory%5D=/repo") == true
        || request.url!.query?.contains("location[directory]=/repo") == true)
      let (status, body) = store.withLock { handle(method, input, &$0) }
      return (try JSONEncoder().encode(body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
  }
  private func failure(_ type: String) -> (Int, JSONValue) {
    (400, .object(["_tag": .string("RpcError"), "type": .string(type), "message": .string(type)]))
  }
  private func handle(_ method: String, _ input: [String: JSONValue], _ store: inout Store) -> (Int, JSONValue) {
    store.calls.append(method)
    if store.unavailable { return failure("rpc.unavailable") }
    func state() -> JSONValue {
      .object(["sessionID": .string("ses_a"), "revision": .number(store.revision),
        "quotes": .array(store.quotes.map { .object($0) }), "dismissed": .array(store.dismissed.map { .string($0) })])
    }
    func stored(_ quote: [String: JSONValue]) -> [String: JSONValue] {
      var value = quote
      value["attachments"] = .array((quote["attachments"]?.array ?? []).compactMap { id in
        guard let id = id.string, let file = store.attachments[id] else { return nil }
        return .object(["id": .string(id), "mime": .string(file.mime), "size": .number(Double(file.size))])
      })
      value["createdAt"] = .number(1)
      value["updatedAt"] = .number(1)
      value["revision"] = .number(store.revision)
      return value
    }
    switch method {
    case "info": return (200, .object(["output": .object(["version": .number(1), "limits": .object([:])])]))
    case "list": return (200, .object(["output": state()]))
    case "upload":
      let data = Data(base64Encoded: input["data"]?.string ?? "") ?? Data()
      let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      store.attachments[id] = (input["mime"]?.string ?? "", data.count, input["data"]?.string ?? "")
      return (200, .object(["output": .object(["id": .string(id), "mime": input["mime"]!, "size": .number(Double(data.count))])]))
    case "attachment":
      guard let id = input["id"]?.string, let file = store.attachments[id] else { return failure("not_found") }
      return (200, .object(["output": .object(["id": .string(id), "mime": .string(file.mime), "size": .number(Double(file.size)), "data": .string(file.data)])]))
    case "save":
      let quote = input["quote"]!.object!
      if store.sent.contains(quote["id"]!.string!) { return failure("already_sent") }
      store.revision += 1
      store.quotes.removeAll { $0["id"] == quote["id"] }
      store.quotes.append(stored(quote))
      return (200, .object(["output": .object(["revision": .number(store.revision), "quote": .object(stored(quote))])]))
    case "import":
      if store.failImport > 0 {
        store.failImport -= 1
        return failure("attachment_missing")
      }
      var imported: [JSONValue] = []
      var skipped: [JSONValue] = []
      for quote in input["quotes"]?.array ?? [] {
        let value = quote.object!
        if store.sent.contains(value["id"]!.string!) || store.quotes.contains(where: { $0["id"] == value["id"] }) {
          skipped.append(value["id"]!)
          continue
        }
        store.revision += 1
        store.quotes.append(stored(value))
        imported.append(value["id"]!)
      }
      return (200, .object(["output": .object(["state": state(), "imported": .array(imported), "skipped": .array(skipped)])]))
    case "clear":
      for id in input["ids"]?.array?.compactMap(\.string) ?? [] {
        store.quotes.removeAll { $0["id"]?.string == id }
        if input["reason"]?.string == "sent" { store.sent.insert(id) }
      }
      store.revision += 1
      return (200, .object(["output": .object(["revision": .number(store.revision)])]))
    case "dismiss":
      store.dismissed += input["ids"]?.array?.compactMap(\.string) ?? []
      store.revision += 1
      return (200, .object(["output": .object(["revision": .number(store.revision)])]))
    default: return failure("rpc.method_not_found")
    }
  }
}

@Test func quoteModeComesOnlyFromADecidedInfoProbe() async throws {
  #expect(QuoteServer.mode(after: ClientError.rpc("rpc.unavailable")) == .local)
  #expect(QuoteServer.mode(after: ClientError.rpc("rpc.method_not_found")) == .local)
  #expect(QuoteServer.mode(after: ClientError.http(500)) == nil)
  #expect(QuoteServer.mode(after: ClientError.http(401)) == nil)
  #expect(QuoteServer.mode(after: URLError(.notConnectedToInternet)) == nil)
  let server = FakeQuotes()
  try await server.client.quotesInfo(directory: "/repo")
  server.store.withLock { $0.unavailable = true }
  await #expect(throws: ClientError.self) { try await server.client.quotesInfo(directory: "/repo") }
  do { try await server.client.quotesInfo(directory: "/repo") } catch {
    #expect(QuoteServer.mode(after: error) == .local)
  }
}

@Test func webQuotesMapToTheDraftAndBackWithBlobReferences() throws {
  let sha = String(repeating: "ab", count: 32)
  let json = #"""
  {"id":"q-web","messageID":"msg_a","partID":"msg_a:text:0","text":"Rodando: nada.","comment":"Veja",
   "commentPrompt":[{"type":"text","start":0,"end":4,"content":"Veja"},
     {"type":"image","id":"local-web-id","filename":"foto.png","mime":"image/png","blob":{"id":"\#(sha)","url":""}}],
   "anchor":{"start":3,"end":17,"exact":"Rodando: nada.","prefix":"Status: ","suffix":" Pronto"},
   "attachments":[{"id":"\#(sha)","mime":"image/png","size":5}],"createdAt":1,"updatedAt":2,"revision":4}
  """#
  let server = try JSONDecoder().decode(QuoteServer.Quote.self, from: Data(json.utf8))
  let (quote, attachments) = QuoteServer.draft(server)
  #expect(quote.anchor?.coordinate == nil && quote.anchor?.prefix == "Status: " && quote.anchor?.suffix == " Pronto")
  #expect(quote.document.text == "Veja")
  #expect(quote.attachmentParts.compactMap { $0.object?["id"]?.string } == [sha])
  #expect(attachments == [DraftAttachment(id: sha, name: "foto.png", mime: "image/png", size: 5, quoteID: "q-web")])
  // A local (not yet uploaded) attachment never reaches `attachments`, and nothing carries a data URL.
  var edited = quote
  edited.commentPrompt = (edited.commentPrompt ?? []) + [.object(["type": .string("image"), "id": .string("UUID-local"),
    "filename": .string("nova.png"), "mime": .string("image/png"), "dataUrl": .string("data:image/png;base64,AA==")])]
  let local = DraftAttachment(id: "UUID-local", name: "nova.png", mime: "image/png", size: 1, quoteID: "q-web")
  let input = QuoteServer.input(edited, attachments: attachments + [local])
  #expect(input.attachments == [sha])
  let image = try #require(input.commentPrompt?.first { $0.object?["id"]?.string == sha }?.object)
  #expect(image["blob"] == .object(["id": .string(sha), "url": .string("")]))
  let encoded = try #require(String(data: JSONEncoder().encode(input), encoding: .utf8))
  #expect(encoded.contains(#""attachments":[""#) && !encoded.contains("createdAt"))
}

@Test func migrationUploadsImportsWithLocalIDsDismissesAndIsIdempotent() async throws {
  let server = FakeQuotes()
  let attachment = DraftAttachment(name: "foto.png", mime: "image/png", size: 3, quoteID: "q1")
  var quote = ChatQuote(id: "q1", messageID: "msg_a", partID: "msg_a:text:0", text: "Trecho", comment: "Olhe",
    anchor: .init(start: 0, end: 6, exact: "Trecho", coordinate: "source", prefix: "", suffix: " final"))
  quote.commentPrompt = [ComposerDocument(text: "Olhe").parts[0], attachment.commentPart]
  let other = ChatQuote(id: "q2", messageID: "msg_a", partID: "msg_a:text:0", text: "Outro")
  server.store.withLock { $0.failImport = 1 }
  let bytes: @Sendable (DraftAttachment) async throws -> Data = { _ in Data([1, 2, 3]) }
  let first = await QuoteMigration.run(quotes: [quote, other], attachments: [attachment], dismissed: ["sent-1"],
    sessionID: "ses_a", directory: "/repo", client: server.client, bytes: bytes)
  guard case .migrated(let state) = first else { Issue.record("expected migration"); return }
  let sha = SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
  #expect(state.quotes.map(\.id) == ["q1", "q2"])
  #expect(state.quotes[0].attachments.map(\.id) == [sha])
  #expect(state.quotes[0].anchor?.coordinate == "source" && state.quotes[0].anchor?.suffix == " final")
  #expect(QuoteServer.draft(state.quotes[0]).quote.attachmentParts.compactMap { $0.object?["id"]?.string } == [sha])
  #expect(state.dismissed == ["sent-1"])
  // A crash before the local copy was deleted repeats the migration: nothing is duplicated.
  let second = await QuoteMigration.run(quotes: [quote, other], attachments: [attachment], dismissed: [],
    sessionID: "ses_a", directory: "/repo", client: server.client, bytes: bytes)
  guard case .migrated(let again) = second else { Issue.record("expected migration"); return }
  #expect(again.quotes.map(\.id) == ["q1", "q2"])
  #expect(server.store.withLock { $0.calls.filter { $0 == "import" }.count } == 3)
  server.store.withLock { $0.unavailable = true }
  let offline = await QuoteMigration.run(quotes: [quote], attachments: [], dismissed: [], sessionID: "ses_a",
    directory: "/repo", client: server.client, bytes: bytes)
  #expect(offline == .retryLater)
}

@Test func alreadySentAndAttachmentDownloadsUseTheContract() async throws {
  let server = FakeQuotes()
  let client = server.client
  let quote = ChatQuote(id: "q1", messageID: "msg_a", partID: "msg_a:text:0", text: "Trecho", comment: "Olhe")
  let saved = try await client.saveQuote(QuoteServer.input(quote, attachments: []), sessionID: "ses_a", directory: "/repo")
  #expect(saved.quote.id == "q1" && saved.revision == 1)
  #expect(try await client.clearQuotes(["q1"], sent: true, sessionID: "ses_a", directory: "/repo") == 2)
  await #expect(throws: ClientError.self) {
    _ = try await client.saveQuote(QuoteServer.input(quote, attachments: []), sessionID: "ses_a", directory: "/repo")
  }
  do {
    _ = try await client.saveQuote(QuoteServer.input(quote, attachments: []), sessionID: "ses_a", directory: "/repo")
  } catch ClientError.rpc(let type) { #expect(type == "already_sent") }
  let stored = try await client.uploadQuoteAttachment(Data("olá".utf8), mime: "text/plain", filename: "a.txt",
    sessionID: "ses_a", directory: "/repo")
  #expect(QuoteServer.isAttachmentID(stored.id))
  #expect(try await client.quoteAttachment(stored.id, sessionID: "ses_a", directory: "/repo") == Data("olá".utf8))
  #expect(try await client.quotes("ses_a", directory: "/repo").quotes.isEmpty)
}

@Test func webAnchorsResolveByTextWithPrefixAndSuffixTieBreaks() throws {
  let source = "Primeiro item: **ação** rápida.\n\nSegundo item: ação  lenta."
  let blocks = MarkdownBlocks.parse(source)
  func quote(_ prefix: String?, _ suffix: String?, exact: String = "ação") -> ChatQuote {
    // Offsets from a different flattening (the web's textContent) never match iOS's rendered text.
    ChatQuote(messageID: "m", partID: "m:text:0", text: exact,
      anchor: .init(start: 900, end: 900 + exact.utf16.count, exact: exact, coordinate: "rendered", prefix: prefix, suffix: suffix))
  }
  let first = (source as NSString).range(of: "ação")
  let second = (source as NSString).range(of: "ação", range: NSRange(location: NSMaxRange(first), length: (source as NSString).length - NSMaxRange(first)))
  #expect(ChatQuoteAnchoring.sourceRanges(quote("Primeiro item: ", " rápida"), source: source, blocks: blocks) == [first])
  #expect(ChatQuoteAnchoring.sourceRanges(quote("Segundo item: ", " lenta"), source: source, blocks: blocks) == [second])
  #expect(ChatQuoteAnchoring.sourceRanges(quote("", "", exact: "ação"), source: source, blocks: blocks).isEmpty)
  // Older web drafts carry no context: when their offsets fail they are never moved, even to a unique match.
  #expect(ChatQuoteAnchoring.sourceRanges(quote(nil, nil, exact: "rápida"), source: source, blocks: blocks).isEmpty)
  #expect(ChatQuoteAnchoring.sourceRanges(quote("", nil, exact: "rápida"), source: source, blocks: blocks)
    == [(source as NSString).range(of: "rápida")])
  // Whitespace runs and line breaks compare as one space.
  let spaced = quote("item: ", nil, exact: "ação\n lenta")
  #expect(ChatQuoteAnchoring.sourceRanges(spaced, source: source, blocks: blocks)
    == [(source as NSString).range(of: "ação  lenta")])
  // Source anchors (iOS) keep never relocating; unanchored quotes keep the unique-text rule.
  let moved = ChatQuote(messageID: "m", partID: "m:text:0", text: "rápida",
    anchor: .init(start: 0, end: 6, exact: "rápida", coordinate: "source", prefix: "", suffix: ""))
  #expect(ChatQuoteAnchoring.sourceRanges(moved, source: source, blocks: blocks).isEmpty)
}

@Test func iOSSelectionsCaptureRenderedContextAroundTheQuote() throws {
  let source = "Antes do trecho **marcado** e depois dele."
  let block = try #require(MarkdownBlocks.parse(source).first)
  let range = (block.text as NSString).range(of: "marcado")
  let quote = try #require(ChatQuote.selection(source: source, block: block, range: range, messageID: "m", partID: "m:text:0"))
  #expect(quote.anchor?.coordinate == "source")
  #expect(quote.anchor?.prefix == "Antes do trecho ")
  #expect(quote.anchor?.suffix == " e depois dele.")
  let long = String(repeating: "x", count: 100) + " alvo " + String(repeating: "😀", count: 40)
  let wide = try #require(MarkdownBlocks.parse(long).first)
  let selected = try #require(ChatQuote.selection(source: long, block: wide,
    range: (wide.text as NSString).range(of: "alvo"), messageID: "m", partID: "m:text:0"))
  #expect(selected.anchor?.prefix?.utf16.count == 64)
  #expect((selected.anchor?.suffix?.utf16.count ?? 0) <= 66 && selected.anchor?.suffix?.unicodeScalars.allSatisfy { $0.value != 0xFFFD } == true)
}
