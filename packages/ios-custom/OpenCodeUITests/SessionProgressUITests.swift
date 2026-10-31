import XCTest

/// Progresso (rev. 2026-10-30) against an isolated sandbox whose fake repository turns `experimental.todo` on. The
/// owned import's transcript already ends with a completed `todowrite` (3 completed, 1 in progress, 2 pending, 1
/// cancelled); one tiny real prompt (Luna 6/low, `sleep 45`) makes the session itself work. While it runs, the
/// Sessões row, the pill and its sheet show 3/7; when the run ends, they go away. `script/test-progress.py`.
@MainActor final class SessionProgressUITests: XCTestCase {
  private static let current = "Atualizar a Live Activity e o relógio"
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  override func setUp() { continueAfterFailure = false }

  private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + path)))
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode), path)
    return data
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 25) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout), .completed,
      "\(predicate) · \(element.debugDescription.prefix(300))")
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id]
  }

  /// TestFlight 202610302208 (30/10): the run's last Atividade sat cut right above the pill, and a tap on it showed
  /// nothing. At the end of a long conversation (`prepare --history 12`), the run's start brings the pill and the
  /// working bar: what the reader saw at the end stays whole above them; ↓ brings the run's Atividade whole above the
  /// pill; a tap opens it where it can be seen, and closes it again. It stays whole with a quote in the tray, the
  /// keyboard open and after the full-screen composer; when the run ends, the stack leaves no empty room.
  func testLastActivityStaysWholeAboveThePillAndOpens() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PROGRESS_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", session]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 30))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    func lowest(_ label: String) -> XCUIElement? {
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).allElementsBoundByIndex
        .filter { $0.exists && $0.frame.height > 0 }.min { $0.frame.height < $1.frame.height }
    }
    XCTAssertNotNil(lowest("Plano registrado"), "a conversa não abriu no fim")
    let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-'"))
    let before = Set(groups.allElementsBoundByIndex.map(\.identifier))
    let pill = app.buttons["conversation-progress"]
    XCTAssertFalse(pill.exists)
    shot(app, "pill-before-run")

    // The run starts: the pill and the working bar take room below the conversation, not what the reader saw.
    _ = try await request("/api/session/\(session)/prompt", method: "POST", body: [
      "id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      "text": "Use a ferramenta shell para rodar exatamente: sleep 150. Não use todowrite. Depois responda só: pronto.",
      "delivery": "steer",
    ])
    XCTAssertTrue(pill.waitForExistence(timeout: 60))
    try await Task.sleep(for: .seconds(1.5))
    shot(app, "pill-appeared")
    let seen = try XCTUnwrap(lowest("Plano registrado"), "o fim que estava na tela sumiu").frame
    XCTContext.runActivity(named: "início: transcript \(transcript.frame) · fim visto \(seen) · pílula \(pill.frame)") { _ in }
    XCTAssertLessThanOrEqual(seen.maxY, transcript.frame.maxY + 0.5, "a pílula cobre o fim que estava na tela")

    // ↓ to the run's Atividade, the conversation's last row while the shell sleeps.
    var run: XCUIElement?
    let deadline = Date.now.addingTimeInterval(60)
    while run == nil, Date.now < deadline {
      let jump = app.buttons["Ir para a mais recente"]
      if jump.exists { jump.tap() }
      run = groups.allElementsBoundByIndex.filter { !before.contains($0.identifier) && $0.label.contains("Shell") }
        .max { $0.frame.minY < $1.frame.minY }
      if run == nil { try await Task.sleep(for: .seconds(2)) }
    }
    let last = app.buttons[try XCTUnwrap(run, "a Atividade da execução não apareceu").identifier]
    try await Task.sleep(for: .seconds(1.5))
    shot(app, "pill-last-activity")
    XCTContext.runActivity(named: "fim: transcript \(transcript.frame) · atividade \(last.frame) · pílula \(pill.frame)") { _ in }
    XCTAssertTrue(pill.exists, "a execução terminou antes da conferência")
    XCTAssertLessThanOrEqual(last.frame.maxY, pill.frame.minY, "a última Atividade fica embaixo da pílula")
    XCTAssertLessThanOrEqual(last.frame.maxY, transcript.frame.maxY + 0.5, "a última Atividade sai da conversa")

    // A tap just above the pill opens it, and what it opens shows above the pill.
    last.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
    wait(NSPredicate(format: "value == 'Expandido'"), on: last, timeout: 10)
    try await Task.sleep(for: .seconds(1.5))
    shot(app, "pill-activity-open")
    // The shell call inside the card (not the prompt, which also says "sleep 150").
    let command = app.descendants(matching: .any).matching(NSPredicate(
      format: "label CONTAINS 'sleep 150' AND NOT (label CONTAINS 'Use a ferramenta')")).allElementsBoundByIndex
      .filter { $0.frame.height > 0 }.min { $0.frame.height < $1.frame.height }
    XCTContext.runActivity(named: "aberto: atividade \(last.frame) · comando \(command?.frame ?? .zero)") { _ in }
    XCTAssertTrue(pill.exists, "a execução terminou antes da conferência")
    let shown = try XCTUnwrap(command, "o conteúdo aberto não aparece")
    XCTAssertLessThanOrEqual(shown.frame.maxY, pill.frame.minY, "o conteúdo aberto fica embaixo da pílula")
    XCTAssertLessThanOrEqual(shown.frame.maxY, transcript.frame.maxY + 0.5, "o conteúdo aberto sai da conversa")
    XCTAssertGreaterThanOrEqual(last.frame.minY, transcript.frame.minY, "o cabeçalho aberto sai por cima")
    last.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
    wait(NSPredicate(format: "value == 'Recolhido'"), on: last, timeout: 10)
    shot(app, "pill-activity-closed")

    // The rest of the stack: a quote in the tray, the keyboard, the full-screen composer and back.
    func whole(_ name: String) async throws {
      try await Task.sleep(for: .seconds(1.5))
      shot(app, name)
      let shown = last.exists
      XCTContext.runActivity(named: "\(name): transcript \(transcript.frame) · atividade \(shown ? last.frame : .zero) · pílula \(pill.frame)") { _ in }
      XCTAssertTrue(pill.exists, "a execução terminou antes da conferência (\(name))")
      XCTAssertTrue(shown, "a última Atividade sumiu (\(name))")
      XCTAssertLessThanOrEqual(last.frame.maxY, pill.frame.minY, "a última Atividade fica embaixo da pílula (\(name))")
      XCTAssertLessThanOrEqual(last.frame.maxY, transcript.frame.maxY + 0.5, "a última Atividade sai da conversa (\(name))")
    }
    let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS 'Plano registrado'")).firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 5))
    answer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 1)
    let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selecionar Tudo'")).firstMatch
    if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Confira este trecho.")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 10))
    try await whole("pill-quote")
    // Quote and keyboard together leave a 6.3" screen only the pinned prompt's height: the keyboard goes alone.
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    marker.tap()
    XCTAssertTrue(app.buttons["quote-remove"].waitForExistence(timeout: 5))
    app.buttons["quote-remove"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForNonExistence(timeout: 10))
    app.textViews["conversation-composer"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    try await whole("pill-keyboard")
    app.buttons["Adicionar"].tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForExistence(timeout: 5))
    shot(app, "pill-fullscreen")
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForNonExistence(timeout: 5))
    try await whole("pill-fullscreen-back")

    // The run ends: the pill and the working bar leave without leaving room under the conversation.
    wait(NSPredicate(format: "exists == false"), on: pill, timeout: 240)
    try await Task.sleep(for: .seconds(1.5))
    shot(app, "pill-ended")
    let bottom = transcript.cells.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
    XCTContext.runActivity(named: "fim da execução: transcript \(transcript.frame) · última célula \(bottom)") { _ in }
    XCTAssertGreaterThanOrEqual(bottom, transcript.frame.maxY - 40, "espaço vazio sob a conversa quando a pílula sai")
  }

  func testProgressShowsWhileTheSessionWorksAndLeavesWhenItEnds() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PROGRESS_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
    let row = element(app, "session-row-" + session)
    XCTAssertTrue(row.waitForExistence(timeout: 30))
    XCTAssertFalse(row.label.contains("3/7"), "An idle session shows no Progresso: \(row.label)")

    // One tiny real run that never touches the list.
    _ = try await request("/api/session/\(session)/prompt", method: "POST", body: [
      "id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      "text": "Use a ferramenta shell para rodar exatamente: sleep 45. Não use todowrite. Depois responda só: pronto.",
      "delivery": "steer",
    ])
    wait(NSPredicate(format: "label CONTAINS %@", "trabalhando · 3/7 \(Self.current)"), on: row, timeout: 60)
    shot(app, "progress-row")

    row.tap()
    let pill = app.buttons["conversation-progress"]
    XCTAssertTrue(pill.waitForExistence(timeout: 30))
    XCTAssertEqual(pill.label, "Progresso: 3 de 7. Agora: \(Self.current)")
    shot(app, "progress-pill")

    pill.tap()
    let first = element(app, "conversation-progress-item-0")
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertEqual(first.label, "Concluída: Ler o rastreador da Live Activity")
    XCTAssertEqual(element(app, "conversation-progress-item-3").label, "Em andamento: \(Self.current)")
    XCTAssertEqual(element(app, "conversation-progress-item-4").label, "Pendente: Rodar os testes do OpenCodeKit")
    XCTAssertEqual(element(app, "conversation-progress-item-6").label, "Cancelada: Migrar as fixtures antigas")
    XCTAssertFalse(element(app, "conversation-progress-item-7").exists)
    shot(app, "progress-sheet")
    app.buttons["Fechar"].firstMatch.tap()
    wait(NSPredicate(format: "exists == false"), on: first, timeout: 10)

    // The run ends on its own: the pill leaves, and so does the row's Progresso.
    wait(NSPredicate(format: "exists == false"), on: pill, timeout: 180)
    shot(app, "progress-ended")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    wait(NSPredicate(format: "NOT (label CONTAINS '3/7')"), on: row, timeout: 30)
    shot(app, "progress-row-ended")
  }
}
