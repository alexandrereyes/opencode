import XCTest

/// Needs an isolated sandbox. `OPENCODE_APPS_SESSION` lives in a Location where the runner connected
/// codex-computer-use; only its `list_apps` is called, no Mac app is controlled and nothing is sent.
@MainActor final class ComposerAppMentionsUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private let safariID = "suggestion-codex-computer-use:com.apple.Safari"
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme] + arguments
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    return app
  }
  private func openConversation() throws -> XCUIApplication {
    let app = try launch(["-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_APPS_SESSION"])])
    XCTAssertTrue(app.buttons["conversation-mcp-pill"].waitForExistence(timeout: 30))
    return app
  }
  private func waitValue(_ element: XCUIElement, _ value: String) {
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)],
        timeout: 30), .completed)
  }
  private func clear(_ editor: XCUIElement, count: Int) {
    if count > 0 { editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
  }
  /// Records when Safari appears after typing `@`; XCUITest's hierarchy snapshots add about a second.
  private func timing(_ name: String, safari: XCUIElement, type: () -> Void) {
    let start = Date()
    type()
    XCTAssertTrue(safari.waitForExistence(timeout: 10))
    let apps = Date().timeIntervalSince(start)
    let attachment = XCTAttachment(string: String(format: "Safari suggestion after %.0f ms", apps * 1000))
    attachment.name = "timing-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  /// The listing is gone or absent once the panel has rendered other suggestions for the same query.
  private func assertNoComputerUseApps(_ app: XCUIApplication) {
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-'")).firstMatch
        .waitForExistence(timeout: 10))
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-codex-computer-use:'")).firstMatch
        .waitForExistence(timeout: 3))
  }

  func test01AtListsConnectedComputerUseAppsAndFiltersByName() throws {
    let app = try openConversation()
    defer { app.terminate() }
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    let safari = app.buttons[safariID]
    timing("first-at", safari: safari) { editor.typeText("@") }
    shot("apps-at")
    editor.typeText("Saf")
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-codex-computer-use:' AND identifier != %@", safariID))
        .firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertTrue(safari.exists)
    shot("apps-saf")
    safari.tap()
    XCTAssertTrue(safari.waitForNonExistence(timeout: 5))
    shot("apps-inserted")
    // Safari's token is one attachment character; also remove the trailing space.
    clear(editor, count: 2)
    // A second `@` reuses the listing without waiting.
    timing("second-at", safari: safari) { editor.typeText("@") }
    clear(editor, count: 1)
  }

  func test02DisconnectedComputerUseHidesItsAppsAndReconnectingRelists() throws {
    let app = try openConversation()
    defer { app.terminate() }
    let pill = app.buttons["conversation-mcp-pill"]
    pill.tap()
    let computer = app.switches["mcp-codex-computer-use"]
    XCTAssertTrue(computer.waitForExistence(timeout: 10))
    waitValue(computer, "Ativado")
    computer.tap()
    waitValue(computer, "Desativado")
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("@")
    assertNoComputerUseApps(app)
    shot("apps-disconnected")
    clear(editor, count: 1)
    pill.tap()
    XCTAssertTrue(computer.waitForExistence(timeout: 10))
    computer.tap()
    waitValue(computer, "Ativado")
    editor.tap()
    editor.typeText("@Saf")
    XCTAssertTrue(app.buttons[safariID].waitForExistence(timeout: 15))
    shot("apps-reconnected")
    clear(editor, count: 4)
  }

  /// A new chat only records MCP intent before its directory exists; the apps come from the server's
  /// latest Computer Use listing (test01 made one in this sandbox).
  func test03NewChatListsAppsForComputerUseIntent() throws {
    let app = try launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    app.showSessions()
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 20))
    let computer = app.switches["mcp-codex-computer-use"]
    XCTAssertTrue(computer.waitForExistence(timeout: 30))
    if computer.value as? String != "Ativado" { computer.tap() }
    waitValue(computer, "Ativado")
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    // The new-session draft persists; start from an empty one.
    clear(editor, count: (editor.value as? String ?? "").count)
    editor.typeText("@Saf")
    XCTAssertTrue(app.buttons[safariID].waitForExistence(timeout: 10))
    shot("new-chat-apps")
    clear(editor, count: 4)
    // With the keyboard up, the first tap outside the editor may only end editing.
    computer.tap()
    if XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Desativado'"), object: computer)],
      timeout: 3) != .completed
    {
      computer.tap()
    }
    waitValue(computer, "Desativado")
    editor.tap()
    editor.typeText("@")
    assertNoComputerUseApps(app)
    shot("new-chat-intent-off")
    clear(editor, count: 1)
  }
}
