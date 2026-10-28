import XCTest

/// Needs two owned sessions from `script/test-session-swipe.py`: the target and a more recent unpinned anchor.
@MainActor final class SessionSwipeTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "swipe-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSwipePinsAndRenames() throws {
    let target = try XCTUnwrap(environment["OPENCODE_SWIPE_TARGET"])
    let anchor = try XCTUnwrap(environment["OPENCODE_SWIPE_ANCHOR"])
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let row = app.buttons["session-row-" + target]
    let other = app.buttons["session-row-" + anchor]
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    app.revealSessionRow(row)
    XCTAssertFalse(row.label.contains(", fixada"))
    assertBelowAnchor(row, other)

    row.swipeRight()
    XCTAssertTrue(app.buttons["Fixar"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Mais"].exists)
    XCTAssertFalse(app.buttons["Abrir sessão"].exists)
    shot("leading-actions")
    app.buttons["Fixar"].tap()
    wait(row, label: ", fixada", present: true)
    app.revealSessionRow(row)
    XCTAssertTrue(!other.exists || other.frame.minY >= row.frame.maxY, "A fixada deve subir acima das não fixadas.")
    // "Precisa de você" and "Trabalhando" come first; within the list below them, pinned rows lead.
    let pinned = app.buttons["session-section-pinned"]
    XCTAssertTrue(pinned.exists && pinned.frame.maxY <= row.frame.minY, "A fixada deve entrar em Fixadas.")
    let above = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).allElementsBoundByIndex
      .filter { $0.identifier != row.identifier && $0.frame.maxY <= row.frame.minY && $0.frame.minY >= pinned.frame.maxY }
    XCTAssertTrue(above.allSatisfy { $0.label.contains(", fixada") }, "Só sessões fixadas podem ficar acima.")
    shot("pinned")

    row.swipeRight()
    XCTAssertTrue(app.buttons["Desafixar"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Mais"].exists)
    app.buttons["Desafixar"].tap()
    wait(row, label: ", fixada", present: false)
    app.revealSessionRow(row)
    assertBelowAnchor(row, other)
    shot("unpinned")

    // Renaming last: the server may treat it as activity and move the row above the anchor.
    row.swipeLeft()
    XCTAssertTrue(app.buttons["Renomear"].waitForExistence(timeout: 5))
    for action in ["Avisar ao terminar", "Arquivar", "Excluir"] { XCTAssertTrue(app.buttons[action].exists, action) }
    for action in ["Mais", "Abrir sessão", "Fixar", "Desafixar", "Silenciar"] { XCTAssertFalse(app.buttons[action].exists, action) }
    let order = ["Avisar ao terminar", "Arquivar", "Renomear", "Excluir"].map { app.buttons[$0].frame.minX }
    XCTAssertEqual(order, order.sorted())
    shot("trailing-actions")
    app.buttons["Renomear"].tap()
    XCTAssertTrue(app.alerts["Renomear sessão"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    // Evidence of the QuickType bar and Return key before typing hides the software keyboard.
    shot("rename-keyboard")
    app.assertRenameTitleSelected()
    app.typeText(XCUIKeyboardKey.delete.rawValue + "Deslize renomeada")
    shot("rename")
    // Return confirms like Salvar.
    app.typeText("\n")
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
      evaluatedWith: app.alerts["Renomear sessão"])], timeout: 5), .completed)
    XCTAssertTrue(app.staticTexts["Sessão renomeada"].waitForExistence(timeout: 10))
    wait(row, label: "Deslize renomeada,", present: true)
    shot("renamed")

    app.revealSessionRow(row)
    row.press(forDuration: 1)
    app.buttons["Renomear"].tap()
    app.assertRenameTitleSelected()
    shot("long-press-rename")
    app.alerts.buttons["Cancelar"].tap()
    wait(row, label: "Deslize renomeada,", present: true)
  }

  private func assertBelowAnchor(_ row: XCUIElement, _ anchor: XCUIElement) {
    XCTAssertTrue(anchor.exists, "A âncora mais recente deve estar logo acima.")
    XCTAssertLessThanOrEqual(anchor.frame.maxY, row.frame.minY)
  }

  private func wait(_ row: XCUIElement, label: String, present: Bool) {
    let predicate = NSPredicate(format: present ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", label)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: row)], timeout: 10), .completed)
  }
}
