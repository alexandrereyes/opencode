import XCTest

@MainActor final class UserBubbleTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ role: String = "BUBBLE", theme: String = "openchamber-dark", preference: Bool? = true) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_" + role]),
    ]
    if let preference { app.launchArguments += ["-OpenCodeCollapsibleUserMessages", preference ? "YES" : "NO"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed)
  }
  private func prompt(_ app: XCUIApplication) throws -> XCUIElement {
    app.descendants(matching: .any)["user-prompt-" + (try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_MESSAGE"]))]
  }
  private func toggle(_ app: XCUIApplication) throws -> XCUIElement {
    app.buttons["user-prompt-toggle-" + (try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_MESSAGE"]))]
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func scrollAnswer(_ app: XCUIApplication, below: CGFloat, up: Bool) {
    let list = app.collectionViews["conversation-transcript"].frame
    let top = max(below + 24, list.midY)
    let bottom = list.maxY - 24
    let a = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: up ? bottom : top))
    let b = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: up ? top : bottom))
    a.press(forDuration: 0.05, thenDragTo: b)
  }

  func testPinnedPromptOnlyChangesWhenExplicitlyExpandedInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch(theme: theme)
      let control = try toggle(app)
      let text = try prompt(app)
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      XCTAssertEqual(control.value as? String, "Recolhido")
      let height = text.frame.height
      let y = text.frame.minY
      XCTAssertLessThan(height, 45)
      shot(app, "app-collapsed-" + theme)
      for up in [false, true, false] {
        scrollAnswer(app, below: control.frame.maxY, up: up)
        XCTAssertEqual(control.value as? String, "Recolhido")
        XCTAssertEqual(text.frame.height, height, accuracy: 1)
        XCTAssertEqual(text.frame.minY, y, accuracy: 2)
      }
      text.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      XCTAssertGreaterThan(text.frame.height, height)
      XCTAssertLessThanOrEqual(text.frame.height, app.frame.height * 0.4)
      let expandedHeight = text.frame.height
      shot(app, "app-expanded-" + theme)
      for up in [true, false] {
        scrollAnswer(app, below: control.frame.maxY, up: up)
        XCTAssertEqual(control.value as? String, "Expandido")
        XCTAssertEqual(text.frame.height, expandedHeight, accuracy: 1)
      }
      text.tap()
      XCTAssertEqual(control.value as? String, "Expandido", "Tocar o texto expandido não recolhe")
      text.swipeUp(velocity: .slow)
      shot(app, "app-internal-scroll-" + theme)
      XCTAssertEqual(control.value as? String, "Expandido")
      control.tap()
      wait(NSPredicate(format: "value == 'Recolhido'"), on: control)
      XCTAssertEqual(text.frame.height, height, accuracy: 1)
      control.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      control.tap()
      shot(app, "app-recollapsed-" + theme)
      app.terminate()
    }
  }

  func testShortPromptHasNoExpansionControl() throws {
    let app = try launch("SHORT")
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'user-prompt-toggle-'")).firstMatch.exists)
    app.terminate()
  }

  func testCopyAndQuoteMenuPreserveCollapsedState() throws {
    let app = try launch()
    let text = try prompt(app)
    text.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Copiar"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Copiar citação"].exists)
    app.buttons["Copiar"].tap()
    XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
    XCTAssertTrue(app.staticTexts["nota-sintetica.txt"].exists)
    shot(app, "app-copy-menu-preserved")
    app.terminate()
  }

  func testCollapsePreferenceInVoceDefaultsOnAndPersists() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      var app = try launch(theme: theme, preference: nil)
      XCTAssertTrue(try toggle(app).waitForExistence(timeout: 10))
      app.buttons["Voltar"].tap()
      app.tabBars.buttons["Você"].tap()
      var setting = app.switches["settings-collapsible-user-messages"]
      XCTAssertTrue(setting.waitForExistence(timeout: 10))
      app.swipeUp(velocity: .slow)
      XCTAssertEqual(setting.value as? String, "1")
      setting.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      wait(NSPredicate(format: "value == '0'"), on: setting)
      shot(app, "app-setting-disabled-" + theme)
      app.terminate()
      app = try launch(theme: theme, preference: nil)
      XCTAssertFalse(try toggle(app).exists)
      XCTAssertGreaterThan(try prompt(app).frame.height, 45)
      scrollAnswer(app, below: try prompt(app).frame.maxY, up: false)
      XCTAssertFalse(try toggle(app).exists)
      shot(app, "app-collapse-disabled-" + theme)
      app.buttons["Voltar"].tap()
      app.tabBars.buttons["Você"].tap()
      setting = app.switches["settings-collapsible-user-messages"]
      XCTAssertTrue(setting.waitForExistence(timeout: 10))
      app.swipeUp(velocity: .slow)
      XCTAssertEqual(setting.value as? String, "0")
      setting.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      wait(NSPredicate(format: "value == '1'"), on: setting)
      app.terminate()
      app = try launch(theme: theme, preference: nil)
      XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
      shot(app, "app-setting-enabled-" + theme)
      app.terminate()
    }
  }

  func testSearchStillHighlightsAndRevealsLongPrompt() throws {
    let app = try launch()
    app.buttons["Mais opções"].tap()
    app.buttons["Buscar na conversa"].tap()
    let field = app.textFields["conversation-search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("detalhe final exclusivo")
    wait(NSPredicate(format: "label == '1 de 1'"), on: app.staticTexts["search-counter"])
    XCTAssertEqual(try toggle(app).value as? String, "Expandido")
    shot(app, "app-user-search-highlight")
    app.buttons["Cancelar"].tap()
    app.terminate()
  }
}
