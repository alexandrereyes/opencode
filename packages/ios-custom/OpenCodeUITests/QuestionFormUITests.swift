import XCTest

/// An agent's question in the composer's place (A) and its iPhone sheet (B), against the isolated sandbox: each test
/// creates a session and a pending form through the API (no model is called), answers it in the app and reads the
/// answer back from the server. One answer field, the composer's own editor (dictation by the fake microphone and the
/// fixtures' reviewer, `-OpenCodeDictationFake`), follows the question shown; ‹ › keep each question as it was
/// answered; Responder answers the form; Escrever no chat brings the chat's composer back with its draft.
@MainActor final class QuestionFormUITests: XCTestCase {
  private let app = XCUIApplication()
  private let environment = ProcessInfo.processInfo.environment
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }

  private var composer: XCUIElement { app.descendants(matching: .any)["question-composer"].firstMatch }
  private var answer: XCUIElement { app.textViews["question-answer"].firstMatch }
  private var step: XCUIElement { app.staticTexts["question-step"].firstMatch }
  private func button(_ identifier: String) -> XCUIElement { app.buttons[identifier].firstMatch }
  private func option(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
  }
  private func waitValue(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  private func waitLabel(_ element: XCUIElement, _ text: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }
  private func waitKeyboard(_ shown: Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == %@", NSNumber(value: shown)),
      object: app.keyboards.firstMatch)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  private let revised = "Confira as sessões em andamento e prepare um resumo das alterações. Não envie esta mensagem antes da minha revisão."
  private func threeQuestions() async throws -> (String, String) {
    try await create([
      ["key": "tema", "type": "string", "title": "Qual tema usar nas capturas?",
       "description": "As capturas vão para a revisão do desenho; escolha o tema principal ou escreva outro.",
       "options": [["value": "claro", "label": "Claro", "description": "Fundo claro, como o app abre de dia"],
                   ["value": "escuro", "label": "Escuro", "description": "Fundo escuro, o tema que mais aparece nos prints"]],
       "custom": true],
      ["key": "alvos", "type": "multiselect", "title": "Onde testar?",
       "options": [["value": "mac", "label": "Mac"], ["value": "iphone", "label": "iPhone"], ["value": "watch", "label": "Watch"]],
       "custom": true],
      ["key": "nota", "type": "string", "title": "Algo mais para a revisão?"],
    ])
  }
  /// Each question as it was left: the step, the single choice, the multiple choice and its own item, the text.
  private func checkAnswers(dictated: Bool, file: StaticString = #filePath, line: UInt = #line) {
    button("question-previous").tap()
    button("question-previous").tap()
    XCTAssertTrue(waitLabel(step, "1 de 3"), step.label, file: file, line: line)
    XCTAssertTrue(option("Escuro").isSelected, file: file, line: line)
    XCTAssertFalse(option("Claro").isSelected, file: file, line: line)
    button("question-next").tap()
    XCTAssertTrue(waitLabel(step, "2 de 3"), step.label, file: file, line: line)
    XCTAssertTrue(option("Mac").isSelected && option("iPhone").isSelected, file: file, line: line)
    XCTAssertFalse(option("Watch").isSelected, file: file, line: line)
    XCTAssertTrue(app.staticTexts["Vision"].exists, file: file, line: line)
    button("question-next").tap()
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label, file: file, line: line)
    if dictated { XCTAssertEqual(answer.value as? String, revised, file: file, line: line) }
  }

  /// The main case (A): one input area, the chat's draft kept, three kinds of question answered, the last one
  /// dictated with its review; ‹ › again and again; the sheet (B) and back; Responder; the chat's draft again.
  func testTheQuestionTakesTheComposerAndKeepsEveryAnswer() async throws {
    let (session, form) = try await threeQuestions()
    try open(session, dictation: true)
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.textViews["conversation-composer"].exists, "one input area: the chat's composer gives way")
    capture("a-pergunta-1")
    // Escrever no chat, a draft, and back: the draft waits.
    button("question-write-chat").tap()
    let chat = app.textViews["conversation-composer"]
    XCTAssertTrue(chat.waitForExistence(timeout: 10))
    XCTAssertTrue(button("question-resume").exists)
    chat.tap()
    chat.typeText("Rascunho do chat")
    capture("a-escrever-no-chat")
    button("question-resume").tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["question-chat-kept"].exists)
    XCTAssertTrue(waitKeyboard(false) || !app.keyboards.firstMatch.exists)

    // 1: a single choice. Próxima goes on, Responder is not offered yet.
    XCTAssertTrue(waitLabel(step, "1 de 3"), step.label)
    option("Escuro").tap()
    XCTAssertTrue(option("Escuro").isSelected)
    XCTAssertEqual(button("question-primary").label, "Próxima pergunta: Onde testar?")
    button("question-primary").tap()
    // 2: two options and an item of its own, added by the answer composer's action.
    XCTAssertTrue(waitLabel(step, "2 de 3"), step.label)
    option("Mac").tap()
    option("iPhone").tap()
    answer.tap()
    answer.typeText("Vision")
    button("question-answer-done").tap()
    XCTAssertTrue(app.staticTexts["Vision"].waitForExistence(timeout: 5))
    capture("a-pergunta-2-multipla")
    button("question-primary").tap()
    // 3: dictated in the answer composer (the fake microphone, then the fixtures' reviewer).
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label)
    let microphone = button("dictation-microphone")
    XCTAssertTrue(microphone.waitForExistence(timeout: 10), app.debugDescription)
    microphone.tap()
    XCTAssertTrue(button("dictation-stop").waitForExistence(timeout: 10), app.debugDescription)
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertFalse(button("question-previous").isEnabled, "the dictation lands in its own question")
    capture("a-ditando")
    button("dictation-stop").tap()
    XCTAssertTrue(waitValue(answer, contains: "Confira as sessões", timeout: 30), String(describing: answer.value))
    XCTAssertEqual(answer.value as? String, revised)
    capture("a-pergunta-3-ditada")
    let before = try await state(session, form)
    XCTAssertEqual(before.status, "pending", "nothing answered before Responder")

    // ‹ › again and again: each question exactly as it was.
    checkAnswers(dictated: true)
    checkAnswers(dictated: true)

    // B: the same answer in its own sheet; Agora não only closes it.
    button("question-expand").tap()
    let sheet = app.descendants(matching: .any)["question-sheet"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label)
    XCTAssertEqual(answer.value as? String, revised)
    capture("b-ampliada-3")
    button("question-previous").tap()
    XCTAssertTrue(waitLabel(step, "2 de 3"), step.label)
    XCTAssertTrue(option("Mac").isSelected && option("iPhone").isSelected && !option("Watch").isSelected)
    capture("b-ampliada-2")
    button("question-sheet-close").tap()
    XCTAssertTrue(waitLabel(step, "2 de 3"), step.label)
    XCTAssertTrue(option("Mac").isSelected && option("iPhone").isSelected)
    let closed = try await state(session, form)
    XCTAssertEqual(closed.status, "pending", "closing the sheet answers nothing")
    button("question-next").tap()
    XCTAssertEqual(answer.value as? String, revised)
    checkAnswers(dictated: true)

    // Responder: the form's answer, each question's own; then the chat's composer with its draft.
    XCTAssertEqual(button("question-primary").label, "Responder")
    button("question-primary").tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["tema": .string("escuro"), "alvos": .array(["mac", "iphone", "Vision"]), "nota": .string(revised)])
    XCTAssertTrue(chat.waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertTrue(waitValue(chat, contains: "Rascunho do chat"), String(describing: chat.value))
    XCTAssertFalse(composer.exists)
    capture("a-respondida-chat-de-volta")
  }

  /// To the third question, the first two answered (Escuro; Mac).
  private func toTheThird() {
    option("Escuro").tap()
    button("question-primary").tap()
    XCTAssertTrue(waitLabel(step, "2 de 3"), step.label)
    option("Mac").tap()
    button("question-primary").tap()
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label)
  }

  /// A dictation that ends with its question off screen (Escrever no chat, stopped on the dictation strip) lands in
  /// its own question: in the form's answer while hidden (the server's draft has it), then in the field once back.
  func testADictationFinishedWithTheQuestionHiddenLandsInItsQuestion() async throws {
    let (session, form) = try await threeQuestions()
    try open(session, dictation: true, review: "3000")
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    button("question-write-chat").tap()
    let chat = app.textViews["conversation-composer"]
    XCTAssertTrue(chat.waitForExistence(timeout: 10))
    chat.tap()
    chat.typeText("Rascunho do chat")
    button("question-resume").tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    toTheThird()
    button("dictation-microphone").tap()
    XCTAssertTrue(button("dictation-stop").waitForExistence(timeout: 10), app.debugDescription)
    try await Task.sleep(for: .seconds(1.5))
    // The chat while it records; the strip stops it.
    button("question-write-chat").tap()
    XCTAssertTrue(chat.waitForExistence(timeout: 10))
    let stop = button("dictation-strip-stop")
    XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
    capture("oculta-gravando")
    stop.tap()
    let saved = try await waitDraft(session, form) { [revised] in $0?["nota"]?["text"] == .string(revised) }
    XCTAssertTrue(saved, "the dictated answer reached the form while its field was hidden")
    XCTAssertTrue(waitValue(chat, contains: "Rascunho do chat"), String(describing: chat.value))
    capture("oculta-pronta")
    // Back: the third question shows it, and stays so.
    button("question-resume").tap()
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label)
    XCTAssertTrue(waitValue(answer, contains: "Confira", timeout: 10), String(describing: answer.value))
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(answer.value as? String, revised)
    capture("oculta-de-volta")
    button("question-previous").tap()
    XCTAssertTrue(option("Mac").isSelected && !option("iPhone").isSelected)
    button("question-previous").tap()
    XCTAssertTrue(option("Escuro").isSelected)
    button("question-next").tap()
    button("question-next").tap()
    XCTAssertEqual(answer.value as? String, revised)
    button("question-primary").tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["tema": .string("escuro"), "alvos": .array(["mac"]), "nota": .string(revised)])
    XCTAssertTrue(chat.waitForExistence(timeout: 20))
    XCTAssertTrue(waitValue(chat, contains: "Rascunho do chat"), String(describing: chat.value))
  }

  /// A dictation still under review when the sheet (B) opens and closes again lands in the same question.
  func testADictationReviewedAcrossTheSheetLandsInItsQuestion() async throws {
    let (session, form) = try await threeQuestions()
    try open(session, dictation: true, review: "3000")
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    toTheThird()
    button("dictation-microphone").tap()
    XCTAssertTrue(button("dictation-stop").waitForExistence(timeout: 10), app.debugDescription)
    try await Task.sleep(for: .seconds(1.5))
    button("dictation-stop").tap()
    button("question-expand").tap()
    XCTAssertTrue(app.descendants(matching: .any)["question-sheet"].firstMatch.waitForExistence(timeout: 10))
    capture("b-durante-a-revisao")
    button("question-sheet-close").tap()
    XCTAssertTrue(waitValue(answer, contains: "Confira", timeout: 20), String(describing: answer.value))
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(answer.value as? String, revised)
    XCTAssertTrue(waitLabel(step, "3 de 3"), step.label)
    let saved = try await waitDraft(session, form) { [revised] in $0?["nota"]?["text"] == .string(revised) }
    XCTAssertTrue(saved)
  }

  /// A question longer than the composer's lines (Alexandre, 05/11): it says so, opens whole there and closes again,
  /// the answer field and the button within reach, in large text; the button names the next question; with the
  /// keyboard up Mostrar tudo opens the sheet; the open text and the answers stay across ‹ ›.
  func testALongQuestionOpensWholeInPlaceAndTheButtonNamesTheNextOne() async throws {
    let context = "O branch main está 131 commits à frente do remoto, com o merge da integração de ontem no topo. "
      + "O push só publica os commits no repositório; não faz deploy nem atualiza o servidor, que segue na versão "
      + "anterior até a próxima ativação. Os testes do merge passaram no fim da tarde. Posso enviar agora?"
    let (session, form) = try await create([
      ["key": "push", "type": "string", "title": "Push da main", "description": context, "custom": true,
       "options": [["value": "sim", "label": "Pode enviar", "description": "Envio os 131 commits agora"],
                   ["value": "depois", "label": "Depois", "description": "Deixo o push para quando você pedir"]]],
      ["key": "videos", "type": "string", "title": "Vídeos",
       "description": "Os dois vídeos de 3 min 19 s estão na pasta temporária.",
       "options": [["value": "copiar", "label": "Copiar para a Mesa"], ["value": "regravar", "label": "Regravar"],
                   ["value": "manter", "label": "Deixar onde estão"]]],
    ])
    try open(session, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    let whole = composer.staticTexts.matching(NSPredicate(format: "label == %@", context)).firstMatch
    let more = button("question-prompt-more")
    XCTAssertTrue(more.waitForExistence(timeout: 10), "the cut text says so")
    XCTAssertEqual(button("question-primary").label, "Próxima pergunta: Vídeos")
    capture("contexto-fechado")
    more.tap()
    XCTAssertTrue(button("question-prompt-less").waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["question-prompt-open"].exists)
    XCTAssertTrue(whole.exists)
    XCTAssertTrue(answer.isHittable && button("question-primary").isHittable, "the field and the button stay in reach")
    capture("contexto-aberto")
    option("Pode enviar").tap()
    // To the second and back: the text is still open, the option still marked.
    button("question-primary").tap()
    XCTAssertTrue(waitLabel(step, "2 de 2"), step.label)
    XCTAssertEqual(button("question-primary").label, "Responder")
    XCTAssertFalse(button("question-primary").isEnabled, "the last question unanswered: Responder waits")
    button("question-previous").tap()
    XCTAssertTrue(waitLabel(step, "1 de 2"), step.label)
    XCTAssertTrue(button("question-prompt-less").exists)
    XCTAssertTrue(option("Pode enviar").isSelected)
    button("question-prompt-less").tap()
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    // With the keyboard up only the title stays; Mostrar tudo opens the sheet with all of it.
    answer.tap()
    XCTAssertTrue(waitKeyboard(true))
    capture("contexto-teclado")
    more.tap()
    let sheet = app.descendants(matching: .any)["question-sheet"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@", context)).firstMatch.exists)
    button("question-sheet-close").tap()
    button("question-primary").tap()
    XCTAssertTrue(waitLabel(step, "2 de 2"), step.label)
    option("Deixar onde estão").tap()
    button("question-primary").tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["push": .string("sim"), "videos": .string("manter")])
  }

  /// A long question with long options, in large text: the options scroll in their own band, whole; the answer field
  /// with the keyboard keeps Responder in reach.
  func testALongQuestionInLargeTextStaysReadableWithTheKeyboard() async throws {
    let long = "No Acompanhar, o texto que a pessoa pede ao agente fica guardado no registro da avaliação pela vida da "
      + "conta, além dos registros técnicos de 30 dias. O que vale?"
    let (session, form) = try await create([
      ["key": "prazo", "type": "string", "title": "D033 Pedido de ajuste", "description": long,
       "options": [
         ["value": "prazo", "label": "Texto com prazo (Recomendado)", "description": "O registro fica sem o texto livre; o texto sai em 30 dias, como os registros técnicos"],
         ["value": "sempre", "label": "Guardar sempre", "description": "O texto fica no registro enquanto a conta existir, junto da avaliação"],
         ["value": "nunca", "label": "Não guardar", "description": "Nem o registro nem os logs técnicos guardam o texto livre da pessoa"],
       ], "custom": true],
    ])
    try open(session, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    capture("letra-grande")
    // The last option is reached by scrolling the options' band, never cut.
    let last = option("Não guardar")
    for _ in 0..<4 where !last.isHittable { composer.swipeUp() }
    XCTAssertTrue(last.isHittable)
    last.tap()
    XCTAssertTrue(last.isSelected)
    answer.tap()
    XCTAssertTrue(waitKeyboard(true))
    answer.typeText("Guardar só o resumo")
    XCTAssertTrue(answer.isHittable && button("question-primary").isHittable, "with the keyboard, field and Responder stay in reach")
    capture("letra-grande-teclado")
    // The sheet shows the question whole.
    button("question-expand").tap()
    let sheet = app.descendants(matching: .any)["question-sheet"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@", long)).firstMatch.exists,
      "the sheet shows the question whole")
    capture("letra-grande-ampliada")
    button("question-primary").tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["prazo": .string("Guardar só o resumo")])
  }

  // MARK: Drafts (`custom.question-drafts`)

  private func draftFields(_ session: String, _ form: String) async throws -> [String: [String: Value]]? {
    struct Field: Decodable { let selected: [String]; let text: String; let added: [String] }
    struct Draft: Decodable { let fields: [String: Field] }
    struct Output: Decodable { struct Inner: Decodable { let draft: Draft? }; let output: Inner }
    let output: Output = try await request("POST", "/api/rpc/custom.question-drafts/get",
      ["input": ["sessionID": session, "requestID": form]])
    return output.output.draft?.fields.mapValues {
      ["selected": .array($0.selected), "text": .string($0.text), "added": .array($0.added)]
    }
  }
  private func waitDraft(_ session: String, _ form: String, _ check: ([String: [String: Value]]?) -> Bool)
    async throws -> Bool
  {
    for _ in 0..<40 {
      if check(try await draftFields(session, form)) { return true }
      try await Task.sleep(for: .milliseconds(250))
    }
    return false
  }
  private func draftForm() async throws -> (String, String) {
    try await create([
      ["key": "voz", "type": "string", "title": "Voz do Abacato",
       "options": [["value": "marin", "label": "marin"], ["value": "cedar", "label": "cedar"]], "custom": true],
      ["key": "nota", "type": "string", "title": "Algo mais?"],
    ])
  }
  private func selected(_ label: String) -> Bool {
    app.buttons[label].firstMatch.isSelected
  }

  /// The main case: part of the answers, another session in the app and back; then the app closed and reopened.
  func testAnswersSurviveAnotherSessionAndTheAppClosing() async throws {
    let (session, form) = try await draftForm()
    // Another session waiting for an answer too, so the list shows it among the newest ones.
    let other = try await create([["key": "x", "type": "string", "title": "Outra pergunta"]])
    try open(session)
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    app.buttons["cedar"].tap()
    button("question-primary").tap()
    XCTAssertTrue(waitLabel(step, "2 de 2"), step.label)
    answer.tap()
    answer.typeText("rascunho")
    let saved = try await waitDraft(session, form) {
      $0?["voz"]?["selected"] == .array(["cedar"]) && $0?["nota"]?["text"] == .string("rascunho")
    }
    XCTAssertTrue(saved, "o rascunho chegou ao servidor")
    // Another session, inside the app, and back.
    app.showSessions()
    let otherRow = app.buttons["session-row-\(other.0)"]
    XCTAssertTrue(otherRow.waitForExistence(timeout: 20), app.debugDescription)
    otherRow.tap()
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForExistence(timeout: 20))
    app.showSessions()
    let row = app.buttons["session-row-\(session)"]
    XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
    row.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    // Back on the question it was on.
    XCTAssertTrue(waitLabel(step, "2 de 2"), step.label)
    XCTAssertTrue(waitValue(answer, contains: "rascunho"), String(describing: answer.value))
    button("question-previous").tap()
    capture("rascunho-voltou")
    // Closed and reopened.
    app.terminate()
    try open(session)
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertTrue(selected("cedar"))
    button("question-next").tap()
    XCTAssertTrue(waitValue(answer, contains: "rascunho"), String(describing: answer.value))
  }

  /// What another device saved shows here, when the form opens and while it is on screen.
  func testADraftFromAnotherDeviceAppears() async throws {
    let (session, form) = try await draftForm()
    let _: JSONObject = try await request("POST", "/api/rpc/custom.question-drafts/save", ["input": [
      "sessionID": session, "requestID": form, "client": "mac",
      "fields": ["voz": ["selected": [], "text": "viola", "added": []]]]])
    try open(session)
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertTrue(waitValue(answer, contains: "viola"), String(describing: answer.value))
    let _: JSONObject = try await request("POST", "/api/rpc/custom.question-drafts/save", ["input": [
      "sessionID": session, "requestID": form, "client": "mac",
      "fields": ["nota": ["selected": [], "text": "do Mac", "added": []]]]])
    button("question-next").tap()
    XCTAssertTrue(waitValue(answer, contains: "do Mac"), String(describing: answer.value))
    capture("rascunho-outro-aparelho")
  }

  /// Sending the answers leaves no draft behind.
  func testAnsweringClearsTheDraft() async throws {
    let (session, form) = try await draftForm()
    try open(session)
    XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
    app.buttons["marin"].tap()
    button("question-primary").tap()
    answer.tap()
    answer.typeText("ok")
    let saved = try await waitDraft(session, form) { $0?["nota"]?["text"] == .string("ok") }
    XCTAssertTrue(saved)
    button("question-primary").tap()
    let answered = try await waitAnswered(session, form)
    XCTAssertEqual(answered, ["voz": .string("marin"), "nota": .string("ok")])
    let cleared = try await waitDraft(session, form) { $0 == nil }
    XCTAssertTrue(cleared, "responder limpa o rascunho")
  }

  // MARK: Helpers

  private func open(_ session: String, dictation: Bool = false, review: String = "800", extra: [String] = []) throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeOpenSession", session,
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
      + (dictation ? ["-OpenCodeDictationFake", "-OpenCodeDictationReview", review] : []) + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
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

  struct JSONObject: Decodable {}
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
