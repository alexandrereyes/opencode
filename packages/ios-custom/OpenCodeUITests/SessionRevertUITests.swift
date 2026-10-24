import XCTest

@MainActor final class SessionRevertUITests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }
  private func value(_ key: String) throws -> String { try XCTUnwrap(env["OPENCODE_REVERT_" + key]) }
  private func launch(_ session: String, failure: Bool = false, category: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeOpenSession", session,
      "-OpenCodeTheme", env["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(env["OPENCODE_TEST_PASSWORD"])
    if let category { app.launchArguments += ["-UIPreferredContentSizeCategoryName", category, "-OpenCodeSizingDiagnostics"] }
    if failure { app.launchEnvironment["OPENCODE_TEST_REVERT_FAILURE"] = session }
    app.launch()
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 30))
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "revert-" + name + "-" + (env["OPENCODE_TEST_THEME"] ?? "dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func show(_ id: String, app: XCUIApplication) -> XCUIElement {
    let button = app.buttons["user-revert-" + id]
    let list = app.collectionViews["conversation-transcript"]
    for _ in 0..<8 {
      if button.exists && button.isHittable { return button }
      list.swipeDown()
    }
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    return button
  }
  private func answer(_ button: String, app: XCUIApplication) {
    let alert = app.alerts["Redefinir para este ponto?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label == %@",
      "A mensagem volta para o campo de texto e as seguintes ficam ocultas até Refazer. Enviar uma nova mensagem apaga as ocultas de vez.")).firstMatch.exists)
    alert.buttons[button].tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
  }
  private func restored(_ text: String, app: XCUIApplication) {
    let editor = app.textViews["conversation-composer"]
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: editor)], timeout: 30), .completed)
    XCTAssertTrue(app.buttons["revert-redo"].waitForExistence(timeout: 30))
  }

  func testUndoLastEarlierCascadeAndRedo() throws {
    let app = try launch(value("SESSION"))
    defer { app.terminate() }
    let last = try value("LAST")
    let earlier = try value("EARLIER")
    shot("before")
    show(last, app: app).tap()
    shot("confirm")
    answer("Redefinir", app: app)
    restored(try value("LAST_TEXT"), app: app)
    XCTAssertFalse(app.buttons["user-revert-" + last].exists)
    shot("last")
    // The bar's Desfazer hides one more message, so it asks too; Cancelar keeps the current boundary.
    app.buttons["revert-undo"].tap()
    shot("bar-confirm")
    answer("Cancelar", app: app)
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, try value("LAST_TEXT"))
    XCTAssertTrue(app.buttons["user-revert-" + earlier].exists)
    app.buttons["revert-undo"].tap()
    answer("Redefinir", app: app)
    restored(try value("EARLIER_TEXT"), app: app)
    XCTAssertFalse(app.buttons["user-revert-" + earlier].exists)
    shot("earlier")
    app.buttons["revert-redo"].tap()
    XCTAssertFalse(app.alerts.firstMatch.exists)
    restored(try value("LAST_TEXT"), app: app)
    app.buttons["revert-redo"].tap()
    XCTAssertTrue(app.buttons["user-revert-" + last].waitForExistence(timeout: 30))
    shot("redo")
    show(earlier, app: app).tap()
    answer("Redefinir", app: app)
    restored(try value("EARLIER_TEXT"), app: app)
    shot("cascade")
  }

  func testCancelKeepsTimelineAndDraft() throws {
    let app = try launch(value("FAILURE"))
    defer { app.terminate() }
    let message = try value("FAILURE_MESSAGE")
    let composer = app.textViews["conversation-composer"]
    let draft = composer.value as? String
    show(message, app: app).tap()
    answer("Cancelar", app: app)
    let prompt = app.descendants(matching: .any)["user-prompt-" + message]
    prompt.press(forDuration: 1)
    let action = app.buttons.matching(NSPredicate(format: "label == 'Redefinir para este ponto'")).firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    action.tap()
    answer("Cancelar", app: app)
    XCTAssertTrue(app.buttons["user-revert-" + message].exists)
    XCTAssertFalse(app.buttons["revert-redo"].exists)
    XCTAssertEqual(composer.value as? String, draft)
    shot("cancelled")
  }

  func testFailureKeepsTimelineAndRestoredDraft() throws {
    let app = try launch(value("FAILURE"), failure: true)
    defer { app.terminate() }
    show(try value("FAILURE_MESSAGE"), app: app).tap()
    answer("Redefinir", app: app)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Não foi possível atualizar a sessão.'")).firstMatch.waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["user-revert-" + (try value("FAILURE_MESSAGE"))].waitForExistence(timeout: 15))
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, "Mensagem da falha simulada.")
    shot("failure")
  }

  func testDismissMenuDoesNotRevert() throws {
    let app = try launch(value("FAILURE"))
    defer { app.terminate() }
    let message = try value("FAILURE_MESSAGE")
    let prompt = app.descendants(matching: .any)["user-prompt-" + message]
    XCTAssertTrue(prompt.waitForExistence(timeout: 15))
    prompt.press(forDuration: 1)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Redefinir para este ponto'")).firstMatch.waitForExistence(timeout: 5))
    shot("menu")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15)).tap()
    XCTAssertTrue(app.buttons["user-revert-" + message].exists)
  }

  func testChildDoesNotOfferSentMessageUndo() throws {
    let app = try launch(value("CHILD"))
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'user-revert-'")).count, 0)
    shot("child")
  }

  func testNewPromptCommitsStagedBoundary() throws {
    let app = try launch(value("COMMIT"))
    defer { app.terminate() }
    let prompt = app.descendants(matching: .any)["user-prompt-" + (try value("COMMIT_MESSAGE"))]
    XCTAssertTrue(prompt.waitForExistence(timeout: 10))
    prompt.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Copiar"].waitForExistence(timeout: 5))
    let action = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == 'Redefinir para este ponto'"))
      .allElementsBoundByIndex.first(where: \.isHittable))
    action.tap()
    answer("Redefinir", app: app)
    restored("Responda apenas NOVO. Não use ferramentas.", app: app)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
      evaluatedWith: app.buttons["revert-redo"])], timeout: 30), .completed)
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'NOVO'")).firstMatch.waitForExistence(timeout: 30))
    shot("committed")
  }

  func testPinnedHeaderUndoRestoresPromptAndRedo() throws {
    for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL"] {
    let app = try launch(value("STICKY"), category: category)
    defer { app.terminate() }
    let id = try value("STICKY_MESSAGE")
    let undo = app.buttons["user-revert-" + id]
    XCTAssertTrue(undo.waitForExistence(timeout: 15))
    let bubble = app.descendants(matching: .any)["user-bubble-" + id].firstMatch
    let header = app.descendants(matching: .any)["conversation-pinned-user"].firstMatch
    XCTAssertGreaterThanOrEqual(undo.frame.minY, bubble.frame.maxY)
    XCTAssertLessThanOrEqual(undo.frame.maxY, header.frame.maxY)
    shot("sticky-before")
    undo.tap()
    answer("Redefinir", app: app)
    restored("Pedido fixado para desfazer.", app: app)
    XCTAssertFalse(app.buttons["user-revert-" + id].exists)
    shot("sticky-undone")
    app.buttons["revert-redo"].tap()
    XCTAssertTrue(undo.waitForExistence(timeout: 30))
    }
  }
}
