import XCTest

@testable import OpenCode
@testable import OpenCodeKit

/// The form's answer behind `QuestionComposer` (A) and `QuestionSheet` (B), against a local fake server: ‹ › keep
/// every question as it was answered, a single choice's own text survives an option marked meanwhile, a failed
/// Responder keeps it all, and the answer goes once, with exactly what the visible questions hold.
private actor QuestionServer {
  private(set) var replies: [JSONValue] = []
  private(set) var dismissed = 0
  private var fails = false
  func failNext() { fails = true }
  func response(_ request: URLRequest) -> (Data, URLResponse) {
    let path = request.url!.path
    var status = 200
    var body = #"{"data":[]}"#
    if path.hasSuffix("/reply") {
      if fails {
        fails = false
        status = 500
        body = #"{"error":"indisponível"}"#
      } else {
        replies.append(try! JSONDecoder().decode(JSONValue.self, from: request.httpBody!))
        body = ""
      }
    } else if request.httpMethod == "DELETE", path.contains("/form/") {
      dismissed += 1
      body = ""
    } else if path.hasPrefix("/api/rpc/custom.question-drafts/") {
      body = path.hasSuffix("/get") ? #"{"output":{"draft":null}}"# : #"{"output":null}"#
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class QuestionComposerTests: XCTestCase {
  private func form() throws -> PendingForm {
    try JSONDecoder().decode(PendingForm.self, from: Data("""
      {"id":"frm_\(UUID().uuidString)","sessionID":"ses_question","title":"Questions","metadata":{"kind":"question"},
       "fields":[
        {"key":"tema","type":"string","title":"Qual tema usar?","custom":true,
         "options":[{"value":"claro","label":"Claro"},{"value":"escuro","label":"Escuro"}]},
        {"key":"alvos","type":"multiselect","title":"Onde testar?","custom":true,
         "options":[{"value":"mac","label":"Mac"},{"value":"iphone","label":"iPhone"},{"value":"watch","label":"Watch"}]},
        {"key":"nota","type":"string","title":"Algo mais?"}]}
      """.utf8))
  }

  private func wait(_ what: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Tempo esgotado: \(what)")
  }

  func testNavigationKeepsEveryAnswerAndRespondSendsThemOnceAfterAFailure() async throws {
    let server = QuestionServer()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4391")!)) {
      await server.response($0)
    }
    let store = ConversationStore(id: "ses_question", client: client, hub: EventHub(client: client))
    let form = try form()
    let answering = QuestionAnswering(form: form, store: store)
    let (tema, alvos, nota) = (answering.fields[0], answering.fields[1], answering.fields[2])
    let escuro = try XCTUnwrap(tema.options?[1])
    let (mac, iphone) = (try XCTUnwrap(alvos.options?[0]), try XCTUnwrap(alvos.options?[1]))
    XCTAssertEqual(answering.field?.key, "tema")
    XCTAssertEqual(answering.next, .next("alvos"), "nothing answered: Próxima, as Return did")

    // A single choice: its own text, then an option marked, unmarked and marked again.
    answering.type("Sépia", in: tema)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("Sépia"))
    answering.choose(escuro, in: tema)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("escuro"))
    XCTAssertEqual(answering.text(tema), "Sépia", "the typed text stays in the field under the option")
    answering.choose(escuro, in: tema)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("Sépia"), "unmarked: the own answer is back")
    answering.choose(escuro, in: tema)
    // Return goes to the next unanswered question.
    answering.advance()
    XCTAssertEqual(answering.field?.key, "alvos")

    // A multiple choice: two options and an item of its own (Return adds it).
    answering.choose(mac, in: alvos)
    answering.choose(iphone, in: alvos)
    answering.type("Vision", in: alvos)
    answering.advance()
    XCTAssertEqual(answering.sync.state.values["alvos"], .array([.string("mac"), .string("iphone"), .string("Vision")]))
    XCTAssertEqual(answering.text(alvos), "")
    XCTAssertEqual(answering.added(alvos), ["Vision"])
    answering.advance()
    XCTAssertEqual(answering.field?.key, "nota")
    answering.type("Confira as sessões em andamento.", in: nota)

    // Back and forth, again and again: each question exactly as it was left.
    for _ in 0..<3 {
      answering.move(-1)
      XCTAssertEqual(answering.field?.key, "alvos")
      XCTAssertTrue(answering.selected(mac, in: alvos) && answering.selected(iphone, in: alvos))
      XCTAssertFalse(answering.selected(try XCTUnwrap(alvos.options?[2]), in: alvos))
      XCTAssertEqual(answering.added(alvos), ["Vision"])
      answering.move(-1)
      XCTAssertEqual(answering.field?.key, "tema")
      XCTAssertTrue(answering.selected(escuro, in: tema))
      XCTAssertEqual(answering.text(tema), "Sépia")
      answering.move(-1)
      XCTAssertEqual(answering.field?.key, "tema", "the first question is the first")
      answering.move(1)
      answering.move(1)
      XCTAssertEqual(answering.field?.key, "nota")
      XCTAssertEqual(answering.text(nota), "Confira as sessões em andamento.")
      answering.move(1)
      XCTAssertEqual(answering.field?.key, "nota", "the last question is the last")
    }
    // Ampliar and Agora não change nothing.
    answering.expanded = true
    answering.expanded = false
    XCTAssertEqual(answering.field?.key, "nota")
    XCTAssertEqual(answering.next, .send)

    // Responder fails: everything stays, nothing was dismissed.
    await server.failNext()
    answering.send()
    try await wait("a falha") { store.error != nil && !answering.sending }
    let none = await server.replies
    XCTAssertTrue(none.isEmpty)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("escuro"))
    XCTAssertEqual(answering.text(tema), "Sépia")
    XCTAssertEqual(answering.sync.state.values["alvos"], .array([.string("mac"), .string("iphone"), .string("Vision")]))
    XCTAssertEqual(answering.text(nota), "Confira as sessões em andamento.")

    // Again: once, with each question's answer.
    answering.send()
    answering.send()
    try await wait("a resposta") { await server.replies.count == 1 && !answering.sending }
    let replies = await server.replies
    XCTAssertEqual(replies.count, 1, "Responder sends once")
    XCTAssertEqual(replies.first, .object(["answer": .object([
      "tema": .string("escuro"),
      "alvos": .array([.string("mac"), .string("iphone"), .string("Vision")]),
      "nota": .string("Confira as sessões em andamento."),
    ])]))
    let dismissed = await server.dismissed
    XCTAssertEqual(dismissed, 0)
  }

  /// Emptying a single choice's own text keeps a marked option; typing replaces it.
  func testTypingReplacesAMarkedOptionAndEmptyingKeepsIt() async throws {
    let server = QuestionServer()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4392")!)) {
      await server.response($0)
    }
    let store = ConversationStore(id: "ses_question", client: client, hub: EventHub(client: client))
    let answering = QuestionAnswering(form: try form(), store: store)
    let tema = answering.fields[0]
    let claro = try XCTUnwrap(tema.options?[0])
    answering.choose(claro, in: tema)
    answering.type("Al", in: tema)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("Al"))
    answering.type("", in: tema)
    XCTAssertNil(answering.sync.state.values["tema"])
    answering.choose(claro, in: tema)
    answering.type("", in: tema)
    XCTAssertEqual(answering.sync.state.values["tema"], .string("claro"))
  }
}
