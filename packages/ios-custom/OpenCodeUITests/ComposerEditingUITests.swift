import XCTest

@MainActor final class ComposerEditingUITests: XCTestCase {
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeComposerFixture",
                           "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 10))
    return app
  }
  private func expect(_ text: String, app: XCUIApplication) {
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: app.staticTexts["fixture-text"])], timeout: 5) == .completed)
  }
  func testSuggestionsTypingDeletionAndDraftRestore() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("$sam")
    XCTAssertTrue(app.buttons["suggestion-sample"].waitForExistence(timeout: 5))
    app.buttons["suggestion-sample"].tap()
    editor.typeText("inicio $rev")
    XCTAssertTrue(app.buttons["suggestion-review"].waitForExistence(timeout: 5))
    app.buttons["suggestion-review"].tap()
    editor.typeText("fim")
    expect("$sample inicio $review fim", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "2 tokens")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
    expect("$sample inicio ", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
    editor.typeText("texto restaurado")
    app.buttons["Salvar"].tap()
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "composer-skills"
    shot.lifetime = .keepAlways
    add(shot)
    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    expect("$sample inicio texto restaurado", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
    editor.typeText(" depois")
    expect("$sample inicio texto restaurado depois", app: app)
  }
  func testNativeSelectAllAndUndo() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("antes $sam")
    XCTAssertTrue(app.buttons["suggestion-sample"].waitForExistence(timeout: 5))
    app.buttons["suggestion-sample"].tap()
    editor.typeText("depois")
    editor.press(forDuration: 1.2)
    let select = app.menuItems["Selecionar Tudo"]
    if select.waitForExistence(timeout: 3) { select.tap() }
    else {
      let all = app.buttons["Selecionar Tudo"]
      XCTAssertTrue(all.waitForExistence(timeout: 3)); all.tap()
    }
    editor.typeText("substituido")
    expect("substituido", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "0 tokens")
    app.buttons["Desfazer"].tap()
    expect("antes $sample depois", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
  }

  func testDoubleTapTokenAndReplaceSelection() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Antes $sam")
    XCTAssertTrue(app.buttons["suggestion-sample"].waitForExistence(timeout: 5))
    app.buttons["suggestion-sample"].tap()
    editor.typeText("depois")
    editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85, dy: 10)).doubleTap()
    editor.typeText("X")
    expect("Antes X depois", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "0 tokens")
  }

  func testDragSelectionHandleAcrossTokenAndProse() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Antes $sam")
    XCTAssertTrue(app.buttons["suggestion-sample"].waitForExistence(timeout: 5))
    app.buttons["suggestion-sample"].tap()
    editor.typeText("depois")
    let origin = editor.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 85, dy: 10)).doubleTap()
    // Native end grabber for the body-font token, then the end of the same line.
    origin.withOffset(CGVector(dx: 122, dy: 29)).press(forDuration: 0.3,
      thenDragTo: origin.withOffset(CGVector(dx: 210, dy: 10)))
    editor.typeText("X")
    expect("Antes X", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "0 tokens")
  }
}
