import XCTest

/// Reads existing sandbox fixtures only: never submits prompts or answers seeded requests.
@MainActor final class TranscriptCompatibilityTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func launch(_ role: String, native: Bool) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_" + role]),
    ]
    if native { app.launchArguments.append("-OpenCodeNativeTranscript") }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Não foi possível atualizar a conversa.'")).firstMatch.exists)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed)
  }
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<24 {
      let transcript = app.collectionViews["conversation-transcript"]
      if element.exists && element.isHittable,
        element.frame.minY > transcript.frame.minY, element.frame.maxY < transcript.frame.maxY { return }
      let forward = element.exists && element.frame.midY > transcript.frame.midY
      transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.65 : 0.45))
        .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.45 : 0.65)))
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }
  private func shot(_ name: String, native: Bool) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = (native ? "native-" : "rpc-") + name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testToolsReasoningAndChildThroughBothTransports() throws {
    for native in [false, true] {
      let app = try launch("WORKING", native: native)
      let group = app.buttons["Usou 5 · Leu, Agente e Editou"]
      reveal(group, app: app)
      if !app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pensou'")).firstMatch.exists { group.tap() }
      let reasoning = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pensou'")).firstMatch
      reveal(reasoning, app: app)
      XCTAssertTrue(reasoning.exists)
      shot("tools-reasoning-subagents", native: native)
      let subagent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Comparar alternativas Linear'")).firstMatch
      reveal(subagent, app: app)
      shot("subagent-cards", native: native)
      app.terminate()
      let child = try launch("CHILD", native: native)
      XCTAssertTrue(child.textViews.matching(NSPredicate(format: "value CONTAINS 'Licenças revisadas'")).firstMatch.waitForExistence(timeout: 10))
      XCTAssertTrue(child.buttons["Voltar à sessão principal"].exists)
      shot("child", native: native)
      child.terminate()
    }
  }
  func testAttachmentsCompactionAndOlderPagesThroughBothTransports() throws {
    for native in [false, true] {
      var app = try launch("HISTORY", native: native)
      shot("history-tail", native: native)
      let compaction = app.staticTexts["Contexto resumido"]
      reveal(compaction, app: app)
      shot("compaction", native: native)
      let attachment = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'exemplo.png'")).firstMatch
      for _ in 0..<20 {
        if attachment.exists && attachment.isHittable { break }
        let transcript = app.collectionViews["conversation-transcript"]
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
          .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
      }
      XCTAssertTrue(attachment.exists && attachment.isHittable)
      XCTAssertFalse(app.staticTexts["Imagem indisponível"].exists)
      shot("attachment", native: native)
      if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
      // Start paging from a fresh tail, not pages already loaded while locating the image.
      app.buttons["Voltar"].tap()
      app.terminate()
      app = try launch("HISTORY", native: native)
      app.buttons["Mais opções"].tap()
      app.buttons["Buscar na conversa"].tap()
      let search = app.textFields["conversation-search"]
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      search.tap()
      search.typeText("revisao 1 concluida")
      wait(NSPredicate(format: "label == '0 de 0'"), on: app.staticTexts["search-counter"])
      app.buttons["Buscar em mensagens mais antigas"].tap()
      wait(NSPredicate(format: "label == '1 de 1'"), on: app.staticTexts["search-counter"])
      XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Revisão 1 concluída'")).firstMatch.waitForExistence(timeout: 10))
      shot("older-page", native: native)
      app.terminate()
    }
  }
  func testPendingPermissionAndQuestionThroughBothTransports() throws {
    for native in [false, true] {
      let permission = try launch("PERMISSION", native: native)
      XCTAssertTrue(permission.buttons["Permitir"].waitForExistence(timeout: 10))
      XCTAssertTrue(permission.buttons["Negar"].exists)
      shot("permission", native: native)
      permission.terminate()
      let question = try launch("QUESTION", native: native)
      XCTAssertTrue(question.staticTexts["Qual licença você quer revisar?"].waitForExistence(timeout: 10))
      shot("question", native: native)
      question.terminate()
    }
  }
}
