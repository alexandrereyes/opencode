import XCTest

@MainActor final class ComposerEditingUITests: XCTestCase {
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeComposerFixture",
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
  func testReturnPicksTheLoadedFirstSuggestionAndOtherwiseBreaksTheLine() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("$re")
    XCTAssertTrue(app.buttons["suggestion-review"].waitForExistence(timeout: 5))
    editor.typeText("\n")
    XCTAssertTrue(app.buttons["suggestion-review"].waitForNonExistence(timeout: 5))
    expect("$review ", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
    // No panel: Return keeps inserting a line break.
    editor.typeText("fim\n")
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "fim\n"), evaluatedWith: editor)], timeout: 5), .completed)
    // An empty list (no snippets in the fixture) keeps the line break too.
    editor.typeText("#nada")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 5))
    editor.typeText("\n")
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "#nada\n"), evaluatedWith: editor)], timeout: 5), .completed)
    // Still loading (the panel waits 180 ms): Return keeps the line break.
    editor.typeText("!REA\n")
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "!REA\n"), evaluatedWith: editor)], timeout: 5), .completed)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "composer-return-suggestion"
    shot.lifetime = .keepAlways
    add(shot)
  }
  func testBangListsFilesAndAtDoesNot() throws {
    let app = try launch()
    defer { app.terminate() }
    app.buttons["Limpar"].tap()
    let editor = app.textViews["conversation-composer"]
    let file = app.buttons["suggestion-README.md"]
    editor.tap()
    // `@` keeps agents (and sessions/apps) but no longer lists files.
    editor.typeText("@")
    XCTAssertTrue(app.buttons["suggestion-explore"].waitForExistence(timeout: 5))
    XCTAssertFalse(file.exists)
    XCTAssertFalse(app.staticTexts["Arquivos"].exists)
    shot("composer-at-without-files")
    editor.typeText("REA")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 5))
    XCTAssertFalse(file.exists)
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
    // `!` lists files and inserts the same `@path` token.
    editor.typeText("Veja !REA")
    XCTAssertTrue(file.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Arquivos"].exists)
    XCTAssertFalse(app.buttons["suggestion-explore"].exists)
    shot("composer-bang-files")
    file.tap()
    XCTAssertTrue(file.waitForNonExistence(timeout: 5))
    expect("Veja @README.md ", app: app)
    XCTAssertEqual(app.staticTexts["fixture-tokens"].label, "1 tokens")
    // `!` after a letter, punctuation or an emoji is prose.
    for prose in ["ok!", " Pode arrumar!", " Sério?!", " 👍!"] {
      editor.typeText(prose)
      XCTAssertFalse(app.staticTexts["Arquivos"].waitForExistence(timeout: 1.5), prose)
      XCTAssertFalse(app.staticTexts["Nenhum item correspondente"].exists, prose)
    }
    expect("Veja @README.md ok! Pode arrumar! Sério?! 👍!", app: app)
    shot("composer-bang-prose")
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + (ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
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
