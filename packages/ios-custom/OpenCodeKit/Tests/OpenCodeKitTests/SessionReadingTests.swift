import Foundation
import Testing

@testable import OpenCodeKit

@Test func transcriptSearchFoldsCaseAccentsAndRetainsUTF16EmojiRanges() {
  let text = "😀 AÇÃO ação Ac\u{327}a\u{303}o 👩🏽‍💻"
  let ranges = ConversationSearch.ranges(" acao ", in: text)
  #expect(ranges.count == 3)
  #expect(ranges.first == NSRange(location: 3, length: 4))
  #expect(ranges.map { (text as NSString).substring(with: $0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")) } == ["acao", "acao", "acao"])
  #expect(ConversationSearch.ranges("👩🏽‍💻", in: text).count == 1)
  #expect(ConversationSearch.ranges("  ", in: text).isEmpty)
  #expect(ConversationSearch.ranges("aa", in: "aaa").count == 1)
}

@Test func transcriptSearchOrdersOccurrencesAndExcludesToolAndReasoning() throws {
  let messages = try JSONDecoder().decode([ConversationMessage].self, from: Data("""
    [{"id":"z","type":"user","time":{"created":1},"text":"ação ação"},
     {"id":"a","type":"assistant","time":{"created":1},"content":[
       {"type":"reasoning","text":"ação"},{"type":"text","text":"AÇÃO"},
       {"type":"tool","name":"shell","state":{"input":{"command":"ação"}}},
       {"type":"text","text":"ação"}]}]
    """.utf8))
  let found = ConversationSearch.matches("acao", messages: messages)
  #expect(found.map(\.partID) == ["z:text:0", "z:text:0", "a:text:0", "a:text:1"])
  #expect(found.map(\.range.location) == [0, 5, 0, 0])
  #expect(ConversationSearch.counter(index: 2, count: found.count) == "3 de 4")
  #expect(ConversationSearch.counter(index: nil, count: 0) == "0 de 0")
}

@Test func searchHighlightsMapSourceAcrossMarkdownRunsWithoutGeneratedMarkers() throws {
  let source = "- Prefixo **ação** e `código` 😀"
  let block = try #require(MarkdownBlocks.parse(source).first)
  let range = (source as NSString).range(of: "ação** e `código")
  let rendered = ConversationSearch.renderedRanges(range, block: block)
  #expect(rendered.map { (block.text as NSString).substring(with: $0) }.joined() == "ação e código")
  #expect(ConversationSearch.renderedRanges(NSRange(location: 0, length: 1), block: block).isEmpty)
}

@Test func olderSearchIsBoundedAndStopsAtNewMatchesOrExhaustion() {
  #expect(ConversationSearch.continuePaging(hasOlder: true, pages: 0, foundNew: false))
  #expect(ConversationSearch.continuePaging(hasOlder: true, pages: 2, foundNew: false))
  #expect(!ConversationSearch.continuePaging(hasOlder: true, pages: 3, foundNew: false))
  #expect(!ConversationSearch.continuePaging(hasOlder: false, pages: 1, foundNew: false))
  #expect(!ConversationSearch.continuePaging(hasOlder: true, pages: 1, foundNew: true))
}

@Test func renameIgnoresEmptyUnchangedAndRollsBackOnlyItsOptimisticTitle() throws {
  #expect(SessionRename(" \n ", current: "Antes") == nil)
  #expect(SessionRename(" Antes \n", current: "Antes") == nil)
  let change = try #require(SessionRename(" Depois \n", current: "Antes"))
  #expect(change.title == "Depois")
  #expect(change.rollback(current: "Depois") == "Antes")
  #expect(change.rollback(current: "Atualizado externamente") == "Atualizado externamente")
}

@Test func removedTodoIsSuppressedEvenWhenFailedAndDoesNotCountInStepSummary() {
  for status in ["completed", "running", "error"] {
    let todo = ConversationPart(type: "tool", name: "todowrite", state: .object(["status": .string(status)]))
    #expect(todo.suppressed)
    #expect(ConversationProjection.stepLabel([todo, ConversationPart(type: "tool", name: "read")]) == "Usou 1 · Ler")
  }
}

@Test func noticesRequireTypedEvidenceNotAnArbitrary404OrNetworkFailure() {
  #expect(ConversationNotice.classify(ClientError.incompatibleServer, directory: nil) == .incompatible)
  #expect(ConversationNotice.classify(ClientError.locationNotFound("/a"), directory: "/a") == .missingDirectory("/a"))
  #expect(ConversationNotice.classify(ClientError.locationNotFound("/other"), directory: "/a") == nil)
  #expect(ConversationNotice.classify(ClientError.http(404), directory: "/a") == nil)
  #expect(ConversationNotice.classify(URLError(.notConnectedToInternet), directory: "/a") == nil)
}

@Test func renameUsesPatchAndInfoWithoutVersionIsIncompatible() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    if request.url?.path == "/api/info" {
      return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/api/session/ses_test")
    let payload = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    #expect(payload == .object(["title": .string("Novo")]))
    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
  }
  try await client.rename("ses_test", title: "Novo")
  await #expect(throws: ClientError.self) { try await client.info() }
}

@Test func detailsReadEachServiceInTheSessionsLocationAndPreserveUnavailable() async {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.first { $0.name == "location[directory]" }?.value == "/test/checkout")
    let body: String = switch request.url?.path {
    case "/api/mcp": """
      {"data":[{"name":"Docs","status":{"status":"needs_auth","error":"Login"}}]}
      """
    case "/api/plugin": """
      {"data":[{"source":{"type":"builtin"},"state":{"status":"active"}},
       {"id":"custom","source":{"type":"local","path":"/plugin"},"state":{"status":"active"}}]}
      """
    case "/api/config": """
      [{"type":"document","info":{"lsp":{"swift":{"disabled":true},"ts":{"disabled":false}}}},
       {"type":"document","info":{"lsp":false}},
       {"type":"document","info":{"lsp":{"swift":{"disabled":false}}}}]
      """
    case "/api/vcs": #"{"data":{"branch":{"current":"review"}}}"#
    case "/api/vcs/diff": #"{"data":[{"file":"test.swift","additions":12,"deletions":3}]}"#
    default: "{}"
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/api/skill" ? 503 : 200, httpVersion: nil, headerFields: nil)!)
  }
  let details = await client.sessionServices(directory: "/test/checkout")
  #expect(details.branch == "review")
  #expect(details.changes?.first?.additions == 12)
  #expect(details.plugins?.map(\.id) == ["custom"])
  #expect(details.mcp?.first?.label == "Requer autenticação")
  #expect(details.skills == nil)
  #expect(details.lsp?.map(\.id) == ["swift"])
  #expect(details.lsp?.first?.label == "Configurado")
}

@Test func missingDirectoryHTTPReadsTypedBodyAndAvailabilityUsesDefaultLocation() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    if request.url?.path.contains("/rpc/") == true {
      #expect(request.url?.query == nil)
      let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
      #expect(body.object?["input"]?.object?["directory"]?.string == "/missing")
      return (Data("{\"output\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    return (Data("""
      {"_tag":"LocationNotFoundError","location":{"directory":"/missing"},"message":"Missing"}
      """.utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.directoryAvailable("/missing") == false)
  do {
    _ = try await client.models(directory: "/missing")
    Issue.record("A Location ausente deve produzir um erro tipado")
  } catch {
    #expect(ConversationNotice.classify(error, directory: "/missing") == .missingDirectory("/missing"))
  }
}

@Test func malformedLegacyVersionIsStillClassifiedAsIncompatible() async {
  for body in ["{}", #"{"version":null}"#, #"{"version":42}"#] {
    let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
      (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await client.info()
      Issue.record("A resposta sem versão textual deve ser incompatível")
    } catch {
      #expect(ConversationNotice.classify(error, directory: nil) == .incompatible)
    }
  }
}
