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

  // MARK: Keyboard

  /// A long question first, so the second question's field starts below the visible conversation.
  private func keyboardForm(second: [String: Any]) async throws -> (String, String) {
    let long = "No Acompanhar, o texto que a pessoa pede ao agente fica guardado no registro da avaliação pela vida da "
      + "conta, além dos registros técnicos de 30 dias. O que vale?"
    return try await create([
      ["key": "prazo", "type": "string", "title": "D033 Pedido de ajuste", "description": long,
       "options": [
         ["value": "prazo", "label": "Texto com prazo (Recomendado)", "description": "O registro fica sem o texto livre; o texto sai em 30 dias, como os registros técnicos"],
         ["value": "sempre", "label": "Guardar sempre", "description": "O texto fica no registro enquanto a conta existir, junto da avaliação"],
         ["value": "nunca", "label": "Não guardar", "description": "Nem o registro nem os logs técnicos guardam o texto livre da pessoa"],
       ], "custom": true],
      second,
    ])
  }
  private func option(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
  }
  private func waitKeyboard(_ shown: Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == %@", NSNumber(value: shown)),
      object: app.keyboards.firstMatch)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  /// Tapping an option (or empty space in the card) leaves the answer field; tapping the field brings it back.
  func testTappingAnOptionOrTheCardHidesTheKeyboard() async throws {
    let (session, form) = try await keyboardForm(second: ["key": "nota", "type": "string", "title": "Algo mais?"])
    try open(session)
    let prazo = app.textFields["question-answer-prazo"]
    XCTAssertTrue(prazo.waitForExistence(timeout: 30), app.debugDescription)
    prazo.tap()
    prazo.typeText("outra")
    XCTAssertTrue(waitKeyboard(true))
    option("Guardar sempre").tap()
    XCTAssertTrue(waitKeyboard(false), "Tocar numa opção esconde o teclado")
    capture("teclado-opcao")
    // The option's own answer field focuses again.
    prazo.tap()
    XCTAssertTrue(waitKeyboard(true))
    XCTAssertTrue(waitFocus(prazo, true))
    // Empty space in the card: its title.
    app.staticTexts["D033 Pedido de ajuste"].tap()
    XCTAssertTrue(waitKeyboard(false), "Tocar fora dos campos esconde o teclado")
    // Answers and Enviar still work.
    option("Texto com prazo").tap()
    let nota = app.textFields["question-answer-nota"]
    nota.tap()
    nota.typeText("ok")
    app.staticTexts["Algo mais?"].tap()
    XCTAssertTrue(waitKeyboard(false))
    app.buttons["Enviar"].tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["prazo": .string("prazo"), "nota": .string("ok")])
  }

  /// Return toward a question with options only leaves the field and hides the keyboard.
  func testReturnToAnOptionsOnlyQuestionHidesTheKeyboard() async throws {
    let (session, _) = try await keyboardForm(second: ["key": "seguir", "type": "string", "title": "Seguir com o desenho",
      "options": [["value": "sim", "label": "Sim, seguir"], ["value": "nao", "label": "Não seguir"]]])
    try open(session)
    let prazo = app.textFields["question-answer-prazo"]
    XCTAssertTrue(prazo.waitForExistence(timeout: 30), app.debugDescription)
    prazo.tap()
    prazo.typeText("outra\n")
    XCTAssertTrue(waitKeyboard(false), "Return para uma pergunta só de opções esconde o teclado")
    XCTAssertTrue(waitFocus(prazo, false))
  }

  /// Return toward a question with its own answer focuses that field where it can be seen.
  func testReturnToAQuestionWithItsOwnAnswerShowsThatField() async throws {
    let (session, _) = try await keyboardForm(second: ["key": "voz", "type": "string", "title": "Voz do Abacato",
      "options": [["value": "marin", "label": "marin"], ["value": "cedar", "label": "cedar"]], "custom": true])
    try open(session)
    let prazo = app.textFields["question-answer-prazo"]
    XCTAssertTrue(prazo.waitForExistence(timeout: 30), app.debugDescription)
    prazo.tap()
    prazo.typeText("outra\n")
    let voz = app.textFields["question-answer-voz"]
    XCTAssertTrue(waitFocus(voz, true))
    let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: voz)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "O campo em foco aparece na tela")
    capture("teclado-proxima-resposta")
  }

  /// Dragging the conversation hides the keyboard of a question's field; the composer's keeps working.
  func testDraggingTheConversationHidesTheKeyboard() async throws {
    let (session, _) = try await keyboardForm(second: ["key": "nota", "type": "string", "title": "Algo mais?"])
    try open(session)
    let prazo = app.textFields["question-answer-prazo"]
    XCTAssertTrue(prazo.waitForExistence(timeout: 30), app.debugDescription)
    prazo.tap()
    XCTAssertTrue(waitKeyboard(true))
    app.collectionViews["conversation-transcript"].swipeUp()
    XCTAssertTrue(waitKeyboard(false), "Arrastar a conversa esconde o teclado")
    capture("teclado-arrastar")
    let composer = app.textViews["conversation-composer"]
    composer.tap()
    XCTAssertTrue(waitKeyboard(true))
    composer.typeText("Rascunho")
    XCTAssertTrue((composer.value as? String ?? "").contains("Rascunho"))
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
