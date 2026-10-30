import XCTest

/// The question form against the isolated sandbox: each test creates a session and a pending form through the API
/// (no model is called), answers it in the app and reads the answer back from the server. The answer fields have no
/// send button of their own; Return sends once every question is answered, otherwise goes to the next one.
@MainActor final class QuestionFormUITests: XCTestCase {
  private let app = XCUIApplication()
  private let environment = ProcessInfo.processInfo.environment
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }

  func testSeveralQuestionsReturnGoesToTheNextOneThenSends() async throws {
    let (session, form) = try await create([
      ["key": "voz", "type": "string", "title": "Voz do Abacato", "description": "Qual voz o Abacato usa?",
       "options": [["value": "marin", "label": "marin"], ["value": "cedar", "label": "cedar"]], "custom": true],
      ["key": "seguir", "type": "string", "title": "Seguir com o desenho",
       "options": [["value": "sim", "label": "Sim, seguir"], ["value": "apps", "label": "Prefiro mudar os apps"]]],
      ["key": "nota", "type": "string", "title": "Algo mais?"],
    ])
    try open(session)
    let voz = app.textFields["question-answer-voz"]
    XCTAssertTrue(voz.waitForExistence(timeout: 30), app.debugDescription)
    voz.tap()
    voz.typeText("viola")
    // Only the form's Enviar sends; the field has no ↑ of its own.
    XCTAssertTrue(app.buttons["Enviar"].exists)
    XCTAssertFalse(app.buttons["composer-send"].exists)
    XCTAssertFalse(app.buttons["Enviar mensagem"].exists)
    capture("pergunta-campo-sem-enviar")
    // "seguir" has options only: Return leaves the field for it, without sending.
    voz.typeText("\n")
    XCTAssertTrue(waitFocus(voz, false))
    let status = try await state(session, form)
    XCTAssertEqual(status.status, "pending")
    app.buttons["Sim, seguir"].tap()
    let nota = app.textFields["question-answer-nota"]
    nota.tap()
    nota.typeText("ok")
    capture("pergunta-respondida")
    nota.typeText("\n")
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["voz": .string("viola"), "seguir": .string("sim"), "nota": .string("ok")])
  }

  func testReturnFromAnEarlierQuestionGoesToTheNextTypedAnswer() async throws {
    let (session, form) = try await create([
      ["key": "nome", "type": "string", "title": "Nome do módulo"],
      ["key": "pasta", "type": "string", "title": "Em que pasta salvar?"],
    ])
    try open(session)
    let nome = app.textFields["question-answer-nome"]
    let pasta = app.textFields["question-answer-pasta"]
    XCTAssertTrue(nome.waitForExistence(timeout: 30), app.debugDescription)
    nome.tap()
    nome.typeText("capturas\n")
    XCTAssertTrue(waitFocus(pasta, true))
    pasta.typeText("Capturas/2026\n")
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["nome": .string("capturas"), "pasta": .string("Capturas/2026")])
  }

  func testOneMultipleChoiceReturnAddsTheOwnAnswerThenSends() async throws {
    let (session, form) = try await create([
      ["key": "itens", "type": "multiselect", "title": "O que testar?",
       "options": [["value": "mac", "label": "Mac"], ["value": "iphone", "label": "iPhone"]], "custom": true],
    ])
    try open(session)
    let itens = app.textFields["question-answer-itens"]
    XCTAssertTrue(itens.waitForExistence(timeout: 30), app.debugDescription)
    app.buttons["Mac"].tap()
    itens.tap()
    itens.typeText("watch\n")
    XCTAssertTrue(app.staticTexts["watch"].waitForExistence(timeout: 5))
    let status = try await state(session, form)
    XCTAssertEqual(status.status, "pending")
    capture("pergunta-multipla")
    // Empty, with everything answered: Return is Enviar.
    itens.typeText("\n")
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["itens": Value.array(["mac", "watch"])])
  }

  // MARK: Helpers

  private func open(_ session: String) throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeOpenSession", session,
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
  }

  private func waitFocus(_ element: XCUIElement, _ focused: Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == %@", NSNumber(value: focused)),
      object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  enum Value: Decodable, Equatable {
    case string(String), array([String])
    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self) { self = .string(text); return }
      self = .array(try container.decode([String].self))
    }
  }
  struct State: Decodable { let status: String; let answer: [String: Value]? }

  /// A session in the test directory with one pending question form.
  private func create(_ fields: [[String: Any]]) async throws -> (String, String) {
    let directory = try XCTUnwrap(environment["OPENCODE_TEST_DIRECTORY"])
    struct Created: Decodable { struct Data: Decodable { let id: String }; let data: Data }
    let session: Created = try await request("POST", "/api/session",
      ["title": "Pergunta \(name)", "location": ["directory": directory]])
    let form: Created = try await request("POST", "/api/session/\(session.data.id)/form",
      ["title": "Questions", "fields": fields, "metadata": ["kind": "question"]])
    return (session.data.id, form.data.id)
  }

  private func state(_ session: String, _ form: String) async throws -> State {
    struct Detail: Decodable { struct Data: Decodable { let state: State }; let data: Data }
    let detail: Detail = try await request("GET", "/api/session/\(session)/form/\(form)", nil)
    return detail.data.state
  }

  private func waitAnswered(_ session: String, _ form: String) async throws -> [String: Value]? {
    for _ in 0..<40 {
      let current = try await state(session, form)
      if current.status != "pending" { return current.answer }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("O formulário continuou pendente")
    return nil
  }

  private func request<Output: Decodable>(_ method: String, _ path: String, _ body: [String: Any]?) async throws
    -> Output
  {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + path)))
    request.httpMethod = method
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
    return try JSONDecoder().decode(Output.self, from: data)
  }
}
