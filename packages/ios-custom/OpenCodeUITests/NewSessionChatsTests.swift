import XCTest

/// Needs an isolated sandbox with at least one selected project; sends one tiny prompt to a new managed chat.
@MainActor final class NewSessionChatsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func enabled(_ element: XCUIElement) -> Bool {
    XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
      ], timeout: 30) == .completed
  }

  func test01ChatsLocationCreatesManagedChatListedUnderChatsFilter() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    let filter = app.buttons["filter-chats"]
    XCTAssertTrue(filter.waitForExistence(timeout: 20))
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'"))
    let recent = rows.count

    app.buttons["Nova sessão"].tap()
    let location = app.buttons["new-project"]
    XCTAssertTrue(location.waitForExistence(timeout: 20))
    XCTAssertTrue(enabled(location))
    location.tap()
    let chats = app.buttons["new-project-chats"]
    XCTAssertTrue(chats.waitForExistence(timeout: 5))
    let project = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'new-project-' AND identifier != 'new-project-chats'")
    ).firstMatch
    XCTAssertTrue(project.exists)
    XCTAssertLessThan(chats.frame.minY, project.frame.minY, "Chats is listed before projects, as on the web")
    shot("chats-project-sheet")
    chats.tap()

    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 10))
    XCTAssertTrue(enabled(app.buttons["Projeto: Chats"]))
    XCTAssertFalse(app.buttons["new-directory"].exists)
    XCTAssertTrue(app.staticTexts["Vale quando o chat for criado"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 20))
    shot("chats-new-session")

    let text = "Responda apenas: OK chats"
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(text)
    XCTAssertTrue(enabled(app.buttons["Enviar mensagem"]))
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
    shot("chats-sent")

    app.buttons["Voltar"].tap()
    XCTAssertTrue(filter.waitForExistence(timeout: 10))
    // Recentes keeps excluding chats; only the Chats filter lists them.
    XCTAssertEqual(rows.count, recent)
    shot("chats-recent-without-chat")
    filter.tap()
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
    shot("chats-filter")
    // Like a repository filter, an active Chats filter preselects Chats for the next new session.
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 20))
    app.buttons["Voltar"].tap()
    XCTAssertTrue(filter.waitForExistence(timeout: 10))
    filter.tap()
  }
}
