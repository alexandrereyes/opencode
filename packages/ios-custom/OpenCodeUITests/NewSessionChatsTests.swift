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

  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    return app
  }
  private func openNewSession(_ app: XCUIApplication) {
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 20))
    XCTAssertTrue(enabled(app.buttons["new-project"]))
  }
  private func leave(_ app: XCUIApplication) {
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 10))
  }

  /// Starts with an empty or chat new-session draft.
  func test01ChatsLocationCreatesManagedChatListedUnderChatsFilter() throws {
    let app = try launch()
    defer { app.terminate() }
    let filter = app.buttons["filter-chats"]
    XCTAssertTrue(filter.waitForExistence(timeout: 20))
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'"))
    let recent = rows.count

    // The Sessões "+" starts in Chats instead of the last remembered project.
    openNewSession(app)
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 10))
    app.buttons["new-project"].tap()
    let chats = app.buttons["new-project-chats"]
    XCTAssertTrue(chats.waitForExistence(timeout: 5))
    let projects = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'new-project-' AND identifier != 'new-project-chats' AND identifier != 'new-project-add'"))
    let project = projects.firstMatch
    XCTAssertTrue(project.exists)
    XCTAssertTrue(
      projects.allElementsBoundByIndex.allSatisfy { chats.frame.minY < $0.frame.minY },
      "Chats is listed before every project, as on the web")
    shot("chats-project-sheet")
    let search = app.textFields["selector-search"]
    search.tap()
    search.typeText("chat")
    XCTAssertTrue(chats.waitForExistence(timeout: 5))
    XCTAssertTrue(
      projects.allElementsBoundByIndex.allSatisfy { chats.frame.minY < $0.frame.minY })
    shot("chats-project-search")
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

    leave(app)
    // Recentes keeps excluding chats; only the Chats filter lists them.
    XCTAssertEqual(rows.count, recent)
    shot("chats-recent-without-chat")
    filter.tap()
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
    shot("chats-filter")
    openNewSession(app)
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 20))
    leave(app)
    filter.tap()
  }

  /// Needs a selected repository (`OPENCODE_TEST_CHATS_PROJECT`, default `demo`). Sends nothing.
  func test02SessionsPlusPrefersChatsOverFilterButKeepsDraftInProgress() throws {
    let name = environment["OPENCODE_TEST_CHATS_PROJECT"] ?? "demo"
    let app = try launch()
    defer { app.terminate() }
    // Requested literally: a repository filter does not override Chats for the Sessões "+".
    let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20))
    chip.tap()
    openNewSession(app)
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 10))
    shot("chats-plus-with-filter")

    // Work in progress in a project survives leaving and reopening from "+".
    app.buttons["new-project"].tap()
    // Search keeps the row on screen however many projects the sandbox has.
    let search = app.textFields["selector-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText(name)
    XCTAssertTrue(app.buttons["new-project-" + name].waitForExistence(timeout: 5))
    app.buttons["new-project-" + name].tap()
    let label = "Projeto: " + name
    XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 10))
    XCTAssertTrue(enabled(app.buttons[label]))
    let input = app.textViews["conversation-composer"]
    input.tap()
    input.typeText("rascunho em andamento")
    leave(app)
    app.buttons["Todas"].firstMatch.tap()
    openNewSession(app)
    XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 10))
    XCTAssertEqual(input.value as? String, "rascunho em andamento")
    shot("chats-plus-restored-work")

    // An emptied project draft is no longer work in progress: "+" returns to Chats.
    input.tap()
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
    leave(app)
    openNewSession(app)
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 10))
    leave(app)
  }
}
