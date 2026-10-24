import XCTest

/// Needs an isolated sandbox with the seeded `opencode2` project selected; sends nothing.
@MainActor final class NewSessionTypographyTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    app.buttons["Nova sessão"].tap()
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "typography-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func enabled(_ element: XCUIElement) -> Bool {
    XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)],
      timeout: 30) == .completed
  }
  private func hideKeyboard(_ app: XCUIApplication) {
    // The introduction area dismisses the keyboard.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
  }
  /// The new-session draft persists, so leave it empty for the next run.
  private func clear(_ input: XCUIElement) {
    let value = input.value as? String ?? ""
    guard !value.isEmpty else { return }
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).tap()
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
  }
  private func choose(_ identifier: String, _ app: XCUIApplication) {
    app.buttons["new-project"].tap()
    let option = app.buttons[identifier]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    option.tap()
    XCTAssertTrue(enabled(app.buttons["new-project"]))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 20))
  }

  func test01ProjectAndChatsWithoutPlaceholder() throws {
    let app = try launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 20))
    XCTAssertTrue(enabled(app.buttons["new-project"]))
    choose("new-project-opencode2", app)
    XCTAssertTrue(app.buttons["new-project"].label.contains("opencode2"))
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    clear(input)
    // VoiceOver keeps naming the field even without a visible placeholder.
    XCTAssertEqual(input.label, "Mensagem")
    XCTAssertFalse(app.staticTexts["Mensagem"].exists)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    shot("project-keyboard")
    hideKeyboard(app)
    shot("project")

    input.tap()
    let text = "Revisar as fontes da nova sessão"
    input.typeText(text)
    hideKeyboard(app)
    shot("project-typed")
    clear(input)
    XCTAssertTrue(app.descendants(matching: .any)["dictation-microphone"].waitForExistence(timeout: 5))

    choose("new-project-chats", app)
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Mensagem"].exists)
    if app.keyboards.firstMatch.exists { hideKeyboard(app) }
    shot("chats")
    choose("new-project-opencode2", app)
  }

  func test02EmptyStateWithoutProjects() throws {
    let app = try launch()
    defer { app.terminate() }
    guard app.staticTexts["Nenhum projeto selecionado"].waitForExistence(timeout: 20) else {
      throw XCTSkip("Requires an isolated sandbox without selected projects")
    }
    shot("empty")
  }
}
