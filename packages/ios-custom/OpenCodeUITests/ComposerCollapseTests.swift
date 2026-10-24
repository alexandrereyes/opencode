import XCTest

@MainActor final class ComposerCollapseTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func launch(role: String? = nil, failing: Bool = false) throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
                           environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    if let role {
      let id = try XCTUnwrap(environment["OPENCODE_TEST_" + role])
      app.launchArguments += ["-OpenCodeOpenSession", id]
      if failing { app.launchEnvironment["OPENCODE_TEST_COMPOSER_FAILURE"] = id }
    }
    app.launch()
    if role != nil { XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30)) }
    return app
  }
  private func expand(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["Adicionar"].waitForExistence(timeout: 15))
    app.buttons["Adicionar"].tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForExistence(timeout: 5))
  }
  private func assertCompact(_ app: XCUIApplication) {
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForNonExistence(timeout: 20))
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, "")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = "sent-compact"
    image.lifetime = .keepAlways
    add(image)
  }
  func testSuccessfulSendCollapsesAndDoesNotRestoreKeyboardOrExpansion() throws {
    let app = try launch(role: "OWN")
    defer { app.terminate() }
    expand(app)
    app.textViews["conversation-composer"].typeText("Responda apenas OK, sem ferramentas.")
    app.buttons["Enviar mensagem"].tap()
    assertCompact(app)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    assertCompact(app)
  }
  func testFailedSendKeepsExpandedDraftEditable() throws {
    let app = try launch(role: "COMMENT", failing: true)
    defer { app.terminate() }
    expand(app)
    let text = "Responda apenas OK. Falha de envio do compositor."
    app.textViews["conversation-composer"].typeText(text)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.staticTexts["send-error"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.navigationBars["Mensagem"].exists)
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, text)
    app.textViews["conversation-composer"].tap()
    app.textViews["conversation-composer"].typeText(" Revisado.")
    let revised = try XCTUnwrap(app.textViews["conversation-composer"].value as? String)
    XCTAssertTrue(revised.contains(" Revisado."))
    XCTAssertEqual(revised.replacingOccurrences(of: " Revisado.", with: ""), text)
    XCTAssertTrue(app.navigationBars["Mensagem"].exists)
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = "failure-stays-expanded"
    image.lifetime = .keepAlways
    add(image)
  }
  func testNewSessionSuccessfulSendOpensCompactConversation() throws {
    let app = try launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 25))
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["new-base"].exists)
    expand(app)
    app.textViews["conversation-composer"].typeText(try XCTUnwrap(environment["OPENCODE_TEST_NEW_PROMPT"]))
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Enviar mensagem"])], timeout: 20) == .completed)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    assertCompact(app)
  }
}
