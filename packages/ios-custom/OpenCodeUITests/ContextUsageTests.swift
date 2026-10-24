import XCTest

@MainActor final class ContextUsageTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ id: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", id]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 30), .completed)
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "cache-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testFixedUsageBelowComposerOpensDetailsAndDoesNotRepeatInAnswers() throws {
    let app = try launch(try XCTUnwrap(environment["OPENCODE_TEST_USAGE_COMPLETE"]))
    let line = app.buttons["conversation-usage"]
    XCTAssertTrue(line.waitForExistence(timeout: 15))
    XCTAssertTrue(line.label.contains("Contexto 38 por cento"))
    XCTAssertTrue(line.label.contains("cache 91 por cento"))
    XCTAssertEqual(app.buttons.matching(identifier: "conversation-usage").count, 1)
    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'answer-usage-'" )).firstMatch.exists)
    XCTAssertTrue(app.buttons["Copiar resposta"].exists)
    XCTAssertGreaterThan(line.frame.minY, app.buttons["model-picker"].frame.maxY)
    XCTAssertLessThanOrEqual(line.frame.minX, app.textViews["conversation-composer"].frame.minX)
    shot("fixed")
    line.tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Uso da sessão'")).firstMatch.exists)
    XCTAssertTrue(app.descendants(matching: .any)["session-usage-context"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["session-usage-cache"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["session-usage-tokens"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["session-usage-cost"].exists)
    shot("session")
    for _ in 0..<8 {
      if app.staticTexts["Projeto"].exists { break }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(app.staticTexts["Projeto"].exists)
    app.buttons["Fechar"].tap()
    app.terminate()
  }

  func testNoMeasurementHidesUsage() throws {
    let app = try launch(try XCTUnwrap(environment["OPENCODE_TEST_USAGE_MISSING"]))
    XCTAssertFalse(app.buttons["conversation-usage"].exists)
    app.terminate()
    let empty = try launch(try XCTUnwrap(environment["OPENCODE_TEST_USAGE_EMPTY"]))
    XCTAssertFalse(empty.buttons["conversation-usage"].exists)
    empty.terminate()
  }

  func testKeyboardAndExpandedComposerReserveTheirOwnSpace() throws {
    let app = try launch(try XCTUnwrap(environment["OPENCODE_TEST_USAGE_COMPLETE"]))
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Rascunho local de verificação.")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    let line = app.buttons["conversation-usage"]
    XCTAssertTrue(line.exists)
    XCTAssertGreaterThan(line.frame.minY, app.buttons["model-picker"].frame.maxY)
    XCTAssertLessThanOrEqual(line.frame.maxY, app.keyboards.firstMatch.frame.minY)
    XCTAssertLessThanOrEqual(app.collectionViews["conversation-transcript"].frame.maxY, editor.frame.minY)
    shot("keyboard")
    line.tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["session-usage-context"].exists)
    app.buttons["Fechar"].tap()
    editor.tap()
    app.buttons["Adicionar"].tap()
    let expand = app.buttons.matching(identifier: "Expandir compositor")
    XCTAssertTrue(expand.firstMatch.waitForExistence(timeout: 5))
    try XCTUnwrap(expand.allElementsBoundByIndex.first(where: \.isHittable)).tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForExistence(timeout: 10))
    XCTAssertFalse(line.exists)
    shot("expanded")
    app.buttons["Recolher"].tap()
    XCTAssertTrue(line.waitForExistence(timeout: 15))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(line.frame.maxY, app.keyboards.firstMatch.frame.minY)
    app.terminate()
  }

  func testVoiceBarAndUsageLineReserveSpaceAroundComposer() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeVoiceBarFixture", "speaking", "-OpenCodeOpenSession",
      try XCTUnwrap(environment["OPENCODE_TEST_USAGE_COMPLETE"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let voice = app.descendants(matching: .any)["floating-voice-bar"]
    let line = app.buttons["conversation-usage"]
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(line.waitForExistence(timeout: 25))
    XCTAssertTrue(voice.waitForExistence(timeout: 15))
    XCTAssertLessThanOrEqual(app.collectionViews["conversation-transcript"].frame.maxY, voice.frame.minY)
    XCTAssertLessThanOrEqual(voice.frame.maxY, editor.frame.minY)
    XCTAssertGreaterThan(line.frame.minY, app.buttons["model-picker"].frame.maxY)
    editor.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(voice.frame.maxY, editor.frame.minY)
    XCTAssertLessThanOrEqual(line.frame.maxY, app.keyboards.firstMatch.frame.minY)
    shot("voice-keyboard")
    app.terminate()
  }

  func testChildShowsItsOwnCurrentMeasurementAndUpdatesLive() async throws {
    let child = try XCTUnwrap(environment["OPENCODE_TEST_USAGE_CHILD"])
    let app = try launch(child)
    let line = app.buttons["conversation-usage"]
    XCTAssertTrue(line.waitForExistence(timeout: 20))
    XCTAssertFalse(line.label.contains("399 mil"))
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].exists)
    XCTAssertTrue(app.staticTexts["child-agent"].exists)
    XCTAssertTrue(app.buttons["Parar"].exists)
    shot("child")
    let before = line.label
    try await update(child)
    XCTAssertTrue(line.exists)
    wait(NSPredicate(format: "label != %@ AND label CONTAINS 'cache'", before), on: line)
    shot("child-updated")
    app.terminate()
  }

  func testNewSessionHasNoUsageLine() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 25))
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["conversation-usage"].exists)
    app.terminate()
  }

  func testAgentsUseFamilyContextAndRefreshWithoutNavigation() async throws {
    let app = try launch(try XCTUnwrap(environment["OPENCODE_TEST_USAGE_PARENT"]))
    let agents = app.buttons.matching(NSPredicate(format: "label CONTAINS 'agente' AND label CONTAINS 'execução'" )).firstMatch
    XCTAssertTrue(agents.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "hittable == true"), on: agents)
    agents.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    let childID = try XCTUnwrap(environment["OPENCODE_TEST_USAGE_CHILD"])
    let line = app.otherElements.matching(identifier: "child-usage-" + childID).firstMatch
    XCTAssertTrue(line.waitForExistence(timeout: 20))
    XCTAssertTrue(line.label.contains("cache"))
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Parar '" )).firstMatch.exists)
    shot("agents")
    let before = line.label
    try await update(childID)
    XCTAssertTrue(line.waitForExistence(timeout: 20))
    wait(NSPredicate(format: "label != %@ AND label CONTAINS 'cache'", before), on: line)
    shot("agents-updated")
    app.buttons["Concluir"].tap()
    app.terminate()
  }

  private func update(_ child: String) async throws {
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    func api(_ path: String, body: [String: String]) async throws {
      var request = URLRequest(url: URL(string: TestSandbox.url + path)!)
      request.httpMethod = "POST"
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
    }
    try await api("/api/session/" + child + "/interrupt", body: [:])
    func active() async throws -> Bool {
      var request = URLRequest(url: URL(string: TestSandbox.url + "/api/session/active")!)
      request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
      let (data, _) = try await URLSession.shared.data(for: request)
      return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])?[child] != nil
    }
    let stopping = ContinuousClock.now.advanced(by: .seconds(20))
    while try await active(), ContinuousClock.now < stopping {
      try await Task.sleep(for: .milliseconds(100))
    }
    let stillRunning = try await active()
    XCTAssertFalse(stillRunning)
    func state() async throws -> (Double, String?) {
      var request = URLRequest(url: URL(string: TestSandbox.url + "/api/session/" + child)!)
      request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
      let (data, _) = try await URLSession.shared.data(for: request)
      let value = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
      return ((value?["time"] as? [String: Any])?["idle"] as? Double ?? 0, value?["outcome"] as? String)
    }
    let watermark = try await state().0
    try await api("/api/session/" + child + "/prompt", body: ["id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
      "text": "Responda apenas: Medição atualizada.", "delivery": "steer"])
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    repeat {
      let value = try await state()
      if value.0 > watermark, value.1 == "succeeded" { break }
      try await Task.sleep(for: .milliseconds(250))
    } while ContinuousClock.now < deadline
    let completed = try await state()
    XCTAssertGreaterThan(completed.0, watermark)
    XCTAssertEqual(completed.1, "succeeded")
    try await api("/api/session/" + child + "/prompt", body: ["id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
      "text": "Use apenas shell para executar sleep 600, sem background. Depois responda: fim.", "delivery": "steer"])
    let starting = ContinuousClock.now.advanced(by: .seconds(20))
    while try await active() == false, ContinuousClock.now < starting {
      try await Task.sleep(for: .milliseconds(100))
    }
    let restarted = try await active()
    XCTAssertTrue(restarted)
  }
}
